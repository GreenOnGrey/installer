# shellcheck shell=bash
# update (FTR.INFRA.INST-0001 R22–R24, tech §7): the install brought to the set of versions of this release,
# or one service to a version of its own (a pin) as an exception from the set.

# The services of update in rollout order, and the variable of config/versions.env each one follows. The
# MCP servers roll out with the stand (deploy_all), so their pin applies before it.
readonly UPDATE_SERVICES=(nabu-core nabu-web hammurapi-core hammurapi-web mcp-servers)
declare -grA SERVICE_VERSION_VAR=([nabu-core]=NABU_CORE_VERSION [nabu-web]=NABU_WEB_VERSION
  [hammurapi-core]=HAMMURAPI_CORE_VERSION [hammurapi-web]=HAMMURAPI_WEB_VERSION [mcp-servers]=MCP_CHART_VERSION)
readonly DOWNGRADE_ANNOTATION=greenongrey.tech/downgrade-safe-to

UPDATE_SERVICE="" UPDATE_TO="" DRY_RUN=0
# The pins of a running update: install_steps and write_version use them instead of the stored ones, and
# they are stored only once the update succeeded.
PINS_OVERRIDE=""

# version_data — .data of installer-version, {} if it does not exist; a failed read stops the run, as
# it would otherwise lose the pins.
version_data() {
  local out
  out=$(kc -n "$NS_STATE" get configmap "$STATE_VERSION_CM" --ignore-not-found -o json) ||
    die "$E_CLUSTER" "failed to read $NS_STATE/$STATE_VERSION_CM"
  if [[ -n $out ]]; then jq -c '.data // {}' <<<"$out"; else echo '{}'; fi
}

# pinned_versions — {service: version} pinned by update --to, or {}.
pinned_versions() {
  if [[ -n $PINS_OVERRIDE ]]; then
    echo "$PINS_OVERRIDE"
    return
  fi
  version_data | jq -c '(.pinned // "{}") | fromjson? // {}'
}

# write_pins <JSON> — the pins in installer-version, the rest of it as it is.
write_pins() {
  local data
  data=$(version_data) || exit
  state_configmap "$STATE_VERSION_CM" "$(jq -c --arg p "$1" '. + {pinned: $p}' <<<"$data")"
}

# apply_pins — pinned versions replace those of the set for this run (install keeps them, R23).
apply_pins() {
  local pins service version
  pins=$(pinned_versions) || exit
  while IFS=$'\t' read -r service version; do
    [[ -n $service && -n ${SERVICE_VERSION_VAR[$service]:-} ]] || continue
    printf -v "${SERVICE_VERSION_VAR[$service]}" '%s' "$version"
    log "pinned: $service $version"
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$pins")
}

# service_enabled <service> — the service is part of this install.
service_enabled() {
  case $1 in
    nabu-*) has_product nabu ;;
    hammurapi-*) has_product hammurapi ;;
    mcp-servers) mcp_enabled ;;
  esac
}

# installed_version <service> — the version running now, as the installer rolled it out, or nothing.
installed_version() {
  if [[ $1 == mcp-servers ]]; then
    hm list -n "$NS_MCP" -o json 2>/dev/null | jq -r --arg r "$MCP_RELEASE" '.[] | select(.name == $r) | .chart | sub("^mcp-servers-"; "")'
  else
    recorded_products | jq -r --arg c "$1" '.[$c] // empty'
  fi
}

# version_lt <a> <b> — a is older than b (a leading v is ignored).
version_lt() {
  local a=${1#v} b=${2#v}
  [[ $a != "$b" && $(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1) == "$a" ]]
}

# downgrade_safe_to <service> — the oldest version the chart allows to go back to, or nothing.
downgrade_safe_to() {
  local chart version
  case $1 in
    nabu-*) chart=$CHART_REPO_BASE/$1 version=$NABU_CHART_VERSION ;;
    hammurapi-*) chart=$CHART_REPO_BASE/$1 version=$HAMMURAPI_CHART_VERSION ;;
    mcp-servers) chart=$MCP_CHART_REPO version=$MCP_CHART_VERSION ;;
  esac
  # Chart.yaml: "annotations:" then "  greenongrey.tech/downgrade-safe-to: v1.2.0" (no yq on the machine).
  local out
  out=$(hm show chart "$chart" --version "$version" 2>/dev/null) ||
    die "$E_EXTERNAL" "failed to read the chart $chart $version for its annotation $DOWNGRADE_ANNOTATION; nothing was changed"
  printf '%s\n' "$out" |
    awk -v k="$DOWNGRADE_ANNOTATION:" '{ sub(/^[ \t]+/, "") } index($0, k) == 1 { v = substr($0, length(k) + 1); gsub(/[ \t"\047]/, "", v); print v; exit }'
}
CHART_REPO_BASE=${CHART_REPO_BASE:-oci://ghcr.io/greenongrey/charts}

# update_plan — service, installed (- if none) and target version of each service of this install,
# tab-separated: read with IFS=tab collapses empty fields, so none is "-".
update_plan() {
  local service var
  for service in "${UPDATE_SERVICES[@]}"; do
    service_enabled "$service" || continue
    [[ -z $UPDATE_SERVICE || $UPDATE_SERVICE == "$service" ]] || continue
    var=${SERVICE_VERSION_VAR[$service]}
    local installed
    installed=$(installed_version "$service")
    printf '%s\t%s\t%s\n' "$service" "${installed:--}" "${!var}"
  done
}

# check_downgrades <plan> — R23: a version below the running one needs the consent of the chart (code 2).
check_downgrades() {
  local service installed target safe refused=()
  while IFS=$'\t' read -r service installed target; do
    [[ -n $service && $installed != - ]] && version_lt "$target" "$installed" || continue
    safe=$(downgrade_safe_to "$service") || exit
    if [[ -z $safe ]] || version_lt "$target" "$safe"; then
      refused+=("$service $installed → $target")
    fi
  done <<<"$1"
  ((${#refused[@]} == 0)) && return 0
  die "$E_USAGE" "going back is not allowed by the charts (annotation $DOWNGRADE_ANNOTATION): ${refused[*]}; keep the running version with update <service> --to <it>; nothing was changed"
}

print_plan() {
  local service installed target stand
  stand=$(version_data | jq -r '.tag // "not recorded"')
  printf '\n%-16s %-14s %s\n' Service Installed Target
  printf '%-16s %-14s %s\n' stand "$stand" "$(installer_version)"
  while IFS=$'\t' read -r service installed target; do
    [[ -n $service ]] || continue
    printf '%-16s %-14s %s%s\n' "$service" "$installed" "$target" "$([[ $installed == "$target" ]] && echo "   (unchanged)")"
  done <<<"$1"
  if [[ $POSTGRES_MODE == internal || $KAFKA_MODE == internal || $S3_MODE == internal ]]; then
    printf '\nThe built-in storages keep their data, but there is no rollback: back them up first (R24).\n'
  fi
  printf '\n'
}

confirm_update() {
  ((ASSUME_YES || DRY_RUN)) && return 0
  printf 'Apply this update? Type yes: ' >&2
  local answer=""
  read -r answer || true
  [[ $answer == yes ]] || die "$E_CANCELLED" "cancelled: nothing was changed"
}

# on_update_exit — services of the plan that were neither updated nor failed are skipped (R24).
on_update_exit() {
  local code=$1 service
  if ((code != 0)); then
    while IFS=$'\t' read -r service _; do
      [[ -n $service ]] || continue
      [[ " ${RESULT_UPDATED[*]} ${RESULT_FAILED[*]} ${RESULT_SKIPPED[*]} " == *" $service "* ]] || RESULT_SKIPPED+=("$service")
    done <<<"${UPDATE_PLAN:-}"
  fi
  on_install_exit "$code"
}

# validate_update_args — the service and its version, before anything is read from the cluster.
validate_update_args() {
  if [[ -n $UPDATE_SERVICE && -z ${SERVICE_VERSION_VAR[$UPDATE_SERVICE]:-} ]]; then
    usage_error "update: the service is one of ${UPDATE_SERVICES[*]}, not '$UPDATE_SERVICE'"
  fi
  if [[ -n $UPDATE_TO ]]; then
    [[ -n $UPDATE_SERVICE ]] || usage_error "update: --to needs a service"
    if [[ $UPDATE_SERVICE == mcp-servers ]]; then
      [[ $UPDATE_TO =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "update mcp-servers --to: a chart version X.Y.Z, not '$UPDATE_TO'"
    else
      [[ $UPDATE_TO =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "update $UPDATE_SERVICE --to: a tag vX.Y.Z, not '$UPDATE_TO'"
    fi
  fi
  # R22: changes without a terminal need --yes; a dry run changes nothing.
  if ((!ASSUME_YES && !DRY_RUN)) && ! interactive; then
    usage_error "update without a terminal needs --yes (or --dry-run)"
  fi
}

cmd_update() {
  start_run_log
  trap 'on_update_exit $?' EXIT
  step update
  cluster_reachable || die "$E_CHECKS" "cluster $(cluster_label) is not running: start it with install"
  restore_config strict
  # R24: a stand with a problem is not updated.
  run_checks || die "$E_CHECKS" "the checks of the stand fail, nothing was changed: $(first_failure)"
  step update
  local pins
  pins=$(pinned_versions) || exit
  if [[ -n $UPDATE_SERVICE ]] && ! service_enabled "$UPDATE_SERVICE"; then
    die "$E_USAGE" "$UPDATE_SERVICE is not part of this install (PRODUCTS, MCP_* options)"
  fi
  if [[ -z $UPDATE_SERVICE ]]; then
    pins='{}'
  elif [[ -n $UPDATE_TO ]]; then
    pins=$(jq -c --arg s "$UPDATE_SERVICE" --arg v "$UPDATE_TO" '. + {($s): $v}' <<<"$pins")
  else
    pins=$(jq -c --arg s "$UPDATE_SERVICE" 'del(.[$s])' <<<"$pins")
  fi
  # The pins of this run before the plan: the plan shows what the run would do.
  local service var
  for service in "${UPDATE_SERVICES[@]}"; do
    var=${SERVICE_VERSION_VAR[$service]}
    printf -v "$var" '%s' "$(jq -r --arg s "$service" --arg d "${!var}" '.[$s] // $d' <<<"$pins")"
  done
  UPDATE_PLAN=$(update_plan)
  print_plan "$UPDATE_PLAN"
  check_downgrades "$UPDATE_PLAN"
  if ((DRY_RUN)); then
    log "dry run: nothing was changed"
    while IFS=$'\t' read -r service _; do [[ -n $service ]] && RESULT_SKIPPED+=("$service"); done <<<"$UPDATE_PLAN"
    UPDATE_PLAN=""
    return 0
  fi
  confirm_update
  acquire_lock
  # Stored only after a success: a failed rollout must not leave a pin to a version that never ran.
  PINS_OVERRIDE=$pins
  if [[ -z $UPDATE_SERVICE ]]; then
    install_steps
  else
    update_one "$UPDATE_SERVICE"
  fi
  write_pins "$pins"
}

# update_one <service> — one service at its version, the rest of the install as it is.
update_one() {
  step update
  case $1 in
    mcp-servers)
      # The memory budget first, as in deploy_all (FTR.NAB.CMN-0006 R3).
      mcp_preflight
      deploy_mcp
      ;;
    *-web)
      [[ -n $(installed_version "${1%-web}-core") ]] || die 21 "roll out ${1%-web}-core first"
      ;&
    *)
      products_preflight
      deploy_products_of "$1"
      ;;
  esac
  local var=${SERVICE_VERSION_VAR[$1]}
  # R24: the update ends with the checks of the stand, like install.
  run_checks || die "$E_CHECKS" "$1 ${!var} is rolled out, but the checks fail: $(first_failure)"
  ok "$1 ${!var}"
}
