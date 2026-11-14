# shellcheck shell=bash
# Checks of the machine before installing (R1). They change nothing.

OS_RELEASE_FILE=${OS_RELEASE_FILE:-/etc/os-release}
MEMINFO_FILE=${MEMINFO_FILE:-/proc/meminfo}
SUPPORTED_OS="Debian 13, Ubuntu 24.04 or 26.04 LTS, RHEL, Rocky or AlmaLinux 9 and 10"

host_arch() { uname -m; }
host_cpus() { nproc; }
# host_free_disk_gb <path> — free space, GB.
host_free_disk_gb() { df -P -BG "$1" | awk 'NR==2 {gsub("G","",$4); print $4}'; }
# host_memory_mib — the memory of the machine, MiB: the most a minikube profile can get (RSRC_OVER_ALLOC_MEM above
# it); empty if meminfo cannot be read.
host_memory_mib() { awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' "$MEMINFO_FILE" 2>/dev/null || true; }
# mk_memory_mib [value] — MK_MEMORY in MiB; minikube reads a number without a unit as MB. Empty if not a size.
mk_memory_mib() {
  local v=${1:-$MK_MEMORY} n
  [[ $v =~ ^[0-9]+[gGmM]?$ ]] || return 0
  n=${v%[gGmM]}
  if [[ $v == *[gG] ]]; then echo $((n * 1024)); else echo "$n"; fi
}
# mk_memory_fits [value] — the size is no more than the machine has; true when either is unknown (validate_config
# and minikube judge those).
mk_memory_fits() {
  local want host
  want=$(mk_memory_mib "${1:-$MK_MEMORY}") host=$(host_memory_mib)
  [[ -z $want || -z $host ]] || ((want <= host))
}

host_has_sudo() { [[ $(id -u) == 0 ]] || sudo -n true 2>/dev/null; }

# os_field <name> — a field of os-release.
os_field() {
  # shellcheck source=/dev/null
  [[ -r $OS_RELEASE_FILE ]] && (. "$OS_RELEASE_FILE" && eval "echo \"\${$1:-}\"")
}

# os_major — the major version: 9 of 9.4.
os_major() { local v; v=$(os_field VERSION_ID); echo "${v%%.*}"; }

# os_is_el — RHEL and its rebuilds (FTR.INFRA.INST-0001 R9).
os_is_el() {
  case $(os_field ID) in
    rhel | rocky | almalinux) return 0 ;;
    *) return 1 ;;
  esac
}

# os_is_ubuntu — the supported LTS releases only, by ID: derivatives (ID_LIKE=ubuntu) are not checked
# (FTR.INFRA.INST-0001 R9, tech decision 49).
os_is_ubuntu() {
  [[ $(os_field ID) == ubuntu ]] || return 1
  case $(os_field VERSION_ID) in
    24.04 | 26.04) return 0 ;;
    *) return 1 ;;
  esac
}

# host_rpm_installed <package> — for the checks of conflicts.
host_rpm_installed() { rpm -q "$1" >/dev/null 2>&1; }
# host_deb_installed <package>, host_snap_installed <snap> — the same on Debian and Ubuntu.
host_deb_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]; }
host_snap_installed() { command -v snap >/dev/null 2>&1 && snap list "$1" >/dev/null 2>&1; }

# docker_engine_version — the version of the Docker Engine of the machine from packages (docker-ce, docker.io,
# moby): the one with dockerd and docker.service; empty without it. The snap of Docker has neither and does not count.
# Outputs are read whole, not piped into grep -q: under pipefail an early grep would fail the writer.
docker_engine_version() {
  local units
  command -v dockerd >/dev/null 2>&1 || return 0
  units=$(systemctl list-unit-files docker.service 2>/dev/null || true)
  grep -q '^docker\.service' <<<"$units" || return 0
  dockerd --version 2>/dev/null | sed -n 's/^Docker version \([0-9][0-9.]*\).*/\1/p'
}

# docker_managed — the installer put this Docker here: its packages are held (apt-mark) or locked (dnf versionlock).
# Only such a Docker follows the versions of versions.env; any other stays as the user keeps it. A docker-ce that the
# user held is taken for the installer's too (tech decision 50).
docker_managed() {
  local held
  if os_is_el; then
    held=$(dnf versionlock list 2>/dev/null || true)
    grep -q '^docker-ce-[0-9]' <<<"$held"
  else
    held=$(apt-mark showhold 2>/dev/null || true)
    grep -qx docker-ce <<<"$held"
  fi
}

# docker_of_machine — a Docker Engine of the machine that the installer uses as it is (FTR.INFRA.INST-0001 R9):
# then nothing of Docker installs, and the packages docker-ce would replace conflict with nothing. The installer's own
# Docker is not such: it may be updated, so its conflicts are checked. Too old an engine is code 10.
docker_of_machine() {
  local v
  v=$(docker_engine_version)
  [[ -n $v ]] && ! docker_managed || return 1
  [[ $(printf '%s\n%s\n' "$DOCKER_MIN_VERSION" "$v" | sort -V | head -1) == "$DOCKER_MIN_VERSION" ]] ||
    die "$E_HOST" "Docker $v of the machine is older than $DOCKER_MIN_VERSION: update or remove it and run up again"
}

# check_el_conflicts — docker-ce conflicts with these. The packages are the user's, so they stay.
check_el_conflicts() {
  local p found=()
  for p in podman runc; do
    if host_rpm_installed "$p"; then found+=("$p"); fi
  done
  ((${#found[@]} == 0)) ||
    die "$E_HOST" "${found[*]} conflicts with Docker CE: remove it and run up again (nothing was removed)"
}

# check_deb_conflicts — Debian and Ubuntu without a Docker Engine to use: apt would remove these packages for
# docker-ce on its own. They are the user's, so they stay.
check_deb_conflicts() {
  local p found=()
  for p in docker.io containerd runc podman-docker; do
    if host_deb_installed "$p"; then found+=("$p"); fi
  done
  ((${#found[@]} == 0)) ||
    die "$E_HOST" "${found[*]} conflicts with Docker CE: remove it and run up again (nothing was removed)"
}

# check_docker_snap — the snap of Docker stops the run even beside another Docker: two daemons fight for the
# socket, and the units of the stand need docker.service, which the snap has not.
check_docker_snap() {
  if host_snap_installed docker; then
    die "$E_HOST" "snap docker conflicts with Docker CE: remove it and run up again (nothing was removed)"
  fi
}

check_host() {
  step host
  local id version arch cpus mem_gb disk
  [[ -r $OS_RELEASE_FILE ]] || die "$E_HOST" "$OS_RELEASE_FILE not found: $SUPPORTED_OS are supported"
  id=$(os_field ID)
  version=$(os_field VERSION_ID)
  if os_is_el && [[ $(os_major) =~ ^(9|10)$ ]]; then
    docker_of_machine || check_el_conflicts
  elif os_is_ubuntu || [[ $id == debian && $version == 13 ]]; then
    check_docker_snap
    docker_of_machine || check_deb_conflicts
  else
    die "$E_HOST" "unsupported OS: ${id:-?} ${version:-?}; $SUPPORTED_OS are required"
  fi
  arch=$(host_arch)
  [[ $arch == x86_64 ]] || die "$E_HOST" "unsupported architecture: $arch; x86_64 is required"
  host_has_sudo || die "$E_HOST" "passwordless sudo is required (check: sudo -n true)"
  cpus=$(host_cpus)
  ((cpus >= HOST_MIN_CPUS)) || die "$E_HOST" "not enough CPUs: $cpus, at least $HOST_MIN_CPUS required"
  mem_gb=$(($(host_memory_mib) / 1024))
  ((mem_gb >= HOST_MIN_MEMORY_GB)) || die "$E_HOST" "not enough memory: ${mem_gb} GB, at least ${HOST_MIN_MEMORY_GB} GB required"
  # Free disk and the size of the profile matter only before the cluster exists: on a repeated `up` the stand
  # already takes that space, and MK_MEMORY applies only when the profile is created.
  if ! profile_exists; then
    # minikube refuses a profile larger than the machine, but only after Docker and the tools are installed.
    mk_memory_fits ||
      die "$E_HOST" "MK_MEMORY=$MK_MEMORY is more than the memory of this machine (${mem_gb} GB): lower it; 12g holds the stand with all MCP servers"
    disk=$(host_free_disk_gb "${DOCKER_ROOT:-/var/lib}")
    ((disk >= HOST_MIN_DISK_GB)) || die "$E_HOST" "not enough disk space: ${disk} GB, at least ${HOST_MIN_DISK_GB} GB required"
  fi
  ok "machine is suitable: $id $version, $arch, $cpus CPU, ${mem_gb} GB"
}
