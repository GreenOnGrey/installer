#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.HMR.INFRA-0002: bin/hammurapi-deploy: order, exit codes, secrets only on stdin.

load helpers

DEPLOY="$BATS_TEST_DIRNAME/../../bin/hammurapi-deploy"

setup() {
  setup_stubs
  export DEPLOY_LOCK_DIR=$BATS_TEST_TMPDIR/lock INSTALLER_CONFIG=/dev/null
  export DEPLOY_LOGS=$BATS_TEST_TMPDIR/logs APPLIED=$BATS_TEST_TMPDIR/applied
  mkdir -p "$DEPLOY_LOCK_DIR" "$DEPLOY_LOGS" "$APPLIED"
  # An empty TMPDIR: no files with secrets may stay in it after a rollout.
  export TMPDIR=$BATS_TEST_TMPDIR/tmp
  mkdir -p "$TMPDIR"
  stub flock 'exit 0'
  # status of the stand: STAND_OK, PUBLIC come from the test's environment.
  export STAND_OK=true PUBLIC=true
  cat >"$STUBS/status.sh" <<'EOF'
jq -cn --argjson ok "$STAND_OK" --argjson pub "$PUBLIC" \
  '{ok: $ok, checks: [{name: "logs", ok: $ok, message: "logs do not reach VictoriaLogs"}],
    public: ({enabled: $pub} + (if $pub then {baseDomain: "34-12-5-6.sslip.io"} else {} end))}'
EOF
  export STATUS_CMD=$STUBS/status.sh
  # helm: CORE_INSTALLED says whether the release hammurapi-core exists.
  export CORE_INSTALLED=false
  stub helm '
case "$*" in
  *"status hammurapi-core -n hammurapi -o json"*) echo "{\"version\":3}" ;;
  *"status hammurapi-core"*) [[ $CORE_INSTALLED == true ]] ;;
  *"status hammurapi-web -n hammurapi -o json"*) echo "{\"version\":2}" ;;
  *"status hammurapi-web"*) exit 1 ;;
  *"registry login"*) cat >/dev/null ;;
  *) exit 0 ;;
esac'
  # kubectl: manifests from stdin are kept for checks; FINGERPRINT is the stored key hash.
  export FINGERPRINT=""
  stub kubectl '
case "$*" in
  *"apply -f -"*) cat >>"$APPLIED/manifests" ; echo >>"$APPLIED/manifests" ;;
  *"--dry-run=client -o yaml"*) echo "kind: Dummy" ;;
  *"get configmap hammurapi-key-fingerprint"*) printf "%s" "$FINGERPRINT" ;;
  *"get configmap hammurapi-deploy-state"*) exit 1 ;;
  *"get secret postgres-conn -o json"*|*"get secret kafka-conn -o json"*) echo "{\"metadata\":{\"name\":\"x\"},\"data\":{\"uri\":\"cA==\"}}" ;;
  *"get secret s3-conn -o json"*) echo "{\"metadata\":{\"name\":\"s3-conn\"},\"data\":{\"endpoint\":\"$(printf http://s3.storages.svc:9000 | base64)\"}}" ;;
  *) exit 0 ;;
esac'
  # GitHub API.
  stub curl '
url=${*: -1}
case "$url" in
  */app) echo "{\"slug\":\"hammurapi-demo\"}" ;;
  */app/hook/config) cat >/dev/null; echo "{}" ;;
  */repos/*/installation) [[ ${APP_INSTALLED:-true} == true ]] && echo "{\"id\":42}" || exit 22 ;;
  */app/installations/42) echo "{\"permissions\":{\"contents\":\"write\",\"pull_requests\":\"write\"},\"events\":[\"push\",\"pull_request\"]}" ;;
esac'
  openssl genrsa -out "$BATS_TEST_TMPDIR/app.pem" 2048 2>/dev/null
  PAYLOAD=$(jq -cn --rawfile key "$BATS_TEST_TMPDIR/app.pem" '{
    image: "ghcr.io/greenongrey/hammurapi-core",
    config: {GIT_REPO: "GreenOnGrey/hammurapi-spec", GITHUB_APP_ID: "123", GITHUB_CLIENT_ID: "Iv1.abc",
      BOOTSTRAP_ADMINS: "owner"},
    secrets: {GITHUB_APP_PRIVATE_KEY: $key, GITHUB_CLIENT_SECRET: "client-secret-XYZ",
      WEBHOOK_SECRET: "webhook-secret-XYZ", TOKEN_ENCRYPTION_KEY: "token-key-XYZ",
      BOOTSTRAP_DEEPSEEK_API_KEY: "sk-deepseek-SECRET"},
    ghcrPullToken: "ghp_pulltokenXYZ"}')
  export PAYLOAD
}

deploy() { printf '%s' "$PAYLOAD" | bash "$DEPLOY" "$@"; }

# The core path signs a JWT with the key through /dev/fd (process substitution): the native
# openssl in Git Bash on Windows cannot read it. The target is Debian and CI on Linux.
need_linux() { [[ $(uname -s) == Linux ]] || skip "JWT signing through /dev/fd is Linux only"; }
last_json() { printf '%s\n' "$output" | tail -n 1; }

@test "INS-03: the stand is not ready: code 20 before any change" {
  STAND_OK=false
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 20 ]
  last_json | jq -e '.status == "failure" and .code == 20 and (.error | contains("logs do not reach"))'
  not_called "apply -f -"
  not_called "helm --kube-context hammurapi upgrade"
}

@test "INS-03: public access is off: code 20" {
  PUBLIC=false
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 20 ]
  [[ $output == *"public access of the stand is off"* ]]
}

@test "INS-02: web before core: code 21, roll out hammurapi-core first, the server is unchanged" {
  run deploy hammurapi-web v2.3.0 0.4.0
  [ "$status" -eq 21 ]
  [[ $output == *"roll out hammurapi-core first"* ]]
  not_called "create namespace"
  not_called "apply -f -"
}

@test "INS-01, CH-02: first install of core: the chart of the right version, secrets, GitHub App setup" {
  need_linux
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 0 ]
  last_json | jq -e '.status == "success" and .firstInstall == true and .publicBaseDomain == "34-12-5-6.sslip.io" and .revision == "3"'
  # Hammurapi subdomains next to Nabu: hammurapi. and hammurapi-api.
  last_json | jq -e '.webUrl == "https://hammurapi.34-12-5-6.sslip.io" and .apiUrl == "https://hammurapi-api.34-12-5-6.sslip.io"'
  called "hosts.api=hammurapi-api"
  called "upgrade --install hammurapi-core oci://ghcr.io/greenongrey/charts/hammurapi-core --version 0.4.0"
  called "image.tag=v1.8.0"
  called "publicBaseDomain=34-12-5-6.sslip.io"
  called "--atomic"
  called "/app/hook/config"
  grep -q '"name":"hammurapi-secrets"' "$APPLIED/manifests"
  grep -q '"name":"hammurapi-config"' "$APPLIED/manifests"
  grep -q '"HAMMURAPI_BOT_LOGIN":"hammurapi-demo\[bot\]"' "$APPLIED/manifests"
  grep -q '"name":"ghcr-pull","namespace":"hammurapi"' "$APPLIED/manifests"
  called "create namespace hammurapi "
  not_called "hammurapi-runner"
  not_grep -q "hammurapi-runner" "$APPLIED/manifests"
}

@test "INS-12, R14: secrets reach neither command arguments nor temporary files" {
  need_linux
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 0 ]
  local s
  for s in client-secret-XYZ webhook-secret-XYZ token-key-XYZ sk-deepseek-SECRET ghp_pulltokenXYZ "BEGIN PRIVATE KEY"; do
    not_called "$s"
    [[ $output != *"$s"* ]] || { echo "in the log: $s"; return 1; }
  done
  [ -z "$(find "$TMPDIR" -type f)" ]
}

@test "S3: the copy of s3-conn for core gets endpoint_host without a scheme and use_ssl" {
  need_linux
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 0 ]
  local s3
  s3=$(grep '"name":"s3-conn"' "$APPLIED/manifests" | head -1)
  [ "$(jq -r '.data.endpoint_host | @base64d' <<<"$s3")" = "s3.storages.svc:9000" ]
  [ "$(jq -r '.data.use_ssl | @base64d' <<<"$s3")" = "false" ]
  [ "$(jq -r '.metadata.namespace' <<<"$s3")" = "hammurapi" ]
}

@test "FTR.HMR.CMN-0007 HN-08: no agent operator token, the LLM key of the first run is in hammurapi-secrets" {
  need_linux
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 0 ]
  local sec
  sec=$(grep '"name":"hammurapi-secrets"' "$APPLIED/manifests" | head -1)
  jq -e '(.stringData | has("AGENT_SERVICE_TOKEN") | not) and .stringData.BOOTSTRAP_DEEPSEEK_API_KEY == "sk-deepseek-SECRET"
    and (.stringData | has("ACP_AGENT_ENV") | not)' <<<"$sec"
}

@test "INS-06: the encryption key changed: code 24, the release did not update" {
  FINGERPRINT=0000000000000000000000000000000000000000000000000000000000000000
  CORE_INSTALLED=true
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 24 ]
  [[ $output == *"encryption key changed"* ]]
  not_called "upgrade --install"
}

@test "INS-06: the rollout passes with --allow-key-rotation" {
  need_linux
  FINGERPRINT=0000000000000000000000000000000000000000000000000000000000000000
  CORE_INSTALLED=true
  run deploy hammurapi-core v1.8.0 0.4.0 --allow-key-rotation
  [ "$status" -eq 0 ]
  called "upgrade --install hammurapi-core"
}

@test "INS-08: the GitHub App is not installed on the specifications repository: code 26 and a link" {
  need_linux
  export APP_INSTALLED=false
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 26 ]
  [[ $output == *"https://github.com/apps/hammurapi-demo/installations/new"* ]]
}

@test "R6: a web rollout leaves core alone and needs no core configuration" {
  CORE_INSTALLED=true
  PAYLOAD='{"image":"ghcr.io/greenongrey/hammurapi-web","ghcrPullToken":"ghp_x"}'
  run deploy hammurapi-web v2.3.0 0.4.0
  [ "$status" -eq 0 ]
  called "upgrade --install hammurapi-web oci://ghcr.io/greenongrey/charts/hammurapi-web --version 0.4.0"
  not_called "upgrade --install hammurapi-core"
  not_called "/app/hook/config"
  not_called "hammurapi-runner"
}

@test "a wrong tag or component: code 2" {
  run deploy hammurapi-core 1.8 0.4.0
  [ "$status" -eq 2 ]
  run deploy hammurapi-api v1.8.0 0.4.0
  [ "$status" -eq 2 ]
}

@test "R10: a rollout of the component is running: code 17" {
  command -v flock >/dev/null || skip "no flock"
  rm -f "$STUBS/flock"
  hash -r
  (flock "$DEPLOY_LOCK_DIR/hammurapi-deploy-hammurapi-core.lock" sleep 5) &
  sleep 0.5
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 17 ]
  kill %1 2>/dev/null || true
}

@test "FTR.INFRA.INST-0001 R17: OBSERVABILITY=false: nothing is installed, installed releases are removed" {
  load_script
  OBSERVABILITY=false
  stub helm '[[ $* == *"status grafana"* ]] && exit 0; [[ $* == *"status"* ]] && exit 1; exit 0'
  run deploy_observability
  [ "$status" -eq 0 ]
  called "uninstall grafana -n observability"
  not_called "uninstall vector"
  not_called "upgrade --install"
}

@test "FTR.INFRA.INST-0001 R17: OBSERVABILITY=false: no namespace of its own and no Grafana password" {
  load_script
  OBSERVABILITY=false
  [ "$(stand_namespaces)" = storages ]
  [[ $(public_hosts) != *grafana* ]]
  stub kubectl 'exit 0'
  POSTGRES_MODE=external S3_MODE=external run ensure_credentials
  [ "$status" -eq 0 ]
  not_called grafana-admin
}

@test "FTR.INFRA.INST-0001 R17: OBSERVABILITY=false: run_checks starts no probe of Grafana, metrics or logs" {
  load_script
  OBSERVABILITY=false
  start_probe_pods() { echo called >"$BATS_TEST_TMPDIR/probe"; }
  check_pods() { record pods ok x; }
  check_storages() { record storages ok x; }
  check_mcp() { :; }
  check_resources() { record resources ok x; }
  check_public() { :; }
  cleanup_probes() { :; }
  run_checks
  [ ! -e "$BATS_TEST_TMPDIR/probe" ]
  [[ ${CHECK_RESULTS[*]} != *grafana* && ${CHECK_RESULTS[*]} != *metrics* && ${CHECK_RESULTS[*]} != *logs* ]]
}

@test "FTR.INFRA.INST-0001 R17: the observability default keeps Grafana among the hosts and namespaces" {
  load_script
  [[ $(public_hosts) == *" grafana"* ]]
  [ "$(stand_namespaces | wc -l)" -eq 2 ]
}

@test "FTR.INFRA.INST-0001 R17: all storages external and observability off: an empty namespace passes" {
  load_script
  OBSERVABILITY=false
  stub kubectl 'echo "error: no matching resources found" >&2; exit 1'
  check_pods
  [[ ${CHECK_RESULTS[*]} == "pods|ok|all pods in storages are ready" ]]
}

@test "FTR.INFRA.INST-0001 R17: removing observability deletes the secrets of Grafana" {
  load_script
  OBSERVABILITY=false
  stub helm 'exit 1'
  run deploy_observability
  [ "$status" -eq 0 ]
  called "delete secret grafana-admin grafana-github-oauth --ignore-not-found"
}
