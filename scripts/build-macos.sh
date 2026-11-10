#!/bin/sh
# Build and ad-hoc sign the microvm CLI. Run this on the Mac that will boot VMs.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
    echo "build-macos.sh must run on macOS. On Linux, 'swift test' and 'go test ./guest/...' cover the portable code." >&2
    exit 1
fi
swift build -c release
(cd guest && go build -o ../.build/release/microvm-workspace ./workspace && go build -o ../.build/release/microvm-mkruntime ./mkruntime)
bin=".build/release/microvm"
codesign --sign - --entitlements entitlements/microvm.entitlements --force "$bin"
echo "signed $bin"
echo "next: ./scripts/fetch-image.sh"
