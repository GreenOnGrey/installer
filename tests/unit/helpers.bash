# shellcheck shell=bash disable=SC2016
# Shared functions of bats tests: stubbing external commands and sourcing the script.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

# setup_stubs — a stub directory ahead in PATH; calls are written to $CALLS.
setup_stubs() {
  STUBS=$BATS_TEST_TMPDIR/stubs
  CALLS=$BATS_TEST_TMPDIR/calls
  mkdir -p "$STUBS"
  : >"$CALLS"
  export PATH="$STUBS:$PATH" CALLS STUBS
  local c
  for c in sudo apt-get apt-mark docker kubectl helm minikube curl systemctl usermod gpg sg; do
    stub "$c" 'exit 0'
  done
}

# stub <command> <sh body> — a stub that records the call.
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

called() { grep -q -- "$1" "$CALLS"; }

# In bats, ! command does not fail a test, so negative checks work only this way.
not_called() {
  if grep -q -- "$1" "$CALLS"; then
    echo "unexpected call: $(grep -- "$1" "$CALLS" | head -1)"
    return 1
  fi
}

not_grep() {
  if grep "$@" >/dev/null; then
    echo "found: grep $*"
    return 1
  fi
}

# load_script — functions of installer with the default configuration.
load_script() {
  # shellcheck source=../../installer
  source "$ROOT/installer"
  COLOR=0
  setup_color
  load_config "$ROOT" /dev/null
  # Server descriptions as in the chart mcp-servers; tests do not download the chart.
  MCP_CHART_DIR=$ROOT/tests/fixtures/mcp/chart
  WORK_DIR=$BATS_TEST_TMPDIR/work
  RUN_DIR=$BATS_TEST_TMPDIR/run
  mkdir -p "$WORK_DIR" "$RUN_DIR"
  export MINIKUBE_HOME=$BATS_TEST_TMPDIR/minikube
}

os_release() {
  printf 'ID=%s\nVERSION_ID="%s"\n' "$1" "$2" >"$BATS_TEST_TMPDIR/os-release"
  OS_RELEASE_FILE=$BATS_TEST_TMPDIR/os-release
}

meminfo_gb() {
  printf 'MemTotal:       %d kB\n' $(($1 * 1024 * 1024)) >"$BATS_TEST_TMPDIR/meminfo"
  MEMINFO_FILE=$BATS_TEST_TMPDIR/meminfo
}
