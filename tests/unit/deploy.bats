#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# HMR.INFRA-0002: bin/hammurapi-deploy — порядок, коды выхода, секреты только в stdin.

load helpers

DEPLOY="$BATS_TEST_DIRNAME/../../bin/hammurapi-deploy"

setup() {
  setup_stubs
  export DEPLOY_LOCK_DIR=$BATS_TEST_TMPDIR/lock HAMMURAPI_INFRA_CONFIG=/dev/null
  export DEPLOY_LOGS=$BATS_TEST_TMPDIR/logs APPLIED=$BATS_TEST_TMPDIR/applied
  mkdir -p "$DEPLOY_LOCK_DIR" "$DEPLOY_LOGS" "$APPLIED"
  # Пустой TMPDIR: после выкатки в нём не должно остаться файлов с секретами.
  export TMPDIR=$BATS_TEST_TMPDIR/tmp
  mkdir -p "$TMPDIR"
  stub flock 'exit 0'
  # status стенда: STAND_OK, PUBLIC — из окружения теста.
  export STAND_OK=true PUBLIC=true
  cat >"$STUBS/status.sh" <<'EOF'
jq -cn --argjson ok "$STAND_OK" --argjson pub "$PUBLIC" \
  '{ok: $ok, checks: [{name: "logs", ok: $ok, message: "логи не поступают в VictoriaLogs"}],
    public: ({enabled: $pub} + (if $pub then {baseDomain: "34-12-5-6.sslip.io"} else {} end))}'
EOF
  export STATUS_CMD=$STUBS/status.sh
  # helm: CORE_INSTALLED — есть ли релиз hammurapi-core.
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
  # kubectl: манифесты из stdin сохраняются для проверок; FINGERPRINT — сохранённый хеш ключа.
  export FINGERPRINT="" AGENT_TOKEN=""
  stub kubectl '
case "$*" in
  *"apply -f -"*) cat >>"$APPLIED/manifests" ; echo >>"$APPLIED/manifests" ;;
  *"--dry-run=client -o yaml"*) echo "kind: Dummy" ;;
  *"get configmap hammurapi-key-fingerprint"*) printf "%s" "$FINGERPRINT" ;;
  *"get configmap hammurapi-deploy-state"*) exit 1 ;;
  *"get secret hammurapi-secrets"*) [[ -n $AGENT_TOKEN ]] && printf "%s" "$AGENT_TOKEN" | base64 ;;
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

# Путь core подписывает JWT ключом через /dev/fd (process substitution): нативный
# openssl в Git Bash на Windows его не читает. Цель — Debian стенда и CI на Linux.
need_linux() { [[ $(uname -s) == Linux ]] || skip "подпись JWT через /dev/fd — только Linux"; }
last_json() { printf '%s\n' "$output" | tail -n 1; }

@test "INS-03: стенд не готов — код 20 до изменений" {
  STAND_OK=false
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 20 ]
  last_json | jq -e '.status == "failure" and .code == 20 and (.error | contains("логи не поступают"))'
  not_called "apply -f -"
  not_called "helm --kube-context hammurapi upgrade"
}

@test "INS-03: публичный доступ выключен — код 20" {
  PUBLIC=false
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 20 ]
  [[ $output == *"публичный доступ стенда выключен"* ]]
}

@test "INS-02: web до core — код 21, «сначала выкатите hammurapi-core», сервер не изменён" {
  run deploy hammurapi-web v2.3.0 0.4.0
  [ "$status" -eq 21 ]
  [[ $output == *"сначала выкатите hammurapi-core"* ]]
  not_called "create namespace"
  not_called "apply -f -"
}

@test "INS-01, CH-02: первая установка core — чарт нужной версии, секреты, настройка GitHub App" {
  need_linux
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 0 ]
  last_json | jq -e '.status == "success" and .firstInstall == true and .publicBaseDomain == "34-12-5-6.sslip.io" and .revision == "3"'
  called "upgrade --install hammurapi-core oci://ghcr.io/greenongrey/charts/hammurapi-core --version 0.4.0"
  called "image.tag=v1.8.0"
  called "publicBaseDomain=34-12-5-6.sslip.io"
  called "--atomic"
  called "/app/hook/config"
  grep -q '"name":"hammurapi-secrets"' "$APPLIED/manifests"
  grep -q '"name":"hammurapi-config"' "$APPLIED/manifests"
  grep -q '"HAMMURAPI_BOT_LOGIN":"hammurapi-demo\[bot\]"' "$APPLIED/manifests"
  grep -q '"name":"ghcr-pull"' "$APPLIED/manifests"
  called "delete secret hammurapi-runner-agent"
}

@test "INS-12, R14: секреты не попадают в аргументы команд и во временные файлы" {
  need_linux
  AGENT_TOKEN=agent-token-KEEP
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 0 ]
  local s
  for s in client-secret-XYZ webhook-secret-XYZ token-key-XYZ sk-deepseek-SECRET agent-token-KEEP ghp_pulltokenXYZ "BEGIN PRIVATE KEY"; do
    not_called "$s"
    [[ $output != *"$s"* ]] || { echo "в журнале: $s"; return 1; }
  done
  [ -z "$(find "$TMPDIR" -type f)" ]
}

@test "S3: копия s3-conn для core получает endpoint_host без схемы и use_ssl" {
  need_linux
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 0 ]
  local s3
  s3=$(grep '"name":"s3-conn"' "$APPLIED/manifests" | head -1)
  [ "$(jq -r '.data.endpoint_host | @base64d' <<<"$s3")" = "s3.storages.svc:9000" ]
  [ "$(jq -r '.data.use_ssl | @base64d' <<<"$s3")" = "false" ]
  [ "$(jq -r '.metadata.namespace' <<<"$s3")" = "hammurapi" ]
}

@test "HMR.CMN-0004: токен оператора агента создаётся один раз, ключ LLM первого запуска — в hammurapi-secrets" {
  need_linux
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 0 ]
  local sec
  sec=$(grep '"name":"hammurapi-secrets"' "$APPLIED/manifests" | head -1)
  jq -e '(.stringData.AGENT_SERVICE_TOKEN | test("^[0-9a-f]{64}$")) and .stringData.BOOTSTRAP_DEEPSEEK_API_KEY == "sk-deepseek-SECRET"
    and (.stringData | has("ACP_AGENT_ENV") | not)' <<<"$sec"
  # Повторная выкатка сохраняет токен.
  : >"$APPLIED/manifests"
  AGENT_TOKEN=agent-token-KEEP
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 0 ]
  sec=$(grep '"name":"hammurapi-secrets"' "$APPLIED/manifests" | head -1)
  [ "$(jq -r '.stringData.AGENT_SERVICE_TOKEN' <<<"$sec")" = "agent-token-KEEP" ]
}

@test "INS-06: изменён ключ шифрования — код 24, релиз не обновлялся" {
  FINGERPRINT=0000000000000000000000000000000000000000000000000000000000000000
  CORE_INSTALLED=true
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 24 ]
  [[ $output == *"ключ шифрования изменён"* ]]
  not_called "upgrade --install"
}

@test "INS-06: с --allow-key-rotation выкатка проходит" {
  need_linux
  FINGERPRINT=0000000000000000000000000000000000000000000000000000000000000000
  CORE_INSTALLED=true
  run deploy hammurapi-core v1.8.0 0.4.0 --allow-key-rotation
  [ "$status" -eq 0 ]
  called "upgrade --install hammurapi-core"
}

@test "INS-08: GitHub App не установлен на репозиторий спецификаций — код 26 и ссылка" {
  need_linux
  export APP_INSTALLED=false
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 26 ]
  [[ $output == *"https://github.com/apps/hammurapi-demo/installations/new"* ]]
}

@test "R6: выкатка web не трогает core и не требует конфигурации core" {
  CORE_INSTALLED=true
  PAYLOAD='{"image":"ghcr.io/greenongrey/hammurapi-web","ghcrPullToken":"ghp_x"}'
  run deploy hammurapi-web v2.3.0 0.4.0
  [ "$status" -eq 0 ]
  called "upgrade --install hammurapi-web oci://ghcr.io/greenongrey/charts/hammurapi-web --version 0.4.0"
  not_called "upgrade --install hammurapi-core"
  not_called "/app/hook/config"
}

@test "неверный тег или компонент — код 2" {
  run deploy hammurapi-core 1.8 0.4.0
  [ "$status" -eq 2 ]
  run deploy hammurapi-api v1.8.0 0.4.0
  [ "$status" -eq 2 ]
}

@test "R10: выкатка компонента уже идёт — код 17" {
  command -v flock >/dev/null || skip "нет flock"
  rm -f "$STUBS/flock"
  hash -r
  (flock "$DEPLOY_LOCK_DIR/hammurapi-deploy-hammurapi-core.lock" sleep 5) &
  sleep 0.5
  run deploy hammurapi-core v1.8.0 0.4.0
  [ "$status" -eq 17 ]
  kill %1 2>/dev/null || true
}
