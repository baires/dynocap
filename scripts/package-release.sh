#!/bin/sh
# Pack a darwin-arm64 prefix: signed binaries, the guest tree, Package.swift,
# the virtualization entitlement, and images/aarch64. Walking up from bin/dynocap
# finds guest/mkimage/main.go and Package.swift.
#
# Set DYNOCAP_RELEASE_IMAGE to a directory that already holds kernel, initrd,
# and manifest.json to reuse a built image. Otherwise this runs mkimage, which
# downloads pinned Alpine files.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "package-release.sh builds a darwin-arm64 archive and must run on Apple Silicon." >&2
  exit 1
fi

version="${1:-${DYNOCAP_VERSION:-dev}}"
name="dynocap-${version}-darwin-arm64.tar.gz"

./scripts/build-macos.sh

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/bin" "$stage/images/aarch64" "$stage/entitlements" "$stage/guest"

cp .build/release/dynocap .build/release/dynocap-workspace .build/release/dynocap-mkruntime "$stage/bin/"
chmod 755 "$stage/bin/dynocap" "$stage/bin/dynocap-workspace" "$stage/bin/dynocap-mkruntime"
cp Package.swift "$stage/Package.swift"
cp entitlements/dynocap.entitlements "$stage/entitlements/dynocap.entitlements"
tar -C "$root/guest" -cf - --exclude agent/dynocap-agent . | tar -C "$stage/guest" -xf -

if [ -n "${DYNOCAP_RELEASE_IMAGE:-}" ]; then
  for file in kernel initrd manifest.json; do
    if [ ! -f "${DYNOCAP_RELEASE_IMAGE}/$file" ]; then
      echo "DYNOCAP_RELEASE_IMAGE is missing $file: ${DYNOCAP_RELEASE_IMAGE}" >&2
      exit 1
    fi
    cp "${DYNOCAP_RELEASE_IMAGE}/$file" "$stage/images/aarch64/$file"
  done
else
  cache="${DYNOCAP_IMAGE_CACHE:-$stage/cache}"
  mkdir -p "$cache"
  (cd "$root/guest" && go run ./mkimage --arch aarch64 --out "$stage/images/aarch64" --cache "$cache" --repo "$root")
fi

mkdir -p "$root/dist"
tar -C "$stage" -czf "$root/dist/$name" bin guest Package.swift entitlements images
# Stable names are byte copies for the curl installer. The versioned archive is what the tap pins.
cp "$root/dist/$name" "$root/dist/dynocap-darwin-arm64.tar.gz"
(
  cd "$root/dist"
  shasum -a 256 "$name" > "$name.sha256"
  shasum -a 256 dynocap-darwin-arm64.tar.gz > dynocap-darwin-arm64.tar.gz.sha256
)
echo "packed dist/$name"
