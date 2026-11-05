# shellcheck shell=bash
# Public access (FTR.HMR.INFRA-0002, R17–R21): MetalLB, Traefik, cert-manager,
# one Let's Encrypt certificate for web., api., grafana.<base domain>, forwarding of
# ports 80/443 of the machine to the Traefik address, Grafana sign-in through GitHub.
# Enabled by PUBLIC_ACCESS=true; without it the stand works as in FTR.HMR.INFRA-0001.

readonly NS_INGRESS=ingress NS_CERT_MANAGER=cert-manager
FORWARD_BIN=${FORWARD_BIN:-/usr/local/lib/installer/ingress-forward}
FORWARD_STATE=${FORWARD_STATE:-/var/lib/installer}

PUBLIC_IP_RESOLVED="" PUBLIC_DOMAIN="" LB_IP=""

public_enabled() { [[ ${PUBLIC_ACCESS:-false} == true ]]; }

# detect_public_ip — PUBLIC_IP or an external address service (no cloud API).
detect_public_ip() {
  if [[ -n ${PUBLIC_IP:-} ]]; then
    echo "$PUBLIC_IP"
    return
  fi
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return
    fi
  done
  return 1
}

# public_domain <ip> — PUBLIC_BASE_DOMAIN or <IP with dashes>.sslip.io (R18).
public_domain() {
  if [[ -n ${PUBLIC_BASE_DOMAIN:-} ]]; then
    echo "$PUBLIC_BASE_DOMAIN"
  else
    echo "${1//./-}.sslip.io"
  fi
}

# metallb_range — METALLB_RANGE or <minikube subnet>.200-.209.
metallb_range() {
  if [[ -n ${METALLB_RANGE:-} ]]; then
    echo "$METALLB_RANGE"
    return
  fi
  local ip
  ip=$(mk ip -p "$MK_PROFILE") || return 1
  echo "${ip%.*}.200-${ip%.*}.209"
}

# public_prepare — address and domain; runs before the releases, so Grafana gets
# its Ingress and GitHub sign-in address at once.
public_prepare() {
  public_enabled || return 0
  step public
  PUBLIC_IP_RESOLVED=$(detect_public_ip) || die "$E_DEPLOY" "failed to detect the external IP of the machine; set PUBLIC_IP"
  PUBLIC_DOMAIN=$(public_domain "$PUBLIC_IP_RESOLVED")
  log "base domain: $PUBLIC_DOMAIN (external IP $PUBLIC_IP_RESOLVED)"
}

# grafana_public_values <file> — Ingress, root_url and GitHub sign-in (R20).
grafana_public_values() {
  local f=$1
  {
    echo "ingress:"
    echo "  enabled: true"
    echo "  ingressClassName: traefik"
    echo "  hosts: [\"grafana.$PUBLIC_DOMAIN\"]"
    echo "  tls: [{ hosts: [\"grafana.$PUBLIC_DOMAIN\"] }]"
    echo "grafana.ini:"
    echo "  server: { root_url: \"https://grafana.$PUBLIC_DOMAIN\" }"
    if [[ -n ${GRAFANA_GITHUB_CLIENT_ID:-} ]]; then
      echo "  auth.github:"
      echo "    enabled: true"
      echo "    allow_sign_up: true"
      echo "    scopes: user:email,read:org"
      echo "    allowed_organizations: $GRAFANA_GITHUB_ORG"
      echo "    role_attribute_path: \"'Editor'\""
      echo "  auth: { disable_login_form: false }"
      # GF_AUTH_GITHUB_CLIENT_ID and GF_AUTH_GITHUB_CLIENT_SECRET come from a secret.
      echo "envFromSecret: grafana-github-oauth"
      # Grafana reads the variables only at start, and a changed secret does not restart
      # the pod: a hash of the values in a pod annotation does.
      echo "podAnnotations:"
      echo "  checksum/github-oauth: $(printf '%s\n%s' "$GRAFANA_GITHUB_CLIENT_ID" "$(secret_value GRAFANA_GITHUB_CLIENT_SECRET)" | sha256sum | cut -c1-64)"
    fi
  } >"$f"
}

# ensure_public_secrets — the GitHub OAuth app for Grafana (the secret comes from
# GRAFANA_GITHUB_CLIENT_SECRET or the *_FILE file; refreshed on every up).
ensure_public_secrets() {
  public_enabled || return 0
  [[ -n ${GRAFANA_GITHUB_CLIENT_ID:-} ]] || return 0
  put_secret "$NS_OBSERVABILITY" grafana-github-oauth Opaque \
    GF_AUTH_GITHUB_CLIENT_ID "$GRAFANA_GITHUB_CLIENT_ID" \
    GF_AUTH_GITHUB_CLIENT_SECRET "$(secret_value GRAFANA_GITHUB_CLIENT_SECRET)"
}

# metallb_pool — the MetalLB pool start-end saved in the minikube profile.
metallb_pool() {
  jq -r '.KubernetesConfig | "\(.LoadBalancerStartIP // "")-\(.LoadBalancerEndIP // "")"' \
    "${MINIKUBE_HOME:-$HOME/.minikube}/profiles/$MK_PROFILE/config.json" 2>/dev/null || true
}

# metallb_addon <start> <end> — the metallb addon with its pool in the minikube profile.
# On every minikube start (machine reboots included) the addon reapplies its
# ConfigMap from the profile's pool; without a pool it comes out empty
# ("- -"), MetalLB cannot parse it, and nothing announces the Traefik address.
# minikube 1.39 takes the pool only as answers to prompts and opens a new buffered
# stdin read for each prompt, so the second line comes after a pause.
metallb_addon() {
  local start=$1 end=$2 delay
  if [[ $(metallb_pool) == "$start-$end" ]]; then
    mk addons enable metallb -p "$MK_PROFILE" >"$RUN_DIR/metallb.log" 2>&1 ||
      die "$E_DEPLOY" "failed to enable MetalLB, see $RUN_DIR/metallb.log"
    return
  fi
  for delay in 2 5; do
    { echo "$start"; sleep "$delay"; echo "$end"; } |
      mk addons configure metallb -p "$MK_PROFILE" >"$RUN_DIR/metallb.log" 2>&1 || true
    [[ $(metallb_pool) == "$start-$end" ]] && return
  done
  die "$E_DEPLOY" "failed to save the MetalLB pool $start-$end in the minikube profile, see $RUN_DIR/metallb.log"
}

metallb_config() {
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
  namespace: metallb-system
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - $1
EOF
}

cluster_issuers() {
  local name server
  for name in letsencrypt letsencrypt-staging; do
    server=https://acme-v02.api.letsencrypt.org/directory
    [[ $name == letsencrypt-staging ]] && server=https://acme-staging-v02.api.letsencrypt.org/directory
    cat <<EOF
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $name
  labels: { app.kubernetes.io/managed-by: installer }
spec:
  acme:
    email: $ACME_EMAIL
    server: $server
    privateKeySecretRef: { name: $name-account }
    solvers:
      - http01: { ingress: { ingressClassName: traefik } }
EOF
  done
}

# public_hosts — host names of the certificate without the domain: Hammurapi, Grafana and PUBLIC_EXTRA_HOSTS (Nabu).
public_hosts() {
  echo "${HAMMURAPI_WEB_HOST:-hammurapi} ${HAMMURAPI_API_HOST:-hammurapi-api} grafana${PUBLIC_EXTRA_HOSTS:+ $PUBLIC_EXTRA_HOSTS}"
}

public_certificate() {
  cat <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: $NS_INGRESS
  labels: { app.kubernetes.io/managed-by: installer }
spec:
  secretName: $CERT_NAME
  issuerRef: { kind: ClusterIssuer, name: ${ACME_ISSUER:-letsencrypt} }
  dnsNames:
EOF
  local h
  for h in $(public_hosts); do
    printf '    - %s.%s\n' "$h" "$PUBLIC_DOMAIN"
  done
}

public_state_manifest() {
  kc -n "$NS_STATE" create configmap "$STATE_PUBLIC_CM" \
    --from-literal="baseDomain=$PUBLIC_DOMAIN" --from-literal="publicIp=$PUBLIC_IP_RESOLVED" \
    --from-literal="lbIp=$LB_IP" --from-literal="issuer=${ACME_ISSUER:-letsencrypt}" \
    --dry-run=client -o yaml
}

# install_forward — the script and systemd unit forwarding 80/443 to the Traefik address.
install_forward() {
  local unit=$UNIT_PREFIX-ingress-forward
  as_root install -d -m 755 "$(dirname "$FORWARD_BIN")" "$FORWARD_STATE"
  as_root install -m 755 "$ROOT/bin/ingress-forward" "$FORWARD_BIN"
  echo "$LB_IP" | as_root tee "$FORWARD_STATE/lb-ip" >/dev/null
  echo "$UNIT_PREFIX" | as_root tee "$FORWARD_STATE/unit-prefix" >/dev/null
  as_root tee "$UNIT_DIR/$unit.service" >/dev/null <<EOF
# Forwards TCP 80/443 of the external interface to the Traefik address in the minikube network
# (FTR.HMR.INFRA-0002). Installed by installer up.
[Unit]
Description=GreenOnGrey: forwarding of 80/443 to the minikube ingress
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=MK_PROFILE=$MK_PROFILE
Environment=FORWARD_STATE=$FORWARD_STATE
ExecStart=$FORWARD_BIN apply
ExecStop=$FORWARD_BIN remove

[Install]
WantedBy=multi-user.target docker.service
EOF
  as_root systemctl daemon-reload
  as_root systemctl enable "$unit.service" >/dev/null 2>&1
  # restart: rules are recreated with the current address.
  as_root systemctl restart "$unit.service" ||
    die "$E_DEPLOY" "failed to apply the forwarding rules, see journalctl -u $unit"
}

deploy_public() {
  if ! public_enabled; then
    # Otherwise status would find the old ConfigMap and report an old domain.
    kc -n "$NS_STATE" delete configmap "$STATE_PUBLIC_CM" --ignore-not-found >/dev/null ||
      warn "failed to delete $NS_STATE/$STATE_PUBLIC_CM: status may report an old domain"
    kc -n "$NS_INGRESS" delete configmap hammurapi-infra-public --ignore-not-found >/dev/null ||
      warn "failed to delete $NS_INGRESS/hammurapi-infra-public: status may report an old domain"
    return 0
  fi
  step public
  local range first
  range=$(metallb_range) || die "$E_DEPLOY" "failed to detect the minikube subnet for MetalLB"
  first=${range%-*}
  log "MetalLB: pool $range"
  metallb_addon "$first" "${range#*-}"
  metallb_config "$range" | apply_stdin
  kc create namespace "$NS_INGRESS" --dry-run=client -o yaml | apply_stdin
  kc create namespace "$NS_CERT_MANAGER" --dry-run=client -o yaml | apply_stdin

  release cert-manager "$NS_CERT_MANAGER" jetstack/cert-manager "$CERT_MANAGER_CHART_VERSION" cert-manager.yaml
  wait_crd clusterissuers.cert-manager.io
  wait_crd certificates.cert-manager.io
  cluster_issuers | apply_stdin

  release traefik "$NS_INGRESS" traefik/traefik "$TRAEFIK_CHART_VERSION" traefik.yaml \
    --set-string "service.spec.loadBalancerIP=$first" \
    --set-string "tlsStore.default.defaultCertificate.secretName=$CERT_NAME"
  LB_IP=$(kc -n "$NS_INGRESS" get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n $LB_IP ]] || die "$E_DEPLOY" "MetalLB gave no address to the traefik service"
  log "Traefik: $LB_IP"
  install_forward

  public_certificate | apply_stdin
  public_state_manifest | apply_stdin
  local hosts
  hosts=$(public_hosts)
  log "certificate for ${hosts// /., }.$PUBLIC_DOMAIN (${ACME_ISSUER:-letsencrypt})"
  if ! kc -n "$NS_INGRESS" wait "certificate/$CERT_NAME" --for=condition=Ready --timeout=5m >/dev/null 2>&1; then
    kc -n "$NS_INGRESS" describe certificate "$CERT_NAME" >"$RUN_DIR/certificate.txt" 2>&1 || true
    kc get challenges -A -o wide >>"$RUN_DIR/certificate.txt" 2>&1 || true
    die "$E_DEPLOY" "the certificate was not issued in 5 minutes: check that ports 80/443 of the machine are open from outside and *.$PUBLIC_DOMAIN points to $PUBLIC_IP_RESOLVED (see $RUN_DIR/certificate.txt)"
  fi
  ok "public access: https://{${hosts// /,}}.$PUBLIC_DOMAIN"
}

# public_curl <host> <scheme> [curl arguments…] — a request to Traefik from the machine
# (--resolve to the load balancer address: independent of the cloud's hairpin NAT).
public_curl() {
  local host=$1 scheme=$2 port=443
  shift 2
  [[ $scheme == http ]] && port=80
  curl -sS --max-time 15 --resolve "$host:$port:$LB_IP" "$@" "$scheme://$host/"
}

check_public() {
  public_enabled || return 0
  local host="grafana.$PUBLIC_DOMAIN" code insecure=() redirect
  LB_IP=${LB_IP:-$(kc -n "$NS_INGRESS" get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)}
  PUBLIC_DOMAIN=${PUBLIC_DOMAIN:-$(state_public | jq -r '.baseDomain // empty' 2>/dev/null || true)}
  host="grafana.$PUBLIC_DOMAIN"
  if [[ -z $LB_IP || -z $PUBLIC_DOMAIN ]]; then
    record public fail "public access is not configured: no Traefik address or domain"
    return
  fi
  # A staging certificate is not trusted, so only issuance and the route are checked.
  [[ ${ACME_ISSUER:-letsencrypt} == letsencrypt-staging ]] && insecure=(-k)
  code=$(public_curl "$host" https "${insecure[@]}" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
  redirect=$(public_curl "$host" http -o /dev/null -w '%{http_code} %{redirect_url}' 2>/dev/null || true)
  if [[ $code != 200 && $code != 302 ]]; then
    record public fail "https://$host answers '${code:-no answer}' (expected 200 or a 302 to sign-in; certificate ${ACME_ISSUER:-letsencrypt})"
  elif [[ ! $redirect =~ ^30[178]\ https:// ]]; then
    record public fail "http://$host does not redirect to HTTPS: '${redirect:-no answer}'"
  else
    record public ok "https://{${HAMMURAPI_WEB_HOST:-hammurapi},${HAMMURAPI_API_HOST:-hammurapi-api},grafana}.$PUBLIC_DOMAIN through $LB_IP, HTTP → HTTPS"
  fi
}
