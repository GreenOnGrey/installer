# shellcheck shell=bash
# uninstall (FTR.INFRA.INST-0001 R5): only what the installer installed. External Postgres, Kafka and S3
# and their data stay: the installer holds only their connection secrets, which go with the namespace.

# Namespaces the installer and bin/*-deploy create carry this label; values of the products come first.
readonly OWNED_PART_OF=(nabu hammurapi landing installer)

# owned_namespaces — labelled namespaces in removal order: products, then the stand, storages and the
# state last, so the operators outlive the objects they serve.
owned_namespaces() {
  local json
  json=$(kc get namespaces -l "app.kubernetes.io/part-of in ($(
    IFS=,
    echo "${OWNED_PART_OF[*]}"
  ))" -o json) || die "$E_CLUSTER" "failed to list the namespaces of context $KUBE_CONTEXT"
  jq -r --arg storages "$NS_STORAGES" --arg state "$NS_STATE" '.items[] | .metadata.name as $n
    | [(if $n == $state then 3 elif $n == $storages then 2 elif .metadata.labels["app.kubernetes.io/part-of"] == "installer" then 1 else 0 end), $n]
    | @tsv' <<<"$json" | sort -k1,1n -k2 | cut -f2
}

# ordered_releases <ns> — releases of a namespace, the operators of storages last.
ordered_releases() {
  local out
  out=$(hm list -n "$1" -q) || die "$E_DEPLOY" "failed to list the releases of $1: nothing is removed from it"
  awk '$0 == "strimzi" || $0 == "cnpg" { last = last $0 "\n"; next } { print } END { printf "%s", last }' <<<"$out"
}

# warn_unlabelled — stand namespaces without the label: an older tag created them, or they existed before.
warn_unlabelled() {
  local ns left=()
  for ns in "$NS_STATE" "$NS_STORAGES" "$NS_OBSERVABILITY" "$NS_MCP" "$NS_INGRESS" "$NS_CERT_MANAGER"; do
    [[ " $* " == *" $ns "* ]] && continue
    if [[ -n $(kc get namespace "$ns" --ignore-not-found -o name 2>/dev/null) ]]; then left+=("$ns"); fi
  done
  ((${#left[@]} == 0)) ||
    warn "left alone, as they have no label app.kubernetes.io/part-of=installer: ${left[*]}; remove them by hand if they are of this installation"
}

uninstall_external() {
  step uninstall
  local nss=() ns rel listed
  listed=$(owned_namespaces) || exit
  [[ -n $listed ]] && mapfile -t nss <<<"$listed"
  warn_unlabelled "${nss[@]}"
  if ((${#nss[@]} == 0)); then
    ok "context $KUBE_CONTEXT holds nothing labelled by the installer"
    return 0
  fi
  log "namespaces: ${nss[*]}"
  local rels
  for ns in "${nss[@]}"; do
    # Apart from the loop: a failed list stops the run before any namespace goes.
    rels=$(ordered_releases "$ns") || exit
    while read -r rel; do
      [[ -n $rel ]] || continue
      log "removing release $rel ($ns)"
      hm uninstall "$rel" -n "$ns" --wait --timeout "$HELM_TIMEOUT" >/dev/null ||
        die "$E_DEPLOY" "failed to remove release $rel in $ns; run uninstall again"
    done <<<"$rels"
  done
  # Cluster-wide objects of the installer outside Helm: the ACME issuers of the built-in ingress.
  if kc get crd clusterissuers.cert-manager.io >/dev/null 2>&1; then
    kc delete clusterissuer -l app.kubernetes.io/managed-by=installer --ignore-not-found >/dev/null ||
      warn "failed to delete the ClusterIssuers of the installer"
  fi
  for ns in "${nss[@]}"; do
    log "removing namespace $ns"
    kc delete namespace "$ns" --ignore-not-found --timeout="$HELM_TIMEOUT" >/dev/null ||
      die "$E_DEPLOY" "namespace $ns was not removed in $HELM_TIMEOUT; run uninstall again"
  done
  ok "removed from context $KUBE_CONTEXT: ${nss[*]}"
}

uninstall_minikube() {
  step uninstall
  have minikube || die "$E_CLUSTER" "minikube is not installed"
  # The forwarding first: its rules point into the network of the profile.
  remove_forward
  cluster_delete >/dev/null || die "$E_CLUSTER" "minikube delete failed"
  remove_autostart
  ok "profile $MK_PROFILE deleted"
}
