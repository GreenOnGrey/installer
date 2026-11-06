#!/usr/bin/env bash
# Static checks of manifests (level I): renders exactly the releases that
# `up` would deploy, for 8 combinations of storage modes; kubeconform, requests and
# limits, service types, scrape jobs, storage services, retention.
# Needs: helm ≥ 3.17, kubeconform, jq, yq (mikefarah). Network for charts.
#   tests/manifests.sh            # all checks
#   SKIP_REPOS=1 tests/manifests.sh   # without helm repo add/update
# SC2034: the sourced functions of lib/*.sh read configuration variables.
# shellcheck disable=SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${OUT:-$ROOT/.work/manifests}
COLOR=${COLOR:-auto}
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/external.sh
source "$ROOT/lib/external.sh"
# shellcheck source=../lib/checks.sh
source "$ROOT/lib/checks.sh"
# shellcheck source=../lib/state.sh
source "$ROOT/lib/state.sh"
# shellcheck source=../lib/deploy.sh
source "$ROOT/lib/deploy.sh"
# shellcheck source=../lib/public.sh
source "$ROOT/lib/public.sh"
# shellcheck source=../lib/mcp.sh
source "$ROOT/lib/mcp.sh"
setup_color
load_config "$ROOT" /dev/null
KUBE_VERSION=${K8S_VERSION#v}
FAILURES=0

fail() {
  printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"
  FAILURES=$((FAILURES + 1))
}
pass() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }

# hm — renders a release (`helm template`) to stdout instead of installing, and
# release() writes it to $RUN_DIR/helm-<release>.log.
hm() {
  if [[ $1 == upgrade ]]; then
    shift 2
    local name=$1 chart=$2 args=()
    shift 2
    while (($#)); do
      case $1 in
        --wait) ;;
        --timeout) shift ;;
        *) args+=("$1") ;;
      esac
      shift
    done
    helm template "$name" "$chart" --kube-version "$KUBE_VERSION" --include-crds "${args[@]}"
  elif [[ $1 == status ]]; then
    return 1
  fi
}
kc() { return 0; }

# render <directory> — releases of the current configuration.
render() {
  RUN_DIR=$1 WORK_DIR=$1/work
  rm -rf "$RUN_DIR"
  mkdir -p "$WORK_DIR"
  RELEASES=()
  STEP=render
  deploy_operators
  deploy_storages
  deploy_observability
}

# jq on Windows (Git Bash) prints CRLF; tr changes nothing on Linux.
jq() { command jq "$@" | tr -d '\r'; }

# docs_json <files…> — all manifest objects as a JSON stream.
docs_json() { cat "$@" | yq -o=json -I=0 'select(. != null)'; }

# resources_missing <files…> — containers without requests or limits.
resources_missing() {
  docs_json "$@" | jq -r '
    select(.kind | IN("Deployment", "StatefulSet", "DaemonSet", "Job", "Pod", "CronJob"))
    | (if .kind == "Pod" then .spec elif .kind == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end) as $s
    | "\(.kind)/\(.metadata.name)" as $o
    | (($s.containers // []) + ($s.initContainers // []))[]
    | select((.resources.requests.cpu // "") == "" or (.resources.requests.memory // "") == ""
        or (.resources.limits.cpu // "") == "" or (.resources.limits.memory // "") == "")
    | "\($o)/\(.name)"'
}

check_resources() {
  local dir=$1 missing
  missing=$(resources_missing "$dir"/helm-*.log)
  missing+=$(docs_json "$dir"/helm-storages.log | jq -r '
    select(.kind == "KafkaNodePool" or .kind == "Cluster")
    | select((.spec.resources.requests.memory // "") == "" or (.spec.resources.limits.memory // "") == "")
    | " \(.kind)/\(.metadata.name)"')
  if [[ -n $missing ]]; then fail "RES-01 $2: no requests or limits: $(echo "$missing" | tr '\n' ' ')"; else pass "RES-01 $2: requests and limits are set"; fi
}

check_service_types() {
  local bad
  bad=$(docs_json "$1"/helm-*.log | jq -r 'select(.kind == "Service") | select((.spec.type // "ClusterIP") | IN("ClusterIP", "ExternalName") | not) | "\(.metadata.name):\(.spec.type)"')
  if [[ -n $bad ]]; then fail "SEC-04 $2: services exposed outside: $bad"; else pass "SEC-04 $2: only ClusterIP and ExternalName"; fi
}

check_storage_services() {
  local names
  names=$(docs_json "$1/helm-storages.log" | jq -r 'select(.kind == "Service") | .metadata.name' | sort | tr '\n' ' ')
  if [[ $names == "kafka postgres s3 " ]]; then pass "STO-05 $2: services postgres, kafka, s3"; else fail "STO-05 $2: services: $names"; fi
}

check_scrape_jobs() {
  local jobs expected
  jobs=$(yq -r '.config.scrape_configs[].job_name' "$1/vmagent-scrape.yaml" | sort | tr '\n' ' ')
  # hammurapi and mcp (values/scrape/hammurapi.yaml) are always configured but not required by
  # the checks: they have no targets until Hammurapi, Nabu and MCP servers are deployed.
  expected=$({ expected_jobs; echo hammurapi; echo mcp; } | sort | tr '\n' ' ')
  if [[ $jobs == "$expected" ]]; then pass "MET-02 $2: scrape jobs $jobs"; else fail "MET-02 $2: jobs '$jobs', expected '$expected'"; fi
}

check_internal_releases() {
  local dir=$1 label=$2 ok=1
  [[ $KAFKA_MODE == internal ]] || { [[ -f $dir/helm-strimzi.log ]] && ok=0; }
  [[ $POSTGRES_MODE == internal ]] || { [[ -f $dir/helm-cnpg.log ]] && ok=0; }
  [[ $S3_MODE == internal ]] || { [[ -f $dir/helm-seaweedfs.log ]] && ok=0; }
  if docs_json "$dir/helm-storages.log" | jq -e --arg pg "$POSTGRES_MODE" --arg k "$KAFKA_MODE" '
      select((.kind == "Cluster" and $pg == "external") or (.kind == "Kafka" and $k == "external"))' >/dev/null; then ok=0; fi
  if ((ok)); then pass "EXT-01 $label: external storages are not deployed"; else fail "EXT-01 $label: a storage in external mode is deployed"; fi
}

kubeconform_dir() {
  local dir=$1 label=$2 schemas=$OUT/schemas out f
  # Only Kubernetes objects: render logs may hold Helm warnings.
  for f in "$dir"/helm-*.log; do
    grep -v -E '^(WARNING|walk\.go|coalesce\.go)' "$f"
    printf '\n---\n'
  done | yq 'select(.kind != null)' >"$dir/all.yaml"
  if out=$(kubeconform -strict -summary -kubernetes-version "$KUBE_VERSION" \
    -schema-location default -schema-location "$schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    -skip CustomResourceDefinition - <"$dir/all.yaml" 2>&1); then
    pass "QUAL-02 $label: kubeconform — $(tail -1 <<<"$out")"
  else
    fail "QUAL-02 $label: kubeconform"
    echo "$out" | grep -v '^Summary' | head -20 | sed 's/^/      /'
  fi
}

# crd_schemas — JSON schemas of CRs (Kafka, KafkaNodePool, Cluster) from operator CRDs.
crd_schemas() {
  local schemas=$OUT/schemas
  rm -rf "$schemas"
  mkdir -p "$schemas"
  docs_json "$1"/helm-strimzi.log "$1"/helm-cnpg.log | jq -c 'select(.kind == "CustomResourceDefinition")' |
    while IFS= read -r crd; do
      local group kind
      group=$(jq -r .spec.group <<<"$crd")
      kind=$(jq -r '.spec.names.kind | ascii_downcase' <<<"$crd")
      mkdir -p "$schemas/$group"
      jq -r '.spec.versions[] | .name' <<<"$crd" | while read -r v; do
        jq --arg v "$v" '.spec.versions[] | select(.name == $v) | .schema.openAPIV3Schema' <<<"$crd" >"$schemas/$group/${kind}_$v.json"
      done
    done
}

# --- FTR.NAB.CMN-0006: MCP servers ---

# mcp_chart — the pinned chart version downloads without credentials and renders with the
# installer's values; the repository mcps checks the chart itself.
mcp_chart() {
  printf '\nMCP servers\n'
  local f=$OUT/mcp-servers.yaml args=() deps want srv
  MCP_DOCLING=true MCP_SEARCH=true MCP_YANDEX_MAIL=true MCP_DOCGEN=true
  mcp_load
  mapfile -t args < <(mcp_helm_args)
  if ! helm template "$MCP_RELEASE" "$MCP_CHART_DIR" -n mcp --kube-version "$KUBE_VERSION" "${args[@]}" >"$f" 2>&1; then
    fail "MCP-01: chart mcp-servers $MCP_CHART_VERSION does not render: $(tail -1 "$f")"
    return
  fi
  kubeconform_file "$f" "mcp-servers"
  deps=$(docs_json "$f" | jq -r 'select(.kind == "Deployment") | .metadata.name' | sort | tr '\n' ' ')
  want=$(for srv in "${MCP_SERVERS[@]}"; do tr ' ' '\n' <<<"${MCP_DEPLOYMENTS[$srv]}"; done | sort | tr '\n' ' ')
  if [[ $deps == "$want" ]]; then
    pass "MCP-01: chart $MCP_CHART_VERSION and its descriptions: $deps"
  else
    fail "MCP-01: Deployments of the chart '$deps', in descriptions '$want'"
  fi
  mcp_wizard_list
  MCP_DOCLING=false MCP_SEARCH=false MCP_YANDEX_MAIL=false MCP_DOCGEN=false
}

# mcp_wizard_list — config/mcp-servers.tsv, which the wizard reads without Helm, names the servers of the
# chart and the memory each one requests.
mcp_wizard_list() {
  local srv o want="" have f mib
  have=$(sed '/^#/d' "$ROOT/config/mcp-servers.tsv" | cut -f1,2 | tr '\t' ' ' | sort)
  for srv in "${MCP_SERVERS[@]}"; do
    local args=()
    for o in "${MCP_SERVERS[@]}"; do printf -v "$(mcp_opt "$o")" false; done
    # A server new to the chart has no option in defaults.env yet.
    [[ " ${MCP_OPTIONS[*]} " == *" $(mcp_opt "$srv") "* ]] || MCP_OPTIONS+=("$(mcp_opt "$srv")")
    printf -v "$(mcp_opt "$srv")" true
    mapfile -t args < <(mcp_helm_args)
    f=$OUT/mcp-$srv.yaml
    helm template "$MCP_RELEASE" "$MCP_CHART_DIR" -n mcp --kube-version "$KUBE_VERSION" "${args[@]}" >"$f"
    mib=$(docs_json "$f" | jq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | .resources.requests.memory // empty' |
      while read -r q; do to_bytes "$q"; done | awk '{ s += $1 } END { print int(s / 1048576) }')
    want+="$srv $mib"$'\n'
  done
  want=$(sort <<<"${want%$'\n'}")
  if [[ $have == "$want" ]]; then
    pass "R21: config/mcp-servers.tsv matches the chart: $(tr '\n' ',' <<<"$want")"
  else
    fail "R21: config/mcp-servers.tsv has '$(tr '\n' ',' <<<"$have")', the chart '$(tr '\n' ',' <<<"$want")'"
  fi
}

# --- FTR.HMR.INFRA-0002: Hammurapi charts and public access ---

# kubeconform_file <file> <label>
kubeconform_file() {
  local out
  if out=$(kubeconform -strict -summary -kubernetes-version "$KUBE_VERSION" -skip CustomResourceDefinition \
    -schema-location default -schema-location "$OUT/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    -ignore-missing-schemas "$1" 2>&1); then
    pass "QUAL-02 $2: kubeconform — $(tail -1 <<<"$out")"
  else
    fail "QUAL-02 $2: kubeconform"
    echo "$out" | head -10 | sed 's/^/      /'
  fi
}

# nabu_charts — Nabu charts on the same stand (FTR.NAB.CMN-0001 arch §11).
nabu_charts() {
  printf '\nNabu charts\n'
  local dir=$OUT/nabu c f bad
  mkdir -p "$dir"
  for c in nabu-core nabu-web; do
    f=$dir/$c.yaml
    if ! helm lint "$ROOT/charts/$c" --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io >/dev/null 2>&1 ||
      ! helm template "$c" "$ROOT/charts/$c" -n nabu --kube-version "$KUBE_VERSION" \
        --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io >"$f" 2>&1; then
      fail "QUAL-02 $c: helm lint/template"
      continue
    fi
    kubeconform_file "$f" "$c"
    bad=$(docs_json "$f" | jq -r '
      select(.kind | IN("Deployment", "Job", "CronJob"))
      | .kind as $k
      | (if $k == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end) as $s
      | "\($k)/\(.metadata.name)" as $o
      | $s.containers[]
      | [ (if (.resources.requests.cpu // "") == "" or (.resources.limits.memory // "") == "" then "resources" else empty end),
          (if ((.securityContext.runAsNonRoot // $s.securityContext.runAsNonRoot // false) | not) then "runAsNonRoot" else empty end) ]
      | select(length > 0) | "\($o): \(join(", "))"')
    if [[ -n $bad ]]; then fail "RES-01 $c: $(echo "$bad" | tr '\n' ' ')"; else pass "RES-01 $c: requests, limits, runAsNonRoot"; fi
  done
  # Hosts nabu. and nabu-api. of the same domain; the API without service ports.
  local hosts
  hosts=$(docs_json "$dir"/nabu-*.yaml | jq -r 'select(.kind == "Ingress") | .spec.rules[].host' | sort -u | tr '\n' ' ')
  if [[ $hosts == "nabu-api.34-12-5-6.sslip.io nabu.34-12-5-6.sslip.io " ]]; then
    pass "R29: Ingress nabu.<domain> and nabu-api.<domain>"
  else
    fail "R29: Nabu hosts '$hosts'"
  fi
  # FTR.NAB.CMN-0008: sandbox profiles by the nabu tag and preloading their images by worker.
  local profiles verbs
  profiles=$(docs_json "$dir/nabu-core.yaml" | jq -r 'select(.kind == "Deployment" and .metadata.name == "worker")
    | .spec.template.spec.containers[0].env[] | select(.name == "SANDBOX_PROFILES") | .value')
  verbs=$(docs_json "$dir/nabu-core.yaml" | jq -r 'select(.kind == "Role" and .metadata.name == "nabu-sandboxes")
    | .rules[] | select(.resources == ["daemonsets"]) | .verbs | join(",")')
  if [[ $profiles == *"documents=ghcr.io/greenongrey/nabu-sandbox-documents:v1.0.0"* && $verbs == "get,list,watch,create,update" ]]; then
    pass "PRE-04: SANDBOX_PROFILES with the nabu tag, worker manages the DaemonSet in the sandbox namespace"
  else
    fail "PRE-04: profiles '$profiles', daemonset rights '$verbs'"
  fi
  # FTR.HMR.CMN-0007 PF-03, PX-13: the profile code and the egress gateway; sandboxes with a proxy
  # reach only the gateway, and the workspace channel is closed outside.
  if [[ $profiles == *"code=ghcr.io/greenongrey/nabu-sandbox-code:v1.0.0"* ]] &&
    docs_json "$dir/nabu-core.yaml" | jq -e 'select(.kind == "Deployment" and .metadata.name == "egress")
      | .spec.template.spec.containers[0].args == ["egress"]' >/dev/null &&
    docs_json "$dir/nabu-core.yaml" | jq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "sandboxes-egress")
      | .spec.egress[0].ports == [{"port": 3128}]' >/dev/null &&
    docs_json "$dir/nabu-core.yaml" | jq -e 'select(.kind == "Deployment" and .metadata.name == "worker")
      | .spec.template.spec.containers[0].env[] | select(.name == "EGRESS_URL")' >/dev/null &&
    ! docs_json "$dir/nabu-core.yaml" | jq -e 'select(.kind == "Ingress") | .spec.rules[].http.paths[] | select(.backend.service.name == "relay")' >/dev/null; then
    pass "PF-03, PX-13: the profile code, the egress gateway and its network policies"
  else
    fail "PF-03, PX-13: the profile code or the egress gateway"
  fi
  # Without profiles: one nabu-core image, as before FTR.NAB.CMN-0008 (tech §9).
  local legacy
  legacy=$(helm template nabu-core "$ROOT/charts/nabu-core" -n nabu --kube-version "$KUBE_VERSION" --set image.tag=v1.0.0 \
    --set publicBaseDomain=34-12-5-6.sslip.io --set sandboxes.profiles=null --set sandboxes.defaults=null 2>&1 |
    docs_json | jq -r 'select(.kind == "Deployment" and .metadata.name == "worker") | .spec.template.spec.containers[0].env[]
      | select(.name | IN("SANDBOX_PROFILES", "SANDBOX_DEFAULTS", "SANDBOX_IMAGE")) | "\(.name)=\(.value)"' | tr '\n' ' ')
  if [[ $legacy == "SANDBOX_IMAGE=ghcr.io/greenongrey/nabu-core:v1.0.0 " ]]; then
    pass "PRE-04: without profiles, one nabu-core image"
  else
    fail "PRE-04 without profiles: '$legacy'"
  fi
}

# landing_chart — the GreenOnGrey site on the same stand (FTR.LND.WEB-0001 arch §7).
landing_chart() {
  printf '\nchart landing\n'
  local dir=$OUT/landing f bad hosts site
  mkdir -p "$dir"
  f=$dir/landing.yaml
  if ! helm lint "$ROOT/charts/landing" --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io >/dev/null 2>&1 ||
    ! helm template landing "$ROOT/charts/landing" -n landing --kube-version "$KUBE_VERSION" \
      --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io >"$f" 2>&1; then
    fail "LND-38 QUAL-02 landing: helm lint/template"
    return
  fi
  kubeconform_file "$f" "LND-38 landing"
  bad=$(docs_json "$f" | jq -r '
    select(.kind == "Deployment")
    | .spec.template.spec as $s
    | "\(.kind)/\(.metadata.name)" as $o
    | $s.containers[]
    | [ (if (.resources.requests.cpu // "") == "" or (.resources.limits.memory // "") == "" then "resources" else empty end),
        (if ((.securityContext.runAsNonRoot // $s.securityContext.runAsNonRoot // false) | not) then "runAsNonRoot" else empty end) ]
    | select(length > 0) | "\($o): \(join(", "))"')
  if [[ -n $bad ]]; then fail "LND-38 RES-01 landing: $(echo "$bad" | tr '\n' ' ')"; else pass "LND-38 RES-01 landing: requests, limits, runAsNonRoot"; fi
  # Host web.<domain>, and the site gets the same address in SITE_URL.
  hosts=$(docs_json "$f" | jq -r 'select(.kind == "Ingress") | .spec.rules[].host' | tr '\n' ' ')
  site=$(docs_json "$f" | jq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SITE_URL") | .value')
  if [[ $hosts == "web.34-12-5-6.sslip.io " && $site == "https://web.34-12-5-6.sslip.io" ]]; then
    pass "LND-38 R26: Ingress web.<domain>, the SITE_URL of the site is the same address"
  else
    fail "LND-38 R26: host '$hosts', SITE_URL '$site'"
  fi
  # The own domain: the site address is the domain, a separate certificate for the domain and www.,
  # a redirect from www., and the stand's host stays.
  local own=$dir/landing-domain.yaml names regex
  if ! helm template landing "$ROOT/charts/landing" -n landing --kube-version "$KUBE_VERSION" \
    --set image.tag=v1.0.0 --set publicBaseDomain=34-12-5-6.sslip.io --set domain=example.org \
    --set issuer=letsencrypt-staging >"$own" 2>&1; then
    fail "LND-40 landing with a domain: helm template"
    return
  fi
  kubeconform_file "$own" "LND-40 landing with a domain"
  hosts=$(docs_json "$own" | jq -r 'select(.kind == "Ingress") | .spec.rules[].host' | sort | tr '\n' ' ')
  site=$(docs_json "$own" | jq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SITE_URL") | .value')
  names=$(docs_json "$own" | jq -r 'select(.kind == "Certificate") | "\(.spec.issuerRef.name): \(.spec.dnsNames | join(" "))"')
  regex=$(docs_json "$own" | jq -r 'select(.kind == "Middleware") | .spec.redirectRegex | "\(.regex) -> \(.replacement)"')
  # shellcheck disable=SC2016 # ${1} is a Traefik substitution, not shell
  if [[ $hosts == "example.org web.34-12-5-6.sslip.io www.example.org " && $site == "https://example.org" &&
    $names == "letsencrypt-staging: example.org www.example.org" &&
    $regex == '^https?://www\.example\.org/(.*) -> https://example.org/${1}' ]]; then
    pass "LND-40: the domain and www. in Ingress and certificate, SITE_URL is the domain, www. redirects"
  else
    fail "LND-40: hosts '$hosts', SITE_URL '$site', certificate '$names', redirect '$regex'"
  fi
}

hammurapi_charts() {
  printf '\nHammurapi charts\n'
  local dir=$OUT/hammurapi c f bad
  mkdir -p "$dir"
  for c in hammurapi-core hammurapi-web; do
    f=$dir/$c.yaml
    if ! helm lint "$ROOT/charts/$c" --set image.tag=v1.8.0 --set publicBaseDomain=34-12-5-6.sslip.io >/dev/null 2>&1 ||
      ! helm template "$c" "$ROOT/charts/$c" -n hammurapi --kube-version "$KUBE_VERSION" \
        --set image.tag=v1.8.0 --set publicBaseDomain=34-12-5-6.sslip.io >"$f" 2>&1; then
      fail "QUAL-02 $c: helm lint/template"
      continue
    fi
    kubeconform_file "$f" "$c"
    # CH-04: requests, limits, probes of long-lived containers, runAsNonRoot.
    bad=$(docs_json "$f" | jq -r '
      select(.kind | IN("Deployment", "Job", "CronJob"))
      | .kind as $k
      | (if $k == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end) as $s
      | "\($k)/\(.metadata.name)" as $o
      | $s.containers[]
      | [ (if (.resources.requests.cpu // "") == "" or (.resources.limits.memory // "") == "" then "resources" else empty end),
          (if $k == "Deployment" and (.readinessProbe == null or .livenessProbe == null) then "probes" else empty end),
          (if ((.securityContext.runAsNonRoot // $s.securityContext.runAsNonRoot // false) | not) then "runAsNonRoot" else empty end) ]
      | select(length > 0) | "\($o): \(join(", "))"')
    if [[ -n $bad ]]; then fail "CH-04 $c: $(echo "$bad" | tr '\n' ' ')"; else pass "CH-04 $c: requests, limits, probes, runAsNonRoot"; fi
  done
  # CH-07: Ingress api has only public prefixes; service ports are not published.
  # /mcp/nabu is the MCP for personal Nabu agents with their JWT (FTR.HMR.CMN-0006 R7).
  local paths ports
  paths=$(docs_json "$dir/hammurapi-core.yaml" | jq -r 'select(.kind == "Ingress" and .metadata.name == "api") | .spec.rules[].http.paths[].path' | sort | tr '\n' ' ')
  ports=$(docs_json "$dir/hammurapi-core.yaml" | jq -r 'select(.kind == "Ingress") | .spec.rules[].http.paths[].backend.service.port.name' | sort -u | tr '\n' ' ')
  if [[ $paths == "/admin/api/ /api/ /hooks/ /mcp/nabu " && $ports == "http " ]]; then
    pass "CH-07: Ingress api: /api/, /admin/api/, /hooks/, /mcp/nabu to the port http"
  else
    fail "CH-07: paths '$paths', ports '$ports'"
  fi
  # FTR.HMR.CMN-0007 HN-08: Hammurapi has no agent or runner: no operator, no roles
  # on Jobs, no internal API; Nabu service agents reach worker-mcp.
  if ! docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding")' >/dev/null &&
    ! docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Deployment" and .metadata.name == "agent")' >/dev/null &&
    ! docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Service" and .metadata.name == "api-internal")' >/dev/null &&
    docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Service" and .metadata.name == "worker-mcp")' >/dev/null; then
    pass "HN-08: no agent operator, runner or Kubernetes rights; worker-mcp is in place"
  else
    fail "HN-08: hammurapi-core still has an agent, a runner or their rights"
  fi
  # The removed ServiceAccount worker must not return through the deprecated field
  # serviceAccount of the live Deployment: the name is explicit.
  if docs_json "$dir/hammurapi-core.yaml" | jq -e 'select(.kind == "Deployment" and .metadata.name == "worker")
      | .spec.template.spec.serviceAccountName == "default"' >/dev/null; then
    pass "HN-08: worker runs explicitly under the ServiceAccount default"
  else
    fail "HN-08: worker has no serviceAccountName: default"
  fi
  # Web gets the API address on its domain.
  if docs_json "$dir/hammurapi-web.yaml" | jq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[]
      | select(.name == "API_BASE_URL" and .value == "https://hammurapi-api.34-12-5-6.sslip.io")' >/dev/null; then
    pass "R17: web has API_BASE_URL https://hammurapi-api.<domain>"
  else
    fail "R17: web has no API_BASE_URL"
  fi
}

# product_ingress — the Ingress of each product chart in both modes (FTR.INFRA.INST-0001 R17).
product_ingress() {
  printf '\nproduct ingress\n'
  local c f base=(--set image.tag=v1.0.0 --set publicBaseDomain=x.example)
  f=$OUT/ingress.yaml
  for c in hammurapi-core hammurapi-web nabu-core nabu-web; do
    helm template "$c" "$ROOT/charts/$c" -n products --kube-version "$KUBE_VERSION" "${base[@]}" >"$f" 2>&1 || { fail "R17 $c: helm template"; continue; }
    if docs_json "$f" | jq -se '[.[] | select(.kind == "Ingress")] | length > 0 and all(.spec.ingressClassName == "traefik"
        and (.metadata.annotations // {} | has("cert-manager.io/cluster-issuer") | not) and all(.spec.tls[]; has("secretName") | not))' >/dev/null; then
      pass "R17 $c: by default Traefik and its default certificate"
    else
      fail "R17 $c: the default Ingress changed"
    fi
    helm template "$c" "$ROOT/charts/$c" -n products --kube-version "$KUBE_VERSION" "${base[@]}" \
      --set-string ingress.className=nginx --set-string ingress.clusterIssuer=corp >"$f" 2>&1 || { fail "R17 $c: helm template external"; continue; }
    if docs_json "$f" | jq -se '[.[] | select(.kind == "Ingress")] | length > 0 and all(.spec.ingressClassName == "nginx"
        and .metadata.annotations["cert-manager.io/cluster-issuer"] == "corp" and all(.spec.tls[]; (.secretName // "") != ""))' >/dev/null; then
      pass "R17 $c: an external class, issuer and a secret of its own"
    else
      fail "R17 $c: the external Ingress"
    fi
  done
}

public_access_charts() {
  printf '\npublic access\n'
  local dir=$OUT/public
  mkdir -p "$dir"
  if ! helm template traefik traefik/traefik --version "$TRAEFIK_CHART_VERSION" -n ingress --kube-version "$KUBE_VERSION" \
    -f "$ROOT/values/traefik.yaml" --set-string service.spec.loadBalancerIP=192.168.49.200 >"$dir/traefik.yaml" 2>&1; then
    fail "traefik: helm template: $(head -3 "$dir/traefik.yaml")"
  else
    kubeconform_file "$dir/traefik.yaml" traefik
    local args
    args=$(docs_json "$dir/traefik.yaml" | jq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[]')
    if grep -q 'redirections.entryPoint.scheme=https' <<<"$args" && grep -q 'allowACMEByPass=true' <<<"$args" &&
      docs_json "$dir/traefik.yaml" | jq -e 'select(.kind == "TLSStore") | .spec.defaultCertificate.secretName == "greenongrey-public"' >/dev/null; then
      pass "R19: HTTP → HTTPS, HTTP-01 bypasses the redirect, default certificate greenongrey-public"
    else
      fail "R19: Traefik settings"
    fi
  fi
  if ! helm template cert-manager jetstack/cert-manager --version "$CERT_MANAGER_CHART_VERSION" -n cert-manager \
    --kube-version "$KUBE_VERSION" -f "$ROOT/values/cert-manager.yaml" >"$dir/cert-manager.yaml" 2>&1; then
    fail "cert-manager: helm template: $(head -3 "$dir/cert-manager.yaml")"
  else
    kubeconform_file "$dir/cert-manager.yaml" cert-manager
  fi
  RUN_DIR=$dir
  local missing
  missing=$(docs_json "$dir"/traefik.yaml "$dir"/cert-manager.yaml | jq -r '
    select(.kind | IN("Deployment", "Job")) | "\(.kind)/\(.metadata.name)" as $o
    | .spec.template.spec.containers[]
    | select((.resources.requests.memory // "") == "" or (.resources.limits.memory // "") == "") | "\($o)/\(.name)"')
  if [[ -n $missing ]]; then fail "RES-01 public access: $(echo "$missing" | tr '\n' ' ')"; else pass "RES-01 public access: requests and limits"; fi
  # Ingress of Grafana with GitHub OAuth (R20).
  PUBLIC_DOMAIN=34-12-5-6.sslip.io GRAFANA_GITHUB_CLIENT_ID=Iv1.x
  grafana_public_values "$dir/grafana-public.yaml"
  if helm template grafana grafana-community/grafana --version "$GRAFANA_CHART_VERSION" -n observability \
    --kube-version "$KUBE_VERSION" -f "$ROOT/values/grafana.yaml" -f "$dir/grafana-public.yaml" >"$dir/grafana.yaml" 2>&1 &&
    docs_json "$dir/grafana.yaml" | jq -e 'select(.kind == "Ingress") | .spec.rules[0].host == "grafana.34-12-5-6.sslip.io"' >/dev/null &&
    docs_json "$dir/grafana.yaml" | jq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "grafana")
      | .envFrom[]? | select(.secretRef.name == "grafana-github-oauth")' >/dev/null; then
    pass "R20: Ingress grafana.<domain>, the GitHub OAuth secret"
  else
    fail "R20: Grafana with public access: $(head -3 "$dir/grafana.yaml")"
  fi
}

main() {
  if [[ ${SKIP_REPOS:-0} != 1 ]]; then
    RUN_DIR=$OUT
    mkdir -p "$OUT"
    helm_repos
  fi
  local combo pg kafka s3 first=1
  for combo in iii iie iei iee eii eie eei eee; do
    pg=${combo:0:1} kafka=${combo:1:1} s3=${combo:2:1}
    POSTGRES_MODE=$([[ $pg == i ]] && echo internal || echo external)
    KAFKA_MODE=$([[ $kafka == i ]] && echo internal || echo external)
    S3_MODE=$([[ $s3 == i ]] && echo internal || echo external)
    POSTGRES_HOST=pg.example.internal POSTGRES_PORT=5432
    KAFKA_BOOTSTRAP=bootstrap.kafka.example.internal:9092
    S3_ENDPOINT=https://storage.googleapis.com
    local label="postgres=$POSTGRES_MODE kafka=$KAFKA_MODE s3=$S3_MODE" dir=$OUT/$combo
    printf '\n%s\n' "$label"
    # Render output goes to a log next to the combination's directory (render clears it):
    # on an error it shows what broke, such as downloading an external chart.
    (render "$dir") >"$OUT/render-$combo.log" 2>&1 || {
      fail "render $label: $(tail -5 "$OUT/render-$combo.log" "$dir"/helm-*.log 2>/dev/null | grep -v '^==>' | grep -v '^$' | tail -5 | tr '\n' ' ')"
      continue
    }
    if ((first)); then
      crd_schemas "$dir"
      first=0
    fi
    kubeconform_dir "$dir" "$label"
    check_resources "$dir" "$label"
    check_service_types "$dir" "$label"
    check_storage_services "$dir" "$label"
    check_scrape_jobs "$dir" "$label"
    check_internal_releases "$dir" "$label"
  done

  printf '\nexternal Postgres by IP\n'
  POSTGRES_MODE=external KAFKA_MODE=internal S3_MODE=internal POSTGRES_HOST=10.20.0.5
  (render "$OUT/ip") >/dev/null 2>&1 || true
  if docs_json "$OUT/ip/helm-storages.log" | jq -e 'select(.kind == "EndpointSlice" and .endpoints[0].addresses[0] == "10.20.0.5"
      and .metadata.labels["kubernetes.io/service-name"] == "postgres")' >/dev/null &&
    docs_json "$OUT/ip/helm-storages.log" | jq -e 'select(.kind == "Service" and .metadata.name == "postgres" and (.spec.selector == null))' >/dev/null; then
    pass "EXT-02: the service postgres without a selector and an EndpointSlice with 10.20.0.5"
  else
    fail "EXT-02: no service without a selector or EndpointSlice for the IP"
  fi

  printf '\nretention\n'
  local vm vl
  vm=$(docs_json "$OUT/iii/helm-victoria-metrics.log" | jq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' | grep -c -- '-retentionPeriod=7d' || true)
  vl=$(docs_json "$OUT/iii/helm-victoria-logs.log" | jq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' | grep -c -- '-retentionPeriod=3d' || true)
  if [[ $vm == 1 && $vl == 1 ]]; then pass "OBS-02: retentionPeriod 7d and 3d"; else fail "OBS-02: retentionPeriod of metrics/logs is not 7d/3d"; fi
  POSTGRES_MODE=internal VM_RETENTION=14d VL_RETENTION=1d
  (render "$OUT/retention") >/dev/null 2>&1 || true
  vm=$(docs_json "$OUT/retention/helm-victoria-metrics.log" | jq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' | grep -c -- '-retentionPeriod=14d' || true)
  vl=$(docs_json "$OUT/retention/helm-victoria-logs.log" | jq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' | grep -c -- '-retentionPeriod=1d' || true)
  if [[ $vm == 1 && $vl == 1 ]]; then pass "OBS-02: values from the configuration apply"; else fail "OBS-02: VM_RETENTION/VL_RETENTION did not apply"; fi

  printf '\nlocal charts\n'
  if helm lint "$ROOT/charts/hammurapi-storages" --set kafka.version=4 --set postgres.image=x >/dev/null &&
    helm lint "$OUT/iii/work/hammurapi-dashboards" >/dev/null; then pass "QUAL-02: helm lint of local charts"; else fail "QUAL-02: helm lint"; fi

  hammurapi_charts
  nabu_charts
  landing_chart
  public_access_charts
  product_ingress
  mcp_chart

  if ((FAILURES)); then
    printf '\n%sChecks failed: %d%s\n' "$C_RED" "$FAILURES" "$C_RESET"
    exit 1
  fi
  printf '\n%sAll manifest checks passed%s\n' "$C_GREEN" "$C_RESET"
}

main "$@"
