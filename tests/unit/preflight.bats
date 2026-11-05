#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 R8, R10: the external target and the checks of the cluster.

load helpers

setup() {
  setup_stubs
  load_script
  INSTALL_TARGET=external KUBE_CONTEXT=ctx
  CONFIG_EXPLICIT[KUBE_CONTEXT]=1
  PREFLIGHT_DELAY=0
  sleep() { :; }
  # NO_POLICY: connections pass after the policy. SERVER, CLIENT: gitVersions.
  export SERVER=v1.36.2 CLIENT=v1.36.0 DEFAULT_SC=true CAN=yes NO_POLICY="" STATE=$BATS_TEST_TMPDIR/policy
  stub_cluster
}

stub_cluster() {
  stub kubectl '
case "$*" in
  *"version -o json"*) echo "{\"clientVersion\":{\"gitVersion\":\"$CLIENT\"},\"serverVersion\":{\"gitVersion\":\"$SERVER\"}}" ;;
  *" version"*) [[ -z $NO_CONTEXT ]] ;;
  *"auth can-i"*) echo "$CAN" ;;
  *"get storageclass"*) echo "{\"items\":[{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"$DEFAULT_SC\"}}}]}" ;;
  *"get ingressclass"*) [[ -z $NO_CLASS ]] ;;
  *"get clusterissuer"*) [[ -z $NO_ISSUER ]] ;;
  *"apply -f -"*) m=$(cat); [[ $m == *"policyTypes: [Ingress]"* ]] && : >"$STATE"; [[ $m == *"policyTypes: [Egress]"* ]] && : >"$STATE.egress"; exit 0 ;;
  *"get pod server"*) echo 10.0.0.9 ;;
  *"get pod control"*) echo 10.0.0.8 ;;
  *exec*)
    [[ -z $EXEC_FAILS ]] || exit 1
    if [[ $* == *10.0.0.9* ]]; then
      if [[ -e $STATE && -z $NO_POLICY ]]; then echo deny; else echo pass; fi
    else
      if [[ -e $STATE.egress && -z $NO_EGRESS ]]; then echo deny; else echo pass; fi
    fi
    ;;
esac'
}

@test "TGT-08: all reasons are reported together with code 18" {
  SERVER=v1.30.0 CLIENT=v1.30.0 CAN=no DEFAULT_SC=false
  run preflight
  [ "$status" -eq 18 ]
  [[ $output == *"older than the minimum 1.35"* ]]
  [[ $output == *"cluster-admin"* ]]
  [[ $output == *"no default StorageClass"* ]]
  not_called "installer-preflight"
}

@test "TGT-11: above the tested version: a warning, the install goes on" {
  SERVER=v1.38.0 CLIENT=v1.38.0
  run preflight
  [ "$status" -eq 0 ]
  [[ $output == *"newer than the tested 1.37"* ]]
}

@test "TGT-11: kubectl two minor versions behind: code 18" {
  SERVER=v1.37.0 CLIENT=v1.35.0
  run preflight
  [ "$status" -eq 18 ]
  [[ $output == *"kubectl 1.35 differs from Kubernetes 1.37"* ]]
}

@test "TGT-11: the bounds of the range pass; a provider suffix in the version is read" {
  SERVER=v1.35.8-gke.100 CLIENT=v1.35.1
  run preflight
  [ "$status" -eq 0 ]
  rm -f "$STATE" "$STATE.egress"
  SERVER=v1.37.0 CLIENT=v1.37.1
  run preflight
  [ "$status" -eq 0 ]
}

@test "R10: an unreachable context: code 18 with its name" {
  export NO_CONTEXT=1
  run preflight
  [ "$status" -eq 18 ]
  [[ $output == *"context ctx is unreachable"* ]]
}

@test "R10: all external, ingress external: no cluster-admin or StorageClass is needed" {
  POSTGRES_MODE=external KAFKA_MODE=external S3_MODE=external OBSERVABILITY=false INGRESS_MODE=external
  CAN=no DEFAULT_SC=false
  run preflight
  [ "$status" -eq 0 ]
}

@test "R10: external ingress: the class and the issuer must exist" {
  PUBLIC_ACCESS=true INGRESS_MODE=external INGRESS_CLASS=nginx ACME_ISSUER=corp
  export NO_CLASS=1 NO_ISSUER=1
  run preflight
  [ "$status" -eq 18 ]
  [[ $output == *"ingress class nginx does not exist"* && $output == *"ClusterIssuer corp does not exist"* ]]
}

@test "TGT-07 (U): NetworkPolicy is not applied: code 18, sandboxes named, the namespace removed" {
  NO_POLICY=1
  run preflight
  [ "$status" -eq 18 ]
  [[ $output == *"does not apply NetworkPolicy to incoming traffic: the sandboxes of Nabu"* ]]
  called "delete namespace installer-preflight"
}

@test "TGT-07 (U): a CNI without egress rules: code 18" {
  export NO_EGRESS=1
  run preflight
  [ "$status" -eq 18 ]
  [[ $output == *"to outgoing traffic"* ]]
  called "delete namespace installer-preflight"
}

@test "R10: a failing kubectl exec is not taken for a denied connection" {
  NO_POLICY=1
  # Connections pass, then each API call fails: nothing says the policy works.
  preflight_connect() {
    local n
    n=$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0)
    echo $((n + 1)) >"$BATS_TEST_TMPDIR/n"
    ((n < 2)) || return 1
    echo pass
  }
  run preflight
  [ "$status" -eq 18 ]
  [[ $output == *"does not apply NetworkPolicy"* ]]
}

@test "R10: a denied control means a broken network, not a working policy" {
  preflight_connect() {
    local n
    n=$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0)
    echo $((n + 1)) >"$BATS_TEST_TMPDIR/n"
    ((n < 2)) && echo pass || echo deny
  }
  run preflight
  [ "$status" -eq 18 ]
}

@test "R10: a namespace left by a killed run is removed first" {
  run preflight
  [ "$status" -eq 0 ]
  [ "$(grep -c "delete namespace installer-preflight" "$CALLS")" -eq 2 ]
}

@test "R10: nothing built in and public access off: no cluster-admin is needed" {
  POSTGRES_MODE=external KAFKA_MODE=external S3_MODE=external OBSERVABILITY=false PUBLIC_ACCESS=false
  CAN=no
  run preflight
  [ "$status" -eq 0 ]
  PUBLIC_ACCESS=true
  rm -f "$STATE" "$STATE.egress"
  run preflight
  [ "$status" -eq 18 ]
  [[ $output == *cluster-admin* ]]
}

@test "R10: NetworkPolicy is applied: passes, and the namespace is removed" {
  run preflight
  [ "$status" -eq 0 ]
  called "wget -q -T 3"
  [ -e "$STATE" ] && [ -e "$STATE.egress" ]
  called "delete namespace installer-preflight"
}

@test "R10: a missing tool is named" {
  have() { [[ $1 != helm ]]; }
  run preflight
  [ "$status" -eq 18 ]
  [[ $output == *"helm is not installed"* ]]
}

@test "TGT-06 (U): up on the external target leaves the machine alone, all kubectl with the context" {
  check_host() { echo called >"$BATS_TEST_TMPDIR/host"; }
  deploy_all() { :; }
  write_config() { :; }
  run_checks() { :; }
  write_version() { :; }
  print_summary() { :; }
  exec() { :; }
  flock() { :; }
  stub tee 'cat >/dev/null'
  ROOT_LOG=$BATS_TEST_TMPDIR
  LOCK_FILE=/nonexistent/lock
  acquire_lock
  preflight
  ensure_stand_namespaces
  [ ! -e "$BATS_TEST_TMPDIR/host" ]
  for c in sudo apt-get dnf systemctl minikube docker; do not_called "$c "; done
  while read -r line; do
    case $line in kubectl*) [[ $line == "kubectl --context ctx"* ]] ;; esac
  done <"$CALLS"
  [[ $LOCK_FILE == "$WORK_DIR/installer.lock" ]]
}

@test "R8: the external target needs a context; another target is an error" {
  unset 'CONFIG_EXPLICIT[KUBE_CONTEXT]'
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *KUBE_CONTEXT* ]]
  INSTALL_TARGET=cloud run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *INSTALL_TARGET* ]]
}

@test "R18: the external target with public access needs a domain" {
  CONFIG_EXPLICIT[KUBE_CONTEXT]=1
  PUBLIC_ACCESS=true PUBLIC_BASE_DOMAIN='' ACME_EMAIL=a@b.example
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *PUBLIC_BASE_DOMAIN* ]]
}

@test "R8: built-in ingress on the external target: no MetalLB and no forwarding" {
  PUBLIC_ACCESS=true PUBLIC_BASE_DOMAIN=x.example PUBLIC_DOMAIN=x.example ACME_EMAIL=a@b.example
  run deploy_public
  [ "$status" -ne 2 ]
  not_called "minikube"
  not_called "systemctl"
  not_called "loadBalancerIP"
  called "upgrade --install traefik"
}

@test "CLI-08 (U): uninstall of the external target: releases, then namespaces of the installer, no minikube" {
  RUN_DIR=$BATS_TEST_TMPDIR
  kc() {
    echo "kubectl $*" >>"$CALLS"
    case "$*" in
      "get namespaces"*) echo '{"items":[
        {"metadata":{"name":"installer","labels":{"app.kubernetes.io/part-of":"installer"}}},
        {"metadata":{"name":"storages","labels":{"app.kubernetes.io/part-of":"installer"}}},
        {"metadata":{"name":"mcp","labels":{"app.kubernetes.io/part-of":"installer"}}},
        {"metadata":{"name":"nabu","labels":{"app.kubernetes.io/part-of":"nabu"}}}]}' ;;
    esac
  }
  hm() {
    echo "helm $*" >>"$CALLS"
    [[ "$*" == "list -n storages -q" ]] && printf 'cnpg\nstorages\nstrimzi\nseaweedfs\n'
    [[ "$*" == "list -n nabu -q" ]] && echo nabu-core
    return 0
  }
  run uninstall_external
  [ "$status" -eq 0 ]
  not_called "minikube"
  # Products first, the stand next, storages with their operators last, the state at the end.
  [ "$(grep -o 'uninstall [a-z-]* -n [a-z]*' "$CALLS" | tr '\n' ' ')" = \
    "uninstall nabu-core -n nabu uninstall storages -n storages uninstall seaweedfs -n storages uninstall cnpg -n storages uninstall strimzi -n storages " ]
  [ "$(grep -o 'delete namespace [a-z]*' "$CALLS" | tr '\n' ' ')" = \
    "delete namespace nabu delete namespace mcp delete namespace storages delete namespace installer " ]
  # The label selector covers the namespaces of bin/*-deploy too.
  called "part-of in (nabu,hammurapi,landing,installer)"
}

@test "CLI-08 (U): uninstall of an external target without anything of the installer changes nothing" {
  kc() { echo "kubectl $*" >>"$CALLS"; [[ "$*" == "get namespaces"* ]] && echo '{"items":[]}'; return 0; }
  run uninstall_external
  [ "$status" -eq 0 ]
  not_called "delete"
  not_called "uninstall"
}

@test "R8: status of the external target asks the context, not minikube" {
  cluster_reachable
  not_called "minikube"
  [ "$(cluster_label)" = "context ctx" ]
  stub kubectl 'exit 1'
  run cluster_reachable
  [ "$status" -ne 0 ]
}

@test "R10: the memory of all nodes counts" {
  stub kubectl 'printf "8Gi\n8Gi\n"'
  [ "$(cluster_allocatable_memory)" -eq $((16 * 1024 * 1024 * 1024)) ]
}

@test "the minikube target stays the default: its route is untouched" {
  unset INSTALL_TARGET
  run target_external
  [ "$status" -ne 0 ]
  [ "$(cluster_label)" = "minikube greenongrey" ]
}

@test "CLI-08 (U): a failed list of releases stops uninstall before any namespace goes" {
  kc() {
    echo "kubectl $*" >>"$CALLS"
    [[ "$*" == "get namespaces"* ]] && echo '{"items":[{"metadata":{"name":"storages","labels":{"app.kubernetes.io/part-of":"installer"}}}]}'
    return 0
  }
  hm() { echo "helm $*" >>"$CALLS"; [[ "$*" != list* ]]; }
  run uninstall_external
  [ "$status" -eq 13 ]
  not_called "delete namespace"
}

@test "CLI-08 (U): uninstall names stand namespaces without the label and leaves them" {
  kc() {
    echo "kubectl $*" >>"$CALLS"
    case "$*" in
      "get namespaces"*) echo '{"items":[]}' ;;
      "get namespace installer"* | "get namespace storages"*) echo "namespace/${3}" ;;
    esac
    return 0
  }
  run uninstall_external
  [ "$status" -eq 0 ]
  [[ $output == *"left alone"*"installer storages"* ]]
  not_called "delete"
}

@test "R5: uninstall of the external target without KUBE_CONTEXT: code 2, nothing deleted" {
  run env -u KUBE_CONTEXT INSTALL_TARGET=external LOGS_DIR="$BATS_TEST_TMPDIR" bash "$ROOT/installer" uninstall --yes --no-color
  [ "$status" -eq 2 ]
  [[ $output == *KUBE_CONTEXT* ]]
  not_called "delete"
}

@test "R5: ensure_namespace labels a namespace it creates and leaves an existing one alone" {
  kc() { echo "kubectl $*" >>"$CALLS"; [[ "$*" == "get namespace old"* ]] && echo namespace/old; [[ "$*" == "create"* ]] && echo '{"metadata":{"name":"new"}}'; return 0; }
  apply_stdin() { cat >>"$BATS_TEST_TMPDIR/applied"; }
  ensure_namespace old
  not_called "create namespace old"
  ensure_namespace new
  jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "installer"' "$BATS_TEST_TMPDIR/applied"
}
