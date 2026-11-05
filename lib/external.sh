# shellcheck shell=bash
# External storage mode (R12). The built-in storage is not installed; a service of the
# same name (chart hammurapi-storages) points to the external host, and the *-conn secret
# is filled from the configuration. Before consumers deploy, the Job
# external-check verifies what products need (FTR.INFRA.INST-0001 R15, R16): the vector extension and the
# rights of the Postgres owner, Kafka metadata, write, read and delete in each bucket.

any_external() {
  [[ $POSTGRES_MODE == external || $KAFKA_MODE == external || $S3_MODE == external ]]
}

# host_port <host:port | URL> <default port> — "host port".
host_port() {
  local v=$1 def=$2 host port
  v=${v#*://}
  v=${v%%/*}
  v=${v%%,*}
  if [[ $v == *:* ]]; then host=${v%:*} port=${v##*:}; else host=$v port=$def; fi
  printf '%s %s\n' "$host" "$port"
}

is_ip() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# external_values — --set arguments for the chart hammurapi-storages in external mode.
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
  log "checking external storages"
  out=$(probe_job_manifest external-check check "$pg" "$kafka" "$s3" | run_probe_job external-check 170) || rc=$?
  if ((rc != 0)); then
    local msgs=""
    while IFS= read -r line; do
      [[ $line == fail\|* ]] && msgs+="${line#fail|}; "
    done <<<"$out"
    die "$E_EXTERNAL" "an external storage did not pass the check from the cluster: ${msgs:-$out}"
  fi
  ok "external storages passed the check"
}
