#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# R1: проверки машины перед установкой.

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

@test "HOST-01: Debian 12 — код 10, ничего не устанавливается" {
  os_release debian 12
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"неподдерживаемая ОС: debian 12"* ]]
  not_called apt-get
  not_called curl
}

@test "HOST-01: Debian 13 проходит проверку" {
  run check_host
  [ "$status" -eq 0 ]
  [[ $output == *"машина подходит: Debian 13"* ]]
}

@test "HOST-02: архитектура aarch64 — код 10" {
  host_arch() { echo aarch64; }
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"aarch64"* ]]
}

@test "HOST-03: нет sudo без пароля — код 10" {
  host_has_sudo() { return 1; }
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"sudo"* ]]
}

@test "HOST-04: мало памяти — код 10 с требуемым и фактическим значением" {
  meminfo_gb 8
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"8 ГБ"* && $output == *"15 ГБ"* ]]
}

@test "HOST-04: мало CPU — код 10" {
  host_cpus() { echo 2; }
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"CPU: 2"* ]]
}

@test "R1: мало места на диске до создания кластера — код 10" {
  host_free_disk_gb() { echo 20; }
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"20 ГБ"* ]]
}

@test "R4: на повторном up место на диске не проверяется" {
  host_free_disk_gb() { echo 20; }
  mkdir -p "$MINIKUBE_HOME/profiles/hammurapi"
  echo '{}' >"$MINIKUBE_HOME/profiles/hammurapi/config.json"
  run check_host
  [ "$status" -eq 0 ]
}
