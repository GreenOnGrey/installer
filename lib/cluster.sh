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

# cluster_reachable — the cluster of the configured target answers.
cluster_reachable() {
  if target_external; then kc version >/dev/null 2>&1; else have minikube && cluster_running; fi
}

# cluster_label — the cluster in messages.
cluster_label() {
  if target_external; then echo "context $KUBE_CONTEXT"; else echo "minikube $MK_PROFILE"; fi
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
  # Before the node is awaited: its network plugin is pulled from Docker Hub too.
  registry_mirrors
  kc wait --for=condition=Ready node --all --timeout=5m >/dev/null || die "$E_CLUSTER" "$(node_not_ready)"
  kubelet_gc
  ensure_stand_namespaces
  if [[ ${STAND_AUTOSTART:-true} == true ]]; then
    install_autostart
  else
    remove_autostart
  fi
}

# autostart_mode <mode> — a mode of bin/stand-autostart with the settings of this run, through the group docker
# when this session is not in it yet. Through bash: bin/stand-autostart has no executable bit in a release, and
# install -m 755 sets it in the system (install_autostart).
autostart_mode() {
  local cmd
  printf -v cmd '%q ' env MK_PROFILE="$MK_PROFILE" IMAGE_GC_HIGH="$IMAGE_GC_HIGH" \
    IMAGE_GC_LOW="$IMAGE_GC_LOW" IMAGE_GC_MAX_AGE="$IMAGE_GC_MAX_AGE" REGISTRY_MIRRORS="${REGISTRY_MIRRORS:-}" \
    bash "$ROOT/bin/stand-autostart" "$1"
  if docker_ok; then eval "$cmd"; else sg docker -c "$cmd"; fi
}

# kubelet_gc — image garbage collection in the kubelet of the node (bin/stand-autostart kubelet-gc):
# minikube turns it off, and old images pile up on disk (FTR.NAB.CMN-0008).
# A failure is only a warning: the stand works while the disk lasts.
kubelet_gc() {
  if autostart_mode kubelet-gc 2>"$RUN_DIR/kubelet-gc.log"; then
    ok "image garbage collection: disk ${IMAGE_GC_HIGH}%, unused images older than $IMAGE_GC_MAX_AGE"
  else
    warn "image garbage collection is not configured, see $RUN_DIR/kubelet-gc.log"
  fi
}

DOCKER_DAEMON_FILE=${DOCKER_DAEMON_FILE:-/etc/docker/daemon.json}

# docker_no_nat — Docker runs without its network plumbing (--iptables=False, --ip-forward=False or
# --ip-masq=False in the unit or daemon.json). Then the node of minikube gets no NAT and reaches no registry,
# whatever sysctl says: a hardened image does this, and the installer does not change the Docker of the machine.
docker_no_nat() {
  local flags
  flags=$(systemctl show docker -p ExecStart 2>/dev/null || true)
  [[ ! -r $DOCKER_DAEMON_FILE ]] || flags+=$'\n'"$(<"$DOCKER_DAEMON_FILE")"
  grep -Eqi -- '--iptables[= ]+false|--ip-forward[= ]+false|--ip-masq[= ]+false' <<<"$flags" && return 0
  grep -Eqi '"iptables"[[:space:]]*:[[:space:]]*false|"ip-forward"[[:space:]]*:[[:space:]]*false|"ip-masq"[[:space:]]*:[[:space:]]*false' <<<"$flags"
}

# node_not_ready — why the node is not ready: the message of its condition Ready and the first failed pull of an
# image, with what usually stands behind them on a machine of a closed network.
node_not_ready() {
  local why pull msg="the cluster node is not ready"
  why=$(kc get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
  [[ -z $why ]] || msg+=": $why"
  pull=$(kc get events -A --field-selector reason=Failed -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null |
    grep -m1 'Failed to pull image' || true)
  if [[ -n $pull ]]; then
    msg+="; $pull."
    # A wrong tag or a missing login is not a network fault: the advice would send the reader the wrong way.
    if [[ $pull =~ (i/o timeout|connection refused|no such host|TLS handshake timeout|network is unreachable|dial tcp) ]]; then
      if docker_no_nat; then
        msg+=" Containers of the machine do not reach the registry: Docker runs with iptables, ip-forward or ip-masq"
        msg+=" off (--iptables=False/--ip-forward=False/--ip-masq=False), so the node has no NAT; enable the defaults"
        msg+=" of Docker or add a MASQUERADE rule for the subnet of the node"
      else
        msg+=" Containers of the machine do not reach the registry: check IP forwarding and NAT of Docker"
        msg+=" (sysctl net.ipv4.ip_forward, iptables -t nat -S POSTROUTING), or set REGISTRY_MIRRORS to a mirror of your network"
      fi
    fi
  fi
  echo "$msg"
}

# registry_mirrors — the mirrors of REGISTRY_MIRRORS in the node's containerd, and pods of controllers stuck pulling
# an image start over (bin/stand-autostart registry-mirrors, FTR.INFRA.INST-0001 R32). With mirrors a failure stops
# the run, since images would not come; without them it is a warning.
registry_mirrors() {
  if autostart_mode registry-mirrors 2>"$RUN_DIR/registry-mirrors.log"; then
    [[ -z ${REGISTRY_MIRRORS:-} ]] || ok "registry mirrors: $REGISTRY_MIRRORS"
    return 0
  fi
  [[ -z ${REGISTRY_MIRRORS:-} ]] || die "$E_CLUSTER" "registry mirrors are not configured, see $RUN_DIR/registry-mirrors.log"
  warn "the registry mirrors of an earlier run are not removed, see $RUN_DIR/registry-mirrors.log"
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
Environment="REGISTRY_MIRRORS=${REGISTRY_MIRRORS:-}"
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

ensure_stand_namespaces() {
  local ns
  for ns in $(stand_namespaces); do ensure_namespace "$ns"; done
}

# ensure_namespace <name> — a new namespace gets the label by which uninstall finds it; an existing one
# stays as it is, as it may hold what the installer did not create.
ensure_namespace() {
  local out
  out=$(kc get namespace "$1" --ignore-not-found -o name) || die "$E_CLUSTER" "failed to read namespace $1"
  [[ -z $out ]] || return 0
  kc create namespace "$1" --dry-run=client -o json |
    jq '.metadata.labels["app.kubernetes.io/part-of"] = "installer"' | apply_stdin
}

cluster_delete() {
  mk delete -p "$MK_PROFILE"
}
