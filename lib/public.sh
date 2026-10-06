# shellcheck shell=bash
# Публичный доступ (FTR.HMR.INFRA-0002, R17–R21): MetalLB, Traefik, cert-manager,
# один сертификат Let's Encrypt на web., api., grafana.<базовый домен>, проброс
# портов 80/443 машины на адрес Traefik, вход в Grafana через GitHub.
# Включается PUBLIC_ACCESS=true; без него стенд работает как в FTR.HMR.INFRA-0001.

readonly NS_INGRESS=ingress NS_CERT_MANAGER=cert-manager
readonly PUBLIC_CM=hammurapi-infra-public
FORWARD_BIN=${FORWARD_BIN:-/usr/local/lib/hammurapi-infra/ingress-forward}
FORWARD_UNIT=${FORWARD_UNIT:-/etc/systemd/system/hammurapi-ingress-forward.service}
FORWARD_STATE=${FORWARD_STATE:-/var/lib/hammurapi-infra}

PUBLIC_IP_RESOLVED="" PUBLIC_DOMAIN="" LB_IP=""

public_enabled() { [[ ${PUBLIC_ACCESS:-false} == true ]]; }

# detect_public_ip — PUBLIC_IP или внешний сервис определения адреса (без API облака).
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

# public_domain <ip> — PUBLIC_BASE_DOMAIN или <IP с дефисами>.sslip.io (R18).
public_domain() {
  if [[ -n ${PUBLIC_BASE_DOMAIN:-} ]]; then
    echo "$PUBLIC_BASE_DOMAIN"
  else
    echo "${1//./-}.sslip.io"
  fi
}

# metallb_range — METALLB_RANGE или <подсеть minikube>.200-.209.
metallb_range() {
  if [[ -n ${METALLB_RANGE:-} ]]; then
    echo "$METALLB_RANGE"
    return
  fi
  local ip
  ip=$(mk ip -p "$MK_PROFILE") || return 1
  echo "${ip%.*}.200-${ip%.*}.209"
}

# public_prepare — адрес и домен; вызывается до релизов, чтобы Grafana сразу
# получила свой Ingress и адрес для входа через GitHub.
public_prepare() {
  public_enabled || return 0
  step public
  PUBLIC_IP_RESOLVED=$(detect_public_ip) || die "$E_DEPLOY" "не удалось определить внешний IP машины; задайте PUBLIC_IP"
  PUBLIC_DOMAIN=$(public_domain "$PUBLIC_IP_RESOLVED")
  log "базовый домен: $PUBLIC_DOMAIN (внешний IP $PUBLIC_IP_RESOLVED)"
}

# grafana_public_values <файл> — Ingress, root_url и вход через GitHub (R20).
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
      # GF_AUTH_GITHUB_CLIENT_ID и GF_AUTH_GITHUB_CLIENT_SECRET — из секрета.
      echo "envFromSecret: grafana-github-oauth"
      # Grafana читает переменные только при старте, а смена данных секрета под не
      # перезапускает: хеш значений в аннотации пода перезапускает его при их смене.
      echo "podAnnotations:"
      echo "  checksum/github-oauth: $(printf '%s\n%s' "$GRAFANA_GITHUB_CLIENT_ID" "$(secret_value GRAFANA_GITHUB_CLIENT_SECRET)" | sha256sum | cut -c1-64)"
    fi
  } >"$f"
}

# ensure_public_secrets — OAuth-приложение GitHub для Grafana (значение секрета —
# из GRAFANA_GITHUB_CLIENT_SECRET или файла *_FILE; обновляется при каждом up).
ensure_public_secrets() {
  public_enabled || return 0
  [[ -n ${GRAFANA_GITHUB_CLIENT_ID:-} ]] || return 0
  put_secret "$NS_OBSERVABILITY" grafana-github-oauth Opaque \
    GF_AUTH_GITHUB_CLIENT_ID "$GRAFANA_GITHUB_CLIENT_ID" \
    GF_AUTH_GITHUB_CLIENT_SECRET "$(secret_value GRAFANA_GITHUB_CLIENT_SECRET)"
}

# metallb_pool — пул MetalLB «начало-конец», сохранённый в профиле minikube.
metallb_pool() {
  jq -r '.KubernetesConfig | "\(.LoadBalancerStartIP // "")-\(.LoadBalancerEndIP // "")"' \
    "${MINIKUBE_HOME:-$HOME/.minikube}/profiles/$MK_PROFILE/config.json" 2>/dev/null || true
}

# metallb_addon <начало> <конец> — дополнение metallb с пулом в профиле minikube.
# При каждом minikube start (в том числе после перезагрузки машины) дополнение
# заново применяет свой ConfigMap из пула профиля; без пула он получается пустым
# («- -»), MetalLB его не разбирает, и адрес Traefik никто не анонсирует.
# minikube 1.39 принимает пул только ответами на вопросы и на каждый вопрос
# создаёт новое буферизованное чтение stdin, поэтому вторая строка — с паузой.
metallb_addon() {
  local start=$1 end=$2 delay
  if [[ $(metallb_pool) == "$start-$end" ]]; then
    mk addons enable metallb -p "$MK_PROFILE" >"$RUN_DIR/metallb.log" 2>&1 ||
      die "$E_DEPLOY" "не удалось включить MetalLB, см. $RUN_DIR/metallb.log"
    return
  fi
  for delay in 2 5; do
    { echo "$start"; sleep "$delay"; echo "$end"; } |
      mk addons configure metallb -p "$MK_PROFILE" >"$RUN_DIR/metallb.log" 2>&1 || true
    [[ $(metallb_pool) == "$start-$end" ]] && return
  done
  die "$E_DEPLOY" "не удалось сохранить пул MetalLB $start-$end в профиле minikube, см. $RUN_DIR/metallb.log"
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
  labels: { app.kubernetes.io/managed-by: hammurapi-infra }
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

# public_hosts — имена хостов сертификата без домена: Hammurapi, Grafana и PUBLIC_EXTRA_HOSTS (Nabu).
public_hosts() {
  echo "${HAMMURAPI_WEB_HOST:-hammurapi} ${HAMMURAPI_API_HOST:-hammurapi-api} grafana${PUBLIC_EXTRA_HOSTS:+ $PUBLIC_EXTRA_HOSTS}"
}

public_certificate() {
  cat <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hammurapi-public
  namespace: $NS_INGRESS
  labels: { app.kubernetes.io/managed-by: hammurapi-infra }
spec:
  secretName: hammurapi-public
  issuerRef: { kind: ClusterIssuer, name: ${ACME_ISSUER:-letsencrypt} }
  dnsNames:
EOF
  local h
  for h in $(public_hosts); do
    printf '    - %s.%s\n' "$h" "$PUBLIC_DOMAIN"
  done
}

public_state_manifest() {
  kc -n "$NS_INGRESS" create configmap "$PUBLIC_CM" \
    --from-literal="baseDomain=$PUBLIC_DOMAIN" --from-literal="publicIp=$PUBLIC_IP_RESOLVED" \
    --from-literal="lbIp=$LB_IP" --from-literal="issuer=${ACME_ISSUER:-letsencrypt}" \
    --dry-run=client -o yaml
}

# install_forward — скрипт и systemd-юнит проброса 80/443 на адрес Traefik.
install_forward() {
  as_root install -d -m 755 "$(dirname "$FORWARD_BIN")" "$FORWARD_STATE"
  as_root install -m 755 "$ROOT/bin/ingress-forward" "$FORWARD_BIN"
  echo "$LB_IP" | as_root tee "$FORWARD_STATE/lb-ip" >/dev/null
  as_root tee "$FORWARD_UNIT" >/dev/null <<EOF
# Проброс TCP 80/443 внешнего интерфейса на адрес Traefik в сети minikube
# (FTR.HMR.INFRA-0002). Устанавливает hammurapi-infra.sh up.
[Unit]
Description=Hammurapi: проброс 80/443 на ingress minikube
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
  as_root systemctl enable hammurapi-ingress-forward.service >/dev/null 2>&1
  # restart: правила пересоздаются с актуальным адресом.
  as_root systemctl restart hammurapi-ingress-forward.service ||
    die "$E_DEPLOY" "не удалось применить правила проброса, см. journalctl -u hammurapi-ingress-forward"
}

deploy_public() {
  public_enabled || return 0
  step public
  local range first
  range=$(metallb_range) || die "$E_DEPLOY" "не удалось определить подсеть minikube для MetalLB"
  first=${range%-*}
  log "MetalLB: пул $range"
  metallb_addon "$first" "${range#*-}"
  metallb_config "$range" | apply_stdin
  kc create namespace "$NS_INGRESS" --dry-run=client -o yaml | apply_stdin
  kc create namespace "$NS_CERT_MANAGER" --dry-run=client -o yaml | apply_stdin

  release cert-manager "$NS_CERT_MANAGER" jetstack/cert-manager "$CERT_MANAGER_CHART_VERSION" cert-manager.yaml
  wait_crd clusterissuers.cert-manager.io
  wait_crd certificates.cert-manager.io
  cluster_issuers | apply_stdin

  release traefik "$NS_INGRESS" traefik/traefik "$TRAEFIK_CHART_VERSION" traefik.yaml \
    --set-string "service.spec.loadBalancerIP=$first"
  LB_IP=$(kc -n "$NS_INGRESS" get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n $LB_IP ]] || die "$E_DEPLOY" "MetalLB не выдал адрес сервису traefik"
  log "Traefik: $LB_IP"
  install_forward

  public_certificate | apply_stdin
  public_state_manifest | apply_stdin
  local hosts
  hosts=$(public_hosts)
  log "сертификат для ${hosts// /., }.$PUBLIC_DOMAIN (${ACME_ISSUER:-letsencrypt})"
  if ! kc -n "$NS_INGRESS" wait certificate/hammurapi-public --for=condition=Ready --timeout=5m >/dev/null 2>&1; then
    kc -n "$NS_INGRESS" describe certificate hammurapi-public >"$RUN_DIR/certificate.txt" 2>&1 || true
    kc get challenges -A -o wide >>"$RUN_DIR/certificate.txt" 2>&1 || true
    die "$E_DEPLOY" "сертификат не выпущен за 5 минут: проверьте, что порты 80/443 машины открыты снаружи, а *.$PUBLIC_DOMAIN указывает на $PUBLIC_IP_RESOLVED (см. $RUN_DIR/certificate.txt)"
  fi
  ok "публичный доступ: https://{${hosts// /,}}.$PUBLIC_DOMAIN"
}

# public_curl <хост> <схема> [аргументы curl…] — запрос к Traefik с машины
# (--resolve на адрес балансировщика: не зависит от hairpin NAT облака).
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
  PUBLIC_DOMAIN=${PUBLIC_DOMAIN:-$(kc -n "$NS_INGRESS" get configmap "$PUBLIC_CM" -o jsonpath='{.data.baseDomain}' 2>/dev/null)}
  host="grafana.$PUBLIC_DOMAIN"
  if [[ -z $LB_IP || -z $PUBLIC_DOMAIN ]]; then
    record public fail "публичный доступ не настроен: нет адреса Traefik или домена"
    return
  fi
  # Сертификат staging не доверенный — проверяем только выпуск и маршрут.
  [[ ${ACME_ISSUER:-letsencrypt} == letsencrypt-staging ]] && insecure=(-k)
  code=$(public_curl "$host" https "${insecure[@]}" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
  redirect=$(public_curl "$host" http -o /dev/null -w '%{http_code} %{redirect_url}' 2>/dev/null || true)
  if [[ $code != 200 && $code != 302 ]]; then
    record public fail "https://$host отвечает «${code:-нет ответа}» (ожидалось 200 или 302 на вход; сертификат ${ACME_ISSUER:-letsencrypt})"
  elif [[ ! $redirect =~ ^30[178]\ https:// ]]; then
    record public fail "http://$host не перенаправляет на HTTPS: «${redirect:-нет ответа}»"
  else
    record public ok "https://{${HAMMURAPI_WEB_HOST:-hammurapi},${HAMMURAPI_API_HOST:-hammurapi-api},grafana}.$PUBLIC_DOMAIN через $LB_IP, HTTP → HTTPS"
  fi
}
