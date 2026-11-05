#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# R12, R13: configuration, external mode, secrets.

load helpers

setup() {
  setup_stubs
  load_script
}

@test "SEC-03: a password directly in local.env: code 2" {
  printf 'POSTGRES_MODE=external\nPOSTGRES_PASSWORD=s3cret\n' >"$BATS_TEST_TMPDIR/local.env"
  run load_config "$ROOT" "$BATS_TEST_TMPDIR/local.env"
  [ "$status" -eq 2 ]
  [[ $output == *"POSTGRES_PASSWORD is written directly"* ]]
  [[ $output != *"s3cret"* ]]
}

@test "SEC-03: a path to a password file (*_FILE) in local.env is allowed" {
  printf 'POSTGRES_PASSWORD_FILE=/secure/pg\n' >"$BATS_TEST_TMPDIR/local.env"
  run load_config "$ROOT" "$BATS_TEST_TMPDIR/local.env"
  [ "$status" -eq 0 ]
}

@test "configuration: an environment variable wins over local.env, and local.env over defaults.env" {
  printf 'MK_CPUS=5\nVM_RETENTION=30d\n' >"$BATS_TEST_TMPDIR/local.env"
  # load_script already loaded the defaults, so reset them as in a new process.
  unset MK_CPUS VM_RETENTION VL_RETENTION
  MK_CPUS=6 load_config "$ROOT" "$BATS_TEST_TMPDIR/local.env"
  [ "$MK_CPUS" = 6 ]
  [ "$VM_RETENTION" = 30d ]
  [ "$VL_RETENTION" = 3d ]
}

@test "EXT-06: external Postgres without a host: code 2 with the parameter name" {
  POSTGRES_MODE=external POSTGRES_HOST=""
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"POSTGRES_HOST"* ]]
}

@test "EXT-06: external Postgres without a password: code 2" {
  POSTGRES_MODE=external POSTGRES_HOST=db POSTGRES_PORT=5432 POSTGRES_DATABASE=h POSTGRES_USER=h POSTGRES_SSLMODE=require
  unset POSTGRES_PASSWORD POSTGRES_PASSWORD_FILE
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"POSTGRES_PASSWORD"* ]]
}

@test "EXT-06: a password from a *_FILE file is accepted" {
  POSTGRES_MODE=external POSTGRES_HOST=db POSTGRES_PORT=5432 POSTGRES_DATABASE=h POSTGRES_USER=h POSTGRES_SSLMODE=require
  echo -n secret >"$BATS_TEST_TMPDIR/pg"
  POSTGRES_PASSWORD_FILE=$BATS_TEST_TMPDIR/pg
  run validate_config
  [ "$status" -eq 0 ]
  [ "$(secret_value POSTGRES_PASSWORD)" = secret ]
}

@test "EXT-06: external Kafka SASL_SSL without a mechanism: code 2" {
  KAFKA_MODE=external KAFKA_BOOTSTRAP=b:9092 KAFKA_SECURITY_PROTOCOL=SASL_SSL KAFKA_SASL_MECHANISM=""
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"KAFKA_SASL_MECHANISM"* ]]
}

@test "EXT-06: an unknown Kafka protocol: code 2" {
  KAFKA_MODE=external KAFKA_BOOTSTRAP=b:9092 KAFKA_SECURITY_PROTOCOL=SSL
  run validate_config
  [ "$status" -eq 2 ]
}

@test "EXT-06: a wrong mode: code 2" {
  S3_MODE=managed
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"S3_MODE"* ]]
}

@test "EXT-02 (U): an external IP host gives isIP, a DNS name does not" {
  POSTGRES_MODE=external POSTGRES_HOST=10.20.0.5 POSTGRES_PORT=5432
  S3_MODE=external S3_ENDPOINT=https://storage.googleapis.com
  run external_values
  [[ $output == *"postgres.external.isIP=true"* ]]
  [[ $output == *"s3.external.host=storage.googleapis.com"* && $output == *"s3.external.port=443"* ]]
  [[ $output != *"s3.external.isIP"* ]]
}

@test "built-in mode: external_values prints nothing" {
  run external_values
  [ -z "$output" ]
}

@test "SEC-02: an existing secret is not recreated" {
  stub kubectl 'exit 0'
  run ensure_secret storages postgres-credentials kubernetes.io/basic-auth username hammurapi password x
  [ "$status" -eq 0 ]
  called "kubectl --context greenongrey -n storages get secret postgres-credentials"
  not_called "kubectl --context greenongrey create"
}

@test "SEC-02: a missing secret is created, the value goes through stdin" {
  stub kubectl '[[ $* == *"get secret"* ]] && exit 1; [[ $* == *"create -f -"* ]] && cat >"$STUBS/../created.yaml"; exit 0'
  run ensure_secret storages grafana-admin Opaque admin-password topsecret
  [ "$status" -eq 0 ]
  not_called topsecret
  grep -q "admin-password: $(printf topsecret | base64)" "$BATS_TEST_TMPDIR/created.yaml"
  grep -q "app.kubernetes.io/managed-by: installer" "$BATS_TEST_TMPDIR/created.yaml"
}

@test "SEC: a generated password has 32 alphanumeric characters" {
  run gen_password
  [[ $output =~ ^[A-Za-z0-9]{32}$ ]]
}

@test "STO-04 (U): keys of postgres-conn in external mode match the specification" {
  stub kubectl '[[ $* == *"apply -f -"* ]] && cat >"$STUBS/../conn.yaml"; exit 0'
  POSTGRES_MODE=external POSTGRES_HOST=db POSTGRES_PORT=5432 POSTGRES_DATABASE=h POSTGRES_USER=u POSTGRES_SSLMODE=require POSTGRES_PASSWORD='p@ss'
  run write_postgres_conn
  [ "$status" -eq 0 ]
  keys=$(sed -n 's/^  \([a-z_]*\): .*/\1/p' "$BATS_TEST_TMPDIR/conn.yaml" | grep -v -e '^name$' -e '^namespace$' | sort | tr '\n' ' ')
  [ "$keys" = "database host password port sslmode uri username " ]
  uri=$(sed -n 's/^  uri: //p' "$BATS_TEST_TMPDIR/conn.yaml" | base64 -d)
  [ "$uri" = "postgresql://u:p%40ss@db:5432/h?sslmode=require" ]
}

@test "STO-04 (U): keys of kafka-conn and s3-conn" {
  stub kubectl '[[ $* == *"apply -f -"* ]] && cat >>"$STUBS/../conn.yaml"; exit 0'
  KAFKA_MODE=external KAFKA_BOOTSTRAP=b:9092 KAFKA_SECURITY_PROTOCOL=SASL_SSL KAFKA_SASL_MECHANISM=PLAIN KAFKA_USERNAME=u KAFKA_PASSWORD=p
  S3_MODE=external S3_ENDPOINT=https://storage.googleapis.com S3_REGION=r S3_BUCKET=b S3_ACCESS_KEY=a S3_SECRET_KEY=s S3_PATH_STYLE=false
  write_kafka_conn
  write_s3_conn
  keys=$(sed -n 's/^  \([a-z_]*\): .*/\1/p' "$BATS_TEST_TMPDIR/conn.yaml" | grep -v -e '^name$' -e '^namespace$' | sort | tr '\n' ' ')
  [ "$keys" = "access_key bootstrap_servers bucket endpoint password path_style region sasl_mechanism secret_key security_protocol username " ]
}

@test "configuration: image garbage collection: IMAGE_GC_LOW < IMAGE_GC_HIGH ≤ 100, the age is a duration" {
  IMAGE_GC_HIGH=80 IMAGE_GC_LOW=85
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"IMAGE_GC_LOW < IMAGE_GC_HIGH"* ]]
  IMAGE_GC_HIGH=85 IMAGE_GC_LOW=80 IMAGE_GC_MAX_AGE=14d
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"IMAGE_GC_MAX_AGE"* ]]
}

@test "FTR.INFRA.INST-0001 R28: check_pods skips probes of this release and of an older tag" {
  run grep -c "managed-by notin (installer,hammurapi-infra)" "$ROOT/lib/checks.sh"
  [ "$output" -eq 1 ]
}

@test "probes: a label on the Job and the pod, check_pods of other runs skips them" {
  run bash -c 'source "$1"; probe_job_manifest storage-probe check - - -' _ "$ROOT/lib/checks.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'app.kubernetes.io/managed-by: installer' <<<"$output")" -eq 2 ]
}

@test "FTR.INFRA.INST-0001 R8: all cluster access goes to KUBE_CONTEXT, by default the context of the profile" {
  stub kubectl 'exit 0'
  stub helm 'exit 0'
  kc get ns
  hm list
  called "kubectl --context $MK_PROFILE get ns"
  called "helm --kube-context $MK_PROFILE list"
  KUBE_CONTEXT=other
  kc get pods
  hm status x
  called "kubectl --context other get pods"
  called "helm --kube-context other status x"
}

@test "FTR.INFRA.INST-0001 R8: the context is set only through kc and hm" {
  not_grep -nE '(kubectl|helm) +--(kube-)?context' "$ROOT"/lib/[a-bd-z]*.sh "$ROOT"/lib/cluster.sh "$ROOT"/lib/checks.sh
}

@test "FTR.INFRA.INST-0001 R28: a new install has the names of the installer" {
  [ "$MK_PROFILE" = greenongrey ]
  [ "$UNIT_PREFIX" = greenongrey ]
  [ "$CERT_NAME" = greenongrey-public ]
  [ "$LOCK_FILE" = /var/lock/installer.lock ]
  [ "$(kube_context)" = greenongrey ]
}

@test "FTR.INFRA.INST-0001 R28: another profile exists: code 2, no second cluster" {
  mkdir -p "$MINIKUBE_HOME/profiles/hammurapi"
  : >"$MINIKUBE_HOME/profiles/hammurapi/config.json"
  run check_single_profile
  [ "$status" -eq 2 ]
  [[ $output == *"profile hammurapi"* && $output == *"MK_PROFILE=greenongrey"* ]]
  [[ $output == *UNIT_PREFIX* && $output == *CERT_NAME* ]]
}

@test "FTR.INFRA.INST-0001 R28: the profile of the config exists, or none exists: no error" {
  run check_single_profile
  [ "$status" -eq 0 ]
  mkdir -p "$MINIKUBE_HOME/profiles/hammurapi" "$MINIKUBE_HOME/profiles/other"
  : >"$MINIKUBE_HOME/profiles/hammurapi/config.json"
  : >"$MINIKUBE_HOME/profiles/other/config.json"
  MK_PROFILE=hammurapi run check_single_profile
  [ "$status" -eq 0 ]
}

@test "FTR.INFRA.INST-0001 R28: an invalid UNIT_PREFIX or CERT_NAME: code 2" {
  UNIT_PREFIX='a b;' run validate_config
  [ "$status" -eq 2 ]
  CERT_NAME='../x' run validate_config
  [ "$status" -eq 2 ]
}

@test "FTR.INFRA.INST-0001 tech §3: the config file of deploy scripts, the old name still works" {
  unset INSTALLER_CONFIG HAMMURAPI_INFRA_CONFIG
  [ "$(installer_config)" = /opt/installer/local.env ]
  [ "$(HAMMURAPI_INFRA_CONFIG=/old installer_config)" = /old ]
  [ "$(INSTALLER_CONFIG=/new HAMMURAPI_INFRA_CONFIG=/old installer_config)" = /new ]
}

@test "RES-07 (U): an invalid OBSERVABILITY: code 2" {
  OBSERVABILITY=maybe run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *OBSERVABILITY* ]]
}
