#!/bin/sh
# Download the pinned Alpine virt kernel and minirootfs, build the static
# guest agent, and write ~/.microvm/images/<arch>/{kernel,initrd,manifest.json}.
# Requires Go 1.22+ and network. Does not require Docker.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
home="${MICROVM_HOME:-$HOME/.microvm}"
case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64) arch=x86_64 ;;
    *)
        echo "unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac
cd "$root/guest"
exec go run ./mkimage \
    --arch "$arch" \
    --out "$home/images/$arch" \
    --cache "$home/cache" \
    --repo "$root"
