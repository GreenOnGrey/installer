#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 R9, tech §6: a probe that did not run names why, and the images of the probes are
# pulled before the checks race their first pull.

load helpers

setup() {
  setup_stubs
  load_script
  PROBE_RUN="test"
  CHECKS_PROBE=checks-probe-test
  LOG_PROBE=log-probe-test
  CHECK_RESULTS=()
}

@test "CHK-01: a storage probe that waits for its image names the reason, not a bare timeout" {
  kc() {
    case "$*" in
      *"get job storage-probe-test"*) echo "0/0" ;;
      *"get pod -l job-name=storage-probe-test"*) echo "probe-pod" ;;
      *"spec.containers"*) echo "postgres" ;;
      *"state.terminated.exitCode"*) : ;;
      *"logs probe-pod -c postgres"*) : ;;
      *"waiting.reason"*) echo "ImagePullBackOff" ;;
      *"status.phase"*) echo "Pending" ;;
      *) return 0 ;;
    esac
  }
  run run_probe_job storage-probe 0 <<<"apiVersion: v1"
  [ "$status" -eq 1 ]
  [[ $output == *"fail|postgres: ImagePullBackOff"* ]]
}

@test "CHK-02: a log probe that did not start says so instead of 'logs do not reach VictoriaLogs'" {
  kc() {
    case "$*" in
      *"create -f -"*) cat >/dev/null ;;
      *"wait --for=condition=Ready pod/log-probe-test"*) return 1 ;;
      *"status.phase"*) echo "Pending" ;;
      *"waiting.reason"*) echo "ImagePullBackOff" ;;
      *) return 0 ;;
    esac
  }
  # In the current shell: `run` would keep CHECK_RESULTS in its subshell.
  check_logs
  [[ ${CHECK_RESULTS[*]} == *"logs|fail|the probe pod log-probe-test did not start: ImagePullBackOff"* ]]
  [[ ${CHECK_RESULTS[*]} != *"logs do not reach"* ]]
}

@test "CHK-03: a Grafana data source that does not answer keeps the answer of Grafana" {
  probe_curl() { echo '{"database":"ok"}'; }
  kc() {
    case "$*" in
      *"exec checks-probe-test"*) echo '{"status":"ERROR","message":"Plugin not found: victoriametrics-logs-datasource"}' ;;
      *) return 0 ;;
    esac
  }
  check_grafana
  [[ ${CHECK_RESULTS[*]} == *"grafana|fail|data sources do not answer:"*"Plugin not found"* ]]
}

@test "CHK-05: a node under memory pressure fails the resources check and names the pressure" {
  kc() {
    case "$*" in
      *"get nodes -o json"*) echo '{"items":[{"status":{"conditions":[{"type":"MemoryPressure","status":"True"}]}}]}' ;;
      *) return 0 ;;
    esac
  }
  check_resources
  [[ ${CHECK_RESULTS[*]} == *"resources|fail|node pressure: MemoryPressure"* ]]
  [[ ${CHECK_RESULTS[*]} == *"docling"* ]]
}

@test "CHK-06: a machine out of memory fails the check and names the process that holds the memory" {
  printf 'MemTotal: 16632200 kB\nMemFree: 300000 kB\nMemAvailable: 220000 kB\n' >"$BATS_TEST_TMPDIR/meminfo"
  MEMINFO_FILE=$BATS_TEST_TMPDIR/meminfo
  ps() { echo "12078304 193718 java"; }
  check_host_memory
  [[ ${CHECK_RESULTS[*]} == *"memory|fail|the machine is short of memory: 0.2 GiB available of 15.9 GiB"* ]]
  [[ ${CHECK_RESULTS[*]} == *"java (pid 193718) holds 11.5 GiB"* ]]
}

@test "CHK-06: a machine with less than a tenth left warns, with plenty it passes, an existing cluster is not checked" {
  ps() { echo "900000 42 java"; }
  printf 'MemTotal: 16632200 kB\nMemAvailable: 1200000 kB\n' >"$BATS_TEST_TMPDIR/meminfo"
  MEMINFO_FILE=$BATS_TEST_TMPDIR/meminfo
  check_host_memory
  [[ ${CHECK_RESULTS[*]} == *"memory|warn|"*"java (pid 42)"* ]]
  printf 'MemTotal: 16632200 kB\nMemAvailable: 12000000 kB\n' >"$BATS_TEST_TMPDIR/meminfo"
  CHECK_RESULTS=()
  check_host_memory
  [[ ${CHECK_RESULTS[*]} == *"memory|ok|11.4 GiB available of 15.9 GiB"* ]]
  CHECK_RESULTS=()
  INSTALL_TARGET=external check_host_memory
  [[ -z ${CHECK_RESULTS[*]} ]]
}

@test "CHK-04: the images of the probes are pulled once after the node is ready" {
  PROBE_BUSYBOX_IMAGE=busybox:1 PROBE_CURL_IMAGE=curl:1 PROBE_KCAT_IMAGE=kcat:1 \
    PROBE_S3_IMAGE=aws:1 POSTGRES_IMAGE=postgres:1
  mk() { echo "mk $*" >>"$CALLS"; return 0; }
  run preload_probe_images
  [ "$status" -eq 0 ]
  [[ $output == *"checks: images of the probes are ready"* ]]
  called "crictl pull busybox:1"
  called "crictl pull curl:1"
  called "crictl pull kcat:1"
  called "crictl pull aws:1"
  called "crictl pull postgres:1"
}

@test "CHK-04: an image that does not come is a warning with its name" {
  PROBE_BUSYBOX_IMAGE=busybox:1 PROBE_CURL_IMAGE=curl:1 PROBE_KCAT_IMAGE=kcat:1 \
    PROBE_S3_IMAGE=aws:1 POSTGRES_IMAGE=postgres:1
  mk() { echo "no such image" >&2; return 1; }
  run preload_probe_images
  [ "$status" -eq 0 ]
  [[ $output == *"checks: image busybox:1 is not pulled"* ]]
  [[ $output != *"images of the probes are ready"* ]]
}
