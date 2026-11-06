# shellcheck shell=bash
# Public access (FTR.HMR.INFRA-0002, R17–R21): MetalLB, Traefik, cert-manager,
# one Let's Encrypt certificate for web., api., grafana.<base domain>, forwarding of
# ports 80/443 of the machine to the Traefik address, Grafana sign-in through GitHub.
# Enabled by PUBLIC_ACCESS=true; without it the stand works as in FTR.HMR.INFRA-0001.

readonly NS_INGRESS=ingress NS_CERT_MANAGER=cert-manager
FORWARD_BIN=${FORWARD_BIN:-/usr/local/lib/installer/ingress-forward}
FORWARD_STATE=${FORWARD_STATE:-/var/lib/installer}

PUBLIC_IP_RESOLVED="" PUBLIC_DOMAIN="" LB_IP=""
readonly GRAFANA_TLS_SECRET=grafana-tls

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
  if ingress_external || target_external; then
    PUBLIC_DOMAIN=$PUBLIC_BASE_DOMAIN
    log "base domain: $PUBLIC_DOMAIN (ingress class ${INGRESS_CLASS:-traefik}, issuer ${ACME_ISSUER:-letsencrypt})"
    return 0
  fi
  # install_steps prepares before the cluster changes, deploy_all again: the address is detected once.
  [[ -z $PUBLIC_DOMAIN ]] || return 0
  PUBLIC_IP_RESOLVED=$(detect_public_ip) || die "$E_DEPLOY" "failed to detect the external IP of the machine; set PUBLIC_IP"
  PUBLIC_DOMAIN=$(public_domain "$PUBLIC_IP_RESOLVED")
  log "base domain: $PUBLIC_DOMAIN (external IP $PUBLIC_IP_RESOLVED)"
  if [[ -z ${PUBLIC_BASE_DOMAIN:-} ]]; then
    warn "no PUBLIC_BASE_DOMAIN: $PUBLIC_DOMAIN is a fallback. Let's Encrypt limits certificates per registered domain, and all of sslip.io shares one limit, so issuance may fail for days: set a domain of your own (R18)"
  fi
  check_dns
}

# check_dns — every public host of the domain points to the machine, or Let's Encrypt issues no certificate
# (R18). The wizard asks whether to go on; without it code 19, before any certificate is requested.
# PUBLIC_DNS_CHECK=false skips it, for a proxy in front of the machine.
check_dns() {
  [[ -n ${PUBLIC_BASE_DOMAIN:-} && ${PUBLIC_DNS_CHECK:-true} == true ]] || return 0
  local host ips wrong=()
  for host in $(public_hosts); do
    ips=$(getent ahostsv4 "$host.$PUBLIC_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ') || true
    ips=${ips% }
    [[ $ips == "$PUBLIC_IP_RESOLVED" ]] || wrong+=("$host.$PUBLIC_DOMAIN → ${ips:-no record}")
  done
  if ((${#wrong[@]} == 0)); then
    ok "DNS: the hosts of $PUBLIC_DOMAIN point to $PUBLIC_IP_RESOLVED"
    return 0
  fi
  local msg
  msg="DNS of $PUBLIC_DOMAIN does not point to the machine $PUBLIC_IP_RESOLVED: $(printf '%s; ' "${wrong[@]}")Let's Encrypt would issue no certificate"
  if wizard_running; then
    warn "$msg"
    wizard_confirm "Go on anyway (the certificate waits for DNS)?" || die "$E_CANCELLED" "cancelled: point the hosts to $PUBLIC_IP_RESOLVED and run ./installer again"
    return 0
  fi
  die "$E_DNS" "$msg; point the hosts (or *.$PUBLIC_DOMAIN) to $PUBLIC_IP_RESOLVED, or set PUBLIC_DNS_CHECK=false behind a proxy; no certificate was requested"
}

# grafana_public_values <file> — Ingress, root_url and GitHub sign-in (R20).
grafana_public_values() {
  local f=$1
  {
    echo "ingress:"
    echo "  enabled: true"
    echo "  ingressClassName: ${INGRESS_CLASS:-traefik}"
    echo "  hosts: [\"grafana.$PUBLIC_DOMAIN\"]"
    if ingress_external; then
      echo "  annotations: { cert-manager.io/cluster-issuer: \"$ACME_ISSUER\" }"
      echo "  tls: [{ hosts: [\"grafana.$PUBLIC_DOMAIN\"], secretName: $GRAFANA_TLS_SECRET }]"
    else
      echo "  tls: [{ hosts: [\"grafana.$PUBLIC_DOMAIN\"] }]"
    fi
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
  public_enabled && observability_enabled || return 0
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

# public_hosts — host names of the certificate without the domain: Hammurapi, Grafana if it is on, and PUBLIC_EXTRA_HOSTS (Nabu).
# The hosts of Hammurapi stay unless PRODUCTS leaves it out and no CI has deployed it here: a host without DNS
# would fail the whole certificate.
public_hosts() {
  local hosts=() products=",${PRODUCTS// /},"
  if [[ $products == ,, || $products == *,hammurapi,* ]] ||
    hm status hammurapi-core -n "${HAMMURAPI_NAMESPACE:-hammurapi}" >/dev/null 2>&1; then
    hosts+=("${HAMMURAPI_WEB_HOST:-hammurapi}" "${HAMMURAPI_API_HOST:-hammurapi-api}")
  fi
  if observability_enabled; then hosts+=(grafana); fi
  # shellcheck disable=SC2206 # a list of names
  hosts+=(${PUBLIC_EXTRA_HOSTS:-})
  echo "${hosts[*]}"
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
    --from-literal="ingressMode=${INGRESS_MODE:-internal}" --from-literal="ingressClass=${INGRESS_CLASS:-traefik}" \
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
After=docker.service firewalld.service
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

# remove_forward — the unit stops, so its rules go (ingress-forward remove), then its files.
remove_forward() {
  local unit=$UNIT_PREFIX-ingress-forward
  [[ -f $UNIT_DIR/$unit.service ]] || return 0
  as_root systemctl disable --now "$unit.service" >/dev/null 2>&1 ||
    warn "failed to stop $unit: check iptables and firewalld for rules to $(cat "$FORWARD_STATE/lb-ip" 2>/dev/null)"
  as_root rm -f "$UNIT_DIR/$unit.service" "$FORWARD_BIN"
  as_root rm -f "$FORWARD_STATE/lb-ip" "$FORWARD_STATE/unit-prefix" "$FORWARD_STATE/applied-ip"
  as_root rmdir --ignore-fail-on-non-empty "$FORWARD_STATE" 2>/dev/null || true
  as_root systemctl daemon-reload
  log "forwarding of 80/443 is removed"
}

# deploy_public_external — nothing to install: the cluster has the controller and the issuer (R17).
deploy_public_external() {
  public_state_manifest | apply_stdin
  if observability_enabled && ! wait_certificate "$NS_OBSERVABILITY" "$GRAFANA_TLS_SECRET"; then
    kc -n "$NS_OBSERVABILITY" describe certificate "$GRAFANA_TLS_SECRET" >"$RUN_DIR/certificate.txt" 2>&1 || true
    die "$E_DEPLOY" "issuer $ACME_ISSUER did not issue the certificate of Grafana in 5 minutes, see $RUN_DIR/certificate.txt"
  fi
  ok "public access: *.$PUBLIC_DOMAIN through ingress class $INGRESS_CLASS, issuer $ACME_ISSUER"
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
  if ingress_external; then
    deploy_public_external
    return 0
  fi
  local range first lb_args=()
  if ! target_external; then
    range=$(metallb_range) || die "$E_DEPLOY" "failed to detect the minikube subnet for MetalLB"
    first=${range%-*}
    log "MetalLB: pool $range"
    metallb_addon "$first" "${range#*-}"
    metallb_config "$range" | apply_stdin
    lb_args=(--set-string "service.spec.loadBalancerIP=$first")
  fi
  ensure_namespace "$NS_INGRESS"
  ensure_namespace "$NS_CERT_MANAGER"

  release cert-manager "$NS_CERT_MANAGER" jetstack/cert-manager "$CERT_MANAGER_CHART_VERSION" cert-manager.yaml
  wait_crd clusterissuers.cert-manager.io
  wait_crd certificates.cert-manager.io
  cluster_issuers | apply_stdin

  release traefik "$NS_INGRESS" traefik/traefik "$TRAEFIK_CHART_VERSION" traefik.yaml \
    "${lb_args[@]}" \
    --set-string "tlsStore.default.defaultCertificate.secretName=$CERT_NAME"
  LB_IP=$(kc -n "$NS_INGRESS" get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n $LB_IP ]] || die "$E_DEPLOY" "the traefik service has no load balancer address"
  log "Traefik: $LB_IP"
  # On an external target the load balancer of the cluster takes the traffic.
  if ! target_external; then install_forward; fi

  public_certificate | apply_stdin
  public_state_manifest | apply_stdin
  local hosts
  hosts=$(public_hosts)
  log "certificate for ${hosts// /., }.$PUBLIC_DOMAIN (${ACME_ISSUER:-letsencrypt})"
  if ! kc -n "$NS_INGRESS" wait "certificate/$CERT_NAME" --for=condition=Ready --timeout=5m >/dev/null 2>&1; then
    kc -n "$NS_INGRESS" describe certificate "$CERT_NAME" >"$RUN_DIR/certificate.txt" 2>&1 || true
    kc get challenges -A -o wide >>"$RUN_DIR/certificate.txt" 2>&1 || true
    # The address appears only during this run, so on a new cluster DNS cannot point to it yet.
    if target_external; then
      die "$E_DEPLOY" "the certificate was not issued in 5 minutes: point *.$PUBLIC_DOMAIN to the load balancer $LB_IP and run up again (see $RUN_DIR/certificate.txt)"
    fi
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

# check_public_external — what the stand relies on in the cluster. No request to a host: DNS and the
# load balancer are not the stand's, and a failure here stops rollouts of products.
check_public_external() {
  local ready
  if ! kc get ingressclass "$INGRESS_CLASS" >/dev/null 2>&1; then
    record public fail "ingress class $INGRESS_CLASS does not exist"
    return
  fi
  ready=$(resource_ready clusterissuer "$ACME_ISSUER")
  if [[ $ready != True ]]; then
    record public fail "ClusterIssuer $ACME_ISSUER is not ready ('${ready:-does not exist}')"
    return
  fi
  if observability_enabled; then
    ready=$(resource_ready -n "$NS_OBSERVABILITY" certificate "$GRAFANA_TLS_SECRET")
    if [[ $ready != True ]]; then
      record public fail "the certificate of Grafana is not ready ('${ready:-does not exist}')"
      return
    fi
  fi
  record public ok "ingress class $INGRESS_CLASS, ClusterIssuer $ACME_ISSUER"
}

# check_public_certificate — Traefik of the stand in an external cluster: DNS and the load balancer are
# not the stand's, so no request goes to a host.
check_public_certificate() {
  local ready
  ready=$(resource_ready -n "$NS_INGRESS" certificate "$CERT_NAME")
  if [[ $ready == True ]]; then
    record public ok "certificate $CERT_NAME is ready"
  else
    record public fail "certificate $NS_INGRESS/$CERT_NAME is not ready ('${ready:-no status}', ${ACME_ISSUER:-letsencrypt})"
  fi
}

check_public() {
  public_enabled || return 0
  if ingress_external; then
    check_public_external
    return 0
  fi
  if target_external; then
    check_public_certificate
    return 0
  fi
  local host code insecure=() redirect hosts
  LB_IP=${LB_IP:-$(kc -n "$NS_INGRESS" get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)}
  PUBLIC_DOMAIN=${PUBLIC_DOMAIN:-$(state_public | jq -r '.baseDomain // empty' 2>/dev/null || true)}
  host="grafana.$PUBLIC_DOMAIN"
  hosts=$(public_hosts)
  # Without Grafana the stand has no host of its own, and a product fault must not stop rollouts of
  # products: the certificate and the redirect of Traefik are what the stand answers for.
  if ! observability_enabled; then
    host="${hosts%% *}.$PUBLIC_DOMAIN"
  fi
  if [[ -z $LB_IP || -z $PUBLIC_DOMAIN ]]; then
    record public fail "public access is not configured: no Traefik address or domain"
    return
  fi
  # A staging certificate is not trusted, so only issuance and the route are checked.
  [[ ${ACME_ISSUER:-letsencrypt} == letsencrypt-staging ]] && insecure=(-k)
  code=$(public_curl "$host" https "${insecure[@]}" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
  redirect=$(public_curl "$host" http -o /dev/null -w '%{http_code} %{redirect_url}' 2>/dev/null || true)
  if ! observability_enabled; then
    code=$(resource_ready -n "$NS_INGRESS" certificate "$CERT_NAME")
    if [[ $code != True ]]; then
      record public fail "certificate $NS_INGRESS/$CERT_NAME is not ready ('${code:-no status}', ${ACME_ISSUER:-letsencrypt})"
    elif [[ ! $redirect =~ ^30[178]\ https:// ]]; then
      record public fail "http://$host does not redirect to HTTPS: '${redirect:-no answer}'"
    else
      record public ok "certificate $CERT_NAME is ready for {${hosts// /,}}.$PUBLIC_DOMAIN, HTTP → HTTPS through $LB_IP"
    fi
  elif [[ $code != 200 && $code != 302 ]]; then
    record public fail "https://$host answers '${code:-no answer}' (expected 200 or a 302 to sign-in; certificate ${ACME_ISSUER:-letsencrypt})"
  elif [[ ! $redirect =~ ^30[178]\ https:// ]]; then
    record public fail "http://$host does not redirect to HTTPS: '${redirect:-no answer}'"
  else
    record public ok "https://{${hosts// /,}}.$PUBLIC_DOMAIN through $LB_IP, HTTP → HTTPS"
  fi
}
