# shellcheck shell=bash
# Installs dependencies (R2): utilities, Docker Engine, kubectl, Helm, minikube.
# A component of the right version is skipped.

BIN_DIR=${BIN_DIR:-/usr/local/bin}
APT_UPDATED=0

apt_update_once() {
  if [[ $APT_UPDATED == 0 ]]; then
    retry 3 10 as_root apt-get update -qq || die "$E_PREREQ" "apt-get update failed"
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  retry 3 10 as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --allow-downgrades "$@" >/dev/null ||
    die "$E_PREREQ" "failed to install: $*"
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

install_utils() {
  local missing=() p
  for p in curl ca-certificates gnupg jq openssl util-linux; do
    pkg_installed "$p" || missing+=("$p")
  done
  if ((${#missing[@]})); then
    log "utilities: ${missing[*]}"
    apt_install "${missing[@]}"
  fi
}

# --- Docker Engine ---

docker_installed_version() {
  dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true
}

install_docker() {
  if [[ $(docker_installed_version) == "$DOCKER_VERSION" ]]; then
    debug "Docker $DOCKER_VERSION is already installed"
  else
    log "Docker Engine $DOCKER_VERSION"
    as_root install -m 0755 -d /etc/apt/keyrings
    if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
      retry 3 10 curl -fsSL https://download.docker.com/linux/debian/gpg -o "$WORK_DIR/docker.asc" ||
        die "$E_PREREQ" "failed to download the Docker repository key"
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
    log "user $user added to the docker group"
  fi
}

# docker_ok — this process can use Docker without sudo.
docker_ok() { docker info >/dev/null 2>&1; }

# --- kubectl ---

kubectl_minor() {
  have kubectl || return 0
  kubectl version --client -o json 2>/dev/null | jq -r '"v" + .clientVersion.major + "." + .clientVersion.minor' 2>/dev/null || true
}

install_kubectl() {
  if [[ $(kubectl_minor) == "$KUBECTL_MINOR" ]]; then
    debug "kubectl $KUBECTL_MINOR is already installed"
    return
  fi
  log "kubectl $KUBECTL_VERSION"
  as_root install -m 0755 -d /etc/apt/keyrings
  retry 3 10 curl -fsSL "https://pkgs.k8s.io/core:/stable:/$KUBECTL_MINOR/deb/Release.key" -o "$WORK_DIR/k8s.key" ||
    die "$E_PREREQ" "failed to download the Kubernetes repository key"
  as_root gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "$WORK_DIR/k8s.key"
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBECTL_MINOR/deb/ /" |
    as_root tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  APT_UPDATED=0
  apt_install "kubectl=$KUBECTL_VERSION"
  as_root apt-mark hold kubectl >/dev/null
}

# --- Binaries verified by SHA-256 ---

# verify_sha256 <file> <expected sum>
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
    debug "Helm $HELM_VERSION is already installed"
    return
  fi
  log "Helm $HELM_VERSION"
  local archive="$WORK_DIR/helm.tar.gz"
  retry 3 10 curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" -o "$archive" ||
    die "$E_PREREQ" "failed to download Helm $HELM_VERSION"
  verify_sha256 "$archive" "$HELM_SHA256" ||
    die "$E_PREREQ" "checksum of Helm $HELM_VERSION does not match; nothing was installed"
  tar -xzf "$archive" -C "$WORK_DIR" linux-amd64/helm
  as_root install -m 0755 "$WORK_DIR/linux-amd64/helm" "$BIN_DIR/helm"
}

minikube_installed_version() {
  have minikube || return 0
  minikube version --short 2>/dev/null || true
}

install_minikube() {
  if [[ $(minikube_installed_version) == "$MINIKUBE_VERSION" ]]; then
    debug "minikube $MINIKUBE_VERSION is already installed"
    return
  fi
  log "minikube $MINIKUBE_VERSION"
  local bin="$WORK_DIR/minikube"
  retry 3 10 curl -fsSL "https://github.com/kubernetes/minikube/releases/download/$MINIKUBE_VERSION/minikube-linux-amd64" -o "$bin" ||
    die "$E_PREREQ" "failed to download minikube $MINIKUBE_VERSION"
  verify_sha256 "$bin" "$MINIKUBE_SHA256" ||
    die "$E_PREREQ" "checksum of minikube $MINIKUBE_VERSION does not match; nothing was installed"
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
