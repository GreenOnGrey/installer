#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 R7: the release archive (.github/scripts/release-archive.sh) and the version it carries.

load helpers

ARCHIVE="$BATS_TEST_DIRNAME/../../.github/scripts/release-archive.sh"

# tagged_clone — a repository with the files of this working copy, uncommitted ones too, and the tag v9.9.9.
tagged_clone() {
  REPO=$BATS_TEST_TMPDIR/repo
  git init -q "$REPO"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$REPO" 2>/dev/null) || true
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q -m tree
  git -C "$REPO" tag v9.9.9
}

@test "R7: installer.tar.gz of a tag: the installer, RELEASE, no tests or workflows; the checksum matches" {
  tagged_clone
  (cd "$REPO" && bash "$ARCHIVE" v9.9.9 "$BATS_TEST_TMPDIR/dist")
  cd "$BATS_TEST_TMPDIR/dist"
  sha256sum -c installer.tar.gz.sha256
  tar -tzf installer.tar.gz >list
  grep -qx 'installer/installer' list
  grep -qx 'installer/lib/wizard.sh' list
  grep -qx 'installer/RELEASE' list
  grep -qx 'installer/lib/mcp-sample.html' list
  not_grep -q '^installer/tests/' list
  not_grep -q '^installer/\.github' list
  not_grep -q '^installer/\.git/' list
  tar -xzf installer.tar.gz
  grep -qx 'TAG=v9.9.9' installer/RELEASE
  grep -qx "COMMIT=$(git -C "$REPO" rev-parse --short=7 HEAD)" installer/RELEASE
  run bash installer/installer help
  [ "$status" -eq 0 ]
  [[ $output == *Usage* ]]
}

@test "R7: the archive of a tag is the same bytes every time, whatever the umask" {
  tagged_clone
  (cd "$REPO" && bash "$ARCHIVE" v9.9.9 "$BATS_TEST_TMPDIR/a" && sleep 1 && umask 077 && bash "$ARCHIVE" v9.9.9 "$BATS_TEST_TMPDIR/b")
  cmp "$BATS_TEST_TMPDIR/a/installer.tar.gz" "$BATS_TEST_TMPDIR/b/installer.tar.gz"
}

@test "R7: a tag not in the format vX.Y.Z: code 2" {
  run bash "$ARCHIVE" main "$BATS_TEST_TMPDIR/dist"
  [ "$status" -eq 2 ]
}

@test "R7: the version of an unpacked archive comes from RELEASE, even inside another working copy" {
  setup_stubs
  load_script
  unset INFRA_TAG INFRA_COMMIT
  # The outer working copy has a tag of its own on its HEAD.
  outer=$BATS_TEST_TMPDIR/outer
  git init -q "$outer"
  git -C "$outer" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m outer
  git -C "$outer" tag v0.0.1
  ROOT=$outer/installer
  mkdir -p "$ROOT"
  printf 'TAG=v1.2.3\nCOMMIT=abc1234\n' >"$ROOT/RELEASE"
  [ "$(installer_version)" = v1.2.3 ]
  kc() { echo "kubectl $*" >>"$CALLS"; }
  apply_stdin() { :; }
  pinned_versions() { echo '{}'; }
  write_version
  called 'tag=v1.2.3'
  called 'commit=abc1234'
  # INFRA_TAG of the production rollout wins.
  INFRA_TAG=v2.0.0
  [ "$(installer_version)" = v2.0.0 ]
}

@test "R7: a RELEASE left in a working copy is ignored: git tells the version" {
  setup_stubs
  load_script
  unset INFRA_TAG INFRA_COMMIT
  ROOT=$BATS_TEST_TMPDIR/clone
  git init -q "$ROOT"
  git -C "$ROOT" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m clone
  git -C "$ROOT" tag v3.0.0
  printf 'TAG=v1.2.3\n' >"$ROOT/RELEASE"
  [ "$(installer_version)" = v3.0.0 ]
}
