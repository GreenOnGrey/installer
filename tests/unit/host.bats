#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# R1: checks of the machine before installing.

load helpers

setup() {
  setup_stubs
  load_script
  os_release debian 13
  meminfo_gb 16
  host_arch() { echo x86_64; }
  host_cpus() { echo 4; }
  host_has_sudo() { return 0; }
  host_free_disk_gb() { echo 100; }
}

@test "HOST-01: Debian 12: code 10, nothing installs" {
  os_release debian 12
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"unsupported OS: debian 12"* ]]
  not_called apt-get
  not_called curl
}

@test "HOST-01: Debian 13 passes" {
  run check_host
  [ "$status" -eq 0 ]
  [[ $output == *"machine is suitable: Debian 13"* ]]
}

@test "HOST-02: architecture aarch64: code 10" {
  host_arch() { echo aarch64; }
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"aarch64"* ]]
}

@test "HOST-03: no passwordless sudo: code 10" {
  host_has_sudo() { return 1; }
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"sudo"* ]]
}

@test "HOST-04: not enough memory: code 10 with the required and actual values" {
  meminfo_gb 8
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"8 GB"* && $output == *"15 GB"* ]]
}

@test "HOST-04: not enough CPUs: code 10" {
  host_cpus() { echo 2; }
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"CPUs: 2"* ]]
}

@test "R1: not enough disk before the cluster exists: code 10" {
  host_free_disk_gb() { echo 20; }
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"20 GB"* ]]
}

@test "R4: a repeated up does not check disk space" {
  host_free_disk_gb() { echo 20; }
  mkdir -p "$MINIKUBE_HOME/profiles/greenongrey"
  echo '{}' >"$MINIKUBE_HOME/profiles/greenongrey/config.json"
  run check_host
  [ "$status" -eq 0 ]
}
