#!/usr/bin/env bash
# resolve-tag.sh <tag> — checks the format vX.Y.Z (R18) and prints the tag.
set -euo pipefail
tag=${1:-}
if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::tag '$tag' is not in the format vX.Y.Z" >&2
  exit 1
fi
echo "$tag"
