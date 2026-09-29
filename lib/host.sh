# shellcheck shell=bash
# Проверки машины перед установкой (R1). Ничего не меняют.

OS_RELEASE_FILE=${OS_RELEASE_FILE:-/etc/os-release}
MEMINFO_FILE=${MEMINFO_FILE:-/proc/meminfo}

host_arch() { uname -m; }
host_cpus() { nproc; }
# host_free_disk_gb <путь> — свободное место, ГБ.
host_free_disk_gb() { df -P -BG "$1" | awk 'NR==2 {gsub("G","",$4); print $4}'; }
host_has_sudo() { [[ $(id -u) == 0 ]] || sudo -n true 2>/dev/null; }

check_host() {
  step host
  local id version arch cpus mem_kb mem_gb disk
  [[ -r $OS_RELEASE_FILE ]] || die "$E_HOST" "не найден $OS_RELEASE_FILE — поддерживается только Debian 13"
  # shellcheck source=/dev/null
  id=$(. "$OS_RELEASE_FILE" && echo "${ID:-}")
  # shellcheck source=/dev/null
  version=$(. "$OS_RELEASE_FILE" && echo "${VERSION_ID:-}")
  if [[ $id != debian || $version != 13 ]]; then
    die "$E_HOST" "неподдерживаемая ОС: ${id:-?} ${version:-?}; нужна Debian 13"
  fi
  arch=$(host_arch)
  [[ $arch == x86_64 ]] || die "$E_HOST" "неподдерживаемая архитектура: $arch; нужна x86_64"
  host_has_sudo || die "$E_HOST" "нужен sudo без пароля (проверка: sudo -n true)"
  cpus=$(host_cpus)
  ((cpus >= HOST_MIN_CPUS)) || die "$E_HOST" "мало CPU: $cpus, нужно не меньше $HOST_MIN_CPUS"
  mem_kb=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO_FILE")
  mem_gb=$((mem_kb / 1024 / 1024))
  ((mem_gb >= HOST_MIN_MEMORY_GB)) || die "$E_HOST" "мало памяти: ${mem_gb} ГБ, нужно не меньше ${HOST_MIN_MEMORY_GB} ГБ"
  # Место на диске нужно только до создания кластера: на повторном `up` его
  # уже занимает сам стенд.
  if ! profile_exists; then
    disk=$(host_free_disk_gb "${DOCKER_ROOT:-/var/lib}")
    ((disk >= HOST_MIN_DISK_GB)) || die "$E_HOST" "мало места на диске: ${disk} ГБ, нужно не меньше ${HOST_MIN_DISK_GB} ГБ"
  fi
  ok "машина подходит: Debian $version, $arch, $cpus CPU, ${mem_gb} ГБ"
}
