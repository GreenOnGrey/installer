# shellcheck shell=bash disable=SC2016
# SC2016: скрипты проб намеренно в одинарных кавычках — они выполняются в контейнерах.
# MCP-серверы стенда (FTR.NAB.CMN-0006, tech §2): разбор документов, веб-поиск,
# Яндекс Почта только для чтения. Каждый включается своей опцией; namespace $NS_MCP,
# один релиз mcp-servers. Ключи генерируются при первом `up` и хранятся только
# в секретах namespace.

MCP_RELEASE=mcp-servers

# --- Свойства серверов: одна таблица вместо ветвлений по серверу ---

MCP_SERVERS=(docling search yandex-mail)
# сервис и порт MCP; Deployment'ы сервера (готовность в status)
declare -gA MCP_SERVICE=([docling]=docling-mcp:8080 [search]=search:3000 [yandex-mail]=yandex-mail:8000)
declare -gA MCP_DEPLOYMENTS=([docling]="docling-mcp docling-serve" [search]=search [yandex-mail]=yandex-mail)
# секреты, которые `up` создаёт для сервера
declare -gA MCP_SECRETS=([docling]="mcp-docling-serve-key mcp-docling-key" [search]="mcp-search-key mcp-searxng-secret")
# платформенный ключ доступа (секрет) — только у платформенных серверов
declare -gA MCP_KEY_SECRET=([docling]=mcp-docling-key [search]=mcp-search-key)
# инструменты, которые проверка стенда ждёт в tools/list
declare -gA MCP_WANT_TOOLS=([docling]="convert_document_into_docling_document export_docling_document_to_markdown"
  [search]="searxng_web_search web_url_read")
# OAuth персональных серверов для каталога Nabu (creds)
declare -gA MCP_OAUTH=(
  [yandex-mail]='{"authorizeUrl":"https://oauth.yandex.ru/authorize","tokenUrl":"https://oauth.yandex.ru/token","scopes":["mail:imap_ro","login:email"]}')
# подсказки позиции каталога: разрешённые инструменты и файловые аргументы (README, «Внесение в каталог»)
declare -gA MCP_CATALOG_HINT=(
  [docling]='{"allowedTools":["convert_document_into_docling_document","export_docling_document_to_markdown","get_overview_of_document_anchors","search_for_text_in_document_anchors","get_text_of_document_item_at_anchor"],"fileArgs":[{"tool":"convert_document_into_docling_document","arg":"source"}]}')
# число инструментов по результатам проверок (status)
declare -gA MCP_TOOL_COUNT=()

# mcp_opt <сервер> — имя опции: yandex-mail → MCP_YANDEX_MAIL.
mcp_opt() { local s=${1^^}; echo "MCP_${s//-/_}"; }

# mcp_on <сервер> — сервер включён.
mcp_on() { local o; o=$(mcp_opt "$1"); [[ ${!o:-false} == true ]]; }

mcp_enabled() {
  local s
  for s in "${MCP_SERVERS[@]}"; do mcp_on "$s" && return 0; done
  return 1
}

# mcp_enabled_list — включённые серверы по одному в строке.
mcp_enabled_list() {
  local s
  for s in "${MCP_SERVERS[@]}"; do if mcp_on "$s"; then echo "$s"; fi; done
}

mcp_url() { echo "http://${MCP_SERVICE[$1]%%:*}.$NS_MCP.svc:${MCP_SERVICE[$1]##*:}/mcp"; }

mcp_mode() { if [[ -n ${MCP_KEY_SECRET[$1]:-} ]]; then echo platform; else echo personal; fi; }

# validate_mcp_config — опции и параметры серверов (R1).
validate_mcp_config() {
  local s o
  for s in "${MCP_SERVERS[@]}"; do
    o=$(mcp_opt "$s")
    case ${!o:-false} in
      true | false) ;;
      *) die "$E_USAGE" "$o должен быть true или false, а не «${!o}»" ;;
    esac
  done
  if ! [[ $MCP_DOCLING_MAX_MB =~ ^[0-9]+$ ]] || ((MCP_DOCLING_MAX_MB < 1 || MCP_DOCLING_MAX_MB > 200)); then
    die "$E_USAGE" "MCP_DOCLING_MAX_MB: целое число мегабайт от 1 до 200"
  fi
  [[ $MCP_SEARCH_ENGINES =~ ^[a-z0-9_]+(,[a-z0-9_]+)*$ ]] ||
    die "$E_USAGE" "MCP_SEARCH_ENGINES: имена систем SearXNG через запятую, например duckduckgo,bing"
}

# mcp_helm_args — значения чарта из конфигурации и config/versions.env.
mcp_helm_args() {
  local engines
  engines=$(tr ',' '\n' <<<"$MCP_SEARCH_ENGINES" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null ||
    printf '[]')
  local docling search yandex
  docling=$(mcp_on docling && echo true || echo false)
  search=$(mcp_on search && echo true || echo false)
  yandex=$(mcp_on yandex-mail && echo true || echo false)
  printf '%s\n' \
    --set "docling.enabled=$docling" --set "search.enabled=$search" \
    --set "yandexMail.enabled=$yandex" \
    --set-string "docling.serve.image=$DOCLING_SERVE_IMAGE" \
    --set-string "docling.mcp.image=$MCP_IMAGE_REGISTRY/docling-mcp:$DOCLING_MCP_VERSION" \
    --set-string "docling.auth.image=$MCP_PROXY_IMAGE" \
    --set "docling.serve.maxFileMB=$MCP_DOCLING_MAX_MB" \
    --set-string "search.mcp.image=$MCP_SEARXNG_IMAGE" \
    --set-string "search.searxng.image=$SEARXNG_IMAGE" \
    --set-json "search.engines=$engines" \
    --set-string "yandexMail.image=$MCP_IMAGE_REGISTRY/imap-mcp:$IMAP_MCP_VERSION" \
    --set-string "s3.namespace=$NS_STORAGES"
}

gen_key() { openssl rand -hex 32; }

# ensure_mcp_secrets — ключи включённых серверов; существующие не меняются (STD-12).
ensure_mcp_secrets() {
  local srv name
  while read -r srv; do
    for name in ${MCP_SECRETS[$srv]:-}; do
      ensure_secret "$NS_MCP" "$name" Opaque key "$(gen_key)"
    done
  done < <(mcp_enabled_list)
}

# drop_disabled_secrets — ключи выключенных серверов (STD-03); только после
# релиза, который на них уже не ссылается.
drop_disabled_secrets() {
  local srv name
  for srv in "${MCP_SERVERS[@]}"; do
    mcp_on "$srv" && continue
    for name in ${MCP_SECRETS[$srv]:-}; do
      kc -n "$NS_MCP" delete secret "$name" --ignore-not-found >/dev/null
    done
  done
}

# copy_pull_secret — ghcr-pull из namespace Nabu: собранные образы лежат в
# $MCP_IMAGE_REGISTRY, как образы Nabu.
copy_pull_secret() {
  local src
  src=$(kc -n nabu get secret ghcr-pull -o json 2>/dev/null) || {
    warn "нет секрета nabu/ghcr-pull: образы $MCP_IMAGE_REGISTRY должны быть доступны без него"
    return 0
  }
  jq -c --arg ns "$NS_MCP" '{apiVersion: "v1", kind: "Secret", type: .type, data: .data,
    metadata: {name: "ghcr-pull", namespace: $ns, labels: {"app.kubernetes.io/managed-by": "hammurapi-infra"}}}' <<<"$src" |
    apply_stdin
}

# mcp_rendered_memory — сумма запросов памяти контейнеров включённых серверов, байты.
mcp_rendered_memory() {
  local args=()
  mapfile -t args < <(mcp_helm_args)
  helm template "$MCP_RELEASE" "$ROOT/charts/mcp-servers" -n "$NS_MCP" "${args[@]}" 2>/dev/null |
    yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | .resources.requests.memory' |
    while read -r q; do [[ -n $q && $q != null ]] && to_bytes "$q"; done |
    awk '{ s += $1 } END { print s + 0 }'
}

# mcp_budget <запрошено вне mcp> <серверы> <allocatable> <ёмкость> — «ok» или
# сообщение с недостающим объёмом и нужным MK_MEMORY (R3, STD-09).
mcp_budget() {
  local others=$1 servers=$2 alloc=$3 capacity=$4
  local need=$((others + servers)) limit=$((alloc * 2 / 3))
  if ((need <= limit)); then
    echo ok
    return
  fi
  local system=$((capacity - alloc))
  # память ноды, при которой need — две трети allocatable, плюс системная часть
  local want_gib=$(((need * 3 / 2 + system + 1073741823) / 1073741824))
  printf 'MCP-серверам не хватает %s ГиБ памяти стенда: нужен MK_MEMORY=%sg (сейчас %s). Профиль minikube пересоздаётся: ./hammurapi-infra.sh down, затем up\n' \
    "$(gib $((need - limit)))" "$want_gib" "$MK_MEMORY"
}

# mcp_preflight — бюджет памяти до любых изменений стенда (R3: «ничего не
# меняя»). Считаются поды стенда (namespace проверки resources) и включённые
# серверы; при первом `up` подов ещё нет — считаются только серверы.
mcp_preflight() {
  mcp_enabled || return 0
  local others=0 q servers alloc capacity verdict
  while read -r q; do
    [[ -n $q ]] && others=$((others + $(to_bytes "$q")))
  done < <({ kc get pods -n "$NS_STORAGES" -o json 2>/dev/null; kc get pods -n "$NS_OBSERVABILITY" -o json 2>/dev/null; } |
    jq -rs '.[].items[] | select(.status.phase == "Running" or .status.phase == "Pending")
      | .spec.containers[] | .resources.requests.memory // empty')
  servers=$(mcp_rendered_memory)
  alloc=$(to_bytes "$(kc get nodes -o jsonpath='{.items[0].status.allocatable.memory}')")
  capacity=$(to_bytes "$(kc get nodes -o jsonpath='{.items[0].status.capacity.memory}')")
  verdict=$(mcp_budget "$others" "$servers" "$alloc" "$capacity")
  [[ $verdict == ok ]] || die "$E_USAGE" "$verdict"
  log "память: стенд $(gib "$others") + MCP-серверы $(gib "$servers") из $(gib $((alloc * 2 / 3))) ГиБ бюджета"
}

# deploy_mcp — релиз mcp-servers или его удаление, если все опции выключены (R1).
deploy_mcp() {
  step mcp
  if ! mcp_enabled; then
    if hm status "$MCP_RELEASE" -n "$NS_MCP" >/dev/null 2>&1; then
      log "все MCP-серверы выключены: удаление релиза и namespace $NS_MCP"
      hm uninstall "$MCP_RELEASE" -n "$NS_MCP" --wait --timeout "$HELM_TIMEOUT" >/dev/null ||
        die "$E_DEPLOY" "не удалось удалить релиз $MCP_RELEASE"
    fi
    kc delete ns "$NS_MCP" --ignore-not-found --wait=false >/dev/null
    return
  fi
  kc create ns "$NS_MCP" --dry-run=client -o yaml |
    yq '.metadata.labels."app.kubernetes.io/part-of" = "hammurapi-stand"' | apply_stdin
  ensure_mcp_secrets
  copy_pull_secret
  local args=()
  mapfile -t args < <(mcp_helm_args)
  release_local "$MCP_RELEASE" "$NS_MCP" "$ROOT/charts/mcp-servers" "${args[@]}"
  drop_disabled_secrets
  ok "MCP-серверы: $(mcp_enabled_list | paste -sd, -)"
}

# --- Адреса для каталога Nabu (R5) ---

# mcp_creds_json — раздел mcp вывода creds --json: только включённые серверы.
mcp_creds_json() {
  local out='{}' srv entry
  while read -r srv; do
    entry=$(jq -cn --arg u "$(mcp_url "$srv")" --arg m "$(mcp_mode "$srv")" '{url: $u, mode: $m}')
    if [[ -n ${MCP_KEY_SECRET[$srv]:-} ]]; then
      entry=$(jq -c --arg k "$(secret_key "$NS_MCP" "${MCP_KEY_SECRET[$srv]}" key)" \
        '. + {header: "Authorization", value: "Bearer \($k)"}' <<<"$entry")
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
  printf '\nMCP-серверы (namespace %s) — вносятся в каталог Nabu\n' "$NS_MCP"
  jq -r 'to_entries[] | .key as $s | .value |
    "  \($s | .[0:11] | . + (" " * (12 - length)))\(.url)   \(if .mode == "platform" then "платформенный" else "персональный" end)",
    (if .value then "              Authorization: \(.value)" else empty end),
    (if .oauth then "              OAuth: authorize \(.oauth.authorizeUrl), token \(.oauth.tokenUrl), scope \(.oauth.scopes | join(" "))\(if .oauth.clientId then ", client_id \(.oauth.clientId)" else "" end)" else empty end),
    (if .fileArgs then "              файловые аргументы: \(.fileArgs | map("\(.tool).\(.arg)") | join(", "))" else empty end)' \
    <<<"$(mcp_creds_json)"
}

# --- Проверки (R5, R6) ---

mcp_probe_manifest() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mcp-probe
  namespace: $NS_MCP
  labels: { app.kubernetes.io/name: checks-probe, app.kubernetes.io/managed-by: hammurapi-infra }
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
  cat <<EOF
      resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { cpu: 200m, memory: 128Mi } }
      securityContext: { runAsNonRoot: true, allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
EOF
}

# mcp_key_var <сервер> — переменная окружения пробного пода с ключом: search → SEARCH_KEY.
mcp_key_var() { local s=${1^^}; echo "${s//-/_}_KEY"; }

mcp_probe() { kc -n "$NS_MCP" exec mcp-probe -c curl -- sh -c "$1" 2>&1; }

# mcp_rpc_script <url> <переменная с ключом в пробе или -> <метод> <params JSON> —
# ответ JSON-RPC после initialize и notifications/initialized; события SSE
# разворачиваются. Ключ берётся из окружения пробного пода и передаётся curl
# через stdin (-K -): ни в argv kubectl, ни в argv curl его нет.
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
call -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hammurapi-infra","version":"1"}}}' >/dev/null
CODE=\$(head -1 /tmp/hdr | cut -d" " -f2)
if [ "\$CODE" != "200" ]; then echo "HTTP \$CODE"; exit 0; fi
SID=\$(grep -i "^mcp-session-id:" /tmp/hdr | cut -d" " -f2 | tr -d "\\r")
call -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
call -d '{"jsonrpc":"2.0","id":2,"method":"$method","params":$params}' | sed -n "s/^data: //p;/^{/p"
EOF
}

mcp_rpc() { mcp_probe "$(mcp_rpc_script "$@")"; }

# mcp_tools <ответ tools/list> — имена инструментов.
mcp_tools() { jq -r '.result.tools[]?.name' 2>/dev/null <<<"$1" | sort | tr '\n' ' '; }

# check_mcp_server <сервер> — проверки tech §2.6, каждая своей записью:
# mcp-<сервер>-tools, -auth; mcp-search-query; mcp-docling-serve-auth, mcp-docling-convert.
check_mcp_server() {
  local srv=$1 url out names
  url=$(mcp_url "$srv")
  # R6, R21: без ключа или токена — 401
  out=$(mcp_rpc "$url" - tools/list '{}')
  if [[ $out == "HTTP 401" ]]; then
    record "mcp-$srv-auth" ok "без $([[ $(mcp_mode "$srv") == platform ]] && echo ключа || echo токена) — 401"
  else
    record "mcp-$srv-auth" fail "без ключа ожидался 401, ответ: ${out:0:120}"
  fi
  [[ $(mcp_mode "$srv") == platform ]] || return 0
  local key
  key=$(mcp_key_var "$srv")
  out=$(mcp_rpc "$url" "$key" tools/list '{}')
  names=$(mcp_tools "$out")
  local t missing=()
  for t in ${MCP_WANT_TOOLS[$srv]:-}; do [[ " $names " == *" $t "* ]] || missing+=("$t"); done
  if [[ -z $names || ${#missing[@]} -gt 0 ]]; then
    record "mcp-$srv-tools" fail "tools/list: нет ${missing[*]:-инструментов}; ответ: ${out:0:160}"
  else
    MCP_TOOL_COUNT[$srv]=$(wc -w <<<"$names" | tr -d ' ')
    record "mcp-$srv-tools" ok "${MCP_TOOL_COUNT[$srv]} инструментов"
  fi
  case $srv in
    search) check_mcp_search_query "$url" "$key" ;;
    docling) check_mcp_docling_serve ;;
  esac
}

check_mcp_search_query() {
  local out
  out=$(mcp_rpc "$1" "$2" tools/call '{"name":"searxng_web_search","arguments":{"query":"kubernetes"}}')
  if jq -e '.result.isError != true and ((.result.content[0].text // "") | test("http"))' >/dev/null 2>&1 <<<"$out"; then
    record mcp-search-query ok "запрос «kubernetes» нашёл страницы"
  else
    record mcp-search-query fail "запрос «kubernetes» без результатов: ${out:0:160}"
  fi
}

# check_mcp_docling_serve — docling-serve без ключа отвечает 401, эталонный
# документ разбирается в Markdown (R6).
check_mcp_docling_serve() {
  local code html out
  code=$(mcp_probe 'curl -sS -m 10 -o /dev/null -w "%{http_code}" http://docling-serve:5001/v1/convert/source -H "Content-Type: application/json" -d "{}"')
  if [[ $code == 401 ]]; then record mcp-docling-serve-auth ok "без ключа — 401"; else
    record mcp-docling-serve-auth fail "без ключа ожидался 401, ответ: $code"
  fi
  html=$(base64 -w0 "$ROOT/tests/fixtures/mcp/sample.html")
  out=$(mcp_probe 'echo '"$html"' | base64 -d > /tmp/sample.html &&
    printf "header = \"X-Api-Key: %s\"\n" "$DOCLING_SERVE_KEY" | curl -K - -sS -m 300 http://docling-serve:5001/v1/convert/file \
      -F "files=@/tmp/sample.html;type=text/html" -F "to_formats=md"')
  if jq -e '.document.md_content | test("Hammurapi infra probe")' >/dev/null 2>&1 <<<"$out"; then
    record mcp-docling-convert ok "эталонный документ разобран в Markdown"
  else
    record mcp-docling-convert fail "эталонный документ не разобран: ${out:0:160}"
  fi
}

# check_mcp — готовность подов и проверки включённых серверов.
check_mcp() {
  mcp_enabled || return 0
  local out
  if ! out=$(kc -n "$NS_MCP" wait --for=condition=Ready pod -l 'app.kubernetes.io/part-of=mcp-servers' --timeout="$CHECK_TIMEOUT" 2>&1); then
    record mcp fail "не все поды $NS_MCP готовы: $(echo "$out" | grep -v 'condition met' | head -2 | tr '\n' ' ')"
    return
  fi
  kc -n "$NS_MCP" delete pod mcp-probe --ignore-not-found --wait=true >/dev/null 2>&1 || true
  if ! mcp_probe_manifest | kc create -f - >/dev/null || ! kc -n "$NS_MCP" wait --for=condition=Ready pod/mcp-probe --timeout=120s >/dev/null; then
    record mcp fail "не запустился пробный под mcp-probe"
    return
  fi
  local srv
  while read -r srv; do check_mcp_server "$srv"; done < <(mcp_enabled_list)
  kc -n "$NS_MCP" delete pod mcp-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# mcp_status_json [deployments JSON] — раздел mcp вывода status --json (R5):
# готовность — по Deployment'ам сервера, число инструментов и проверки — по
# результатам проверок этого запуска.
mcp_status_json() {
  local deploys=${1:-}
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
      checks=$(jq -c --arg n "$name" --arg s "$state" --arg m "$msg" '. + [{name: $n, ok: ($s == "ok"), message: $m}]' <<<"$checks")
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
