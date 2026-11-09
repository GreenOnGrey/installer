#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 R11, R13: the products of an install, their sign-in and secrets (lib/product.sh).

load helpers

setup() {
  setup_stubs
  PRODUCTS=nabu
  load_script
  CONFIG_MISSING=()
}

# fake_deploy <body> — bin/nabu-deploy of the test: records its arguments, reads the payload.
fake_deploy() {
  PRODUCT_BIN=$BATS_TEST_TMPDIR/bin
  mkdir -p "$PRODUCT_BIN"
  printf '#!/usr/bin/env bash\necho "nabu-deploy $*" >>"$CALLS"\ncat >"$BATS_TEST_TMPDIR/payload-$1"\n%s\n' "$1" >"$PRODUCT_BIN/nabu-deploy"
}

# nabu_github — a complete configuration of Nabu with sign-in through GitHub.
nabu_github() {
  PUBLIC_ACCESS=true AUTH_PROVIDER=github BOOTSTRAP_ADMINS=admin@example.com NABU_GITHUB_CLIENT_ID=Iv1.abc
  export NABU_GITHUB_CLIENT_SECRET=gh-secret-XYZ
}

@test "PRD-05: Nabu without sign-in, administrators and public access: code 2, all named" {
  run validate_config products
  [ "$status" -eq 2 ]
  [[ $output == *PUBLIC_ACCESS* && $output == *AUTH_PROVIDER* && $output == *BOOTSTRAP_ADMINS* ]]
}

@test "R13: GitHub sign-in needs the client and its secret; a secret kept by an earlier install counts" {
  nabu_github
  unset NABU_GITHUB_CLIENT_SECRET
  NABU_GITHUB_CLIENT_ID=
  validate_products
  [[ ${CONFIG_MISSING[*]} == *NABU_GITHUB_CLIENT_ID* && ${CONFIG_MISSING[*]} == *NABU_GITHUB_CLIENT_SECRET* ]]
  CONFIG_MISSING=()
  NABU_GITHUB_CLIENT_ID=Iv1.abc PRODUCT_INPUTS_READ=0
  kc() { [[ "$*" == *"get secret product-inputs"* ]] && echo '{"data":{"NABU_GITHUB_CLIENT_SECRET":"a2VwdA=="}}'; return 0; }
  validate_products
  [ "${#CONFIG_MISSING[@]}" -eq 0 ]
}

@test "R13: OIDC sign-in needs the issuer, the client and its secret" {
  PUBLIC_ACCESS=true AUTH_PROVIDER=oidc BOOTSTRAP_ADMINS=a@example.com
  validate_products
  [[ ${CONFIG_MISSING[*]} == *OIDC_ISSUER* && ${CONFIG_MISSING[*]} == *OIDC_CLIENT_ID* && ${CONFIG_MISSING[*]} == *OIDC_CLIENT_SECRET* ]]
}

@test "R11: no products: nothing is required and nothing rolls out" {
  PRODUCTS=
  validate_products
  [ "${#CONFIG_MISSING[@]}" -eq 0 ]
  run deploy_products
  [ "$status" -eq 0 ]
  not_called nabu-deploy
}

@test "R11: an unknown product: code 2" {
  PRODUCTS=nabu,site
  run validate_products
  [ "$status" -eq 2 ]
}

@test "PRD-04 (U): SECRETS_KEY of an installed Nabu goes into the payload, a new one only at the first install" {
  nabu_github
  secret_key() { [[ "$*" == "nabu nabu-secrets SECRETS_KEY" ]] && printf 'kept-key'; }
  run nabu_payload nabu-core
  echo "$output" | jq -e --arg pi "$NABU_PI_VERSION" '.secrets.SECRETS_KEY == "kept-key" and .secrets.GITHUB_CLIENT_SECRET == "gh-secret-XYZ"
    and .config.AUTH_PROVIDER == "github" and .config.GITHUB_CLIENT_ID == "Iv1.abc" and .config.PI_VERSION == $pi
    and (.config | has("OIDC_ISSUER") | not) and (.secrets | has("BOOTSTRAP_LLM_API_KEY") | not)
    and .image == "ghcr.io/greenongrey/nabu-core"'
  secret_key() { return 1; }
  run nabu_payload nabu-core
  echo "$output" | jq -e '.secrets.SECRETS_KEY | test("^[0-9a-f]{64}$")'
}

@test "CLI-11 (U): the secrets of the products reach neither arguments nor the log" {
  nabu_github
  export BOOTSTRAP_LLM_API_KEY=sk-llm-SECRET
  secret_key() { printf 'kept-key-SECRET'; }
  fake_deploy 'echo "{\"status\":\"success\"}"'
  hm() { return 1; }
  kc() { echo "kubectl $*" >>"$CALLS"; [[ "$*" != apply* ]] || cat >/dev/null; }
  CONFIG_FILE=/dev/null
  run deploy_products
  [ "$status" -eq 0 ]
  local s
  for s in gh-secret-XYZ sk-llm-SECRET kept-key-SECRET; do
    not_called "$s"
    [[ $output != *"$s"* ]] || { echo "in the log: $s"; return 1; }
  done
}

@test "R11: a component rolled out by its own CI is left alone and listed as skipped" {
  nabu_github
  hm() { [[ $1 == status ]]; }
  state_data() { echo '{}'; }
  local rc=0
  deploy_component nabu-deploy nabu nabu-core v0.3.4 0.3.0 || rc=$?
  [ "$rc" -eq 1 ]
  [[ ${RESULT_SKIPPED[*]} == nabu-core ]]
  not_called nabu-deploy
}

@test "R11: a component of the installer rolls out with the pinned versions and is recorded" {
  nabu_github
  hm() { [[ $1 == status ]]; }
  state_data() { echo '{"nabu-core":"v0.3.3"}'; }
  fake_deploy 'echo "{\"status\":\"success\"}"'
  apply_stdin() { cat >"$BATS_TEST_TMPDIR/recorded"; }
  CONFIG_FILE=/dev/null
  deploy_component nabu-deploy nabu nabu-core "$NABU_CORE_VERSION" "$NABU_CHART_VERSION"
  called "nabu-deploy nabu-core $NABU_CORE_VERSION $NABU_CHART_VERSION"
  jq -e --arg v "$NABU_CORE_VERSION" '.data == {"nabu-core": $v}' "$BATS_TEST_TMPDIR/recorded"
  [[ ${RESULT_UPDATED[*]} == nabu-core ]]
}

@test "R11: a failed rollout stops install with the code of the script and its error" {
  nabu_github
  hm() { return 1; }
  fake_deploy 'echo "{\"status\":\"failure\",\"code\":26,\"error\":\"failed to create database nabu\"}"; exit 26'
  CONFIG_FILE=/dev/null
  run deploy_component nabu-deploy nabu nabu-core v0.3.4 0.3.0
  [ "$status" -eq 26 ]
  [[ $output == *"failed to create database nabu"* ]]
}

@test "R13: given secrets are kept in installer/product-inputs; kept ones without a new value stay" {
  nabu_github
  kc() { [[ "$*" == *"get secret product-inputs"* ]] && echo '{"data":{"BOOTSTRAP_LLM_API_KEY":"b2xk"}}'; return 0; }
  apply_stdin() { cat >"$BATS_TEST_TMPDIR/secret"; }
  save_product_inputs
  grep -q "NABU_GITHUB_CLIENT_SECRET: $(printf gh-secret-XYZ | base64 -w0)" "$BATS_TEST_TMPDIR/secret"
  grep -q "BOOTSTRAP_LLM_API_KEY: $(printf old | base64 -w0)" "$BATS_TEST_TMPDIR/secret"
}

@test "PRD-06 (U): without a model key the summary reminds to add a connection" {
  nabu_github
  PUBLIC_DOMAIN=x.example
  run products_summary
  [[ $output == *"https://nabu.x.example"* && $output == *BOOTSTRAP_LLM_API_KEY* ]]
}

@test "RES-09, R13: secrets of the products in the config file: code 2" {
  printf 'NABU_GITHUB_CLIENT_SECRET=abc\n' >"$BATS_TEST_TMPDIR/c.env"
  run load_config "$ROOT" "$BATS_TEST_TMPDIR/c.env"
  [ "$status" -eq 2 ]
}

@test "R11: status needs no sign-in of the products: the rollouts of every product call it" {
  run validate_config
  [ "$status" -eq 0 ]
}

@test "R11: a core of the CI of Nabu keeps its web: neither is rolled out" {
  nabu_github
  fake_deploy 'echo "{\"status\":\"success\"}"'
  hm() { [[ $1 == status && $2 == nabu-core ]]; }
  state_data() { echo '{}'; }
  CONFIG_FILE=/dev/null
  kc() { return 0; }
  put_secret() { :; }
  run deploy_products
  [ "$status" -eq 0 ]
  not_called nabu-deploy
}

@test "R11: the first rollout is recorded before it runs, so a failed one is retried by the next install" {
  nabu_github
  hm() { return 1; }
  state_data() { echo '{}'; }
  apply_stdin() { cat >>"$BATS_TEST_TMPDIR/recorded"; }
  fake_deploy 'exit 27'
  CONFIG_FILE=/dev/null
  run deploy_component nabu-deploy nabu nabu-core v0.3.4 0.3.0
  [ "$status" -eq 27 ]
  jq -se '.[0].data == {"nabu-core": "v0.3.4"}' "$BATS_TEST_TMPDIR/recorded"
}

@test "R13: a stopped cluster hides kept secrets: install starts, and the products check them again" {
  nabu_github
  unset NABU_GITHUB_CLIENT_SECRET
  kc() { return 1; }
  validate_products
  [ "${#CONFIG_MISSING[@]}" -eq 0 ]
  kc() { [[ "$*" == *"get secret product-inputs"* ]] && echo '{"data":{}}'; return 0; }
  hm() { return 1; }
  CONFIG_FILE=/dev/null
  run deploy_products
  [ "$status" -eq 2 ]
  [[ $output == *NABU_GITHUB_CLIENT_SECRET* ]]
}

# --- Hammurapi ---

# hammurapi_github — a complete configuration of Nabu and Hammurapi with sign-in through GitHub.
hammurapi_github() {
  nabu_github
  PRODUCTS=nabu,hammurapi HAMMURAPI_GITHUB_APP_ID=123 HAMMURAPI_GITHUB_CLIENT_ID=Iv1.ham HAMMURAPI_SPEC_REPO=acme/specs
  printf -- '-----BEGIN PRIVATE KEY-----\nAAA\nBBB\n-----END PRIVATE KEY-----\n' >"$BATS_TEST_TMPDIR/app.pem"
  export HAMMURAPI_GITHUB_APP_PRIVATE_KEY_FILE=$BATS_TEST_TMPDIR/app.pem HAMMURAPI_GITHUB_CLIENT_SECRET=ham-secret-XYZ
  PUBLIC_DOMAIN=x.example
}

@test "R11: Hammurapi without an external Nabu adds Nabu" {
  hammurapi_github
  PRODUCTS=hammurapi
  validate_products
  [ "$(product_list | paste -sd, -)" = "nabu,hammurapi" ]
  [ "${#CONFIG_MISSING[@]}" -eq 0 ]
}

@test "R11: Hammurapi needs its GitHub App, the repository of specifications and their secrets" {
  nabu_github
  PRODUCTS=nabu,hammurapi
  validate_products
  local m=${CONFIG_MISSING[*]}
  [[ $m == *HAMMURAPI_GITHUB_APP_ID* && $m == *HAMMURAPI_GITHUB_CLIENT_ID* && $m == *HAMMURAPI_SPEC_REPO* ]]
  [[ $m == *HAMMURAPI_GITHUB_APP_PRIVATE_KEY* && $m == *HAMMURAPI_GITHUB_CLIENT_SECRET* ]]
  HAMMURAPI_SPEC_REPO="not a repo"
  run validate_products
  [ "$status" -eq 2 ]
}

@test "R11: an external Nabu needs its address, client and secret, and leaves nabu out of PRODUCTS" {
  hammurapi_github
  PRODUCTS=hammurapi NABU_MODE=external
  validate_products
  local m=${CONFIG_MISSING[*]}
  [[ $m == *NABU_URL* && $m == *NABU_CLIENT_ID* && $m == *NABU_CLIENT_SECRET* ]]
  [[ $m != *NABU_GITHUB_CLIENT_ID* ]]
  [ "$(product_list)" = hammurapi ]
  PRODUCTS=nabu,hammurapi
  run validate_products
  [ "$status" -eq 2 ]
}

@test "PRD-02: an external Nabu that issues no token to the client: code 14 before anything is installed" {
  hammurapi_github
  PRODUCTS=hammurapi NABU_MODE=external NABU_URL=https://nabu-api.other.example NABU_CLIENT_ID=ham
  export NABU_CLIENT_SECRET='s3cret&XYZ'
  stub curl 'cat >"$BATS_TEST_TMPDIR/body"; exit 22'
  run products_preflight
  [ "$status" -eq 14 ]
  # The secret goes in the body, encoded, not in the arguments.
  not_called "s3cret"
  grep -q 'client_id=ham&client_secret=s3cret%26XYZ' "$BATS_TEST_TMPDIR/body"
  stub curl 'cat >/dev/null; echo "{\"access_token\":\"t\"}"'
  run products_preflight
  [ "$status" -eq 0 ]
}

@test "R11: an internal Hammurapi next to a Nabu of its own CI stops before anything changes" {
  hammurapi_github
  hm() { [[ $1 == status && $2 == nabu-core ]]; }
  state_data() { echo '{}'; }
  run products_preflight
  [ "$status" -eq 2 ]
  [[ $output == *NABU_MODE=external* ]]
  state_data() { echo '{"nabu-core":"v0.3.5"}'; }
  run products_preflight
  [ "$status" -eq 0 ]
}

@test "R13: the private key of the GitHub App keeps its lines as \\n, the form of bin/hammurapi-deploy" {
  hammurapi_github
  [ "$(input_value HAMMURAPI_GITHUB_APP_PRIVATE_KEY)" = '-----BEGIN PRIVATE KEY-----\nAAA\nBBB\n-----END PRIVATE KEY-----' ]
}

@test "FTR.NAB.CMN-0001 R17a: Nabu creates the client of Hammurapi from the hash of the secret Hammurapi gets" {
  hammurapi_github
  secret_key() { return 1; }
  # A NABU_CLIENT_SECRET of the environment belongs to an external Nabu, never to this one.
  export NABU_CLIENT_SECRET=left-over
  ensure_nabu_client
  local generated=${GENERATED_INPUTS[NABU_BOOTSTRAP_CLIENT_SECRET]}
  [[ $generated == nabu_* ]]
  local nabu ham
  nabu=$(nabu_payload nabu-core)
  ham=$(hammurapi_payload hammurapi-core)
  jq -e --arg h "$(printf '%s' "$generated" | sha256sum | awk '{print $1}')" \
    '.secrets.BOOTSTRAP_CLIENTS | fromjson | .[0] | .name == "hammurapi" and .secretSha256 == $h and .url == "https://hammurapi.x.example"' <<<"$nabu"
  jq -e --arg s "$generated" '.secrets.NABU_CLIENT_SECRET == $s and .config.NABU_CLIENT_ID == "hammurapi"
    and .config.NABU_URL == "https://nabu-api.x.example" and .config.NABU_WEB_URL == "https://nabu.x.example"
    and .config.GIT_REPO == "acme/specs" and .config.GITHUB_APP_ID == "123" and .config.GITHUB_CLIENT_ID == "Iv1.ham"
    and .secrets.GITHUB_CLIENT_SECRET == "ham-secret-XYZ" and (.secrets.GITHUB_APP_PRIVATE_KEY | contains("\\nAAA\\n"))
    and (.secrets.WEBHOOK_SECRET | test("^[0-9a-f]{64}$")) and (.secrets.TOKEN_ENCRYPTION_KEY | test("^[0-9a-f]{64}$"))' <<<"$ham"
}

@test "R13: a kept client secret and the keys of an installed Hammurapi do not change" {
  hammurapi_github
  kc() { [[ "$*" == *"get secret product-inputs"* ]] && echo "{\"data\":{\"NABU_BOOTSTRAP_CLIENT_SECRET\":\"$(printf kept | base64 -w0)\"}}"; return 0; }
  secret_key() { [[ $1 == hammurapi ]] && printf 'kept-%s' "$3"; }
  ensure_nabu_client
  [ -z "${GENERATED_INPUTS[NABU_BOOTSTRAP_CLIENT_SECRET]:-}" ]
  hammurapi_payload hammurapi-core | jq -e '.secrets.NABU_CLIENT_SECRET == "kept" and .secrets.WEBHOOK_SECRET == "kept-WEBHOOK_SECRET"
    and .secrets.TOKEN_ENCRYPTION_KEY == "kept-TOKEN_ENCRYPTION_KEY"'
}

@test "R11: an external Nabu: no bootstrap client, Hammurapi gets the given client" {
  hammurapi_github
  PRODUCTS=hammurapi NABU_MODE=external NABU_URL=https://nabu-api.other.example/ NABU_CLIENT_ID=ham
  export NABU_CLIENT_SECRET=given-secret
  ensure_nabu_client
  [ "${#GENERATED_INPUTS[@]}" -eq 0 ]
  hammurapi_payload hammurapi-core | jq -e '.config.NABU_URL == "https://nabu-api.other.example" and .config.NABU_CLIENT_ID == "ham"
    and (.config | has("NABU_WEB_URL") | not) and .secrets.NABU_CLIENT_SECRET == "given-secret"'
}

@test "FTR.HMR.DEV-0003 R23: SPEC_LANGUAGE reaches Hammurapi when it is set" {
  hammurapi_github
  PRODUCTS=hammurapi NABU_MODE=external NABU_URL=https://nabu-api.other.example NABU_CLIENT_ID=ham
  export NABU_CLIENT_SECRET=given-secret
  SPEC_LANGUAGE=ru hammurapi_payload hammurapi-core | jq -e '.config.SPEC_LANGUAGE == "ru"'
  SPEC_LANGUAGE= hammurapi_payload hammurapi-core | jq -e '.config | has("SPEC_LANGUAGE") | not'
}

@test "R11: Nabu, then Hammurapi, each core before its web" {
  hammurapi_github
  hm() { return 1; }
  state_data() { echo '{}'; }
  apply_stdin() { cat >/dev/null; }
  kc() { [[ "$*" == *"get secret product-inputs"* ]] && echo '{"data":{}}'; return 0; }
  secret_key() { return 1; }
  fake_deploy 'echo "{\"status\":\"success\"}"'
  printf '#!/usr/bin/env bash\necho "hammurapi-deploy $*" >>"$CALLS"\ncat >/dev/null\necho "{\\"status\\":\\"success\\"}"\n' >"$PRODUCT_BIN/hammurapi-deploy"
  CONFIG_FILE=/dev/null
  run deploy_products
  [ "$status" -eq 0 ]
  [ "$(grep -o 'deploy [a-z-]* v[0-9.]*' "$CALLS" | tr '\n' ' ')" = \
    "deploy nabu-core $NABU_CORE_VERSION deploy nabu-web $NABU_WEB_VERSION deploy hammurapi-core $HAMMURAPI_CORE_VERSION deploy hammurapi-web $HAMMURAPI_WEB_VERSION " ]
}

@test "R11: switching to an external Nabu needs its secret: the generated one of the internal Nabu does not count" {
  hammurapi_github
  PRODUCTS=hammurapi NABU_MODE=external NABU_URL=https://nabu-api.other.example NABU_CLIENT_ID=ham
  kc() { [[ "$*" == *"get secret product-inputs"* ]] && echo "{\"data\":{\"NABU_BOOTSTRAP_CLIENT_SECRET\":\"$(printf kept | base64 -w0)\"}}"; return 0; }
  validate_products
  [[ ${CONFIG_MISSING[*]} == *NABU_CLIENT_SECRET* ]]
}

@test "FTR.NAB.CMN-0001 R17a: api of Nabu restarts when its service clients changed, and only then" {
  hammurapi_github
  secret_key() { [[ $3 == BOOTSTRAP_CLIENTS ]] && printf new; }
  RESULT_UPDATED=(nabu-core)
  restart_nabu_api old
  called "rollout restart deployment/api"
  : >"$CALLS"
  secret_key() { printf same; }
  restart_nabu_api same
  not_called "rollout restart"
}

@test "R11: Hammurapi next to a Nabu of its own CI: code 2 that asks for an external client" {
  hammurapi_github
  hm() { [[ $1 == status && $2 == nabu-core ]]; }
  state_data() { echo '{}'; }
  kc() { [[ "$*" == *"get secret product-inputs"* ]] && echo '{"data":{}}'; return 0; }
  put_secret() { :; }
  fake_deploy 'echo "{\"status\":\"success\"}"'
  CONFIG_FILE=/dev/null
  run deploy_products
  [ "$status" -eq 2 ]
  [[ $output == *NABU_MODE=external* ]]
  not_called "deploy hammurapi"
}
