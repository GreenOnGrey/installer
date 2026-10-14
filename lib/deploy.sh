# shellcheck shell=bash
# Релизы Helm в порядке архитектуры (п. 4): операторы → секреты → внешние
# хранилища → хранилища → хранилища наблюдаемости → сборщики → Grafana и дашборды.

declare -A HELM_REPOS=(
  [strimzi]=https://strimzi.io/charts/
  [cnpg]=https://cloudnative-pg.github.io/charts
  [seaweedfs]=https://seaweedfs.github.io/seaweedfs/helm
  [vm]=https://victoriametrics.github.io/helm-charts/
  [prometheus-community]=https://prometheus-community.github.io/helm-charts
  [vector]=https://helm.vector.dev
  [grafana-community]=https://grafana-community.github.io/helm-charts
  [traefik]=https://traefik.github.io/charts
  [jetstack]=https://charts.jetstack.io
)

# Выведенные из конфигурации версии релизов — для сводки.
RELEASES=()

helm_repos() {
  local name
  for name in "${!HELM_REPOS[@]}"; do
    retry 3 10 helm repo add --force-update "$name" "${HELM_REPOS[$name]}" >/dev/null ||
      die "$E_DEPLOY" "не удалось добавить репозиторий чартов $name"
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

# release_local <релиз> <ns> <каталог чарта> [аргументы helm…] — релиз
# локального чарта; в сводке версия — «локальный».
release_local() {
  local name=$1 ns=$2 chart=$3
  shift 3
  release "$name" "$ns" "$chart" - - "$@"
  RELEASES[-1]="$name локальный"
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
    # Hammurapi (FTR.HMR.INFRA-0002): не обязателен в проверках, пока не установлен.
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
  # Публичный доступ: Ingress Grafana и вход через GitHub (FTR.HMR.INFRA-0002, R20).
  local grafana_public=()
  if public_enabled; then
    grafana_public_values "$RUN_DIR/grafana-public.yaml"
    grafana_public=(-f "$RUN_DIR/grafana-public.yaml")
  fi
  release grafana "$ns" grafana-community/grafana "$GRAFANA_CHART_VERSION" grafana.yaml \
    --set-string "grafana\.ini.plugins.preinstall_sync=victoriametrics-logs-datasource@$VL_PLUGIN_VERSION" \
    --set "persistence.size=$GRAFANA_STORAGE" "${grafana_public[@]}"
  stage_dashboards "$WORK_DIR/hammurapi-dashboards"
  release_local dashboards "$ns" "$WORK_DIR/hammurapi-dashboards"
}

deploy_all() {
  step deploy
  # R3 FTR.NAB.CMN-0006: бюджет памяти MCP-серверов — до любых изменений стенда
  mcp_preflight
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
  deploy_mcp
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
