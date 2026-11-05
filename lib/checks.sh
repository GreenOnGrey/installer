# shellcheck shell=bash disable=SC2016
# SC2016: probe scripts are in single quotes on purpose: they run inside containers.
# Checks of the stand (R14, R15). Everything runs inside the cluster and nothing
# is exposed. Probe pods and Jobs are removed after the check.

VM_URL="http://victoria-metrics-victoria-metrics-single-server:8428"
VL_URL="http://victoria-logs-victoria-logs-single-server:9428"
GRAFANA_URL="http://grafana"
PROBE_TOPIC=installer-probe

# Check results: name|ok|message or name|fail|message.
CHECK_RESULTS=()
MEM_REQUESTED=0 MEM_ALLOCATABLE=0

record() { CHECK_RESULTS+=("$1|$2|$3"); }

probe_id() { openssl rand -hex 6; }

# Suffix of this run's probe pods and Jobs: two deploys running at the same time
# do not delete each other's probes. Abandoned probes end on their own
# (activeDeadlineSeconds, ttlSecondsAfterFinished).
PROBE_RUN=${PROBE_RUN:-$(probe_id)}
CHECKS_PROBE="checks-probe-$PROBE_RUN"
LOG_PROBE="log-probe-$PROBE_RUN"

# expected_jobs — scrape jobs of the current configuration (R8).
expected_jobs() {
  local jobs=(kubelet cadvisor apiserver node-exporter kube-state-metrics stack)
  [[ $KAFKA_MODE == internal ]] && jobs+=(kafka kafka-exporter)
  [[ $POSTGRES_MODE == internal ]] && jobs+=(postgres)
  [[ $S3_MODE == internal ]] && jobs+=(s3)
  [[ $KAFKA_MODE == internal || $POSTGRES_MODE == internal ]] && jobs+=(operators)
  printf '%s\n' "${jobs[@]}"
}

# --- Probe pods ---

probe_resources() {
  printf '      resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { cpu: 200m, memory: %s } }\n' "${1:-128Mi}"
}

checks_probe_manifest() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $CHECKS_PROBE
  namespace: $NS_OBSERVABILITY
  labels: { app.kubernetes.io/name: checks-probe, app.kubernetes.io/managed-by: installer }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 900
  terminationGracePeriodSeconds: 1
  containers:
    - name: curl
      image: $PROBE_CURL_IMAGE
      command: ["sh", "-c", "sleep 600"]
      env:
        - { name: GF_USER, valueFrom: { secretKeyRef: { name: grafana-admin, key: admin-user } } }
        - { name: GF_PASS, valueFrom: { secretKeyRef: { name: grafana-admin, key: admin-password } } }
$(probe_resources)
EOF
}

log_probe_manifest() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $LOG_PROBE
  namespace: $NS_STORAGES
  labels: { app.kubernetes.io/name: log-probe, app.kubernetes.io/managed-by: installer }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 900
  terminationGracePeriodSeconds: 1
  containers:
    - name: probe
      image: $PROBE_BUSYBOX_IMAGE
      command: ["sh", "-c", "while true; do echo installer-probe-$1; sleep 5; done"]
$(probe_resources 32Mi)
EOF
}

# Container scripts of the storage probe. MODE=check tests access only
# (before the deploy, external mode), MODE=full writes and reads.
readonly PG_PROBE='
export PGHOST="$PG_host" PGPORT="$PG_port" PGUSER="$PG_username" PGPASSWORD="$PG_password" PGDATABASE="$PG_database" PGSSLMODE="$PG_sslmode" PGCONNECT_TIMEOUT=10
if [ "$MODE" = check ]; then
  pg_isready -q -t 10 || { echo "Postgres: $PG_host:$PG_port is unreachable"; exit 1; }
  exit 0
fi
out=$(psql -tAc "select 1" 2>&1)
if [ "$out" = 1 ]; then echo "Postgres: select 1 — ok"; exit 0; fi
case "$out" in
  *"password authentication failed"*|*"authentication failed"*) echo "Postgres: authentication failed" ;;
  *"could not connect"*|*"timeout"*|*"Connection refused"*) echo "Postgres: $PG_host:$PG_port is unreachable" ;;
  *) echo "Postgres: $(echo "$out" | head -1)" ;;
esac
exit 1'

readonly KAFKA_PROBE='
conf=/tmp/kcat.conf
{
  echo "bootstrap.servers=$KAFKA_bootstrap_servers"
  echo "security.protocol=$KAFKA_security_protocol"
  if [ "$KAFKA_security_protocol" = SASL_SSL ] && [ "$KAFKA_sasl_mechanism" != OAUTHBEARER ]; then
    echo "sasl.mechanisms=$KAFKA_sasl_mechanism"
    echo "sasl.username=$KAFKA_username"
    echo "sasl.password=$KAFKA_password"
  fi
} > "$conf"
if [ "$KAFKA_sasl_mechanism" = OAUTHBEARER ]; then
  # The application obtains the OAUTHBEARER token; the probe tests TCP only.
  for hp in $(echo "$KAFKA_bootstrap_servers" | tr "," " "); do
    nc -z -w 10 "${hp%:*}" "${hp##*:}" || { echo "Kafka: $hp is unreachable"; exit 1; }
  done
  echo "Kafka: OAUTHBEARER, only the TCP connection was checked"; exit 0
fi
if [ "$MODE" = check ]; then
  kcat -F "$conf" -L -m 15 >/dev/null 2>/tmp/err || { echo "Kafka: $KAFKA_bootstrap_servers is unreachable: $(head -1 /tmp/err)"; exit 1; }
  exit 0
fi
i=0
until echo "$PROBE_ID" | kcat -F "$conf" -P -t '"$PROBE_TOPIC"' -m 15 2>/tmp/err; do
  i=$((i+1)); [ $i -ge 6 ] && { echo "Kafka: write failed: $(head -1 /tmp/err)"; exit 1; }
  sleep 5
done
kcat -F "$conf" -C -t '"$PROBE_TOPIC"' -o -20 -e -q -m 15 2>/tmp/err | grep -q "$PROBE_ID" ||
  { echo "Kafka: the written message was not read back $(head -1 /tmp/err)"; exit 1; }
echo "Kafka: write and read ok"'

readonly S3_PROBE='
export HOME=/tmp AWS_ACCESS_KEY_ID="$S3_access_key" AWS_SECRET_ACCESS_KEY="$S3_secret_key" AWS_DEFAULT_REGION="$S3_region" \
  AWS_EC2_METADATA_DISABLED=true AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
[ "$S3_path_style" = true ] && aws configure set default.s3.addressing_style path
s3() { aws --endpoint-url "$S3_endpoint" "$@"; }
if [ "$MODE" = check ]; then
  s3 s3api head-bucket --bucket "$S3_bucket" >/dev/null 2>/tmp/err || { echo "S3: bucket $S3_bucket at $S3_endpoint is unreachable: $(tail -1 /tmp/err)"; exit 1; }
  exit 0
fi
key="installer-probe/$PROBE_ID"
echo "$PROBE_ID" | s3 s3 cp - "s3://$S3_bucket/$key" >/dev/null 2>/tmp/err || { echo "S3: write failed: $(tail -1 /tmp/err)"; exit 1; }
s3 s3 cp "s3://$S3_bucket/$key" - 2>/tmp/err | grep -q "$PROBE_ID" || { echo "S3: read failed: $(tail -1 /tmp/err)"; exit 1; }
s3 s3 rm "s3://$S3_bucket/$key" >/dev/null 2>/tmp/err || { echo "S3: delete failed: $(tail -1 /tmp/err)"; exit 1; }
echo "S3: write, read and delete ok"'

# yaml_block <text> — a YAML multi-line scalar with the container indent.
yaml_block() { printf '%s\n' "$1" | sed 's/^/            /'; }

# probe_job_manifest <name> <check|full> <pg|-> <kafka|-> <s3|->
probe_job_manifest() {
  local name=$1 mode=$2 id
  id=$(probe_id)
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name-$PROBE_RUN
  namespace: $NS_STORAGES
  labels: { app.kubernetes.io/name: $name, app.kubernetes.io/managed-by: installer }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 180
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      # A label on the pod itself: check_pods of another run skips probes by it.
      labels: { app.kubernetes.io/name: $name, app.kubernetes.io/managed-by: installer }
    spec:
      restartPolicy: Never
      containers:
EOF
  if [[ $3 == pg ]]; then
    cat <<EOF
        - name: postgres
          image: $POSTGRES_IMAGE
          command: ["sh", "-c"]
          args:
          - |
$(yaml_block "$PG_PROBE")
          env: [{ name: MODE, value: $mode }]
          envFrom: [{ prefix: PG_, secretRef: { name: postgres-conn } }]
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { cpu: 200m, memory: 128Mi } }
EOF
  fi
  if [[ $4 == kafka ]]; then
    cat <<EOF
        - name: kafka
          image: $PROBE_KCAT_IMAGE
          command: ["sh", "-c"]
          args:
          - |
$(yaml_block "$KAFKA_PROBE")
          env: [{ name: MODE, value: $mode }, { name: PROBE_ID, value: "$id" }]
          envFrom: [{ prefix: KAFKA_, secretRef: { name: kafka-conn } }]
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { cpu: 200m, memory: 128Mi } }
EOF
  fi
  if [[ $5 == s3 ]]; then
    cat <<EOF
        - name: s3
          image: $PROBE_S3_IMAGE
          command: ["sh", "-c"]
          args:
          - |
$(yaml_block "$S3_PROBE")
          env: [{ name: MODE, value: $mode }, { name: PROBE_ID, value: "$id" }]
          envFrom: [{ prefix: S3_, secretRef: { name: s3-conn } }]
          resources: { requests: { cpu: 10m, memory: 64Mi }, limits: { cpu: 500m, memory: 256Mi } }
EOF
  fi
}

# run_probe_job <name> <timeout, s> <manifest from stdin> — prints container
# messages; code 0 if all containers succeeded.
run_probe_job() {
  local name=$1-$PROBE_RUN timeout=$2 deadline status rc=0 c msg
  kc create -f - >/dev/null || return 1
  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    status=$(kc -n "$NS_STORAGES" get job "$name" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)
    [[ $status == 1/* || $status == */1 ]] && break
    sleep 3
  done
  local pod
  pod=$(kc -n "$NS_STORAGES" get pod -l "job-name=$name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z $pod ]]; then
    echo "$name: the pod was not created"
    rc=1
  else
    for c in $(kc -n "$NS_STORAGES" get pod "$pod" -o jsonpath='{.spec.containers[*].name}'); do
      local code
      code=$(kc -n "$NS_STORAGES" get pod "$pod" -o "jsonpath={.status.containerStatuses[?(@.name=='$c')].state.terminated.exitCode}")
      msg=$(kc -n "$NS_STORAGES" logs "$pod" -c "$c" --tail=5 2>/dev/null | tail -1)
      if [[ $code == 0 ]]; then
        [[ -n $msg ]] && echo "ok|$msg"
      else
        [[ -z $code ]] && msg="$c: did not finish in $timeout s"
        echo "fail|${msg:-$c: code $code}"
        rc=1
      fi
    done
  fi
  kc -n "$NS_STORAGES" delete job "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  return $rc
}

# --- Checks ---

check_pods() {
  local ns failed=0 out
  for ns in $(stand_namespaces); do
    # Pods of finished Jobs and probe pods do not count.
    if ! out=$(kc -n "$ns" wait --for=condition=Ready pod \
      --field-selector=status.phase!=Succeeded,status.phase!=Failed \
      -l 'app.kubernetes.io/managed-by notin (installer,hammurapi-infra)' --timeout="$CHECK_TIMEOUT" 2>&1); then
      # All storages external and observability off: an empty namespace is fine.
      [[ $out == *"no matching resources"* ]] && continue
      record pods fail "$ns: not all pods are ready: $(echo "$out" | grep -v 'condition met' | head -3 | tr '\n' ' ')"
      failed=1
    fi
  done
  ((failed)) || record pods ok "all pods in $(stand_namespaces | paste -sd' ' | sed 's/ / and /') are ready"
}

start_probe_pods() {
  kc -n "$NS_OBSERVABILITY" delete pod "$CHECKS_PROBE" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  checks_probe_manifest | kc create -f - >/dev/null
  kc -n "$NS_OBSERVABILITY" wait --for=condition=Ready "pod/$CHECKS_PROBE" --timeout=120s >/dev/null
}

probe_curl() { kc -n "$NS_OBSERVABILITY" exec "$CHECKS_PROBE" -c curl -- curl -sS -m 15 "$@"; }

vm_query() { probe_curl "$VM_URL/api/v1/query" --data-urlencode "query=$1"; }

check_metrics() {
  local deadline=$((SECONDS + 150)) jobs down missing job
  while :; do
    jobs=$(vm_query 'count by (job) (up)' 2>/dev/null | jq -r '.data.result[].metric.job' 2>/dev/null | sort -u || true)
    # The hammurapi job is optional: a failing Hammurapi must not block its own rollout.
    down=$(vm_query 'up{job!="hammurapi"} == 0' 2>/dev/null | jq -r '.data.result[].metric | "\(.job)/\(.instance)"' 2>/dev/null || true)
    missing=""
    while read -r job; do
      grep -qx "$job" <<<"$jobs" || missing+="$job "
    done < <(expected_jobs)
    [[ -z $missing && -z $down ]] && break
    ((SECONDS >= deadline)) && break
    sleep 10
  done
  if [[ -n $missing ]]; then
    record metrics fail "no scrape targets for jobs: ${missing% }"
  elif [[ -n $down ]]; then
    record metrics fail "scrape targets are down: $(echo "$down" | tr '\n' ' ')"
  else
    record metrics ok "all scrape jobs are active: $(echo "$jobs" | tr '\n' ' ')"
  fi
}

check_logs() {
  local id deadline found=""
  id=$(probe_id)
  kc -n "$NS_STORAGES" delete pod "$LOG_PROBE" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  log_probe_manifest "$id" | kc create -f - >/dev/null
  kc -n "$NS_STORAGES" wait --for=condition=Ready "pod/$LOG_PROBE" --timeout=120s >/dev/null 2>&1 || true
  # Time for Vector to find the new file and flush to VictoriaLogs.
  deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    found=$(probe_curl "$VL_URL/select/logsql/query" --data-urlencode "query=\"installer-probe-$id\"" \
      --data-urlencode limit=1 2>/dev/null | head -1 || true)
    [[ -n $found ]] && break
    sleep 5
  done
  kc -n "$NS_STORAGES" delete pod "$LOG_PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [[ -z $found ]]; then
    record logs fail "logs do not reach VictoriaLogs"
  elif [[ $(jq -r '[.namespace, .pod, .container, .node] | map(. != null and . != "") | all' <<<"$found" 2>/dev/null) != true ||
    $(jq -r .namespace <<<"$found" 2>/dev/null) != "$NS_STORAGES" ]]; then
    record logs fail "the VictoriaLogs record has no namespace, pod, container, node fields"
  else
    record logs ok "a log line from $NS_STORAGES was found in VictoriaLogs"
  fi
}

check_grafana() {
  local health uid failed=""
  health=$(probe_curl "$GRAFANA_URL/api/health" 2>/dev/null | jq -r .database 2>/dev/null || true)
  if [[ $health != ok ]]; then
    record grafana fail "Grafana does not answer on /api/health"
    return
  fi
  for uid in victoriametrics victorialogs; do
    # The shell of the probe pod fills in credentials from its environment.
    if ! kc -n "$NS_OBSERVABILITY" exec "$CHECKS_PROBE" -c curl -- sh -c \
      "curl -sS -m 15 -u \"\$GF_USER:\$GF_PASS\" $GRAFANA_URL/api/datasources/uid/$uid/health" 2>/dev/null |
      jq -e '.status == "OK"' >/dev/null 2>&1; then
      failed+="$uid "
    fi
  done
  if [[ -n $failed ]]; then
    record grafana fail "data sources do not answer: ${failed% }"
  else
    record grafana ok "Grafana and both data sources answer"
  fi
}

check_storages() {
  local out rc=0 line msgs=() errs=()
  out=$(probe_job_manifest storage-probe full pg kafka s3 | run_probe_job storage-probe 150) || rc=$?
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    case $line in
      ok\|*) msgs+=("${line#ok|}") ;;
      fail\|*) errs+=("${line#fail|}") ;;
      *) errs+=("$line") ;;
    esac
  done <<<"$out"
  if ((rc != 0 || ${#errs[@]})); then
    record storages fail "$(printf '%s; ' "${errs[@]:-the storage probe did not run}")"
  else
    record storages ok "$(printf '%s; ' "${msgs[@]}")"
  fi
}

# collect_resources — total memory requests and containers without requests or limits.
check_resources() {
  local pods missing ns
  pods=$(for ns in $(stand_namespaces); do kc get pods -n "$ns" -o json; done
    if mcp_enabled; then kc get pods -n "$NS_MCP" -l 'app.kubernetes.io/part-of=mcp-servers' -o json; fi)
  missing=$(jq -rs '[.[].items[] | select(.status.phase == "Running" or .status.phase == "Pending")
      | .metadata.namespace as $ns | .metadata.name as $p
      | (.spec.containers + (.spec.initContainers // []))[]
      | select((.resources.requests.cpu // "") == "" or (.resources.requests.memory // "") == ""
          or (.resources.limits.cpu // "") == "" or (.resources.limits.memory // "") == "")
      | "\($ns)/\($p)/\(.name)"] | join(" ")' <<<"$pods")
  MEM_REQUESTED=0
  local q
  while read -r q; do
    MEM_REQUESTED=$((MEM_REQUESTED + $(to_bytes "$q")))
  done < <(jq -rs '.[].items[] | select(.status.phase == "Running" or .status.phase == "Pending")
      | .spec.containers[] | .resources.requests.memory // empty' <<<"$pods")
  MEM_ALLOCATABLE=$(to_bytes "$(kc get nodes -o jsonpath='{.items[0].status.allocatable.memory}')")
  local pct=0
  ((MEM_ALLOCATABLE > 0)) && pct=$((MEM_REQUESTED * 100 / MEM_ALLOCATABLE))
  local summary
  summary="requested $(gib "$MEM_REQUESTED") of $(gib "$MEM_ALLOCATABLE") GiB ($pct%)"
  if [[ -n $missing ]]; then
    record resources fail "no requests or limits: $missing"
  elif ((MEM_REQUESTED * 3 > MEM_ALLOCATABLE * 2)); then
    record resources fail "$summary, more than two thirds of the node memory"
  else
    record resources ok "$summary"
  fi
}

gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

cleanup_probes() {
  kc -n "$NS_OBSERVABILITY" delete pod "$CHECKS_PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kc -n "$NS_STORAGES" delete pod "$LOG_PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kc -n "$NS_STORAGES" delete job "storage-probe-$PROBE_RUN" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# run_checks — all checks; code 0 if all pass.
run_checks() {
  step checks
  CHECK_RESULTS=()
  check_pods
  if ! observability_enabled; then
    debug "observability is off: no checks of Grafana, metrics and logs"
  elif start_probe_pods; then
    check_grafana
    check_metrics
    check_logs
  else
    record grafana fail "the probe pod checks-probe did not start"
    record metrics fail "the probe pod checks-probe did not start"
    record logs fail "the probe pod checks-probe did not start"
  fi
  check_storages
  check_mcp
  check_resources
  check_public
  cleanup_probes
  local r name state msg failed=0
  for r in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r name state msg <<<"$r"
    if [[ $state == ok ]]; then ok "$name: $msg"; else
      warn "$name: $msg"
      failed=1
    fi
  done
  return $failed
}

# first_failure — the message of the first failed check.
first_failure() {
  local r name state msg
  for r in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r name state msg <<<"$r"
    [[ $state == fail ]] && {
      echo "$msg"
      return
    }
  done
}
