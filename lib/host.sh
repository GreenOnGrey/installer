# shellcheck shell=bash
# Checks of the machine before installing (R1). They change nothing.

OS_RELEASE_FILE=${OS_RELEASE_FILE:-/etc/os-release}
MEMINFO_FILE=${MEMINFO_FILE:-/proc/meminfo}

host_arch() { uname -m; }
host_cpus() { nproc; }
# host_free_disk_gb <path> — free space, GB.
host_free_disk_gb() { df -P -BG "$1" | awk 'NR==2 {gsub("G","",$4); print $4}'; }
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

# host_rpm_installed <package> — for the checks of conflicts.
host_rpm_installed() { rpm -q "$1" >/dev/null 2>&1; }

# check_el_conflicts — docker-ce conflicts with these. The packages are the user's, so they stay.
check_el_conflicts() {
  local p found=()
  for p in podman runc; do
    if host_rpm_installed "$p"; then found+=("$p"); fi
  done
  ((${#found[@]} == 0)) ||
    die "$E_HOST" "${found[*]} conflicts with Docker CE: remove it and run up again (nothing was removed)"
}

check_host() {
  step host
  local id version arch cpus mem_kb mem_gb disk
  [[ -r $OS_RELEASE_FILE ]] || die "$E_HOST" "$OS_RELEASE_FILE not found: Debian 13, RHEL, Rocky or AlmaLinux 9 and 10 are supported"
  id=$(os_field ID)
  version=$(os_field VERSION_ID)
  if os_is_el && [[ $(os_major) =~ ^(9|10)$ ]]; then
    check_el_conflicts
  elif [[ $id != debian || $version != 13 ]]; then
    die "$E_HOST" "unsupported OS: ${id:-?} ${version:-?}; Debian 13, RHEL, Rocky or AlmaLinux 9 and 10 are required"
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
  ok "machine is suitable: $id $version, $arch, $cpus CPU, ${mem_gb} GB"
}
