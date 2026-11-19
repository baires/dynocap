#!/bin/sh
# Build and ad-hoc sign the dynocap CLI. Run this on the Mac that will boot VMs.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
    echo "build-macos.sh must run on macOS. On Linux, 'swift test' and 'go test ./guest/...' cover the portable code." >&2
    exit 1
fi
swift build -c release
(cd guest && go build -o ../.build/release/dynocap-workspace ./workspace && go build -o ../.build/release/dynocap-mkruntime ./mkruntime)
bin=".build/release/dynocap"
codesign --sign - --entitlements entitlements/dynocap.entitlements --force "$bin"
echo "signed $bin"
legacy=".build/release/microvm"
if [ -e "$legacy" ] && ! [ "$legacy" -ef "$bin" ]; then
    printf 'warning: %s is a separate build artifact from before the rename. Use %s.\n' "$legacy" "$bin" >&2
fi
echo "next: $bin doctor --fix"
