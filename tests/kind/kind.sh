#!/usr/bin/env bash
# Integration on kind (QA, level I): the external target on a real cluster.
#
#   KIND_NODE=kindest/node:v1.37.0 tests/kind/kind.sh <scenario>
#
# Scenarios: no-policy (TGT-07), preflight, install (TGT-06, TGT-10, RES-07), ingress (RES-06),
# external (RES-03, RES-05). Each creates its own cluster and deletes it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCENARIO=${1:?scenario}
CLUSTER=installer-$SCENARIO
export INSTALL_TARGET=external KUBE_CONTEXT=kind-$CLUSTER
: "${KIND_NODE:=kindest/node:v1.37.0}"
FLANNEL_VERSION=v0.28.10
K=(kubectl --context "$KUBE_CONTEXT")
RUN_LOG=$(mktemp)

pass() { echo "✓ $*"; }
fail() {
  echo "✗ $*" >&2
  tail -40 "$RUN_LOG" >&2 || true
  "${K[@]}" get pods -A >&2 || true
  exit 1
}

cleanup() { if [[ ${KEEP:-0} != 1 ]]; then kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT

create_cluster() {
  kind create cluster --name "$CLUSTER" --image "$KIND_NODE" --wait 5m >/dev/null
}

# installer_run <expected code> <command…> — the environment holds the configuration.
installer_run() {
  local expect=$1 rc=0
  shift
  (cd "$ROOT" && bash ./installer "$@" --no-color) >"$RUN_LOG" 2>&1 || rc=$?
  [[ $rc == "$expect" ]] || fail "installer $*: code $rc, expected $expect"
}

status_ok() {
  (cd "$ROOT" && bash ./installer status --json --no-color) 2>/dev/null | jq -e "$1" >/dev/null ||
    fail "status --json does not match: $1"
}

preflight_gone() {
  ! "${K[@]}" get namespace installer-preflight >/dev/null 2>&1 || fail "namespace installer-preflight stays"
}

no_release() {
  if helm --kube-context "$KUBE_CONTEXT" list -A -q | grep -qx "$1"; then fail "release $1 is installed"; fi
}

has_release() {
  helm --kube-context "$KUBE_CONTEXT" list -A -q | grep -qx "$1" || fail "release $1 is not installed"
}

# TGT-07: a CNI without NetworkPolicy. Flannel does not apply it.
scenario_no_policy() {
  local cfg
  cfg=$(mktemp)
  cat >"$cfg" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: { disableDefaultCNI: true, podSubnet: 10.244.0.0/16 }
EOF
  # Flannel exits when the kernel of the host has no bridge netfilter, as on a GitHub runner.
  sudo modprobe br_netfilter || true
  # --wait fails without a CNI: the nodes become Ready only after flannel.
  kind create cluster --name "$CLUSTER" --image "$KIND_NODE" --config "$cfg" >/dev/null
  # Flannel needs the bridge CNI plugin, which the kind node does not ship.
  docker exec "$CLUSTER-control-plane" sh -c 'mkdir -p /opt/cni/bin && curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.7.1/cni-plugins-linux-amd64-v1.7.1.tgz | tar -xz -C /opt/cni/bin ./bridge ./host-local ./loopback ./portmap'
  "${K[@]}" apply -f "https://github.com/flannel-io/flannel/releases/download/$FLANNEL_VERSION/kube-flannel.yml" >/dev/null
  "${K[@]}" -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=3m >/dev/null ||
    { "${K[@]}" -n kube-flannel logs daemonset/kube-flannel-ds --tail=20 >&2 || true; fail "flannel did not start"; }
  "${K[@]}" wait --for=condition=Ready node --all --timeout=5m >/dev/null
  "${K[@]}" -n kube-system rollout status deployment/coredns --timeout=3m >/dev/null || fail "CoreDNS did not start"
  installer_run 18 up
  grep -q "does not apply NetworkPolicy to incoming traffic" "$RUN_LOG" || fail "the reason is not named"
  preflight_gone
  no_release storages
  pass "TGT-07: code 18, sandboxes named, the namespace removed, nothing installed"
}

# preflight only: a NetworkPolicy is really applied by kindnet, then the first deploy step is stopped.
scenario_preflight() {
  create_cluster
  (
    cd "$ROOT"
    # shellcheck source=/dev/null
    bash -c 'source ./installer; COLOR=0; setup_color; load_config "$PWD" /dev/null; preflight' _
  ) >"$RUN_LOG" 2>&1 || fail "preflight on a fitting cluster"
  grep -q "NetworkPolicy is applied" "$RUN_LOG" || fail "no verdict on NetworkPolicy"
  preflight_gone
  pass "R10: kindnet applies NetworkPolicy, the check says so and removes its namespace"
}

# TGT-06, TGT-10, RES-07: built-in storages and observability on an existing cluster.
scenario_install() {
  create_cluster
  installer_run 0 up
  status_ok '.ok and .target == "external"'
  if systemctl list-unit-files 'greenongrey*' --no-legend 2>/dev/null | grep -q .; then fail "a systemd unit appeared"; fi
  if [[ -e /usr/local/lib/installer || -e /var/lib/installer ]]; then fail "files of the installer on the machine"; fi
  has_release grafana
  pass "TGT-06, TGT-10: up and the checks pass on $KIND_NODE, the machine did not change"

  export OBSERVABILITY=false
  installer_run 0 up
  status_ok '.ok and .observability == false'
  no_release grafana
  no_release victoria-metrics
  pass "RES-07: observability off: no components, the checks pass"

  installer_run 0 up
  pass "UP-02: a repeated up passes"
}

# RES-06: the ingress of the cluster. cert-manager with a self-signed issuer, so no DNS is needed.
scenario_ingress() {
  create_cluster
  # shellcheck source=../../config/versions.env
  source "$ROOT/config/versions.env"
  helm --kube-context "$KUBE_CONTEXT" repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm --kube-context "$KUBE_CONTEXT" install cluster-cm jetstack/cert-manager --version "$CERT_MANAGER_CHART_VERSION" \
    -n outside-cm --create-namespace --set crds.enabled=true --wait >/dev/null
  "${K[@]}" apply -f - >/dev/null <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: corp }
spec: { selfSigned: {} }
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata: { name: corp-class }
spec: { controller: example.com/none }
EOF
  export PUBLIC_ACCESS=true INGRESS_MODE=external INGRESS_CLASS=corp-class ACME_ISSUER=corp PUBLIC_BASE_DOMAIN=stand.example
  installer_run 0 up
  no_release traefik
  no_release cert-manager
  [[ $("${K[@]}" -n observability get ingress -o jsonpath='{.items[0].spec.ingressClassName}') == corp-class ]] ||
    fail "Grafana does not use the class"
  [[ $("${K[@]}" -n observability get certificate grafana-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]] ||
    fail "the certificate of Grafana is not ready"
  status_ok '.ok and .public.ingressMode == "external" and .public.ingressClass == "corp-class" and .public.issuer == "corp"'
  pass "RES-06: no Traefik or cert-manager of the stand, Grafana uses the class and the issuer"
}

# RES-03, RES-05: external Postgres and S3, here pods in another namespace.
scenario_external() {
  create_cluster
  "${K[@]}" create namespace outside >/dev/null
  "${K[@]}" -n outside apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: postgres, labels: { app: postgres } }
spec:
  containers:
    - name: postgres
      image: pgvector/pgvector:pg17
      env: [{ name: POSTGRES_PASSWORD, value: owner-password }, { name: POSTGRES_USER, value: owner1 }, { name: POSTGRES_DB, value: hammurapi }]
      readinessProbe: { exec: { command: [pg_isready, -U, owner1] } }
---
apiVersion: v1
kind: Service
metadata: { name: postgres }
spec: { selector: { app: postgres }, ports: [{ port: 5432 }] }
---
apiVersion: v1
kind: Pod
metadata: { name: s3, labels: { app: s3 } }
spec:
  containers:
    - name: s3
      image: chrislusf/seaweedfs:4.48
      args: [server, -s3, -s3.port=8333]
      env: [{ name: AWS_ACCESS_KEY_ID, value: key }, { name: AWS_SECRET_ACCESS_KEY, value: secret }]
---
apiVersion: v1
kind: Service
metadata: { name: s3 }
spec: { selector: { app: s3 }, ports: [{ port: 8333 }] }
EOF
  "${K[@]}" -n outside wait --for=condition=Ready pod/postgres pod/s3 --timeout=5m >/dev/null
  export POSTGRES_MODE=external POSTGRES_HOST=postgres.outside.svc POSTGRES_PORT=5432 POSTGRES_DATABASE=hammurapi \
    POSTGRES_USER=owner1 POSTGRES_PASSWORD=owner-password POSTGRES_SSLMODE=disable \
    S3_MODE=external S3_ENDPOINT=http://s3.outside.svc:8333 S3_ACCESS_KEY=key S3_SECRET_KEY=secret S3_PATH_STYLE=true \
    S3_BUCKET=hammurapi-bucket S3_BUCKET_NABU=nabu-bucket OBSERVABILITY=false

  installer_run 14 up
  grep -q "bucket hammurapi-bucket" "$RUN_LOG" || fail "the bucket is not named"
  no_release storages
  pass "RES-03: no bucket: code 14 with its name, storages not deployed"

  local b
  for b in hammurapi-bucket nabu-bucket; do
    "${K[@]}" -n outside exec s3 -- sh -c "echo 's3.bucket.create -name $b' | weed shell" >/dev/null
  done
  installer_run 0 up
  status_ok '.ok and .storages.postgres == "external" and .storages.s3 == "external"'
  no_release seaweedfs
  no_release cnpg
  pass "RES-03, RES-05: Postgres and S3 passed the check from the cluster, the built-in ones are not installed"
}

case $SCENARIO in
  no-policy) scenario_no_policy ;;
  preflight) scenario_preflight ;;
  install) scenario_install ;;
  ingress) scenario_ingress ;;
  external) scenario_external ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac
