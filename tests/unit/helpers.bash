# shellcheck shell=bash disable=SC2016
# Общие функции bats-тестов: подмена внешних команд и подключение скрипта.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

# setup_stubs — каталог заглушек впереди PATH; вызовы пишутся в $CALLS.
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

# stub <команда> <тело sh> — заглушка, записывающая вызов.
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

called() { grep -q -- "$1" "$CALLS"; }

# В bats «! команда» не валит тест — отрицательные проверки только так.
not_called() {
  if grep -q -- "$1" "$CALLS"; then
    echo "неожиданный вызов: $(grep -- "$1" "$CALLS" | head -1)"
    return 1
  fi
}

not_grep() {
  if grep "$@" >/dev/null; then
    echo "найдено: grep $*"
    return 1
  fi
}

# load_script — функции installer с конфигурацией по умолчанию.
load_script() {
  # shellcheck source=../../installer
  source "$ROOT/installer"
  COLOR=0
  setup_color
  load_config "$ROOT" /dev/null
  # Описания серверов — как в чарте mcp-servers; чарт в тестах не скачивается.
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
