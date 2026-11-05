# shellcheck shell=bash
# Products of an install (FTR.INFRA.INST-0001 R11, R13): bin/nabu-deploy with a payload built here from
# the configuration and the secrets of the cluster. The deploy contract (stdin JSON, codes, the last line
# of JSON) does not change, so the CI of a product runs the same script.

readonly STATE_PRODUCTS_CM=installer-products PRODUCT_INPUTS_SECRET=product-inputs
PRODUCT_BIN=${PRODUCT_BIN:-$ROOT/bin}
# installer/product-inputs as read once per run: JSON of .data, {} if absent, or nothing if the cluster
# does not answer (a stopped minikube).
PRODUCT_INPUTS=""
PRODUCT_INPUTS_READ=0

nabu_ns() { echo "${NABU_NAMESPACE:-nabu}"; }

# product_list — the products of PRODUCTS, one per line.
product_list() { tr ', ' '\n\n' <<<"${PRODUCTS:-}" | sed '/^$/d'; }

has_product() { product_list | grep -qx "$1"; }

read_product_inputs() {
  ((PRODUCT_INPUTS_READ)) && return 0
  PRODUCT_INPUTS_READ=1
  local out
  if out=$(kc -n "$NS_STATE" get secret "$PRODUCT_INPUTS_SECRET" --ignore-not-found -o json 2>/dev/null); then
    PRODUCT_INPUTS=$(if [[ -n $out ]]; then jq -c '.data // {}' <<<"$out"; else echo '{}'; fi)
  else
    PRODUCT_INPUTS=""
  fi
}

# stored_input <key> — the value kept by an earlier install, or nothing.
stored_input() {
  read_product_inputs
  [[ -n $PRODUCT_INPUTS ]] || return 0
  jq -r --arg k "$1" '.[$k] // empty | @base64d' <<<"$PRODUCT_INPUTS"
}

# product_secret <key> — the value given to this run, else the kept one.
product_secret() {
  local v
  v=$(secret_value "$1")
  if [[ -n $v ]]; then printf '%s' "$v"; else stored_input "$1"; fi
}

# require_product_secret <what> <key> — while the cluster does not answer, a kept value cannot be seen:
# deploy_products checks again once the cluster runs.
require_product_secret() {
  [[ -n $(secret_value "$2") ]] && return 0
  read_product_inputs
  [[ -z $PRODUCT_INPUTS || -n $(stored_input "$2") ]] && return 0
  CONFIG_MISSING+=("$1: neither $2 (environment variable) nor ${2}_FILE is set, and no earlier install kept it")
}

# validate_products — the products and their sign-in; missing values go to CONFIG_MISSING. Only install
# calls it: status serves the rollouts of every product and does not depend on the sign-in of Nabu.
validate_products() {
  local p
  while read -r p; do
    case $p in
      nabu) ;;
      hammurapi) die "$E_USAGE" "PRODUCTS: Hammurapi comes with a later release of the installer; use nabu or leave it empty" ;;
      *) die "$E_USAGE" "PRODUCTS: nabu or nothing, not '$p'" ;;
    esac
  done < <(product_list)
  has_product nabu || return 0
  local what="PRODUCTS=nabu"
  [[ ${PUBLIC_ACCESS:-false} == true ]] ||
    CONFIG_MISSING+=("$what: set PUBLIC_ACCESS=true, as the products need HTTPS and OAuth callbacks")
  require_param "$what" AUTH_PROVIDER
  require_param "$what" BOOTSTRAP_ADMINS
  case ${AUTH_PROVIDER:-} in
    "") ;;
    github)
      require_param "$what" NABU_GITHUB_CLIENT_ID
      require_product_secret "$what" NABU_GITHUB_CLIENT_SECRET
      ;;
    oidc)
      require_param "$what" OIDC_ISSUER
      require_param "$what" OIDC_CLIENT_ID
      require_product_secret "$what" OIDC_CLIENT_SECRET
      ;;
    *) die "$E_USAGE" "AUTH_PROVIDER must be github or oidc, not '$AUTH_PROVIDER'" ;;
  esac
}

# save_product_inputs — the given secrets are kept for later runs; kept ones without a new value stay.
save_product_inputs() {
  local key value args=() changed=0
  for key in "${PRODUCT_SECRET_KEYS[@]}"; do
    value=$(secret_value "$key")
    if [[ -n $value ]]; then
      [[ $value == "$(stored_input "$key")" ]] || changed=1
    else
      value=$(stored_input "$key")
    fi
    [[ -n $value ]] && args+=("$key" "$value")
  done
  ((changed)) || return 0
  put_secret "$NS_STATE" "$PRODUCT_INPUTS_SECRET" Opaque "${args[@]}" ||
    die "$E_DEPLOY" "failed to write $NS_STATE/$PRODUCT_INPUTS_SECRET"
  PRODUCT_INPUTS_READ=0
}

# nabu_secrets_key — SECRETS_KEY of an installed Nabu, or a new one: it encrypts stored secrets, so a
# rollout never changes it (bin/nabu-deploy stops with code 24 otherwise).
nabu_secrets_key() {
  local key
  key=$(secret_key "$(nabu_ns)" nabu-secrets SECRETS_KEY 2>/dev/null || true)
  [[ -n $key ]] || key=$(openssl rand -hex 32)
  printf '%s' "$key"
}

# nabu_payload <component> — the stdin of bin/nabu-deploy. Secrets reach jq through the environment.
nabu_payload() {
  local repo=${NABU_IMAGE_REPO:-ghcr.io/greenongrey}
  if [[ $1 == nabu-web ]]; then
    jq -cn --arg image "$repo/nabu-web" '{image: $image}'
    return
  fi
  local github_secret="" oidc_secret=""
  if [[ $AUTH_PROVIDER == github ]]; then github_secret=$(product_secret NABU_GITHUB_CLIENT_SECRET); fi
  if [[ $AUTH_PROVIDER == oidc ]]; then oidc_secret=$(product_secret OIDC_CLIENT_SECRET); fi
  P_SECRETS_KEY=$(nabu_secrets_key) P_GITHUB_SECRET=$github_secret P_OIDC_SECRET=$oidc_secret \
    P_LLM_KEY=$(product_secret BOOTSTRAP_LLM_API_KEY) \
    jq -cn --arg image "$repo/nabu-core" --arg provider "$AUTH_PROVIDER" \
    --arg github_id "${NABU_GITHUB_CLIENT_ID:-}" --arg org "${GITHUB_ALLOWED_ORG:-}" \
    --arg issuer "${OIDC_ISSUER:-}" --arg oidc_id "${OIDC_CLIENT_ID:-}" --arg oidc_name "${OIDC_PROVIDER_NAME:-}" \
    --arg admins "$BOOTSTRAP_ADMINS" --arg lang "${DEFAULT_LANGUAGE:-en}" --arg tz "${DEFAULT_TIMEZONE:-UTC}" \
    --arg pi "$NABU_PI_VERSION" '
    def nonempty: with_entries(select(.value != null and .value != ""));
    {image: $image,
     config: ({AUTH_PROVIDER: $provider, BOOTSTRAP_ADMINS: $admins, DEFAULT_LANGUAGE: $lang, DEFAULT_TIMEZONE: $tz,
       PI_VERSION: $pi}
       + (if $provider == "github" then {GITHUB_CLIENT_ID: $github_id, GITHUB_ALLOWED_ORG: $org}
          else {OIDC_ISSUER: $issuer, OIDC_CLIENT_ID: $oidc_id, OIDC_PROVIDER_NAME: $oidc_name} end) | nonempty),
     secrets: ({SECRETS_KEY: $ENV.P_SECRETS_KEY, GITHUB_CLIENT_SECRET: $ENV.P_GITHUB_SECRET,
       OIDC_CLIENT_SECRET: $ENV.P_OIDC_SECRET, BOOTSTRAP_LLM_API_KEY: $ENV.P_LLM_KEY} | nonempty)}'
}

# recorded_products — {component: tag} of the components the installer owns.
recorded_products() {
  local data
  data=$(state_data "$STATE_PRODUCTS_CM")
  [[ -n $data ]] || data='{}'
  echo "$data"
}

record_product() {
  state_configmap "$STATE_PRODUCTS_CM" "$(recorded_products | jq -c --arg c "$1" --arg t "$2" '. + {($c): $t}')"
}

# deploy_component <script> <ns> <component> <tag> <chart version> — returns 1 if the component
# belongs to the CI of its product and stays as it is.
deploy_component() {
  local script=$1 ns=$2 component=$3 tag=$4 chart=$5 rc=0 result
  if [[ -z $(recorded_products | jq -r --arg c "$component" '.[$c] // empty') ]]; then
    if hm status "$component" -n "$ns" >/dev/null 2>&1; then
      warn "$component was rolled out by its own CI, not by the installer: left alone"
      RESULT_SKIPPED+=("$component")
      return 1
    fi
    # Recorded before the first rollout: a failed one is the installer's to retry.
    record_product "$component" "$tag"
  fi
  log "$component $tag (chart $chart)"
  nabu_payload "$component" |
    INSTALLER_CONFIG=$CONFIG_FILE bash "$PRODUCT_BIN/$script" "$component" "$tag" "$chart" >"$RUN_DIR/$component.log" 2>&1 || rc=$?
  if ((rc != 0)); then
    RESULT_FAILED+=("$component")
    result=$(tail -n 1 "$RUN_DIR/$component.log" | jq -r '.error // empty' 2>/dev/null || true)
    die "$rc" "$component was not rolled out: ${result:-see the log} ($RUN_DIR/$component.log)"
  fi
  record_product "$component" "$tag"
  RESULT_UPDATED+=("$component")
}

deploy_products() {
  [[ -n $(product_list) ]] || return 0
  step products
  # The cluster runs now, so kept secrets that a stopped minikube hid are checked again.
  PRODUCT_INPUTS_READ=0
  CONFIG_MISSING=()
  validate_products
  die_if_missing
  save_product_inputs
  if has_product nabu; then
    # Web follows its core: a core of the CI of Nabu keeps its web too.
    if deploy_component nabu-deploy "$(nabu_ns)" nabu-core "$NABU_CORE_VERSION" "$NABU_CHART_VERSION"; then
      deploy_component nabu-deploy "$(nabu_ns)" nabu-web "$NABU_WEB_VERSION" "$NABU_CHART_VERSION" || true
    else
      RESULT_SKIPPED+=(nabu-web)
    fi
  fi
  ok "products: $(product_list | paste -sd, -)"
}

# products_summary — addresses of the products, and what is still to be done by hand.
products_summary() {
  has_product nabu || return 0
  printf '\nNabu          https://%s.%s   API https://%s.%s\n' "${NABU_WEB_HOST:-nabu}" "$PUBLIC_DOMAIN" "${NABU_API_HOST:-nabu-api}" "$PUBLIC_DOMAIN"
  if [[ -z $(product_secret BOOTSTRAP_LLM_API_KEY) ]]; then
    printf '              no model key yet (BOOTSTRAP_LLM_API_KEY): add a model connection in the admin area of Nabu\n'
  fi
}
