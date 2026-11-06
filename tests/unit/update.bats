#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 R22–R24: update, pins and going back (lib/update.sh).

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../../installer"

setup() {
  setup_stubs
  PRODUCTS=nabu
  load_script
  CONFIG_MISSING=()
  RUN_DIR=$BATS_TEST_TMPDIR
}

# installed <products JSON> <pins JSON> — what the cluster records.
installed() {
  PRODUCTS_STATE=$1 PINS_STATE=$2
  state_data() {
    case $1 in
      "$STATE_PRODUCTS_CM") echo "$PRODUCTS_STATE" ;;
      "$STATE_VERSION_CM") jq -cn --arg p "$PINS_STATE" '{tag: "v0.3.7", pinned: $p}' ;;
    esac
  }
  state_version() { state_data "$STATE_VERSION_CM"; }
  version_data() { state_data "$STATE_VERSION_CM"; }
}

@test "UPD: version_lt compares versions, the v aside" {
  version_lt v0.3.4 v0.3.10
  version_lt 0.1.0 0.2.0
  run version_lt v0.3.5 v0.3.5
  [ "$status" -ne 0 ]
  run version_lt v1.0.0 v0.9.9
  [ "$status" -ne 0 ]
}

@test "UPD-03: update without a terminal and without --yes: code 2, nothing read" {
  run bash -c "bash '$SCRIPT' update --no-color </dev/null"
  [ "$status" -eq 2 ]
  [[ $output == *"--yes"* ]]
  not_called "kubectl"
}

@test "R23: --to needs a service and a version of its form; the service is a known one" {
  run bash "$SCRIPT" update --to v1.0.0 --yes --no-color
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" update nabu-core --to 1.0 --yes --no-color
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" update mcp-servers --to v1.0.0 --yes --no-color
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" update nabu-api --yes --no-color
  [ "$status" -eq 2 ]
  [[ $output == *"nabu-core nabu-web"* ]]
  run bash "$SCRIPT" install --to v1.0.0
  [ "$status" -eq 2 ]
}

@test "R23: pins replace the versions of the set for install too" {
  installed '{}' '{"nabu-core":"v0.4.0"}'
  apply_pins
  [ "$NABU_CORE_VERSION" = v0.4.0 ]
  [ "$NABU_WEB_VERSION" = "$(grep '^NABU_WEB_VERSION=' "$ROOT/config/versions.env" | cut -d= -f2)" ]
}

@test "UPD-04 (U): the plan shows installed and target versions, a pin included" {
  installed '{"nabu-core":"v0.3.4","nabu-web":"v0.3.4"}' '{}'
  NABU_CORE_VERSION=v0.4.0
  run update_plan
  [[ ${lines[0]} == $'nabu-core\tv0.3.4\tv0.4.0' ]]
  [[ ${lines[1]} == $'nabu-web\tv0.3.4\t'* ]]
  UPDATE_SERVICE=nabu-web
  run update_plan
  [ "${#lines[@]}" -eq 1 ]
}

@test "UPD-05: going back without the annotation of the chart: code 2" {
  hm() { echo "apiVersion: v2"; }
  run check_downgrades $'nabu-core\tv0.4.0\tv0.3.4'
  [ "$status" -eq 2 ]
  [[ $output == *"nabu-core v0.4.0 → v0.3.4"* && $output == *"nothing was changed"* ]]
}

@test "UPD-05: the chart allows going back down to its annotation, not below" {
  hm() { printf 'apiVersion: v2\nannotations:\n  greenongrey.tech/downgrade-safe-to: "v0.3.0"\n'; }
  run check_downgrades $'nabu-core\tv0.4.0\tv0.3.4'
  [ "$status" -eq 0 ]
  run check_downgrades $'nabu-core\tv0.4.0\tv0.2.9'
  [ "$status" -eq 2 ]
  # Forward and the same version need no consent.
  hm() { echo "apiVersion: v2"; }
  run check_downgrades $'nabu-core\tv0.3.4\tv0.4.0\nnabu-web\tv0.3.4\tv0.3.4\nhammurapi-core\t-\tv0.3.8'
  [ "$status" -eq 0 ]
}

@test "UPD-08: built-in storages: the plan reminds of a backup" {
  run print_plan ""
  [[ $output == *"back them up first"* ]]
  POSTGRES_MODE=external KAFKA_MODE=external S3_MODE=external
  run print_plan ""
  [[ $output != *"back them up"* ]]
}

@test "UPD-06: the checks of the stand fail: code 15, nothing is changed" {
  cluster_reachable() { return 0; }
  restore_config() { :; }
  run_checks() { CHECK_RESULTS=("pods|fail|a pod is not ready"); return 1; }
  ASSUME_YES=1 LOGS_DIR=$BATS_TEST_TMPDIR/logs
  run cmd_update
  [ "$status" -eq 15 ]
  [[ $output == *"a pod is not ready"* ]]
  not_called "apply"
  not_called "upgrade"
}

@test "UPD-02: --dry-run shows the plan and changes nothing" {
  cluster_reachable() { return 0; }
  restore_config() { :; }
  run_checks() { return 0; }
  installed '{"nabu-core":"v0.3.4","nabu-web":"v0.3.4"}' '{}'
  write_pins() { echo "write_pins $*" >>"$CALLS"; }
  DRY_RUN=1 LOGS_DIR=$BATS_TEST_TMPDIR/logs COMMAND=update
  run cmd_update
  [ "$status" -eq 0 ]
  [[ $output == *nabu-core*v0.3.4*"$NABU_CORE_VERSION"* ]]
  not_called write_pins
  not_called "upgrade"
  echo "${lines[-1]}" | jq -e '.command == "update" and .updated == [] and (.skipped | index("nabu-core"))'
}

@test "R23: update <service> --to pins it; update <service> removes its pin; update removes all" {
  cluster_reachable() { return 0; }
  restore_config() { :; }
  run_checks() { return 0; }
  installed '{"nabu-core":"v0.3.4","nabu-web":"v0.3.4"}' '{"nabu-web":"v0.3.9"}'
  write_pins() { echo "pins $1" >>"$CALLS"; }
  run_checks() { return 0; }
  acquire_lock() { :; }
  deploy_products_of() { echo "deploy $1 $NABU_CORE_VERSION" >>"$CALLS"; }
  install_steps() { echo "install_steps" >>"$CALLS"; }
  ASSUME_YES=1 LOGS_DIR=$BATS_TEST_TMPDIR/logs COMMAND=update
  UPDATE_SERVICE=nabu-core UPDATE_TO=v0.3.6
  run cmd_update
  [ "$status" -eq 0 ]
  called 'pins {"nabu-web":"v0.3.9","nabu-core":"v0.3.6"}'
  called "deploy nabu-core v0.3.6"
  : >"$CALLS"
  UPDATE_TO=""
  run cmd_update
  called 'pins {"nabu-web":"v0.3.9"}'
  : >"$CALLS"
  UPDATE_SERVICE=""
  run cmd_update
  called 'pins {}'
  called install_steps
}

@test "UPD-07 (U): a failed service stops the update; the rest of the plan is skipped" {
  UPDATE_PLAN=$'nabu-core\tv0.3.4\tv0.3.5\nnabu-web\tv0.3.4\tv0.3.5\nhammurapi-core\tv0.3.8\tv0.3.9\nhammurapi-web\tv0.3.7\tv0.3.8'
  RESULT_UPDATED=(nabu-core) RESULT_FAILED=(nabu-web)
  COMMAND=update RUN_DIR=$BATS_TEST_TMPDIR
  collect_diagnostics() { :; }
  run on_update_exit 13
  echo "${lines[-1]}" | jq -e '.updated == ["nabu-core"] and .failed == ["nabu-web"]
    and .skipped == ["hammurapi-core", "hammurapi-web"] and .code == 13'
}

@test "R23: write_version keeps the pins" {
  installed '{}' '{"nabu-core":"v0.4.0"}'
  kc() { echo "kubectl $*" >>"$CALLS"; }
  apply_stdin() { :; }
  write_version
  called 'pinned={"nabu-core":"v0.4.0"}'
}

@test "R23: update of a service that is not part of the install: code 2, nothing rolled out" {
  cluster_reachable() { return 0; }
  restore_config() { :; }
  run_checks() { return 0; }
  installed '{}' '{}'
  deploy_products_of() { echo "deploy $1" >>"$CALLS"; }
  ASSUME_YES=1 LOGS_DIR=$BATS_TEST_TMPDIR/logs COMMAND=update UPDATE_SERVICE=hammurapi-core
  run cmd_update
  [ "$status" -eq 2 ]
  not_called deploy
}

@test "R23: a failed rollout stores no pin" {
  cluster_reachable() { return 0; }
  restore_config() { :; }
  run_checks() { return 0; }
  installed '{"nabu-core":"v0.3.4"}' '{}'
  write_pins() { echo "pins $1" >>"$CALLS"; }
  acquire_lock() { :; }
  products_preflight() { :; }
  deploy_products_of() { die 26 "failed"; }
  ASSUME_YES=1 LOGS_DIR=$BATS_TEST_TMPDIR/logs COMMAND=update UPDATE_SERVICE=nabu-core UPDATE_TO=v9.9.9
  run cmd_update
  [ "$status" -eq 26 ]
  not_called pins
}

@test "UPD-05: an unreadable chart is a failure of the registry, not a refusal" {
  hm() { return 1; }
  run check_downgrades $'nabu-core\tv0.4.0\tv0.3.4'
  [ "$status" -eq 14 ]
}

@test "R23: a failed read of installer-version stops the run instead of losing the pins" {
  kc() { return 1; }
  run pinned_versions
  [ "$status" -eq 12 ]
}
