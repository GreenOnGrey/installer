#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329,SC2154
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
  *"create -f -"*|*"apply -f -"*) m=$(cat); n=$(awk "/^  name:/ {print \$2; exit}" <<<"$m"); v=$(awk "/^  key:/ {print \$2}" <<<"$m" | base64 -d); printf "%s" "$v" >"$KUBE_SECRETS/$n" ;;
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
  : >"$cfg"
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

@test "R21 (MCP-07): servers enabled but not rolled out yet: a warning, so update does not stop before it deploys them" {
  MCP_SEARCH=true
  # The chart is there, the release is not: kubectl finds no deployments of mcp-servers.
  mcp_try_load() { return 0; }
  CHECK_RESULTS=()
  check_mcp
  [ "${CHECK_RESULTS[*]}" = "mcp|warn|enabled, not rolled out yet: install or update mcp-servers deploys them" ]
  not_called "wait --for=condition=Ready pod"
  not_called "create -f -"
}

@test "R21 (MCP-07): a release that is rolled out is still checked: a Deployment that is not ready is a failure" {
  MCP_SEARCH=true
  MCP_OPTIONS=(MCP_SEARCH)
  MCP_SERVERS=(search)
  MCP_DEPLOYMENTS[search]="search"
  mcp_try_load() { return 0; }
  stub kubectl '
case "$*" in
  *"get deploy -l app.kubernetes.io/part-of=mcp-servers -o name"*) echo "deployment.apps/search" ;;
  *"rollout status deployment/search"*) echo "error: timed out waiting for the condition" >&2; exit 1 ;;
  *) exit 0 ;;
esac'
  CHECK_RESULTS=()
  check_mcp
  [[ ${CHECK_RESULTS[*]} == *"mcp|fail|deployment search of search is not ready"* ]]
}

@test "R21 (MCP-09): the networks of the company reach the chart, and nothing when there are none" {
  MCP_SEARCH=true MCP_SEARCH_KEY=k-search
  MCP_EGRESS_ALLOW=""
  run mcp_helm_args
  [ "$status" -eq 0 ]
  [[ $output != *egressAllow* ]]
  MCP_EGRESS_ALLOW="10.20.30.0/24,10.20.31.5/32"
  run mcp_helm_args
  [ "$status" -eq 0 ]
  [[ $output == *'egressAllow=["10.20.30.0/24","10.20.31.5/32"]'* ]]
  # FTR.INFRA.MCPS-0003 R7: the search goes through DeepSeek, so the list only opens the policy.
  [[ $output != *allowPrivateUrls* ]]
  MCP_EGRESS_ALLOW=""
  run mcp_helm_args
  [[ $output != *allowPrivateUrls* ]]
}

@test "R21 (MCP-09): MCP_EGRESS_ALLOW takes CIDRs separated by commas and nothing else" {
  MCP_EGRESS_ALLOW="10.20.30.0/24,10.20.31.5/32"
  run validate_mcp_config
  [ "$status" -eq 0 ]
  MCP_EGRESS_ALLOW="10.20.30.0"
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_EGRESS_ALLOW* ]]
  MCP_EGRESS_ALLOW="site.example"
  run validate_mcp_config
  [ "$status" -eq 2 ]
}

@test "STD-05: an option value other than true/false: code 2" {
  MCP_DOCLING=yes
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *"MCP_DOCLING must be true or false"* ]]
}

@test "FTR.INFRA.MCPS-0003 R2, R3: the search needs its key and an https address" {
  MCP_SEARCH=true
  # the key may live in the cluster already: a repeated up without it keeps working
  MCP_SEARCH_KEY=
  run require_mcp_secrets
  [ "$status" -eq 2 ]
  [[ $output == *MCP_SEARCH_KEY* ]]
  printf 'k-deepseek' >"$KUBE_SECRETS/mcp-deepseek-key"
  run require_mcp_secrets
  [ "$status" -eq 0 ]
  rm -f "$KUBE_SECRETS/mcp-deepseek-key"
  # a file keeps the key out of the environment of every command
  printf 'k-from-file' >"$BATS_TEST_TMPDIR/deepseek"
  MCP_SEARCH_KEY_FILE="$BATS_TEST_TMPDIR/deepseek"
  run require_mcp_secrets
  [ "$status" -eq 0 ]
  MCP_SEARCH_KEY_FILE=
  # the same key reaches the Secret
  MCP_SEARCH_KEY="k-search"
  ensure_mcp_secrets
  [ "$(cat "$KUBE_SECRETS/mcp-deepseek-key")" = "k-search" ]
  MCP_SEARCH_KEY="key with spaces"
  run validate_mcp_config
  [ "$status" -eq 2 ]
  MCP_SEARCH_KEY=k-search
  run validate_mcp_config
  [ "$status" -eq 0 ]
  MCP_SEARCH_URL=http://api.deepseek.com
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_SEARCH_URL* ]]
  MCP_SEARCH_URL=https://api.deepseek.com
  run validate_mcp_config
  [ "$status" -eq 0 ]
  # off: neither the key nor the address is needed
  MCP_SEARCH=false MCP_SEARCH_KEY="" MCP_SEARCH_URL="http://example.com"
  run validate_mcp_config
  [ "$status" -eq 0 ]
}

@test "FTR.INFRA.MCPS-0003 R14: an old MCP_SEARCH_ENGINES does not stop the stand" {
  MCP_SEARCH=true MCP_SEARCH_KEY=k-search
  MCP_SEARCH_ENGINES=duckduckgo,bing
  run validate_mcp_config
  [ "$status" -eq 0 ]
  run mcp_helm_args
  [ "$status" -eq 0 ]
  [[ $output != *engines* ]]
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
  MCP_DOCLING=true MCP_SEARCH=true MCP_SEARCH_KEY=k-deepseek
  ensure_mcp_secrets
  [ -f "$KUBE_SECRETS/mcp-docling-key" ] && [ -f "$KUBE_SECRETS/mcp-deepseek-key" ]
  # FTR.INFRA.MCPS-0003 R2: the vendor key comes from the configuration, not from openssl
  [ "$(cat "$KUBE_SECRETS/mcp-deepseek-key")" = "k-deepseek" ]
  [[ $(cat "$KUBE_SECRETS/mcp-docling-key") =~ ^[0-9a-f]{64}$ ]]
  first=$(cat "$KUBE_SECRETS/mcp-deepseek-key")
  : >"$CALLS"
  ensure_mcp_secrets
  [ "$(cat "$KUBE_SECRETS/mcp-deepseek-key")" = "$first" ]
  not_called "rollout restart deploy/search"
  # a changed key is written and the Deployment restarts, so the pod picks it up
  MCP_SEARCH_KEY=k-new
  : >"$CALLS"
  ensure_mcp_secrets
  [ "$(cat "$KUBE_SECRETS/mcp-deepseek-key")" = "k-new" ]
  called "rollout restart deploy/search"
  MCP_DOCLING=false
  ensure_mcp_secrets
  # ensure_mcp_secrets deletes nothing: the release still references the keys
  [ -f "$KUBE_SECRETS/mcp-docling-key" ]
  drop_disabled_secrets
  [ ! -f "$KUBE_SECRETS/mcp-docling-key" ] && [ ! -f "$KUBE_SECRETS/mcp-docling-serve-key" ]
  [ -f "$KUBE_SECRETS/mcp-deepseek-key" ]
  # FTR.INFRA.MCPS-0003 R1: the secret of a disabled server goes too
  MCP_SEARCH=false
  drop_disabled_secrets
  [ ! -f "$KUBE_SECRETS/mcp-deepseek-key" ]
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

@test "STD-09 (R3): the budget follows MK_MEMORY, not the memory the node reports" {
  MCP_DOCLING=true MK_MEMORY=12g
  meminfo_gb 16
  mcp_rendered_memory() { echo $((7 << 30)); }
  stub kubectl '
case "$*" in
  *"range .items[*]"*) echo 16Gi ;;
  *"get nodes -o jsonpath={.items[0].status.capacity.memory}"*) echo 16Gi ;;
  *"get pods -n storages"*) echo "{\"items\":[{\"status\":{\"phase\":\"Running\"},\"spec\":{\"containers\":[{\"resources\":{\"requests\":{\"memory\":\"2Gi\"}}}]}}]}" ;;
  *"get pods -n observability"*) echo "{\"items\":[]}" ;;
  *) exit 0 ;;
esac'
  # 2 GiB of the stand + 7 GiB of servers = 9 GiB: more than two thirds of the 12g profile, less than two
  # thirds of the 16 GiB the node reports. The profile that fits is 9 × 3/2 = 14g, not more than the machine.
  run deploy_all
  [ "$status" -eq 2 ]
  [[ $output == *"MK_MEMORY=14g"* ]]
  not_called "helm --kube-context greenongrey upgrade"
}

@test "STD-13: keys reach neither argv nor the log" {
  MCP_SEARCH=true MCP_SEARCH_KEY=k-secret-deepseek
  ensure_mcp_secrets 2>"$BATS_TEST_TMPDIR/log"
  key=$(cat "$KUBE_SECRETS/mcp-deepseek-key")
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
  MCP_DOCLING=true MCP_SEARCH_KEY=k-search
  mcp_load
  run mcp_helm_args
  [[ $output == *"docling.enabled=true"* ]]
  [[ $output == *"yandexMail.enabled=false"* ]]
  [[ $output != *image* ]]
  # FTR.INFRA.MCPS-0003 R3: the address of the API is a setting of the stand
  [[ $output == *"search.url=https://api.deepseek.com"* ]]
}

@test "STD-17, MCP-06: creds: addresses and access mode of enabled servers only" {
  MCP_SEARCH=true MCP_YANDEX_MAIL=true MCP_SEARCH_KEY=k-search
  printf 'k-search' >"$KUBE_SECRETS/mcp-deepseek-key"
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
      "SEARCH_KEY tools/list") echo '{"result":{"tools":[{"name":"web_search"},{"name":"web_fetch"}]}}' ;;
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

@test "R6: a refused or unavailable vendor is a warning; a wrong key or balance is a failure" {
  MCP_SEARCH=true
  CHECK_RESULTS=()
  mcp_rpc() { echo '{"result":{"isError":true,"content":[{"type":"text","text":"the search rate limit is exhausted: retry later"}]}}'; }
  check_mcp_search_query http://search.mcp.svc:3000/mcp SEARCH_KEY
  [[ ${CHECK_RESULTS[0]} == "mcp-search-query|warn|the server answers"* ]]
  mcp_rpc() { echo "curl: (7) Failed to connect"; }
  check_mcp_search_query http://search.mcp.svc:3000/mcp SEARCH_KEY
  [[ ${CHECK_RESULTS[1]} == "mcp-search-query|fail|"* ]]
  # FTR.INFRA.MCPS-0003 R10: a wrong key or an empty balance never fixes itself.
  mcp_rpc() { echo '{"result":{"isError":true,"content":[{"type":"text","text":"the balance of the search account ran out: ask the operator of the stand"}]}}'; }
  check_mcp_search_query http://search.mcp.svc:3000/mcp SEARCH_KEY
  [[ ${CHECK_RESULTS[2]} == "mcp-search-query|fail|the key or the balance"* ]]
  mcp_rpc() { echo "HTTP 401"; }
  check_mcp_search_query http://search.mcp.svc:3000/mcp SEARCH_KEY
  [[ ${CHECK_RESULTS[3]} == "mcp-search-query|fail|"* ]]
}

@test "R6: an SSE answer gives each tool once (the probe used to print a data line twice)" {
  cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'HTTP/1.1 200 OK\r\nmcp-session-id: s1\r\n\r\n' >/tmp/hdr
printf 'event: message\r\ndata: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"web_search"},{"name":"web_fetch"}]}}\r\n\r\n'
EOF
  chmod +x "$STUBS/curl"
  mcp_probe() { bash -c "$1" 2>/dev/null; }
  local out names
  out=$(mcp_rpc http://search.mcp.svc:3000/mcp SEARCH_KEY tools/list '{}')
  names=$(mcp_tools "$out")
  [ "$(wc -w <<<"$names" | tr -d ' ')" = 2 ]
  [ "$names" = "web_fetch web_search " ]
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

@test "FTR.INFRA.MCPS-0001 R4: an enabled personal server needs the address of its system" {
  MCP_JIRA=true
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_JIRA_URL* ]]
  MCP_JIRA_URL=https://jira.company.ru
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_JIRA_CLOUD_ID* ]]
  # Data Center signs users in by a personal token: no cloud id is needed
  MCP_JIRA_AUTH_MODE=dc
  run validate_mcp_config
  [ "$status" -eq 0 ]
}

@test "FTR.INFRA.MCPS-0001 R4: GitLab and ClickHouse settings are checked" {
  MCP_GITLAB=true MCP_GITLAB_URL=gitlab.company.ru
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_GITLAB_URL* ]]
  MCP_GITLAB_URL=https://gitlab.company.ru
  run validate_mcp_config
  [ "$status" -eq 0 ]
  MCP_CLICKHOUSE=true MCP_CLICKHOUSE_HOST=ch.company.ru MCP_CLICKHOUSE_SCHEME=ftp
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_CLICKHOUSE_SCHEME* ]]
  MCP_CLICKHOUSE_SCHEME=https
  MCP_CLICKHOUSE_PORT=70000
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_CLICKHOUSE_PORT* ]]
  MCP_CLICKHOUSE_PORT=8443
  run validate_mcp_config
  [ "$status" -eq 0 ]
}

@test "FTR.INFRA.MCPS-0002 R10: Greenplum needs a master, a database and a known mode of SSL" {
  MCP_GREENPLUM=true
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_GREENPLUM_HOST* ]]
  MCP_GREENPLUM_HOST=gp-master.company.ru
  MCP_GREENPLUM_SSLMODE=secure
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_GREENPLUM_SSLMODE* ]]
  MCP_GREENPLUM_SSLMODE=verify-full
  MCP_GREENPLUM_PORT=70000
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_GREENPLUM_PORT* ]]
  MCP_GREENPLUM_PORT=5432
  MCP_GREENPLUM_DATABASE="bad;name"
  run validate_mcp_config
  [ "$status" -eq 2 ]
  [[ $output == *MCP_GREENPLUM_DATABASE* ]]
  MCP_GREENPLUM_DATABASE=citydrive_db
  run validate_mcp_config
  [ "$status" -eq 0 ]
}

@test "FTR.INFRA.MCPS-0001 R10: the values of a personal server reach the chart" {
  MCP_JIRA=true MCP_JIRA_URL=https://jira.company.ru MCP_JIRA_AUTH_MODE=cloud MCP_JIRA_CLOUD_ID=site-1
  MCP_GITLAB=true MCP_GITLAB_URL=https://gitlab.company.ru
  MCP_CLICKHOUSE=true MCP_CLICKHOUSE_HOST=ch.company.ru MCP_CLICKHOUSE_PORT=8443 MCP_CLICKHOUSE_SCHEME=https
  MCP_CA_SECRET=company-ca
  MCP_CHART_DIR=$ROOT/tests/fixtures/mcp/chart
  run mcp_helm_args
  [ "$status" -eq 0 ]
  [[ $output == *"jira.url=https://jira.company.ru"* && $output == *"jira.authMode=cloud"* && $output == *"jira.cloudId=site-1"* ]]
  [[ $output == *"jira.caSecret=company-ca"* ]]
  [[ $output == *"gitlab.url=https://gitlab.company.ru"* ]]
  [[ $output == *"clickhouse.host=ch.company.ru"* && $output == *"clickhouse.secure=true"* ]]
  [[ $output == *"clickhouse.caSecret=company-ca"* ]]
}

@test "FTR.INFRA.MCPS-0001 R10: creds print the personal token of a description" {
  MCP_GITLAB=true MCP_GITLAB_URL=https://gitlab.company.ru
  load_config "$ROOT" /dev/null
  MCP_CHART_DIR=$ROOT/tests/fixtures/mcp/chart
  run mcp_creds_json
  [ "$status" -eq 0 ]
  jq -e '.gitlab.mode == "personal" and .gitlab.token.header == "Private-Token"
    and .gitlab.token.prefix == "" and (.gitlab.token.hint | test("read_api"))' <<<"$output"
  run mcp_creds_text
  [[ $output == *'Token: a personal access token of GitLab with the read_api scope (header Private-Token, prefix "")'* ]]
}

@test "R21 (MCP-07): a server that is enabled but not rolled out on a running stand is a warning" {
  # Other servers of the release are already deployed: the check of the stand goes on and meets this one.
  MCP_DOCGEN=true
  mcp_try_load() { return 0; }
  MCP_DEPLOYMENTS["docgen"]="docgen doc-convert"
  stub kubectl '
case "$*" in
  *"get deploy docgen"*) exit 1 ;;
  *) exit 0 ;;
esac'
  CHECK_RESULTS=()
  check_mcp_server docgen
  [ "${CHECK_RESULTS[*]}" = "mcp-docgen-auth|warn|enabled, not rolled out yet: install or update mcp-servers deploys it" ]
  not_called "exec"
}

@test "R21: the check waits for the Deployments of the enabled servers, not for every pod of the namespace" {
  MCP_SEARCH=true MCP_DOCGEN=true MCP_DOCLING=false
  MCP_OPTIONS=(MCP_SEARCH MCP_DOCGEN MCP_DOCLING)
  MCP_SERVERS=(search docgen docling)
  MCP_DEPLOYMENTS[search]="search"
  MCP_DEPLOYMENTS[docgen]="docconly"
  MCP_DEPLOYMENTS[docling]="docling-mcp docling-serve"
  mcp_try_load() { return 0; }
  # docgen is not ready: the check names it and stops; a pod of the disabled docling is never awaited
  stub kubectl '
case "$*" in
  *"rollout status deployment/docconly"*) exit 1 ;;
  *) exit 0 ;;
esac'
  CHECK_RESULTS=()
  wait_mcp_deployments && status_ok=1 || status_ok=0
  [ "$status_ok" -eq 0 ]
  [[ ${CHECK_RESULTS[*]} == *"mcp|fail|deployment docconly of docgen is not ready"* ]]
  called "rollout status deployment/search"
  not_called "rollout status deployment/docling-mcp"
  not_called "wait --for=condition=Ready pod"
}

@test "R21: Deployments and Services of a disabled server are removed, those of an enabled one stay" {
  MCP_SEARCH=false MCP_DOCLING=true
  MCP_OPTIONS=(MCP_SEARCH MCP_DOCLING)
  MCP_SERVERS=(search docling)
  MCP_DEPLOYMENTS[search]="search"
  MCP_DEPLOYMENTS[docling]="docling-mcp docling-serve"
  MCP_SERVICE[search]="search:3000"
  MCP_SERVICE[docling]="docling-mcp:8080"
  mcp_try_load() { return 0; }
  stub kubectl 'exit 0'
  drop_disabled_workloads
  called "delete deployment search"
  called "delete service search"
  not_called "delete deployment docling-mcp"
  not_called "delete service docling-mcp"
}
