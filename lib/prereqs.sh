# shellcheck shell=bash
# Установка зависимостей (R2): утилиты, Docker Engine, kubectl, Helm, minikube.
# Компонент нужной версии пропускается.

BIN_DIR=${BIN_DIR:-/usr/local/bin}
APT_UPDATED=0

apt_update_once() {
  if [[ $APT_UPDATED == 0 ]]; then
    retry 3 10 as_root apt-get update -qq || die "$E_PREREQ" "apt-get update не выполнен"
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  retry 3 10 as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --allow-downgrades "$@" >/dev/null ||
    die "$E_PREREQ" "не удалось установить: $*"
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

install_utils() {
  local missing=() p
  for p in curl ca-certificates gnupg jq openssl util-linux; do
    pkg_installed "$p" || missing+=("$p")
  done
  if ((${#missing[@]})); then
    log "утилиты: ${missing[*]}"
    apt_install "${missing[@]}"
  fi
}

# --- Docker Engine ---

docker_installed_version() {
  dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true
}

install_docker() {
  if [[ $(docker_installed_version) == "$DOCKER_VERSION" ]]; then
    debug "Docker $DOCKER_VERSION уже установлен"
  else
    log "Docker Engine $DOCKER_VERSION"
    as_root install -m 0755 -d /etc/apt/keyrings
    if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
      retry 3 10 curl -fsSL https://download.docker.com/linux/debian/gpg -o "$WORK_DIR/docker.asc" ||
        die "$E_PREREQ" "не удалось загрузить ключ репозитория Docker"
      as_root install -m 0644 "$WORK_DIR/docker.asc" /etc/apt/keyrings/docker.asc
    fi
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" |
      as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
    APT_UPDATED=0
    apt_install "docker-ce=$DOCKER_VERSION" "docker-ce-cli=$DOCKER_VERSION" "containerd.io=$CONTAINERD_VERSION"
    as_root apt-mark hold docker-ce docker-ce-cli containerd.io >/dev/null
  fi
  if ! systemctl is-enabled --quiet docker 2>/dev/null; then
    as_root systemctl enable --now docker >/dev/null
  fi
  local user=${SUDO_USER:-$(id -un)}
  if [[ $user != root ]] && ! id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
    as_root usermod -aG docker "$user"
    log "пользователь $user добавлен в группу docker"
  fi
}

# docker_ok — текущий процесс может работать с Docker без sudo.
docker_ok() { docker info >/dev/null 2>&1; }

# --- kubectl ---

kubectl_minor() {
  have kubectl || return 0
  kubectl version --client -o json 2>/dev/null | jq -r '"v" + .clientVersion.major + "." + .clientVersion.minor' 2>/dev/null || true
}

install_kubectl() {
  if [[ $(kubectl_minor) == "$KUBECTL_MINOR" ]]; then
    debug "kubectl $KUBECTL_MINOR уже установлен"
    return
  fi
  log "kubectl $KUBECTL_VERSION"
  as_root install -m 0755 -d /etc/apt/keyrings
  retry 3 10 curl -fsSL "https://pkgs.k8s.io/core:/stable:/$KUBECTL_MINOR/deb/Release.key" -o "$WORK_DIR/k8s.key" ||
    die "$E_PREREQ" "не удалось загрузить ключ репозитория Kubernetes"
  as_root gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "$WORK_DIR/k8s.key"
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBECTL_MINOR/deb/ /" |
    as_root tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  APT_UPDATED=0
  apt_install "kubectl=$KUBECTL_VERSION"
  as_root apt-mark hold kubectl >/dev/null
}

# --- Бинарники с проверкой SHA-256 ---

# verify_sha256 <файл> <ожидаемая сумма>
verify_sha256() {
  local actual
  actual=$(sha256sum "$1" | awk '{print $1}')
  [[ $actual == "$2" ]]
}

helm_installed_version() {
  have helm || return 0
  helm version --template '{{.Version}}' 2>/dev/null || true
}

install_helm() {
  if [[ $(helm_installed_version) == "$HELM_VERSION" ]]; then
    debug "Helm $HELM_VERSION уже установлен"
    return
  fi
  log "Helm $HELM_VERSION"
  local archive="$WORK_DIR/helm.tar.gz"
  retry 3 10 curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" -o "$archive" ||
    die "$E_PREREQ" "не удалось загрузить Helm $HELM_VERSION"
  verify_sha256 "$archive" "$HELM_SHA256" ||
    die "$E_PREREQ" "контрольная сумма Helm $HELM_VERSION не совпала; ничего не установлено"
  tar -xzf "$archive" -C "$WORK_DIR" linux-amd64/helm
  as_root install -m 0755 "$WORK_DIR/linux-amd64/helm" "$BIN_DIR/helm"
}

minikube_installed_version() {
  have minikube || return 0
  minikube version --short 2>/dev/null || true
}

install_minikube() {
  if [[ $(minikube_installed_version) == "$MINIKUBE_VERSION" ]]; then
    debug "minikube $MINIKUBE_VERSION уже установлен"
    return
  fi
  log "minikube $MINIKUBE_VERSION"
  local bin="$WORK_DIR/minikube"
  retry 3 10 curl -fsSL "https://github.com/kubernetes/minikube/releases/download/$MINIKUBE_VERSION/minikube-linux-amd64" -o "$bin" ||
    die "$E_PREREQ" "не удалось загрузить minikube $MINIKUBE_VERSION"
  verify_sha256 "$bin" "$MINIKUBE_SHA256" ||
    die "$E_PREREQ" "контрольная сумма minikube $MINIKUBE_VERSION не совпала; ничего не установлено"
  as_root install -m 0755 "$bin" "$BIN_DIR/minikube"
}

install_prereqs() {
  step prereqs
  install_utils
  install_docker
  install_kubectl
  install_helm
  install_minikube
  ok "Docker $(docker_installed_version), kubectl $(kubectl_minor), Helm $(helm_installed_version), minikube $(minikube_installed_version)"
}
