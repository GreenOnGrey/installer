# shellcheck shell=bash
# The wizard (FTR.INFRA.INST-0001 R3, R4, tech §4): questions on plain read, so it runs on a clean machine.
# It only collects the configuration: the file is written, and the same `install --config` as in CI runs,
# with the typed secrets in its environment. Values come from the file and the cluster, then the defaults.

# Keys the wizard answered, in the order of the questions; they replace their lines in the file.
WIZARD_KEYS=()
# Secrets typed in: kept in memory, never in the file; install gets them through the environment.
declare -gA WIZARD_SECRETS=()
# The machine has kubectl and jq: values kept in the cluster can be read.
WIZARD_CLUSTER=0
WIZARD_INSTALLER=${WIZARD_INSTALLER:-}
readonly WIZARD_HEADER="# Written by the wizard of ./installer; secrets are kept in the cluster, not here."
readonly SSLIP_WARNING="Without a domain the stand uses <IP>.sslip.io. Let's Encrypt limits certificates per registered domain, and all of sslip.io shares one limit: issuance may fail for days."

# wizard_running — install runs from the wizard in a terminal, so it may ask (R18).
wizard_running() { [[ ${INSTALLER_WIZARD:-0} == 1 ]] && interactive; }

# Colors of the wizard in a terminal: what the installer says, the headings of the steps, what to do outside
# (in GitHub, GitLab, the identity provider), a refused answer, and what the user types. Empty without colors.
W_SAY="" W_HEAD="" W_TODO="" W_WARN="" W_IN="" W_OFF=""

# wizard_colors — on when the colors of the run are on and the wizard talks to a terminal.
wizard_colors() {
  [[ $COLOR == 1 && -t 2 ]] || return 0
  W_SAY=$'\e[36m' W_HEAD=$'\e[1;34m' W_TODO=$'\e[33m' W_WARN=$'\e[31m' W_IN=$'\e[1;32m' W_OFF=$'\e[0m'
}

# say <text…> — the wizard talks on stderr: stdout of install ends with its JSON.
say() {
  local line
  for line in "$@"; do printf '%s%s%s\n' "$W_SAY" "$line" "$W_OFF" >&2; done
}

# say_warn <text> — an answer is refused: why.
say_warn() { printf '%s%s%s\n' "$W_WARN" "$1" "$W_OFF" >&2; }

# prompt <text> — the question, then the color of what the user types.
prompt() { printf '%s%s%s%s' "$W_SAY" "$1" "$W_OFF" "$W_IN" >&2; }

# wizard_read <var> — one line of the answer; no answer (end of input) cancels.
wizard_read() {
  local rc=0
  IFS= read -r "$1" || rc=$?
  printf '%s' "$W_OFF" >&2
  ((rc == 0)) || die "$E_CANCELLED" "cancelled: no answer, nothing was written or changed"
}

# wizard_confirm <question> — yes or not.
wizard_confirm() {
  local answer rc=0
  prompt "$1 Type yes: "
  IFS= read -r answer || rc=$?
  printf '%s' "$W_OFF" >&2
  ((rc == 0)) && [[ $answer == yes ]]
}

# wizard_todo <where> <item…> — what to do outside the installer before the next answers, numbered.
# An item starting with "-" continues the item before it.
wizard_todo() {
  local where=$1 item n=0
  shift
  printf '\n%s%s%s\n' "$W_TODO" "Do in $where, then answer below:" "$W_OFF" >&2
  for item in "$@"; do
    if [[ $item == -* ]]; then
      printf '%s     %s%s\n' "$W_TODO" "${item#-}" "$W_OFF" >&2
    else
      n=$((n + 1))
      printf '%s  %d. %s%s\n' "$W_TODO" "$n" "$item" "$W_OFF" >&2
    fi
  done
}

# wizard_set <key> <value> — an answer: the variable of this run and a line of the file.
wizard_set() {
  printf -v "$1" '%s' "$2"
  export "${1?}"
  CONFIG_EXPLICIT[$1]=1
  [[ " ${WIZARD_KEYS[*]} " == *" $1 "* ]] || WIZARD_KEYS+=("$1")
}

# ask <key> <question> [<regex> <hint> [<suggestion>]] — Enter keeps the shown value, "-" empties it.
ask() {
  local key=$1 question=$2 re=${3:-} hint=${4:-} value=${!1:-} answer
  [[ -n $value ]] || value=${5:-}
  while true; do
    prompt "$question${value:+ [$value]}: "
    wizard_read answer
    case $answer in
      "") answer=$value ;;
      -) answer="" ;;
    esac
    if [[ -n $re && ! $answer =~ $re ]]; then
      say_warn "  ${hint:-not a valid value}"
      continue
    fi
    break
  done
  wizard_set "$key" "$answer"
}

# ask_choice <key> <question> <value>=<label>… — a numbered choice; Enter keeps the current value.
ask_choice() {
  local key=$1 question=$2 current=${!1:-} i=1 answer def="" opt
  shift 2
  local values=()
  say "$question"
  for opt in "$@"; do
    values+=("${opt%%=*}")
    [[ ${opt%%=*} == "$current" ]] && def=$i
    say "  $i) ${opt#*=}"
    i=$((i + 1))
  done
  [[ -n $def ]] || def=1
  while true; do
    prompt "Choice [$def]: "
    wizard_read answer
    answer=${answer:-$def}
    if [[ $answer =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#values[@]})); then
      wizard_set "$key" "${values[answer - 1]}"
      return
    fi
    say_warn "  a number from 1 to ${#values[@]}"
  done
}

# ask_yes_no <key> <question> — true or false.
ask_yes_no() {
  local key=$1 def=n answer
  [[ ${!1:-false} == true ]] && def=y
  while true; do
    prompt "$2 (y/n) [$def]: "
    wizard_read answer
    case ${answer:-$def} in
      y | yes) wizard_set "$key" true && return ;;
      n | no) wizard_set "$key" false && return ;;
    esac
  done
}

# secret_known <key> — the secret has a value already: typed, in the environment or a file, or kept by an
# earlier install in the cluster (product-inputs, the *-conn secrets; nothing without kubectl and jq).
secret_known() {
  [[ -n ${WIZARD_SECRETS[$1]+x} ]] && return 0
  if [[ " ${PRODUCT_SECRET_KEYS[*]} " == *" $1 "* ]]; then
    [[ -n $(product_secret "$1") ]]
  else
    [[ -n $(secret_value "$1") ]]
  fi
}

# ask_secret <key> <question> [optional] — hidden input; a known secret stays on Enter.
ask_secret() {
  local key=$1 known=0 answer xtrace=0
  secret_known "$key" && known=1
  # Tracing would print the value.
  [[ $- == *x* ]] && xtrace=1 && set +x
  while true; do
    if ((known)); then prompt "$2 [set, Enter keeps it]: "; else prompt "$2${3:+ [optional]}: "; fi
    IFS= read -rs answer || { printf '%s\n' "$W_OFF" >&2; die "$E_CANCELLED" "cancelled: no answer, nothing was written or changed"; }
    printf '%s\n' "$W_OFF" >&2
    [[ -n $answer || $known == 1 || -n ${3:-} ]] && break
    say_warn "  a value is required"
  done
  if [[ -n $answer ]]; then WIZARD_SECRETS[$key]=$answer; fi
  ((xtrace)) && set -x
  return 0
}

# ask_secret_file <key> <question> — a file whose content is the secret (a .pem); the path is not kept.
ask_secret_file() {
  local key=$1 path known=0
  secret_known "$key" && known=1
  while true; do
    if ((known)); then prompt "$2 [set, Enter keeps it]: "; else prompt "$2: "; fi
    wizard_read path
    path=${path/#\~/$HOME}
    if [[ -z $path ]]; then
      ((known)) && return 0
      say_warn "  a file is required"
    elif [[ -r $path ]]; then
      WIZARD_SECRETS[$key]=$(<"$path")
      return 0
    else
      say_warn "  cannot read $path"
    fi
  done
}

# wizard_steps — the steps of the wizard for the answers so far: Hammurapi, Models and the size of minikube
# come and go with the products and the cluster, so the count may change after those answers.
wizard_steps() {
  local steps=("Where to install" "Products" "Domain and certificates" "Sign-in")
  [[ ${PRODUCTS:-} == *hammurapi* ]] && steps+=("Hammurapi")
  steps+=("Storages" "Observability" "MCP servers")
  [[ ${NABU_MODE:-internal} == internal ]] && steps+=("Models")
  [[ ${INSTALL_TARGET:-minikube} == minikube ]] && steps+=("Size of minikube")
  steps+=("Summary")
  printf '%s\n' "${steps[@]}"
}

# wizard_section <step> — the heading with the number of the step and the count.
wizard_section() {
  local steps=() i n=0
  mapfile -t steps < <(wizard_steps)
  for i in "${!steps[@]}"; do [[ ${steps[i]} == "$1" ]] && n=$((i + 1)); done
  if ((n)); then
    printf '\n%s== Step %d of %d: %s ==%s\n' "$W_HEAD" "$n" "${#steps[@]}" "$1" "$W_OFF" >&2
  else
    printf '\n%s== %s ==%s\n' "$W_HEAD" "$1" "$W_OFF" >&2
  fi
}

wizard_target() {
  wizard_section "Where to install"
  ask_choice INSTALL_TARGET "The cluster:" \
    "minikube=this machine: the installer sets up Docker and minikube (Debian 13; Ubuntu 24.04 or 26.04 LTS; RHEL, Rocky or AlmaLinux 9 and 10)" \
    "external=an existing Kubernetes cluster from kubeconfig: nothing changes on this machine"
  if [[ $INSTALL_TARGET == minikube ]]; then
    wizard_set KUBE_CONTEXT ""
    return
  fi
  local contexts=() c
  have kubectl || die "$E_PREREQ" "an existing cluster needs kubectl, helm and jq on this machine: install them and run ./installer again"
  mapfile -t contexts < <(kubectl config get-contexts -o name 2>/dev/null)
  ((${#contexts[@]})) || die "$E_PREREQ" "kubeconfig has no contexts: add the cluster with kubectl config and run ./installer again"
  local opts=()
  for c in "${contexts[@]}"; do opts+=("$c=$c"); done
  ask_choice KUBE_CONTEXT "The context of kubeconfig:" "${opts[@]}"
}

wizard_products() {
  wizard_section "Products"
  local choice=nabu
  if [[ ${PRODUCTS:-} == *hammurapi* ]]; then
    if [[ ${NABU_MODE:-internal} == external ]]; then choice=hammurapi; else choice=nabu,hammurapi; fi
  fi
  PRODUCTS=$choice
  ask_choice PRODUCTS "What to install:" \
    "nabu=Nabu: agents and chats" \
    "nabu,hammurapi=Nabu and Hammurapi" \
    "hammurapi=Hammurapi connected to a Nabu that runs elsewhere"
  # R11: the site of GreenOnGrey is ours, not a product to install (web. of the defaults goes); the hosts of Nabu
  # follow the products, and other hosts of the file stay.
  local nabu_hosts="${NABU_WEB_HOST:-nabu} ${NABU_API_HOST:-nabu-api}" extra=() h
  if [[ -n ${CONFIG_EXPLICIT[PUBLIC_EXTRA_HOSTS]+x} ]]; then
    for h in ${PUBLIC_EXTRA_HOSTS:-}; do [[ " $nabu_hosts " == *" $h "* ]] || extra+=("$h"); done
  fi
  if [[ $PRODUCTS == hammurapi ]]; then
    wizard_set NABU_MODE external
    wizard_set PUBLIC_EXTRA_HOSTS "${extra[*]}"
    wizard_todo "that Nabu" \
      "Sign in as an administrator and open Admin → Clients." \
      "Add a client for Hammurapi; copy its ID and secret: the secret is shown once."
    ask NABU_URL "The API of Nabu, https://…" '^https://[^ ]+$' "an https:// address"
    ask NABU_CLIENT_ID "The client ID" '.' "a value is required"
    ask_secret NABU_CLIENT_SECRET "The client secret"
  else
    wizard_set NABU_MODE internal
    wizard_set PUBLIC_EXTRA_HOSTS "$nabu_hosts${extra[*]:+ ${extra[*]}}"
  fi
  wizard_set PUBLIC_ACCESS true
  if [[ $PRODUCTS == *hammurapi* ]]; then
    # FTR.HMR.DEV-0003 R23: the language of the documents, apart from the language of the interface
    [[ ${SPEC_LANGUAGE:-} == ru || ${SPEC_LANGUAGE:-} == en ]] || SPEC_LANGUAGE=$([[ ${DEFAULT_LANGUAGE:-en} == ru ]] && echo ru || echo en)
    ask_choice SPEC_LANGUAGE "The language of the specifications (the headings Hammurapi reads and writes in them):" \
      "ru=Russian" "en=English"
    ask_choice HAMMURAPI_GIT_PROVIDER "The repositories of Hammurapi live on:" \
      "github=GitHub (github.com or GitHub Enterprise)" "gitlab=GitLab (gitlab.com or self-hosted)"
  fi
}

wizard_domain() {
  wizard_section "Domain and certificates"
  local was=${TLS_TERMINATION:-ingress}
  ask_choice TLS_TERMINATION "Where is TLS terminated?" \
    "ingress=here: the install gets certificates (Let's Encrypt, or the ClusterIssuer of the cluster)" \
    "external=on a load balancer in front of the install, kept by your team: it sends HTTP to port 80"
  if [[ $INSTALL_TARGET == external ]]; then
    ask_choice INGRESS_MODE "Ingress:" \
      "internal=install Traefik$([[ $TLS_TERMINATION == ingress ]] && echo " and cert-manager") into the cluster" \
      "external=use an ingress class$([[ $TLS_TERMINATION == ingress ]] && echo " and a ClusterIssuer") the cluster already has"
    if [[ $INGRESS_MODE == external ]]; then
      ask INGRESS_CLASS "The ingress class" '^[a-z0-9][a-z0-9.-]*$' "the name of an IngressClass"
      [[ $TLS_TERMINATION == external ]] ||
        ask ACME_ISSUER "The ClusterIssuer" '^[a-z0-9][a-z0-9.-]*$' "the name of a ClusterIssuer"
    else
      wizard_set INGRESS_CLASS traefik
    fi
  else
    wizard_set INGRESS_MODE internal
    wizard_set INGRESS_CLASS traefik
  fi
  local re='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' ip='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  say "The products get hosts of the domain (the summary lists them): point them, or *.<domain>, to this installation."
  if [[ $TLS_TERMINATION == external ]]; then
    ask PUBLIC_BASE_DOMAIN "The domain" "$re" "a domain such as example.com: the certificate of the load balancer names it"
    ask PUBLIC_IP "The address the hosts resolve to (the load balancer), for the DNS check; \"-\" to skip it" "^$|$ip" "an IPv4 address"
    if [[ $INGRESS_MODE == internal ]]; then
      say "Traefik trusts the headers X-Forwarded-* (the original scheme and client) only from the load balancer."
      ask TLS_PROXY_CIDRS "Addresses or CIDRs of the load balancer, comma-separated" "$CIDR_LIST_RE" "such as 10.0.0.0/24,10.0.1.5"
    fi
    say "The load balancer redirects HTTP to HTTPS itself; the install answers on port 80 only."
    # The charts of the products answer HTTP from this release on.
    local chart
    for chart in NABU_CHART_VERSION HAMMURAPI_CHART_VERSION; do
      if [[ $(printf '%s\n%s\n' "$TLS_EXTERNAL_CHART_MIN" "${!chart}" | sort -V | head -1) != "$TLS_EXTERNAL_CHART_MIN" ]]; then
        say "$chart=$TLS_EXTERNAL_CHART_MIN: the charts of the products answer HTTP behind a load balancer from this version on."
        wizard_set "$chart" "$TLS_EXTERNAL_CHART_MIN"
      fi
    done
    return
  fi
  # PUBLIC_IP named the load balancer; on the ingress it is the address of the machine, detected when empty.
  [[ $was != external ]] || wizard_set PUBLIC_IP ""
  if [[ $INSTALL_TARGET == minikube ]]; then
    say "$SSLIP_WARNING"
    ask PUBLIC_BASE_DOMAIN "The domain, Enter for <IP>.sslip.io" "^$|$re" "a domain such as example.com"
  else
    ask PUBLIC_BASE_DOMAIN "The domain" "$re" "a domain such as example.com: an existing cluster needs one"
  fi
  if [[ $INGRESS_MODE == internal ]]; then
    ask ACME_EMAIL "The e-mail for the notices of Let's Encrypt" '^[^ ]+@[^ ]+\.[^ ]+$' "an e-mail address"
  fi
}

wizard_auth() {
  wizard_section "Sign-in"
  local api="https://${NABU_API_HOST:-nabu-api}.${PUBLIC_BASE_DOMAIN:-<domain>}"
  local hmr="https://${HAMMURAPI_API_HOST:-hammurapi-api}.${PUBLIC_BASE_DOMAIN:-<domain>}"
  if [[ $PRODUCTS == *hammurapi* && ${HAMMURAPI_GIT_PROVIDER:-github} == gitlab ]]; then
    say "People sign in with OpenID Connect (Keycloak, Google, Entra ID, GitLab itself…): Hammurapi works with GitLab."
    wizard_set AUTH_PROVIDER oidc
  else
    ask_choice AUTH_PROVIDER "People sign in with:" "github=GitHub" "oidc=OpenID Connect (Keycloak, Google, Entra ID…)"
  fi
  local web="https://${NABU_WEB_HOST:-nabu}.${PUBLIC_BASE_DOMAIN:-<domain>}"
  if [[ $AUTH_PROVIDER == github ]]; then
    if [[ $NABU_MODE == internal ]]; then
      wizard_todo "GitHub: the OAuth App of Nabu" \
        "Open Settings → Developer settings → OAuth Apps → New OAuth App, of the organization or of your account:" \
        "-https://github.com/settings/applications/new" \
        "Application name: Nabu; Homepage URL: $web" \
        "Authorization callback URL: $api/auth/callback" \
        "Register application; copy the Client ID, then Generate a new client secret and copy it."
      ask NABU_GITHUB_CLIENT_ID "Its client ID" '.' "a value is required"
      ask_secret NABU_GITHUB_CLIENT_SECRET "Its client secret"
    fi
    ask GITHUB_ALLOWED_ORG "Only members of this GitHub organization, Enter for anyone" '^[A-Za-z0-9-]*$' "the login of an organization"
  else
    local callbacks=()
    [[ $NABU_MODE == internal ]] && callbacks+=("$api/auth/callback")
    [[ $PRODUCTS == *hammurapi* ]] && callbacks+=("$hmr/api/v1/auth/callback")
    wizard_todo "the identity provider (Keycloak, Google, Entra ID…): one client for all products" \
      "Create an OpenID Connect client with a secret (Keycloak: Clients → Create client;" \
      "-Client authentication on, Standard flow on)." \
      "Valid redirect URIs, each of them:" "${callbacks[@]/#/-}" \
      "Copy the client ID and its secret (Keycloak: the tab Credentials)." \
      "The issuer is the address of the realm or tenant, such as https://sso.example.com/realms/<realm>."
    ask OIDC_ISSUER "The issuer, https://…" '^https://[^ ]+$' "an https:// address"
    ask OIDC_CLIENT_ID "The client ID" '.' "a value is required"
    ask_secret OIDC_CLIENT_SECRET "The client secret"
    ask OIDC_PROVIDER_NAME "The name on the sign-in button" '' '' "Single sign-on"
  fi
  ask BOOTSTRAP_ADMINS "Administrators: logins or e-mails, comma-separated" '.' "at least one administrator"
}

wizard_hammurapi() {
  [[ $PRODUCTS == *hammurapi* ]] || return 0
  local hmr="https://${HAMMURAPI_API_HOST:-hammurapi-api}.${PUBLIC_BASE_DOMAIN:-<domain>}"
  wizard_section "Hammurapi"
  if [[ ${HAMMURAPI_GIT_PROVIDER:-github} == gitlab ]]; then
    wizard_hammurapi_gitlab "$hmr"
    return
  fi
  wizard_todo "GitHub: the GitHub App of Hammurapi" \
    "Create the repository of specifications, if there is none, with rules/ of the repository hammurapi." \
    "Open Settings → Developer settings → GitHub Apps → New GitHub App, of the organization:" \
    "-https://github.com/organizations/<organization>/settings/apps/new" \
    "GitHub App name: any free name, such as hammurapi-<company>; Homepage URL: https://${HAMMURAPI_WEB_HOST:-hammurapi}.${PUBLIC_BASE_DOMAIN:-<domain>}" \
    "Callback URL: $hmr/api/v1/auth/callback; Expire user authorization tokens: on." \
    "Webhook: Active, URL $hmr/hooks/v1/git, secret empty: the installer writes the address and the secret." \
    "Repository permissions, Read and write: Contents, Pull requests, Issues, Actions, Workflows;" \
    "-Read-only: Checks, Commit statuses, Metadata." \
    "Subscribe to events: Push, Pull request, Pull request review, Pull request review comment, Issue comment," \
    "-Check suite, Status." \
    "Create GitHub App; copy the App ID and the Client ID from its page." \
    "Generate a new client secret and copy it; Generate a private key: a .pem downloads, copy it to this machine." \
    "Install App: on the repository of specifications and on the repositories of services."
  ask HAMMURAPI_GITHUB_APP_ID "The App ID" '^[0-9]+$' "a number"
  ask HAMMURAPI_GITHUB_CLIENT_ID "Its client ID" '.' "a value is required"
  ask_secret HAMMURAPI_GITHUB_CLIENT_SECRET "Its client secret"
  ask_secret_file HAMMURAPI_GITHUB_APP_PRIVATE_KEY "The file of its private key (.pem)"
  ask HAMMURAPI_SPEC_REPO "The repository of specifications, owner/name" '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' "owner/name"
}

# wizard_hammurapi_gitlab <api of Hammurapi> — the OAuth application links the GitLab account of a person
# (commits and merge requests in their name); the bot commits, merges and keeps the webhook of the project.
wizard_hammurapi_gitlab() {
  ask HAMMURAPI_GITLAB_URL "The address of GitLab" '^https?://[^/[:space:]]+(/[^[:space:]]*)?$' "an http(s):// address" \
    https://gitlab.com
  local gl=${HAMMURAPI_GITLAB_URL%/}
  wizard_todo "GitLab: the application of Hammurapi (people link their GitLab accounts through it)" \
    "Open User settings → Applications → Add new application:" \
    "-$gl/-/user_settings/applications" \
    "-(or Settings → Applications of a group, or Admin → Applications of the instance)" \
    "Name: Hammurapi; Redirect URI: $1/api/v1/auth/git/callback" \
    "Confidential: on; scopes: api, read_user." \
    "Save application; copy the Application ID and the Secret."
  ask HAMMURAPI_GITLAB_CLIENT_ID "Its application ID" '.' "a value is required"
  ask_secret HAMMURAPI_GITLAB_CLIENT_SECRET "Its secret"
  wizard_todo "GitLab: the project of specifications" \
    "Create the project, if there is none, with rules/ of the repository hammurapi and the default branch main." \
    "Its path is what follows $gl/ in its address, such as platform/specs."
  ask HAMMURAPI_SPEC_REPO "The project of specifications, group/project" '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$' \
    "group/project, subgroups too"
  wizard_todo "GitLab: the bot of Hammurapi (it commits, merges at a release and keeps the webhook)" \
    "Either a user, such as hammurapi-bot: add it to $gl/$HAMMURAPI_SPEC_REPO/-/project_members as a Maintainer," \
    "-sign in as it and create a personal access token: $gl/-/user_settings/personal_access_tokens" \
    "Or a project or group access token: Settings → Access tokens of the project or of its group," \
    "-role Maintainer." \
    "Scope of the token: api. Mind its expiry date: Hammurapi stops working on it when it expires." \
    "Copy the token. The installer adds the webhook of the project and generates its secret." \
    "After the install, add the same webhook to the projects of services (or once to their group, GitLab Premium):" \
    "-docs/products.md, section Hammurapi on GitLab, shows its address and how to read its secret." \
    "Self-hosted GitLab refuses webhooks to private addresses (such as 10.x, 192.168.x) by default: if" \
    "-${HAMMURAPI_API_HOST:-hammurapi-api}.${PUBLIC_BASE_DOMAIN:-<domain>} resolves to one, an administrator of GitLab allows it in" \
    "-Admin → Settings → Network → Outbound requests: Allow requests to the local network from webhooks," \
    "-or adds ${HAMMURAPI_API_HOST:-hammurapi-api}.${PUBLIC_BASE_DOMAIN:-<domain>} to the allowlist there."
  ask_secret HAMMURAPI_GITLAB_BOT_TOKEN "The token of the bot"
}

wizard_storages() {
  wizard_section "Storages"
  local hint="built-in: installed into the cluster, with no backups of their own"
  ask_choice POSTGRES_MODE "Postgres:" "internal=built-in ($hint)" "external=external: Postgres 16+ with the extension vector"
  if [[ $POSTGRES_MODE == external ]]; then
    ask POSTGRES_HOST "Host" '.' "a value is required"
    ask POSTGRES_PORT "Port" '^[0-9]+$' "a number" 5432
    ask POSTGRES_DATABASE "Database" '.' "a value is required"
    ask POSTGRES_USER "User, the owner of the database" '.' "a value is required"
    ask POSTGRES_SSLMODE "sslmode" '^(disable|require|verify-ca|verify-full)$' "disable, require, verify-ca or verify-full" require
    ask_secret POSTGRES_PASSWORD "Password"
  fi
  ask_choice KAFKA_MODE "Kafka:" "internal=built-in" "external=external"
  if [[ $KAFKA_MODE == external ]]; then
    ask KAFKA_BOOTSTRAP "Bootstrap servers, host:port,…" '.' "a value is required"
    ask_choice KAFKA_SECURITY_PROTOCOL "Security protocol:" "PLAINTEXT=PLAINTEXT" "SASL_SSL=SASL_SSL"
    if [[ $KAFKA_SECURITY_PROTOCOL == SASL_SSL ]]; then
      ask_choice KAFKA_SASL_MECHANISM "SASL mechanism:" "PLAIN=PLAIN" "SCRAM-SHA-512=SCRAM-SHA-512" "OAUTHBEARER=OAUTHBEARER"
      ask KAFKA_USERNAME "User" '.' "a value is required"
      ask_secret KAFKA_PASSWORD "Password"
    fi
  fi
  ask_choice S3_MODE "S3:" "internal=built-in" "external=external: any S3-compatible storage"
  if [[ $S3_MODE == external ]]; then
    ask S3_ENDPOINT "Endpoint, https://…" '^https?://[^ ]+$' "an http(s):// address"
    ask S3_REGION "Region" '.' "a value is required"
    ask S3_BUCKET "The bucket of Hammurapi" '.' "a value is required"
    ask S3_BUCKET_NABU "The bucket of Nabu" '.' "a value is required"
    ask_yes_no S3_PATH_STYLE "Path-style addresses (MinIO and most self-hosted storages)"
    ask_secret S3_ACCESS_KEY "Access key"
    ask_secret S3_SECRET_KEY "Secret key"
  fi
  wizard_section "Observability"
  ask_yes_no OBSERVABILITY "Install metrics, logs and Grafana"
}

# mcp_catalog — "name<TAB>MiB<TAB>what it does" of the servers the wizard offers.
mcp_catalog() { sed '/^#/d; /^$/d' "$ROOT/config/mcp-servers.tsv"; }

wizard_mcp() {
  wizard_section "MCP servers"
  local names=() mibs=() i=1 name mib what o mark answer n
  while IFS=$'\t' read -r name mib what; do
    names+=("$name") mibs+=("$mib")
    o=$(mcp_opt "$name")
    mark=" "
    [[ ${!o:-false} == true ]] && mark=x
    say "  $i) [$mark] $name, $(awk -v m="$mib" 'BEGIN { printf "%.1f", m / 1024 }') GiB: $what"
    i=$((i + 1))
  done < <(mcp_catalog)
  while true; do
    prompt 'Numbers of the servers to install, "-" for none, Enter keeps the marked ones: '
    wizard_read answer
    [[ -z $answer || $answer == - || $answer =~ ^[0-9\ ,]+$ ]] && break
    say_warn "  numbers such as 1 3"
  done
  if [[ -n $answer ]]; then
    for i in "${!names[@]}"; do
      o=$(mcp_opt "${names[i]}")
      printf -v "$o" false
    done
    for n in ${answer//,/ }; do
      [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#names[@]})) || continue
      o=$(mcp_opt "${names[n - 1]}")
      printf -v "$o" true
    done
  fi
  WIZARD_MCP_MIB=0
  for i in "${!names[@]}"; do
    o=$(mcp_opt "${names[i]}")
    wizard_set "$o" "${!o:-false}"
    [[ " ${MCP_OPTIONS[*]} " == *" $o "* ]] || MCP_OPTIONS+=("$o")
    [[ ${!o} == true ]] && WIZARD_MCP_MIB=$((WIZARD_MCP_MIB + mibs[i]))
  done
  ((WIZARD_MCP_MIB == 0)) || say "The servers request $(awk -v m="$WIZARD_MCP_MIB" 'BEGIN { printf "%.1f", m / 1024 }') GiB of memory."
  if [[ ${MCP_YANDEX_MAIL:-false} == true ]]; then
    say "Yandex Mail: after the install, add the server to the catalog of Nabu (./installer creds shows its address)," \
      "  then create an app at https://oauth.yandex.ru/client/new (web services) with the permissions mail:imap_ro" \
      "  and login:email, and the redirect URI https://${NABU_API_HOST:-nabu-api}.${PUBLIC_BASE_DOMAIN:-<domain>}/api/v1/oauth/callback/<ID of the entry>;" \
      "  its ID and secret go to the catalog entry."
  fi
}

# wizard_memory_gib — the memory of the minikube profile for the stand and the chosen servers: the stand
# takes 12 GiB, and a server needs half as much again as it requests (the budget is two thirds, R21).
wizard_memory_gib() {
  local want=$((12 + (WIZARD_MCP_MIB * 3 / 2 + 1023) / 1024)) now=${MK_MEMORY%[gGmM]}
  # minikube reads a number without a unit as MB.
  [[ $MK_MEMORY == *[gG] ]] || now=$((now / 1024))
  ((now > want)) && want=$now
  echo "$want"
}

wizard_extras() {
  if [[ $NABU_MODE == internal ]]; then
    wizard_section "Models"
    ask_secret BOOTSTRAP_LLM_API_KEY "The key of the first model connection of Nabu, Enter to add one later in the admin area" optional
  fi
  [[ $INSTALL_TARGET == minikube ]] || return 0
  wizard_section "Size of minikube"
  local mem_gb
  mem_gb=$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 }' "$MEMINFO_FILE" 2>/dev/null || echo "?")
  say "This machine: $(host_cpus 2>/dev/null || echo "?") CPUs, $mem_gb GB of memory."
  ask MK_CPUS "CPUs" '^[0-9]+$' "a number"
  local suggest
  suggest=$(wizard_memory_gib)
  [[ ${MK_MEMORY%[gGmM]} == "$suggest" && $MK_MEMORY == *[gG] ]] || say "With these MCP servers MK_MEMORY=${suggest}g is needed."
  MK_MEMORY=${suggest}g
  ask MK_MEMORY "Memory" '^[0-9]+[gGmM]$' "a number with g or m, such as 12g"
  ask MK_DISK "Disk" '^[0-9]+[gG]$' "a number with g, such as 60g"
  if ((WIZARD_CLUSTER)) && cluster_running 2>/dev/null; then
    say "The profile $MK_PROFILE exists: a new size applies only after ./installer uninstall."
  fi
}

# wizard_check — the answers pass the same checks as install (R4); the message, if not.
wizard_check() {
  (
    for k in "${!WIZARD_SECRETS[@]}"; do export "$k=${WIZARD_SECRETS[$k]}"; done
    STEP=wizard
    validate_config products >/dev/null
    # Without the time of the log line: two passes compare their messages.
  ) 2>&1 | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z //'
}

# wizard_summary — the answers without secrets.
wizard_summary() {
  local k
  wizard_section "Summary"
  for k in "${WIZARD_KEYS[@]}"; do say "  $k=${!k}"; done
  for k in "${!WIZARD_SECRETS[@]}"; do say "  $k: typed in, kept in the cluster"; done
  local hosts
  hosts=$(public_hosts)
  say "" "Hosts: ${hosts// /, } of ${PUBLIC_BASE_DOMAIN:-<IP>.sslip.io}."
  [[ -n ${PUBLIC_BASE_DOMAIN:-} ]] || say "$SSLIP_WARNING"
}

# env_line <key> — KEY=value, quoted for the shell when needed.
env_line() {
  local v=${!1}
  if [[ $v =~ ^[A-Za-z0-9_./:@,+-]*$ ]]; then
    printf '%s=%s\n' "$1" "$v"
  else
    printf "%s='%s'\n" "$1" "${v//\'/\'\\\'\'}"
  fi
}

# wizard_content <file> — the file with the answered keys replaced: other lines and comments stay.
wizard_content() {
  local k
  if [[ -f $1 ]]; then
    awk -v keys=" ${WIZARD_KEYS[*]} " -v header="$WIZARD_HEADER" '
      $0 == header { next }
      match($0, /^[[:space:]]*[A-Z_][A-Z0-9_]*=/) {
        k = substr($0, RSTART, RLENGTH - 1); sub(/^[[:space:]]*/, "", k)
        if (index(keys, " " k " ")) next
      }
      { print }' "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
    echo
  fi
  echo "$WIZARD_HEADER"
  for k in "${WIZARD_KEYS[@]}"; do env_line "$k"; done
}

# wizard_write <file> — through sudo where the user cannot write.
wizard_write() {
  local file=$1 dir content
  dir=$(dirname "$file")
  content=$(wizard_content "$file")
  if [[ -w $file || (! -e $file && -w $dir) ]]; then
    printf '%s\n' "$content" >"$file"
  else
    as_root mkdir -p "$dir"
    printf '%s\n' "$content" | as_root tee "$file" >/dev/null
    as_root chmod 0644 "$file"
  fi
  log "configuration: $file"
}

# wizard_install <file> — install --config <file>, as CI runs it: the configuration of this process is
# dropped, so the run reads the file; the environment of the user stays, apart from the keys answered.
wizard_install() {
  local file=$1 k flags=()
  while read -r k; do
    if [[ " ${WIZARD_KEYS[*]} " == *" $k "* || " $ORIG_ENV_NAMES " != *" $k "* ]]; then
      unset "$k" 2>/dev/null || true
    fi
  done < <({ env_keys "$ROOT/config/versions.env"; env_keys "$ROOT/config/defaults.env"; env_keys "$file"; } | sort -u)
  for k in "${!WIZARD_SECRETS[@]}"; do export "$k=${WIZARD_SECRETS[$k]}"; done
  ((VERBOSE)) && flags+=(--verbose)
  [[ $COLOR == 0 && -t 1 ]] && flags+=(--no-color)
  export INSTALLER_WIZARD=1
  exec "${WIZARD_INSTALLER:-$ROOT/installer}" install --config "$file" "${flags[@]}"
}

cmd_wizard() {
  local file=$1 err last_err=""
  wizard_colors
  # Ctrl-C or a cancel at a prompt leaves the color of the input on: the terminal gets it back.
  trap 'printf "%s" "$W_OFF" >&2' EXIT
  trap 'printf "%s\n" "$W_OFF" >&2; exit 130' INT
  say "GreenOnGrey installer $(installer_version): questions first, then the same install as ./installer install."
  say "Enter keeps the value in brackets; nothing changes until you confirm the summary."
  if [[ -n $W_OFF ]]; then
    printf '%s%s%s, %s%s%s, %s%s%s, %s%s%s.\n' "$W_HEAD" "Blue: the steps" "$W_OFF" "$W_SAY" "cyan: the installer" "$W_OFF" \
      "$W_TODO" "yellow: what to do in GitHub, GitLab or the identity provider" "$W_OFF" "$W_IN" "green: your answers" "$W_OFF" >&2
  fi
  if have kubectl && have jq; then WIZARD_CLUSTER=1; fi
  # R4: on an installed system the cluster holds the MCP options and the kept secrets.
  if ((WIZARD_CLUSTER)) && cluster_reachable 2>/dev/null; then restore_config; fi
  while true; do
    wizard_target
    wizard_products
    wizard_domain
    wizard_auth
    wizard_hammurapi
    wizard_storages
    wizard_mcp
    wizard_extras
    err=$(wizard_check) && break
    # The same failure after a second pass is in a key the wizard does not ask about.
    [[ $err != "${last_err:-}" ]] || die "$E_USAGE" "the configuration does not pass the checks of install; fix $file: $err"
    last_err=$err
    say "" "The answers do not pass the checks of install:" "$err" "The questions start again, with your answers."
  done
  wizard_summary
  wizard_confirm $'\n'"Write $file and install?" || die "$E_CANCELLED" "cancelled: nothing was written or changed"
  wizard_write "$file"
  wizard_install "$file"
}
