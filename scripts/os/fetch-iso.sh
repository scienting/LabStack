#!/usr/bin/env bash
#
# Download the latest Ubuntu live-server installer ISO into iso/.
#
# Pulls SHA256SUMS from releases.ubuntu.com first, derives the real
# filename from it (e.g. ubuntu-24.04.4-live-server-amd64.iso), and
# only downloads if the file isn't already present and valid. Keeps a
# stable `latest-ubuntu-<edition>-<arch>.iso` symlink in iso/ pointing
# at the newest snapshot.

set -euo pipefail

RELEASE="26.04"           # 24.04, 22.04, 26.04, etc.
EDITION="live-server"     # live-server | desktop
ARCH="amd64"
DEST_DIR="iso"

while (($#)); do
    case "$1" in
        --release)  RELEASE="${2:?missing value}"; shift 2 ;;
        --edition)  EDITION="${2:?missing value}"; shift 2 ;;
        --arch)     ARCH="${2:?missing value}"; shift 2 ;;
        --dest)     DEST_DIR="${2:?missing value}"; shift 2 ;;
        -h|--help)
            awk '/^#!/ {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "$0"
            exit 0 ;;
        *) echo "[-] unknown arg: $1" >&2; exit 1 ;;
    esac
done

BASE="https://releases.ubuntu.com/${RELEASE}"
LATEST_NAME="latest-ubuntu-${EDITION}-${ARCH}.iso"

mkdir -p "$DEST_DIR"

# Fetch SHA256SUMS, which lists every artifact for the release. Lines
# look like:  <hash> *ubuntu-24.04.4-live-server-amd64.iso
echo "[+] Fetching ${BASE}/SHA256SUMS"
tmp_sums="$(mktemp)"
trap 'rm -f "$tmp_sums"' EXIT
curl --fail --location --silent --show-error --output "$tmp_sums" \
    "${BASE}/SHA256SUMS" \
    || { echo "[-] SHA256SUMS fetch failed (is release '${RELEASE}' published?)" >&2; exit 2; }

# Pick the line matching our edition + arch. The pattern intentionally
# anchors on '-${EDITION}-${ARCH}.iso' to avoid accidentally matching
# e.g. zsync or manifest files.
match_line="$(grep -E "[ *]ubuntu-[^ ]*-${EDITION}-${ARCH}\.iso\$" "$tmp_sums" | head -n1 || true)"
if [[ -z "$match_line" ]]; then
    echo "[-] no ${EDITION}-${ARCH} ISO listed in SHA256SUMS:" >&2
    cat "$tmp_sums" >&2
    exit 2
fi

# Field 2 is the filename, possibly prefixed by '*' (binary mode marker
# from sha256sum -b). Strip it.
real_name="$(awk '{print $2}' <<<"$match_line")"
real_name="${real_name#\*}"

iso="${DEST_DIR}/${real_name}"
sum="${DEST_DIR}/${real_name}.sha256"

# Build a single-line sha256 sidecar in the format `sha256sum -c`
# expects, so make-usb.sh can verify it the same way it does for the
# NixOS path.
expected_hash="$(awk '{print $1}' <<<"$match_line")"
printf '%s  %s\n' "$expected_hash" "$real_name" > "${sum}.tmp"

if [[ -f "$iso" ]]; then
    mv "${sum}.tmp" "$sum"
    if ( cd "$DEST_DIR" && sha256sum --status -c "${real_name}.sha256" ); then
        echo "[+] ${iso} already present and verified."
        ln -sfn "${real_name}" "${DEST_DIR}/${LATEST_NAME}"
        rm -f "$tmp_sums"
        trap - EXIT
        exit 0
    fi
    echo "[!] ${iso} present but sha256 mismatch. Re-downloading from scratch."
    rm -f "$iso"
else
    mv "${sum}.tmp" "$sum"
fi

rm -f "$tmp_sums"
trap - EXIT

echo "[+] Downloading ${BASE}/${real_name}"
echo "    -> ${iso}"
curl --fail --location --progress-bar --continue-at - \
    --output "$iso" "${BASE}/${real_name}" \
    || { echo "[-] download failed" >&2; exit 2; }

echo "[+] Verifying sha256..."
( cd "$DEST_DIR" && sha256sum -c "${real_name}.sha256" ) \
    || { echo "[-] sha256 verification failed" >&2; exit 3; }

ln -sfn "${real_name}" "${DEST_DIR}/${LATEST_NAME}"
echo "[+] ${iso}"
echo "[+] symlink: ${DEST_DIR}/${LATEST_NAME} -> ${real_name}"
