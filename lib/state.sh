# shellcheck shell=bash
# Состояние установки (FTR.INFRA.INST-0001 tech §9): ConfigMap'ы namespace $NS_STATE. Прежние
# места (ingress, observability) читаются, пока их не заменит следующий `up`, и остаются: выгрузка
# старого тега при откате читает именно их. Удалим их, когда откат на такие теги перестанет быть нужен.

readonly STATE_PUBLIC_CM=installer-public STATE_VERSION_CM=installer-version STATE_CONFIG_CM=installer-config

# state_data <ConfigMap> [<прежний namespace> <прежнее имя>] — .data в JSON или пусто.
state_data() {
  local out
  out=$(kc -n "$NS_STATE" get configmap "$1" -o json 2>/dev/null | jq -c '.data // empty' 2>/dev/null || true)
  if [[ -z $out && $# -gt 1 ]]; then
    out=$(kc -n "$2" get configmap "$3" -o json 2>/dev/null | jq -c '.data // empty' 2>/dev/null || true)
  fi
  printf '%s' "$out"
}

state_public() { state_data "$STATE_PUBLIC_CM" "$NS_INGRESS" hammurapi-infra-public; }
state_version() { state_data "$STATE_VERSION_CM" "$NS_OBSERVABILITY" hammurapi-infra-version; }

# config_storable <ключ> — ключ хранится в кластере: только опции и параметры MCP-серверов,
# без них ручной `up` удалил бы серверы. Всё остальное задаёт файл конфигурации.
config_storable() { [[ $1 =~ ^MCP_[A-Z0-9_]+$ && $1 != MCP_CHART_* ]]; }

# write_config — настройки MCP в кластер, только значения, отличные от умолчаний: иначе новые
# умолчания релиза не дошли бы до этой установки.
write_config() {
  local key value default data='{}'
  while read -r key; do
    config_storable "$key" || continue
    value=${!key-}
    # Чистое окружение: иначе заданный ключ, которого нет в умолчаниях, совпал бы сам с собой.
    default=$(env -i "$BASH" -c '. "$1" 2>/dev/null; printf %s "${!2-}"' _ "$ROOT/config/defaults.env" "$key")
    [[ $value != "$default" ]] || continue
    data=$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$data")
  done < <({ env_keys "$ROOT/config/defaults.env"; printf '%s\n' "${MCP_OPTIONS[@]}"; } | sort -u)
  jq -n --arg ns "$NS_STATE" --arg name "$STATE_CONFIG_CM" --argjson data "$data" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: $name, namespace: $ns,
      labels: {"app.kubernetes.io/managed-by": "hammurapi-infra"}}, data: $data}' | apply_stdin
}

# restore_config [strict] — настройки MCP из кластера там, где этот запуск их не задаёт: ключи
# файла и окружения важнее. Чтобы выключить сервер, задайте MCP_<ИМЯ>=false. strict (up): ошибка
# чтения останавливает запуск, иначе up развернул бы умолчания и перезаписал сохранённое.
restore_config() {
  local out data entry key value
  if ! out=$(kc -n "$NS_STATE" get configmap "$STATE_CONFIG_CM" --ignore-not-found -o json 2>&1); then
    [[ ${1:-} != strict ]] || die "$E_CLUSTER" "не удалось прочитать конфигурацию из кластера: $(tail -1 <<<"$out")"
    warn "не удалось прочитать конфигурацию из кластера: $(tail -1 <<<"$out")"
    return 0
  fi
  [[ -n $out ]] || return 0
  data=$(jq -c '.data // {}' <<<"$out")
  while read -r entry; do
    key=$(base64 -d <<<"$entry" | jq -r .key)
    value=$(base64 -d <<<"$entry" | jq -r .value)
    config_storable "$key" || continue
    [[ -z ${CONFIG_EXPLICIT[$key]+x} ]] || continue
    printf -v "$key" '%s' "$value"
    export "${key?}"
    if [[ $value =~ ^(true|false)$ && " ${MCP_OPTIONS[*]} " != *" $key "* ]]; then
      MCP_OPTIONS+=("$key")
    fi
  done < <(jq -r 'to_entries[] | @base64' <<<"$data")
}
