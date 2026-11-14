#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.NAB.CMN-0006: MCP servers of the stand: options, memory budget, keys, removal of the
# release, addresses for the Nabu catalog.

load helpers

setup() {
  setup_stubs
  load_script
  KUBE_SECRETS=$BATS_TEST_TMPDIR/secrets
  mkdir -p "$KUBE_SECRETS"
  export KUBE_SECRETS
  # kubectl: secrets are files of a directory; HAS_RELEASE says whether the release mcp-servers exists.
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

@test "STD-01: all servers are off by default" {
  [ "$MCP_DOCLING" = false ] && [ "$MCP_SEARCH" = false ] && [ "$MCP_YANDEX_MAIL" = false ]
  run mcp_enabled
  [ "$status" -ne 0 ]
}

@test "FTR.INFRA.INST-0001 R21: a foreign MCP_* variable from the environment is not a server option" {
  export MCP_CONNECTION_NONBLOCKING=true MCP_SOMETHING=not-a-bool
  load_config "$ROOT" /dev/null
  run mcp_enabled
  [ "$status" -ne 0 ]
  run validate_mcp_config
  [ "$status" -eq 0 ]
}

@test "MCP-02 (U), FTR.INFRA.INST-0001 R20: a server from its description and option needs no installer code" {
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

@test "FTR.INFRA.INST-0001 R21: while no server is on, the chart does not download" {
  MCP_CHART_DIR=""
  mcp_load
  [ "$MCP_LOADED" -eq 0 ]
  not_called "helm pull"
}

@test "OPEN-05 (U), FTR.INFRA.INST-0001 R20: the chart downloads anonymously and once per export" {
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

@test "FTR.INFRA.INST-0001 R20: the chart is unavailable: code 13" {
  stub helm 'exit 1'
  retry() { "${@:3}"; }
  MCP_SEARCH=true MCP_CHART_DIR=""
  ROOT=$BATS_TEST_TMPDIR
  run mcp_load
  [ "$status" -eq 13 ]
  [[ $output == *"failed to download chart"* ]]
}

@test "FTR.INFRA.INST-0001 R21: an enabled option without a server in the chart: code 2" {
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

@test "FTR.INFRA.INST-0001 R20: an old MCP_* parameter in the config file is not an option" {
  local cfg=$BATS_TEST_TMPDIR/local.env
  echo 'MCP_IMAGE_REGISTRY=ghcr.io/x' >"$cfg"
  load_config "$ROOT" "$cfg"
  run validate_mcp_config
  [ "$status" -eq 0 ]
}

@test "FTR.INFRA.INST-0001 R20: the chart is unavailable: status reports it and check_mcp records a failure" {
  stub helm 'exit 1'
  retry() { "${@:3}"; }
  MCP_SEARCH=true MCP_CHART_DIR=""
  ROOT=$BATS_TEST_TMPDIR
  run mcp_status_json
  [ "$status" -eq 0 ]
  jq -e '.error | test("failed to download chart")' <<<"$output"
  CHECK_RESULTS=()
  check_mcp
  [[ ${CHECK_RESULTS[*]} == *"mcp|fail|"* ]]
}

@test "STD-05: an option value other than true/false: code 2" {
  MCP_DOCLING=yes
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *"MCP_DOCLING must be true or false"* ]]
}

@test "a wrong list of search engines: code 2" {
  MCP_SEARCH_ENGINES='bing; rm -rf'
  run validate_mcp_config
  [ "$status" -eq 2 ]
}

@test "STD-09: the budget fits" {
  run mcp_budget $((4 << 30)) $((2 << 30)) $((12 << 30)) $((12 << 30))
  [ "$output" = ok ]
}

@test "STD-08, STD-09: the budget is exceeded: the missing amount and the needed MK_MEMORY" {
  MK_MEMORY=12g
  meminfo_gb 32
  # stand 6 GiB + servers 3 GiB = 9 GiB with a budget of 8 GiB of 12; the system part is 0.5 GiB
  run mcp_budget $((6 << 30)) $((3 << 30)) $((12 << 30)) $((25 << 29))
  [[ $output == *"lack 1.0 GiB"* ]]
  # 9 × 3/2 + 0.5 = 14 GiB
  [[ $output == *"MK_MEMORY=14g"* ]]
  [[ $output == *"(now 12g)"* ]]
}

@test "STD-09: the needed MK_MEMORY is more than the machine: turn servers off instead" {
  MK_MEMORY=12g
  meminfo_gb 12
  run mcp_budget $((6 << 30)) $((3 << 30)) $((12 << 30)) $((25 << 29))
  [[ $output == *"MK_MEMORY=14g would be needed, more than this machine has; turn servers off"* ]]
}

@test "STD-11, STD-12, STD-03: keys are created once, and those of disabled servers go after the release" {
  MCP_DOCLING=true MCP_SEARCH=true
  ensure_mcp_secrets
  [ -f "$KUBE_SECRETS/mcp-docling-key" ] && [ -f "$KUBE_SECRETS/mcp-search-key" ] && [ -f "$KUBE_SECRETS/mcp-searxng-secret" ]
  [[ $(cat "$KUBE_SECRETS/mcp-search-key") =~ ^[0-9a-f]{64}$ ]]
  first=$(cat "$KUBE_SECRETS/mcp-search-key")
  ensure_mcp_secrets
  [ "$(cat "$KUBE_SECRETS/mcp-search-key")" = "$first" ]
  MCP_DOCLING=false
  ensure_mcp_secrets
  # ensure_mcp_secrets deletes nothing: the release still references the keys
  [ -f "$KUBE_SECRETS/mcp-docling-key" ]
  drop_disabled_secrets
  [ ! -f "$KUBE_SECRETS/mcp-docling-key" ] && [ ! -f "$KUBE_SECRETS/mcp-docling-serve-key" ]
  [ -f "$KUBE_SECRETS/mcp-search-key" ]
}

@test "STD-08 (R3): the budget is exceeded: up stops before any change to the stand" {
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
  not_called "helm --kube-context greenongrey upgrade"
  not_called "repo add"
  not_called "create -f -"
  not_called "apply -f -"
}

@test "STD-13: keys reach neither argv nor the log" {
  MCP_SEARCH=true
  ensure_mcp_secrets 2>"$BATS_TEST_TMPDIR/log"
  key=$(cat "$KUBE_SECRETS/mcp-search-key")
  not_grep -F "$key" "$CALLS"
  not_grep -F "$key" "$BATS_TEST_TMPDIR/log"
}

@test "STD-04: all off: the release and namespace are removed" {
  HAS_RELEASE=true
  deploy_mcp
  called "helm --kube-context greenongrey uninstall mcp-servers -n mcp"
  called "kubectl --context greenongrey delete ns mcp"
}

@test "STD-01, MCP-03 (U): all off and no release: nothing installs" {
  deploy_mcp
  not_called "upgrade --install mcp-servers"
  not_called uninstall
}

@test "chart values: enabling and configuration; the chart itself sets images" {
  MCP_DOCLING=true
  mcp_load
  run mcp_helm_args
  [[ $output == *"docling.enabled=true"* ]]
  [[ $output == *"yandexMail.enabled=false"* ]]
  [[ $output != *image* ]]
  [[ $output == *"search.engines=[\"duckduckgo\""* ]]
}

@test "STD-17, MCP-06: creds: addresses and access mode of enabled servers only" {
  MCP_SEARCH=true MCP_YANDEX_MAIL=true
  printf 'k-search' >"$KUBE_SECRETS/mcp-search-key"
  run mcp_creds_json
  [ "$(jq -r '.search.url' <<<"$output")" = "http://search.mcp.svc:3000/mcp" ]
  [ "$(jq -r '.search.value' <<<"$output")" = "Bearer k-search" ]
  [ "$(jq -r 'has("docling")' <<<"$output")" = false ]
  [ "$(jq -r '."yandex-mail".url' <<<"$output")" = "http://yandex-mail.mcp.svc:8000/mcp" ]
  [ "$(jq -c '."yandex-mail".oauth.scopes' <<<"$output")" = '["mail:imap_ro","login:email"]' ]
}

@test "R1: Yandex Mail has its own option, off by default; enabling gives a release" {
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

@test "R6: the probe script takes the key from the pod's environment and passes it to curl through stdin" {
  run mcp_rpc_script http://search.mcp.svc:3000/mcp SEARCH_KEY tools/list '{}'
  [[ $output == *'eval "KEY=\$SEARCH_KEY"'* ]]
  [[ $output == *"curl -K -"* ]]
  not_grep -F -- '-H "Authorization' <<<"$output"
  sh -n <<<"$output"
}

@test "R6: server checks are separate records" {
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
  [[ " ${CHECK_RESULTS[*]} " == *"mcp-search-tools|ok|2 tools"* ]]
  [[ " ${CHECK_RESULTS[*]} " == *"mcp-search-query|ok"* ]]
  [ "${MCP_TOOL_COUNT[search]}" = 2 ]
}

@test "R6: search engines that refuse the server by their limits are a warning; anything else is a failure" {
  MCP_SEARCH=true
  CHECK_RESULTS=()
  mcp_rpc() { echo '{"result":{"content":[{"type":"text","text":"Search Degraded: No results for \"kubernetes\", and these engines failed: brave (too many requests)"}]}}'; }
  check_mcp_search_query http://search.mcp.svc:3000/mcp SEARCH_KEY
  [[ ${CHECK_RESULTS[0]} == "mcp-search-query|warn|the server answers"* ]]
  mcp_rpc() { echo "curl: (7) Failed to connect"; }
  check_mcp_search_query http://search.mcp.svc:3000/mcp SEARCH_KEY
  [[ ${CHECK_RESULTS[1]} == "mcp-search-query|fail|"* ]]
  # An engine that does not answer at all may be the network of the stand: a failure.
  mcp_rpc() { echo '{"result":{"content":[{"type":"text","text":"No results, and these engines failed: brave (too many requests), bing (timeout)"}]}}'; }
  check_mcp_search_query http://search.mcp.svc:3000/mcp SEARCH_KEY
  [[ ${CHECK_RESULTS[2]} == "mcp-search-query|fail|"* ]]
}

@test "R6: a warning does not fail the checks; status shows it and its JSON keeps ok" {
  check_pods() { record pods ok "ready"; }
  check_storages() { record mcp-search-query warn "engines failed"; }
  for f in check_grafana check_metrics check_logs check_mcp check_resources check_public cleanup_probes; do eval "$f() { :; }"; done
  start_probe_pods() { return 0; }
  run_checks
  run checks_json
  echo "$output" | jq -e '.[] | select(.name == "mcp-search-query") | .ok and .warning'
}

@test "STD-15: status: readiness by Deployments, tool count and checks" {
  MCP_SEARCH=true MCP_DOCLING=true
  MCP_TOOL_COUNT[search]=4
  CHECK_RESULTS=("mcp-search-tools|ok|4 tools" "mcp-search-auth|ok|without a key: 401" "storages|ok|x")
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

@test "R3: server memory comes from the rendered chart through kubectl and jq, without yq" {
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

@test "the stand does not depend on yq: the machine has none (prereqs installs jq)" {
  not_grep -nE '(^|[^#]*[|;&(] *|^ *)yq\b' "$ROOT"/lib/*.sh "$ROOT/installer"
}
