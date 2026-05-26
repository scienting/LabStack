#!/usr/bin/env bash
# Write an installer ISO to a USB stick.
#
# Two modes, auto-detected from the ISO:
#
#   nixos     Raw `dd` write of a NixOS installer ISO. After booting,
#             clone your config repo and run `nixos-install --flake ...`.
#
#   ubuntu    Partition the stick (single FAT32, boot flag), copy the
#             ISO contents file-by-file, and optionally drop an
#             autoinstall.yaml at the root for unattended Subiquity
#             installs. Lets you ship a per-machine YAML without
#             rebuilding the ISO.
#
# The script self-elevates via sudo if not already running as root.
#
# Flags:
#   --iso PATH              installer ISO
#   --device PATH           target whole disk (e.g. /dev/sdb)
#   --autoinstall PATH      autoinstall.yaml (Ubuntu mode only; optional)
#   --mode nixos|ubuntu     force mode; default = auto-detect from ISO
#   --allow-internal        permit writing to a non-removable disk
#   --yes / -y              skip the typed-device confirmation
#   -h / --help             this help

set -euo pipefail



if [[ -t 1 ]]; then
    GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; BLUE=$'\e[34m'
    BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    GREEN=""; YELLOW=""; RED=""; BLUE=""; BOLD=""; RESET=""
fi
log()   { printf '%s[+]%s %s\n'  "$GREEN"  "$RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n'  "$YELLOW" "$RESET" "$*" >&2; }
err()   { printf '%s[-]%s %s\n'  "$RED"    "$RESET" "$*" >&2; }
info()  { printf '%s[i]%s %s\n'  "$BLUE"   "$RESET" "$*"; }
die()   { err "$1"; exit "${2:-1}"; }



ISO_PATH=""
DEVICE=""
AUTOINSTALL_PATH=""
MODE=""           # "" = auto-detect, else "nixos" | "ubuntu"
ALLOW_INTERNAL=0
ASSUME_YES=0

# Save original args before the parser shifts them away; needed if we
# later re-exec under sudo.
ORIG_ARGS=("$@")

while (($#)); do
    case "$1" in
        --iso)            ISO_PATH="${2:?missing path}"; shift 2 ;;
        --device|--dev)   DEVICE="${2:?missing path}"; shift 2 ;;
        --autoinstall)    AUTOINSTALL_PATH="${2:?missing path}"; shift 2 ;;
        --mode)
            MODE="${2:?missing value}"
            case "$MODE" in nixos|ubuntu) ;; *) die "--mode must be nixos or ubuntu" 2 ;; esac
            shift 2 ;;
        --allow-internal) ALLOW_INTERNAL=1; shift ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        -h|--help)
            awk '/^#!/ {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "$0"
            exit 0 ;;
        *) die "unknown arg: $1" 2 ;;
    esac
done



# Self-elevate via sudo if not already root. We re-exec rather than tell
# the user to prefix the command, so `just make-usb` and `./scripts/make-usb.sh`
# both Just Work.
if (( EUID != 0 )); then
    if ! command -v sudo >/dev/null 2>&1; then
        die "must run as root and sudo is not installed" 1
    fi
    # ORIG_ARGS may be empty; ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} expands
    # safely under set -u even when the array is unset.
    exec sudo --preserve-env=PATH -- "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi

# Require an interactive tty for any prompt we still need.
need_tty=0
[[ -z "$DEVICE" || -z "$ISO_PATH" ]] && need_tty=1
(( ASSUME_YES )) || need_tty=1
if (( need_tty )) && ! [[ -t 0 ]]; then
    die "stdin is not a tty; pass --iso, --device, and --yes for non-interactive use" 2
fi

# Tools needed regardless of mode. Mode-specific tools are checked after
# we know which mode we're in.
REQUIRED=(lsblk sync wipefs blockdev mount umount awk)
missing=()
for cmd in "${REQUIRED[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if ((${#missing[@]})); then
    err "missing tools: ${missing[*]}"
    cat >&2 <<'EOF'

On NixOS / with Nix installed, re-run inside a shell that has them:
  nix shell nixpkgs#util-linux nixpkgs#coreutils -c sudo ./scripts/make-usb.sh

On Debian/Ubuntu:
  sudo apt install util-linux coreutils
EOF
    exit 3
fi



human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"; }

is_removable() {
    # /sys/block/<name>/removable: 1 = removable (USB stick, SD via USB reader),
    # 0 = fixed (internal disk, many "USB" enclosures lie though).
    local name; name="$(basename "$1")"
    [[ "$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)" == "1" ]]
}

contains_root_or_boot() {
    # Refuse if any partition on this disk holds /, /boot, or active swap.
    local dev="$1"
    lsblk -lnpo MOUNTPOINT,NAME "$dev" | awk -v d="$dev" '
        $1=="/" || $1=="/boot" || $1=="[SWAP]" { found=1 }
        END { exit !found }
    '
}

# Detect ISO flavor from its volume identifier (ISO 9660 PVD, sector 16).
# The volume ID lives at byte offset 40 within sector 16 (32 bytes, ASCII-padded).
# We read 128 bytes from offset 32768 to cover the whole field plus context.
detect_iso_mode() {
    local iso="$1" header vid
    header="$(dd if="$iso" bs=1 skip=32808 count=128 status=none 2>/dev/null \
              | tr -d '\0' | tr -c '[:print:]' ' ')"
    # Trim leading whitespace.
    vid="${header#"${header%%[![:space:]]*}"}"
    case "$vid" in
        *[Nn][Ii][Xx][Oo][Ss]*) echo nixos ;;
        *[Uu][Bb][Uu][Nn][Tt][Uu]*) echo ubuntu ;;
        *) echo "" ;;
    esac
}

select_device() {
    log "Available whole disks:"
    printf '   %-3s %-14s %-8s %-6s %-16s %s\n' "Idx" "Device" "Size" "Bus" "Removable" "Model"

    # Use lsblk's pairs mode for robust parsing (handles spaces in MODEL).
    # lsblk -P emits lines of KEY="value" KEY="value" ... we sanity-check
    # the line matches that strict shape before eval'ing it.
    local -a CANDS=()
    local line NAME SIZE MODEL TRAN RM TYPE
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z]+=\"[^\"]*\"[[:space:]]*)+$ ]] || continue
        NAME=""; SIZE=""; MODEL=""; TRAN=""; RM=""; TYPE=""
        eval "$line"
        [[ "${TYPE:-}" == "disk" ]] || continue
        # Skip optical, loop, ram, zram, dm.
        case "$NAME" in
            /dev/sr*|/dev/loop*|/dev/ram*|/dev/zram*|/dev/dm-*) continue ;;
        esac
        CANDS+=("$NAME"$'\t'"${SIZE:-?}"$'\t'"${TRAN:-?}"$'\t'"${RM:-0}"$'\t'"${MODEL:-?}")
    done < <(lsblk -dpP -o NAME,SIZE,MODEL,TRAN,RM,TYPE)

    ((${#CANDS[@]})) || die "no candidate disks found" 4

    local i=1
    for c in "${CANDS[@]}"; do
        IFS=$'\t' read -r n s t r m <<<"$c"
        local marker=""
        if [[ "$r" == "1" ]]; then marker="${GREEN}yes${RESET}"; else marker="${YELLOW}no${RESET}"; fi
        if contains_root_or_boot "$n"; then
            marker="${RED}SYSTEM DISK${RESET}"
        fi
        printf '   %-3s %-14s %-8s %-6s %-16b %s\n' "$i" "$n" "$s" "$t" "$marker" "$m"
        ((i++))
    done
    echo
    echo "Enter 0 to abort."
    echo

    local idx
    while :; do
        read -r -p "Select device [1-${#CANDS[@]}]: " idx
        [[ "$idx" =~ ^[0-9]+$ ]] || { warn "not a number"; continue; }
        (( idx == 0 )) && die "aborted by user" 1
        (( idx >= 1 && idx <= ${#CANDS[@]} )) || { warn "out of range"; continue; }
        IFS=$'\t' read -r n _ _ r _ <<<"${CANDS[idx-1]}"
        if contains_root_or_boot "$n"; then
            err "$n is the running system disk — refusing"; continue
        fi
        if [[ "$r" != "1" ]] && (( ! ALLOW_INTERNAL )); then
            err "$n is not removable; pass --allow-internal if you really mean it"
            continue
        fi
        DEVICE="$n"
        return 0
    done
}



if [[ -z "$DEVICE" ]]; then
    select_device
else
    [[ -b "$DEVICE" ]] || die "$DEVICE is not a block device" 2
    # Reject partitions. We want whole disks only.
    if [[ "$(lsblk -dno TYPE "$DEVICE" 2>/dev/null)" != "disk" ]]; then
        die "$DEVICE is not a whole disk (partition or other type)" 4
    fi
    if contains_root_or_boot "$DEVICE"; then
        die "$DEVICE holds /, /boot, or active swap — refusing" 4
    fi
    if ! is_removable "$DEVICE" && (( ! ALLOW_INTERNAL )); then
        die "$DEVICE is not removable; pass --allow-internal to override" 4
    fi
fi

DEV_BYTES="$(blockdev --getsize64 "$DEVICE")"
log "Target: $DEVICE ($(human "$DEV_BYTES"))"



if [[ -z "$ISO_PATH" ]]; then
    while :; do
        read -r -e -p "Path to installer ISO: " ISO_PATH
        ISO_PATH="${ISO_PATH/#\~/$HOME}"
        [[ -f "$ISO_PATH" ]] && break
        warn "not a file: $ISO_PATH"
    done
fi
[[ -f "$ISO_PATH" ]] || die "ISO not found: $ISO_PATH" 2

ISO_BYTES="$(stat -c '%s' "$ISO_PATH")"
log "ISO: $ISO_PATH ($(human "$ISO_BYTES"))"

# Sanity: file should look like an ISO 9660 image.
if command -v file >/dev/null 2>&1; then
    if ! file -b "$ISO_PATH" | grep -qiE 'iso 9660|udf'; then
        warn "$(file -b "$ISO_PATH")"
        warn "file(1) doesn't recognise this as ISO 9660. Continuing anyway."
    fi
fi

# Sanity: ISO must fit on disk.
if (( ISO_BYTES > DEV_BYTES )); then
    die "ISO is larger than the disk" 4
fi

# Mode auto-detection.
if [[ -z "$MODE" ]]; then
    detected="$(detect_iso_mode "$ISO_PATH" || true)"
    if [[ -n "$detected" ]]; then
        MODE="$detected"
        log "Detected ISO type: $MODE"
    else
        warn "Could not detect ISO type from volume id."
        if [[ -t 0 ]]; then
            while :; do
                read -r -p "Mode? [nixos/ubuntu]: " MODE
                [[ "$MODE" == "nixos" || "$MODE" == "ubuntu" ]] && break
                warn "answer 'nixos' or 'ubuntu'"
            done
        else
            die "unable to auto-detect mode; pass --mode nixos|ubuntu" 2
        fi
    fi
fi

# Autoinstall is meaningless in NixOS mode; refuse silently-wrong invocations.
if [[ -n "$AUTOINSTALL_PATH" ]]; then
    [[ "$MODE" == "ubuntu" ]] || die "--autoinstall is only valid in ubuntu mode" 2
    [[ -f "$AUTOINSTALL_PATH" ]] || die "autoinstall file not found: $AUTOINSTALL_PATH" 2
fi

# Optional sha256 sidecar verification.
# Resolve through symlinks so `make-usb --iso iso/latest-...iso` finds
# the sidecar that lives next to the real file.
ISO_REAL="$(readlink -f "$ISO_PATH")"
if [[ -f "$ISO_REAL.sha256" ]]; then
    log "Verifying $ISO_REAL.sha256..."
    ( cd "$(dirname "$ISO_REAL")" && sha256sum -c "$(basename "$ISO_REAL").sha256" ) \
        || die "sha256 verification failed" 5
elif [[ -f "$ISO_PATH.sha256" ]]; then
    log "Verifying $ISO_PATH.sha256..."
    ( cd "$(dirname "$ISO_PATH")" && sha256sum -c "$(basename "$ISO_PATH").sha256" ) \
        || die "sha256 verification failed" 5
fi

# Mode-specific tool checks.
case "$MODE" in
    nixos)
        for cmd in dd; do
            command -v "$cmd" >/dev/null 2>&1 || die "nixos mode requires '$cmd'" 3
        done
        ;;
    ubuntu)
        mode_missing=()
        for cmd in parted mkfs.vfat cp; do
            command -v "$cmd" >/dev/null 2>&1 || mode_missing+=("$cmd")
        done
        if ((${#mode_missing[@]})); then
            err "ubuntu mode needs: ${mode_missing[*]}"
            cat >&2 <<'EOF'

On Debian/Ubuntu:
  sudo apt install parted dosfstools

On NixOS / with Nix installed:
  nix shell nixpkgs#parted nixpkgs#dosfstools -c sudo ./scripts/make-usb.sh
EOF
            exit 3
        fi
        ;;
esac



cat <<EOF

${BOLD}About to:${RESET}
  Mode            $MODE
  ${RED}WIPE${RESET}            $DEVICE  ($(human "$DEV_BYTES"))
  Source ISO      $ISO_PATH
EOF
if [[ "$MODE" == "ubuntu" ]]; then
    printf '  Autoinstall     %s\n' "${AUTOINSTALL_PATH:-<none>}"
fi
cat <<EOF

${YELLOW}All data on $DEVICE will be destroyed.${RESET}
EOF

if (( ! ASSUME_YES )); then
    read -r -p "Type the device path to confirm (e.g. $DEVICE): " typed
    [[ "$typed" == "$DEVICE" ]] || die "confirmation didn't match — aborting" 1
fi



log "Unmounting any partitions on $DEVICE..."
while read -r part mnt; do
    [[ -n "$mnt" ]] || continue
    warn "umount $part ($mnt)"
    umount "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || warn "could not umount $part"
done < <(lsblk -lnpo NAME,MOUNTPOINT "$DEVICE" | awk '$2!=""')



log "Wiping signatures..."
wipefs -a "$DEVICE" >/dev/null

case "$MODE" in
    nixos)
        log "Writing ISO with dd (this can take a few minutes)..."
        if ! dd if="$ISO_PATH" of="$DEVICE" bs=4M status=progress conv=fsync oflag=direct; then
            err "dd failed."
            # Surface the most recent kernel complaints about this device so the
            # user can distinguish bad-block / hardware failure ("Medium Error",
            # "Hardware Error") from cable/port flakiness ("usb ... reset",
            # "Communication failure") without having to dig through dmesg.
            dev_short="$(basename "$DEVICE")"
            if dmesg_out="$(dmesg 2>/dev/null | grep -E "(${dev_short}|usb [0-9]+-[0-9]+)" | tail -10)" \
               && [[ -n "$dmesg_out" ]]; then
                warn "Recent kernel messages mentioning ${dev_short} or USB events:"
                printf '%s\n' "$dmesg_out" | sed 's/^/    /' >&2
                warn "Look for 'Medium Error' / 'Hardware Error' (bad flash → replace stick),"
                warn "or 'reset' / 'Communication failure' (cable/port → try a different one)."
            else
                warn "Run \`sudo dmesg | tail -30\` to see why the kernel rejected the write."
            fi
            exit 5
        fi

        log "Final sync (flushing kernel buffers; may take a moment)..."
        sync
        blockdev --flushbufs "$DEVICE" 2>/dev/null || true
        ;;

    ubuntu)
        # Compute the first partition device name. NVMe and mmcblk insert
        # a 'p' before the partition number, e.g. /dev/nvme0n1p1.
        case "$DEVICE" in
            *[0-9]) PART="${DEVICE}p1" ;;
            *)      PART="${DEVICE}1"  ;;
        esac

        log "Creating single FAT32 partition on $DEVICE..."
        parted --script "$DEVICE" \
            mklabel msdos \
            mkpart primary fat32 1MiB 100% \
            set 1 boot on

        # parted returns before the kernel has rescanned the partition
        # table; give it a moment and ask explicitly.
        log "Re-reading partition table..."
        partprobe "$DEVICE" 2>/dev/null || blockdev --rereadpt "$DEVICE" 2>/dev/null || true
        udevadm settle 2>/dev/null || true

        # Wait up to ~5s for the partition node to appear.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            [[ -b "$PART" ]] && break
            sleep 0.5
        done
        [[ -b "$PART" ]] || die "partition $PART did not appear after parted" 5

        log "Formatting $PART as FAT32..."
        mkfs.vfat -F 32 -n UBUNTU "$PART" >/dev/null

        MNT_ISO="$(mktemp -d)"
        MNT_USB="$(mktemp -d)"
        cleanup() {
            # Best-effort: unmount both, remove tmp dirs.
            mountpoint -q "$MNT_USB" && { sync; umount "$MNT_USB" 2>/dev/null || umount -l "$MNT_USB" 2>/dev/null || true; }
            mountpoint -q "$MNT_ISO" && { umount "$MNT_ISO" 2>/dev/null || umount -l "$MNT_ISO" 2>/dev/null || true; }
            rmdir "$MNT_USB" "$MNT_ISO" 2>/dev/null || true
        }
        trap cleanup EXIT

        log "Mounting ISO ($ISO_PATH) at $MNT_ISO..."
        mount -o loop,ro "$ISO_PATH" "$MNT_ISO"

        log "Mounting USB ($PART) at $MNT_USB..."
        mount "$PART" "$MNT_USB"

        log "Copying ISO contents to USB..."
        # -a preserves perms/symlinks; -T treats source as the directory
        # itself rather than nesting it. We don't fail the whole run on
        # cp's exit status because read-only FAT quirks (e.g. setting
        # immutable bits) can yield nonzero status while every file
        # actually landed; we verify with a size sanity check below.
        set +e
        cp -aT "${MNT_ISO}/." "${MNT_USB}/"
        cp_status=$?
        set -e
        if (( cp_status != 0 )); then
            warn "cp returned $cp_status; FAT32 can't preserve every attribute, this is usually harmless."
        fi

        if [[ -n "$AUTOINSTALL_PATH" ]]; then
            log "Installing autoinstall.yaml at USB root..."
            cp -- "$AUTOINSTALL_PATH" "${MNT_USB}/autoinstall.yaml"
        else
            info "No --autoinstall provided; USB will boot interactively."
        fi

        log "Finish writing to USB (this can take several minutes)..."
        sync

        log "Unmounting..."
        umount "$MNT_USB"
        umount "$MNT_ISO"
        rmdir "$MNT_USB" "$MNT_ISO"
        trap - EXIT

        blockdev --flushbufs "$DEVICE" 2>/dev/null || true
        ;;
esac



echo
log "${BOLD}Done.${RESET} You can unplug $DEVICE now."
echo
case "$MODE" in
    nixos)
        info "Boot the new machine from this USB. Once at the installer shell:"
        info "  - Connect to the network (Ethernet, or 'sudo systemctl start wpa_supplicant' + 'wpa_cli', or 'nmtui' on the graphical ISO)."
        info "  - Clone your repo:   git clone <your-repo-url> /tmp/notfiles"
        info "  - Partition the target disk, mount at /mnt, then:"
        info "      nixos-install --flake /tmp/notfiles#<hostname>"
        ;;
    ubuntu)
        info "Boot the new machine from this USB."
        if [[ -n "$AUTOINSTALL_PATH" ]]; then
            info "Subiquity will pick up /autoinstall.yaml from the USB root."
            info "Any interactive sections in the YAML will still prompt for input."
        else
            info "Subiquity will start in fully interactive mode."
            info "To make it unattended, re-run with --autoinstall <path-to-yaml>."
        fi
        ;;
esac
echo
