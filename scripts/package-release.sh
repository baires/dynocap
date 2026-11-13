#!/bin/sh
# Pack a darwin-arm64 prefix: signed binaries, the guest tree, Package.swift,
# the virtualization entitlement, and images/aarch64. Walking up from bin/microvm
# finds guest/mkimage/main.go and Package.swift.
#
# Set MICROVM_RELEASE_IMAGE to a directory that already holds kernel, initrd,
# and manifest.json to reuse a built image. Otherwise this runs mkimage, which
# downloads pinned Alpine files.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "package-release.sh builds a darwin-arm64 archive and must run on Apple Silicon." >&2
  exit 1
fi

version="${1:-${MICROVM_VERSION:-dev}}"
name="microvm-${version}-darwin-arm64.tar.gz"

./scripts/build-macos.sh

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/bin" "$stage/images/aarch64" "$stage/entitlements" "$stage/guest"

cp .build/release/microvm .build/release/microvm-workspace .build/release/microvm-mkruntime "$stage/bin/"
chmod 755 "$stage/bin/microvm" "$stage/bin/microvm-workspace" "$stage/bin/microvm-mkruntime"
cp Package.swift "$stage/Package.swift"
cp entitlements/microvm.entitlements "$stage/entitlements/microvm.entitlements"
tar -C "$root/guest" -cf - --exclude agent/microvm-agent . | tar -C "$stage/guest" -xf -

if [ -n "${MICROVM_RELEASE_IMAGE:-}" ]; then
  for file in kernel initrd manifest.json; do
    if [ ! -f "${MICROVM_RELEASE_IMAGE}/$file" ]; then
      echo "MICROVM_RELEASE_IMAGE is missing $file: ${MICROVM_RELEASE_IMAGE}" >&2
      exit 1
    fi
    cp "${MICROVM_RELEASE_IMAGE}/$file" "$stage/images/aarch64/$file"
  done
else
  cache="${MICROVM_IMAGE_CACHE:-$stage/cache}"
  mkdir -p "$cache"
  (cd "$root/guest" && go run ./mkimage --arch aarch64 --out "$stage/images/aarch64" --cache "$cache" --repo "$root")
fi

mkdir -p "$root/dist"
tar -C "$stage" -czf "$root/dist/$name" bin guest Package.swift entitlements images
(
  cd "$root/dist"
  shasum -a 256 "$name" > "$name.sha256"
)
echo "packed dist/$name"
