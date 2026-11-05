# shellcheck shell=bash
# State of an install (FTR.INFRA.INST-0001 tech §9): ConfigMaps of namespace $NS_STATE. The old
# locations (ingress, observability) are read until the next `up` replaces them, and they stay: the
# unpacked older tag reads them on a rollback. They go when rollbacks to such tags stop being needed.

readonly STATE_PUBLIC_CM=installer-public STATE_VERSION_CM=installer-version STATE_CONFIG_CM=installer-config

# state_data <ConfigMap> [<old namespace> <old name>] — .data as JSON, or nothing.
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

# config_storable <key> — the key is kept in the cluster: only options and parameters of MCP servers,
# because a manual `up` would delete the servers without them. The config file sets everything else.
config_storable() { [[ $1 =~ ^MCP_[A-Z0-9_]+$ && $1 != MCP_CHART_* ]]; }

# write_config — stores MCP settings in the cluster, only values that differ from the defaults: otherwise
# new defaults of a release would never reach this install.
write_config() {
  local key value default data='{}'
  while read -r key; do
    config_storable "$key" || continue
    value=${!key-}
    # A clean environment: otherwise a set key missing from the defaults would match itself.
    default=$(env -i "$BASH" -c '. "$1" 2>/dev/null; printf %s "${!2-}"' _ "$ROOT/config/defaults.env" "$key")
    [[ $value != "$default" ]] || continue
    data=$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$data")
  done < <({ env_keys "$ROOT/config/defaults.env"; printf '%s\n' "${MCP_OPTIONS[@]}"; } | sort -u)
  jq -n --arg ns "$NS_STATE" --arg name "$STATE_CONFIG_CM" --argjson data "$data" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: $name, namespace: $ns,
      labels: {"app.kubernetes.io/managed-by": "hammurapi-infra"}}, data: $data}' | apply_stdin
}

# restore_config [strict] — MCP settings from the cluster where this run does not set them: keys of
# the file and the environment win. Set MCP_<NAME>=false to disable a server. strict (up): a read
# error stops the run, or up would deploy the defaults and overwrite what is stored.
restore_config() {
  local out data entry key value
  if ! out=$(kc -n "$NS_STATE" get configmap "$STATE_CONFIG_CM" --ignore-not-found -o json 2>&1); then
    [[ ${1:-} != strict ]] || die "$E_CLUSTER" "failed to read the configuration from the cluster: $(tail -1 <<<"$out")"
    warn "failed to read the configuration from the cluster: $(tail -1 <<<"$out")"
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
