# shellcheck shell=bash
# Shared functions: logging, exit codes, retries, configuration.

# Exit codes (technical specification, §1).
readonly E_OK=0 E_UNKNOWN=1 E_USAGE=2 E_HOST=10 E_PREREQ=11 E_CLUSTER=12 E_DEPLOY=13 \
  E_EXTERNAL=14 E_CHECKS=15 E_CANCELLED=16 E_LOCKED=17 E_PREFLIGHT=18

STEP=${STEP:-main}
VERBOSE=${VERBOSE:-0}
COLOR=${COLOR:-auto}
RUN_DIR=${RUN_DIR:-}

# Keys whose values must not be written directly into local.env (tech, §2).
# Secrets of the products given by the user (lib/product.sh keeps them in installer/product-inputs).
readonly PRODUCT_SECRET_KEYS=(NABU_GITHUB_CLIENT_SECRET OIDC_CLIENT_SECRET BOOTSTRAP_LLM_API_KEY
  HAMMURAPI_GITHUB_APP_PRIVATE_KEY HAMMURAPI_GITHUB_CLIENT_SECRET NABU_CLIENT_SECRET)
readonly SECRET_KEYS=(POSTGRES_PASSWORD KAFKA_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY GRAFANA_GITHUB_CLIENT_SECRET
  "${PRODUCT_SECRET_KEYS[@]}")

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

# log <message> — a log line: time [step] message.
log() { printf '%s %s[%s]%s %s\n' "$(now_utc)" "$C_DIM" "$STEP" "$C_RESET" "$*" >&2; }
ok() { printf '%s %s[%s]%s %s✓%s %s\n' "$(now_utc)" "$C_DIM" "$STEP" "$C_RESET" "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s %s[%s]%s %s!%s %s\n' "$(now_utc)" "$C_DIM" "$STEP" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
debug() { [[ $VERBOSE == 1 ]] && log "$*"; return 0; }

# die <code> <message>
die() {
  local code=$1
  shift
  printf '%s %s[%s]%s %s✗ %s%s\n' "$(now_utc)" "$C_DIM" "$STEP" "$C_RESET" "$C_RED" "$*" "$C_RESET" >&2
  exit "$code"
}

step() { STEP=$1; }

# run_cmd <command…> — runs the command; prints it with --verbose.
run_cmd() {
  debug "\$ $*"
  "$@"
}

# retry <attempts> <delay> <command…> — retries network operations.
retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    if ((n >= attempts)); then
      return 1
    fi
    warn "retry $n/$attempts in ${delay}s: $1"
    sleep "$delay"
    n=$((n + 1))
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

# as_root <command…> — through sudo unless already root.
as_root() {
  if [[ $(id -u) == 0 ]]; then "$@"; else sudo "$@"; fi
}

# env_keys <file> — names of KEY=… keys in an env file.
env_keys() {
  sed -nE 's/^[[:space:]]*([A-Z_][A-Z0-9_]*)=.*/\1/p' "$1"
}

# nabu_bucket — the bucket of Nabu; NABU_S3_BUCKET is its old name.
nabu_bucket() { echo "${NABU_S3_BUCKET:-$S3_BUCKET_NABU}"; }

# installer_config — the config file of bin/*-deploy; HAMMURAPI_INFRA_CONFIG is its old name.
# Without either, the system file of the installer, then the file of the production machine.
installer_config() {
  local system=${SYSTEM_CONFIG:-/etc/greenongrey/installer.env}
  if [[ -n ${INSTALLER_CONFIG:-${HAMMURAPI_INFRA_CONFIG:-}} ]]; then
    echo "${INSTALLER_CONFIG:-$HAMMURAPI_INFRA_CONFIG}"
  elif [[ -f $system ]]; then
    echo "$system"
  else
    echo /opt/installer/local.env
  fi
}

# load_config — defaults.env → local.env → environment (flags apply earlier,
# by exporting variables at the entry point).
load_config() {
  local root=$1 local_file=$2 key
  local -A from_env=()
  # Keys set by this run through the file or the environment (restore_config leaves them alone).
  declare -gA CONFIG_EXPLICIT=()
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
        die "$E_USAGE" "$key is written directly in $local_file; use ${key}_FILE or an environment variable"
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
    CONFIG_EXPLICIT[$key]=1
  done
  if [[ -f $local_file ]]; then
    while read -r key; do CONFIG_EXPLICIT[$key]=1; done < <(env_keys "$local_file")
  fi
  # MCP server options are the MCP_*=true|false keys of config files: the environment may hold
  # foreign MCP_* variables, and config files hold parameters with other values.
  MCP_OPTIONS=()
  for f in "${files[@]}"; do
    while read -r key; do
      MCP_OPTIONS+=("$key")
    done < <(sed -n 's/^\(MCP_[A-Z0-9_]*\)=\(true\|false\)$/\1/p' "$f")
  done
}

# secret_value <key> [lines] — the value from the environment variable or the file <key>_FILE. With
# lines, the lines of a multi-line value (a PEM key) are joined by a literal \n; without, line ends go.
secret_value() {
  local key=$1 file_key="${1}_FILE"
  if [[ -n ${!key:-} ]]; then
    [[ ${2:-} == lines ]] || {
      printf '%s' "${!key}"
      return 0
    }
    printf '%s' "${!key}" | join_lines
  elif [[ -n ${!file_key:-} ]]; then
    [[ -r ${!file_key} ]] || die "$E_USAGE" "$file_key: cannot read file ${!file_key}"
    if [[ ${2:-} == lines ]]; then join_lines <"${!file_key}"; else tr -d '\r\n' <"${!file_key}"; fi
  fi
}

# join_lines — lines joined by a literal \n, carriage returns dropped.
join_lines() { awk 'NR > 1 { printf "\\n" } { sub(/\r$/, ""); printf "%s", $0 }'; }

# require_param, require_secret: a missing value is recorded in CONFIG_MISSING, and validate_config
# names them all at once (FTR.INFRA.INST-0001 R6), so a CI run does not fix them one by one.
CONFIG_MISSING=()

require_param() {
  local mode_name=$1 key=$2
  [[ $mode_name == *=* ]] || mode_name+="=external"
  if [[ -z ${!key:-} ]]; then
    CONFIG_MISSING+=("$mode_name: parameter $key is not set")
  fi
}

require_secret() {
  local mode_name=$1 key=$2
  [[ $mode_name == *=* ]] || mode_name+="=external"
  if [[ -z $(secret_value "$key") ]]; then
    CONFIG_MISSING+=("$mode_name: neither $key (environment variable) nor ${key}_FILE is set")
  fi
}

# die_if_missing — code 2 with every missing parameter, one per line.
die_if_missing() {
  ((${#CONFIG_MISSING[@]} == 0)) && return 0
  local list
  list=$(printf '  %s\n' "${CONFIG_MISSING[@]}")
  die "$E_USAGE" "missing parameters:"$'\n'"$list"
}

target_external() { [[ ${INSTALL_TARGET:-minikube} == external ]]; }

ingress_external() { [[ ${INGRESS_MODE:-internal} == external ]]; }

# ingress_from_status <status JSON> — the ingress recorded by `up`: a rollout follows the stand, whatever
# its own config says.
ingress_from_status() {
  INGRESS_MODE=$(jq -r '.public.ingressMode // "internal"' <<<"$1")
  INGRESS_CLASS=$(jq -r '.public.ingressClass // "traefik"' <<<"$1")
  ACME_ISSUER=$(jq -r '.public.issuer // "letsencrypt"' <<<"$1")
}

# resource_ready <kubectl get arguments…> — True when the condition Ready of the object holds.
resource_ready() {
  kc get "$@" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
}

# wait_certificate <ns> <name> — waits until Ready. cert-manager creates the certificate of an Ingress
# some time after the Ingress, and kubectl wait stops at once on a missing object.
wait_certificate() {
  local deadline=$((SECONDS + ${CERT_TIMEOUT:-300}))
  until [[ $(resource_ready -n "$1" certificate "$2") == True ]]; do
    ((SECONDS < deadline)) || return 1
    sleep 5
  done
}

# wait_product_certificate <ns> <component> — external ingress: the certificate of a product's Ingress.
# A warning only: a pending certificate is not a failed release, and DNS may still be on its way.
wait_product_certificate() {
  ingress_external || return 0
  local secret=web-tls
  [[ $2 == *-core ]] && secret=api-tls
  wait_certificate "$1" "$secret" ||
    warn "certificate $1/$secret is not ready: check DNS of the host and the issuer $ACME_ISSUER, and that the chart has ingress.clusterIssuer"
}

# ingress_helm_args — chart values of a product's Ingress, one per line.
ingress_helm_args() {
  printf '%s\n' --set-string "ingress.className=${INGRESS_CLASS:-traefik}"
  if ingress_external; then printf '%s\n' --set-string "ingress.clusterIssuer=$ACME_ISSUER"; fi
}

observability_enabled() { [[ ${OBSERVABILITY:-true} == true ]]; }

# stand_namespaces — the namespaces with the stand's own pods.
stand_namespaces() {
  echo "$NS_STORAGES"
  if observability_enabled; then echo "$NS_OBSERVABILITY"; fi
}

# validate_names — these names go into paths of files written and deleted as root.
validate_names() {
  local key
  for key in UNIT_PREFIX CERT_NAME; do
    [[ ${!key} =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
      die "$E_USAGE" "$key must hold lowercase letters, digits and hyphens, not '${!key}'"
  done
}

# validate_target — the target and, for an existing cluster, its context: never the default one.
validate_target() {
  case ${INSTALL_TARGET:-minikube} in
    minikube) ;;
    external)
      [[ -n ${CONFIG_EXPLICIT[KUBE_CONTEXT]+x} && -n ${KUBE_CONTEXT:-} ]] ||
        CONFIG_MISSING+=("INSTALL_TARGET=external: set KUBE_CONTEXT to a context of kubeconfig")
      ;;
    *) die "$E_USAGE" "INSTALL_TARGET must be minikube or external" ;;
  esac
}

# validate_config [products] — modes and required parameters of external storages; with products
# (install) also the products and their sign-in.
validate_config() {
  local m
  CONFIG_MISSING=()
  case ${STAND_AUTOSTART:-true} in
    true | false) ;;
    *) die "$E_USAGE" "STAND_AUTOSTART must be true or false" ;;
  esac
  validate_target
  case ${OBSERVABILITY:-true} in
    true | false) ;;
    *) die "$E_USAGE" "OBSERVABILITY must be true or false" ;;
  esac
  if ! [[ ${IMAGE_GC_HIGH:-85} =~ ^[0-9]+$ && ${IMAGE_GC_LOW:-80} =~ ^[0-9]+$ ]] ||
    ((${IMAGE_GC_LOW:-80} >= ${IMAGE_GC_HIGH:-85} || ${IMAGE_GC_HIGH:-85} > 100)); then
    die "$E_USAGE" "IMAGE_GC_LOW and IMAGE_GC_HIGH are percentages, IMAGE_GC_LOW < IMAGE_GC_HIGH ≤ 100"
  fi
  validate_names
  [[ ${IMAGE_GC_MAX_AGE:-336h} =~ ^[0-9]+[hms]$ ]] ||
    die "$E_USAGE" "IMAGE_GC_MAX_AGE must be a duration like 336h, not '$IMAGE_GC_MAX_AGE'"
  for m in POSTGRES_MODE KAFKA_MODE S3_MODE; do
    case ${!m} in
      internal | external) ;;
      *) die "$E_USAGE" "$m must be internal or external, not '${!m}'" ;;
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
    case ${KAFKA_SECURITY_PROTOCOL:-} in
      PLAINTEXT | "") ;;
      SASL_SSL)
        require_param KAFKA_MODE KAFKA_SASL_MECHANISM
        case ${KAFKA_SASL_MECHANISM:-} in
          PLAIN | SCRAM-SHA-512 | OAUTHBEARER | "") ;;
          *) die "$E_USAGE" "KAFKA_SASL_MECHANISM must be PLAIN, SCRAM-SHA-512 or OAUTHBEARER" ;;
        esac
        require_param KAFKA_MODE KAFKA_USERNAME
        require_secret KAFKA_MODE KAFKA_PASSWORD
        ;;
      *) die "$E_USAGE" "KAFKA_SECURITY_PROTOCOL must be PLAINTEXT or SASL_SSL" ;;
    esac
  fi
  if [[ $S3_MODE == external ]]; then
    for k in S3_ENDPOINT S3_REGION S3_BUCKET S3_PATH_STYLE; do
      require_param S3_MODE "$k"
    done
    require_secret S3_MODE S3_ACCESS_KEY
    require_secret S3_MODE S3_SECRET_KEY
  fi
  [[ $MK_MEMORY =~ ^[0-9]+[gGmM]$ ]] || die "$E_USAGE" "MK_MEMORY: expected a number with g or m, such as 12g"
  validate_public_config
  validate_mcp_config
  # FTR.NAB.CHAT-0001 R19: speech recognition of Nabu
  case ${NABU_WHISPER:-false} in
    true | false) ;;
    *) die "$E_USAGE" "NABU_WHISPER must be true or false, not '$NABU_WHISPER'" ;;
  esac
  [[ ${NABU_WHISPER_MODEL:-small} =~ ^(tiny|base|small|medium|large-v3|large-v3-turbo|turbo)$ ]] ||
    die "$E_USAGE" "NABU_WHISPER_MODEL must be tiny, base, small, medium, large-v3 or large-v3-turbo"
  if [[ ${1:-} == products ]]; then validate_products; fi
  die_if_missing
}

validate_ingress_internal() {
  [[ ${INGRESS_CLASS:-traefik} == traefik ]] ||
    die "$E_USAGE" "INGRESS_MODE=internal installs Traefik, so INGRESS_CLASS must be traefik or INGRESS_MODE external"
  require_param PUBLIC_ACCESS=true ACME_EMAIL
  [[ -z ${ACME_EMAIL:-} || $ACME_EMAIL == *@*.* ]] || die "$E_USAGE" "ACME_EMAIL: an email address is required"
  case ${ACME_ISSUER:-letsencrypt} in
    letsencrypt | letsencrypt-staging) ;;
    *) die "$E_USAGE" "ACME_ISSUER must be letsencrypt or letsencrypt-staging" ;;
  esac
}

# validate_ingress_external — the defaults name what the stand installs, so they do not count here.
validate_ingress_external() {
  local key
  for key in INGRESS_CLASS ACME_ISSUER; do
    if [[ -z ${CONFIG_EXPLICIT[$key]+x} || -z ${!key} ]]; then
      CONFIG_MISSING+=("INGRESS_MODE=external: set $key to the name of an existing object of the cluster")
    elif ! [[ ${!key} =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
      die "$E_USAGE" "INGRESS_MODE=external: $key must be the name of an object of the cluster, not '${!key}'"
    fi
  done
  require_param INGRESS_MODE=external PUBLIC_BASE_DOMAIN
}

# validate_public_config — public access parameters (FTR.HMR.INFRA-0002, R21).
validate_public_config() {
  case ${PUBLIC_ACCESS:-false} in
    true) ;;
    false) return 0 ;;
    *) die "$E_USAGE" "PUBLIC_ACCESS must be true or false" ;;
  esac
  if target_external; then require_param INSTALL_TARGET=external PUBLIC_BASE_DOMAIN; fi
  case ${INGRESS_MODE:-internal} in
    internal) validate_ingress_internal ;;
    external) validate_ingress_external ;;
    *) die "$E_USAGE" "INGRESS_MODE must be internal or external" ;;
  esac
  if [[ -n ${PUBLIC_BASE_DOMAIN:-} && ! $PUBLIC_BASE_DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    die "$E_USAGE" "PUBLIC_BASE_DOMAIN: invalid name '$PUBLIC_BASE_DOMAIN'"
  fi
  if [[ -n ${PUBLIC_IP:-} && ! $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "$E_USAGE" "PUBLIC_IP: an IPv4 address is required"
  fi
  if [[ -n ${GRAFANA_GITHUB_CLIENT_ID:-} ]] && observability_enabled; then
    require_secret PUBLIC_ACCESS=true GRAFANA_GITHUB_CLIENT_SECRET
    require_param PUBLIC_ACCESS=true GRAFANA_GITHUB_ORG
  fi
}

# mem_mib <12g|12288m> — minikube memory in MiB.
mem_mib() {
  local v=${1,,}
  case $v in
    *g) echo $((${v%g} * 1024)) ;;
    *m) echo "${v%m}" ;;
    *) echo "$v" ;;
  esac
}

# to_bytes <Kubernetes quantity> — 512Mi, 1Gi, 1536Mi, 1G, 100k, 1024.
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

# human_duration <seconds> — 14m 32s.
human_duration() {
  local s=$1
  if ((s >= 60)); then printf '%dm %ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

# kube_context — the kubeconfig context: KUBE_CONTEXT or the context of the minikube profile.
kube_context() { echo "${KUBE_CONTEXT:-$MK_PROFILE}"; }
kc() { kubectl --context "$(kube_context)" "$@"; }
hm() { helm --kube-context "$(kube_context)" "$@"; }

# apply_stdin — kubectl apply from stdin (the manifest stays out of the arguments).
apply_stdin() { kc apply -f - >/dev/null; }
