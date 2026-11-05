#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# R2: dependencies of the right versions are not reinstalled; checksums are verified.

load helpers

setup() {
  setup_stubs
  load_script
  as_root() { echo "as_root $*" >>"$CALLS"; }
}

@test "PRE-02: Docker of the right version: no apt-get install, the service does not restart" {
  stub dpkg-query "[[ \$* == *docker-ce* ]] && printf '%s' '$DOCKER_VERSION'"
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
  called "docker-ce=$DOCKER_VERSION"
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
  for k in DOCKER_VERSION K8S_VERSION KUBECTL_MINOR HELM_VERSION HELM_SHA256 MINIKUBE_VERSION MINIKUBE_SHA256 \
    STRIMZI_CHART_VERSION KAFKA_VERSION CNPG_CHART_VERSION POSTGRES_IMAGE SEAWEEDFS_CHART_VERSION \
    VM_SINGLE_CHART_VERSION VL_SINGLE_CHART_VERSION VMAGENT_CHART_VERSION KSM_CHART_VERSION \
    NODE_EXPORTER_CHART_VERSION VECTOR_CHART_VERSION GRAFANA_CHART_VERSION VL_PLUGIN_VERSION; do
    grep -q "^$k=." "$ROOT/config/versions.env" || { echo "no $k"; return 1; }
  done
  [[ $HELM_SHA256 =~ ^[0-9a-f]{64}$ && $MINIKUBE_SHA256 =~ ^[0-9a-f]{64}$ ]]
}
