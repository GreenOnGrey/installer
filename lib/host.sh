# shellcheck shell=bash
# Checks of the machine before installing (R1). They change nothing.

OS_RELEASE_FILE=${OS_RELEASE_FILE:-/etc/os-release}
MEMINFO_FILE=${MEMINFO_FILE:-/proc/meminfo}

host_arch() { uname -m; }
host_cpus() { nproc; }
# host_free_disk_gb <path> — free space, GB.
host_free_disk_gb() { df -P -BG "$1" | awk 'NR==2 {gsub("G","",$4); print $4}'; }
host_has_sudo() { [[ $(id -u) == 0 ]] || sudo -n true 2>/dev/null; }

check_host() {
  step host
  local id version arch cpus mem_kb mem_gb disk
  [[ -r $OS_RELEASE_FILE ]] || die "$E_HOST" "$OS_RELEASE_FILE not found: only Debian 13 is supported"
  # shellcheck source=/dev/null
  id=$(. "$OS_RELEASE_FILE" && echo "${ID:-}")
  # shellcheck source=/dev/null
  version=$(. "$OS_RELEASE_FILE" && echo "${VERSION_ID:-}")
  if [[ $id != debian || $version != 13 ]]; then
    die "$E_HOST" "unsupported OS: ${id:-?} ${version:-?}; Debian 13 is required"
  fi
  arch=$(host_arch)
  [[ $arch == x86_64 ]] || die "$E_HOST" "unsupported architecture: $arch; x86_64 is required"
  host_has_sudo || die "$E_HOST" "passwordless sudo is required (check: sudo -n true)"
  cpus=$(host_cpus)
  ((cpus >= HOST_MIN_CPUS)) || die "$E_HOST" "not enough CPUs: $cpus, at least $HOST_MIN_CPUS required"
  mem_kb=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO_FILE")
  mem_gb=$((mem_kb / 1024 / 1024))
  ((mem_gb >= HOST_MIN_MEMORY_GB)) || die "$E_HOST" "not enough memory: ${mem_gb} GB, at least ${HOST_MIN_MEMORY_GB} GB required"
  # Free disk is only needed before the cluster exists: on a repeated `up` the
  # stand itself already takes that space.
  if ! profile_exists; then
    disk=$(host_free_disk_gb "${DOCKER_ROOT:-/var/lib}")
    ((disk >= HOST_MIN_DISK_GB)) || die "$E_HOST" "not enough disk space: ${disk} GB, at least ${HOST_MIN_DISK_GB} GB required"
  fi
  ok "machine is suitable: Debian $version, $arch, $cpus CPU, ${mem_gb} GB"
}
