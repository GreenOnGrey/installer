# shellcheck shell=bash disable=SC2016
# SC2016: probe scripts are in single quotes on purpose: they run inside containers.
# MCP servers of the stand (FTR.NAB.CMN-0006, tech §2): document conversion, web search,
# read-only Yandex Mail. Each is enabled by its own option; namespace $NS_MCP,
# one release mcp-servers: the chart and server descriptions come from a release of mcps. Keys are generated on the first `up` and kept only
# in secrets of the namespace.

MCP_RELEASE=mcp-servers

# --- Server properties: descriptions from the chart mcp-servers of repository mcps ---

MCP_SERVERS=()
# chart value enabling a server; MCP service and port; Deployments (readiness in status)
declare -gA MCP_VALUES_KEY=() MCP_SERVICE=() MCP_DEPLOYMENTS=()
# secrets `up` creates for a server; the platform access key, only for platform servers
declare -gA MCP_SECRETS=() MCP_KEY_SECRET=()
# tools the check expects in tools/list
declare -gA MCP_WANT_TOOLS=()
# OAuth of personal servers and hints for the Nabu catalog entry (creds)
declare -gA MCP_OAUTH=() MCP_CATALOG_HINT=()
# number of tools from the check results (status)
declare -gA MCP_TOOL_COUNT=()
MCP_LOADED=0

# mcp_opt <server> — the option name: yandex-mail → MCP_YANDEX_MAIL.
mcp_opt() { local s=${1^^}; echo "MCP_${s//-/_}"; }

# mcp_on <server> — the server is enabled.
mcp_on() {
  local o
  o=$(mcp_opt "$1")
  [[ " ${MCP_OPTIONS[*]} " == *" $o "* && ${!o:-false} == true ]]
}

# mcp_option_names — enabling options (load_config). No server list is needed here:
# the configuration is validated before Helm exists. A new server's option goes in the config file.
mcp_option_names() { printf '%s\n' "${MCP_OPTIONS[@]}"; }

mcp_enabled() {
  local o
  while read -r o; do
    [[ ${!o:-false} == true ]] && return 0
  done < <(mcp_option_names)
  return 1
}

# mcp_fetch_chart — the directory of the pinned chart: MCP_CHART_DIR or the release cache.
# The pull is anonymous: the package is public and a registry login may be stale. status and creds
# run without the up lock, so each run has its own temporary directory. On failure: code 1,
# with the reason in MCP_FETCH_ERROR.
mcp_fetch_chart() {
  [[ -n ${MCP_CHART_DIR:-} ]] && return 0
  local cache=$ROOT/.cache/mcp-servers-$MCP_CHART_VERSION tmp
  if [[ ! -f $cache/Chart.yaml ]]; then
    mkdir -p "$ROOT/.cache"
    tmp=$(mktemp -d "$ROOT/.cache/pull.XXXXXX")
    if ! MCP_FETCH_ERROR=$(retry 3 10 helm pull "$MCP_CHART_REPO" --version "$MCP_CHART_VERSION" --untar --untardir "$tmp" \
      --registry-config "$tmp/registry.json" 2>&1); then
      rm -rf "$tmp"
      MCP_FETCH_ERROR="failed to download chart $MCP_CHART_REPO $MCP_CHART_VERSION: $(tail -1 <<<"$MCP_FETCH_ERROR")"
      return 1
    fi
    # A parallel run may have finished first: its directory is ready.
    mv -T "$tmp/mcp-servers" "$cache" 2>/dev/null || true
    rm -rf "$tmp"
  fi
  MCP_CHART_DIR=$cache
}

# mcp_try_load — server descriptions from the chart; code 1 if the chart is unavailable. While no
# server is enabled, the chart is not needed.
mcp_try_load() {
  ((MCP_LOADED)) && return 0
  mcp_enabled || return 0
  mcp_fetch_chart || return 1
  local f srv o known=" "
  MCP_SERVERS=()
  for f in "$MCP_CHART_DIR"/files/servers/*.json; do
    if [[ ! -f $f ]]; then
      MCP_FETCH_ERROR="chart $MCP_CHART_DIR has no server descriptions"
      return 1
    fi
    srv=$(basename "$f" .json)
    MCP_SERVERS+=("$srv")
    known+="$(mcp_opt "$srv") "
    MCP_VALUES_KEY[$srv]=$(jq -r .valuesKey "$f")
    MCP_SERVICE[$srv]=$(jq -r .service "$f")
    MCP_DEPLOYMENTS[$srv]=$(jq -r '.deployments | join(" ")' "$f")
    MCP_SECRETS[$srv]=$(jq -r '.secrets | join(" ")' "$f")
    MCP_KEY_SECRET[$srv]=$(jq -r '.keySecret // empty' "$f")
    MCP_WANT_TOOLS[$srv]=$(jq -r '.wantTools | join(" ")' "$f")
    MCP_OAUTH[$srv]=$(jq -c '.oauth // empty' "$f")
    MCP_CATALOG_HINT[$srv]=$(jq -c '.catalogHint // empty' "$f")
  done
  # An enabled option without a server is a typo, or the server left the chart.
  while read -r o; do
    if [[ ${!o:-false} == true && $known != *" $o "* ]]; then
      MCP_FETCH_ERROR="$o: chart mcp-servers $MCP_CHART_VERSION has no such server"
      MCP_FETCH_CODE=$E_USAGE
      return 1
    fi
  done < <(mcp_option_names)
  MCP_LOADED=1
}

# mcp_load — the same, but an install cannot continue without the chart.
mcp_load() { mcp_try_load || die "${MCP_FETCH_CODE:-$E_DEPLOY}" "$MCP_FETCH_ERROR"; }

# mcp_enabled_list — enabled servers, one per line.
mcp_enabled_list() {
  local s
  mcp_load
  for s in "${MCP_SERVERS[@]}"; do if mcp_on "$s"; then echo "$s"; fi; done
}

mcp_url() { mcp_load; echo "http://${MCP_SERVICE[$1]%%:*}.$NS_MCP.svc:${MCP_SERVICE[$1]##*:}/mcp"; }

mcp_mode() { mcp_load; if [[ -n ${MCP_KEY_SECRET[$1]:-} ]]; then echo platform; else echo personal; fi; }

# validate_mcp_config — options and parameters of servers (R1).
validate_mcp_config() {
  local o
  while read -r o; do
    case ${!o:-false} in
      true | false) ;;
      *) die "$E_USAGE" "$o must be true or false, not '${!o}'" ;;
    esac
  done < <(mcp_option_names)
  if ! [[ $MCP_DOCLING_MAX_MB =~ ^[0-9]+$ ]] || ((MCP_DOCLING_MAX_MB < 1 || MCP_DOCLING_MAX_MB > 200)); then
    die "$E_USAGE" "MCP_DOCLING_MAX_MB: a whole number of megabytes from 1 to 200"
  fi
  [[ $MCP_SEARCH_ENGINES =~ ^[a-z0-9_]+(,[a-z0-9_]+)*$ ]] ||
    die "$E_USAGE" "MCP_SEARCH_ENGINES: comma-separated SearXNG engine names, such as duckduckgo,bing"
}

# mcp_helm_args — enabling servers and configuration parameters. Images and their versions
# are in the values of the chart pinned by MCP_CHART_VERSION.
mcp_helm_args() {
  local engines srv
  mcp_load
  engines=$(tr ',' '\n' <<<"$MCP_SEARCH_ENGINES" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null ||
    printf '[]')
  for srv in "${MCP_SERVERS[@]}"; do
    printf '%s\n' --set "${MCP_VALUES_KEY[$srv]}.enabled=$(mcp_on "$srv" && echo true || echo false)"
  done
  printf '%s\n' \
    --set "docling.serve.maxFileMB=$MCP_DOCLING_MAX_MB" \
    --set-json "search.engines=$engines" \
    --set-string "s3.namespace=$NS_STORAGES"
}

gen_key() { openssl rand -hex 32; }

# ensure_mcp_secrets — keys of enabled servers; existing ones stay (STD-12).
ensure_mcp_secrets() {
  local srv name
  mcp_load
  while read -r srv; do
    for name in ${MCP_SECRETS[$srv]:-}; do
      if [[ $name == mcp-doc-convert-auth ]]; then
        # basic auth of Gotenberg and legacy (FTR.NAB.CHAT-0003 tech §9.2)
        ensure_secret "$NS_MCP" "$name" Opaque username docconvert password "$(gen_key)"
      else
        ensure_secret "$NS_MCP" "$name" Opaque key "$(gen_key)"
      fi
    done
  done < <(mcp_enabled_list)
}

# sync_preview_secret — the secret nabu-docs-preview for the Nabu api (FTR.NAB.CHAT-0003
# tech §9.2): addresses and credentials of doc-convert and docgen while the documents
# service is on; without it office file preview is off. api restarts
# only if the secret changed.
sync_preview_secret() {
  local ns=${NABU_NAMESPACE:-nabu} before after
  kc get ns "$ns" >/dev/null 2>&1 || return 0
  before=$(kc -n "$ns" get secret nabu-docs-preview -o jsonpath='{.data}' 2>/dev/null || true)
  if ! mcp_on docgen; then
    [[ -z $before ]] && return 0
    kc -n "$ns" delete secret nabu-docs-preview --ignore-not-found >/dev/null
  else
    # secrets reach jq through the environment, not argv
    PREVIEW_USER=$(secret_key "$NS_MCP" mcp-doc-convert-auth username) \
    PREVIEW_PASS=$(secret_key "$NS_MCP" mcp-doc-convert-auth password) \
    PREVIEW_KEY=$(secret_key "$NS_MCP" mcp-docgen-key key) \
    jq -cn --arg ns "$ns" --arg mcp "$NS_MCP" \
      '$ENV.PREVIEW_USER as $user | $ENV.PREVIEW_PASS as $pass | $ENV.PREVIEW_KEY as $key | {apiVersion: "v1", kind: "Secret", type: "Opaque",
        metadata: {name: "nabu-docs-preview", namespace: $ns, labels: {"app.kubernetes.io/managed-by": "installer"}},
        stringData: {PREVIEW_CONVERT_URL: "http://doc-convert.\($mcp).svc:3000", PREVIEW_CONVERT_USER: $user, PREVIEW_CONVERT_PASSWORD: $pass,
          PREVIEW_LEGACY_URL: "http://doc-convert.\($mcp).svc:3001", PREVIEW_DOCGEN_URL: "http://docgen.\($mcp).svc:8000", PREVIEW_DOCGEN_KEY: $key}}' |
      apply_stdin
  fi
  after=$(kc -n "$ns" get secret nabu-docs-preview -o jsonpath='{.data}' 2>/dev/null || true)
  if [[ $before != "$after" ]] && kc -n "$ns" get deploy api >/dev/null 2>&1; then
    kc -n "$ns" rollout restart deploy/api >/dev/null && log "Nabu api restarted: preview settings changed"
  fi
}

# drop_disabled_secrets — keys of disabled servers (STD-03); only after a
# release that no longer references them.
drop_disabled_secrets() {
  local srv name
  mcp_load
  for srv in "${MCP_SERVERS[@]}"; do
    mcp_on "$srv" && continue
    for name in ${MCP_SECRETS[$srv]:-}; do
      kc -n "$NS_MCP" delete secret "$name" --ignore-not-found >/dev/null
    done
  done
}

# copy_pull_secret — ghcr-pull from the Nabu namespace: built images are in
# ghcr.io/greenongrey, like the images of Nabu.
copy_pull_secret() {
  local src
  src=$(kc -n nabu get secret ghcr-pull -o json 2>/dev/null) || {
    warn "no secret nabu/ghcr-pull: images are pulled without it"
    return 0
  }
  jq -c --arg ns "$NS_MCP" '{apiVersion: "v1", kind: "Secret", type: .type, data: .data,
    metadata: {name: "ghcr-pull", namespace: $ns, labels: {"app.kubernetes.io/managed-by": "installer"}}}' <<<"$src" |
    apply_stdin
}

# mcp_rendered_memory — total memory requests of containers of enabled servers, bytes.
# The rendered chart turns into JSON through kubectl (client dry-run): the machine has
# jq but no yq.
mcp_rendered_memory() {
  local args=() rendered
  mapfile -t args < <(mcp_helm_args)
  rendered=$(hm template "$MCP_RELEASE" "$MCP_CHART_DIR" -n "$NS_MCP" "${args[@]}") ||
    die "$E_DEPLOY" "chart mcp-servers does not render"
  kc create --dry-run=client -o json -f - <<<"$rendered" |
    jq -r '(if .kind == "List" then .items[] else . end) | select(.kind == "Deployment")
      | .spec.template.spec.containers[] | .resources.requests.memory // empty' |
    while read -r q; do to_bytes "$q"; done |
    awk '{ s += $1 } END { print s + 0 }'
}

# mcp_budget <requested outside mcp> <servers> <allocatable> <capacity> — ok, or a
# message with the missing amount and the needed MK_MEMORY (R3, STD-09).
mcp_budget() {
  local others=$1 servers=$2 alloc=$3 capacity=$4
  local need=$((others + servers)) limit=$((alloc * 2 / 3))
  if ((need <= limit)); then
    echo ok
    return
  fi
  if target_external; then
    printf 'MCP servers lack %s GiB of memory: add nodes to the cluster or turn servers off\n' "$(gib $((need - limit)))"
    return
  fi
  local system=$((capacity - alloc))
  # node memory where need is two thirds of allocatable, plus the system part
  local want_gib=$(((need * 3 / 2 + system + 1073741823) / 1073741824))
  # A profile larger than the machine is refused (check_host): then servers have to go, not MK_MEMORY up.
  if ! mk_memory_fits "${want_gib}g"; then
    printf 'MCP servers lack %s GiB of memory: MK_MEMORY=%sg would be needed, more than this machine has; turn servers off\n' \
      "$(gib $((need - limit)))" "$want_gib"
    return
  fi
  printf 'MCP servers lack %s GiB of memory: MK_MEMORY=%sg is needed (now %s). The minikube profile has to be recreated: ./installer down, then up\n' \
    "$(gib $((need - limit)))" "$want_gib" "$MK_MEMORY"
}

# mcp_preflight — the memory budget before any change to the stand (R3: "changing
# nothing"). Counts pods of the stand (the namespaces of the resources check) and enabled
# servers; on the first `up` there are no pods yet, so only servers count.
mcp_preflight() {
  mcp_enabled || return 0
  mcp_load
  local others=0 q servers alloc capacity verdict ns
  while read -r q; do
    [[ -n $q ]] && others=$((others + $(to_bytes "$q")))
  done < <({ for ns in $(stand_namespaces); do kc get pods -n "$ns" -o json 2>/dev/null; done; } |
    jq -rs '.[].items[] | select(.status.phase == "Running" or .status.phase == "Pending")
      | .spec.containers[] | .resources.requests.memory // empty')
  servers=$(mcp_rendered_memory) || die "$E_DEPLOY" "failed to count the memory of MCP servers"
  alloc=$(cluster_allocatable_memory)
  capacity=$(to_bytes "$(kc get nodes -o jsonpath='{.items[0].status.capacity.memory}')")
  verdict=$(mcp_budget "$others" "$servers" "$alloc" "$capacity")
  [[ $verdict == ok ]] || die "$E_USAGE" "$verdict"
  log "memory: stand $(gib "$others") + MCP servers $(gib "$servers") of the $(gib $((alloc * 2 / 3))) GiB budget"
}

# deploy_mcp — the release mcp-servers, or its removal if all options are off (R1).
deploy_mcp() {
  step mcp
  if ! mcp_enabled; then
    if hm status "$MCP_RELEASE" -n "$NS_MCP" >/dev/null 2>&1; then
      log "all MCP servers are off: removing the release and namespace $NS_MCP"
      hm uninstall "$MCP_RELEASE" -n "$NS_MCP" --wait --timeout "$HELM_TIMEOUT" >/dev/null ||
        die "$E_DEPLOY" "failed to remove release $MCP_RELEASE"
    fi
    kc delete ns "$NS_MCP" --ignore-not-found --wait=false >/dev/null
    sync_preview_secret
    return
  fi
  mcp_load
  ensure_namespace "$NS_MCP"
  ensure_mcp_secrets
  copy_pull_secret
  local args=()
  mapfile -t args < <(mcp_helm_args)
  release_local "$MCP_RELEASE" "$NS_MCP" "$MCP_CHART_DIR" "${args[@]}"
  RELEASES[-1]="$MCP_RELEASE $MCP_CHART_VERSION"
  sync_preview_secret
  drop_disabled_secrets
  ok "MCP servers: $(mcp_enabled_list | paste -sd, -)"
}

# --- Addresses for the Nabu catalog (R5) ---

# mcp_creds_json — the mcp section of creds --json: enabled servers only.
mcp_creds_json() {
  local out='{}' srv entry
  mcp_load
  while read -r srv; do
    entry=$(jq -cn --arg u "$(mcp_url "$srv")" --arg m "$(mcp_mode "$srv")" '{url: $u, mode: $m}')
    if [[ -n ${MCP_KEY_SECRET[$srv]:-} ]]; then
      entry=$(MCP_KEY=$(secret_key "$NS_MCP" "${MCP_KEY_SECRET[$srv]}" key) \
        jq -c '. + {header: "Authorization", value: "Bearer \($ENV.MCP_KEY)"}' <<<"$entry")
    fi
    if [[ -n ${MCP_OAUTH[$srv]:-} ]]; then
      entry=$(jq -c --argjson o "${MCP_OAUTH[$srv]}" '. + {oauth: $o}' <<<"$entry")
    fi
    if [[ -n ${MCP_CATALOG_HINT[$srv]:-} ]]; then
      entry=$(jq -c --argjson h "${MCP_CATALOG_HINT[$srv]}" '. + $h' <<<"$entry")
    fi
    out=$(jq -c --arg s "$srv" --argjson e "$entry" '. + {($s): $e}' <<<"$out")
  done < <(mcp_enabled_list)
  echo "$out"
}

mcp_creds_text() {
  mcp_enabled || return 0
  mcp_load
  printf '\nMCP servers (namespace %s), to add to the Nabu catalog\n' "$NS_MCP"
  jq -r 'to_entries[] | .key as $s | .value |
    "  \($s | .[0:11] | . + (" " * (12 - length)))\(.url)   \(if .mode == "platform" then "platform" else "personal" end)",
    (if .value then "              Authorization: \(.value)" else empty end),
    (if .oauth then "              OAuth: authorize \(.oauth.authorizeUrl), token \(.oauth.tokenUrl), scope \(.oauth.scopes | join(" "))\(if .oauth.clientId then ", client_id \(.oauth.clientId)" else "" end)" else empty end),
    (if .fileArgs then "              file arguments: \(.fileArgs | map("\(.tool).\(.arg)") | join(", "))" else empty end),
    (if .resultArgs then "              result paths: \(.resultArgs | map("\(.tool).\(.arg)") | join(", ")); writes only to the space: \(.spaceOnlyTools // [] | join(", "))" else empty end)' \
    <<<"$(mcp_creds_json)"
}

# --- Checks (R5, R6) ---

mcp_probe_manifest() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mcp-probe-$PROBE_RUN
  namespace: $NS_MCP
  labels: { app.kubernetes.io/name: checks-probe, app.kubernetes.io/managed-by: installer }
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  automountServiceAccountToken: false
  containers:
    - name: curl
      image: $PROBE_CURL_IMAGE
      command: ["sh", "-c", "sleep 900"]
      env:
        - { name: PROBE, value: "1" }
EOF
  local srv
  while read -r srv; do
    [[ -n ${MCP_KEY_SECRET[$srv]:-} ]] &&
      printf '        - { name: %s, valueFrom: { secretKeyRef: { name: %s, key: key } } }\n' "$(mcp_key_var "$srv")" "${MCP_KEY_SECRET[$srv]}"
  done < <(mcp_enabled_list)
  if mcp_on docling; then
    printf '        - { name: DOCLING_SERVE_KEY, valueFrom: { secretKeyRef: { name: mcp-docling-serve-key, key: key } } }\n'
  fi
  if mcp_on docgen; then
    printf '        - { name: DOC_CONVERT_USER, valueFrom: { secretKeyRef: { name: mcp-doc-convert-auth, key: username } } }\n'
    printf '        - { name: DOC_CONVERT_PASSWORD, valueFrom: { secretKeyRef: { name: mcp-doc-convert-auth, key: password } } }\n'
  fi
  cat <<EOF
      resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { cpu: 200m, memory: 128Mi } }
      # the curl image sets its user by name (curl_user): without a numeric UID kubelet
      # cannot verify runAsNonRoot and does not start the container
      securityContext: { runAsNonRoot: true, runAsUser: 100, runAsGroup: 101, allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
EOF
}

# mcp_key_var <server> — the probe pod's environment variable with the key: search → SEARCH_KEY.
mcp_key_var() { local s=${1^^}; echo "${s//-/_}_KEY"; }

mcp_probe() { kc -n "$NS_MCP" exec "mcp-probe-$PROBE_RUN" -c curl -- sh -c "$1" 2>&1; }

# mcp_rpc_script <url> <variable with the key in the probe, or -> <method> <params JSON> —
# the JSON-RPC answer after initialize and notifications/initialized; SSE events
# are unwrapped. The key comes from the probe pod's environment and reaches curl
# through stdin (-K -): it is in neither kubectl's nor curl's argv.
mcp_rpc_script() {
  local url=$1 keyvar=$2 method=$3 params=$4
  cat <<EOF
set -e
KEY=
[ "$keyvar" != "-" ] && eval "KEY=\\\$$keyvar"
call() {
  if [ -n "\$SID" ]; then set -- -H "Mcp-Session-Id: \$SID" "\$@"; fi
  { if [ -n "\$KEY" ]; then printf 'header = "Authorization: Bearer %s"\n' "\$KEY"; fi; } |
    curl -K - -sS -m 120 -D /tmp/hdr -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \\
      -H "MCP-Protocol-Version: 2025-06-18" "\$@" "$url"
}
SID=
call -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"installer","version":"1"}}}' >/dev/null
CODE=\$(head -1 /tmp/hdr | cut -d" " -f2)
if [ "\$CODE" != "200" ]; then echo "HTTP \$CODE"; exit 0; fi
SID=\$(grep -i "^mcp-session-id:" /tmp/hdr | cut -d" " -f2 | tr -d "\\r")
call -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
call -d '{"jsonrpc":"2.0","id":2,"method":"$method","params":$params}' | sed -n "s/^data: //p;/^{/p"
EOF
}

mcp_rpc() { mcp_probe "$(mcp_rpc_script "$@")"; }

# mcp_tools <tools/list answer> — tool names.
mcp_tools() { jq -r '.result.tools[]?.name' 2>/dev/null <<<"$1" | sort | tr '\n' ' '; }

# check_mcp_server <server> — the checks of tech §2.6, each with its own record:
# mcp-<server>-tools, -auth; mcp-search-query; mcp-docling-serve-auth, mcp-docling-convert.
check_mcp_server() {
  local srv=$1 url out names
  mcp_load
  url=$(mcp_url "$srv")
  # R6, R21: without a key or token: 401
  out=$(mcp_rpc "$url" - tools/list '{}')
  if [[ $out == "HTTP 401" ]]; then
    record "mcp-$srv-auth" ok "without a $([[ $(mcp_mode "$srv") == platform ]] && echo key || echo token): 401"
  else
    record "mcp-$srv-auth" fail "expected 401 without a key, got: ${out:0:120}"
  fi
  [[ $(mcp_mode "$srv") == platform ]] || return 0
  local key
  key=$(mcp_key_var "$srv")
  out=$(mcp_rpc "$url" "$key" tools/list '{}')
  names=$(mcp_tools "$out")
  local t missing=()
  for t in ${MCP_WANT_TOOLS[$srv]:-}; do [[ " $names " == *" $t "* ]] || missing+=("$t"); done
  if [[ -z $names || ${#missing[@]} -gt 0 ]]; then
    record "mcp-$srv-tools" fail "tools/list: missing ${missing[*]:-tools}; answer: ${out:0:160}"
  else
    MCP_TOOL_COUNT[$srv]=$(wc -w <<<"$names" | tr -d ' ')
    record "mcp-$srv-tools" ok "${MCP_TOOL_COUNT[$srv]} tools"
  fi
  case $srv in
    search) check_mcp_search_query "$url" "$key" ;;
    docling) check_mcp_docling_serve ;;
    docgen) check_mcp_docgen ;;
  esac
}

# search_refusals <answer> — "limits" when SearXNG names the engines that failed and each of them refused by its
# limits (too many requests, CAPTCHA, access denied, suspended); nothing otherwise.
search_refusals() {
  local reasons
  reasons=$(jq -r '.result.content[0].text // ""' 2>/dev/null <<<"$1" | grep -o 'engines failed:.*' | grep -oE '\([^)]*\)' || true)
  [[ -n $reasons ]] || return 0
  grep -viqE 'too many requests|captcha|access denied|suspended' <<<"$reasons" || echo limits
}

check_mcp_search_query() {
  local out
  out=$(mcp_rpc "$1" "$2" tools/call '{"name":"searxng_web_search","arguments":{"query":"kubernetes"}}')
  if jq -e '.result.isError != true and ((.result.content[0].text // "") | test("http"))' >/dev/null 2>&1 <<<"$out"; then
    record mcp-search-query ok "the query kubernetes found pages"
  elif [[ $(search_refusals "$out") == limits ]]; then
    # The server works, and every engine that failed refused it by its limits (data center addresses). An engine
    # that does not answer at all stays a failure: then the network of the stand may be broken.
    record mcp-search-query warn "the server answers, but the search engines refused it: ${out:0:160}"
  else
    record mcp-search-query fail "the query kubernetes found nothing: ${out:0:160}"
  fi
}

# check_mcp_docling_serve — docling-serve answers 401 without a key, and the reference
# document converts to Markdown (R6). The document is part of the installer: the release archive has no tests/.
check_mcp_docling_serve() {
  local code html out
  code=$(mcp_probe 'curl -sS -m 10 -o /dev/null -w "%{http_code}" http://docling-serve:5001/v1/convert/source -H "Content-Type: application/json" -d "{}"')
  if [[ $code == 401 ]]; then record mcp-docling-serve-auth ok "without a key: 401"; else
    record mcp-docling-serve-auth fail "expected 401 without a key, got: $code"
  fi
  html=$(base64 -w0 "$ROOT/lib/mcp-sample.html")
  out=$(mcp_probe 'echo '"$html"' | base64 -d > /tmp/sample.html &&
    printf "header = \"X-Api-Key: %s\"\n" "$DOCLING_SERVE_KEY" | curl -K - -sS -m 300 http://docling-serve:5001/v1/convert/file \
      -F "files=@/tmp/sample.html;type=text/html" -F "to_formats=md"')
  if jq -e '.document.md_content | test("Hammurapi infra probe")' >/dev/null 2>&1 <<<"$out"; then
    record mcp-docling-convert ok "the reference document converted to Markdown"
  else
    record mcp-docling-convert fail "the reference document did not convert: ${out:0:160}"
  fi
}

# check_mcp_docgen — doc-convert answers 401 without credentials, and the reference
# HTML (with a JavaScript chart) and HTML with a link to a cluster address
# become PDF, while the link is not fetched (FTR.NAB.CHAT-0003 R22, tech §9.5).
# The probe pod sends files directly to Gotenberg: the check needs no S3 links.
check_mcp_docgen() {
  local code out
  code=$(mcp_probe 'curl -sS -m 10 -o /dev/null -w "%{http_code}" -X POST http://doc-convert:3000/forms/chromium/convert/html')
  if [[ $code == 401 ]]; then record mcp-docgen-convert-auth ok "doc-convert without credentials: 401"; else
    record mcp-docgen-convert-auth fail "doc-convert: expected 401 without credentials, got: $code"
  fi
  out=$(mcp_probe 'printf "%s" "<html><body><h1>Hammurapi infra probe</h1><canvas id=c width=200 height=100></canvas><script>var x=document.getElementById(\"c\").getContext(\"2d\");x.fillRect(10,10,80,50);window.status=\"ready\"</script></body></html>" > /tmp/index.html &&
    printf "user = \"%s:%s\"\n" "$DOC_CONVERT_USER" "$DOC_CONVERT_PASSWORD" | curl -K - -sS -m 120 -o /tmp/out.pdf -w "%{http_code}" \
      http://doc-convert:3000/forms/chromium/convert/html -F "files=@/tmp/index.html" -F "waitForExpression=window.status === '"'"'ready'"'"'" &&
    head -c 5 /tmp/out.pdf')
  if [[ $out == "200%PDF-" ]]; then record mcp-docgen-html ok "HTML with JavaScript → PDF"; else
    record mcp-docgen-html fail "HTML → PDF failed: ${out:0:120}"
  fi
  out=$(mcp_probe 'printf "%s" "<html><body><img src=\"http://docgen.'"$NS_MCP"'.svc:8000/healthz\"><iframe src=\"https://kubernetes.default.svc/api\"></iframe></body></html>" > /tmp/index.html &&
    printf "user = \"%s:%s\"\n" "$DOC_CONVERT_USER" "$DOC_CONVERT_PASSWORD" | curl -K - -sS -m 120 -o /tmp/out.pdf -w "%{http_code}" \
      http://doc-convert:3000/forms/chromium/convert/html -F "files=@/tmp/index.html"')
  # the image test (sink) proves no requests were made; this proves links to the
  # cluster and cloud metadata do not hang the conversion
  if [[ $out == 200 ]]; then record mcp-docgen-ssrf ok "HTML with links to cluster services → PDF without waiting for the network"; else
    record mcp-docgen-ssrf fail "HTML with links to the cluster: answer ${out:0:120}"
  fi
}

# check_mcp — readiness of pods and checks of enabled servers.
check_mcp() {
  # Component rollouts check only the stand (see cmd_status).
  [[ ${INSTALLER_STAND_ONLY:-} != 1 ]] || return 0
  mcp_enabled || return 0
  if ! mcp_try_load; then
    record mcp fail "$MCP_FETCH_ERROR"
    return
  fi
  local out
  if ! out=$(kc -n "$NS_MCP" wait --for=condition=Ready pod -l 'app.kubernetes.io/part-of=mcp-servers' --timeout="$CHECK_TIMEOUT" 2>&1); then
    record mcp fail "not all pods of $NS_MCP are ready: $(echo "$out" | grep -v 'condition met' | head -2 | tr '\n' ' ')"
    return
  fi
  kc -n "$NS_MCP" delete pod "mcp-probe-$PROBE_RUN" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  if ! mcp_probe_manifest | kc create -f - >/dev/null || ! kc -n "$NS_MCP" wait --for=condition=Ready "pod/mcp-probe-$PROBE_RUN" --timeout=120s >/dev/null; then
    record mcp fail "the probe pod mcp-probe did not start"
    return
  fi
  local srv
  while read -r srv; do check_mcp_server "$srv"; done < <(mcp_enabled_list)
  kc -n "$NS_MCP" delete pod "mcp-probe-$PROBE_RUN" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# mcp_status_json [deployments JSON] — the mcp section of status --json (R5):
# readiness from the server's Deployments, tool count and checks from the
# results of this run.
mcp_status_json() {
  local deploys=${1:-}
  if ! mcp_try_load; then
    jq -cn --arg e "$MCP_FETCH_ERROR" '{error: $e}'
    return
  fi
  if [[ -z $deploys ]] && mcp_enabled; then
    deploys=$(kc -n "$NS_MCP" get deploy -o json 2>/dev/null || echo '{"items":[]}')
  fi
  [[ -n $deploys ]] || deploys='{"items":[]}'
  local out='{}' srv r name state msg checks
  for srv in "${MCP_SERVERS[@]}"; do
    if ! mcp_on "$srv"; then
      out=$(jq -c --arg s "$srv" '. + {($s): {enabled: false}}' <<<"$out")
      continue
    fi
    checks='[]'
    for r in "${CHECK_RESULTS[@]}"; do
      IFS='|' read -r name state msg <<<"$r"
      [[ $name == "mcp-$srv-"* ]] || continue
      checks=$(jq -c --arg n "$name" --arg s "$state" --arg m "$msg" '. + [{name: $n, ok: ($s == "ok" or $s == "warn"), warning: ($s == "warn"), message: $m}]' <<<"$checks")
    done
    out=$(jq -c --arg s "$srv" --arg u "$(mcp_url "$srv")" --arg d "${MCP_DEPLOYMENTS[$srv]}" \
      --argjson t "${MCP_TOOL_COUNT[$srv]:-null}" --argjson c "$checks" --argjson dep "$deploys" \
      '($d | split(" ")) as $names
       | ([$dep.items[] | select(.metadata.name | IN($names[]))
           | ((.status.readyReplicas // 0) >= (.spec.replicas // 1))]) as $ready
       | . + {($s): {enabled: true, ready: (($ready | length) == ($names | length) and ($ready | all)),
            tools: $t, url: $u, checks: $c}}' <<<"$out")
  done
  echo "$out"
}
