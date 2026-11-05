#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 tech §9: состояние в namespace installer, конфигурация в кластере.

load helpers

setup() {
  setup_stubs
  load_script
  CM_DIR=$BATS_TEST_TMPDIR/cm
  mkdir -p "$CM_DIR"
  export CM_DIR
  # kubectl: ConfigMap'ы — файлы <ns>_<имя>.json; apply сохраняет манифест из stdin.
  stub kubectl '
args="$*"
case "$args" in
  *"get configmap "*) ns=$(sed "s/.* -n \([^ ]*\) .*/\1/" <<<"$args"); n=$(sed "s/.*get configmap \([^ ]*\).*/\1/" <<<"$args")
    [[ -f $CM_DIR/${ns}_$n.json ]] && cat "$CM_DIR/${ns}_$n.json" || exit 1 ;;
  *"apply -f -"*) m=$(cat); ns=$(jq -r .metadata.namespace <<<"$m"); n=$(jq -r .metadata.name <<<"$m"); echo "$m" >"$CM_DIR/${ns}_$n.json" ;;
  *) exit 0 ;;
esac'
}

# put_cm <ns> <имя> <data JSON>
put_cm() { jq -n --argjson d "$3" '{data: $d}' >"$CM_DIR/$1_$2.json"; }

@test "STATE-01: состояние читается из namespace installer" {
  put_cm installer installer-version '{"tag":"v2"}'
  put_cm observability hammurapi-infra-version '{"tag":"v1"}'
  run state_version
  jq -e '.tag == "v2"' <<<"$output"
}

@test "STATE-02: до первого up новой версии читается прежнее место" {
  put_cm observability hammurapi-infra-version '{"tag":"v1"}'
  put_cm ingress hammurapi-infra-public '{"baseDomain":"x.example"}'
  run state_version
  jq -e '.tag == "v1"' <<<"$output"
  run state_public
  jq -e '.baseDomain == "x.example"' <<<"$output"
}

@test "STATE-03: состояния нет — версия null, публичный доступ выключен" {
  run deployed_version
  [ "$output" = null ]
  run public_status_json
  [ "$output" = '{"enabled":false}' ]
}

@test "CFG-01: в кластер пишутся только значения, отличные от умолчаний" {
  MCP_DOCGEN=true MCP_DOCLING_MAX_MB=50
  write_config
  jq -e '.data == {MCP_DOCGEN: "true", MCP_DOCLING_MAX_MB: "50"} and .metadata.namespace == "installer"' "$CM_DIR/installer_installer-config.json"
}

@test "CFG-02: в кластер пишутся только настройки MCP" {
  MK_PROFILE=other KUBE_CONTEXT=ctx POSTGRES_PASSWORD=s3cr VM_RETENTION=30d PUBLIC_ACCESS=true MCP_CHART_VERSION=9
  MCP_SEARCH=true
  write_config
  jq -e '.data == {MCP_SEARCH: "true"}' "$CM_DIR/installer_installer-config.json"
}

@test "CFG-03: запуск без опций MCP берёт их из кластера — ручной up не удаляет серверы" {
  put_cm installer installer-config '{"MCP_DOCGEN":"true","MCP_DOCLING_MAX_MB":"50"}'
  [ "$MCP_DOCGEN" = false ]
  restore_config
  [ "$MCP_DOCGEN" = true ]
  [ "$MCP_DOCLING_MAX_MB" = 50 ]
  run mcp_enabled
  [ "$status" -eq 0 ]
}

@test "CFG-04: файл и окружение важнее кластера; MCP_<ИМЯ>=false выключает сервер" {
  put_cm installer installer-config '{"MCP_DOCGEN":"true","MCP_SEARCH":"true"}'
  local cfg=$BATS_TEST_TMPDIR/local.env
  echo 'MCP_DOCGEN=false' >"$cfg"
  unset MCP_DOCGEN
  export MCP_SEARCH=false
  CONFIG_EXPLICIT=()
  load_config "$ROOT" "$cfg"
  restore_config
  [ "$MCP_DOCGEN" = false ]
  [ "$MCP_SEARCH" = false ]
}

@test "CFG-05: из кластера берутся только настройки MCP; чужие переменные не экспортируются" {
  put_cm installer installer-config '{"MK_PROFILE":"evil","BASH_ENV":"/tmp/x","KUBECONFIG":"/tmp/k","LD_PRELOAD":"/tmp/l","MCP_CHART_DIR":"/tmp/c","bad name":"x"}'
  local profile=$MK_PROFILE
  unset BASH_ENV KUBECONFIG LD_PRELOAD
  MCP_CHART_DIR=""
  restore_config
  [ "$MK_PROFILE" = "$profile" ]
  [ -z "${BASH_ENV+x}" ] && [ -z "${KUBECONFIG+x}" ] && [ -z "${LD_PRELOAD+x}" ]
  [ -z "$MCP_CHART_DIR" ]
}

@test "CFG-06: опция нового сервера переживает восстановление и запись" {
  put_cm installer installer-config '{"MCP_NEW_ONE":"true"}'
  restore_config
  [[ " ${MCP_OPTIONS[*]} " == *" MCP_NEW_ONE "* ]]
  write_config
  jq -e '.data.MCP_NEW_ONE == "true"' "$CM_DIR/installer_installer-config.json"
}

@test "CFG-08: ошибка чтения конфигурации останавливает up, status только предупреждает" {
  stub kubectl 'echo "connection refused" >&2; exit 1'
  run restore_config strict
  [ "$status" -eq 12 ]
  [[ $output == *"connection refused"* ]]
  run restore_config
  [ "$status" -eq 0 ]
}

@test "CFG-09: конфигурации нет — ничего не меняется" {
  stub kubectl 'exit 0'
  restore_config strict
  [ "$MCP_DOCGEN" = false ]
}

@test "STATE-04: публичный доступ выключен — оба ConfigMap удаляются, прежний не выдаёт старый домен" {
  PUBLIC_ACCESS=false
  deploy_public
  called "-n installer delete configmap installer-public --ignore-not-found"
  called "-n ingress delete configmap hammurapi-infra-public --ignore-not-found"
}

@test "CFG-07: выкатки компонентов проверяют только стенд" {
  grep -q 'INSTALLER_STAND_ONLY=1 bash "$STATUS_CMD" status' "$ROOT/bin/hammurapi-deploy"
  grep -q 'INSTALLER_STAND_ONLY=1 bash "$STATUS_CMD" status' "$ROOT/bin/nabu-deploy"
  grep -q 'INSTALLER_STAND_ONLY=1 bash "$STATUS_CMD" status' "$ROOT/bin/landing-deploy"
}
