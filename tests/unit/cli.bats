#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# R5, R17: commands, flags, exit codes, summary, status --json.

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../../installer"

setup() {
  setup_stubs
  export MINIKUBE_HOME=$BATS_TEST_TMPDIR/minikube
}

@test "CMD-05: an unknown command: code 2 and help" {
  run bash "$SCRIPT" deploy
  [ "$status" -eq 2 ]
  [[ $output == *"unknown command or flag: deploy"* ]]
  [[ $output == *"Usage"* ]]
}

@test "CMD-05: an unknown flag: code 2" {
  run bash "$SCRIPT" up --force
  [ "$status" -eq 2 ]
  [[ $output == *"--force"* ]]
}

@test "CLI-01: no command without a terminal: code 2, help, no question" {
  run bash -c "bash '$SCRIPT' </dev/null"
  [ "$status" -eq 2 ]
  [[ $output == *"Usage"* ]]
  [[ $output != *"?"* ]]
}

@test "CMD-05: --json outside status/creds: code 2" {
  run bash "$SCRIPT" up --json
  [ "$status" -eq 2 ]
}

@test "CMD-05: --yes outside uninstall: code 2" {
  run bash "$SCRIPT" install --yes
  [ "$status" -eq 2 ]
}

@test "help: code 0 and the command list" {
  run bash "$SCRIPT" help
  [ "$status" -eq 0 ]
  [[ $output == *"install"* && $output == *"status"* && $output == *"creds"* && $output == *"uninstall"* ]]
}

@test "R5: up and down stay hidden synonyms of install and uninstall" {
  load_script
  parse_args up
  [ "$COMMAND" = install ]
  COMMAND="" CONFIG_FILE=""
  parse_args down --yes
  [ "$COMMAND" = uninstall ]
  run usage
  [[ $output != *" up "* && $output != *" down "* ]]
}

@test "R5: the config file: --config, INSTALLER_CONFIG, the system file, then config/local.env" {
  load_script
  SYSTEM_CONFIG=$BATS_TEST_TMPDIR/installer.env
  [ "$(INSTALLER_CONFIG='' default_config)" = "$ROOT/config/local.env" ]
  touch "$SYSTEM_CONFIG"
  [ "$(INSTALLER_CONFIG='' default_config)" = "$SYSTEM_CONFIG" ]
  touch "$BATS_TEST_TMPDIR/x.env"
  [ "$(INSTALLER_CONFIG=$BATS_TEST_TMPDIR/x.env default_config)" = "$BATS_TEST_TMPDIR/x.env" ]
}

@test "CMD-03: uninstall in a terminal, answer no: code 16, the profile stays" {
  run bash -c "echo no | script -qec \"bash '$SCRIPT' uninstall --no-color\" /dev/null"
  [ "$status" -eq 16 ]
  [[ $output == *"Type yes"* && $output == *"nothing was deleted"* ]]
  not_called "minikube delete"
}

@test "R5: uninstall without a terminal and without --yes: code 2, nothing deleted" {
  run bash -c "echo yes | bash '$SCRIPT' uninstall --no-color"
  [ "$status" -eq 2 ]
  [[ $output == *"--yes"* ]]
  not_called "minikube delete"
}

@test "CMD-04 (U): uninstall --yes: forwarding, profile, autostart; the last line is the JSON result" {
  export UNIT_DIR=$BATS_TEST_TMPDIR/units LOGS_DIR=$BATS_TEST_TMPDIR/logs
  export LOCK_FILE=$BATS_TEST_TMPDIR/lock OLD_LOCK_FILE=$BATS_TEST_TMPDIR/old-lock
  mkdir -p "$UNIT_DIR"
  touch "$UNIT_DIR/greenongrey-ingress-forward.service"
  run bash "$SCRIPT" uninstall --yes --no-color
  [ "$status" -eq 0 ]
  called "systemctl disable --now greenongrey-ingress-forward.service"
  called "minikube delete -p greenongrey"
  [ "$(grep -n 'ingress-forward' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n 'minikube delete' "$CALLS" | cut -d: -f1)" ]
  echo "${lines[-1]}" | jq -e '.status == "ok" and .command == "uninstall" and .code == 0 and .diagnostics == null'
}

@test "CLI-09: install without a terminal, three parameters missing: code 2, all three named" {
  run env POSTGRES_MODE=external POSTGRES_HOST=db.example POSTGRES_PORT=5432 POSTGRES_DATABASE=h POSTGRES_SSLMODE=require \
    S3_MODE=external S3_ENDPOINT=https://s3.example S3_REGION=r S3_BUCKET=b S3_PATH_STYLE=true S3_ACCESS_KEY=k \
    bash "$SCRIPT" install --no-color </dev/null
  [ "$status" -eq 2 ]
  [[ $output == *"POSTGRES_USER"* && $output == *"POSTGRES_PASSWORD"* && $output == *"S3_SECRET_KEY"* ]]
  [[ $output != *"S3_ACCESS_KEY"* ]]
  not_called "apt-get"
  not_called "minikube"
}

@test "R5: INSTALLER_CONFIG names a missing file: code 2" {
  run env INSTALLER_CONFIG=/nonexistent/installer.env bash "$SCRIPT" status --no-color
  [ "$status" -eq 2 ]
  [[ $output == *"/nonexistent/installer.env"* ]]
}

@test "CLI-09: external Kafka without the protocol: code 2 with the parameter, not an unbound variable" {
  run env KAFKA_MODE=external KAFKA_BOOTSTRAP=k:9092 bash "$SCRIPT" install --no-color </dev/null
  [ "$status" -eq 2 ]
  [[ $output == *KAFKA_SECURITY_PROTOCOL* && $output != *unbound* ]]
}

@test "CLI-10: the result without jq still ends stdout with JSON" {
  load_script
  COMMAND=install
  have() { [[ $1 != jq ]]; }
  run print_result 10
  [ "$status" -eq 0 ]
  [[ $output == '{"status":"failed","command":"install","code":10,'* ]]
}

@test "CLI-10: the result of install: the last line of stdout is JSON, on success and on failure" {
  load_script
  COMMAND=install COMMAND_STARTED=$((SECONDS - 5)) INFRA_TAG=v1.2.0
  run print_result 0
  echo "$output" | jq -e '.status == "ok" and .command == "install" and .code == 0 and .durationSeconds >= 5
    and .installerVersion == "v1.2.0" and .updated == [] and .failed == [] and .skipped == [] and .diagnostics == null'
  RESULT_FAILED=(nabu-web) RESULT_UPDATED=(nabu-core) RESULT_DIAGNOSTICS=/logs/x
  run print_result 13
  echo "$output" | jq -e '.status == "failed" and .code == 13 and .updated == ["nabu-core"] and .failed == ["nabu-web"]
    and .diagnostics == "/logs/x"'
  # A failed install ends with it too, a refused configuration included.
  run env POSTGRES_MODE=bogus bash "$SCRIPT" install --no-color </dev/null
  [ "$status" -ne 0 ]
  echo "${lines[-1]}" | jq -e '.status == "failed" and .command == "install" and .code != 0'
}

@test "CMD-06: the summary of up: versions, addresses, tunnel, port-forward, creds" {
  load_script
  COMMAND_STARTED=$((SECONDS - 872))
  DEPLOYED_TAG=v1.4.0
  RELEASES=("strimzi 1.2.0" "grafana 13.2.7")
  MEM_REQUESTED=$((3 * 1024 * 1024 * 1024)) MEM_ALLOCATABLE=$((12 * 1024 * 1024 * 1024))
  run print_summary
  [ "$status" -eq 0 ]
  # Time counts from SECONDS: on a slow machine the test takes over a second.
  [[ $output =~ Ready\ in\ 14m\ 3[2-9]s ]]
  [[ $output == *"v1.4.0"* ]]
  [[ $output == *"postgres.storages.svc:5432"* && $output == *"kafka.storages.svc:9092"* && $output == *"s3.storages.svc:9000"* ]]
  [[ $output == *"Kafka $KAFKA_VERSION"* && $output == *"grafana"*"13.2.7"* ]]
  [[ $output == *"ssh -L 3000:localhost:3000"* ]]
  [[ $output == *"port-forward svc/grafana 3000:80"* ]]
  [[ $output == *"./installer creds"* ]]
  [[ $output == *"(25%)"* ]]
}

@test "CMD-01: status --json without a cluster: valid JSON and code 15" {
  stub minikube 'exit 1'
  run bash -c "bash '$SCRIPT' status --json 2>/dev/null"
  [ "$status" -eq 15 ]
  echo "$output" | jq -e '.profile.status == "Stopped" and .ok == false and (.checks | length) == 1
    and has("releases") and has("pods") and has("resources") and has("version")'
}

@test "CMD-01: status --json with a cluster: profile, releases, pods, checks, resources" {
  load_script
  running_cluster() { return 0; }
  hm() { echo '[{"name":"grafana","namespace":"observability","chart":"grafana-13.2.7","app_version":"13.2.3","status":"deployed","revision":1}]'; }
  kc() {
    case "$*" in
      *"get pods"*) echo '{"items":[{"metadata":{"namespace":"storages","name":"hammurapi-pg-1"},"status":{"phase":"Running","containerStatuses":[{"ready":true}]}}]}' ;;
      *configmap*) echo '{"data":{"tag":"v1.4.0","commit":"abc1234","deployedAt":"2026-09-29T10:00:00Z","deployedBy":"anna"}}' ;;
    esac
  }
  CHECK_RESULTS=("pods|ok|all pods are ready" "logs|fail|logs do not reach VictoriaLogs")
  MEM_REQUESTED=100 MEM_ALLOCATABLE=400
  run status_json Running 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.profile.name == "greenongrey" and .version.tag == "v1.4.0" and (.releases | length) == 1
    and .pods[0].ready == true and .checks[1].ok == false and .resources.requestedPercent == 25 and .ok == false'
}

@test "FTR.INFRA.INST-0001 R17: creds and the summary with observability off: no Grafana" {
  stub kubectl 'exit 0'
  OBSERVABILITY=false run bash "$SCRIPT" creds --json --no-color
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.grafana == null and .postgres != null'
  not_called grafana-admin
  OBSERVABILITY=false run bash "$SCRIPT" creds --no-color
  [ "$status" -eq 0 ]
  [[ $output != *Grafana* ]]
}
