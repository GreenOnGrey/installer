# shellcheck shell=bash
# Внешний режим хранилищ (R12). Встроенное хранилище не ставится; сервис с тем
# же именем (чарт hammurapi-storages) указывает на внешний хост, секрет *-conn
# заполняется из конфигурации. До развёртывания потребителей Job
# external-check проверяет доступность: pg_isready, метаданные Kafka, HEAD бакета.

any_external() {
  [[ $POSTGRES_MODE == external || $KAFKA_MODE == external || $S3_MODE == external ]]
}

# host_port <host:port | URL> <порт по умолчанию> — «хост порт».
host_port() {
  local v=$1 def=$2 host port
  v=${v#*://}
  v=${v%%/*}
  v=${v%%,*}
  if [[ $v == *:* ]]; then host=${v%:*} port=${v##*:}; else host=$v port=$def; fi
  printf '%s %s\n' "$host" "$port"
}

is_ip() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# external_values — --set для чарта hammurapi-storages во внешнем режиме.
external_values() {
  local host port args=()
  if [[ $POSTGRES_MODE == external ]]; then
    args+=(--set-string "postgres.external.host=$POSTGRES_HOST" --set "postgres.external.port=$POSTGRES_PORT")
    is_ip "$POSTGRES_HOST" && args+=(--set postgres.external.isIP=true)
  fi
  if [[ $KAFKA_MODE == external ]]; then
    read -r host port < <(host_port "$KAFKA_BOOTSTRAP" 9092)
    args+=(--set-string "kafka.external.host=$host" --set "kafka.external.port=$port")
    is_ip "$host" && args+=(--set kafka.external.isIP=true)
  fi
  if [[ $S3_MODE == external ]]; then
    local def=443
    [[ $S3_ENDPOINT == http://* ]] && def=80
    read -r host port < <(host_port "$S3_ENDPOINT" "$def")
    args+=(--set-string "s3.external.host=$host" --set "s3.external.port=$port")
    is_ip "$host" && args+=(--set s3.external.isIP=true)
  fi
  if ((${#args[@]})); then printf '%s\n' "${args[@]}"; fi
}

check_external() {
  any_external || return 0
  step external
  local pg=- kafka=- s3=- out rc=0 line
  [[ $POSTGRES_MODE == external ]] && pg=pg
  [[ $KAFKA_MODE == external ]] && kafka=kafka
  [[ $S3_MODE == external ]] && s3=s3
  log "проверка доступности внешних хранилищ"
  out=$(probe_job_manifest external-check check "$pg" "$kafka" "$s3" | run_probe_job external-check 90) || rc=$?
  if ((rc != 0)); then
    local msgs=""
    while IFS= read -r line; do
      [[ $line == fail\|* ]] && msgs+="${line#fail|}; "
    done <<<"$out"
    die "$E_EXTERNAL" "внешнее хранилище недоступно из кластера: ${msgs:-$out}"
  fi
  ok "внешние хранилища доступны"
}
