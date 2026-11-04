# shellcheck shell=bash disable=SC2016
# SC2016: скрипты проб намеренно в одинарных кавычках — они выполняются в контейнерах.
# MCP-серверы стенда (FTR.NAB.CMN-0006, tech §2): разбор документов, веб-поиск,
# Яндекс Почта только для чтения. Каждый включается своей опцией; namespace $NS_MCP,
# один релиз mcp-servers: чарт и описания серверов — из релиза репозитория mcps. Ключи генерируются при первом `up` и хранятся только
# в секретах namespace.

MCP_RELEASE=mcp-servers

# --- Свойства серверов: описания из чарта mcp-servers репозитория mcps ---

MCP_SERVERS=()
# значение чарта, включающее сервер; сервис и порт MCP; Deployment'ы (готовность в status)
declare -gA MCP_VALUES_KEY=() MCP_SERVICE=() MCP_DEPLOYMENTS=()
# секреты, которые `up` создаёт для сервера; платформенный ключ доступа — только у платформенных
declare -gA MCP_SECRETS=() MCP_KEY_SECRET=()
# инструменты, которые проверка стенда ждёт в tools/list
declare -gA MCP_WANT_TOOLS=()
# OAuth персональных серверов и подсказки позиции каталога Nabu (creds)
declare -gA MCP_OAUTH=() MCP_CATALOG_HINT=()
# число инструментов по результатам проверок (status)
declare -gA MCP_TOOL_COUNT=()
MCP_LOADED=0

# mcp_opt <сервер> — имя опции: yandex-mail → MCP_YANDEX_MAIL.
mcp_opt() { local s=${1^^}; echo "MCP_${s//-/_}"; }

# mcp_on <сервер> — сервер включён.
mcp_on() {
  local o
  o=$(mcp_opt "$1")
  [[ " ${MCP_OPTIONS[*]} " == *" $o "* && ${!o:-false} == true ]]
}

# mcp_option_names — опции включения (load_config). Список серверов здесь не нужен:
# конфигурацию проверяем раньше, чем появляется Helm. Опция нового сервера задаётся в файле конфигурации.
mcp_option_names() { printf '%s\n' "${MCP_OPTIONS[@]}"; }

mcp_enabled() {
  local o
  while read -r o; do
    [[ ${!o:-false} == true ]] && return 0
  done < <(mcp_option_names)
  return 1
}

# mcp_fetch_chart — каталог чарта закреплённой версии: MCP_CHART_DIR или кэш выгрузки.
# Загрузка анонимная: пакет публичный, а вход в реестр мог устареть. status и creds идут
# без блокировки up, поэтому у каждого запуска свой временный каталог. При сбое — код 1,
# причина в MCP_FETCH_ERROR.
mcp_fetch_chart() {
  [[ -n ${MCP_CHART_DIR:-} ]] && return 0
  local cache=$ROOT/.cache/mcp-servers-$MCP_CHART_VERSION tmp
  if [[ ! -f $cache/Chart.yaml ]]; then
    mkdir -p "$ROOT/.cache"
    tmp=$(mktemp -d "$ROOT/.cache/pull.XXXXXX")
    if ! MCP_FETCH_ERROR=$(retry 3 10 helm pull "$MCP_CHART_REPO" --version "$MCP_CHART_VERSION" --untar --untardir "$tmp" \
      --registry-config "$tmp/registry.json" 2>&1); then
      rm -rf "$tmp"
      MCP_FETCH_ERROR="не удалось загрузить чарт $MCP_CHART_REPO $MCP_CHART_VERSION: $(tail -1 <<<"$MCP_FETCH_ERROR")"
      return 1
    fi
    # Параллельный запуск мог успеть раньше: его каталог уже готов.
    mv -T "$tmp/mcp-servers" "$cache" 2>/dev/null || true
    rm -rf "$tmp"
  fi
  MCP_CHART_DIR=$cache
}

# mcp_try_load — описания серверов из чарта; код 1, если чарт недоступен. Пока ни один
# сервер не включён, чарт не нужен.
mcp_try_load() {
  ((MCP_LOADED)) && return 0
  mcp_enabled || return 0
  mcp_fetch_chart || return 1
  local f srv o known=" "
  MCP_SERVERS=()
  for f in "$MCP_CHART_DIR"/files/servers/*.json; do
    if [[ ! -f $f ]]; then
      MCP_FETCH_ERROR="в чарте $MCP_CHART_DIR нет описаний серверов"
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
  # Включённая опция без сервера — опечатка или сервер убран из чарта.
  while read -r o; do
    if [[ ${!o:-false} == true && $known != *" $o "* ]]; then
      MCP_FETCH_ERROR="$o: в чарте mcp-servers $MCP_CHART_VERSION нет такого сервера"
      MCP_FETCH_CODE=$E_USAGE
      return 1
    fi
  done < <(mcp_option_names)
  MCP_LOADED=1
}

# mcp_load — то же, но без чарта установка продолжаться не может.
mcp_load() { mcp_try_load || die "${MCP_FETCH_CODE:-$E_DEPLOY}" "$MCP_FETCH_ERROR"; }

# mcp_enabled_list — включённые серверы по одному в строке.
mcp_enabled_list() {
  local s
  mcp_load
  for s in "${MCP_SERVERS[@]}"; do if mcp_on "$s"; then echo "$s"; fi; done
}

mcp_url() { mcp_load; echo "http://${MCP_SERVICE[$1]%%:*}.$NS_MCP.svc:${MCP_SERVICE[$1]##*:}/mcp"; }

mcp_mode() { mcp_load; if [[ -n ${MCP_KEY_SECRET[$1]:-} ]]; then echo platform; else echo personal; fi; }

# validate_mcp_config — опции и параметры серверов (R1).
validate_mcp_config() {
  local o
  while read -r o; do
    case ${!o:-false} in
      true | false) ;;
      *) die "$E_USAGE" "$o должен быть true или false, а не «${!o}»" ;;
    esac
  done < <(mcp_option_names)
  if ! [[ $MCP_DOCLING_MAX_MB =~ ^[0-9]+$ ]] || ((MCP_DOCLING_MAX_MB < 1 || MCP_DOCLING_MAX_MB > 200)); then
    die "$E_USAGE" "MCP_DOCLING_MAX_MB: целое число мегабайт от 1 до 200"
  fi
  [[ $MCP_SEARCH_ENGINES =~ ^[a-z0-9_]+(,[a-z0-9_]+)*$ ]] ||
    die "$E_USAGE" "MCP_SEARCH_ENGINES: имена систем SearXNG через запятую, например duckduckgo,bing"
}

# mcp_helm_args — включение серверов и параметры конфигурации. Образы и их версии —
# в значениях чарта, закреплённого MCP_CHART_VERSION.
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

# ensure_mcp_secrets — ключи включённых серверов; существующие не меняются (STD-12).
ensure_mcp_secrets() {
  local srv name
  mcp_load
  while read -r srv; do
    for name in ${MCP_SECRETS[$srv]:-}; do
      if [[ $name == mcp-doc-convert-auth ]]; then
        # базовая аутентификация Gotenberg и legacy (FTR.NAB.CHAT-0003 tech §9.2)
        ensure_secret "$NS_MCP" "$name" Opaque username docconvert password "$(gen_key)"
      else
        ensure_secret "$NS_MCP" "$name" Opaque key "$(gen_key)"
      fi
    done
  done < <(mcp_enabled_list)
}

# sync_preview_secret — секрет nabu-docs-preview для api Nabu (FTR.NAB.CHAT-0003
# tech §9.2): адреса и учётные данные doc-convert и docgen, пока включён
# сервис документов; без него предпросмотр офисных файлов выключен. api
# перезапускается, только если секрет изменился.
sync_preview_secret() {
  local ns=${NABU_NAMESPACE:-nabu} before after
  kc get ns "$ns" >/dev/null 2>&1 || return 0
  before=$(kc -n "$ns" get secret nabu-docs-preview -o jsonpath='{.data}' 2>/dev/null || true)
  if ! mcp_on docgen; then
    [[ -z $before ]] && return 0
    kc -n "$ns" delete secret nabu-docs-preview --ignore-not-found >/dev/null
  else
    # секреты идут в jq через окружение, не через argv
    PREVIEW_USER=$(secret_key "$NS_MCP" mcp-doc-convert-auth username) \
    PREVIEW_PASS=$(secret_key "$NS_MCP" mcp-doc-convert-auth password) \
    PREVIEW_KEY=$(secret_key "$NS_MCP" mcp-docgen-key key) \
    jq -cn --arg ns "$ns" --arg mcp "$NS_MCP" \
      '$ENV.PREVIEW_USER as $user | $ENV.PREVIEW_PASS as $pass | $ENV.PREVIEW_KEY as $key | {apiVersion: "v1", kind: "Secret", type: "Opaque",
        metadata: {name: "nabu-docs-preview", namespace: $ns, labels: {"app.kubernetes.io/managed-by": "hammurapi-infra"}},
        stringData: {PREVIEW_CONVERT_URL: "http://doc-convert.\($mcp).svc:3000", PREVIEW_CONVERT_USER: $user, PREVIEW_CONVERT_PASSWORD: $pass,
          PREVIEW_LEGACY_URL: "http://doc-convert.\($mcp).svc:3001", PREVIEW_DOCGEN_URL: "http://docgen.\($mcp).svc:8000", PREVIEW_DOCGEN_KEY: $key}}' |
      apply_stdin
  fi
  after=$(kc -n "$ns" get secret nabu-docs-preview -o jsonpath='{.data}' 2>/dev/null || true)
  if [[ $before != "$after" ]] && kc -n "$ns" get deploy api >/dev/null 2>&1; then
    kc -n "$ns" rollout restart deploy/api >/dev/null && log "api Nabu перезапущен: изменились настройки предпросмотра"
  fi
}

# drop_disabled_secrets — ключи выключенных серверов (STD-03); только после
# релиза, который на них уже не ссылается.
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

# copy_pull_secret — ghcr-pull из namespace Nabu: собранные образы лежат в
# ghcr.io/greenongrey, как образы Nabu.
copy_pull_secret() {
  local src
  src=$(kc -n nabu get secret ghcr-pull -o json 2>/dev/null) || {
    warn "нет секрета nabu/ghcr-pull: образы загружаются без него"
    return 0
  }
  jq -c --arg ns "$NS_MCP" '{apiVersion: "v1", kind: "Secret", type: .type, data: .data,
    metadata: {name: "ghcr-pull", namespace: $ns, labels: {"app.kubernetes.io/managed-by": "hammurapi-infra"}}}' <<<"$src" |
    apply_stdin
}

# mcp_rendered_memory — сумма запросов памяти контейнеров включённых серверов, байты.
# Рендер чарта переводится в JSON kubectl (client dry-run): на машине стенда есть
# jq, но нет yq.
mcp_rendered_memory() {
  local args=() rendered
  mapfile -t args < <(mcp_helm_args)
  rendered=$(hm template "$MCP_RELEASE" "$MCP_CHART_DIR" -n "$NS_MCP" "${args[@]}") ||
    die "$E_DEPLOY" "чарт mcp-servers не рендерится"
  kc create --dry-run=client -o json -f - <<<"$rendered" |
    jq -r '(if .kind == "List" then .items[] else . end) | select(.kind == "Deployment")
      | .spec.template.spec.containers[] | .resources.requests.memory // empty' |
    while read -r q; do to_bytes "$q"; done |
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
  printf 'MCP-серверам не хватает %s ГиБ памяти стенда: нужен MK_MEMORY=%sg (сейчас %s). Профиль minikube пересоздаётся: ./installer down, затем up\n' \
    "$(gib $((need - limit)))" "$want_gib" "$MK_MEMORY"
}

# mcp_preflight — бюджет памяти до любых изменений стенда (R3: «ничего не
# меняя»). Считаются поды стенда (namespace проверки resources) и включённые
# серверы; при первом `up` подов ещё нет — считаются только серверы.
mcp_preflight() {
  mcp_enabled || return 0
  mcp_load
  local others=0 q servers alloc capacity verdict
  while read -r q; do
    [[ -n $q ]] && others=$((others + $(to_bytes "$q")))
  done < <({ kc get pods -n "$NS_STORAGES" -o json 2>/dev/null; kc get pods -n "$NS_OBSERVABILITY" -o json 2>/dev/null; } |
    jq -rs '.[].items[] | select(.status.phase == "Running" or .status.phase == "Pending")
      | .spec.containers[] | .resources.requests.memory // empty')
  servers=$(mcp_rendered_memory) || die "$E_DEPLOY" "не удалось посчитать память MCP-серверов"
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
    sync_preview_secret
    return
  fi
  mcp_load
  kc create ns "$NS_MCP" --dry-run=client -o json |
    jq '.metadata.labels["app.kubernetes.io/part-of"] = "hammurapi-stand"' | apply_stdin
  ensure_mcp_secrets
  copy_pull_secret
  local args=()
  mapfile -t args < <(mcp_helm_args)
  release_local "$MCP_RELEASE" "$NS_MCP" "$MCP_CHART_DIR" "${args[@]}"
  RELEASES[-1]="$MCP_RELEASE $MCP_CHART_VERSION"
  sync_preview_secret
  drop_disabled_secrets
  ok "MCP-серверы: $(mcp_enabled_list | paste -sd, -)"
}

# --- Адреса для каталога Nabu (R5) ---

# mcp_creds_json — раздел mcp вывода creds --json: только включённые серверы.
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
  printf '\nMCP-серверы (namespace %s) — вносятся в каталог Nabu\n' "$NS_MCP"
  jq -r 'to_entries[] | .key as $s | .value |
    "  \($s | .[0:11] | . + (" " * (12 - length)))\(.url)   \(if .mode == "platform" then "платформенный" else "персональный" end)",
    (if .value then "              Authorization: \(.value)" else empty end),
    (if .oauth then "              OAuth: authorize \(.oauth.authorizeUrl), token \(.oauth.tokenUrl), scope \(.oauth.scopes | join(" "))\(if .oauth.clientId then ", client_id \(.oauth.clientId)" else "" end)" else empty end),
    (if .fileArgs then "              файловые аргументы: \(.fileArgs | map("\(.tool).\(.arg)") | join(", "))" else empty end),
    (if .resultArgs then "              пути результата: \(.resultArgs | map("\(.tool).\(.arg)") | join(", ")); пишет только в пространство: \(.spaceOnlyTools // [] | join(", "))" else empty end)' \
    <<<"$(mcp_creds_json)"
}

# --- Проверки (R5, R6) ---

mcp_probe_manifest() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mcp-probe-$PROBE_RUN
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
  if mcp_on docgen; then
    printf '        - { name: DOC_CONVERT_USER, valueFrom: { secretKeyRef: { name: mcp-doc-convert-auth, key: username } } }\n'
    printf '        - { name: DOC_CONVERT_PASSWORD, valueFrom: { secretKeyRef: { name: mcp-doc-convert-auth, key: password } } }\n'
  fi
  cat <<EOF
      resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { cpu: 200m, memory: 128Mi } }
      # у образа curl пользователь задан именем (curl_user): без числового UID kubelet
      # не может проверить runAsNonRoot и не запускает контейнер
      securityContext: { runAsNonRoot: true, runAsUser: 100, runAsGroup: 101, allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
EOF
}

# mcp_key_var <сервер> — переменная окружения пробного пода с ключом: search → SEARCH_KEY.
mcp_key_var() { local s=${1^^}; echo "${s//-/_}_KEY"; }

mcp_probe() { kc -n "$NS_MCP" exec "mcp-probe-$PROBE_RUN" -c curl -- sh -c "$1" 2>&1; }

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
call -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"installer","version":"1"}}}' >/dev/null
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
  mcp_load
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
    docgen) check_mcp_docgen ;;
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

# check_mcp_docgen — doc-convert без учётных данных отвечает 401, эталонные
# HTML (с графиком на JavaScript) и HTML со ссылкой на адрес кластера
# превращаются в PDF, а ссылка не загружается (FTR.NAB.CHAT-0003 R22, tech §9.5).
# Пробный под шлёт файлы прямо в Gotenberg: ссылки S3 проверке не нужны.
check_mcp_docgen() {
  local code out
  code=$(mcp_probe 'curl -sS -m 10 -o /dev/null -w "%{http_code}" -X POST http://doc-convert:3000/forms/chromium/convert/html')
  if [[ $code == 401 ]]; then record mcp-docgen-convert-auth ok "doc-convert без учётных данных — 401"; else
    record mcp-docgen-convert-auth fail "doc-convert без учётных данных ожидался 401, ответ: $code"
  fi
  out=$(mcp_probe 'printf "%s" "<html><body><h1>Hammurapi infra probe</h1><canvas id=c width=200 height=100></canvas><script>var x=document.getElementById(\"c\").getContext(\"2d\");x.fillRect(10,10,80,50);window.status=\"ready\"</script></body></html>" > /tmp/index.html &&
    printf "user = \"%s:%s\"\n" "$DOC_CONVERT_USER" "$DOC_CONVERT_PASSWORD" | curl -K - -sS -m 120 -o /tmp/out.pdf -w "%{http_code}" \
      http://doc-convert:3000/forms/chromium/convert/html -F "files=@/tmp/index.html" -F "waitForExpression=window.status === '"'"'ready'"'"'" &&
    head -c 5 /tmp/out.pdf')
  if [[ $out == "200%PDF-" ]]; then record mcp-docgen-html ok "HTML с JavaScript → PDF"; else
    record mcp-docgen-html fail "HTML → PDF не получился: ${out:0:120}"
  fi
  out=$(mcp_probe 'printf "%s" "<html><body><img src=\"http://docgen.'"$NS_MCP"'.svc:8000/healthz\"><iframe src=\"https://kubernetes.default.svc/api\"></iframe></body></html>" > /tmp/index.html &&
    printf "user = \"%s:%s\"\n" "$DOC_CONVERT_USER" "$DOC_CONVERT_PASSWORD" | curl -K - -sS -m 120 -o /tmp/out.pdf -w "%{http_code}" \
      http://doc-convert:3000/forms/chromium/convert/html -F "files=@/tmp/index.html"')
  # что запросов не было, доказывает тест образа (sink); здесь — что ссылки на
  # кластер и метаданные облака не вешают конвертацию
  if [[ $out == 200 ]]; then record mcp-docgen-ssrf ok "HTML со ссылками на сервисы кластера → PDF без ожидания сети"; else
    record mcp-docgen-ssrf fail "HTML со ссылками на кластер: ответ ${out:0:120}"
  fi
}

# check_mcp — готовность подов и проверки включённых серверов.
check_mcp() {
  mcp_enabled || return 0
  if ! mcp_try_load; then
    record mcp fail "$MCP_FETCH_ERROR"
    return
  fi
  local out
  if ! out=$(kc -n "$NS_MCP" wait --for=condition=Ready pod -l 'app.kubernetes.io/part-of=mcp-servers' --timeout="$CHECK_TIMEOUT" 2>&1); then
    record mcp fail "не все поды $NS_MCP готовы: $(echo "$out" | grep -v 'condition met' | head -2 | tr '\n' ' ')"
    return
  fi
  kc -n "$NS_MCP" delete pod "mcp-probe-$PROBE_RUN" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  if ! mcp_probe_manifest | kc create -f - >/dev/null || ! kc -n "$NS_MCP" wait --for=condition=Ready "pod/mcp-probe-$PROBE_RUN" --timeout=120s >/dev/null; then
    record mcp fail "не запустился пробный под mcp-probe"
    return
  fi
  local srv
  while read -r srv; do check_mcp_server "$srv"; done < <(mcp_enabled_list)
  kc -n "$NS_MCP" delete pod "mcp-probe-$PROBE_RUN" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# mcp_status_json [deployments JSON] — раздел mcp вывода status --json (R5):
# готовность — по Deployment'ам сервера, число инструментов и проверки — по
# результатам проверок этого запуска.
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
