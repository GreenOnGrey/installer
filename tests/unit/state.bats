#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 tech §9: state in the namespace installer, configuration in the cluster.

load helpers

setup() {
  setup_stubs
  load_script
  CM_DIR=$BATS_TEST_TMPDIR/cm
  mkdir -p "$CM_DIR"
  export CM_DIR
  # kubectl: ConfigMaps are files <ns>_<name>.json; apply saves the manifest from stdin.
  stub kubectl '
args="$*"
case "$args" in
  *"get configmap "*) ns=$(sed "s/.* -n \([^ ]*\) .*/\1/" <<<"$args"); n=$(sed "s/.*get configmap \([^ ]*\).*/\1/" <<<"$args")
    [[ -f $CM_DIR/${ns}_$n.json ]] && cat "$CM_DIR/${ns}_$n.json" || exit 1 ;;
  *"apply -f -"*) m=$(cat); ns=$(jq -r .metadata.namespace <<<"$m"); n=$(jq -r .metadata.name <<<"$m"); echo "$m" >"$CM_DIR/${ns}_$n.json" ;;
  *) exit 0 ;;
esac'
}

# put_cm <ns> <name> <data JSON>
put_cm() { jq -n --argjson d "$3" '{data: $d}' >"$CM_DIR/$1_$2.json"; }

@test "STATE-01: state is read from the namespace installer" {
  put_cm installer installer-version '{"tag":"v2"}'
  put_cm observability hammurapi-infra-version '{"tag":"v1"}'
  run state_version
  jq -e '.tag == "v2"' <<<"$output"
}

@test "STATE-02: before the first up of a new version, the old location is read" {
  put_cm observability hammurapi-infra-version '{"tag":"v1"}'
  put_cm ingress hammurapi-infra-public '{"baseDomain":"x.example"}'
  run state_version
  jq -e '.tag == "v1"' <<<"$output"
  run state_public
  jq -e '.baseDomain == "x.example"' <<<"$output"
}

@test "STATE-03: no state: version null, public access off" {
  run deployed_version
  [ "$output" = null ]
  run public_status_json
  [ "$output" = '{"enabled":false}' ]
}

@test "CFG-01: only values that differ from the defaults go to the cluster" {
  MCP_DOCGEN=true MCP_DOCLING_MAX_MB=50
  write_config
  jq -e '.data == {MCP_DOCGEN: "true", MCP_DOCLING_MAX_MB: "50"} and .metadata.namespace == "installer"' "$CM_DIR/installer_installer-config.json"
}

@test "CFG-02: only MCP settings go to the cluster" {
  MK_PROFILE=other KUBE_CONTEXT=ctx POSTGRES_PASSWORD=s3cr VM_RETENTION=30d PUBLIC_ACCESS=true MCP_CHART_VERSION=9
  MCP_SEARCH=true
  write_config
  jq -e '.data == {MCP_SEARCH: "true"}' "$CM_DIR/installer_installer-config.json"
}

@test "CFG-03: a run without MCP options takes them from the cluster, so a manual up keeps the servers" {
  put_cm installer installer-config '{"MCP_DOCGEN":"true","MCP_DOCLING_MAX_MB":"50"}'
  [ "$MCP_DOCGEN" = false ]
  restore_config
  [ "$MCP_DOCGEN" = true ]
  [ "$MCP_DOCLING_MAX_MB" = 50 ]
  run mcp_enabled
  [ "$status" -eq 0 ]
}

@test "CFG-04: the file and environment win over the cluster; MCP_<NAME>=false disables a server" {
  put_cm installer installer-config '{"MCP_DOCGEN":"true","MCP_SEARCH":"true"}'
  local cfg=$BATS_TEST_TMPDIR/local.env
  echo 'MCP_DOCGEN=false' >"$cfg"
  unset MCP_DOCGEN
  export MCP_SEARCH=false
  CONFIG_EXPLICIT=()
  load_config "$ROOT" "$cfg"
  restore_config
  [ "$MCP_DOCGEN" = false ]
  [ "$MCP_SEARCH" = false ]
}

@test "CFG-05: only MCP settings come from the cluster; foreign variables are not exported" {
  put_cm installer installer-config '{"MK_PROFILE":"evil","BASH_ENV":"/tmp/x","KUBECONFIG":"/tmp/k","LD_PRELOAD":"/tmp/l","MCP_CHART_DIR":"/tmp/c","bad name":"x"}'
  local profile=$MK_PROFILE
  unset BASH_ENV KUBECONFIG LD_PRELOAD
  MCP_CHART_DIR=""
  restore_config
  [ "$MK_PROFILE" = "$profile" ]
  [ -z "${BASH_ENV+x}" ] && [ -z "${KUBECONFIG+x}" ] && [ -z "${LD_PRELOAD+x}" ]
  [ -z "$MCP_CHART_DIR" ]
}

@test "CFG-06: the option of a new server survives restore and write" {
  put_cm installer installer-config '{"MCP_NEW_ONE":"true"}'
  restore_config
  [[ " ${MCP_OPTIONS[*]} " == *" MCP_NEW_ONE "* ]]
  write_config
  jq -e '.data.MCP_NEW_ONE == "true"' "$CM_DIR/installer_installer-config.json"
}

@test "CFG-08: a read error of the configuration stops up, status only warns" {
  stub kubectl 'echo "connection refused" >&2; exit 1'
  run restore_config strict
  [ "$status" -eq 12 ]
  [[ $output == *"connection refused"* ]]
  run restore_config
  [ "$status" -eq 0 ]
}

@test "CFG-10: a kubectl warning on stderr does not stop reading the configuration" {
  stub kubectl 'echo "Warning: something is deprecated" >&2; echo "{\"data\":{\"MCP_DOCGEN\":\"true\"}}"'
  restore_config strict
  [ "$MCP_DOCGEN" = true ]
}

@test "CFG-11: an unreadable answer stops up instead of deploying defaults" {
  stub kubectl 'echo "not json"'
  run restore_config strict
  [ "$status" -eq 12 ]
}

@test "CFG-09: no configuration: nothing changes" {
  stub kubectl 'exit 0'
  restore_config strict
  [ "$MCP_DOCGEN" = false ]
}

@test "STATE-04: public access off: both ConfigMaps go, so the old one cannot report an old domain" {
  PUBLIC_ACCESS=false
  deploy_public
  called "-n installer delete configmap installer-public --ignore-not-found"
  called "-n ingress delete configmap hammurapi-infra-public --ignore-not-found"
}

@test "CFG-12: a component rollout does not check MCP servers, even those set in the file" {
  MCP_SEARCH=true INSTALLER_STAND_ONLY=1
  CHECK_RESULTS=()
  check_mcp
  [ "${#CHECK_RESULTS[@]}" -eq 0 ]
  not_called "get pods"
}

@test "CFG-07: component rollouts check only the stand" {
  grep -q 'INSTALLER_STAND_ONLY=1 bash "$STATUS_CMD" status' "$ROOT/bin/hammurapi-deploy"
  grep -q 'INSTALLER_STAND_ONLY=1 bash "$STATUS_CMD" status' "$ROOT/bin/nabu-deploy"
  grep -q 'INSTALLER_STAND_ONLY=1 bash "$STATUS_CMD" status' "$ROOT/bin/landing-deploy"
}

@test "FTR.INFRA.INST-0001 R28: migrate_names relabels what an older tag labelled" {
  stub kubectl '[[ $* == *"get secret,configmap"* ]] && echo "{\"items\":[{\"kind\":\"Secret\",\"metadata\":{\"namespace\":\"storages\",\"name\":\"s3-root\"}}]}"; exit 0'
  run migrate_names
  [ "$status" -eq 0 ]
  called "get secret,configmap -A -l app.kubernetes.io/managed-by=hammurapi-infra"
  called "-n storages label --overwrite Secret/s3-root app.kubernetes.io/managed-by=installer"
}

@test "FTR.INFRA.INST-0001 R28: migrate_names has nothing to do on a new install, and a failure stops nothing" {
  stub kubectl '[[ $* == *"get secret,configmap"* ]] && echo "{\"items\":[]}"; exit 0'
  run migrate_names
  [ "$status" -eq 0 ]
  not_called "label --overwrite"
  stub kubectl 'exit 1'
  run migrate_names
  [ "$status" -eq 0 ]
  [[ $output == *"old label"* ]]
}
