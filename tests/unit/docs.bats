#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 R29, DOC-02: docs/reference.md has a row for every parameter and every exit code, and the
# links between the documents lead to files and headings that exist.

load helpers

REF="$BATS_TEST_DIRNAME/../../docs/reference.md"

# row <name> — a table row of docs/reference.md names it in its first column.
row() { grep -qE "^\| [^|]*\`$1\`" "$REF"; }

@test "DOC-02: every key of config/defaults.env has a row in docs/reference.md" {
  source "$ROOT/lib/common.sh"
  local key missing=()
  while read -r key; do
    row "$key" || missing+=("$key")
  done < <(env_keys "$ROOT/config/defaults.env")
  [ "${#missing[@]}" -eq 0 ] || { echo "no row in docs/reference.md: ${missing[*]}"; false; }
}

@test "DOC-02: every secret, exit code and service of update has a row in docs/reference.md" {
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/update.sh"
  local key code s missing=()
  for key in "${SECRET_KEYS[@]}"; do row "$key" || missing+=("$key"); done
  while read -r code; do
    grep -q "^| \`$code\` |" "$REF" || missing+=("code $code")
  done < <(grep -oE 'E_[A-Z0-9_]+=[0-9]+' "$ROOT/lib/common.sh" | cut -d= -f2)
  for s in "${UPDATE_SERVICES[@]}"; do grep -q "\`$s\`" "$REF" || missing+=("service $s"); done
  [ "${#missing[@]}" -eq 0 ] || { echo "not in docs/reference.md: ${missing[*]}"; false; }
}

# anchors <file> — the anchors GitHub gives the headings of a file, outside code blocks.
anchors() {
  awk '/^```/ { code = !code; next } !code && /^#+ / { sub(/^#+ /, ""); print }' "$1" |
    tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g'
}

@test "R29: the links between the documents lead to files and headings that exist" {
  local f link file anchor missing=()
  for f in "$ROOT"/README.md "$ROOT"/docs/*.md; do
    while read -r link; do
      [[ $link == http* || $link == mailto:* ]] && continue
      file=${link%%#*} anchor=""
      [[ $link == *#* ]] && anchor=${link#*#}
      if [[ -z $file ]]; then file=$f; else file=$(dirname "$f")/$file; fi
      if [[ ! -e $file ]]; then
        missing+=("$(basename "$f"): $link")
      elif [[ -n $anchor && $file == *.md ]] && ! anchors "$file" | grep -qx "$anchor"; then
        missing+=("$(basename "$f"): $link (no heading)")
      fi
    done < <(awk '/^```/ { code = !code; next } !code' "$f" | grep -oE '\]\([^)]+\)' | sed -E 's/^\]\((.*)\)$/\1/')
  done
  [ "${#missing[@]}" -eq 0 ] || { printf '%s\n' "${missing[@]}"; false; }
}
