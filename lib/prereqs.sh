# shellcheck shell=bash
# Installs dependencies (R2, FTR.INFRA.INST-0001 R9): utilities, Docker Engine, kubectl, Helm, minikube.
# A component of the right version is skipped. apt waits for the lock: on a fresh Ubuntu, unattended-upgrades holds it.

BIN_DIR=${BIN_DIR:-/usr/local/bin}
APT_UPDATED=0

apt_update_once() {
  if [[ $APT_UPDATED == 0 ]]; then
    retry 3 10 as_root apt-get -o DPkg::Lock::Timeout=300 update -qq || die "$E_PREREQ" "apt-get update failed"
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  retry 3 10 as_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq --allow-downgrades "$@" >/dev/null ||
    die "$E_PREREQ" "failed to install: $*"
}

dnf_install() {
  retry 3 10 as_root dnf install -y -q "$@" >/dev/null || die "$E_PREREQ" "failed to install: $*"
}

pkg_installed() {
  if os_is_el; then
    # whatprovides: curl of EL comes as curl-minimal, and installing curl over it is a conflict.
    rpm -q --whatprovides "$1" >/dev/null 2>&1
  else
    host_deb_installed "$1"
  fi
}

install_utils() {
  local missing=() p
  for p in curl ca-certificates jq openssl tar util-linux; do
    pkg_installed "$p" || missing+=("$p")
  done
  if ((${#missing[@]})); then
    log "utilities: ${missing[*]}"
    if os_is_el; then dnf_install "${missing[@]}"; else apt_install "${missing[@]}"; fi
  fi
}

# --- Docker Engine ---

docker_installed_version() {
  if os_is_el; then
    rpm -q --qf '%{VERSION}-%{RELEASE}' docker-ce 2>/dev/null | grep -v 'not installed' || true
  else
    dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true
  fi
}

# docker_version_suffix — the part of the names DOCKER_VERSION_*, CONTAINERD_VERSION_* of this machine:
# DEB, UBUNTU_2404, RPM_EL9. Docker builds packages for each release apart (FTR.INFRA.INST-0001 tech §5).
docker_version_suffix() {
  if os_is_el; then
    echo "RPM_EL$(os_major)"
  elif os_is_ubuntu; then
    local v
    v=$(os_field VERSION_ID)
    echo "UBUNTU_${v//./}"
  else
    echo DEB
  fi
}

docker_wanted_version() {
  local var
  var=DOCKER_VERSION_$(docker_version_suffix)
  echo "${!var}"
}

# docker_apt_repo — the distribution and suite of the apt repository of Docker.
docker_apt_repo() {
  if os_is_ubuntu; then
    case $(os_field VERSION_ID) in
      24.04) echo "ubuntu noble" ;;
      26.04) echo "ubuntu resolute" ;;
    esac
  else
    echo "debian trixie"
  fi
}

install_docker_deb() {
  local dist suite docker containerd suffix
  read -r dist suite <<<"$(docker_apt_repo)"
  suffix=$(docker_version_suffix)
  docker=DOCKER_VERSION_$suffix containerd=CONTAINERD_VERSION_$suffix
  as_root install -m 0755 -d /etc/apt/keyrings
  # The key is one for Debian and Ubuntu; the file stays from an earlier run.
  if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    retry 3 10 curl -fsSL "https://download.docker.com/linux/$dist/gpg" -o "$WORK_DIR/docker.asc" ||
      die "$E_PREREQ" "failed to download the Docker repository key"
    as_root install -m 0644 "$WORK_DIR/docker.asc" /etc/apt/keyrings/docker.asc
  fi
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$dist $suite stable" |
    as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
  APT_UPDATED=0
  # The hold of an older run would stop the version asked for, as the versionlock does on EL.
  if dpkg-query -W docker-ce >/dev/null 2>&1; then
    retry 3 10 as_root apt-mark unhold docker-ce docker-ce-cli containerd.io >/dev/null ||
      die "$E_PREREQ" "apt-mark unhold of Docker failed"
  fi
  apt_install "docker-ce=${!docker}" "docker-ce-cli=${!docker}" "containerd.io=${!containerd}"
  retry 3 10 as_root apt-mark hold docker-ce docker-ce-cli containerd.io >/dev/null ||
    die "$E_PREREQ" "apt-mark hold of Docker failed"
}

# ensure_el_kernel_modules — on EL10 the netfilter modules that Docker needs are in kernel-modules-extra, which a
# minimal install does not have, and without them dockerd does not start. The package follows the running kernel.
ensure_el_kernel_modules() {
  modinfo xt_addrtype >/dev/null 2>&1 && return 0
  local kernel
  kernel=$(uname -r)
  log "kernel modules of netfilter: kernel-modules-extra-$kernel"
  retry 3 10 as_root dnf install -y -q "kernel-modules-extra-$kernel" >/dev/null ||
    die "$E_PREREQ" "kernel-modules-extra of the running kernel $kernel is not available: update the kernel, reboot and run up again"
}

# install_docker_el — the repository of Docker; container-selinux comes as its dependency, and SELinux
# stays as it is (FTR.INFRA.INST-0001 R9).
install_docker_el() {
  local major repo=centos docker containerd
  major=$(os_major)
  [[ $(os_field ID) == rhel ]] && repo=rhel
  docker=DOCKER_VERSION_RPM_EL$major containerd=CONTAINERD_VERSION_RPM_EL$major
  as_root tee /etc/yum.repos.d/docker-ce.repo >/dev/null <<EOF
[docker-ce-stable]
name=Docker CE Stable
baseurl=https://download.docker.com/linux/$repo/$major/x86_64/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/$repo/gpg
EOF
  dnf_install python3-dnf-plugin-versionlock
  # The lock of an older run would hide the version asked for.
  as_root dnf versionlock delete docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || true
  dnf_install "docker-ce-${!docker}" "docker-ce-cli-${!docker}" "containerd.io-${!containerd}"
  as_root dnf versionlock add docker-ce docker-ce-cli containerd.io >/dev/null
}

install_docker() {
  local engine
  engine=$(docker_engine_version)
  if [[ -n $engine ]] && ! docker_managed; then
    log "Docker $engine of the machine is used as it is"
  elif [[ $(docker_installed_version) == "$(docker_wanted_version)" ]]; then
    debug "Docker $(docker_wanted_version) is already installed"
  else
    log "Docker Engine $(docker_wanted_version)"
    if os_is_el; then install_docker_el; else install_docker_deb; fi
  fi
  if os_is_el; then ensure_el_kernel_modules; fi
  if ! systemctl is-enabled --quiet docker 2>/dev/null; then
    as_root systemctl enable --now docker >/dev/null ||
      die "$E_PREREQ" "Docker did not start, see journalctl -u docker"
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

# --- Binaries verified by SHA-256 ---

# verify_sha256 <file> <expected sum>
verify_sha256() {
  local actual
  actual=$(sha256sum "$1" | awk '{print $1}')
  [[ $actual == "$2" ]]
}

# install_kubectl — the binary on every OS: no branch for packages. An installed kubectl of the right minor
# version stays, whatever installed it.
install_kubectl() {
  if [[ $(kubectl_minor) == "$KUBECTL_MINOR" ]]; then
    debug "kubectl $KUBECTL_MINOR is already installed"
    return
  fi
  log "kubectl $KUBECTL_BIN_VERSION"
  local bin="$WORK_DIR/kubectl"
  retry 3 10 curl -fsSL "https://dl.k8s.io/release/$KUBECTL_BIN_VERSION/bin/linux/amd64/kubectl" -o "$bin" ||
    die "$E_PREREQ" "failed to download kubectl $KUBECTL_BIN_VERSION"
  verify_sha256 "$bin" "$KUBECTL_SHA256" ||
    die "$E_PREREQ" "checksum of kubectl $KUBECTL_BIN_VERSION does not match; nothing was installed"
  as_root install -m 0755 "$bin" "$BIN_DIR/kubectl"
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
  ok "Docker $(docker_engine_version), kubectl $(kubectl_minor), Helm $(helm_installed_version), minikube $(minikube_installed_version)"
}
