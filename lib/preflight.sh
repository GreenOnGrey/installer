# shellcheck shell=bash
# Checks of an external cluster before anything changes in it (FTR.INFRA.INST-0001 R10, tech §6). All
# reasons are collected and reported together, with code 18.

readonly PREFLIGHT_NS=installer-preflight
PREFLIGHT_ERRORS=()

preflight_error() { PREFLIGHT_ERRORS+=("$1"); }

# version_minor <gitVersion> — prints the minor of v1.N.M, nothing otherwise.
version_minor() { [[ $1 =~ ^v1\.([0-9]+)\. ]] && echo "${BASH_REMATCH[1]}"; }

preflight_versions() {
  local out server client min=${K8S_MIN_VERSION#1.} max=${K8S_MAX_TESTED#1.}
  out=$(kc version -o json 2>/dev/null || true)
  server=$(version_minor "$(jq -r '.serverVersion.gitVersion // empty' <<<"$out" 2>/dev/null)") || true
  client=$(version_minor "$(jq -r '.clientVersion.gitVersion // empty' <<<"$out" 2>/dev/null)") || true
  if [[ -z $server ]]; then
    preflight_error "the version of Kubernetes is unknown"
    return
  fi
  if ((server < min)); then
    preflight_error "Kubernetes 1.$server is older than the minimum $K8S_MIN_VERSION"
  elif ((server > max)); then
    warn "Kubernetes 1.$server is newer than the tested $K8S_MAX_TESTED: the install goes on"
  fi
  if [[ -n $client ]] && ((client - server > 1 || server - client > 1)); then
    preflight_error "kubectl 1.$client differs from Kubernetes 1.$server by more than one minor version"
  fi
}

# preflight_builtin — something built in goes into the cluster: storages, operators, observability.
preflight_builtin() {
  [[ $POSTGRES_MODE == internal || $KAFKA_MODE == internal || $S3_MODE == internal ]] || observability_enabled
}

preflight_rights() {
  # Traefik and cert-manager of the stand bring CRDs too.
  preflight_builtin || { public_enabled && ! ingress_external; } || return 0
  [[ $(kc auth can-i '*' '*' --all-namespaces 2>/dev/null || true) == yes ]] ||
    preflight_error "no rights to install CRDs and operators: cluster-admin of context $KUBE_CONTEXT is required"
}

preflight_storage_class() {
  preflight_builtin || return 0
  local default
  default=$(kc get storageclass -o json 2>/dev/null |
    jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")] | length' 2>/dev/null || true)
  [[ ${default:-0} -gt 0 ]] || preflight_error "no default StorageClass: built-in storages and observability need volumes"
}

preflight_ingress() {
  public_enabled && ingress_external || return 0
  kc get ingressclass "$INGRESS_CLASS" >/dev/null 2>&1 || preflight_error "ingress class $INGRESS_CLASS does not exist"
  kc get clusterissuer "$ACME_ISSUER" >/dev/null 2>&1 || preflight_error "ClusterIssuer $ACME_ISSUER does not exist"
}

# preflight_pod <name> <command> — a pod of the NetworkPolicy check, fit for a restricted namespace.
preflight_pod() {
  cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $PREFLIGHT_NS
  labels: { app: $1, app.kubernetes.io/managed-by: installer }
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: main
      image: $PROBE_BUSYBOX_IMAGE
      command: $2
      securityContext: { runAsNonRoot: true, runAsUser: 65534, allowPrivilegeEscalation: false, capabilities: { drop: [ALL] }, seccompProfile: { type: RuntimeDefault } }
$(probe_resources)
EOF
}

preflight_manifests() {
  local server='["sh", "-c", "mkdir -p /tmp/www && echo ok >/tmp/www/index.html && exec httpd -f -p 8080 -h /tmp/www"]'
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $PREFLIGHT_NS
  labels: { app.kubernetes.io/managed-by: installer }
EOF
  preflight_pod server "$server"
  # No policy selects the control until the egress step: it tells a denied connection from a broken network.
  preflight_pod control "$server"
  preflight_pod client '["sleep", "600"]'
}

# preflight_policy <name> <app> <Ingress|Egress> — denies all of that direction for the pods of the app.
preflight_policy() {
  cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $1
  namespace: $PREFLIGHT_NS
spec:
  podSelector: { matchLabels: { app: $2 } }
  policyTypes: [$3]
EOF
}

preflight_cleanup() {
  [[ ${PREFLIGHT_STARTED:-0} == 1 ]] || return 0
  kc delete namespace "$PREFLIGHT_NS" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 ||
    warn "failed to delete namespace $PREFLIGHT_NS"
  PREFLIGHT_STARTED=0
}

# preflight_connect <ip> — pass or deny from the client; nothing and a failure when kubectl itself fails,
# so a lost API call is never taken for a denied connection.
preflight_connect() {
  kc -n "$PREFLIGHT_NS" exec client -- sh -c "if wget -q -T 3 -O /dev/null http://$1:8080/; then echo pass; else echo deny; fi" 2>/dev/null
}

# preflight_wait_denied <denied ip> [control ip] — three denials in a row, as a CNI applies a policy
# some time after it appears. With a control, it must pass at the same moment.
preflight_wait_denied() {
  local n row=0 result control
  for ((n = 0; n < 15; n++)); do
    result=$(preflight_connect "$1") || result=""
    control=pass
    if [[ -n ${2:-} ]]; then control=$(preflight_connect "$2") || control=""; fi
    if [[ $result == deny && $control == pass ]]; then
      row=$((row + 1))
      ((row < 3)) || return 0
    else
      row=0
    fi
    sleep "${PREFLIGHT_DELAY:-3}"
  done
  return 1
}

# preflight_network_policy — the isolation of Nabu sandboxes rests on NetworkPolicy, in both directions,
# so it is tried for real: connections pass, then a policy denies them, and new ones must not pass.
preflight_network_policy() {
  local server control n reached=0
  PREFLIGHT_STARTED=1
  # A run that was killed may have left its policy behind.
  kc delete namespace "$PREFLIGHT_NS" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  if ! preflight_manifests | kc apply -f - >/dev/null 2>&1 ||
    ! kc -n "$PREFLIGHT_NS" wait --for=condition=Ready pod/server pod/control pod/client --timeout="${PREFLIGHT_POD_TIMEOUT:-180s}" >/dev/null 2>&1; then
    preflight_error "the pods of the NetworkPolicy check did not start in namespace $PREFLIGHT_NS"
    preflight_cleanup
    return
  fi
  server=$(kc -n "$PREFLIGHT_NS" get pod server -o jsonpath='{.status.podIP}' 2>/dev/null || true)
  control=$(kc -n "$PREFLIGHT_NS" get pod control -o jsonpath='{.status.podIP}' 2>/dev/null || true)
  for ((n = 0; n < 5; n++)); do
    if [[ $(preflight_connect "$server" || true) == pass && $(preflight_connect "$control" || true) == pass ]]; then
      reached=1
      break
    fi
    sleep "${PREFLIGHT_DELAY:-3}"
  done
  if ((reached == 0)); then
    preflight_error "pods do not reach each other before any NetworkPolicy, so isolation cannot be checked"
  elif ! preflight_policy deny-ingress server Ingress | kc apply -f - >/dev/null 2>&1 ||
    ! preflight_wait_denied "$server" "$control"; then
    preflight_error "the cluster does not apply NetworkPolicy to incoming traffic: the sandboxes of Nabu would not be isolated"
  elif ! preflight_policy deny-egress client Egress | kc apply -f - >/dev/null 2>&1 ||
    ! preflight_wait_denied "$control"; then
    preflight_error "the cluster does not apply NetworkPolicy to outgoing traffic: the sandboxes of Nabu would not be isolated"
  fi
  preflight_cleanup
}

# preflight — runs all checks, code 18 with all reasons. Changes nothing outside its own namespace.
preflight() {
  step preflight
  PREFLIGHT_ERRORS=()
  local tool
  for tool in kubectl helm jq; do
    have "$tool" || preflight_error "$tool is not installed: with INSTALL_TARGET=external the installer does not install it"
  done
  if ((${#PREFLIGHT_ERRORS[@]} == 0)); then
    if kc version >/dev/null 2>&1; then
      preflight_versions
      preflight_rights
      preflight_storage_class
      preflight_ingress
      if ((${#PREFLIGHT_ERRORS[@]} == 0)); then preflight_network_policy; fi
    else
      preflight_error "context $KUBE_CONTEXT is unreachable"
    fi
  fi
  if ((${#PREFLIGHT_ERRORS[@]})); then
    local e
    for e in "${PREFLIGHT_ERRORS[@]}"; do warn "$e"; done
    die "$E_PREFLIGHT" "the cluster does not fit: ${PREFLIGHT_ERRORS[*]}"
  fi
  ok "the cluster fits: context $KUBE_CONTEXT, NetworkPolicy is applied"
}
