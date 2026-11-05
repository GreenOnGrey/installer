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
  called "kubectl --context hammurapi wait pods --all-namespaces --for=condition=Ready --selector=!job-name --field-selector=status.phase!=Succeeded,status.phase!=Failed"
  called "minikube ssh -p hammurapi -- sudo sh -c"
  called "kubelet-gc 85 80 336h"
  [[ $output == *"all pods are ready"* ]]
}

@test "AUTO-02: кластер уже запущен (включение юнита в up) — ничего не делает и не ждёт подов" {
  mk_state Running/Running
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  not_called "minikube start"
  not_called "kubectl"
  [[ $output == *"already running"* ]]
}

@test "AUTO-03: поды не готовы — юнит не проваливается, неготовые в журнале" {
  mk_state Stopped/Stopped
  stub kubectl 'case "$*" in
    *"wait pods"*) exit 1 ;;
    *"get pods"*) printf "storages hammurapi-pg-1 0/1 CrashLoopBackOff 3\nobservability grafana-0 1/1 Running 0\n" ;;
  esac'
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  [[ $output == *"not all pods are ready"* && $output == *"storages/hammurapi-pg-1 0/1 CrashLoopBackOff"* ]]
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
  [[ $output == *"Docker has not answered"* ]]
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
  grep -qx "Environment=IMAGE_GC_HIGH=85" "$u"
  grep -qx "Environment=IMAGE_GC_LOW=80" "$u"
  grep -qx "Environment=IMAGE_GC_MAX_AGE=336h" "$u"
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
  STAND_AUTOSTART=maybe run bash "$BATS_TEST_DIRNAME/../../installer" up --no-color
  [ "$status" -eq 2 ]
  [[ $output == *"STAND_AUTOSTART"* ]]
}

@test "AUTO-10: kubelet-gc — правит конфигурацию kubelet в ноде, при изменении сообщает о перезапуске" {
  stub minikube 'echo changed'
  IMAGE_GC_MAX_AGE=168h run bash "$AUTOSTART" kubelet-gc
  [ "$status" -eq 0 ]
  called "minikube ssh -p hammurapi -- sudo sh -c"
  called "kubelet-gc 85 80 168h"
  [[ $output == *"kubelet restarted"* ]]
  stub minikube 'echo unchanged'
  run bash "$AUTOSTART" kubelet-gc
  [ "$status" -eq 0 ]
  [[ $output != *"перезапущен"* ]]
}

@test "AUTO-11: kubelet-gc не удался — код 1; при автозапуске юнит не проваливается" {
  stub minikube 'case "$*" in ssh*) echo "ssh: connection refused"; exit 1 ;; esac'
  run bash "$AUTOSTART" kubelet-gc
  [ "$status" -eq 1 ]
  [[ $output == *"failed"*"connection refused"* ]]
  stub minikube 'case "$*" in status*) echo Stopped/Stopped ;; ssh*) exit 1 ;; esac'
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  [[ $output == *"all pods are ready"* ]]
}

@test "AUTO-12: скрипт kubelet-gc в ноде — выставляет ключи, второй запуск ничего не меняет" {
  local node=$BATS_TEST_TMPDIR/node
  mkdir -p "$node"
  printf 'kind: KubeletConfiguration\nimageGCHighThresholdPercent: 100\nimageMaximumGCAge: 0s\n' >"$node/config.yaml"
  # «Нода» — локальный sh: путь к файлу подменяется, systemctl — заглушка.
  # minikube ssh -p P -- sudo sh -c <скрипт в %q> kubelet-gc <значения>: так его разберёт shell ноды.
  stub minikube 'shift 7; script=$(eval "printf %s $1"); script=${script//\/var\/lib\/kubelet\/config.yaml/'"$node"'/config.yaml}; sh -c "$script" "${@:2}"'
  run bash "$AUTOSTART" kubelet-gc
  [ "$status" -eq 0 ]
  grep -qx 'imageGCHighThresholdPercent: 85' "$node/config.yaml"
  grep -qx 'imageGCLowThresholdPercent: 80' "$node/config.yaml"
  grep -qx 'imageMaximumGCAge: 336h' "$node/config.yaml"
  grep -qx 'kind: KubeletConfiguration' "$node/config.yaml"
  called "^systemctl restart kubelet"
  : >"$CALLS"
  run bash "$AUTOSTART" kubelet-gc
  [ "$status" -eq 0 ]
  not_called "^systemctl"
}

@test "AUTO-13: up настраивает сборку мусора и без бита исполнения у bin/stand-autostart, как в релизе" {
  load_script
  local release=$BATS_TEST_TMPDIR/release
  mkdir -p "$release/bin"
  install -m 644 "$ROOT/bin/stand-autostart" "$release/bin/stand-autostart"
  ROOT=$release
  MK_PROFILE=hammurapi
  stub minikube 'case "$*" in ssh*) echo changed ;; esac'
  run kubelet_gc
  [ "$status" -eq 0 ]
  called "minikube ssh -p hammurapi -- sudo sh -c"
  [[ $output == *"image garbage collection: disk 85"* ]]
}
