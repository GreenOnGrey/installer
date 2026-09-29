#!/usr/bin/env bash
# resolve-tag.sh <тег> — проверяет формат vX.Y.Z (R18) и печатает тег.
set -euo pipefail
tag=${1:-}
if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::тег «$tag» не в формате vX.Y.Z" >&2
  exit 1
fi
echo "$tag"
