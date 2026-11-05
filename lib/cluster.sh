# shellcheck shell=bash
# The minikube cluster (R3, R16): profile, docker driver, resources from the configuration.

profile_exists() {
  [[ -f "${MINIKUBE_HOME:-$HOME/.minikube}/profiles/$MK_PROFILE/config.json" ]]
}

# mk <arguments…> — minikube; if the docker group does not apply to this session yet
# (a first install), the command runs through `sg docker`.
mk() {
  if docker_ok; then
    minikube "$@"
  else
    local cmd
    printf -v cmd '%q ' minikube "$@"
    sg docker -c "$cmd"
  fi
}

cluster_running() {
  local host apiserver
  host=$(mk status -p "$MK_PROFILE" -f '{{.Host}}' 2>/dev/null || true)
  apiserver=$(mk status -p "$MK_PROFILE" -f '{{.APIServer}}' 2>/dev/null || true)
  [[ $host == Running && $apiserver == Running ]]
}

cluster_k8s_version() {
  kc version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || true
}

cluster_up() {
  step cluster
  if cluster_running && [[ $(cluster_k8s_version) == "$K8S_VERSION" ]]; then
    ok "cluster $MK_PROFILE is already running (Kubernetes $K8S_VERSION)"
  else
    if profile_exists; then
      log "starting profile $MK_PROFILE (Kubernetes $K8S_VERSION)"
    else
      log "creating profile $MK_PROFILE: $MK_CPUS CPU, $MK_MEMORY, disk $MK_DISK, Kubernetes $K8S_VERSION"
    fi
    mk start -p "$MK_PROFILE" --driver=docker \
      --kubernetes-version="$K8S_VERSION" \
      --cpus="$MK_CPUS" --memory="$MK_MEMORY" --disk-size="$MK_DISK" \
      --addons=default-storageclass,storage-provisioner \
      --interactive=false >"$RUN_DIR/minikube-start.log" 2>&1 ||
      die "$E_CLUSTER" "minikube start failed, see $RUN_DIR/minikube-start.log"
    ok "cluster started"
  fi
  kc wait --for=condition=Ready node --all --timeout=5m >/dev/null ||
    die "$E_CLUSTER" "the cluster node is not ready"
  kubelet_gc
  ensure_namespace "$NS_STORAGES"
  if observability_enabled; then ensure_namespace "$NS_OBSERVABILITY"; fi
  if [[ ${STAND_AUTOSTART:-true} == true ]]; then
    install_autostart
  else
    remove_autostart
  fi
}

# kubelet_gc — image garbage collection in the kubelet of the node (bin/stand-autostart kubelet-gc):
# minikube turns it off, and old images pile up on disk (FTR.NAB.CMN-0008).
# A failure is only a warning: the stand works while the disk lasts.
kubelet_gc() {
  local cmd
  # through bash: bin/stand-autostart has no executable bit in a release, and
  # install -m 755 sets it in the system (install_autostart)
  printf -v cmd '%q ' env MK_PROFILE="$MK_PROFILE" IMAGE_GC_HIGH="$IMAGE_GC_HIGH" \
    IMAGE_GC_LOW="$IMAGE_GC_LOW" IMAGE_GC_MAX_AGE="$IMAGE_GC_MAX_AGE" \
    bash "$ROOT/bin/stand-autostart" kubelet-gc
  if { if docker_ok; then eval "$cmd"; else sg docker -c "$cmd"; fi; } 2>"$RUN_DIR/kubelet-gc.log"; then
    ok "image garbage collection: disk ${IMAGE_GC_HIGH}%, unused images older than $IMAGE_GC_MAX_AGE"
  else
    warn "image garbage collection is not configured, see $RUN_DIR/kubelet-gc.log"
  fi
}

AUTOSTART_BIN=${AUTOSTART_BIN:-/usr/local/lib/installer/stand-autostart}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}

# install_autostart — the systemd unit <prefix>-stand: after a reboot the cluster and
# components come back on their own, and on shutdown the cluster stops
# cleanly. The unit runs as the user who ran up.
install_autostart() {
  local user group path unit=$UNIT_PREFIX-stand
  user=$(id -un) group=$(id -gn)
  # PATH of the unit: the directories where up found minikube and kubectl.
  path="$(dirname "$(command -v minikube)"):$(dirname "$(command -v kubectl)"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  as_root install -d -m 755 "$(dirname "$AUTOSTART_BIN")"
  as_root install -m 755 "$ROOT/bin/stand-autostart" "$AUTOSTART_BIN"
  as_root tee "$UNIT_DIR/$unit.service" >/dev/null <<EOF
# The minikube cluster of the stand on machine boot and shutdown
# (FTR.HMR.INFRA-0001). Installed by installer up; STAND_AUTOSTART=false skips it.
[Unit]
Description=GreenOnGrey: minikube cluster of the stand
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$user
Group=$group
Environment=HOME=$HOME
Environment=PATH=$path
Environment=MK_PROFILE=$MK_PROFILE
Environment=IMAGE_GC_HIGH=$IMAGE_GC_HIGH
Environment=IMAGE_GC_LOW=$IMAGE_GC_LOW
Environment=IMAGE_GC_MAX_AGE=$IMAGE_GC_MAX_AGE
${MINIKUBE_HOME:+Environment=MINIKUBE_HOME=$MINIKUBE_HOME}
ExecStart=$AUTOSTART_BIN start
ExecStop=$AUTOSTART_BIN stop
TimeoutStartSec=30min
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
EOF
  as_root systemctl daemon-reload
  as_root systemctl enable "$unit.service" >/dev/null 2>&1 ||
    die "$E_CLUSTER" "failed to enable autostart of the stand (systemctl enable $unit)"
  # start: the cluster is already running, so the unit only becomes active, and a
  # machine shutdown then stops it cleanly.
  as_root systemctl start "$unit.service" ||
    die "$E_CLUSTER" "the autostart unit did not start, see journalctl -u $unit"
  ok "autostart after a machine reboot: $unit.service"
}

# remove_autostart — removes the unit (down or STAND_AUTOSTART=false); the cluster stays:
# the unit is stopped (ExecStop: minikube stop) only when the profile is already gone.
remove_autostart() {
  local unit=$UNIT_PREFIX-stand now=()
  [[ -f $UNIT_DIR/$unit.service ]] || return 0
  profile_exists || now=(--now)
  as_root systemctl disable "${now[@]}" "$unit.service" >/dev/null 2>&1 || true
  as_root rm -f "$UNIT_DIR/$unit.service" "$AUTOSTART_BIN"
  as_root systemctl daemon-reload
  log "autostart of the stand is disabled"
}

# check_single_profile — a second cluster next to the first is not created (FTR.INFRA.INST-0001 R28).
check_single_profile() {
  profile_exists && return 0
  local f others=()
  for f in "${MINIKUBE_HOME:-$HOME/.minikube}"/profiles/*/config.json; do
    [[ -f $f ]] && others+=("$(basename "$(dirname "$f")")")
  done
  ((${#others[@]} == 0)) ||
    die "$E_USAGE" "minikube already has the profile ${others[*]}, while MK_PROFILE=$MK_PROFILE. To keep that stand, set MK_PROFILE, UNIT_PREFIX and CERT_NAME to its names in the config; otherwise delete the profile"
}

ensure_namespace() {
  kc create namespace "$1" --dry-run=client -o yaml | apply_stdin
}

cluster_delete() {
  mk delete -p "$MK_PROFILE"
}
