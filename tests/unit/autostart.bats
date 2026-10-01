#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# AUTO: кластер и компоненты стенда поднимаются после перезагрузки машины.

load helpers

AUTOSTART="$BATS_TEST_DIRNAME/../../bin/stand-autostart"

setup() {
  setup_stubs
  export HOME=$BATS_TEST_TMPDIR/home MK_PROFILE=hammurapi DOCKER_WAIT=2
  unset MINIKUBE_HOME
  mkdir -p "$HOME/.minikube/profiles/hammurapi"
  echo '{}' >"$HOME/.minikube/profiles/hammurapi/config.json"
  stub kubectl 'exit 0'
}

# mk_state <Host/APIServer> — что отвечает minikube status.
mk_state() {
  stub minikube "case \"\$*\" in status*) echo '$1' ;; esac"
}

@test "AUTO-01: после перезагрузки — minikube start, ожидание ноды и подов" {
  mk_state Stopped/Stopped
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  called "minikube start -p hammurapi --interactive=false"
  called "kubectl --context hammurapi wait --for=condition=Ready node --all"
  called "kubectl --context hammurapi wait pods --all-namespaces --for=condition=Ready --field-selector=status.phase!=Succeeded,status.phase!=Failed"
  [[ $output == *"все поды готовы"* ]]
}

@test "AUTO-02: кластер уже запущен (включение юнита в up) — ничего не делает и не ждёт подов" {
  mk_state Running/Running
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  not_called "minikube start"
  not_called "kubectl"
  [[ $output == *"уже запущен"* ]]
}

@test "AUTO-03: поды не готовы — юнит не проваливается, неготовые в журнале" {
  mk_state Stopped/Stopped
  stub kubectl 'case "$*" in
    *"wait pods"*) exit 1 ;;
    *"get pods"*) printf "storages hammurapi-pg-1 0/1 CrashLoopBackOff 3\nobservability grafana-0 1/1 Running 0\n" ;;
  esac'
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  [[ $output == *"не все поды готовы"* && $output == *"storages/hammurapi-pg-1 0/1 CrashLoopBackOff"* ]]
  [[ $output != *"grafana-0"* ]]
}

@test "AUTO-04: профиля нет (после down) — start и stop ничего не делают" {
  rm -rf "$HOME/.minikube"
  mk_state Stopped/Stopped
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  run bash "$AUTOSTART" stop
  [ "$status" -eq 0 ]
  not_called "minikube"
}

@test "AUTO-05: выключение машины — minikube stop; остановленный кластер не трогается" {
  mk_state Running/Running
  run bash "$AUTOSTART" stop
  [ "$status" -eq 0 ]
  called "minikube stop -p hammurapi"
  : >"$CALLS"
  mk_state Stopped/Stopped
  run bash "$AUTOSTART" stop
  [ "$status" -eq 0 ]
  not_called "minikube stop"
}

@test "AUTO-06: Docker не отвечает — ошибка, кластер не запускается" {
  stub docker 'exit 1'
  mk_state Stopped/Stopped
  run bash "$AUTOSTART" start
  [ "$status" -eq 1 ]
  [[ $output == *"Docker не отвечает"* ]]
  not_called "minikube start"
}

@test "AUTO-07: up ставит юнит от своего пользователя, включает и запускает его" {
  load_script
  as_root() { "$@"; }
  stub minikube 'exit 0'
  AUTOSTART_UNIT=$BATS_TEST_TMPDIR/hammurapi-stand.service
  AUTOSTART_BIN=$BATS_TEST_TMPDIR/lib/stand-autostart
  run install_autostart
  [ "$status" -eq 0 ]
  [ -x "$AUTOSTART_BIN" ]
  local u=$AUTOSTART_UNIT
  grep -qx "User=$(id -un)" "$u"
  grep -qx 'Requires=docker.service' "$u"
  grep -q '^After=docker.service' "$u"
  grep -qx "ExecStart=$AUTOSTART_BIN start" "$u"
  grep -qx "ExecStop=$AUTOSTART_BIN stop" "$u"
  grep -qx 'WantedBy=multi-user.target' "$u"
  grep -qx "Environment=HOME=$HOME" "$u"
  grep -q "^Environment=PATH=$STUBS:" "$u"
  called "systemctl enable hammurapi-stand.service"
  called "systemctl start hammurapi-stand.service"
}

@test "AUTO-08: STAND_AUTOSTART=false — юнит снимается, кластер не останавливается" {
  load_script
  as_root() { "$@"; }
  AUTOSTART_UNIT=$BATS_TEST_TMPDIR/hammurapi-stand.service
  AUTOSTART_BIN=$BATS_TEST_TMPDIR/stand-autostart
  : >"$AUTOSTART_UNIT"
  : >"$AUTOSTART_BIN"
  export MINIKUBE_HOME=$HOME/.minikube
  run remove_autostart
  [ "$status" -eq 0 ]
  [ ! -e "$AUTOSTART_UNIT" ] && [ ! -e "$AUTOSTART_BIN" ]
  called "systemctl disable hammurapi-stand.service"
  not_called "disable --now"
}

@test "AUTO-09: недопустимое STAND_AUTOSTART — код 2" {
  STAND_AUTOSTART=maybe run bash "$BATS_TEST_DIRNAME/../../hammurapi-infra.sh" up --no-color
  [ "$status" -eq 2 ]
  [[ $output == *"STAND_AUTOSTART"* ]]
}
