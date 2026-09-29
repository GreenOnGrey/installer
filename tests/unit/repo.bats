#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# OBS-06, PORT-01, DPL-02, DPL-05, DPL-09, RES: дашборды, переносимость, выкатка.

load helpers

@test "OBS-06: дашборды ссылаются только на victoriametrics/victorialogs, без __inputs" {
  local f bad
  for f in "$ROOT"/dashboards/*.json; do
    jq -e 'has("__inputs") | not' "$f" >/dev/null || { echo "$f: __inputs"; return 1; }
    jq -e 'has("id") | not' "$f" >/dev/null || { echo "$f: id"; return 1; }
    bad=$(jq -r '[.. | objects | select(has("datasource")) | .datasource | select(. != null)
      | if type == "object" then (.uid // "") else . end]
      | map(select(. as $u | ["victoriametrics", "victorialogs", "__expr__", "grafana", "-- Grafana --", "-- Mixed --", "-- Dashboard --"] | index($u) | not))
      | unique | join(",")' "$f")
    [ -z "$bad" ] || { echo "$f: $bad"; return 1; }
    jq -e '.uid | startswith("hammurapi-")' "$f" >/dev/null || { echo "$f: uid"; return 1; }
  done
}

@test "R7: шесть дашбордов" {
  [ "$(find "$ROOT/dashboards" -name '*.json' | wc -l)" -eq 6 ]
}

@test "PORT-01: вызовов API облака нет вне docs/, tests/e2e и .github" {
  run grep -rnE 'gcloud|metadata\.google|169\.254\.169\.254|googleapis\.com/compute' "$ROOT" \
    --include='*.sh' --include='*.yaml' --include='*.env' --include='*.tpl' \
    --exclude-dir=docs --exclude-dir=e2e --exclude-dir=.github --exclude-dir=.git --exclude-dir=.work --exclude-dir=logs \
    --exclude=local.env.example
  [ "$status" -eq 1 ]
}

@test "DPL-02: тег не в формате vX.Y.Z — ошибка" {
  run bash "$ROOT/.github/scripts/resolve-tag.sh" v1.4
  [ "$status" -eq 1 ]
  run bash "$ROOT/.github/scripts/resolve-tag.sh" "v1.4.0; rm -rf /"
  [ "$status" -eq 1 ]
  run bash "$ROOT/.github/scripts/resolve-tag.sh" v1.4.0
  [ "$status" -eq 0 ]
  [ "$output" = v1.4.0 ]
}

@test "DPL-02: workflow срабатывает только на теги v*.*.*" {
  grep -q 'tags: \["v\*\.\*\.\*"\]' "$ROOT/.github/workflows/deploy-prod.yml"
  grep -q 'concurrency: { group: deploy-prod, cancel-in-progress: false }' "$ROOT/.github/workflows/deploy-prod.yml"
}

@test "DPL-09: проверка ключа хоста не отключается" {
  export SSH_DIR=$BATS_TEST_TMPDIR/ssh PROD_HOST=203.0.113.10 PROD_USER=deploy PROD_SSH_KEY=key
  PROD_KNOWN_HOSTS="203.0.113.10 ssh-ed25519 AAAA" run bash "$ROOT/.github/scripts/ssh-setup.sh"
  [ "$status" -eq 0 ]
  grep -q 'StrictHostKeyChecking yes' "$SSH_DIR/config"
  not_grep -qi 'StrictHostKeyChecking no' "$SSH_DIR/config"
  grep -q "UserKnownHostsFile $SSH_DIR/deploy_known_hosts" "$SSH_DIR/config"
  not_grep -rqi 'StrictHostKeyChecking=no' "$ROOT/.github"
}

@test "DPL-09: без отпечатка хоста подключение запрещено" {
  export SSH_DIR=$BATS_TEST_TMPDIR/ssh PROD_HOST=h PROD_USER=u PROD_SSH_KEY=key PROD_KNOWN_HOSTS=""
  run bash "$ROOT/.github/scripts/ssh-setup.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"PROD_KNOWN_HOSTS"* ]]
}

@test "DPL-05: up на машине уже выполняется — код 17" {
  command -v flock >/dev/null || skip "нет flock"
  setup_stubs
  load_script
  LOCK_FILE=$BATS_TEST_TMPDIR/lock
  : >"$LOCK_FILE"
  flock "$LOCK_FILE" sleep 5 &
  sleep 0.5
  run acquire_lock
  [ "$status" -eq 17 ]
  [[ $output == *"уже выполняется"* ]]
  kill %1 2>/dev/null || true
}

@test "RES: to_bytes понимает единицы Kubernetes" {
  source "$ROOT/lib/common.sh"
  [ "$(to_bytes 512Mi)" -eq 536870912 ]
  [ "$(to_bytes 1Gi)" -eq 1073741824 ]
  [ "$(to_bytes 16384Ki)" -eq 16777216 ]
  [ "$(to_bytes 1G)" -eq 1000000000 ]
  [ "$(to_bytes 1024)" -eq 1024 ]
}
