set positional-arguments

# Default: list available recipes.
default:
    @just --list

# Download the latest Ubuntu live-server ISO into iso/.
# Override defaults:  just fetch-iso --release 22.04 --edition desktop --arch amd64
fetch-iso *args:
    @./scripts/os/fetch-iso.sh "$@"

# Make a USB from scratch in one shot: fetch the ISO then write it.
# Example:  just make-usb autoinstall/head.yml
# Args after the YAML are passed through to make-usb (e.g. --device /dev/sdb --yes).
make-usb *args:
    @./scripts/os/make-usb.sh --iso iso/latest-ubuntu-live-server-amd64.iso --autoinstall ./configs/autoinstall/head.yml "$@"

# Remove all downloaded ISOs and checksums.
clean:
    rm -f iso/*.iso iso/*.iso.sha256
    @echo "iso/ cleaned."
