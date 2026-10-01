# shellcheck shell=bash
# Общие функции: журнал, коды выхода, повторы, конфигурация.

# Коды выхода (техническая спецификация, п. 1).
readonly E_OK=0 E_UNKNOWN=1 E_USAGE=2 E_HOST=10 E_PREREQ=11 E_CLUSTER=12 E_DEPLOY=13 \
  E_EXTERNAL=14 E_CHECKS=15 E_CANCELLED=16 E_LOCKED=17

STEP=${STEP:-main}
VERBOSE=${VERBOSE:-0}
COLOR=${COLOR:-auto}
RUN_DIR=${RUN_DIR:-}

# Ключи, значения которых нельзя писать прямо в local.env (tech, п. 2).
readonly SECRET_KEYS=(POSTGRES_PASSWORD KAFKA_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY GRAFANA_GITHUB_CLIENT_SECRET)

setup_color() {
  if [[ $COLOR == auto ]]; then
    if [[ -t 1 ]]; then COLOR=1; else COLOR=0; fi
  fi
  if [[ $COLOR == 1 ]]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
  else
    C_RED='' C_GREEN='' C_YELLOW='' C_DIM='' C_RESET=''
  fi
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# log <сообщение> — строка журнала вида «время [шаг] сообщение».
log() { printf '%s %s[%s]%s %s\n' "$(now_utc)" "$C_DIM" "$STEP" "$C_RESET" "$*" >&2; }
ok() { printf '%s %s[%s]%s %s✓%s %s\n' "$(now_utc)" "$C_DIM" "$STEP" "$C_RESET" "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s %s[%s]%s %s!%s %s\n' "$(now_utc)" "$C_DIM" "$STEP" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
debug() { [[ $VERBOSE == 1 ]] && log "$*"; return 0; }

# die <код> <сообщение>
die() {
  local code=$1
  shift
  printf '%s %s[%s]%s %s✗ %s%s\n' "$(now_utc)" "$C_DIM" "$STEP" "$C_RESET" "$C_RED" "$*" "$C_RESET" >&2
  exit "$code"
}

step() { STEP=$1; }

# run_cmd <команда…> — выполняет команду; с --verbose печатает её.
run_cmd() {
  debug "\$ $*"
  "$@"
}

# retry <попытки> <задержка> <команда…> — повторяет сетевые операции.
retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    if ((n >= attempts)); then
      return 1
    fi
    warn "повтор $n/$attempts через ${delay} с: $1"
    sleep "$delay"
    n=$((n + 1))
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

# as_root <команда…> — через sudo, если не root.
as_root() {
  if [[ $(id -u) == 0 ]]; then "$@"; else sudo "$@"; fi
}

# env_keys <файл> — имена ключей KEY=… из env-файла.
env_keys() {
  sed -nE 's/^[[:space:]]*([A-Z_][A-Z0-9_]*)=.*/\1/p' "$1"
}

# load_config — defaults.env → local.env → окружение (флаги применяются раньше,
# через экспорт переменных в точке входа).
load_config() {
  local root=$1 local_file=$2 key
  local -A from_env=()
  local files=("$root/config/versions.env" "$root/config/defaults.env")
  [[ -f $local_file ]] && files+=("$local_file")
  for f in "${files[@]}"; do
    while read -r key; do
      if [[ -n ${!key+x} && -z ${from_env[$key]+x} ]]; then
        from_env[$key]=${!key}
      fi
    done < <(env_keys "$f")
  done
  if [[ -f $local_file ]]; then
    for key in "${SECRET_KEYS[@]}"; do
      if env_keys "$local_file" | grep -qx "$key"; then
        die "$E_USAGE" "$key записан прямо в $local_file; используйте ${key}_FILE или переменную окружения"
      fi
    done
  fi
  set -a
  for f in "${files[@]}"; do
    # shellcheck disable=SC1090
    source "$f"
  done
  set +a
  for key in "${!from_env[@]}"; do
    printf -v "$key" '%s' "${from_env[$key]}"
    export "${key?}"
  done
}

# secret_value <ключ> — значение из переменной окружения или файла <ключ>_FILE.
secret_value() {
  local key=$1 file_key="${1}_FILE"
  if [[ -n ${!key:-} ]]; then
    printf '%s' "${!key}"
  elif [[ -n ${!file_key:-} ]]; then
    [[ -r ${!file_key} ]] || die "$E_USAGE" "$file_key: файл ${!file_key} не читается"
    tr -d '\r\n' <"${!file_key}"
  fi
}

require_param() {
  local mode_name=$1 key=$2
  [[ $mode_name == *=* ]] || mode_name+="=external"
  if [[ -z ${!key:-} ]]; then
    die "$E_USAGE" "$mode_name: не задан параметр $key"
  fi
}

require_secret() {
  local mode_name=$1 key=$2
  [[ $mode_name == *=* ]] || mode_name+="=external"
  if [[ -z $(secret_value "$key") ]]; then
    die "$E_USAGE" "$mode_name: не задан $key (переменная окружения) или ${key}_FILE"
  fi
}

# validate_config — режимы и обязательные параметры внешних хранилищ.
validate_config() {
  local m
  case ${STAND_AUTOSTART:-true} in
    true | false) ;;
    *) die "$E_USAGE" "STAND_AUTOSTART должен быть true или false" ;;
  esac
  for m in POSTGRES_MODE KAFKA_MODE S3_MODE; do
    case ${!m} in
      internal | external) ;;
      *) die "$E_USAGE" "$m должен быть internal или external, а не «${!m}»" ;;
    esac
  done
  if [[ $POSTGRES_MODE == external ]]; then
    local k
    for k in POSTGRES_HOST POSTGRES_PORT POSTGRES_DATABASE POSTGRES_USER POSTGRES_SSLMODE; do
      require_param POSTGRES_MODE "$k"
    done
    require_secret POSTGRES_MODE POSTGRES_PASSWORD
  fi
  if [[ $KAFKA_MODE == external ]]; then
    require_param KAFKA_MODE KAFKA_BOOTSTRAP
    require_param KAFKA_MODE KAFKA_SECURITY_PROTOCOL
    case $KAFKA_SECURITY_PROTOCOL in
      PLAINTEXT) ;;
      SASL_SSL)
        require_param KAFKA_MODE KAFKA_SASL_MECHANISM
        case $KAFKA_SASL_MECHANISM in
          PLAIN | SCRAM-SHA-512 | OAUTHBEARER) ;;
          *) die "$E_USAGE" "KAFKA_SASL_MECHANISM должен быть PLAIN, SCRAM-SHA-512 или OAUTHBEARER" ;;
        esac
        require_param KAFKA_MODE KAFKA_USERNAME
        require_secret KAFKA_MODE KAFKA_PASSWORD
        ;;
      *) die "$E_USAGE" "KAFKA_SECURITY_PROTOCOL должен быть PLAINTEXT или SASL_SSL" ;;
    esac
  fi
  if [[ $S3_MODE == external ]]; then
    for k in S3_ENDPOINT S3_REGION S3_BUCKET S3_PATH_STYLE; do
      require_param S3_MODE "$k"
    done
    require_secret S3_MODE S3_ACCESS_KEY
    require_secret S3_MODE S3_SECRET_KEY
  fi
  [[ $MK_MEMORY =~ ^[0-9]+[gGmM]$ ]] || die "$E_USAGE" "MK_MEMORY: ожидается число с g или m, например 12g"
  validate_public_config
}

# validate_public_config — параметры публичного доступа (PLT.INFRA-0002, R21).
validate_public_config() {
  case ${PUBLIC_ACCESS:-false} in
    true) ;;
    false) return 0 ;;
    *) die "$E_USAGE" "PUBLIC_ACCESS должен быть true или false" ;;
  esac
  require_param PUBLIC_ACCESS=true ACME_EMAIL
  [[ $ACME_EMAIL == *@*.* ]] || die "$E_USAGE" "ACME_EMAIL: нужен адрес электронной почты"
  case ${ACME_ISSUER:-letsencrypt} in
    letsencrypt | letsencrypt-staging) ;;
    *) die "$E_USAGE" "ACME_ISSUER должен быть letsencrypt или letsencrypt-staging" ;;
  esac
  if [[ -n ${PUBLIC_BASE_DOMAIN:-} && ! $PUBLIC_BASE_DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    die "$E_USAGE" "PUBLIC_BASE_DOMAIN: недопустимое имя «$PUBLIC_BASE_DOMAIN»"
  fi
  if [[ -n ${PUBLIC_IP:-} && ! $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "$E_USAGE" "PUBLIC_IP: нужен IPv4-адрес"
  fi
  if [[ -n ${GRAFANA_GITHUB_CLIENT_ID:-} ]]; then
    require_secret PUBLIC_ACCESS=true GRAFANA_GITHUB_CLIENT_SECRET
    require_param PUBLIC_ACCESS=true GRAFANA_GITHUB_ORG
  fi
}

# mem_mib <12g|12288m> — память minikube в МиБ.
mem_mib() {
  local v=${1,,}
  case $v in
    *g) echo $((${v%g} * 1024)) ;;
    *m) echo "${v%m}" ;;
    *) echo "$v" ;;
  esac
}

# to_bytes <количество Kubernetes> — 512Mi, 1Gi, 1536Mi, 1G, 100k, 1024.
to_bytes() {
  local q=$1 n unit
  [[ -z $q ]] && {
    echo 0
    return
  }
  n=${q%%[A-Za-z]*}
  unit=${q#"$n"}
  case $unit in
    Ki) echo $((n * 1024)) ;;
    Mi) echo $((n * 1024 * 1024)) ;;
    Gi) echo $((n * 1024 * 1024 * 1024)) ;;
    Ti) echo $((n * 1024 * 1024 * 1024 * 1024)) ;;
    k) echo $((n * 1000)) ;;
    M) echo $((n * 1000 * 1000)) ;;
    G) echo $((n * 1000 * 1000 * 1000)) ;;
    '') echo "${n%%.*}" ;;
    *) echo 0 ;;
  esac
}

# human_duration <секунды> — «14 мин 32 с».
human_duration() {
  local s=$1
  if ((s >= 60)); then printf '%d мин %d с' $((s / 60)) $((s % 60)); else printf '%d с' "$s"; fi
}

kc() { kubectl --context "$MK_PROFILE" "$@"; }
hm() { helm --kube-context "$MK_PROFILE" "$@"; }

# apply_stdin — kubectl apply из stdin (манифест не попадает в аргументы).
apply_stdin() { kc apply -f - >/dev/null; }
