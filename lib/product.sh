# shellcheck shell=bash
# Products of an install (FTR.INFRA.INST-0001 R11, R13): bin/nabu-deploy and bin/hammurapi-deploy with
# payloads built here from the configuration and the secrets of the cluster. The deploy contract (stdin
# JSON, codes, the last line of JSON) does not change, so the CI of a product runs the same scripts.

readonly STATE_PRODUCTS_CM=installer-products PRODUCT_INPUTS_SECRET=product-inputs
PRODUCT_BIN=${PRODUCT_BIN:-$ROOT/bin}
# installer/product-inputs as read once per run: JSON of .data, {} if absent, or nothing if the cluster
# does not answer (a stopped minikube).
PRODUCT_INPUTS=""
PRODUCT_INPUTS_READ=0
# Values the installer generates and keeps with the inputs: the secret of the client of Hammurapi in the
# Nabu of this install. Never taken from the environment, so a NABU_CLIENT_SECRET of an external Nabu
# cannot replace it.
declare -gA GENERATED_INPUTS=()
readonly GENERATED_KEYS=(NABU_BOOTSTRAP_CLIENT_SECRET)

nabu_ns() { echo "${NABU_NAMESPACE:-nabu}"; }
hammurapi_ns() { echo "${HAMMURAPI_NAMESPACE:-hammurapi}"; }

# product_list — the products of PRODUCTS, one per line.
product_list() { tr ', ' '\n\n' <<<"${PRODUCTS:-}" | sed '/^$/d'; }

has_product() { product_list | grep -qx "$1"; }

# hammurapi_git — where the repositories of Hammurapi live: github (the default) or gitlab.
hammurapi_git() { echo "${HAMMURAPI_GIT_PROVIDER:-github}"; }

nabu_external() { [[ ${NABU_MODE:-internal} == external ]]; }

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

# input_value <key> — the value given to this run. The private key of the GitHub App keeps its lines
# as \n, the form bin/hammurapi-deploy reads.
input_value() {
  if [[ $1 == HAMMURAPI_GITHUB_APP_PRIVATE_KEY ]]; then secret_value "$1" lines; else secret_value "$1"; fi
}

# product_secret <key> — the value given to this run, else the kept one.
product_secret() {
  local v
  v=$(input_value "$1")
  if [[ -n $v ]]; then printf '%s' "$v"; else stored_input "$1"; fi
}

# require_product_secret <what> <key> — while the cluster does not answer, a kept value cannot be seen:
# deploy_products checks again once the cluster runs.
require_product_secret() {
  [[ -n $(input_value "$2") ]] && return 0
  read_product_inputs
  [[ -z $PRODUCT_INPUTS || -n $(stored_input "$2") ]] && return 0
  CONFIG_MISSING+=("$1: neither $2 (environment variable) nor ${2}_FILE is set, and no earlier install kept it")
}

# validate_products — the products and their sign-in; missing values go to CONFIG_MISSING. Only install
# calls it: status serves the rollouts of every product and does not depend on the sign-in of a product.
validate_products() {
  local p
  while read -r p; do
    case $p in
      nabu | hammurapi) ;;
      *) die "$E_USAGE" "PRODUCTS: nabu, hammurapi or both, not '$p'" ;;
    esac
  done < <(product_list)
  case ${NABU_MODE:-internal} in
    internal | external) ;;
    *) die "$E_USAGE" "NABU_MODE must be internal or external, not '$NABU_MODE'" ;;
  esac
  if nabu_external && has_product nabu; then
    die "$E_USAGE" "NABU_MODE=external: Nabu is not installed here, so leave nabu out of PRODUCTS"
  fi
  # R11: Hammurapi does not work without Nabu.
  if has_product hammurapi && ! nabu_external && ! has_product nabu; then
    PRODUCTS="nabu,$PRODUCTS"
    export PRODUCTS
    log "PRODUCTS: Hammurapi needs Nabu, so Nabu is installed too"
  fi
  [[ -n $(product_list) ]] || return 0
  local what="PRODUCTS=$(product_list | paste -sd, -)" chart
  # Older charts have no ingress.tls: their Ingresses would answer HTTPS only, and the load balancer sends HTTP.
  if tls_external; then
    for chart in NABU_CHART_VERSION HAMMURAPI_CHART_VERSION; do
      [[ $(printf '%s\n%s\n' "$TLS_EXTERNAL_CHART_MIN" "${!chart}" | sort -V | head -1) == "$TLS_EXTERNAL_CHART_MIN" ]] ||
        die "$E_USAGE" "TLS_TERMINATION=external needs the charts of the products from $TLS_EXTERNAL_CHART_MIN: $chart is ${!chart}; set $chart=$TLS_EXTERNAL_CHART_MIN or newer in the config file"
    done
  fi
  [[ ${PUBLIC_ACCESS:-false} == true ]] ||
    CONFIG_MISSING+=("$what: set PUBLIC_ACCESS=true, as the products need HTTPS and OAuth callbacks")
  require_param "$what" AUTH_PROVIDER
  require_param "$what" BOOTSTRAP_ADMINS
  case ${AUTH_PROVIDER:-} in
    "") ;;
    github)
      # Hammurapi signs in with the client of its GitHub App, checked below.
      if has_product nabu; then
        require_param "$what" NABU_GITHUB_CLIENT_ID
        require_product_secret "$what" NABU_GITHUB_CLIENT_SECRET
      fi
      ;;
    oidc)
      require_param "$what" OIDC_ISSUER
      require_param "$what" OIDC_CLIENT_ID
      require_product_secret "$what" OIDC_CLIENT_SECRET
      ;;
    *) die "$E_USAGE" "AUTH_PROVIDER must be github or oidc, not '$AUTH_PROVIDER'" ;;
  esac
  has_product hammurapi || return 0
  require_param "$what" HAMMURAPI_SPEC_REPO
  case $(hammurapi_git) in
    github)
      require_param "$what" HAMMURAPI_GITHUB_APP_ID
      require_param "$what" HAMMURAPI_GITHUB_CLIENT_ID
      require_product_secret "$what" HAMMURAPI_GITHUB_APP_PRIVATE_KEY
      require_product_secret "$what" HAMMURAPI_GITHUB_CLIENT_SECRET
      if [[ -n ${HAMMURAPI_SPEC_REPO:-} && ! $HAMMURAPI_SPEC_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        die "$E_USAGE" "HAMMURAPI_SPEC_REPO: owner/name of a GitHub repository, not '$HAMMURAPI_SPEC_REPO'"
      fi
      ;;
    gitlab)
      # GitHub sign-in next to GitLab would need one more OAuth App of GitHub for Hammurapi.
      [[ ${AUTH_PROVIDER:-oidc} == oidc ]] ||
        die "$E_USAGE" "HAMMURAPI_GIT_PROVIDER=gitlab: people sign in with AUTH_PROVIDER=oidc, not '$AUTH_PROVIDER'"
      require_param "$what" HAMMURAPI_GITLAB_CLIENT_ID
      require_product_secret "$what" HAMMURAPI_GITLAB_CLIENT_SECRET
      require_product_secret "$what" HAMMURAPI_GITLAB_BOT_TOKEN
      if [[ -n ${HAMMURAPI_SPEC_REPO:-} && ! $HAMMURAPI_SPEC_REPO =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$ ]]; then
        die "$E_USAGE" "HAMMURAPI_SPEC_REPO: group/project of a GitLab project, not '$HAMMURAPI_SPEC_REPO'"
      fi
      if [[ -n ${HAMMURAPI_GITLAB_URL:-} && ! $HAMMURAPI_GITLAB_URL =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]]; then
        die "$E_USAGE" "HAMMURAPI_GITLAB_URL: the http(s):// address of GitLab, not '$HAMMURAPI_GITLAB_URL'"
      fi
      ;;
    *) die "$E_USAGE" "HAMMURAPI_GIT_PROVIDER must be github or gitlab, not '$HAMMURAPI_GIT_PROVIDER'" ;;
  esac
  if nabu_external; then
    require_param "NABU_MODE=external" NABU_URL
    require_param "NABU_MODE=external" NABU_CLIENT_ID
    require_product_secret "NABU_MODE=external" NABU_CLIENT_SECRET
    if [[ -n ${NABU_URL:-} && ! $NABU_URL =~ ^https:// ]]; then
      die "$E_USAGE" "NABU_URL: the https:// address of the API of Nabu, not '$NABU_URL'"
    fi
  fi
}

# products_preflight — before anything changes (R11): an external Nabu takes the client of Hammurapi, and an
# internal one is not of its own CI, as only a Nabu of the installer creates that client.
products_preflight() {
  has_product hammurapi || return 0
  step preflight
  if ! nabu_external; then
    if nabu_of_ci; then
      die "$E_USAGE" "Nabu here belongs to its own CI, so it cannot create the client of Hammurapi: register one in Nabu (Admin → Clients) and set NABU_MODE=external, NABU_URL, NABU_CLIENT_ID and NABU_CLIENT_SECRET"
    fi
    return 0
  fi
  # The secret reaches curl through stdin, not an argument.
  P_ID=$NABU_CLIENT_ID P_SECRET=$(product_secret NABU_CLIENT_SECRET) \
    jq -rn '"grant_type=client_credentials&client_id=\($ENV.P_ID | @uri)&client_secret=\($ENV.P_SECRET | @uri)"' |
    curl -fsS --max-time 15 -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @- \
      "${NABU_URL%/}/oauth/token" 2>/dev/null | jq -e '.access_token | length > 0' >/dev/null 2>&1 ||
    die "$E_EXTERNAL" "the external Nabu at $NABU_URL does not issue a token to the client $NABU_CLIENT_ID (POST /oauth/token): check NABU_URL, NABU_CLIENT_ID and NABU_CLIENT_SECRET; nothing was installed"
  ok "external Nabu: $NABU_URL, client $NABU_CLIENT_ID"
}

# nabu_of_ci — a release nabu-core exists, and the installer has no record of it.
nabu_of_ci() {
  hm status nabu-core -n "$(nabu_ns)" >/dev/null 2>&1 &&
    [[ -z $(recorded_products | jq -r '.["nabu-core"] // empty') ]]
}

# save_product_inputs — the given secrets are kept for later runs; kept ones without a new value stay.
save_product_inputs() {
  local key value args=() changed=0
  for key in "${PRODUCT_SECRET_KEYS[@]}" "${GENERATED_KEYS[@]}"; do
    if [[ " ${GENERATED_KEYS[*]} " == *" $key "* ]]; then value=${GENERATED_INPUTS[$key]:-}; else value=$(input_value "$key"); fi
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

# ensure_nabu_client — the secret of the client of Hammurapi in the Nabu of this install: generated once
# and kept with the inputs before Nabu creates the client from its hash (FTR.NAB.CMN-0001 R17a).
ensure_nabu_client() {
  has_product hammurapi && ! nabu_external || return 0
  [[ -z $(stored_input NABU_BOOTSTRAP_CLIENT_SECRET) ]] || return 0
  GENERATED_INPUTS[NABU_BOOTSTRAP_CLIENT_SECRET]="nabu_$(openssl rand -hex 32)"
}

# hammurapi_nabu_secret — the secret of the client of Hammurapi: given for an external Nabu, generated for
# the Nabu of this install.
hammurapi_nabu_secret() {
  if nabu_external; then
    product_secret NABU_CLIENT_SECRET
  elif [[ -n ${GENERATED_INPUTS[NABU_BOOTSTRAP_CLIENT_SECRET]:-} ]]; then
    printf '%s' "${GENERATED_INPUTS[NABU_BOOTSTRAP_CLIENT_SECRET]}"
  else
    stored_input NABU_BOOTSTRAP_CLIENT_SECRET
  fi
}

# kept_key <ns> <secret> <key> — a key an installed product already uses, or a new one: changing it would
# make stored data unreadable (codes 24 of bin/*-deploy).
kept_key() {
  local key
  key=$(secret_key "$1" "$2" "$3" 2>/dev/null || true)
  [[ -n $key ]] || key=$(openssl rand -hex 32)
  printf '%s' "$key"
}

# nabu_bootstrap_clients — BOOTSTRAP_CLIENTS of Nabu: the client of Hammurapi, if it is installed here.
nabu_bootstrap_clients() {
  has_product hammurapi || return 0
  local hash
  hash=$(hammurapi_nabu_secret | sha256sum | awk '{print $1}')
  jq -cn --arg h "$hash" --arg url "https://${HAMMURAPI_WEB_HOST:-hammurapi}.$PUBLIC_DOMAIN" \
    '[{name: "hammurapi", secretSha256: $h, url: $url, agents: []}]'
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
  P_SECRETS_KEY=$(kept_key "$(nabu_ns)" nabu-secrets SECRETS_KEY) P_GITHUB_SECRET=$github_secret P_OIDC_SECRET=$oidc_secret \
    P_LLM_KEY=$(product_secret BOOTSTRAP_LLM_API_KEY) P_CLIENTS=$(nabu_bootstrap_clients) \
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
       OIDC_CLIENT_SECRET: $ENV.P_OIDC_SECRET, BOOTSTRAP_LLM_API_KEY: $ENV.P_LLM_KEY,
       BOOTSTRAP_CLIENTS: $ENV.P_CLIENTS} | nonempty)}'
}

# hammurapi_payload <component> — the stdin of bin/hammurapi-deploy.
hammurapi_payload() {
  local repo=${HAMMURAPI_IMAGE_REPO:-ghcr.io/greenongrey}
  if [[ $1 == hammurapi-web ]]; then
    jq -cn --arg image "$repo/hammurapi-web" '{image: $image}'
    return
  fi
  local ns nabu_url nabu_id nabu_web="" oidc_secret=""
  ns=$(hammurapi_ns)
  if nabu_external; then
    nabu_url=${NABU_URL%/} nabu_id=$NABU_CLIENT_ID
  else
    nabu_url="https://${NABU_API_HOST:-nabu-api}.$PUBLIC_DOMAIN" nabu_id=hammurapi
    nabu_web="https://${NABU_WEB_HOST:-nabu}.$PUBLIC_DOMAIN"
  fi
  if [[ $AUTH_PROVIDER == oidc ]]; then oidc_secret=$(product_secret OIDC_CLIENT_SECRET); fi
  local git app_key="" client_secret="" bot_token=""
  git=$(hammurapi_git)
  if [[ $git == gitlab ]]; then
    client_secret=$(product_secret HAMMURAPI_GITLAB_CLIENT_SECRET)
    bot_token=$(product_secret HAMMURAPI_GITLAB_BOT_TOKEN)
  else
    app_key=$(product_secret HAMMURAPI_GITHUB_APP_PRIVATE_KEY)
    client_secret=$(product_secret HAMMURAPI_GITHUB_CLIENT_SECRET)
  fi
  P_APP_KEY=$app_key P_CLIENT_SECRET=$client_secret P_BOT_TOKEN=$bot_token \
    P_WEBHOOK=$(kept_key "$ns" hammurapi-secrets WEBHOOK_SECRET) P_TOKEN_KEY=$(kept_key "$ns" hammurapi-secrets TOKEN_ENCRYPTION_KEY) \
    P_OIDC_SECRET=$oidc_secret P_NABU_SECRET=$(hammurapi_nabu_secret) \
    jq -cn --arg image "$repo/hammurapi-core" --arg provider "$AUTH_PROVIDER" --arg repo_name "$HAMMURAPI_SPEC_REPO" \
    --arg git "$git" --arg app "${HAMMURAPI_GITHUB_APP_ID:-}" --arg client "${HAMMURAPI_GITHUB_CLIENT_ID:-}" \
    --arg gl_url "${HAMMURAPI_GITLAB_URL:-}" --arg gl_client "${HAMMURAPI_GITLAB_CLIENT_ID:-}" --arg admins "$BOOTSTRAP_ADMINS" \
    --arg org "${GITHUB_ALLOWED_ORG:-}" --arg issuer "${OIDC_ISSUER:-}" --arg oidc_id "${OIDC_CLIENT_ID:-}" \
    --arg oidc_name "${OIDC_PROVIDER_NAME:-}" --arg nabu_url "$nabu_url" --arg nabu_id "$nabu_id" --arg nabu_web "$nabu_web" \
    --arg spec_lang "${SPEC_LANGUAGE:-}" '
    def nonempty: with_entries(select(.value != null and .value != ""));
    {image: $image,
     config: ({GIT_PROVIDER: $git, GIT_REPO: $repo_name,
       BOOTSTRAP_ADMINS: $admins, AUTH_PROVIDER: $provider, NABU_URL: $nabu_url, NABU_CLIENT_ID: $nabu_id,
       NABU_WEB_URL: $nabu_web, SPEC_LANGUAGE: $spec_lang}
       + (if $git == "gitlab" then {GIT_BASE_URL: ($gl_url | rtrimstr("/")), GITLAB_CLIENT_ID: $gl_client}
          else {GITHUB_APP_ID: $app, GITHUB_CLIENT_ID: $client} end)
       + (if $provider == "github" then {GITHUB_ALLOWED_ORG: $org}
          else {OIDC_ISSUER: $issuer, OIDC_CLIENT_ID: $oidc_id, OIDC_PROVIDER_NAME: $oidc_name} end) | nonempty),
     secrets: ((if $git == "gitlab"
         then {GITLAB_CLIENT_SECRET: $ENV.P_CLIENT_SECRET, GITLAB_BOT_TOKEN: $ENV.P_BOT_TOKEN}
         else {GITHUB_APP_PRIVATE_KEY: $ENV.P_APP_KEY, GITHUB_CLIENT_SECRET: $ENV.P_CLIENT_SECRET} end)
       + {WEBHOOK_SECRET: $ENV.P_WEBHOOK, TOKEN_ENCRYPTION_KEY: $ENV.P_TOKEN_KEY, OIDC_CLIENT_SECRET: $ENV.P_OIDC_SECRET,
       NABU_CLIENT_SECRET: $ENV.P_NABU_SECRET} | nonempty)}'
}

# product_payload <component>
product_payload() {
  case $1 in
    nabu-*) nabu_payload "$1" ;;
    hammurapi-*) hammurapi_payload "$1" ;;
  esac
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
  product_payload "$component" |
    INSTALLER_CONFIG=$CONFIG_FILE bash "$PRODUCT_BIN/$script" "$component" "$tag" "$chart" >"$RUN_DIR/$component.log" 2>&1 || rc=$?
  if ((rc != 0)); then
    RESULT_FAILED+=("$component")
    result=$(tail -n 1 "$RUN_DIR/$component.log" | jq -r '.error // empty' 2>/dev/null || true)
    die "$rc" "$component was not rolled out: ${result:-see the log} ($RUN_DIR/$component.log)"
  fi
  record_product "$component" "$tag"
  RESULT_UPDATED+=("$component")
}

# restart_nabu_api <BOOTSTRAP_CLIENTS before the rollout> — api reads BOOTSTRAP_CLIENTS at its start, and a
# rollout at the same tag does not restart it when only the secret changed.
restart_nabu_api() {
  [[ " ${RESULT_UPDATED[*]} " == *" nabu-core "* ]] || return 0
  local after
  after=$(secret_key "$(nabu_ns)" nabu-secrets BOOTSTRAP_CLIENTS 2>/dev/null || true)
  [[ $after != "$1" ]] || return 0
  log "the service clients of Nabu changed: restarting its api"
  kc -n "$(nabu_ns)" rollout restart deployment/api >/dev/null &&
    kc -n "$(nabu_ns)" rollout status deployment/api --timeout="$HELM_TIMEOUT" >/dev/null ||
    die "$E_DEPLOY" "the api of Nabu did not restart with the client of Hammurapi"
}

# deploy_pair <script> <ns> <product> <core tag> <web tag> <chart> — web follows its core: a core of the
# CI of its product keeps its web too.
deploy_pair() {
  if deploy_component "$1" "$2" "$3-core" "$4" "$6"; then
    deploy_component "$1" "$2" "$3-web" "$5" "$6" || true
  else
    RESULT_SKIPPED+=("$3-web")
  fi
}

deploy_products() {
  [[ -n $(product_list) ]] || return 0
  step products
  # The cluster runs now, so kept secrets that a stopped minikube hid are checked again.
  PRODUCT_INPUTS_READ=0
  CONFIG_MISSING=()
  validate_products
  die_if_missing
  ensure_nabu_client
  save_product_inputs
  if has_product nabu; then
    local clients_before
    clients_before=$(secret_key "$(nabu_ns)" nabu-secrets BOOTSTRAP_CLIENTS 2>/dev/null || true)
    deploy_pair nabu-deploy "$(nabu_ns)" nabu "$NABU_CORE_VERSION" "$NABU_WEB_VERSION" "$NABU_CHART_VERSION"
    restart_nabu_api "$clients_before"
  fi
  if has_product hammurapi; then
    # A stopped minikube hid the release from products_preflight.
    if ! nabu_external && [[ " ${RESULT_SKIPPED[*]} " == *" nabu-core "* ]]; then
      die "$E_USAGE" "Nabu here belongs to its own CI, so it cannot create the client of Hammurapi: set NABU_MODE=external with a client registered in it"
    fi
    deploy_pair hammurapi-deploy "$(hammurapi_ns)" hammurapi "$HAMMURAPI_CORE_VERSION" "$HAMMURAPI_WEB_VERSION" "$HAMMURAPI_CHART_VERSION"
  fi
  ok "products: $(product_list | paste -sd, -)"
}

# deploy_products_of <component> — one component at its version (update <service>).
deploy_products_of() {
  local component=$1 script ns chart before="" var=${SERVICE_VERSION_VAR[$1]}
  PRODUCT_INPUTS_READ=0
  CONFIG_MISSING=()
  validate_products
  die_if_missing
  ensure_nabu_client
  save_product_inputs
  case $component in
    nabu-*) script=nabu-deploy ns=$(nabu_ns) chart=$NABU_CHART_VERSION ;;
    hammurapi-*) script=hammurapi-deploy ns=$(hammurapi_ns) chart=$HAMMURAPI_CHART_VERSION ;;
  esac
  [[ $component == nabu-core ]] && before=$(secret_key "$ns" nabu-secrets BOOTSTRAP_CLIENTS 2>/dev/null || true)
  deploy_component "$script" "$ns" "$component" "${!var}" "$chart" ||
    die "$E_USAGE" "$component belongs to the CI of its product: update it there"
  if [[ $component == nabu-core ]]; then restart_nabu_api "$before"; fi
}

# products_summary — addresses of the products, and what is still to be done by hand.
products_summary() {
  if has_product nabu; then
    printf '\nNabu          https://%s.%s   API https://%s.%s\n' "${NABU_WEB_HOST:-nabu}" "$PUBLIC_DOMAIN" "${NABU_API_HOST:-nabu-api}" "$PUBLIC_DOMAIN"
    if [[ -z $(product_secret BOOTSTRAP_LLM_API_KEY) ]]; then
      printf '              no model key yet (BOOTSTRAP_LLM_API_KEY): add a model connection in the admin area of Nabu\n'
    fi
  fi
  if has_product hammurapi; then
    printf '\nHammurapi     https://%s.%s   API https://%s.%s\n' "${HAMMURAPI_WEB_HOST:-hammurapi}" "$PUBLIC_DOMAIN" "${HAMMURAPI_API_HOST:-hammurapi-api}" "$PUBLIC_DOMAIN"
    if ! nabu_external; then
      printf '              allow the service agents of Hammurapi to its client in Nabu (Admin → Clients)\n'
    fi
    printf '              webhook of the repositories: https://%s.%s/hooks/v1/git (application/json), events pushes, pull requests,\n              reviews, review comments and issue comments;\n' "${HAMMURAPI_API_HOST:-hammurapi-api}" "$PUBLIC_DOMAIN"
    printf '              its secret is the key WEBHOOK_SECRET of the secret %s/hammurapi-secrets\n' "$(hammurapi_ns)"
  fi
}
