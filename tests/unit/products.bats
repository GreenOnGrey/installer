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

@test "R11: an unknown product, and Hammurapi before its release: code 2" {
  PRODUCTS=nabu,site
  run validate_products
  [ "$status" -eq 2 ]
  PRODUCTS=hammurapi
  run validate_products
  [ "$status" -eq 2 ]
  [[ $output == *"later release"* ]]
}

@test "PRD-04 (U): SECRETS_KEY of an installed Nabu goes into the payload, a new one only at the first install" {
  nabu_github
  secret_key() { [[ "$*" == "nabu nabu-secrets SECRETS_KEY" ]] && printf 'kept-key'; }
  run nabu_payload nabu-core
  echo "$output" | jq -e '.secrets.SECRETS_KEY == "kept-key" and .secrets.GITHUB_CLIENT_SECRET == "gh-secret-XYZ"
    and .config.AUTH_PROVIDER == "github" and .config.GITHUB_CLIENT_ID == "Iv1.abc" and .config.PI_VERSION == "1.5.0"
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
  called "nabu-deploy nabu-core v0.3.4 0.3.0"
  jq -e '.data == {"nabu-core": "v0.3.4"}' "$BATS_TEST_TMPDIR/recorded"
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

@test "R13: secrets of the products in the config file: code 2" {
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
