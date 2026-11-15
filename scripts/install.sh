#!/bin/sh
# Install the latest darwin-arm64 release into ~/.local/dynocap and re-sign it
# on this Mac. https://dynocap.dev/install.sh serves this file.
set -eu
set -o pipefail

OWNER="${DYNOCAP_GITHUB_OWNER:-baires}"
REPO="${DYNOCAP_GITHUB_REPO:-dynocap}"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "dynocap installs on Apple Silicon (darwin-arm64) only." >&2
  exit 1
fi

mke2fs_present() {
  if command -v mke2fs >/dev/null 2>&1; then
    return 0
  fi
  for path in /opt/homebrew/opt/e2fsprogs/sbin/mke2fs /usr/local/opt/e2fsprogs/sbin/mke2fs /sbin/mke2fs; do
    if [ -x "$path" ]; then
      return 0
    fi
  done
  return 1
}

name="dynocap-darwin-arm64.tar.gz"
base="https://github.com/${OWNER}/${REPO}/releases/latest/download"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
if ! curl -fsSL -o "$workdir/$name" "${base}/${name}"; then
  echo "Could not download the latest ${OWNER}/${REPO} release (${name})." >&2
  exit 1
fi
if ! curl -fsSL -o "$workdir/${name}.sha256" "${base}/${name}.sha256"; then
  echo "Could not download the checksum for the latest ${OWNER}/${REPO} release." >&2
  exit 1
fi
xattr -d com.apple.quarantine "$workdir/$name" 2>/dev/null || true
(
  cd "$workdir"
  shasum -a 256 -c "${name}.sha256"
)
# The checksum comes from the same release as the archive, so it only catches
# corruption. The attestation proves this repository's release workflow built it.
# The stable asset name is a byte copy of the versioned archive the workflow attested.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if ! gh attestation verify "$workdir/$name" --repo "${OWNER}/${REPO}" >/dev/null; then
    echo "The archive has no valid build attestation from ${OWNER}/${REPO}. Not installing." >&2
    exit 1
  fi
elif [ "${DYNOCAP_REQUIRE_ATTESTATION:-0}" = "1" ]; then
  echo "DYNOCAP_REQUIRE_ATTESTATION=1 needs the GitHub CLI (gh), logged in, to verify the archive." >&2
  exit 1
else
  echo "warning: gh is not installed or not logged in, so the build attestation was not verified." >&2
  echo "         Install gh, run gh auth login, and rerun, or set DYNOCAP_REQUIRE_ATTESTATION=1 to refuse unverified installs." >&2
fi

prefix="${HOME}/.local/dynocap"
rm -rf "$prefix"
mkdir -p "$prefix" "${HOME}/.local/bin"
tar -xzf "$workdir/$name" -C "$prefix"
ln -sfn "$prefix/bin/dynocap" "${HOME}/.local/bin/dynocap"
xattr -dr com.apple.quarantine "$prefix" 2>/dev/null || true
codesign --sign - --entitlements "$prefix/entitlements/dynocap.entitlements" --force "$prefix/bin/dynocap"

if ! mke2fs_present; then
  echo "mke2fs is missing. Install it with: brew install e2fsprogs" >&2
fi
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) echo "Add ${HOME}/.local/bin to PATH to run dynocap by name." >&2 ;;
esac

"$prefix/bin/dynocap" doctor --fix
