#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# R12, R13: конфигурация, внешний режим, секреты.

load helpers

setup() {
  setup_stubs
  load_script
}

@test "SEC-03: пароль прямо в local.env — код 2" {
  printf 'POSTGRES_MODE=external\nPOSTGRES_PASSWORD=s3cret\n' >"$BATS_TEST_TMPDIR/local.env"
  run load_config "$ROOT" "$BATS_TEST_TMPDIR/local.env"
  [ "$status" -eq 2 ]
  [[ $output == *"POSTGRES_PASSWORD записан прямо"* ]]
  [[ $output != *"s3cret"* ]]
}

@test "SEC-03: путь к файлу пароля (*_FILE) в local.env допустим" {
  printf 'POSTGRES_PASSWORD_FILE=/secure/pg\n' >"$BATS_TEST_TMPDIR/local.env"
  run load_config "$ROOT" "$BATS_TEST_TMPDIR/local.env"
  [ "$status" -eq 0 ]
}

@test "конфигурация: переменная окружения важнее local.env, local.env важнее defaults.env" {
  printf 'MK_CPUS=5\nVM_RETENTION=30d\n' >"$BATS_TEST_TMPDIR/local.env"
  # load_script уже загрузил значения по умолчанию — сбрасываем их, как в новом процессе.
  unset MK_CPUS VM_RETENTION VL_RETENTION
  MK_CPUS=6 load_config "$ROOT" "$BATS_TEST_TMPDIR/local.env"
  [ "$MK_CPUS" = 6 ]
  [ "$VM_RETENTION" = 30d ]
  [ "$VL_RETENTION" = 3d ]
}

@test "EXT-06: внешний Postgres без хоста — код 2 с именем параметра" {
  POSTGRES_MODE=external POSTGRES_HOST=""
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"POSTGRES_HOST"* ]]
}

@test "EXT-06: внешний Postgres без пароля — код 2" {
  POSTGRES_MODE=external POSTGRES_HOST=db POSTGRES_PORT=5432 POSTGRES_DATABASE=h POSTGRES_USER=h POSTGRES_SSLMODE=require
  unset POSTGRES_PASSWORD POSTGRES_PASSWORD_FILE
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"POSTGRES_PASSWORD"* ]]
}

@test "EXT-06: пароль из файла *_FILE принимается" {
  POSTGRES_MODE=external POSTGRES_HOST=db POSTGRES_PORT=5432 POSTGRES_DATABASE=h POSTGRES_USER=h POSTGRES_SSLMODE=require
  echo -n secret >"$BATS_TEST_TMPDIR/pg"
  POSTGRES_PASSWORD_FILE=$BATS_TEST_TMPDIR/pg
  run validate_config
  [ "$status" -eq 0 ]
  [ "$(secret_value POSTGRES_PASSWORD)" = secret ]
}

@test "EXT-06: внешняя Kafka SASL_SSL без механизма — код 2" {
  KAFKA_MODE=external KAFKA_BOOTSTRAP=b:9092 KAFKA_SECURITY_PROTOCOL=SASL_SSL KAFKA_SASL_MECHANISM=""
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"KAFKA_SASL_MECHANISM"* ]]
}

@test "EXT-06: неизвестный протокол Kafka — код 2" {
  KAFKA_MODE=external KAFKA_BOOTSTRAP=b:9092 KAFKA_SECURITY_PROTOCOL=SSL
  run validate_config
  [ "$status" -eq 2 ]
}

@test "EXT-06: неверный режим — код 2" {
  S3_MODE=managed
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"S3_MODE"* ]]
}

@test "EXT-02 (U): внешний хост-IP даёт isIP, DNS-имя — нет" {
  POSTGRES_MODE=external POSTGRES_HOST=10.20.0.5 POSTGRES_PORT=5432
  S3_MODE=external S3_ENDPOINT=https://storage.googleapis.com
  run external_values
  [[ $output == *"postgres.external.isIP=true"* ]]
  [[ $output == *"s3.external.host=storage.googleapis.com"* && $output == *"s3.external.port=443"* ]]
  [[ $output != *"s3.external.isIP"* ]]
}

@test "встроенный режим: external_values ничего не печатает" {
  run external_values
  [ -z "$output" ]
}

@test "SEC-02: существующий секрет не пересоздаётся" {
  stub kubectl 'exit 0'
  run ensure_secret storages postgres-credentials kubernetes.io/basic-auth username hammurapi password x
  [ "$status" -eq 0 ]
  called "kubectl --context hammurapi -n storages get secret postgres-credentials"
  not_called "kubectl --context hammurapi create"
}

@test "SEC-02: отсутствующий секрет создаётся, значение идёт через stdin" {
  stub kubectl '[[ $* == *"get secret"* ]] && exit 1; [[ $* == *"create -f -"* ]] && cat >"$STUBS/../created.yaml"; exit 0'
  run ensure_secret storages grafana-admin Opaque admin-password topsecret
  [ "$status" -eq 0 ]
  not_called topsecret
  grep -q "admin-password: $(printf topsecret | base64)" "$BATS_TEST_TMPDIR/created.yaml"
  grep -q "app.kubernetes.io/managed-by: hammurapi-infra" "$BATS_TEST_TMPDIR/created.yaml"
}

@test "SEC: сгенерированный пароль — 32 буквенно-цифровых символа" {
  run gen_password
  [[ $output =~ ^[A-Za-z0-9]{32}$ ]]
}

@test "STO-04 (U): ключи postgres-conn во внешнем режиме совпадают со спецификацией" {
  stub kubectl '[[ $* == *"apply -f -"* ]] && cat >"$STUBS/../conn.yaml"; exit 0'
  POSTGRES_MODE=external POSTGRES_HOST=db POSTGRES_PORT=5432 POSTGRES_DATABASE=h POSTGRES_USER=u POSTGRES_SSLMODE=require POSTGRES_PASSWORD='p@ss'
  run write_postgres_conn
  [ "$status" -eq 0 ]
  keys=$(sed -n 's/^  \([a-z_]*\): .*/\1/p' "$BATS_TEST_TMPDIR/conn.yaml" | grep -v -e '^name$' -e '^namespace$' | sort | tr '\n' ' ')
  [ "$keys" = "database host password port sslmode uri username " ]
  uri=$(sed -n 's/^  uri: //p' "$BATS_TEST_TMPDIR/conn.yaml" | base64 -d)
  [ "$uri" = "postgresql://u:p%40ss@db:5432/h?sslmode=require" ]
}

@test "STO-04 (U): ключи kafka-conn и s3-conn" {
  stub kubectl '[[ $* == *"apply -f -"* ]] && cat >>"$STUBS/../conn.yaml"; exit 0'
  KAFKA_MODE=external KAFKA_BOOTSTRAP=b:9092 KAFKA_SECURITY_PROTOCOL=SASL_SSL KAFKA_SASL_MECHANISM=PLAIN KAFKA_USERNAME=u KAFKA_PASSWORD=p
  S3_MODE=external S3_ENDPOINT=https://storage.googleapis.com S3_REGION=r S3_BUCKET=b S3_ACCESS_KEY=a S3_SECRET_KEY=s S3_PATH_STYLE=false
  write_kafka_conn
  write_s3_conn
  keys=$(sed -n 's/^  \([a-z_]*\): .*/\1/p' "$BATS_TEST_TMPDIR/conn.yaml" | grep -v -e '^name$' -e '^namespace$' | sort | tr '\n' ' ')
  [ "$keys" = "access_key bootstrap_servers bucket endpoint password path_style region sasl_mechanism secret_key security_protocol username " ]
}
