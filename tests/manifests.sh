#!/usr/bin/env bash
# Статические проверки манифестов (уровень I): рендер ровно тех релизов, что
# развернула бы `up`, для 8 комбинаций режимов хранилищ; kubeconform, запросы и
# лимиты, типы сервисов, задания сбора метрик, сервисы хранилищ, сроки хранения.
# Нужны: helm ≥ 3.17, kubeconform, jq, yq (mikefarah). Сеть — для чартов.
#   tests/manifests.sh            # все проверки
#   SKIP_REPOS=1 tests/manifests.sh   # без helm repo add/update
set -euo pipefail
# SC2034: переменные конфигурации читают подключённые функции lib/*.sh.
# shellcheck disable=SC2034

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
  expected=$(expected_jobs | sort | tr '\n' ' ')
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

  if ((FAILURES)); then
    printf '\n%sНе прошло проверок: %d%s\n' "$C_RED" "$FAILURES" "$C_RESET"
    exit 1
  fi
  printf '\n%sВсе проверки манифестов прошли%s\n' "$C_GREEN" "$C_RESET"
}

main "$@"
