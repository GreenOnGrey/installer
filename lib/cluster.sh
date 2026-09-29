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
}

ensure_namespace() {
  kc create namespace "$1" --dry-run=client -o yaml | apply_stdin
}

cluster_delete() {
  mk delete -p "$MK_PROFILE"
}
