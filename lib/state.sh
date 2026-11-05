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
  state_configmap "$STATE_CONFIG_CM" "$data"
}

# state_configmap <name> <data JSON> — a ConfigMap of the state with this data.
state_configmap() {
  jq -n --arg ns "$NS_STATE" --arg name "$1" --argjson data "$2" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: $name, namespace: $ns,
      labels: {"app.kubernetes.io/managed-by": "installer"}}, data: $data}' | apply_stdin
}

# migrate_names — what an older tag labelled gets the current label (FTR.INFRA.INST-0001 tech §9).
# deploy_public applies certificates and issuers again; nothing reads the label on them.
migrate_names() {
  local out kind ns name
  if ! out=$(kc get secret,configmap -A -l app.kubernetes.io/managed-by=hammurapi-infra -o json 2>/dev/null |
    jq -r '.items[] | "\(.kind) \(.metadata.namespace) \(.metadata.name)"'); then
    warn "failed to list resources with the old label, the next up tries again"
    return 0
  fi
  while read -r kind ns name; do
    [[ -n $kind ]] || continue
    kc -n "$ns" label --overwrite "$kind/$name" app.kubernetes.io/managed-by=installer >/dev/null ||
      warn "failed to relabel $ns/$kind/$name, the next up tries again"
  done <<<"$out"
}

# restore_config [strict] — MCP settings from the cluster where this run does not set them: keys of
# the file and the environment win. Set MCP_<NAME>=false to disable a server. strict (up): a read
# error stops the run, or up would deploy the defaults and overwrite what is stored.
restore_config() {
  local out data entry key value err
  # stderr apart: a kubectl warning on a successful call must not reach the JSON.
  err=$(mktemp)
  if ! out=$(kc -n "$NS_STATE" get configmap "$STATE_CONFIG_CM" --ignore-not-found -o json 2>"$err") ||
    ! data=$(if [[ -n $out ]]; then jq -ce '.data // {}' <<<"$out" 2>>"$err"; fi); then
    local reason
    reason=$(tail -1 "$err")
    rm -f "$err"
    [[ ${1:-} != strict ]] || die "$E_CLUSTER" "failed to read the configuration from the cluster: $reason"
    warn "failed to read the configuration from the cluster: $reason"
    return 0
  fi
  rm -f "$err"
  [[ -n $out ]] || return 0
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
