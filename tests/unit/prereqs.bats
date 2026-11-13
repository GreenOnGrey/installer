#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# R2: dependencies of the right versions are not reinstalled; checksums are verified.

load helpers

setup() {
  setup_stubs
  load_script
  os_release debian 13
  as_root() { echo "as_root $*" >>"$CALLS"; }
  # The runner of CI has its own Docker: a test that needs one says so.
  docker_engine_version() { :; }
}

@test "TGT-14: Docker of the machine that the installer did not put: used as it is, nothing installs or holds" {
  os_release ubuntu 24.04
  docker_engine_version() { echo 28.2.2; }
  stub apt-mark 'exit 0'
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user" || /usr/bin/id "$@"'
  run install_docker
  [ "$status" -eq 0 ]
  [[ $output == *"Docker 28.2.2 of the machine is used as it is"* ]]
  not_called "apt-get"
  not_called "docker-ce="
  not_called "apt-mark hold"
  called "usermod -aG docker"
}

@test "TGT-14: Docker that the installer put (held) follows versions.env" {
  os_release ubuntu 24.04
  docker_engine_version() { echo 29.0.0; }
  stub apt-mark '[[ $1 == showhold ]] && echo docker-ce; exit 0'
  stub dpkg-query "[[ \$* == *Version* ]] && printf '%s' '5:29.0.0-1~ubuntu.24.04~noble'; exit 0"
  stub curl 'exit 0'
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  run install_docker
  [ "$status" -eq 0 ]
  called "docker-ce=$DOCKER_VERSION_UBUNTU_2404"
}

@test "PRE-02: Docker of the right version: no apt-get install, the service does not restart" {
  stub dpkg-query "[[ \$* == *docker-ce* ]] && printf '%s' '$DOCKER_VERSION_DEB'"
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  run install_docker
  [ "$status" -eq 0 ]
  not_called "apt-get install"
  not_called "docker-ce="
  not_called "restart"
  not_called "enable --now"
}

@test "PRE-02: Docker of another version: the version from versions.env installs" {
  stub dpkg-query "printf '%s' '5:28.0.0-1~debian.13~trixie'"
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  run install_docker
  [ "$status" -eq 0 ]
  called "docker-ce=$DOCKER_VERSION_DEB"
}

@test "PRE-03: the minikube checksum does not match: code 11, the binary is not installed" {
  stub minikube 'exit 1'
  stub curl 'while (($#)); do [[ $1 == -o ]] && echo corrupted >"$2"; shift; done'
  run install_minikube
  [ "$status" -eq 11 ]
  [[ $output == *"checksum of minikube"* ]]
  not_called "as_root install"
}

@test "PRE-03: the Helm checksum does not match: code 11" {
  stub helm 'exit 1'
  stub curl 'while (($#)); do [[ $1 == -o ]] && echo corrupted >"$2"; shift; done'
  run install_helm
  [ "$status" -eq 11 ]
  not_called "as_root install"
}

@test "R2: minikube of the right version does not download" {
  stub minikube "echo $MINIKUBE_VERSION"
  run install_minikube
  [ "$status" -eq 0 ]
  not_called curl
}

@test "R2: all versions of components and charts are set in versions.env" {
  local k
  for k in DOCKER_VERSION_DEB DOCKER_VERSION_UBUNTU_2404 CONTAINERD_VERSION_UBUNTU_2404 DOCKER_VERSION_UBUNTU_2604 CONTAINERD_VERSION_UBUNTU_2604 DOCKER_VERSION_RPM_EL9 DOCKER_VERSION_RPM_EL10 KUBECTL_BIN_VERSION K8S_VERSION KUBECTL_MINOR HELM_VERSION HELM_SHA256 MINIKUBE_VERSION MINIKUBE_SHA256 \
    STRIMZI_CHART_VERSION KAFKA_VERSION CNPG_CHART_VERSION POSTGRES_IMAGE SEAWEEDFS_CHART_VERSION \
    VM_SINGLE_CHART_VERSION VL_SINGLE_CHART_VERSION VMAGENT_CHART_VERSION KSM_CHART_VERSION \
    NODE_EXPORTER_CHART_VERSION VECTOR_CHART_VERSION GRAFANA_CHART_VERSION VL_PLUGIN_VERSION; do
    grep -q "^$k=." "$ROOT/config/versions.env" || { echo "no $k"; return 1; }
  done
  [[ $HELM_SHA256 =~ ^[0-9a-f]{64}$ && $MINIKUBE_SHA256 =~ ^[0-9a-f]{64}$ && $KUBECTL_SHA256 =~ ^[0-9a-f]{64}$ ]]
}

# --- Ubuntu (FTR.INFRA.INST-0001 R9) ---

@test "R9: Docker on Ubuntu 24.04 and 26.04: the repository of ubuntu, the versions of the release, apt-mark" {
  local release suite var
  for release in 24.04:noble 26.04:resolute; do
    suite=${release#*:} release=${release%:*}
    os_release ubuntu "$release"
    : >"$CALLS"
    stub dpkg-query 'exit 1'
    stub curl 'exit 0'
    stub systemctl 'exit 0'
    stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
    as_root() { echo "as_root $*" >>"$CALLS"; [[ $1 == tee ]] && cat >"$BATS_TEST_TMPDIR/repo"; return 0; }
    run install_docker
    [ "$status" -eq 0 ] || { echo "$release: $output"; return 1; }
    var=DOCKER_VERSION_UBUNTU_${release//./}
    [[ ${!var} == *"~ubuntu.$release~$suite" ]]
    called "docker-ce=${!var}"
    var=CONTAINERD_VERSION_UBUNTU_${release//./}
    called "containerd.io=${!var}"
    called "download.docker.com/linux/ubuntu/gpg"
    called "apt-mark hold docker-ce docker-ce-cli containerd.io"
    grep -qx "deb \[arch=amd64 signed-by=/etc/apt/keyrings/docker.asc\] https://download.docker.com/linux/ubuntu $suite stable" "$BATS_TEST_TMPDIR/repo"
  done
}

@test "R9: Docker of another version on Ubuntu: the hold of the earlier run is released before the install" {
  os_release ubuntu 24.04
  stub dpkg-query "[[ \$* == *Version* ]] && printf '%s' '5:28.0.0-1~ubuntu.24.04~noble'; exit 0"
  stub curl 'exit 0'
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  run install_docker
  [ "$status" -eq 0 ]
  [ "$(grep -n 'apt-mark unhold' "$CALLS" | cut -d: -f1)" -lt "$(grep -n "docker-ce=$DOCKER_VERSION_UBUNTU_2404" "$CALLS" | cut -d: -f1)" ]
  [ "$(grep -n "docker-ce=$DOCKER_VERSION_UBUNTU_2404" "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'apt-mark hold' "$CALLS" | cut -d: -f1)" ]
}

@test "R9: Docker of the right version on Ubuntu: apt-get is not called" {
  os_release ubuntu 26.04
  stub dpkg-query "printf '%s' '$DOCKER_VERSION_UBUNTU_2604'"
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  run install_docker
  [ "$status" -eq 0 ]
  not_called "apt-get"
}

@test "R9: apt waits for the lock that unattended-upgrades of a fresh Ubuntu holds" {
  as_root() { echo "as_root $*" >>"$CALLS"; }
  run apt_install jq
  [ "$status" -eq 0 ]
  called "apt-get -o DPkg::Lock::Timeout=300 update"
  called "apt-get -o DPkg::Lock::Timeout=300 install -y -qq --allow-downgrades jq"
}

# --- RHEL and its rebuilds (FTR.INFRA.INST-0001 R9) ---

@test "R9: Docker on Rocky 9: the repository of centos, the pinned versions, versionlock instead of apt-mark" {
  os_release rocky 9.4
  stub rpm 'exit 1'
  stub dnf 'exit 0'
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  as_root() { echo "as_root $*" >>"$CALLS"; [[ $1 == tee ]] && cat >"$BATS_TEST_TMPDIR/repo"; "$@" 2>/dev/null || true; }
  run install_docker
  [ "$status" -eq 0 ]
  called "dnf install -y -q docker-ce-$DOCKER_VERSION_RPM_EL9 docker-ce-cli-$DOCKER_VERSION_RPM_EL9 containerd.io-$CONTAINERD_VERSION_RPM_EL9"
  called "dnf versionlock add docker-ce docker-ce-cli containerd.io"
  not_called apt-get
  not_called apt-mark
  grep -q 'linux/centos/9/x86_64/stable' "$BATS_TEST_TMPDIR/repo"
}

@test "R9: Docker on RHEL 10: the repository of rhel and the versions of EL10" {
  os_release rhel 10.0
  stub rpm 'exit 1'
  stub dnf 'exit 0'
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  as_root() { echo "as_root $*" >>"$CALLS"; [[ $1 == tee ]] && cat >"$BATS_TEST_TMPDIR/repo"; "$@" 2>/dev/null || true; }
  run install_docker
  [ "$status" -eq 0 ]
  called "docker-ce-$DOCKER_VERSION_RPM_EL10"
  grep -q 'linux/rhel/10/x86_64/stable' "$BATS_TEST_TMPDIR/repo"
}

@test "R9: Docker of the right version on EL: dnf is not called" {
  os_release rocky 9.4
  stub rpm "printf '%s' '$DOCKER_VERSION_RPM_EL9'"
  stub dnf 'exit 0'
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  run install_docker
  [ "$status" -eq 0 ]
  not_called "dnf"
}

@test "R9: utilities on EL: curl-minimal counts as curl, and a missing tar installs" {
  os_release rocky 9.4
  stub rpm '[[ $* == *" tar"* ]] && exit 1; exit 0'
  stub dnf 'exit 0'
  as_root() { "$@"; }
  run install_utils
  [ "$status" -eq 0 ]
  called "rpm -q --whatprovides curl"
  called "dnf install -y -q tar"
}

@test "FTR.INFRA.INST-0001 tech §5: kubectl is the binary with its checksum, without packages" {
  have() { [[ $1 != kubectl ]]; }
  stub curl 'while (($#)); do [[ $1 == -o ]] && echo fake >"$2"; shift; done'
  run install_kubectl
  [ "$status" -eq 11 ]
  [[ $output == *"checksum of kubectl"* ]]
  called "dl.k8s.io/release/$KUBECTL_BIN_VERSION/bin/linux/amd64/kubectl"
  not_called apt-get
  not_called "install -m 0755"
}

@test "FTR.INFRA.INST-0001 tech §5: kubectl of the right minor version stays, whatever installed it" {
  stub kubectl "echo '{\"clientVersion\":{\"major\":\"1\",\"minor\":\"${KUBECTL_MINOR#v1.}\"}}'"
  run install_kubectl
  [ "$status" -eq 0 ]
  not_called curl
}

@test "R9: EL10 without netfilter modules: kernel-modules-extra of the running kernel, before Docker starts" {
  os_release rocky 10.2
  stub rpm "printf '%s' '$DOCKER_VERSION_RPM_EL10'"
  stub modinfo 'exit 1'
  stub uname 'echo 6.12.0-1.el10.x86_64'
  stub dnf 'exit 0'
  stub systemctl '[[ $* == *is-enabled* ]] && exit 1; exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  as_root() { "$@"; }
  run install_docker
  [ "$status" -eq 0 ]
  called "dnf install -y -q kernel-modules-extra-6.12.0-1.el10.x86_64"
  [ "$(grep -n 'kernel-modules-extra' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'enable --now docker' "$CALLS" | cut -d: -f1)" ]
}

@test "R9: the modules are there: nothing installs; the package is gone: code 11 with what to do" {
  os_release rocky 9.4
  stub rpm "printf '%s' '$DOCKER_VERSION_RPM_EL9'"
  stub modinfo 'exit 0'
  stub dnf 'exit 1'
  stub systemctl 'exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  run install_docker
  [ "$status" -eq 0 ]
  not_called "kernel-modules-extra"
  stub modinfo 'exit 1'
  sleep() { :; }
  as_root() { "$@"; }
  run ensure_el_kernel_modules
  [ "$status" -eq 11 ]
  [[ $output == *"update the kernel, reboot"* ]]
}

@test "R9: Docker enabled but stopped is started" {
  stub dpkg-query "printf '%s' '$DOCKER_VERSION_DEB'"
  stub systemctl '[[ $* == *is-active* ]] && exit 3; exit 0'
  stub id '[[ $1 == -nG ]] && echo "user docker" || /usr/bin/id "$@"'
  run install_docker
  [ "$status" -eq 0 ]
  called "systemctl enable --now docker"
}

@test "R9: Docker that does not start names the journal" {
  stub dpkg-query "printf '%s' '$DOCKER_VERSION_DEB'"
  stub systemctl 'exit 1'
  as_root() { "$@"; }
  run install_docker
  [ "$status" -eq 11 ]
  [[ $output == *"journalctl -u docker"* ]]
}
