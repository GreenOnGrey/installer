#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.NAB.CMN-0006: MCP-серверы стенда — опции, бюджет памяти, ключи, удаление
# релиза, адреса для каталога Nabu.

load helpers

setup() {
  setup_stubs
  load_script
  KUBE_SECRETS=$BATS_TEST_TMPDIR/secrets
  mkdir -p "$KUBE_SECRETS"
  export KUBE_SECRETS
  # kubectl: секреты — файлы каталога; HAS_RELEASE — есть ли релиз mcp-servers.
  stub kubectl '
case "$*" in
  *"get secret "*" -o jsonpath"*) n=$(sed "s/.*get secret \([^ ]*\).*/\1/" <<<"$*"); [[ -f $KUBE_SECRETS/$n ]] && base64 <"$KUBE_SECRETS/$n" ;;
  *"get secret "*) n=$(sed "s/.*get secret \([^ ]*\).*/\1/" <<<"$*"); [[ -f $KUBE_SECRETS/$n ]] ;;
  *"create -f -"*) m=$(cat); n=$(awk "/^  name:/ {print \$2; exit}" <<<"$m"); v=$(awk "/^  key:/ {print \$2}" <<<"$m" | base64 -d); printf "%s" "$v" >"$KUBE_SECRETS/$n" ;;
  *"delete secret "*) n=$(sed "s/.*delete secret \([^ ]*\).*/\1/" <<<"$*"); rm -f "$KUBE_SECRETS/$n" ;;
  *) exit 0 ;;
esac'
  export HAS_RELEASE=false
  stub helm '
case "$*" in
  *"status mcp-servers"*) [[ $HAS_RELEASE == true ]] ;;
  *) exit 0 ;;
esac'
}

@test "STD-01: по умолчанию все серверы выключены" {
  [ "$MCP_DOCLING" = false ] && [ "$MCP_SEARCH" = false ] && [ "$MCP_YANDEX_MAIL" = false ]
  run mcp_enabled
  [ "$status" -ne 0 ]
}

@test "FTR.INFRA.INST-0001 R21: чужая переменная MCP_* из окружения — не опция сервера" {
  export MCP_CONNECTION_NONBLOCKING=true MCP_SOMETHING=not-a-bool
  load_config "$ROOT" /dev/null
  run mcp_enabled
  [ "$status" -ne 0 ]
  run validate_mcp_config
  [ "$status" -eq 0 ]
}

@test "FTR.INFRA.INST-0001 R20: сервер из описания и своей опции — без кода инсталлятора" {
  local chart=$BATS_TEST_TMPDIR/chart cfg=$BATS_TEST_TMPDIR/local.env
  mkdir -p "$chart/files/servers"
  jq -n '{name: "new-one", valuesKey: "newOne", service: "new-one:9000", deployments: ["new-one"],
    secrets: ["mcp-new-one-key"], keySecret: "mcp-new-one-key", wantTools: ["t"], oauth: null, catalogHint: null}' \
    >"$chart/files/servers/new-one.json"
  echo 'MCP_NEW_ONE=true' >"$cfg"
  load_config "$ROOT" "$cfg"
  MCP_CHART_DIR=$chart
  run mcp_enabled
  [ "$status" -eq 0 ]
  run mcp_helm_args
  [[ $output == *"newOne.enabled=true"* ]]
  run mcp_enabled_list
  [ "$output" = new-one ]
}

@test "FTR.INFRA.INST-0001 R21: пока ни один сервер не включён, чарт не скачивается" {
  MCP_CHART_DIR=""
  mcp_load
  [ "$MCP_LOADED" -eq 0 ]
  not_called "helm pull"
}

@test "FTR.INFRA.INST-0001 R20: чарт скачивается анонимно и один раз на выгрузку" {
  local fake=$BATS_TEST_TMPDIR/root
  mkdir -p "$fake"
  stub helm '
case "$*" in
  *" pull "*|pull\ *) d=$(sed "s/.*--untardir \([^ ]*\).*/\1/" <<<"$*"); mkdir -p "$d/mcp-servers"; touch "$d/mcp-servers/Chart.yaml" ;;
esac'
  ROOT=$fake MCP_CHART_DIR="" mcp_fetch_chart
  ROOT=$fake MCP_CHART_DIR="" mcp_fetch_chart
  [ -f "$fake/.cache/mcp-servers-$MCP_CHART_VERSION/Chart.yaml" ]
  [ "$(grep -c 'helm pull' "$CALLS")" -eq 1 ]
  called "--registry-config"
}

@test "FTR.INFRA.INST-0001 R20: чарт недоступен — код 13" {
  stub helm 'exit 1'
  retry() { "${@:3}"; }
  MCP_SEARCH=true MCP_CHART_DIR=""
  ROOT=$BATS_TEST_TMPDIR
  run mcp_load
  [ "$status" -eq 13 ]
  [[ $output == *"не удалось загрузить чарт"* ]]
}

@test "FTR.INFRA.INST-0001 R21: включённая опция без сервера в чарте — код 2" {
  local cfg=$BATS_TEST_TMPDIR/local.env
  echo 'MCP_DOCGN=true' >"$cfg"
  load_config "$ROOT" "$cfg"
  MCP_CHART_DIR=$ROOT/tests/fixtures/mcp/chart
  run mcp_load
  [ "$status" -eq 2 ]
  [[ $output == *"MCP_DOCGN"* ]]
  run mcp_status_json
  [ "$status" -eq 0 ]
  jq -e '.error | test("MCP_DOCGN")' <<<"$output"
}

@test "FTR.INFRA.INST-0001 R20: прежний параметр MCP_* в файле конфигурации — не опция" {
  local cfg=$BATS_TEST_TMPDIR/local.env
  echo 'MCP_IMAGE_REGISTRY=ghcr.io/x' >"$cfg"
  load_config "$ROOT" "$cfg"
  run validate_mcp_config
  [ "$status" -eq 0 ]
}

@test "FTR.INFRA.INST-0001 R20: чарт недоступен — status сообщает, а не падает; check_mcp записывает сбой" {
  stub helm 'exit 1'
  retry() { "${@:3}"; }
  MCP_SEARCH=true MCP_CHART_DIR=""
  ROOT=$BATS_TEST_TMPDIR
  run mcp_status_json
  [ "$status" -eq 0 ]
  jq -e '.error | test("не удалось загрузить чарт")' <<<"$output"
  CHECK_RESULTS=()
  check_mcp
  [[ ${CHECK_RESULTS[*]} == *"mcp|fail|"* ]]
}

@test "STD-05: значение опции не true/false — код 2" {
  MCP_DOCLING=yes
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *"MCP_DOCLING должен быть true или false"* ]]
}

@test "неверный список поисковых систем — код 2" {
  MCP_SEARCH_ENGINES='bing; rm -rf'
  run validate_mcp_config
  [ "$status" -eq 2 ]
}

@test "STD-09: бюджет — укладывается" {
  run mcp_budget $((4 << 30)) $((2 << 30)) $((12 << 30)) $((12 << 30))
  [ "$output" = ok ]
}

@test "STD-08, STD-09: бюджет превышен — недостающий объём и нужный MK_MEMORY" {
  MK_MEMORY=12g
  # стенд 6 ГиБ + серверы 3 ГиБ = 9 ГиБ при бюджете 8 ГиБ из 12; системная часть 0,5 ГиБ
  run mcp_budget $((6 << 30)) $((3 << 30)) $((12 << 30)) $((25 << 29))
  [[ $output == *"не хватает 1,0 ГиБ"* ]]
  # 9 × 3/2 + 0,5 = 14 ГиБ
  [[ $output == *"MK_MEMORY=14g"* ]]
  [[ $output == *"(сейчас 12g)"* ]]
}

@test "STD-11, STD-12, STD-03: ключи создаются один раз, у выключенных удаляются после релиза" {
  MCP_DOCLING=true MCP_SEARCH=true
  ensure_mcp_secrets
  [ -f "$KUBE_SECRETS/mcp-docling-key" ] && [ -f "$KUBE_SECRETS/mcp-search-key" ] && [ -f "$KUBE_SECRETS/mcp-searxng-secret" ]
  [[ $(cat "$KUBE_SECRETS/mcp-search-key") =~ ^[0-9a-f]{64}$ ]]
  first=$(cat "$KUBE_SECRETS/mcp-search-key")
  ensure_mcp_secrets
  [ "$(cat "$KUBE_SECRETS/mcp-search-key")" = "$first" ]
  MCP_DOCLING=false
  ensure_mcp_secrets
  # ensure_mcp_secrets ничего не удаляет: релиз ещё ссылается на ключи
  [ -f "$KUBE_SECRETS/mcp-docling-key" ]
  drop_disabled_secrets
  [ ! -f "$KUBE_SECRETS/mcp-docling-key" ] && [ ! -f "$KUBE_SECRETS/mcp-docling-serve-key" ]
  [ -f "$KUBE_SECRETS/mcp-search-key" ]
}

@test "STD-08 (R3): бюджет превышен — up останавливается до любых изменений стенда" {
  MCP_DOCLING=true MK_MEMORY=4g
  mcp_rendered_memory() { echo $((3 << 30)); }
  stub kubectl '
case "$*" in
  *"get nodes -o jsonpath={.items[0].status.allocatable.memory}"*) echo 4Gi ;;
  *"get nodes -o jsonpath={.items[0].status.capacity.memory}"*) echo 4Gi ;;
  *"get pods"*) echo "{\"items\":[{\"status\":{\"phase\":\"Running\"},\"spec\":{\"containers\":[{\"resources\":{\"requests\":{\"memory\":\"1Gi\"}}}]}}]}" ;;
  *) exit 0 ;;
esac'
  run deploy_all
  [ "$status" -eq 2 ]
  [[ $output == *"MK_MEMORY="* ]]
  not_called "helm --kube-context hammurapi upgrade"
  not_called "repo add"
  not_called "create -f -"
  not_called "apply -f -"
}

@test "STD-13: ключи не попадают в argv и журнал" {
  MCP_SEARCH=true
  ensure_mcp_secrets 2>"$BATS_TEST_TMPDIR/log"
  key=$(cat "$KUBE_SECRETS/mcp-search-key")
  not_grep -F "$key" "$CALLS"
  not_grep -F "$key" "$BATS_TEST_TMPDIR/log"
}

@test "STD-04: все выключены — релиз и namespace удаляются" {
  HAS_RELEASE=true
  deploy_mcp
  called "helm --kube-context hammurapi uninstall mcp-servers -n mcp"
  called "kubectl --context hammurapi delete ns mcp"
}

@test "STD-01: все выключены и релиза нет — ничего не ставится" {
  deploy_mcp
  not_called "upgrade --install mcp-servers"
  not_called uninstall
}

@test "значения чарта — включение и конфигурация; образы задаёт сам чарт" {
  MCP_DOCLING=true
  mcp_load
  run mcp_helm_args
  [[ $output == *"docling.enabled=true"* ]]
  [[ $output == *"yandexMail.enabled=false"* ]]
  [[ $output != *image* ]]
  [[ $output == *"search.engines=[\"duckduckgo\""* ]]
}

@test "STD-17: creds — адреса и способ доступа только включённых серверов" {
  MCP_SEARCH=true MCP_YANDEX_MAIL=true
  printf 'k-search' >"$KUBE_SECRETS/mcp-search-key"
  run mcp_creds_json
  [ "$(jq -r '.search.url' <<<"$output")" = "http://search.mcp.svc:3000/mcp" ]
  [ "$(jq -r '.search.value' <<<"$output")" = "Bearer k-search" ]
  [ "$(jq -r 'has("docling")' <<<"$output")" = false ]
  [ "$(jq -r '."yandex-mail".url' <<<"$output")" = "http://yandex-mail.mcp.svc:8000/mcp" ]
  [ "$(jq -c '."yandex-mail".oauth.scopes' <<<"$output")" = '["mail:imap_ro","login:email"]' ]
}

@test "R1: Яндекс Почта — своя опция, по умолчанию выключена; включение даёт релиз" {
  [ "$MCP_YANDEX_MAIL" = false ]
  MCP_YANDEX_MAIL=true
  run mcp_enabled
  [ "$status" -eq 0 ]
  run mcp_helm_args
  [[ $output == *"yandexMail.enabled=true"* ]]
  MCP_YANDEX_MAIL=maybe
  run validate_mcp_config
  [ "$status" -eq 2 ]
}

@test "R6: скрипт пробы берёт ключ из окружения пода и передаёт curl через stdin" {
  run mcp_rpc_script http://search.mcp.svc:3000/mcp SEARCH_KEY tools/list '{}'
  [[ $output == *'eval "KEY=\$SEARCH_KEY"'* ]]
  [[ $output == *"curl -K -"* ]]
  not_grep -F -- '-H "Authorization' <<<"$output"
  sh -n <<<"$output"
}

@test "R6: проверки сервера — отдельными записями" {
  MCP_SEARCH=true
  mcp_rpc() {
    case "$2 $3" in
      "- tools/list") echo "HTTP 401" ;;
      "SEARCH_KEY tools/list") echo '{"result":{"tools":[{"name":"searxng_web_search"},{"name":"web_url_read"}]}}' ;;
      "SEARCH_KEY tools/call") echo '{"result":{"content":[{"text":"https://kubernetes.io"}]}}' ;;
    esac
  }
  CHECK_RESULTS=()
  check_mcp_server search
  [[ " ${CHECK_RESULTS[*]} " == *"mcp-search-auth|ok"* ]]
  [[ " ${CHECK_RESULTS[*]} " == *"mcp-search-tools|ok|2 инструментов"* ]]
  [[ " ${CHECK_RESULTS[*]} " == *"mcp-search-query|ok"* ]]
  [ "${MCP_TOOL_COUNT[search]}" = 2 ]
}

@test "STD-15: status — готовность по Deployment'ам, число инструментов и проверки" {
  MCP_SEARCH=true MCP_DOCLING=true
  MCP_TOOL_COUNT[search]=4
  CHECK_RESULTS=("mcp-search-tools|ok|4 инструментов" "mcp-search-auth|ok|без ключа — 401" "storages|ok|x")
  deploys='{"items":[{"metadata":{"name":"search"},"spec":{"replicas":1},"status":{"readyReplicas":1}},
    {"metadata":{"name":"docling-mcp"},"spec":{"replicas":1},"status":{"readyReplicas":1}},
    {"metadata":{"name":"docling-serve"},"spec":{"replicas":1},"status":{}}]}'
  run mcp_status_json "$deploys"
  [ "$(jq -r '.search.ready' <<<"$output")" = true ]
  [ "$(jq -r '.search.tools' <<<"$output")" = 4 ]
  [ "$(jq -r '.search.checks | length' <<<"$output")" = 2 ]
  [ "$(jq -r '.docling.ready' <<<"$output")" = false ]
  [ "$(jq -r '."yandex-mail".enabled' <<<"$output")" = false ]
}

@test "R3: память серверов — из рендера чарта через kubectl и jq, без yq" {
  MCP_DOCLING=true
  stub helm 'echo "kind: Deployment"'
  stub kubectl '
case "$*" in
  *"create --dry-run=client -o json -f -"*) cat >/dev/null
    echo "{\"kind\":\"List\",\"items\":[{\"kind\":\"Deployment\",\"spec\":{\"template\":{\"spec\":{\"containers\":[
      {\"resources\":{\"requests\":{\"memory\":\"2Gi\"}}},{\"resources\":{\"requests\":{\"memory\":\"256Mi\"}}}]}}}},
      {\"kind\":\"Service\"}]}" ;;
  *) exit 0 ;;
esac'
  run mcp_rendered_memory
  [ "$status" -eq 0 ]
  [ "$output" = $(((2 << 30) + (256 << 20))) ]
}

@test "стенд не зависит от yq: на машине его нет (prereqs ставит jq)" {
  not_grep -nE '(^|[^#]*[|;&(] *|^ *)yq\b' "$ROOT"/lib/*.sh "$ROOT/installer"
}
