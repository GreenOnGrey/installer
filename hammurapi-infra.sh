#!/usr/bin/env bash
# Демо-стенд Hammurapi на minikube (FTR.HMR.INFRA-0001): хранилища и наблюдаемость.
#   ./hammurapi-infra.sh up | status | creds | down | help
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/host.sh
source "$ROOT/lib/host.sh"
# shellcheck source=lib/prereqs.sh
source "$ROOT/lib/prereqs.sh"
# shellcheck source=lib/cluster.sh
source "$ROOT/lib/cluster.sh"
# shellcheck source=lib/secrets.sh
source "$ROOT/lib/secrets.sh"
# shellcheck source=lib/external.sh
source "$ROOT/lib/external.sh"
# shellcheck source=lib/checks.sh
source "$ROOT/lib/checks.sh"
# shellcheck source=lib/deploy.sh
source "$ROOT/lib/deploy.sh"
# shellcheck source=lib/public.sh
source "$ROOT/lib/public.sh"
# shellcheck source=lib/mcp.sh
source "$ROOT/lib/mcp.sh"

usage() {
  cat <<'EOF'
Использование: ./hammurapi-infra.sh <команда> [флаги]

Команды:
  up       проверка машины, зависимости, кластер, развёртывание, проверки, сводка
  status   состояние кластера и компонентов, проверки стенда, ресурсы
  creds    адреса, имена секретов и пароли из секретов Kubernetes
  down     удаление профиля minikube со всеми данными (с подтверждением)
  help     эта справка

Флаги:
  --config <файл>  файл переопределений (по умолчанию config/local.env)
  --yes            down: не спрашивать подтверждение
  --json           status, creds: вывод в JSON
  --verbose        подробный вывод команд
  --no-color       без цвета (включается сам, если вывод не в терминал)
EOF
}

usage_error() {
  printf 'Ошибка: %s\n\n' "$1" >&2
  usage >&2
  exit "$E_USAGE"
}

COMMAND="" CONFIG_FILE="" ASSUME_YES=0 JSON=0

parse_args() {
  while (($#)); do
    case $1 in
      up | status | creds | down | help)
        [[ -n $COMMAND ]] && usage_error "лишняя команда: $1"
        COMMAND=$1
        ;;
      --config)
        [[ $# -ge 2 ]] || usage_error "--config требует путь к файлу"
        CONFIG_FILE=$2
        shift
        ;;
      --config=*) CONFIG_FILE=${1#--config=} ;;
      --yes) ASSUME_YES=1 ;;
      --json) JSON=1 ;;
      --verbose) VERBOSE=1 ;;
      --no-color) COLOR=0 ;;
      -h | --help) COMMAND=help ;;
      *) usage_error "неизвестная команда или флаг: $1" ;;
    esac
    shift
  done
  [[ -n $COMMAND ]] || usage_error "не указана команда"
  [[ $ASSUME_YES == 1 && $COMMAND != down ]] && usage_error "--yes допустим только для down"
  [[ $JSON == 1 && $COMMAND != status && $COMMAND != creds ]] && usage_error "--json допустим только для status и creds"
  if [[ -n $CONFIG_FILE && ! -f $CONFIG_FILE ]]; then usage_error "нет файла конфигурации $CONFIG_FILE"; fi
  CONFIG_FILE=${CONFIG_FILE:-$ROOT/config/local.env}
  return 0
}

# --- up ---

acquire_lock() {
  if [[ ! -w $LOCK_FILE ]]; then
    as_root touch "$LOCK_FILE"
    as_root chmod 0666 "$LOCK_FILE"
  fi
  exec 9>>"$LOCK_FILE"
  flock -n 9 || die "$E_LOCKED" "уже выполняется другой запуск up на этой машине ($LOCK_FILE)"
}

collect_diagnostics() {
  have kubectl || return 0
  kc get nodes >/dev/null 2>&1 || return 0
  local dir=$RUN_DIR/diagnostics pod ns rel
  mkdir -p "$dir"
  kc get events -A --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1 || true
  kc get pods -A -o wide >"$dir/pods.txt" 2>&1 || true
  for ns in "$NS_STORAGES" "$NS_OBSERVABILITY"; do
    while read -r pod; do
      [[ -n $pod ]] || continue
      kc -n "$ns" describe pod "$pod" >"$dir/describe-$ns-$pod.txt" 2>&1 || true
      # Логи всех контейнеров: текущий запуск и предыдущий (для CrashLoopBackOff).
      kc -n "$ns" logs "$pod" --all-containers --prefix --tail=300 >"$dir/logs-$ns-$pod.txt" 2>&1 || true
      kc -n "$ns" logs "$pod" --all-containers --prefix --tail=300 --previous >"$dir/logs-$ns-$pod-previous.txt" 2>&1 || true
    done < <(kc -n "$ns" get pods --no-headers 2>/dev/null |
      awk '{split($2, r, "/"); if (r[1] != r[2] && $3 != "Completed") print $1}')
  done
  while read -r rel ns; do
    [[ -n $rel ]] && hm status "$rel" -n "$ns" >"$dir/helm-status-$rel.txt" 2>&1 || true
  done < <(hm list -A -o json 2>/dev/null | jq -r '.[] | "\(.name) \(.namespace)"' 2>/dev/null)
  warn "диагностика сохранена в $dir"
}

on_up_exit() {
  local code=$1
  if ((code != 0)); then
    STEP=main
    collect_diagnostics
    warn "up завершилась с кодом $code; журнал: $RUN_DIR/run.log"
  fi
}

print_summary() {
  local took=$((SECONDS - UP_STARTED)) mode r name ver
  mode="Postgres: $(mode_ru "$POSTGRES_MODE"), Kafka: $(mode_ru "$KAFKA_MODE"), S3: $(mode_ru "$S3_MODE")"
  local ns=$NS_STORAGES res
  res=$(resources_line)
  cat <<EOF

Стенд готов за $(human_duration "$took"). Версия: ${DEPLOYED_TAG:-dev}.

Кластер       minikube $MK_PROFILE (Kubernetes $K8S_VERSION), $MK_CPUS CPU / ${MK_MEMORY^^}
Хранилища     postgres.$ns.svc:5432  kafka.$ns.svc:9092  s3.$ns.svc:9000
              ($mode)
Наблюдаемость Grafana, VictoriaMetrics, VictoriaLogs в namespace $NS_OBSERVABILITY
Ресурсы       $res

Версии        Kafka $KAFKA_VERSION, Postgres ${POSTGRES_IMAGE##*:}, Grafana-плагин VictoriaLogs $VL_PLUGIN_VERSION
EOF
  for r in "${RELEASES[@]}"; do
    read -r name ver <<<"$r"
    printf '              %-20s %s\n' "$name" "$ver"
  done
  cat <<EOF

Grafana:
  на своей машине:  ssh -L $GRAFANA_LOCAL_PORT:localhost:$GRAFANA_LOCAL_PORT $(id -un)@<адрес машины>
  на машине стенда: kubectl --context $MK_PROFILE -n $NS_OBSERVABILITY port-forward svc/grafana $GRAFANA_LOCAL_PORT:80
  затем откройте http://localhost:$GRAFANA_LOCAL_PORT

Пароли: ./hammurapi-infra.sh creds
EOF
  if public_enabled; then
    cat <<EOF

Публичный доступ (сертификат ${ACME_ISSUER:-letsencrypt}):
  https://grafana.$PUBLIC_DOMAIN   https://${HAMMURAPI_WEB_HOST:-hammurapi}.$PUBLIC_DOMAIN   https://${HAMMURAPI_API_HOST:-hammurapi-api}.$PUBLIC_DOMAIN
  порты 80/443 машины → Traefik $LB_IP; откройте их в межсетевом экране облака
EOF
  fi
}

mode_ru() { if [[ $1 == internal ]]; then echo встроенный; else echo внешний; fi; }

resources_line() {
  local pct=0
  ((MEM_ALLOCATABLE > 0)) && pct=$((MEM_REQUESTED * 100 / MEM_ALLOCATABLE))
  echo "запрошено $(gib "$MEM_REQUESTED") ГиБ из $(gib "$MEM_ALLOCATABLE") ГиБ ($pct %)"
}

cmd_up() {
  UP_STARTED=$SECONDS
  RUN_DIR="$ROOT/logs/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$RUN_DIR"
  exec > >(tee -a "$RUN_DIR/run.log") 2>&1
  trap 'on_up_exit $?' EXIT
  log "журнал запуска: $RUN_DIR/run.log"
  check_host
  acquire_lock
  install_prereqs
  cluster_up
  deploy_all
  if ! run_checks; then
    die "$E_CHECKS" "проверки стенда не прошли: $(first_failure)"
  fi
  write_version
  print_summary
}

# --- status ---

# public_status_json — публичный доступ по данным кластера (ConfigMap стенда).
public_status_json() {
  local data
  data=$(kc -n ingress get configmap hammurapi-infra-public -o json 2>/dev/null | jq -c '.data // {}' 2>/dev/null || true)
  if [[ -z $data || $data == "{}" ]]; then
    echo '{"enabled":false}'
  else
    jq -c '{enabled: true, baseDomain, publicIp, lbIp, issuer}' <<<"$data"
  fi
}

deployed_version() {
  kc -n "$NS_OBSERVABILITY" get configmap hammurapi-infra-version -o json 2>/dev/null | jq -c '.data' 2>/dev/null || echo null
}

cmd_status() {
  RUN_DIR=$WORK_DIR
  local running=0 profile_status
  if have minikube && cluster_running; then running=1; fi
  profile_status=$([[ $running == 1 ]] && echo Running || echo Stopped)
  if [[ $running == 1 ]]; then
    run_checks || true
  else
    CHECK_RESULTS=("cluster|fail|кластер $MK_PROFILE не запущен")
  fi
  local failed=0 r
  for r in "${CHECK_RESULTS[@]}"; do [[ $r == *"|fail|"* ]] && failed=1; done
  if [[ $JSON == 1 ]]; then
    status_json "$profile_status" "$running"
  else
    status_text "$profile_status" "$running"
  fi
  ((failed == 0)) || exit "$E_CHECKS"
}

checks_json() {
  local r name state msg
  for r in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r name state msg <<<"$r"
    jq -cn --arg n "$name" --arg s "$state" --arg m "$msg" '{name: $n, ok: ($s == "ok"), message: $m}'
  done | jq -cs .
}

status_json() {
  local profile_status=$1 running=$2 releases='[]' pods='[]' version=null public='{"enabled":false}'
  if [[ $running == 1 ]]; then
    releases=$(hm list -A -o json 2>/dev/null | jq -c '[.[] | {name, namespace, chart, app_version, status, revision}]' || echo '[]')
    pods=$(kc get pods -n "$NS_STORAGES" -o json 2>/dev/null; kc get pods -n "$NS_OBSERVABILITY" -o json 2>/dev/null)
    pods=$(jq -cs '[.[].items[] | {namespace: .metadata.namespace, name: .metadata.name, phase: .status.phase,
      ready: ([.status.containerStatuses[]?.ready] | all)}]' <<<"$pods")
    version=$(deployed_version)
    public=$(public_status_json)
  fi
  jq -n --arg profile "$MK_PROFILE" --arg st "$profile_status" --arg k8s "$K8S_VERSION" \
    --argjson version "$version" --argjson releases "$releases" --argjson pods "$pods" --argjson public "$public" \
    --argjson checks "$(checks_json)" --argjson req "$MEM_REQUESTED" --argjson alloc "$MEM_ALLOCATABLE" \
    --argjson mcp "$(mcp_status_json)" \
    --arg pg "$POSTGRES_MODE" --arg kafka "$KAFKA_MODE" --arg s3 "$S3_MODE" \
    '{profile: {name: $profile, status: $st, kubernetes: $k8s}, version: $version,
      storages: {postgres: $pg, kafka: $kafka, s3: $s3}, public: $public, mcp: $mcp,
      releases: $releases, pods: $pods, checks: $checks,
      resources: {requestedMemoryBytes: $req, allocatableMemoryBytes: $alloc,
        requestedPercent: (if $alloc > 0 then ($req * 100 / $alloc | floor) else 0 end)},
      ok: ($checks | all(.ok))}'
}

status_text() {
  local profile_status=$1 running=$2 r name state msg
  printf '\nКластер    minikube %s — %s\n' "$MK_PROFILE" "$profile_status"
  if [[ $running == 1 ]]; then
    printf 'Версия     %s\n' "$(deployed_version | jq -r 'if . == null then "не записана" else "\(.tag) (\(.commit)), \(.deployedAt), \(.deployedBy)" end')"
    printf '\nРелизы Helm\n'
    hm list -A 2>/dev/null | sed 's/^/  /' || true
    printf '\nПоды\n'
    kc get pods -n "$NS_STORAGES" 2>/dev/null | sed 's/^/  /' || true
    kc get pods -n "$NS_OBSERVABILITY" --no-headers 2>/dev/null | sed 's/^/  /' || true
    mcp_enabled && { kc get pods -n "$NS_MCP" --no-headers 2>/dev/null | sed 's/^/  /' || true; }
    printf '\nРесурсы    %s\n' "$(resources_line)"
  fi
  printf '\nПроверки\n'
  for r in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r name state msg <<<"$r"
    if [[ $state == ok ]]; then
      printf '  %s✓%s %-10s %s\n' "$C_GREEN" "$C_RESET" "$name" "$msg"
    else
      printf '  %s✗%s %-10s %s\n' "$C_RED" "$C_RESET" "$name" "$msg"
    fi
  done
}

# --- creds ---

cmd_creds() {
  if ! have kubectl || ! kc get ns "$NS_STORAGES" >/dev/null 2>&1; then die "$E_CHECKS" "кластер $MK_PROFILE не запущен или стенд не развёрнут"; fi
  local ns=$NS_STORAGES
  local -A pg kafka s3
  local k
  for k in host port database username password sslmode uri; do pg[$k]=$(secret_key "$ns" postgres-conn "$k"); done
  for k in bootstrap_servers security_protocol sasl_mechanism username password; do kafka[$k]=$(secret_key "$ns" kafka-conn "$k"); done
  for k in endpoint region bucket access_key secret_key path_style; do s3[$k]=$(secret_key "$ns" s3-conn "$k"); done
  local gf_user gf_pass
  gf_user=$(secret_key "$NS_OBSERVABILITY" grafana-admin admin-user)
  gf_pass=$(secret_key "$NS_OBSERVABILITY" grafana-admin admin-password)
  if [[ $JSON == 1 ]]; then
    jq -n \
      --arg pgsvc "postgres.$ns.svc:5432" --arg pghost "${pg[host]}" --arg pgport "${pg[port]}" --arg pgdb "${pg[database]}" \
      --arg pguser "${pg[username]}" --arg pgpass "${pg[password]}" --arg pgssl "${pg[sslmode]}" --arg pguri "${pg[uri]}" \
      --arg ksvc "kafka.$ns.svc:9092" --arg kb "${kafka[bootstrap_servers]}" --arg kp "${kafka[security_protocol]}" \
      --arg km "${kafka[sasl_mechanism]}" --arg ku "${kafka[username]}" --arg kpass "${kafka[password]}" \
      --arg ssvc "s3.$ns.svc:9000" --arg se "${s3[endpoint]}" --arg sr "${s3[region]}" --arg sb "${s3[bucket]}" \
      --arg sa "${s3[access_key]}" --arg ss "${s3[secret_key]}" --arg sp "${s3[path_style]}" \
      --arg gu "$gf_user" --arg gp "$gf_pass" --arg ns "$ns" --arg obs "$NS_OBSERVABILITY" --arg pgm "$POSTGRES_MODE" \
      --arg km2 "$KAFKA_MODE" --arg sm "$S3_MODE" --argjson mcp "$(mcp_creds_json)" \
      '{postgres: {mode: $pgm, service: $pgsvc, secret: "\($ns)/postgres-conn", host: $pghost, port: $pgport, database: $pgdb,
          username: $pguser, password: $pgpass, sslmode: $pgssl, uri: $pguri},
        kafka: {mode: $km2, service: $ksvc, secret: "\($ns)/kafka-conn", bootstrap_servers: $kb, security_protocol: $kp,
          sasl_mechanism: $km, username: $ku, password: $kpass},
        s3: {mode: $sm, service: $ssvc, secret: "\($ns)/s3-conn", endpoint: $se, region: $sr, bucket: $sb,
          access_key: $sa, secret_key: $ss, path_style: $sp},
        grafana: {service: "grafana.\($obs).svc:80", secret: "\($obs)/grafana-admin", user: $gu, password: $gp},
        mcp: $mcp}'
    return
  fi
  cat <<EOF
Postgres ($(mode_ru "$POSTGRES_MODE"))
  сервис    postgres.$ns.svc:5432     секрет $ns/postgres-conn
  хост      ${pg[host]}:${pg[port]}   база ${pg[database]}   sslmode ${pg[sslmode]}
  логин     ${pg[username]}
  пароль    ${pg[password]}
  uri       ${pg[uri]}

Kafka ($(mode_ru "$KAFKA_MODE"))
  сервис    kafka.$ns.svc:9092        секрет $ns/kafka-conn
  bootstrap ${kafka[bootstrap_servers]}   ${kafka[security_protocol]} ${kafka[sasl_mechanism]}
  логин     ${kafka[username]:--}
  пароль    ${kafka[password]:--}

S3 ($(mode_ru "$S3_MODE"))
  сервис    s3.$ns.svc:9000           секрет $ns/s3-conn
  endpoint  ${s3[endpoint]}   регион ${s3[region]}   бакет ${s3[bucket]}   path_style ${s3[path_style]}
  ключ      ${s3[access_key]}
  секрет    ${s3[secret_key]}

Grafana
  сервис    grafana.$NS_OBSERVABILITY.svc:80   секрет $NS_OBSERVABILITY/grafana-admin
  логин     $gf_user
  пароль    $gf_pass
EOF
  mcp_creds_text
}

# --- down ---

cmd_down() {
  if [[ $ASSUME_YES != 1 ]]; then
    printf 'Удалить профиль minikube «%s» со всеми данными хранилищ и наблюдаемости? Введите yes: ' "$MK_PROFILE" >&2
    local answer=""
    read -r answer || true
    [[ $answer == yes ]] || die "$E_CANCELLED" "отменено: ничего не удалено"
  fi
  step cluster
  have minikube || die "$E_CLUSTER" "minikube не установлен"
  cluster_delete >/dev/null || die "$E_CLUSTER" "minikube delete не выполнен"
  remove_autostart
  ok "профиль $MK_PROFILE удалён"
}

main() {
  parse_args "$@"
  setup_color
  if [[ $COMMAND == help ]]; then
    usage
    return
  fi
  load_config "$ROOT" "$CONFIG_FILE"
  WORK_DIR="$ROOT/.work"
  mkdir -p "$WORK_DIR"
  case $COMMAND in
    up)
      validate_config
      cmd_up
      ;;
    status)
      validate_config
      cmd_status
      ;;
    creds) cmd_creds ;;
    down) cmd_down ;;
  esac
}

# Подключение без запуска — для юнит-тестов (tests/unit).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
