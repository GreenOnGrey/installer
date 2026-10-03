# shellcheck shell=bash
# Кластер minikube (R3, R16): профиль, драйвер docker, ресурсы из конфигурации.

profile_exists() {
  [[ -f "${MINIKUBE_HOME:-$HOME/.minikube}/profiles/$MK_PROFILE/config.json" ]]
}

# mk <аргументы…> — minikube; если группа docker ещё не применена к текущей
# сессии (первая установка), команда выполняется через `sg docker`.
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
    ok "кластер $MK_PROFILE уже запущен (Kubernetes $K8S_VERSION)"
  else
    if profile_exists; then
      log "запуск профиля $MK_PROFILE (Kubernetes $K8S_VERSION)"
    else
      log "создание профиля $MK_PROFILE: $MK_CPUS CPU, $MK_MEMORY, диск $MK_DISK, Kubernetes $K8S_VERSION"
    fi
    mk start -p "$MK_PROFILE" --driver=docker \
      --kubernetes-version="$K8S_VERSION" \
      --cpus="$MK_CPUS" --memory="$MK_MEMORY" --disk-size="$MK_DISK" \
      --addons=default-storageclass,storage-provisioner \
      --interactive=false >"$RUN_DIR/minikube-start.log" 2>&1 ||
      die "$E_CLUSTER" "minikube start не выполнен, см. $RUN_DIR/minikube-start.log"
    ok "кластер запущен"
  fi
  kc wait --for=condition=Ready node --all --timeout=5m >/dev/null ||
    die "$E_CLUSTER" "нода кластера не готова"
  ensure_namespace "$NS_STORAGES"
  ensure_namespace "$NS_OBSERVABILITY"
  if [[ ${STAND_AUTOSTART:-true} == true ]]; then
    install_autostart
  else
    remove_autostart
  fi
}

AUTOSTART_BIN=${AUTOSTART_BIN:-/usr/local/lib/hammurapi-infra/stand-autostart}
AUTOSTART_UNIT=${AUTOSTART_UNIT:-/etc/systemd/system/hammurapi-stand.service}

# install_autostart — systemd-юнит hammurapi-stand: после перезагрузки машины
# кластер и компоненты стенда поднимаются сами, при выключении кластер
# останавливается штатно. Юнит работает от пользователя, запустившего up.
install_autostart() {
  local user group path
  user=$(id -un) group=$(id -gn)
  # PATH юнита: каталоги minikube и kubectl, где их нашёл up.
  path="$(dirname "$(command -v minikube)"):$(dirname "$(command -v kubectl)"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  as_root install -d -m 755 "$(dirname "$AUTOSTART_BIN")"
  as_root install -m 755 "$ROOT/bin/stand-autostart" "$AUTOSTART_BIN"
  as_root tee "$AUTOSTART_UNIT" >/dev/null <<EOF
# Кластер minikube стенда Hammurapi при загрузке и выключении машины
# (FTR.HMR.INFRA-0001). Устанавливает hammurapi-infra.sh up; STAND_AUTOSTART=false — не ставить.
[Unit]
Description=Hammurapi: кластер minikube стенда
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
${MINIKUBE_HOME:+Environment=MINIKUBE_HOME=$MINIKUBE_HOME}
ExecStart=$AUTOSTART_BIN start
ExecStop=$AUTOSTART_BIN stop
TimeoutStartSec=30min
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
EOF
  as_root systemctl daemon-reload
  as_root systemctl enable hammurapi-stand.service >/dev/null 2>&1 ||
    die "$E_CLUSTER" "не удалось включить автозапуск стенда (systemctl enable hammurapi-stand)"
  # start: кластер уже запущен — юнит только становится активным, и при выключении
  # машины сработает штатная остановка.
  as_root systemctl start hammurapi-stand.service ||
    die "$E_CLUSTER" "юнит автозапуска не запустился, см. journalctl -u hammurapi-stand"
  ok "автозапуск после перезагрузки машины: hammurapi-stand.service"
}

# remove_autostart — снимает юнит (down или STAND_AUTOSTART=false); кластер не трогает:
# остановка юнита (ExecStop — minikube stop) — только когда профиля уже нет.
remove_autostart() {
  [[ -f $AUTOSTART_UNIT ]] || return 0
  local now=()
  profile_exists || now=(--now)
  as_root systemctl disable "${now[@]}" hammurapi-stand.service >/dev/null 2>&1 || true
  as_root rm -f "$AUTOSTART_UNIT" "$AUTOSTART_BIN"
  as_root systemctl daemon-reload
  log "автозапуск стенда отключён"
}

ensure_namespace() {
  kc create namespace "$1" --dry-run=client -o yaml | apply_stdin
}

cluster_delete() {
  mk delete -p "$MK_PROFILE"
}
