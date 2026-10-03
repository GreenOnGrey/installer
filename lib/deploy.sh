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
  done
  retry 3 15 helm repo update >/dev/null || die "$E_DEPLOY" "helm repo update не выполнен"
}

# release <релиз> <ns> <чарт> <версия|-> <файл значений|-> [аргументы helm…]
release() {
  local name=$1 ns=$2 chart=$3 version=$4 values=$5
  shift 5
  local args=(upgrade --install "$name" "$chart" -n "$ns" --wait --timeout "$HELM_TIMEOUT")
  [[ $version != - ]] && args+=(--version "$version")
  [[ $values != - ]] && args+=(-f "$ROOT/values/$values")
  if [[ $version == - ]]; then log "релиз $name (локальный чарт)"; else log "релиз $name ($chart $version)"; fi
  if ! run_cmd hm "${args[@]}" "$@" >"$RUN_DIR/helm-$name.log" 2>&1; then
    die "$E_DEPLOY" "релиз $name не развёрнут, см. $RUN_DIR/helm-$name.log"
  fi
  RELEASES+=("$name $version")
}

# uninstall_if_present <релиз> <ns> — для хранилищ, переведённых во внешний режим.
uninstall_if_present() {
  if hm status "$1" -n "$2" >/dev/null 2>&1; then
    log "удаление релиза $1: хранилище во внешнем режиме"
    hm uninstall "$1" -n "$2" --wait --timeout "$HELM_TIMEOUT" >/dev/null ||
      die "$E_DEPLOY" "не удалось удалить релиз $1"
  fi
}

wait_crd() {
  kc wait --for=condition=Established "crd/$1" --timeout=120s >/dev/null ||
    die "$E_DEPLOY" "CRD $1 не зарегистрирован"
}

deploy_operators() {
  local ns=$NS_STORAGES
  if [[ $KAFKA_MODE == internal ]]; then
    release strimzi "$ns" strimzi/strimzi-kafka-operator "$STRIMZI_CHART_VERSION" strimzi.yaml
    wait_crd kafkas.kafka.strimzi.io
    wait_crd kafkanodepools.kafka.strimzi.io
  fi
  if [[ $POSTGRES_MODE == internal ]]; then
    release cnpg "$ns" cnpg/cloudnative-pg "$CNPG_CHART_VERSION" cnpg.yaml
    wait_crd clusters.postgresql.cnpg.io
  fi
}

storages_args() {
  local args=(
    --set "postgres.mode=$POSTGRES_MODE" --set "kafka.mode=$KAFKA_MODE" --set "s3.mode=$S3_MODE"
    --set-string "postgres.image=$POSTGRES_IMAGE" --set-string "kafka.version=$KAFKA_VERSION"
    --set "postgres.storage=$PG_STORAGE" --set "kafka.storage=$KAFKA_STORAGE"
    --set-string "postgres.database=$PG_DATABASE" --set-string "postgres.owner=$PG_USER"
  )
  printf '%s\n' "${args[@]}"
  external_values
}

deploy_storages() {
  local ns=$NS_STORAGES args
  if [[ $S3_MODE == internal ]]; then
    release seaweedfs "$ns" seaweedfs/seaweedfs "$SEAWEEDFS_CHART_VERSION" seaweedfs.yaml \
      --set "allInOne.data.size=$S3_STORAGE" --set-string "allInOne.s3.createBuckets[0].name=$S3_BUCKET"
  else
    uninstall_if_present seaweedfs "$ns"
  fi
  mapfile -t args < <(storages_args)
  release storages "$ns" "$ROOT/charts/hammurapi-storages" - - "${args[@]}"
  RELEASES[-1]="storages локальный"
  if [[ $KAFKA_MODE == internal ]]; then
    log "ожидание Kafka"
    kc -n "$ns" wait kafka/hammurapi --for=condition=Ready --timeout="$HELM_TIMEOUT" >/dev/null ||
      die "$E_DEPLOY" "Kafka не перешла в Ready"
  else
    uninstall_if_present strimzi "$ns"
  fi
  if [[ $POSTGRES_MODE == internal ]]; then
    log "ожидание Postgres"
    kc -n "$ns" wait cluster.postgresql.cnpg.io/hammurapi-pg --for=condition=Ready --timeout="$HELM_TIMEOUT" >/dev/null ||
      die "$E_DEPLOY" "Postgres не перешёл в Ready"
  else
    uninstall_if_present cnpg "$ns"
  fi
}

# vmagent_scrape_values <файл> — задания сбора текущей конфигурации (R8).
vmagent_scrape_values() {
  {
    printf 'config:\n  scrape_configs:\n'
    cat "$ROOT/values/scrape/base.yaml"
    # Hammurapi (HMR.INFRA-0002): не обязателен в проверках, пока не установлен.
    cat "$ROOT/values/scrape/hammurapi.yaml"
    [[ $KAFKA_MODE == internal ]] && cat "$ROOT/values/scrape/kafka.yaml"
    [[ $POSTGRES_MODE == internal ]] && cat "$ROOT/values/scrape/postgres.yaml"
    [[ $S3_MODE == internal ]] && cat "$ROOT/values/scrape/s3.yaml"
    [[ $KAFKA_MODE == internal || $POSTGRES_MODE == internal ]] && cat "$ROOT/values/scrape/operators.yaml"
    true
  } >"$1"
}

# stage_dashboards <каталог> — копия чарта дашбордов с JSON из dashboards/.
stage_dashboards() {
  local dir=$1
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -r "$ROOT/charts/hammurapi-dashboards/." "$dir/"
  mkdir -p "$dir/files"
  cp "$ROOT"/dashboards/*.json "$dir/files/"
}

deploy_observability() {
  local ns=$NS_OBSERVABILITY
  release victoria-metrics "$ns" vm/victoria-metrics-single "$VM_SINGLE_CHART_VERSION" victoria-metrics.yaml \
    --set-string "server.retentionPeriod=$VM_RETENTION" --set "server.persistentVolume.size=$VM_STORAGE"
  release victoria-logs "$ns" vm/victoria-logs-single "$VL_SINGLE_CHART_VERSION" victoria-logs.yaml \
    --set-string "server.retentionPeriod=$VL_RETENTION" --set "server.persistentVolume.size=$VL_STORAGE"
  release kube-state-metrics "$ns" prometheus-community/kube-state-metrics "$KSM_CHART_VERSION" kube-state-metrics.yaml
  release node-exporter "$ns" prometheus-community/prometheus-node-exporter "$NODE_EXPORTER_CHART_VERSION" node-exporter.yaml
  vmagent_scrape_values "$RUN_DIR/vmagent-scrape.yaml"
  release vmagent "$ns" vm/victoria-metrics-agent "$VMAGENT_CHART_VERSION" vmagent.yaml -f "$RUN_DIR/vmagent-scrape.yaml"
  release vector "$ns" vector/vector "$VECTOR_CHART_VERSION" vector.yaml
  # Публичный доступ: Ingress Grafana и вход через GitHub (HMR.INFRA-0002, R20).
  local grafana_public=()
  if public_enabled; then
    grafana_public_values "$RUN_DIR/grafana-public.yaml"
    grafana_public=(-f "$RUN_DIR/grafana-public.yaml")
  fi
  release grafana "$ns" grafana-community/grafana "$GRAFANA_CHART_VERSION" grafana.yaml \
    --set-string "grafana\.ini.plugins.preinstall_sync=victoriametrics-logs-datasource@$VL_PLUGIN_VERSION" \
    --set "persistence.size=$GRAFANA_STORAGE" "${grafana_public[@]}"
  stage_dashboards "$WORK_DIR/hammurapi-dashboards"
  release dashboards "$ns" "$WORK_DIR/hammurapi-dashboards" - -
  RELEASES[-1]="dashboards локальный"
}

deploy_all() {
  step deploy
  helm_repos
  deploy_operators
  ensure_secrets
  ensure_public_secrets
  check_external
  public_prepare
  step deploy
  deploy_storages
  deploy_observability
  deploy_public
  step deploy
  ok "все релизы развёрнуты"
}

# write_version — развёрнутый тег и коммит в ConfigMap (R18). На проде кода
# из git нет (выгрузка тега от workflow) — тег и коммит приходят в INFRA_TAG и
# INFRA_COMMIT; в рабочей копии git они берутся из неё.
write_version() {
  local tag commit
  tag=${INFRA_TAG:-$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || echo dev)}
  commit=${INFRA_COMMIT:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}
  commit=${commit:0:7}
  kc -n "$NS_OBSERVABILITY" create configmap hammurapi-infra-version \
    --from-literal="tag=$tag" --from-literal="commit=$commit" \
    --from-literal="deployedAt=$(now_utc)" --from-literal="deployedBy=${DEPLOYED_BY:-$(id -un)}" \
    --dry-run=client -o yaml | apply_stdin
  DEPLOYED_TAG=$tag
}
