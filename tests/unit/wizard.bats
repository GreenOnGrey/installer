#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 R3, R4, R18, R19, R21: the wizard (lib/wizard.sh), the domain and the kept secrets.

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../../installer"

setup() {
  setup_stubs
  load_script
  interactive() { return 0; }
  host_cpus() { echo 8; }
  meminfo_gb 32
  FILE=$BATS_TEST_TMPDIR/installer.env
  # install --config as the wizard starts it: its arguments and environment.
  WIZARD_INSTALLER=$BATS_TEST_TMPDIR/fake-installer
  printf '#!/usr/bin/env bash\necho "$*" >"%s/install-args"\nenv >"%s/install-env"\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" >"$WIZARD_INSTALLER"
  chmod +x "$WIZARD_INSTALLER"
}

# answers <line…> — the input of the wizard, one answer per line.
answers() { printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/answers"; }

# Nabu on minikube with GitHub sign-in, built-in storages, no MCP server.
nabu_answers() {
  answers 1 1 1 "${1-}" ops@example.com 1 gh-client gh-secret "" alice 1 1 1 "" "" "" "" "" "" "${2:-yes}"
}

# load_file — the configuration of $FILE, as a new run reads it: the keys loaded by setup do not count as the environment.
load_file() {
  local k
  while read -r k; do unset "$k"; done < <(env_keys "$FILE")
  load_config "$ROOT" "$FILE"
}

wizard() { run cmd_wizard "$FILE" <"$BATS_TEST_TMPDIR/answers"; echo "$output" >"$BATS_TEST_TMPDIR/out"; echo "status $status" >>"$BATS_TEST_TMPDIR/out"; }

@test "CLI-02: no command in a terminal opens the wizard" {
  cmd_wizard() { echo "wizard $1"; }
  SYSTEM_CONFIG=$BATS_TEST_TMPDIR/etc/installer.env
  ROOT=$BATS_TEST_TMPDIR
  run main
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [[ ${lines[-1]} == "wizard $SYSTEM_CONFIG" ]]
  run main --config "$FILE"
  [[ ${lines[-1]} == "wizard $FILE" ]]
}

@test "CLI-03: a refused summary: code 16, no file, no install" {
  nabu_answers "" no
  wizard
  [ "$status" -eq 16 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [ ! -e "$FILE" ]
  [ ! -e "$BATS_TEST_TMPDIR/install-args" ]
}

@test "CLI-04: the file of the wizard is the one written by hand; install --config runs once with it" {
  nabu_answers stand.example.com
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  cat >"$BATS_TEST_TMPDIR/by-hand.env" <<'EOF'
# Written by the wizard of ./installer; secrets are kept in the cluster, not here.
INSTALL_TARGET=minikube
KUBE_CONTEXT=
PRODUCTS=nabu
NABU_MODE=internal
PUBLIC_EXTRA_HOSTS='nabu nabu-api'
PUBLIC_ACCESS=true
TLS_TERMINATION=ingress
INGRESS_MODE=internal
INGRESS_CLASS=traefik
PUBLIC_BASE_DOMAIN=stand.example.com
ACME_EMAIL=ops@example.com
AUTH_PROVIDER=github
NABU_GITHUB_CLIENT_ID=gh-client
GITHUB_ALLOWED_ORG=
BOOTSTRAP_ADMINS=alice
POSTGRES_MODE=internal
KAFKA_MODE=internal
S3_MODE=internal
OBSERVABILITY=true
MCP_DOCGEN=false
MCP_DOCLING=false
MCP_SEARCH=false
MCP_YANDEX_MAIL=false
MK_CPUS=3
MK_MEMORY=12g
MK_DISK=60g
EOF
  diff "$BATS_TEST_TMPDIR/by-hand.env" "$FILE"
  [ "$(cat "$BATS_TEST_TMPDIR/install-args")" = "install --config $FILE" ]
  grep -qx 'NABU_GITHUB_CLIENT_SECRET=gh-secret' "$BATS_TEST_TMPDIR/install-env"
  grep -qx 'INSTALLER_WIZARD=1' "$BATS_TEST_TMPDIR/install-env"
  # The file decides: nothing of the configuration of the wizard reaches install by the environment.
  not_grep -q '^PRODUCTS=' "$BATS_TEST_TMPDIR/install-env"
  not_grep -q '^MK_MEMORY=' "$BATS_TEST_TMPDIR/install-env"
}

@test "R19: the typed secret is in no file and in no argument" {
  nabu_answers stand.example.com
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  not_grep -rq gh-secret "$FILE" "$BATS_TEST_TMPDIR/install-args" "$CALLS"
  [[ $output != *gh-secret* ]]
}

@test "CLI-05: the wizard again: values of the file, secrets kept by the cluster shown as set" {
  printf 'PRODUCTS=nabu\nAUTH_PROVIDER=github\nNABU_GITHUB_CLIENT_ID=old-client\nBOOTSTRAP_ADMINS=bob\nPUBLIC_BASE_DOMAIN=old.example.com\nACME_EMAIL=me@example.com\nCUSTOM_KEY=stays\n' >"$FILE"
  load_file
  stored_input() { [[ $1 == NABU_GITHUB_CLIENT_SECRET ]] && echo kept; }
  # Enter everywhere: the values in brackets stay, and the kept secret needs no new value.
  answers "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" yes
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [[ $output == *"[old-client]"* && $output == *"[set, Enter keeps it]"* && $output == *"[bob]"* ]]
  grep -qx 'NABU_GITHUB_CLIENT_ID=old-client' "$FILE"
  grep -qx 'PUBLIC_BASE_DOMAIN=old.example.com' "$FILE"
  grep -qx 'CUSTOM_KEY=stays' "$FILE"
  [ "$(grep -c '^NABU_GITHUB_CLIENT_ID=' "$FILE")" -eq 1 ]
  not_grep -q NABU_GITHUB_CLIENT_SECRET "$BATS_TEST_TMPDIR/install-env"
}

@test "DOM-01: minikube without a domain: sslip.io, with the warning about the limits" {
  nabu_answers ""
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [[ $output == *"sslip.io shares one limit"* ]]
  grep -qx 'PUBLIC_BASE_DOMAIN=' "$FILE"
}

@test "DOM-02: an existing cluster without a domain: the question again" {
  stub kubectl '[[ $* == *get-contexts* ]] && echo corp; exit 0'
  answers 2 1 1 1 1 "" stand.example.com ops@example.com 1 gh-client gh-secret "" alice 1 1 1 "" "" "" yes
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [[ $output == *"an existing cluster needs one"* ]]
  grep -qx 'KUBE_CONTEXT=corp' "$FILE"
  grep -qx 'PUBLIC_BASE_DOMAIN=stand.example.com' "$FILE"
  not_grep -q '^MK_MEMORY=' "$FILE"
}

@test "R17: TLS on a load balancer: no e-mail for Let's Encrypt; its addresses and the address of DNS" {
  # Charts older than the minimum, whatever config/versions.env pins now: the wizard raises them.
  NABU_CHART_VERSION=0.3.0 HAMMURAPI_CHART_VERSION=0.3.0
  answers 1 1 2 stand.example.com 203.0.113.9 10.0.0.0/24,10.0.1.5 1 gh-client gh-secret "" alice 1 1 1 "" "" "" "" "" "" yes
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  grep -qx 'TLS_TERMINATION=external' "$FILE"
  grep -qx 'TLS_PROXY_CIDRS=10.0.0.0/24,10.0.1.5' "$FILE"
  grep -qx 'PUBLIC_IP=203.0.113.9' "$FILE"
  grep -qx "NABU_CHART_VERSION=$TLS_EXTERNAL_CHART_MIN" "$FILE"
  not_grep -q '^ACME_EMAIL=' "$FILE"
  [[ $output != *sslip.io* ]]
}

@test "R17: back from a load balancer to TLS on the ingress: its address is no longer PUBLIC_IP" {
  printf 'TLS_TERMINATION=external\nPUBLIC_IP=203.0.113.9\nTLS_PROXY_CIDRS=10.0.0.0/24\n' >"$FILE"
  load_file
  answers 1 1 1 stand.example.com ops@example.com 1 gh-client gh-secret "" alice 1 1 1 "" "" "" "" "" "" yes
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  grep -qx 'TLS_TERMINATION=ingress' "$FILE"
  grep -qx 'PUBLIC_IP=' "$FILE"
}

@test "PRD-03: the site is not offered; its host is not in PUBLIC_EXTRA_HOSTS" {
  nabu_answers stand.example.com
  wizard
  [[ $output != *landing* && $output != *"GreenOnGrey site"* ]]
  grep -qx "PUBLIC_EXTRA_HOSTS='nabu nabu-api'" "$FILE"
  PRODUCTS=nabu PUBLIC_EXTRA_HOSTS="nabu nabu-api"
  stub helm 'exit 1'
  [ "$(public_hosts)" = "grafana nabu nabu-api" ]
}

@test "PRD-03: hosts of the file other than those of Nabu stay; its own Nabu hosts are used" {
  printf 'PUBLIC_EXTRA_HOSTS="api docs"\nNABU_API_HOST=api\n' >"$FILE"
  load_file
  nabu_answers stand.example.com
  wizard
  grep -qx "PUBLIC_EXTRA_HOSTS='nabu api docs'" "$FILE"
  [[ $output == *"https://api.stand.example.com/auth/callback"* ]]
}

@test "MCP-04 (U): MK_MEMORY without a unit is MB, as minikube reads it; never more than the machine" {
  MK_MEMORY=16384
  [ "$(wizard_memory_gib)" = 16 ]
  meminfo_gb 15
  MK_MEMORY=17g
  [ "$(wizard_memory_gib)" = 15 ]
  # meminfo that cannot be read: no limit, no failure.
  MEMINFO_FILE=$BATS_TEST_TMPDIR/none
  [ "$(wizard_memory_gib)" = 17 ]
  run wizard_mcp_budget
  [ "$status" -eq 0 ]
}

@test "MCP-04 (U): an answer that fits stays as it is, without a note about the machine" {
  INSTALL_TARGET=minikube NABU_MODE=external MK_MEMORY=12500m
  printf '%s\n' "" "" "" >"$BATS_TEST_TMPDIR/answers"
  run wizard_extras <"$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ $output != *"gives minikube at most"* && $output == *"Memory [12500m]"* ]]
}

@test "R11: Hammurapi with an external Nabu: its client, the GitHub App and the key file" {
  printf -- '-----BEGIN KEY-----\nabc\n-----END KEY-----\n' >"$BATS_TEST_TMPDIR/app.pem"
  answers 1 3 https://nabu.corp.example nabu-client nabu-secret 1 1 1 stand.example.com ops@example.com \
    1 "" alice 42 app-client app-secret "$BATS_TEST_TMPDIR/app.pem" acme/specs 1 1 1 "" "" "" "" "" yes
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  grep -qx 'NABU_MODE=external' "$FILE"
  grep -qx 'PRODUCTS=hammurapi' "$FILE"
  grep -qx 'PUBLIC_EXTRA_HOSTS=' "$FILE"
  grep -qx 'HAMMURAPI_SPEC_REPO=acme/specs' "$FILE"
  grep -qx 'SPEC_LANGUAGE=ru' "$FILE" # FTR.HMR.DEV-0003 R23: the first choice
  not_grep -q "$BATS_TEST_TMPDIR/app.pem" "$FILE"
  not_grep -q 'BEGIN KEY' "$FILE"
  grep -q 'HAMMURAPI_GITHUB_APP_PRIVATE_KEY=-----BEGIN KEY-----' "$BATS_TEST_TMPDIR/install-env"
  grep -qx 'NABU_CLIENT_SECRET=nabu-secret' "$BATS_TEST_TMPDIR/install-env"
}

@test "Hammurapi on GitLab: OIDC sign-in without the question, the application, the project and the bot" {
  answers 1 2 1 2 1 stand.example.com ops@example.com \
    https://sso.example/realms/x gog oidc-secret "" alice \
    https://gitlab.corp.example gl-app gl-secret platform/product/specs glpat-bot 1 1 1 "" "" "" "" "" "" yes
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  grep -qx 'HAMMURAPI_GIT_PROVIDER=gitlab' "$FILE"
  grep -qx 'AUTH_PROVIDER=oidc' "$FILE"
  grep -qx 'HAMMURAPI_GITLAB_URL=https://gitlab.corp.example' "$FILE"
  grep -qx 'HAMMURAPI_GITLAB_CLIENT_ID=gl-app' "$FILE"
  grep -qx 'HAMMURAPI_SPEC_REPO=platform/product/specs' "$FILE"
  grep -q 'https://hammurapi-api.stand.example.com/api/v1/auth/git/callback' "$BATS_TEST_TMPDIR/out"
  not_grep -q 'People sign in with:' "$BATS_TEST_TMPDIR/out"
  not_grep -q 'GitHub App' "$BATS_TEST_TMPDIR/out"
  not_grep -q 'glpat-bot' "$FILE"
  grep -qx 'HAMMURAPI_GITLAB_BOT_TOKEN=glpat-bot' "$BATS_TEST_TMPDIR/install-env"
  grep -qx 'HAMMURAPI_GITLAB_CLIENT_SECRET=gl-secret' "$BATS_TEST_TMPDIR/install-env"
}

@test "the steps are numbered for the answers so far, and what to do outside is a numbered list" {
  nabu_answers
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  grep -qx '== Step 1 of 10: Where to install ==' "$BATS_TEST_TMPDIR/out"
  grep -qx '== Step 10 of 10: Summary ==' "$BATS_TEST_TMPDIR/out"
  grep -qx 'Do in GitHub: the OAuth App of Nabu, then answer below:' "$BATS_TEST_TMPDIR/out"
  grep -q '^  3. Authorization callback URL: https://nabu-api\.' "$BATS_TEST_TMPDIR/out"
  # Without a terminal there are no colors.
  not_grep -q $'\e\\[' "$BATS_TEST_TMPDIR/out"
}

@test "Hammurapi on GitLab: the steps count Hammurapi, the instructions name the links of that GitLab" {
  answers 1 2 1 2 1 stand.example.com ops@example.com \
    https://sso.example/realms/x gog oidc-secret "" alice \
    https://gitlab.corp.example gl-app gl-secret platform/specs glpat-bot 1 1 1 "" "" "" "" "" "" yes
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  grep -q '== Step 5 of 11: Hammurapi ==' "$BATS_TEST_TMPDIR/out"
  grep -q 'https://gitlab.corp.example/-/user_settings/applications' "$BATS_TEST_TMPDIR/out"
  grep -q 'https://gitlab.corp.example/platform/specs/-/project_members' "$BATS_TEST_TMPDIR/out"
  grep -q 'https://hammurapi-api.stand.example.com/api/v1/auth/callback' "$BATS_TEST_TMPDIR/out"
  grep -q 'https://nabu-api.stand.example.com/auth/callback' "$BATS_TEST_TMPDIR/out"
}

@test "MCP-04 (U): docling: the memory of the server; the profile stays 12g, the servers fit the machine" {
  answers 1 1 1 stand.example.com ops@example.com 1 gh-client gh-secret "" alice 1 1 1 "" 2 "" "" "" "" yes
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [[ $output == *"docling, 1.5 GiB"* ]]
  [[ $output != *"budget of this machine"* ]]
  grep -qx 'MCP_DOCLING=true' "$FILE"
  grep -qx 'MCP_SEARCH=false' "$FILE"
  grep -qx 'MK_MEMORY=12g' "$FILE"
}

@test "MCP-04 (U): a machine of 16 GB: 17g of an earlier answer becomes 16g, and more than the machine is asked again" {
  meminfo_gb 16
  INSTALL_TARGET=minikube NABU_MODE=external MK_MEMORY=17g WIZARD_MCP_MIB=$((2867))
  printf '%s\n' "" 20g "" "" >"$BATS_TEST_TMPDIR/answers"
  run wizard_extras <"$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ $output == *"This machine gives minikube at most 16g"* && $output == *"more than this machine has"* ]]
  [[ $output != *"budget of this machine"* ]]
  wizard_extras <"$BATS_TEST_TMPDIR/answers" 2>/dev/null
  [ "$MK_MEMORY" = 16g ]
}

@test "MCP-04 (U): servers above two thirds of the machine: a warning to turn some off" {
  meminfo_gb 4
  INSTALL_TARGET=minikube NABU_MODE=external WIZARD_MCP_MIB=3000
  printf '%s\n' "" "" "" >"$BATS_TEST_TMPDIR/answers"
  run wizard_extras <"$BATS_TEST_TMPDIR/answers"
  [[ $output == *"more than the budget of this machine (2 GiB)"* ]]
}

@test "R4: a question refuses an invalid answer and asks again" {
  # OIDC with an issuer, then an empty client ID is refused by the question itself.
  answers 1 1 1 stand.example.com ops@example.com 2 https://id.example.com "" client-id oidc-secret "" alice \
    1 1 1 "" "" "" "" "" "" yes
  wizard
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [[ $output == *"a value is required"* ]]
  grep -qx 'OIDC_CLIENT_ID=client-id' "$FILE"
}

@test "R4: answers that fail the checks of install: the questions again" {
  printf 'MCP_DOCLING_MAX_MB=999\n' >"$FILE"
  load_file
  # The same answers twice: the cause is in the file, and the wizard names it instead of asking forever.
  answers 1 1 1 s.example.com ops@example.com 1 c s "" alice 1 1 1 "" "" "" "" "" "" \
    1 1 1 s.example.com ops@example.com 1 c s "" alice 1 1 1 "" "" "" "" "" ""
  wizard
  [ "$status" -eq 2 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [[ $output == *"do not pass the checks of install"*"MCP_DOCLING_MAX_MB"* && $output == *"fix $FILE"* ]]
  [ "$(cat "$FILE")" = "MCP_DOCLING_MAX_MB=999" ]
}

@test "R4: no answer (end of input) cancels: code 16" {
  answers 1
  wizard
  [ "$status" -eq 16 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [ ! -e "$FILE" ]
}

@test "R4: the user's environment reaches install; the configuration loaded by the wizard does not" {
  ORIG_ENV_NAMES=" HOME PATH HTTPS_PROXY "
  export HTTPS_PROXY=http://proxy:3128
  nabu_answers stand.example.com
  wizard
  grep -qx 'HTTPS_PROXY=http://proxy:3128' "$BATS_TEST_TMPDIR/install-env"
  not_grep -q '^NS_STORAGES=' "$BATS_TEST_TMPDIR/install-env"
}

# --- R18: the domain ---

@test "DOM-04: minikube, no domain, no terminal: sslip.io and the warning in the log" {
  PUBLIC_ACCESS=true PUBLIC_IP=203.0.113.7
  run public_prepare
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [[ $output == *"203-0-113-7.sslip.io"* && $output == *"limits certificates"* ]]
}

@test "DOM-05: DNS points elsewhere: code 19 without the wizard, nothing requested" {
  PUBLIC_ACCESS=true PUBLIC_IP=203.0.113.7 PUBLIC_BASE_DOMAIN=stand.example.com PRODUCTS=nabu
  PUBLIC_EXTRA_HOSTS="nabu nabu-api"
  getent() { case $2 in nabu.*) echo "198.51.100.1 STREAM $2" ;; *) echo "203.0.113.7 STREAM $2" ;; esac; }
  stub helm 'exit 1'
  INSTALLER_WIZARD=0
  run public_prepare
  [ "$status" -eq 19 ]
  [[ $output == *"nabu.stand.example.com → 198.51.100.1"* ]]
  [[ $output != *"grafana.stand.example.com →"* ]]
  not_called kubectl
  # The wizard asks instead.
  INSTALLER_WIZARD=1
  run public_prepare <<<"no"
  [ "$status" -eq 16 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  run public_prepare <<<"yes"
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  # Behind a proxy the check is off.
  INSTALLER_WIZARD=0 PUBLIC_DNS_CHECK=false
  run public_prepare
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
}

@test "DOM-05: DNS points to the machine: the run goes on" {
  PUBLIC_ACCESS=true PUBLIC_IP=203.0.113.7 PUBLIC_BASE_DOMAIN=stand.example.com
  getent() { echo "203.0.113.7 STREAM $2"; }
  run public_prepare
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/out"; false; }
  [[ $output == *"point to 203.0.113.7"* ]]
}

@test "R18: a stand without products keeps the hosts of Hammurapi; Nabu alone leaves them out" {
  stub helm 'exit 1'
  PRODUCTS="" PUBLIC_EXTRA_HOSTS="nabu nabu-api web"
  [ "$(public_hosts)" = "hammurapi hammurapi-api grafana nabu nabu-api web" ]
  PRODUCTS=nabu,hammurapi
  [[ $(public_hosts) == "hammurapi hammurapi-api"* ]]
  PRODUCTS=nabu
  [[ $(public_hosts) != *hammurapi* ]]
  # Hammurapi deployed by its own CI keeps its hosts.
  stub helm '[[ $* == *"status hammurapi-core"* ]]'
  [[ $(public_hosts) == "hammurapi hammurapi-api"* ]]
}

# --- R19, tech §3.1: secrets kept by the cluster ---

# conn_secret <JSON of decoded data> — kubectl get secret answers with it.
conn_secret() {
  jq -c '{data: map_values(@base64)}' <<<"$1" >"$BATS_TEST_TMPDIR/secret.json"
  stub kubectl "cat '$BATS_TEST_TMPDIR/secret.json'"
}

@test "RES-08: a secret not given is taken from the cluster for the same host and user" {
  POSTGRES_HOST=db.corp POSTGRES_USER=app
  conn_secret '{"host": "db.corp", "username": "app", "password": "kept-pass"}'
  [ "$(secret_value POSTGRES_PASSWORD)" = kept-pass ]
  # A given value wins, and replaces the one of the cluster on install.
  POSTGRES_PASSWORD=new-pass
  [ "$(secret_value POSTGRES_PASSWORD)" = new-pass ]
}

@test "RES-08: another host or user is another resource: its secret is asked for" {
  POSTGRES_HOST=db2.corp POSTGRES_USER=app
  conn_secret '{"host": "db.corp", "username": "app", "password": "kept-pass"}'
  [ -z "$(secret_value POSTGRES_PASSWORD)" ]
  POSTGRES_MODE=external POSTGRES_PORT=5432 POSTGRES_DATABASE=d POSTGRES_SSLMODE=require
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"POSTGRES_PASSWORD"*"the cluster keeps none"* ]]
}

@test "RES-08: S3 keys and the Grafana secret come back the same way" {
  S3_ENDPOINT=https://s3.corp
  conn_secret '{"endpoint": "https://s3.corp", "bucket": "hammurapi", "access_key": "AK", "secret_key": "SK"}'
  [ "$(secret_value S3_ACCESS_KEY)" = AK ]
  [ "$(secret_value S3_SECRET_KEY)" = SK ]
  # Another bucket on the same endpoint may be another account.
  S3_BUCKET=other
  [ -z "$(secret_value S3_ACCESS_KEY)" ]
  GRAFANA_GITHUB_CLIENT_ID=gf
  conn_secret '{"GF_AUTH_GITHUB_CLIENT_ID": "gf", "GF_AUTH_GITHUB_CLIENT_SECRET": "gfs"}'
  [ "$(secret_value GRAFANA_GITHUB_CLIENT_SECRET)" = gfs ]
  # Product secrets are kept elsewhere (product-inputs).
  [ -z "$(secret_value NABU_GITHUB_CLIENT_SECRET)" ]
}
