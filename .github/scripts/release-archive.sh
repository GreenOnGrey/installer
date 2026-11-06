#!/usr/bin/env bash
# The release archive (FTR.INFRA.INST-0001 R7, tech §10): installer.tar.gz of a tag, with a top directory
# installer/, without .git, .github and tests, and with the file RELEASE, as the archive has no git to tell
# its version. Next to it installer.tar.gz.sha256. git archive gives the files the time of the commit and
# fixed modes, so the bytes depend only on the tag.
#   release-archive.sh <tag> <output directory>
set -euo pipefail

tag=${1:?tag} out=${2:?output directory}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "tag '$tag' is not in the format vX.Y.Z" >&2; exit 2; }
commit=$(git rev-parse --verify "refs/tags/$tag^{commit}")

mkdir -p "$out"
git archive --format=tar --prefix=installer/ \
  --add-virtual-file="installer/RELEASE:TAG=$tag"$'\n'"COMMIT=${commit:0:7}"$'\n' \
  "$commit" -- . ':(exclude).github' ':(exclude)tests' | gzip -n9 >"$out/installer.tar.gz"
(cd "$out" && sha256sum installer.tar.gz >installer.tar.gz.sha256)
echo "$out/installer.tar.gz: $tag ($commit)"
