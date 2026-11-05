#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# R2: dependencies of the right versions are not reinstalled; checksums are verified.

load helpers

setup() {
  setup_stubs
  load_script
  os_release debian 13
  as_root() { echo "as_root $*" >>"$CALLS"; }
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
  for k in DOCKER_VERSION_DEB DOCKER_VERSION_RPM_EL9 DOCKER_VERSION_RPM_EL10 KUBECTL_BIN_VERSION K8S_VERSION KUBECTL_MINOR HELM_VERSION HELM_SHA256 MINIKUBE_VERSION MINIKUBE_SHA256 \
    STRIMZI_CHART_VERSION KAFKA_VERSION CNPG_CHART_VERSION POSTGRES_IMAGE SEAWEEDFS_CHART_VERSION \
    VM_SINGLE_CHART_VERSION VL_SINGLE_CHART_VERSION VMAGENT_CHART_VERSION KSM_CHART_VERSION \
    NODE_EXPORTER_CHART_VERSION VECTOR_CHART_VERSION GRAFANA_CHART_VERSION VL_PLUGIN_VERSION; do
    grep -q "^$k=." "$ROOT/config/versions.env" || { echo "no $k"; return 1; }
  done
  [[ $HELM_SHA256 =~ ^[0-9a-f]{64}$ && $MINIKUBE_SHA256 =~ ^[0-9a-f]{64}$ && $KUBECTL_SHA256 =~ ^[0-9a-f]{64}$ ]]
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
