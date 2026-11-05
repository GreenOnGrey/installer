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

@test "CMD-05: no command: code 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "CMD-05: --json outside status/creds: code 2" {
  run bash "$SCRIPT" up --json
  [ "$status" -eq 2 ]
}

@test "CMD-05: --yes outside down: code 2" {
  run bash "$SCRIPT" up --yes
  [ "$status" -eq 2 ]
}

@test "help: code 0 and the command list" {
  run bash "$SCRIPT" help
  [ "$status" -eq 0 ]
  [[ $output == *"up"* && $output == *"status"* && $output == *"creds"* && $output == *"down"* ]]
}

@test "CMD-03: down, answer no: code 16, the profile stays" {
  run bash -c "echo no | bash '$SCRIPT' down --no-color"
  [ "$status" -eq 16 ]
  [[ $output == *"nothing was deleted"* ]]
  not_called "minikube delete"
}

@test "CMD-04 (U): down --yes: minikube delete without a question" {
  run bash "$SCRIPT" down --yes --no-color
  [ "$status" -eq 0 ]
  called "minikube delete -p hammurapi"
}

@test "CMD-06: the summary of up: versions, addresses, tunnel, port-forward, creds" {
  load_script
  UP_STARTED=$((SECONDS - 872))
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
  echo "$output" | jq -e '.profile.name == "hammurapi" and .version.tag == "v1.4.0" and (.releases | length) == 1
    and .pods[0].ready == true and .checks[1].ok == false and .resources.requestedPercent == 25 and .ok == false'
}
