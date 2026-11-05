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
# shellcheck source=../lib/mcp.sh
source "$ROOT/lib/mcp.sh"
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

# resources_missing <файлы…> — контейнеры без запросов или лимитов.
resources_missing() {
  docs_json "$@" | jq -r '
    select(.kind | IN("Deployment", "StatefulSet", "DaemonSet", "Job", "Pod", "CronJob"))
    | (if .kind == "Pod" then .spec elif .kind == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end) as $s
    | "\(.kind)/\(.metadata.name)" as $o
    | (($s.containers // []) + ($s.initContainers // []))[]
    | select((.resources.requests.cpu // "") == "" or (.resources.requests.memory // "") == ""
        or (.resources.limits.cpu // "") == "" or (.resources.limits.memory // "") == "")
    | "\($o)/\(.name)"'
}

check_resources() {
  local dir=$1 missing
  missing=$(resources_missing "$dir"/helm-*.log)
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
  # hammurapi и mcp (values/scrape/hammurapi.yaml) — всегда в конфигурации, но не обязательны в
  # проверках стенда: целей у них нет, пока не развёрнуты Hammurapi, Nabu и MCP-серверы.
  expected=$({ expected_jobs; echo hammurapi; echo mcp; } | sort | tr '\n' ' ')
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

# --- FTR.NAB.CMN-0006: MCP-серверы ---

# mcp_chart — закреплённая версия чарта загружается без учётных данных и рендерится со
# значениями инсталлятора; сам чарт проверяет репозиторий mcps.
mcp_chart() {
  printf '\nMCP-серверы\n'
  local f=$OUT/mcp-servers.yaml args=() deps want srv
  MCP_DOCLING=true MCP_SEARCH=true MCP_YANDEX_MAIL=true MCP_DOCGEN=true
  mcp_load
  mapfile -t args < <(mcp_helm_args)
  if ! helm template "$MCP_RELEASE" "$MCP_CHART_DIR" -n mcp --kube-version "$KUBE_VERSION" "${args[@]}" >"$f" 2>&1; then
    fail "MCP-01: чарт mcp-servers $MCP_CHART_VERSION не рендерится: $(tail -1 "$f")"
    return
  fi
  kubeconform_file "$f" "mcp-servers"
  deps=$(docs_json "$f" | jq -r 'select(.kind == "Deployment") | .metadata.name' | sort | tr '\n' ' ')
  want=$(for srv in "${MCP_SERVERS[@]}"; do tr ' ' '\n' <<<"${MCP_DEPLOYMENTS[$srv]}"; done | sort | tr '\n' ' ')
  if [[ $deps == "$want" ]]; then
    pass "MCP-01: чарт $MCP_CHART_VERSION и его описания: $deps"
  else
    fail "MCP-01: Deployment'ы чарта «$deps», в описаниях «$want»"
  fi
  MCP_DOCLING=false MCP_SEARCH=false MCP_YANDEX_MAIL=false MCP_DOCGEN=false
}

# --- FTR.HMR.INFRA-0002: чарты Hammurapi и публичный доступ ---

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

# nabu_charts — чарты Nabu на том же стенде (FTR.NAB.CMN-0001 arch §11).
nabu_charts() {
  printf '\nчарты Nabu\n'
  local dir=$OUT/nabu c f bad
  mkdir -p "$dir"
  for c in nabu-core nabu-web; do
    f=$dir/$c.yaml
    if ! helm lint "$ROOT/charts/$c" --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io >/dev/null 2>&1 ||
      ! helm template "$c" "$ROOT/charts/$c" -n nabu --kube-version "$KUBE_VERSION" \
        --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io >"$f" 2>&1; then
      fail "QUAL-02 $c: helm lint/template"
      continue
    fi
    kubeconform_file "$f" "$c"
    bad=$(docs_json "$f" | jq -r '
      select(.kind | IN("Deployment", "Job", "CronJob"))
      | .kind as $k
      | (if $k == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end) as $s
      | "\($k)/\(.metadata.name)" as $o
      | $s.containers[]
      | [ (if (.resources.requests.cpu // "") == "" or (.resources.limits.memory // "") == "" then "ресурсы" else empty end),
          (if ((.securityContext.runAsNonRoot // $s.securityContext.runAsNonRoot // false) | not) then "runAsNonRoot" else empty end) ]
      | select(length > 0) | "\($o): \(join(", "))"')
    if [[ -n $bad ]]; then fail "RES-01 $c: $(echo "$bad" | tr '\n' ' ')"; else pass "RES-01 $c: запросы, лимиты, runAsNonRoot"; fi
  done
  # Хосты nabu. и nabu-api. того же домена; API без служебных портов.
  local hosts
  hosts=$(docs_json "$dir"/nabu-*.yaml | jq -r 'select(.kind == "Ingress") | .spec.rules[].host' | sort -u | tr '\n' ' ')
  if [[ $hosts == "nabu-api.34-12-5-6.sslip.io nabu.34-12-5-6.sslip.io " ]]; then
    pass "R29: Ingress nabu.<домен> и nabu-api.<домен>"
  else
    fail "R29: хосты Nabu «$hosts»"
  fi
  # FTR.NAB.CMN-0008: профили песочниц по тегу nabu и предзагрузка их образов worker'ом.
  local profiles verbs
  profiles=$(docs_json "$dir/nabu-core.yaml" | jq -r 'select(.kind == "Deployment" and .metadata.name == "worker")
    | .spec.template.spec.containers[0].env[] | select(.name == "SANDBOX_PROFILES") | .value')
  verbs=$(docs_json "$dir/nabu-core.yaml" | jq -r 'select(.kind == "Role" and .metadata.name == "nabu-sandboxes")
    | .rules[] | select(.resources == ["daemonsets"]) | .verbs | join(",")')
  if [[ $profiles == *"documents=ghcr.io/greenongrey/nabu-sandbox-documents:v1.0.0"* && $verbs == "get,list,watch,create,update" ]]; then
    pass "PRE-04: SANDBOX_PROFILES с тегом nabu, worker управляет DaemonSet в namespace песочниц"
  else
    fail "PRE-04: профили «$profiles», права на daemonsets «$verbs»"
  fi
  # FTR.HMR.CMN-0007 PF-03, PX-13: профиль code и шлюз egress; песочницы с прокси
  # ходят только к шлюзу, снаружи канал рабочих пространств закрыт.
  if [[ $profiles == *"code=ghcr.io/greenongrey/nabu-sandbox-code:v1.0.0"* ]] &&
    docs_json "$dir/nabu-core.yaml" | jq -e 'select(.kind == "Deployment" and .metadata.name == "egress")
      | .spec.template.spec.containers[0].args == ["egress"]' >/dev/null &&
    docs_json "$dir/nabu-core.yaml" | jq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "sandboxes-egress")
      | .spec.egress[0].ports == [{"port": 3128}]' >/dev/null &&
    docs_json "$dir/nabu-core.yaml" | jq -e 'select(.kind == "Deployment" and .metadata.name == "worker")
      | .spec.template.spec.containers[0].env[] | select(.name == "EGRESS_URL")' >/dev/null &&
    ! docs_json "$dir/nabu-core.yaml" | jq -e 'select(.kind == "Ingress") | .spec.rules[].http.paths[] | select(.backend.service.name == "relay")' >/dev/null; then
    pass "PF-03, PX-13: профиль code, шлюз egress и его сетевые политики"
  else
    fail "PF-03, PX-13: профиль code или шлюз egress"
  fi
  # Без профилей — один образ nabu-core, как до FTR.NAB.CMN-0008 (tech §9).
  local legacy
  legacy=$(helm template nabu-core "$ROOT/charts/nabu-core" -n nabu --kube-version "$KUBE_VERSION" --set image.tag=v1.0.0 \
    --set publicBaseDomain=34-12-5-6.sslip.io --set sandboxes.profiles=null --set sandboxes.defaults=null 2>&1 |
    docs_json | jq -r 'select(.kind == "Deployment" and .metadata.name == "worker") | .spec.template.spec.containers[0].env[]
      | select(.name | IN("SANDBOX_PROFILES", "SANDBOX_DEFAULTS", "SANDBOX_IMAGE")) | "\(.name)=\(.value)"' | tr '\n' ' ')
  if [[ $legacy == "SANDBOX_IMAGE=ghcr.io/greenongrey/nabu-core:v1.0.0 " ]]; then
    pass "PRE-04: без профилей — один образ nabu-core"
  else
    fail "PRE-04 без профилей: «$legacy»"
  fi
}

# landing_chart — сайт GreenOnGrey на том же стенде (FTR.LND.WEB-0001 arch §7).
landing_chart() {
  printf '\nчарт landing\n'
  local dir=$OUT/landing f bad hosts site
  mkdir -p "$dir"
  f=$dir/landing.yaml
  if ! helm lint "$ROOT/charts/landing" --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io >/dev/null 2>&1 ||
    ! helm template landing "$ROOT/charts/landing" -n landing --kube-version "$KUBE_VERSION" \
      --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io >"$f" 2>&1; then
    fail "LND-38 QUAL-02 landing: helm lint/template"
    return
  fi
  kubeconform_file "$f" "LND-38 landing"
  bad=$(docs_json "$f" | jq -r '
    select(.kind == "Deployment")
    | .spec.template.spec as $s
    | "\(.kind)/\(.metadata.name)" as $o
    | $s.containers[]
    | [ (if (.resources.requests.cpu // "") == "" or (.resources.limits.memory // "") == "" then "ресурсы" else empty end),
        (if ((.securityContext.runAsNonRoot // $s.securityContext.runAsNonRoot // false) | not) then "runAsNonRoot" else empty end) ]
    | select(length > 0) | "\($o): \(join(", "))"')
  if [[ -n $bad ]]; then fail "LND-38 RES-01 landing: $(echo "$bad" | tr '\n' ' ')"; else pass "LND-38 RES-01 landing: запросы, лимиты, runAsNonRoot"; fi
  # Хост web.<домен>, и тот же адрес сайт получает в SITE_URL.
  hosts=$(docs_json "$f" | jq -r 'select(.kind == "Ingress") | .spec.rules[].host' | tr '\n' ' ')
  site=$(docs_json "$f" | jq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SITE_URL") | .value')
  if [[ $hosts == "web.34-12-5-6.sslip.io " && $site == "https://web.34-12-5-6.sslip.io" ]]; then
    pass "LND-38 R26: Ingress web.<домен>, SITE_URL сайта — тот же адрес"
  else
    fail "LND-38 R26: хост «$hosts», SITE_URL «$site»"
  fi
  # Собственный домен: адрес сайта — домен, отдельный сертификат на домен и www.,
  # перенаправление с www., прежний хост стенда остаётся.
  local own=$dir/landing-domain.yaml names regex
  if ! helm template landing "$ROOT/charts/landing" -n landing --kube-version "$KUBE_VERSION" \
    --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io --set domain=example.org \
    --set issuer=letsencrypt-staging >"$own" 2>&1; then
    fail "LND-40 landing с доменом: helm template"
    return
  fi
  kubeconform_file "$own" "LND-40 landing с доменом"
  hosts=$(docs_json "$own" | jq -r 'select(.kind == "Ingress") | .spec.rules[].host' | sort | tr '\n' ' ')
  site=$(docs_json "$own" | jq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SITE_URL") | .value')
  names=$(docs_json "$own" | jq -r 'select(.kind == "Certificate") | "\(.spec.issuerRef.name): \(.spec.dnsNames | join(" "))"')
  regex=$(docs_json "$own" | jq -r 'select(.kind == "Middleware") | .spec.redirectRegex | "\(.regex) -> \(.replacement)"')
  # shellcheck disable=SC2016 # ${1} — подстановка Traefik, а не shell
  if [[ $hosts == "example.org web.34-12-5-6.sslip.io www.example.org " && $site == "https://example.org" &&
    $names == "letsencrypt-staging: example.org www.example.org" &&
    $regex == '^https?://www\.example\.org/(.*) -> https://example.org/${1}' ]]; then
    pass "LND-40: домен и www. в Ingress и сертификате, SITE_URL — домен, www. перенаправляется"
  else
    fail "LND-40: хосты «$hosts», SITE_URL «$site», сертификат «$names», перенаправление «$regex»"
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
  # /mcp/nabu — MCP для персональных агентов Nabu с их JWT (FTR.HMR.CMN-0006 R7).
  local paths ports
  paths=$(docs_json "$dir/hammurapi-core.yaml" | jq -r 'select(.kind == "Ingress" and .metadata.name == "api") | .spec.rules[].http.paths[].path' | sort | tr '\n' ' ')
  ports=$(docs_json "$dir/hammurapi-core.yaml" | jq -r 'select(.kind == "Ingress") | .spec.rules[].http.paths[].backend.service.port.name' | sort -u | tr '\n' ' ')
  if [[ $paths == "/admin/api/ /api/ /hooks/ /mcp/nabu " && $ports == "http " ]]; then
    pass "CH-07: Ingress api — /api/, /admin/api/, /hooks/, /mcp/nabu на порт http"
  else
    fail "CH-07: пути «$paths», порты «$ports»"
  fi
  # FTR.HMR.CMN-0007 HN-08: агента и runner в Hammurapi нет — ни оператора, ни ролей
  # на Job, ни внутреннего API; служебные агенты Nabu ходят в worker-mcp.
  if ! docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding")' >/dev/null &&
    ! docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Deployment" and .metadata.name == "agent")' >/dev/null &&
    ! docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Service" and .metadata.name == "api-internal")' >/dev/null &&
    docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Service" and .metadata.name == "worker-mcp")' >/dev/null; then
    pass "HN-08: без оператора агента, runner и прав в Kubernetes; worker-mcp на месте"
  else
    fail "HN-08: в hammurapi-core остались агент, runner или их права"
  fi
  # Удалённый ServiceAccount worker не должен вернуться через устаревшее поле
  # serviceAccount живого Deployment: имя задано явно.
  if docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Deployment" and .metadata.name == "worker")
      | .spec.template.spec.serviceAccountName == "default"' >/dev/null; then
    pass "HN-08: worker явно работает под ServiceAccount default"
  else
    fail "HN-08: у worker не задан serviceAccountName: default"
  fi
  # Web получает адрес API на своём домене.
  if docs_json "$dir/hammurapi-web.yaml" | jq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[]
      | select(.name == "API_BASE_URL" and .value == "https://hammurapi-api.34-12-5-6.sslip.io")' >/dev/null; then
    pass "R17: web — API_BASE_URL https://hammurapi-api.<домен>"
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
    # Вывод рендера — в журнал рядом с каталогом комбинации (render очищает каталог):
    # при ошибке видно, что сломалось, например загрузка внешнего чарта.
    (render "$dir") >"$OUT/render-$combo.log" 2>&1 || {
      fail "рендер $label: $(tail -5 "$OUT/render-$combo.log" "$dir"/helm-*.log 2>/dev/null | grep -v '^==>' | grep -v '^$' | tail -5 | tr '\n' ' ')"
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
  nabu_charts
  landing_chart
  public_access_charts
  mcp_chart

  if ((FAILURES)); then
    printf '\n%sНе прошло проверок: %d%s\n' "$C_RED" "$FAILURES" "$C_RESET"
    exit 1
  fi
  printf '\n%sВсе проверки манифестов прошли%s\n' "$C_GREEN" "$C_RESET"
}

main "$@"
