#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
files=$(gofmt -l guest)
if [ -n "$files" ]; then
  printf '%s\n' "$files"
  echo "gofmt: rewrite the files above with gofmt -w"
  exit 1
fi
