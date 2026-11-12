#!/usr/bin/env bash
# Fixture for the shell:1 runtime: bash features, git and ssh, and no language toolchain.
set -euo pipefail
declare -A tools=([git]="git --version" [ssh]="ssh -V")
for name in "${!tools[@]}"; do
  ${tools[$name]} >/dev/null 2>&1 || { echo "missing $name"; exit 1; }
done
for language in node npm python3 uv go; do
  if command -v "$language" >/dev/null; then echo "unexpected $language"; exit 1; fi
done
[[ "$(printf '%s' "${BASH_VERSINFO[0]}")" -ge 5 ]]
echo "shell ok"
