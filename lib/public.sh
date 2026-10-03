#!/usr/bin/env bash
# Статические проверки манифестов (уровень I): рендер ровно тех релизов, что
# развернула бы `up`, для 8 комбинаций режимов хранилищ; kubeconform, запросы и
# лимиты, типы сервисов, задания сбора метрик, сервисы хранилищ, сроки хранения.
# Нужны: helm ≥ 3.17, kubeconform, jq, yq (mikefarah). Сеть — для чартов.
#   tests/manifests.sh            # все проверки
#   SKIP_REPOS=1 tests/manifests.sh   # без helm repo add/update
# SC2034: переменные конфигурации читают подключённые функции lib/*.sh.
# shellcheck disable=SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${OUT:-$ROOT/.work/manifests}
COLOR=${COLOR:-auto}
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/external.sh
source "$ROOT/lib/external.sh"
# shellcheck source=../lib/checks.sh
source "$ROOT/lib/checks.sh"
# shellcheck source=../lib/deploy.sh
source "$ROOT/lib/deploy.sh"
# shellcheck source=../lib/public.sh
source "$ROOT/lib/public.sh"
setup_color
load_config "$ROOT" /dev/null
KUBE_VERSION=${K8S_VERSION#v}
FAILURES=0

fail() {
  printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"
  FAILURES=$((FAILURES + 1))
}
pass() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }

# hm — вместо установки рендерит релиз (`helm template`) в stdout, который
# release() пишет в $RUN_DIR/helm-<релиз>.log.
hm() {
  if [[ $1 == upgrade ]]; then
    shift 2
    local name=$1 chart=$2 args=()
    shift 2
    while (($#)); do
      case $1 in
        --wait) ;;
        --timeout) shift ;;
        *) args+=("$1") ;;
      esac
      shift
    done
    helm template "$name" "$chart" --kube-version "$KUBE_VERSION" --include-crds "${args[@]}"
    elif [[ $1 == status ]]; then
    return 1
  fi
}
kc() { return 0; }

# render <каталог> — релизы текущей конфигурации.
render() {
  RUN_DIR=$1 WORK_DIR=$1/work
  rm -rf "$RUN_DIR"
  mkdir -p "$WORK_DIR"
  RELEASES=()
  STEP=render
  deploy_operators
  deploy_storages
  deploy_observability
}

# jq на Windows (Git Bash) печатает CRLF; на Linux tr ничего не меняет.
jq() { command jq "$@" | tr -d '\r'; }

# docs_json <файлы…> — все объекты манифестов как поток JSON.
docs_json() { cat "$@" | yq -o=json -I=0 'select(. != null)'; }

check_resources() {
  local dir=$1 missing
  missing=$(docs_json "$dir"/helm-*.log | jq -r '
    select(.kind | IN("Deployment", "StatefulSet", "DaemonSet", "Job", "Pod", "CronJob"))
    | (if .kind == "Pod" then .spec elif .kind == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end) as $s
    | "\(.kind)/\(.metadata.name)" as $o
    | (($s.containers // []) + ($s.initContainers // []))[]
    | select((.resources.requests.cpu // "") == "" or (.resources.requests.memory // "") == ""
        or (.resources.limits.cpu // "") == "" or (.resources.limits.memory // "") == "")
  | "\($o)/\(.name)"')
  missing+=$(docs_json "$dir"/helm-storages.log | jq -r '
    select(.kind == "KafkaNodePool" or .kind == "Cluster")
    | select((.spec.resources.requests.memory // "") == "" or (.spec.resources.limits.memory // "") == "")
  | " \(.kind)/\(.metadata.name)"')
  if [[ -n $missing ]]; then fail "RES-01 $2: нет запросов или лимитов: $(echo "$missing" | tr '\n' ' ')"; else pass "RES-01 $2: запросы и лимиты заданы"; fi
}

check_service_types() {
  local bad
  bad=$(docs_json "$1"/helm-*.log | jq -r 'select(.kind == "Service") | select((.spec.type // "ClusterIP") | IN("ClusterIP", "ExternalName") | not) | "\(.metadata.name):\(.spec.type)"')
  if [[ -n $bad ]]; then fail "SEC-04 $2: сервисы наружу: $bad"; else pass "SEC-04 $2: только ClusterIP и ExternalName"; fi
}

check_storage_services() {
  local names
  names=$(docs_json "$1/helm-storages.log" | jq -r 'select(.kind == "Service") | .metadata.name' | sort | tr '\n' ' ')
  if [[ $names == "kafka postgres s3 " ]]; then pass "STO-05 $2: сервисы postgres, kafka, s3"; else fail "STO-05 $2: сервисы: $names"; fi
}

check_scrape_jobs() {
  local jobs expected
  jobs=$(yq -r '.config.scrape_configs[].job_name' "$1/vmagent-scrape.yaml" | sort | tr '\n' ' ')
  # hammurapi — всегда в конфигурации, но не обязателен в проверках стенда.
  expected=$({ expected_jobs; echo hammurapi; } | sort | tr '\n' ' ')
  if [[ $jobs == "$expected" ]]; then pass "MET-02 $2: задания сбора $jobs"; else fail "MET-02 $2: задания «$jobs», ожидались «$expected»"; fi
}

check_internal_releases() {
  local dir=$1 label=$2 ok=1
  [[ $KAFKA_MODE == internal ]] || { [[ -f $dir/helm-strimzi.log ]] && ok=0; }
  [[ $POSTGRES_MODE == internal ]] || { [[ -f $dir/helm-cnpg.log ]] && ok=0; }
  [[ $S3_MODE == internal ]] || { [[ -f $dir/helm-seaweedfs.log ]] && ok=0; }
  if docs_json "$dir/helm-storages.log" | jq -e --arg pg "$POSTGRES_MODE" --arg k "$KAFKA_MODE" '
  select((.kind == "Cluster" and $pg == "external") or (.kind == "Kafka" and $k == "external"))' >/dev/null; then ok=0; fi
  if ((ok)); then pass "EXT-01 $label: внешние хранилища не разворачиваются"; else fail "EXT-01 $label: развёрнуто хранилище во внешнем режиме"; fi
}

kubeconform_dir() {
  local dir=$1 label=$2 schemas=$OUT/schemas out f
  # Только объекты Kubernetes: в журналах рендера бывают предупреждения Helm.
  for f in "$dir"/helm-*.log; do
    grep -v -E '^(WARNING|walk\.go|coalesce\.go)' "$f"
    printf '\n---\n'
  done | yq 'select(.kind != null)' >"$dir/all.yaml"
  if out=$(kubeconform -strict -summary -kubernetes-version "$KUBE_VERSION" \
    -schema-location default -schema-location "$schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    -skip CustomResourceDefinition - <"$dir/all.yaml" 2>&1); then
    pass "QUAL-02 $label: kubeconform — $(tail -1 <<<"$out")"
  else
    fail "QUAL-02 $label: kubeconform"
    echo "$out" | grep -v '^Summary' | head -20 | sed 's/^/      /'
  fi
}

# crd_schemas — JSON-схемы CR (Kafka, KafkaNodePool, Cluster) из CRD операторов.
crd_schemas() {
  local schemas=$OUT/schemas
  rm -rf "$schemas"
  mkdir -p "$schemas"
  docs_json "$1"/helm-strimzi.log "$1"/helm-cnpg.log | jq -c 'select(.kind == "CustomResourceDefinition")' |
  while IFS= read -r crd; do
    local group kind
      group=$(jq -r .spec.group <<<"$crd")
      kind=$(jq -r '.spec.names.kind | ascii_downcase' <<<"$crd")
      mkdir -p "$schemas/$group"
      jq -r '.spec.versions[] | .name' <<<"$crd" | while read -r v; do
        jq --arg v "$v" '.spec.versions[] | select(.name == $v) | .schema.openAPIV3Schema' <<<"$crd" >"$schemas/$group/${kind}_$v.json"
      done
    done
}

# --- HMR.INFRA-0002: чарты Hammurapi и публичный доступ ---

# kubeconform_file <файл> <метка>
kubeconform_file() {
  local out
  if out=$(kubeconform -strict -summary -kubernetes-version "$KUBE_VERSION" -skip CustomResourceDefinition \
    -schema-location default -schema-location "$OUT/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    -ignore-missing-schemas "$1" 2>&1); then
    pass "QUAL-02 $2: kubeconform — $(tail -1 <<<"$out")"
  else
    fail "QUAL-02 $2: kubeconform"
    echo "$out" | head -10 | sed 's/^/      /'
  fi
}

hammurapi_charts() {
  printf '\nчарты Hammurapi\n'
  local dir=$OUT/hammurapi c f bad
  mkdir -p "$dir"
  for c in hammurapi-core hammurapi-web; do
    f=$dir/$c.yaml
    if ! helm lint "$ROOT/charts/$c" --set image.tag=v1.8.0 --set publicBaseDomain=34-12-5-6.sslip.io >/dev/null 2>&1 ||
      ! helm template "$c" "$ROOT/charts/$c" -n hammurapi --kube-version "$KUBE_VERSION" \
        --set image.tag=v1.8.0 --set publicBaseDomain=34-12-5-6.sslip.io >"$f" 2>&1; then
      fail "QUAL-02 $c: helm lint/template"
      continue
    fi
    kubeconform_file "$f" "$c"
    # CH-04: запросы, лимиты, пробы у долгоживущих контейнеров, runAsNonRoot.
    bad=$(docs_json "$f" | jq -r '
      select(.kind | IN("Deployment", "Job", "CronJob"))
      | .kind as $k
      | (if $k == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end) as $s
      | "\($k)/\(.metadata.name)" as $o
      | $s.containers[]
      | [ (if (.resources.requests.cpu // "") == "" or (.resources.limits.memory // "") == "" then "ресурсы" else empty end),
          (if $k == "Deployment" and (.readinessProbe == null or .livenessProbe == null) then "пробы" else empty end),
          (if ((.securityContext.runAsNonRoot // $s.securityContext.runAsNonRoot // false) | not) then "runAsNonRoot" else empty end) ]
      | select(length > 0) | "\($o): \(join(", "))"')
    if [[ -n $bad ]]; then fail "CH-04 $c: $(echo "$bad" | tr '\n' ' ')"; else pass "CH-04 $c: запросы, лимиты, пробы, runAsNonRoot"; fi
  done
  # CH-07: Ingress api — только публичные префиксы; служебные порты не публикуются.
  local paths ports
  paths=$(docs_json "$dir/hammurapi-core.yaml" | jq -r 'select(.kind == "Ingress" and .metadata.name == "api") | .spec.rules[].http.paths[].path' | sort | tr '\n' ' ')
  ports=$(docs_json "$dir/hammurapi-core.yaml" | jq -r 'select(.kind == "Ingress") | .spec.rules[].http.paths[].backend.service.port.name' | sort -u | tr '\n' ' ')
  if [[ $paths == "/admin/api/ /api/ /hooks/ " && $ports == "http " ]]; then
    pass "CH-07: Ingress api — /api/, /admin/api/, /hooks/ на порт http"
  else
    fail "CH-07: пути «$paths», порты «$ports»"
  fi
  # R15: права worker на Job — только в hammurapi-runners.
  if docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Role" and .metadata.namespace == "hammurapi-runners")
      | .rules[] | select(.apiGroups == ["batch"]) | .resources == ["jobs"] and (.verbs | index("create"))' >/dev/null &&
    ! docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding")' >/dev/null; then
    pass "CH-03: worker создаёт Job только в hammurapi-runners"
  else
    fail "CH-03: права worker на Job"
  fi
  # HMR.CMN-0004: оператор агента получает только свой токен; к нему — api, worker
  # и задачи runner; к серверу рабочей копии задачи — только оператор.
  if docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Deployment" and .metadata.name == "agent")
      | .spec.template.spec.containers[0] | (.args == ["agent"]) and (.envFrom == null)
        and ([.env[] | select(.valueFrom) | .valueFrom.secretKeyRef.key] == ["AGENT_SERVICE_TOKEN"])' >/dev/null &&
    docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "agent")
      | .spec.ingress[0].ports == [{"port": 8090}]' >/dev/null &&
    docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "runner-workspace"
      and .metadata.namespace == "hammurapi-runners") | .spec.ingress[0].ports == [{"port": 8095}]' >/dev/null &&
    docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Service" and .metadata.name == "worker-mcp")' >/dev/null; then
    pass "HMR.CMN-0004: оператор агента, worker-mcp и сетевые политики"
  else
    fail "HMR.CMN-0004: оператор агента и сетевые политики"
  fi
  # Web получает адрес API на своём домене.
  if docs_json "$dir/hammurapi-web.yaml" | jq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[]
      | select(.name == "API_BASE_URL" and .value == "https://api.34-12-5-6.sslip.io")' >/dev/null; then
    pass "R17: web — API_BASE_URL https://api.<домен>"
  else
    fail "R17: web без API_BASE_URL"
  fi
}

public_access_charts() {
  printf '\nпубличный доступ\n'
  local dir=$OUT/public
  mkdir -p "$dir"
  if ! helm template traefik traefik/traefik --version "$TRAEFIK_CHART_VERSION" -n ingress --kube-version "$KUBE_VERSION" \
    -f "$ROOT/values/traefik.yaml" --set-string service.spec.loadBalancerIP=192.168.49.200 >"$dir/traefik.yaml" 2>&1; then
    fail "traefik: helm template: $(head -3 "$dir/traefik.yaml")"
  else
    kubeconform_file "$dir/traefik.yaml" traefik
    local args
    args=$(docs_json "$dir/traefik.yaml" | jq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[]')
    if grep -q 'redirections.entryPoint.scheme=https' <<<"$args" && grep -q 'allowACMEByPass=true' <<<"$args" &&
      docs_json "$dir/traefik.yaml" | jq -e 'select(.kind == "TLSStore") | .spec.defaultCertificate.secretName == "hammurapi-public"' >/dev/null; then
      pass "R19: HTTP → HTTPS, HTTP-01 мимо перенаправления, сертификат по умолчанию hammurapi-public"
    else
      fail "R19: настройки Traefik"
    fi
  fi
  if ! helm template cert-manager jetstack/cert-manager --version "$CERT_MANAGER_CHART_VERSION" -n cert-manager \
    --kube-version "$KUBE_VERSION" -f "$ROOT/values/cert-manager.yaml" >"$dir/cert-manager.yaml" 2>&1; then
    fail "cert-manager: helm template: $(head -3 "$dir/cert-manager.yaml")"
  else
    kubeconform_file "$dir/cert-manager.yaml" cert-manager
  fi
  RUN_DIR=$dir
  local missing
  missing=$(docs_json "$dir"/traefik.yaml "$dir"/cert-manager.yaml | jq -r '
    select(.kind | IN("Deployment", "Job")) | "\(.kind)/\(.metadata.name)" as $o
    | .spec.template.spec.containers[]
    | select((.resources.requests.memory // "") == "" or (.resources.limits.memory // "") == "") | "\($o)/\(.name)"')
  if [[ -n $missing ]]; then fail "RES-01 публичный доступ: $(echo "$missing" | tr '\n' ' ')"; else pass "RES-01 публичный доступ: запросы и лимиты"; fi
  # Ingress Grafana с GitHub OAuth (R20).
  PUBLIC_DOMAIN=34-12-5-6.sslip.io GRAFANA_GITHUB_CLIENT_ID=Iv1.x
  grafana_public_values "$dir/grafana-public.yaml"
  if helm template grafana grafana-community/grafana --version "$GRAFANA_CHART_VERSION" -n observability \
    --kube-version "$KUBE_VERSION" -f "$ROOT/values/grafana.yaml" -f "$dir/grafana-public.yaml" >"$dir/grafana.yaml" 2>&1 &&
    docs_json "$dir/grafana.yaml" | jq -e 'select(.kind == "Ingress") | .spec.rules[0].host == "grafana.34-12-5-6.sslip.io"' >/dev/null &&
    docs_json "$dir/grafana.yaml" | jq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "grafana")
      | .envFrom[]? | select(.secretRef.name == "grafana-github-oauth")' >/dev/null; then
    pass "R20: Ingress grafana.<домен>, секрет OAuth GitHub"
  else
    fail "R20: Grafana с публичным доступом: $(head -3 "$dir/grafana.yaml")"
  fi
}

main() {
  if [[ ${SKIP_REPOS:-0} != 1 ]]; then
    RUN_DIR=$OUT
    mkdir -p "$OUT"
    helm_repos
  fi
  local combo pg kafka s3 first=1
  for combo in iii iie iei iee eii eie eei eee; do
    pg=${combo:0:1} kafka=${combo:1:1} s3=${combo:2:1}
    POSTGRES_MODE=$([[ $pg == i ]] && echo internal || echo external)
    KAFKA_MODE=$([[ $kafka == i ]] && echo internal || echo external)
    S3_MODE=$([[ $s3 == i ]] && echo internal || echo external)
    POSTGRES_HOST=pg.example.internal POSTGRES_PORT=5432
    KAFKA_BOOTSTRAP=bootstrap.kafka.example.internal:9092
    S3_ENDPOINT=https://storage.googleapis.com
    local label="postgres=$POSTGRES_MODE kafka=$KAFKA_MODE s3=$S3_MODE" dir=$OUT/$combo
    printf '\n%s\n' "$label"
    (render "$dir") >/dev/null 2>&1 || {
      fail "рендер $label: $(tail -3 "$dir"/helm-*.log 2>/dev/null | tail -3)"
      continue
    }
    if ((first)); then
      crd_schemas "$dir"
      first=0
    fi
    kubeconform_dir "$dir" "$label"
    check_resources "$dir" "$label"
    check_service_types "$dir" "$label"
    check_storage_services "$dir" "$label"
    check_scrape_jobs "$dir" "$label"
    check_internal_releases "$dir" "$label"
  done

  printf '\nвнешний Postgres по IP\n'
  POSTGRES_MODE=external KAFKA_MODE=internal S3_MODE=internal POSTGRES_HOST=10.20.0.5
  (render "$OUT/ip") >/dev/null 2>&1 || true
  if docs_json "$OUT/ip/helm-storages.log" | jq -e 'select(.kind == "EndpointSlice" and .endpoints[0].addresses[0] == "10.20.0.5"
      and .metadata.labels["kubernetes.io/service-name"] == "postgres")' >/dev/null &&
    docs_json "$OUT/ip/helm-storages.log" | jq -e 'select(.kind == "Service" and .metadata.name == "postgres" and (.spec.selector == null))' >/dev/null; then
    pass "EXT-02: сервис postgres без селектора и EndpointSlice с 10.20.0.5"
  else
    fail "EXT-02: нет сервиса без селектора или EndpointSlice для IP"
  fi

  printf '\nсроки хранения\n'
  local vm vl
  vm=$(docs_json "$OUT/iii/helm-victoria-metrics.log" | jq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' | grep -c -- '-retentionPeriod=7d' || true)
  vl=$(docs_json "$OUT/iii/helm-victoria-logs.log" | jq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' | grep -c -- '-retentionPeriod=3d' || true)
  if [[ $vm == 1 && $vl == 1 ]]; then pass "OBS-02: retentionPeriod 7d и 3d"; else fail "OBS-02: retentionPeriod метрик/логов не 7d/3d"; fi
  POSTGRES_MODE=internal VM_RETENTION=14d VL_RETENTION=1d
  (render "$OUT/retention") >/dev/null 2>&1 || true
  vm=$(docs_json "$OUT/retention/helm-victoria-metrics.log" | jq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' | grep -c -- '-retentionPeriod=14d' || true)
  vl=$(docs_json "$OUT/retention/helm-victoria-logs.log" | jq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' | grep -c -- '-retentionPeriod=1d' || true)
  if [[ $vm == 1 && $vl == 1 ]]; then pass "OBS-02: значения из конфигурации применяются"; else fail "OBS-02: VM_RETENTION/VL_RETENTION не применились"; fi

  printf '\nлокальные чарты\n'
  if helm lint "$ROOT/charts/hammurapi-storages" --set kafka.version=4 --set postgres.image=x >/dev/null &&
    helm lint "$OUT/iii/work/hammurapi-dashboards" >/dev/null; then pass "QUAL-02: helm lint локальных чартов"; else fail "QUAL-02: helm lint"; fi

  hammurapi_charts
  public_access_charts

  if ((FAILURES)); then
    printf '\n%sНе прошло проверок: %d%s\n' "$C_RED" "$FAILURES" "$C_RESET"
    exit 1
  fi
  printf '\n%sВсе проверки манифестов прошли%s\n' "$C_GREEN" "$C_RESET"
}

main "$@"
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
    - web.$PUBLIC_DOMAIN
    - api.$PUBLIC_DOMAIN
    - grafana.$PUBLIC_DOMAIN
EOF
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
# (HMR.INFRA-0002). Устанавливает hammurapi-infra.sh up.
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
  log "сертификат для web., api., grafana.$PUBLIC_DOMAIN (${ACME_ISSUER:-letsencrypt})"
  if ! kc -n "$NS_INGRESS" wait certificate/hammurapi-public --for=condition=Ready --timeout=5m >/dev/null 2>&1; then
    kc -n "$NS_INGRESS" describe certificate hammurapi-public >"$RUN_DIR/certificate.txt" 2>&1 || true
    kc get challenges -A -o wide >>"$RUN_DIR/certificate.txt" 2>&1 || true
    die "$E_DEPLOY" "сертификат не выпущен за 5 минут: проверьте, что порты 80/443 машины открыты снаружи, а *.$PUBLIC_DOMAIN указывает на $PUBLIC_IP_RESOLVED (см. $RUN_DIR/certificate.txt)"
  fi
  ok "публичный доступ: https://{web,api,grafana}.$PUBLIC_DOMAIN"
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
    record public ok "https://{web,api,grafana}.$PUBLIC_DOMAIN через $LB_IP, HTTP → HTTPS"
  fi
}
