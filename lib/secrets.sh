# shellcheck shell=bash
# Секреты (R11, R13). Пароли генерируются при первом `up` и хранятся только в
# секретах Kubernetes. Значения передаются kubectl через stdin, в аргументы
# команд и журнал не попадают.

# gen_password — 32 буквенно-цифровых символа (без head: при pipefail он мог бы дать SIGPIPE).
gen_password() {
  local p
  p=$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9')
  printf '%s' "${p:0:32}"
}

secret_exists() { kc -n "$1" get secret "$2" >/dev/null 2>&1; }

# secret_manifest <ns> <имя> <тип> <ключ> <значение> [<ключ> <значение>…]
secret_manifest() {
  local ns=$1 name=$2 type=$3
  shift 3
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n' "$name" "$ns"
  printf '  labels:\n    app.kubernetes.io/managed-by: hammurapi-infra\ntype: %s\ndata:\n' "$type"
  while (($#)); do
    printf '  %s: %s\n' "$1" "$(printf '%s' "$2" | base64 -w0)"
    shift 2
  done
}

# ensure_secret — создаёт секрет, только если его нет (повторный `up` не меняет пароли).
ensure_secret() {
  local ns=$1 name=$2
  if secret_exists "$ns" "$name"; then
    debug "секрет $ns/$name уже есть"
    return
  fi
  secret_manifest "$@" | kc create -f - >/dev/null
  log "создан секрет $ns/$name"
}

# put_secret — создаёт или обновляет секрет (секреты *-conn).
put_secret() {
  secret_manifest "$@" | apply_stdin
}

# secret_key <ns> <имя> <ключ> — значение ключа секрета.
secret_key() {
  kc -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d
}

uri_encode() { jq -rn --arg v "$1" '$v | @uri'; }

s3_seaweedfs_config() {
  jq -cn --arg a "$1" --arg s "$2" \
    '{identities: [{name: "hammurapi", credentials: [{accessKey: $a, secretKey: $s}], actions: ["Admin", "Read", "Write", "List", "Tagging"]}]}'
}

ensure_credentials() {
  local ns=$NS_STORAGES
  if [[ $POSTGRES_MODE == internal ]]; then
    ensure_secret "$ns" postgres-credentials kubernetes.io/basic-auth \
      username "$PG_USER" password "$(gen_password)"
  fi
  if [[ $S3_MODE == internal ]]; then
    if ! secret_exists "$ns" s3-root; then
      local access secret
      access=$(gen_password)
      access="hmr${access:0:17}"
      secret=$(gen_password)
      ensure_secret "$ns" s3-root Opaque access_key "$access" secret_key "$secret"
      ensure_secret "$ns" s3-seaweedfs-config Opaque seaweedfs_s3_config "$(s3_seaweedfs_config "$access" "$secret")"
    fi
  fi
  ensure_secret "$NS_OBSERVABILITY" grafana-admin Opaque admin-user admin admin-password "$(gen_password)"
}

write_postgres_conn() {
  local ns=$NS_STORAGES host port db user pass sslmode
  if [[ $POSTGRES_MODE == internal ]]; then
    host="postgres.$ns.svc" port=5432 db=$PG_DATABASE sslmode=disable
    user=$(secret_key "$ns" postgres-credentials username)
    pass=$(secret_key "$ns" postgres-credentials password)
  else
    host=$POSTGRES_HOST port=$POSTGRES_PORT db=$POSTGRES_DATABASE sslmode=$POSTGRES_SSLMODE
    user=$POSTGRES_USER
    pass=$(secret_value POSTGRES_PASSWORD)
  fi
  put_secret "$ns" postgres-conn Opaque host "$host" port "$port" database "$db" \
    username "$user" password "$pass" sslmode "$sslmode" \
    uri "postgresql://$(uri_encode "$user"):$(uri_encode "$pass")@$host:$port/$(uri_encode "$db")?sslmode=$sslmode"
}

write_kafka_conn() {
  local ns=$NS_STORAGES
  if [[ $KAFKA_MODE == internal ]]; then
    put_secret "$ns" kafka-conn Opaque bootstrap_servers "kafka.$ns.svc:9092" \
      security_protocol PLAINTEXT sasl_mechanism "" username "" password ""
  else
    put_secret "$ns" kafka-conn Opaque bootstrap_servers "$KAFKA_BOOTSTRAP" \
      security_protocol "$KAFKA_SECURITY_PROTOCOL" sasl_mechanism "${KAFKA_SASL_MECHANISM:-}" \
      username "${KAFKA_USERNAME:-}" password "$(secret_value KAFKA_PASSWORD)"
  fi
}

write_s3_conn() {
  local ns=$NS_STORAGES
  if [[ $S3_MODE == internal ]]; then
    put_secret "$ns" s3-conn Opaque endpoint "http://s3.$ns.svc:9000" region "$S3_REGION" \
      bucket "$S3_BUCKET" access_key "$(secret_key "$ns" s3-root access_key)" \
      secret_key "$(secret_key "$ns" s3-root secret_key)" path_style true
  else
    put_secret "$ns" s3-conn Opaque endpoint "$S3_ENDPOINT" region "$S3_REGION" bucket "$S3_BUCKET" \
      access_key "$(secret_value S3_ACCESS_KEY)" secret_key "$(secret_value S3_SECRET_KEY)" \
      path_style "$S3_PATH_STYLE"
  fi
}

ensure_secrets() {
  step secrets
  ensure_credentials
  # Секреты *-conn выводятся из секретов учётных данных (встроенный режим) или
  # из конфигурации (внешний) при каждом `up`: содержимое то же — изменений нет.
  write_postgres_conn
  write_kafka_conn
  write_s3_conn
  ok "секреты на месте"
}
