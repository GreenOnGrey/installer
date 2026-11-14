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
  # The runner of CI has its own Docker: a test that needs one says so.
  docker_engine_version() { :; }
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
  [[ $output == *"machine is suitable: debian 13"* ]]
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

@test "HOST-05: MK_MEMORY above the memory of the machine: code 10 before anything installs" {
  meminfo_gb 15
  MK_MEMORY=17g
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"MK_MEMORY=17g is more than the memory of this machine (15 GB)"* ]]
  not_called apt-get
  MK_MEMORY=15g
  run check_host
  [ "$status" -eq 0 ]
  # The size applies only when the profile is created.
  MK_MEMORY=17g
  mkdir -p "$MINIKUBE_HOME/profiles/greenongrey"
  echo '{}' >"$MINIKUBE_HOME/profiles/greenongrey/config.json"
  run check_host
  [ "$status" -eq 0 ]
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

@test "R9: RHEL, Rocky and AlmaLinux 9 and 10 fit" {
  host_rpm_installed() { return 1; }
  local d
  for d in "rhel 9.4" "rocky 9.5" "almalinux 10.0" "rocky 10.1"; do
    # shellcheck disable=SC2086
    os_release $d
    run check_host
    [ "$status" -eq 0 ] || { echo "$d: $output"; return 1; }
  done
}

@test "R9: Ubuntu 24.04 and 26.04 LTS fit" {
  host_deb_installed() { return 1; }
  host_snap_installed() { return 1; }
  local d
  for d in "ubuntu 24.04" "ubuntu 26.04"; do
    # shellcheck disable=SC2086
    os_release $d
    run check_host
    [ "$status" -eq 0 ] || { echo "$d: $output"; return 1; }
    [[ $output == *"machine is suitable: $d"* ]]
  done
}

@test "TGT-04: other systems and versions: code 10, the supported ones are named" {
  host_rpm_installed() { return 1; }
  host_deb_installed() { return 1; }
  host_snap_installed() { return 1; }
  local d
  for d in "ubuntu 22.04" "ubuntu 25.10" "rocky 8.10" "centos 9" "fedora 41"; do
    # shellcheck disable=SC2086
    os_release $d
    run check_host
    [ "$status" -eq 10 ] || { echo "$d: $status"; return 1; }
    [[ $output == *"Debian 13, Ubuntu 24.04 or 26.04 LTS, RHEL, Rocky or AlmaLinux 9 and 10"* ]]
  done
  # A derivative of Ubuntu on the base of 24.04 is not Ubuntu (tech decision 49).
  printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="22"\nUBUNTU_CODENAME=noble\n' >"$OS_RELEASE_FILE"
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"unsupported OS: linuxmint 22"* ]]
}

@test "TGT-05: Ubuntu with docker.io or the snap of Docker: code 10 with the reason, nothing removed" {
  os_release ubuntu 24.04
  stub apt-get 'exit 0'
  stub dpkg-query '[[ $* == *docker.io* ]] && echo "install ok installed"'
  stub snap 'exit 1'
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"docker.io conflicts with Docker CE"* && $output == *"nothing was removed"* ]]
  not_called apt-get

  stub dpkg-query 'exit 1'
  stub snap '[[ $* == "list docker" ]]'
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"snap docker conflicts with Docker CE"* ]]
}

@test "TGT-14: Docker of the machine is used: docker.io on Ubuntu, podman beside Docker on EL pass" {
  docker_engine_version() { echo 28.2.2; }
  docker_managed() { return 1; }
  stub snap 'exit 1'
  os_release ubuntu 24.04
  stub dpkg-query 'echo "install ok installed"'
  run check_host
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  os_release rocky 9.4
  stub rpm 'exit 0'
  run check_host
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "TGT-14: Docker of the machine older than the minimum: code 10, update or remove it" {
  docker_engine_version() { echo 19.03.13; }
  docker_managed() { return 1; }
  stub snap 'exit 1'
  stub dpkg-query 'exit 1'
  local d
  for d in "debian 13" "ubuntu 24.04" "rocky 9.4"; do
    # shellcheck disable=SC2086
    os_release $d
    run check_host
    [ "$status" -eq 10 ] || { echo "$d: $status $output"; return 1; }
    [[ $output == *"Docker 19.03.13 of the machine is older than $DOCKER_MIN_VERSION: update or remove it"* ]]
  done
}

@test "R9: the Docker Engine of the machine is the one with dockerd and docker.service" {
  # shellcheck source=../../lib/host.sh
  source "$ROOT/lib/host.sh"
  stub dockerd 'echo "Docker version 28.2.2, build 28.2.2-0ubuntu1~24.04.1"'
  stub systemctl 'echo "docker.service enabled enabled"'
  [ "$(docker_engine_version)" = 28.2.2 ]
  # No docker.service: the snap of Docker or a dockerd without its unit.
  stub systemctl 'echo "0 unit files listed."'
  # shellcheck disable=SC2218 # restored from lib/host.sh above, not the stub of setup
  [ -z "$(docker_engine_version)" ]
}

@test "TGT-05: the snap of Docker stops the run even beside a Docker Engine; Debian checks what docker-ce replaces" {
  docker_engine_version() { echo 28.2.2; }
  os_release ubuntu 26.04
  stub dpkg-query 'exit 1'
  stub snap '[[ $* == "list docker" ]]'
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"snap docker conflicts with Docker CE"* ]]

  docker_engine_version() { :; }
  os_release debian 13
  stub snap 'exit 1'
  stub dpkg-query '[[ $* == *runc* ]] && echo "install ok installed"'
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"runc conflicts with Docker CE"* ]]
}

@test "TGT-14: the Docker that the installer locked may be updated, so its conflicts are still checked" {
  docker_engine_version() { echo 29.0.0; }
  docker_managed() { return 0; }
  os_release rocky 9.4
  stub rpm '[[ $* == *podman* ]]'
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"podman conflicts with Docker CE"* ]]
}

@test "TGT-05: EL with podman: code 10 with the reason, nothing removed" {
  os_release rocky 9.4
  stub rpm '[[ $* == *podman* ]]'
  stub dnf 'exit 0'
  run check_host
  [ "$status" -eq 10 ]
  [[ $output == *"podman conflicts with Docker CE"* && $output == *"nothing was removed"* ]]
  not_called dnf
}
