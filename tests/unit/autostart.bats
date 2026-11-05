#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# AUTO: the cluster and components come back after a machine reboot.

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

# mk_state <Host/APIServer> — what minikube status answers.
mk_state() {
  stub minikube "case \"\$*\" in status*) echo '$1' ;; esac"
}

@test "AUTO-01: after a reboot, minikube start and waiting for the node and pods" {
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

@test "AUTO-02: the cluster already runs (up enables the unit): does nothing, does not wait for pods" {
  mk_state Running/Running
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  not_called "minikube start"
  not_called "kubectl"
  [[ $output == *"already running"* ]]
}

@test "AUTO-03: pods are not ready: the unit does not fail, unready ones are in the log" {
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

@test "AUTO-04: no profile (after down): start and stop do nothing" {
  rm -rf "$HOME/.minikube"
  mk_state Stopped/Stopped
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  run bash "$AUTOSTART" stop
  [ "$status" -eq 0 ]
  not_called "minikube"
}

@test "AUTO-05: machine shutdown: minikube stop; a stopped cluster is left alone" {
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

@test "AUTO-06: Docker does not answer: an error, the cluster does not start" {
  stub docker 'exit 1'
  mk_state Stopped/Stopped
  run bash "$AUTOSTART" start
  [ "$status" -eq 1 ]
  [[ $output == *"Docker has not answered"* ]]
  not_called "minikube start"
}

@test "AUTO-07: up installs the unit as its user, enables and starts it" {
  load_script
  as_root() { "$@"; }
  stub minikube 'exit 0'
  UNIT_DIR=$BATS_TEST_TMPDIR
  AUTOSTART_BIN=$BATS_TEST_TMPDIR/lib/stand-autostart
  run install_autostart
  [ "$status" -eq 0 ]
  [ -x "$AUTOSTART_BIN" ]
  local u=$UNIT_DIR/greenongrey-stand.service
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
  called "systemctl enable greenongrey-stand.service"
  called "systemctl start greenongrey-stand.service"
}

@test "FTR.INFRA.INST-0001 R28: UNIT_PREFIX names the unit, the name pinned on prod stays" {
  load_script
  as_root() { "$@"; }
  stub minikube 'exit 0'
  UNIT_DIR=$BATS_TEST_TMPDIR
  AUTOSTART_BIN=$BATS_TEST_TMPDIR/lib/stand-autostart
  UNIT_PREFIX=hammurapi run install_autostart
  [ "$status" -eq 0 ]
  [ -f "$UNIT_DIR/hammurapi-stand.service" ]
  called "systemctl start hammurapi-stand.service"
}

@test "AUTO-08: STAND_AUTOSTART=false: the unit is removed, the cluster does not stop" {
  load_script
  as_root() { "$@"; }
  UNIT_DIR=$BATS_TEST_TMPDIR
  AUTOSTART_BIN=$BATS_TEST_TMPDIR/stand-autostart
  local unit=$UNIT_DIR/greenongrey-stand.service
  : >"$unit"
  : >"$AUTOSTART_BIN"
  export MINIKUBE_HOME=$HOME/.minikube
  run remove_autostart
  [ "$status" -eq 0 ]
  [ ! -e "$unit" ] && [ ! -e "$AUTOSTART_BIN" ]
  called "systemctl disable greenongrey-stand.service"
  not_called "disable --now"
}

@test "AUTO-09: an invalid STAND_AUTOSTART: code 2" {
  STAND_AUTOSTART=maybe run bash "$BATS_TEST_DIRNAME/../../installer" up --no-color
  [ "$status" -eq 2 ]
  [[ $output == *"STAND_AUTOSTART"* ]]
}

@test "AUTO-10: kubelet-gc edits the kubelet configuration in the node and reports a restart on a change" {
  stub minikube 'echo changed'
  IMAGE_GC_MAX_AGE=168h run bash "$AUTOSTART" kubelet-gc
  [ "$status" -eq 0 ]
  called "minikube ssh -p hammurapi -- sudo sh -c"
  called "kubelet-gc 85 80 168h"
  [[ $output == *"kubelet restarted"* ]]
  stub minikube 'echo unchanged'
  run bash "$AUTOSTART" kubelet-gc
  [ "$status" -eq 0 ]
  [[ $output != *"restarted"* ]]
}

@test "AUTO-11: kubelet-gc failed: code 1; on autostart the unit does not fail" {
  stub minikube 'case "$*" in ssh*) echo "ssh: connection refused"; exit 1 ;; esac'
  run bash "$AUTOSTART" kubelet-gc
  [ "$status" -eq 1 ]
  [[ $output == *"failed"*"connection refused"* ]]
  stub minikube 'case "$*" in status*) echo Stopped/Stopped ;; ssh*) exit 1 ;; esac'
  run bash "$AUTOSTART" start
  [ "$status" -eq 0 ]
  [[ $output == *"all pods are ready"* ]]
}

@test "AUTO-12: the kubelet-gc script in the node sets the keys, a second run changes nothing" {
  local node=$BATS_TEST_TMPDIR/node
  mkdir -p "$node"
  printf 'kind: KubeletConfiguration\nimageGCHighThresholdPercent: 100\nimageMaximumGCAge: 0s\n' >"$node/config.yaml"
  # The node is a local sh: the file path is replaced, systemctl is a stub.
  # minikube ssh -p P -- sudo sh -c <script in %q> kubelet-gc <values>: this is how the node's shell parses it.
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

@test "AUTO-13: up configures garbage collection even without the executable bit of bin/stand-autostart, as in a release" {
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
