#!/usr/bin/env bash
# End-to-end on a temporary Google Cloud machine (QA, level E). Run manually
# before a release of the repository and when config/versions.env, values/, charts/ change.
#
#   GCP_PROJECT=… GCP_ZONE=europe-west1-b tests/e2e/e2e.sh
#
# Creates an e2-standard-4 machine with a clean E2E_OS (debian-13 by default; ubuntu-2404, ubuntu-2604), copies the working copy,
# runs the scenarios and deletes the machine. Stage times are in the report (success metrics).
# E2E_UPGRADE_FROM=<tag> runs only the upgrade from that tag (PROD-01).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${GCP_PROJECT:?}" "${GCP_ZONE:?}"
INSTANCE=${GCP_INSTANCE:-installer-e2e-$(date -u +%Y%m%d%H%M%S)}
MACHINE_TYPE=${MACHINE_TYPE:-e2-standard-4}
REPORT=${REPORT:-$ROOT/.work/e2e-report.md}
KEEP=${KEEP:-0}
E2E_OS=${E2E_OS:-debian-13}
case $E2E_OS in
  debian-13) IMAGE=(--image-family debian-13 --image-project debian-cloud) OS_NAME="Debian 13" ;;
  ubuntu-2404) IMAGE=(--image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud) OS_NAME="Ubuntu 24.04" ;;
  ubuntu-2604) IMAGE=(--image-family ubuntu-2604-lts-amd64 --image-project ubuntu-os-cloud) OS_NAME="Ubuntu 26.04" ;;
  *) echo "E2E_OS: debian-13, ubuntu-2404 or ubuntu-2604, not $E2E_OS" >&2; exit 2 ;;
esac
REMOTE_DIR=installer
FAILED=0

mkdir -p "$(dirname "$REPORT")"
{
  echo "# e2e installer — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Machine: $MACHINE_TYPE, $OS_NAME, $GCP_ZONE. Commit: $(git -C "$ROOT" rev-parse --short HEAD)."
  echo
  echo "| ID | Scenario | Result | Time, s |"
  echo "|---|---|---|---|"
} >"$REPORT"

g() { gcloud --project "$GCP_PROJECT" --quiet "$@"; }
# E2E_IAP=1: sign in through IAP (port 22 of the machine is closed outside).
IAP_ARGS=()
[[ ${E2E_IAP:-0} == 1 ]] && IAP_ARGS=(--tunnel-through-iap)
on_vm() { g compute ssh "$INSTANCE" --zone "$GCP_ZONE" "${IAP_ARGS[@]}" --command "cd $REMOTE_DIR && $1"; }

# stage <ID> <description> <command on the machine> [expected code]
stage() {
  local id=$1 title=$2 cmd=$3 expect=${4:-0} start rc=0 took mark
  echo "=== $id: $title"
  start=$SECONDS
  on_vm "$cmd" || rc=$?
  took=$((SECONDS - start))
  if [[ $rc == "$expect" ]]; then mark="✓"; else
    mark="✗ (code $rc, expected $expect)"
    FAILED=$((FAILED + 1))
  fi
  echo "| $id | $title | $mark | $took |" >>"$REPORT"
}

cleanup() {
  if [[ $KEEP != 1 ]]; then
    g compute instances delete "$INSTANCE" --zone "$GCP_ZONE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== creating machine $INSTANCE"
g compute instances create "$INSTANCE" --zone "$GCP_ZONE" --machine-type "$MACHINE_TYPE" \
  "${IMAGE[@]}" --boot-disk-size 100GB --boot-disk-type pd-balanced \
  --metadata enable-oslogin=TRUE >/dev/null
for _ in $(seq 1 30); do on_vm true 2>/dev/null && break || sleep 10; done 2>/dev/null || true
git -C "$ROOT" archive --format=tar.gz --prefix="$REMOTE_DIR/" HEAD >"$ROOT/.work/e2e.tar.gz"
g compute scp "$ROOT/.work/e2e.tar.gz" "$INSTANCE:e2e.tar.gz" --zone "$GCP_ZONE" "${IAP_ARGS[@]}"
g compute ssh "$INSTANCE" --zone "$GCP_ZONE" "${IAP_ARGS[@]}" --command "tar -xzf e2e.tar.gz && rm e2e.tar.gz"

# The stand only: the products need sign-in, which e2e has not.
H="env PRODUCTS= bash ./installer"

# PROD-01 (FTR.INFRA.INST-0001 R26): the tag of prod with the names of prod, then this commit on top.
if [[ -n ${E2E_UPGRADE_FROM:-} ]]; then
  OLD=../installer-old PINNED=../pinned.env HMR="kubectl --context hammurapi"
  SECRETS="jq -S '[.items[] | {n: .metadata.name, d: .data}] | sort_by(.n)'"
  PODS="$HMR get pods -A -o json | jq -S '[.items[] | {n: .metadata.name, uid: .metadata.uid, r: [.status.containerStatuses[]?.restartCount]}]'"
  git -C "$ROOT" archive --format=tar.gz --prefix=installer-old/ "$E2E_UPGRADE_FROM" >"$ROOT/.work/e2e-old.tar.gz"
  g compute scp "$ROOT/.work/e2e-old.tar.gz" "$INSTANCE:e2e-old.tar.gz" --zone "$GCP_ZONE" "${IAP_ARGS[@]}"
  g compute ssh "$INSTANCE" --zone "$GCP_ZONE" "${IAP_ARGS[@]}" --command \
    "tar -xzf e2e-old.tar.gz && rm e2e-old.tar.gz && printf 'MK_PROFILE=hammurapi\nUNIT_PREFIX=hammurapi\nCERT_NAME=hammurapi-public\n' >pinned.env"
  stage PROD-01a "up of $E2E_UPGRADE_FROM with the names of prod" "cd $OLD && bash \$(ls installer hammurapi-infra.sh 2>/dev/null | head -1) up --no-color --config $PINNED"
  on_vm "sleep 15; $PODS >/tmp/pods-before.json;
    $HMR get secret -A -l app.kubernetes.io/managed-by=hammurapi-infra -o json | $SECRETS >/tmp/secrets-before.json" || true
  stage PROD-01 "up of this commit restarts no pod and keeps passwords" \
    "$H up --no-color --config $PINNED && sleep 15 && $PODS | diff -q - /tmp/pods-before.json &&
     $HMR get secret -A -l app.kubernetes.io/managed-by=installer -o json | $SECRETS | diff -q - /tmp/secrets-before.json"
  stage PROD-01b "the old label is gone, the units and the profile keep their names" \
    "! $HMR get secret,cm -A -l app.kubernetes.io/managed-by=hammurapi-infra --no-headers 2>/dev/null | grep -q . &&
     systemctl is-active --quiet hammurapi-stand && test -f /usr/local/lib/installer/stand-autostart &&
     $H status --no-color --config $PINNED"
  { echo; echo "Failed: $FAILED."; } >>"$REPORT"
  cat "$REPORT"
  exit $((FAILED > 0))
fi

stage UP-01 "up on a clean machine (target ≤ 20 min)" "$H up --no-color"
stage CMD-01 "status --json" "$H status --json --no-color | jq -e '.ok and (.checks | length) >= 6'"
stage CMD-02 "creds: addresses and passwords of all storages and Grafana" \
  "$H creds --json | jq -e '.postgres.password != \"\" and .s3.secret_key != \"\" and .grafana.password != \"\" and .kafka.bootstrap_servers != \"\"'"
stage OBS-04 "seven dashboards in the folder Hammurapi Infra" \
  "kubectl --context greenongrey -n observability get cm -l grafana_dashboard=1 -o name | wc -l | grep -qx 7"
stage OBS-05 "sign-in to Grafana without a password is forbidden" \
  "kubectl --context greenongrey -n observability run gf-anon --rm -i --restart=Never --image=curlimages/curl:8.22.0 -- \
     curl -s -o /dev/null -w '%{http_code}' http://grafana/api/dashboards/uid/hammurapi-kafka | grep -qx 401"

# UP-02, SEC-02: a repeated up restarts no pod and keeps passwords.
on_vm "kubectl --context greenongrey get pods -A -o json | jq -S '[.items[] | {n: .metadata.name, uid: .metadata.uid, r: [.status.containerStatuses[]?.restartCount]}]' >/tmp/pods-before.json;
  kubectl --context greenongrey get secret -A -l app.kubernetes.io/managed-by=installer -o json | jq -S '[.items[] | {n: .metadata.name, d: .data}]' >/tmp/secrets-before.json" || true
stage UP-02 "a repeated up without changes (target ≤ 3 min)" "$H up --no-color"
stage SEC-02 "a repeated up changes no passwords or pods" \
  "kubectl --context greenongrey get secret -A -l app.kubernetes.io/managed-by=installer -o json | jq -S '[.items[] | {n: .metadata.name, d: .data}]' | diff -q - /tmp/secrets-before.json &&
   kubectl --context greenongrey get pods -A -o json | jq -S '[.items[] | {n: .metadata.name, uid: .metadata.uid, r: [.status.containerStatuses[]?.restartCount]}]' | diff -q - /tmp/pods-before.json"

# PERS: data survive minikube stop/start and a machine reboot.
PG="kubectl --context greenongrey -n storages exec hammurapi-pg-1 -c postgres --"
stage PERS-01a "writing data to Postgres" "$PG psql -U postgres -d hammurapi -c 'create table if not exists e2e(v text); insert into e2e values (\$\$persist\$\$)'"
stage PERS-01 "minikube stop and up: data are in place" \
  "minikube stop -p greenongrey && $H up --no-color && $PG psql -U postgres -d hammurapi -tAc 'select v from e2e' | grep -qx persist"
echo "=== rebooting the machine"
g compute instances reset "$INSTANCE" --zone "$GCP_ZONE" >/dev/null
sleep 60
for _ in $(seq 1 30); do on_vm true 2>/dev/null && break || sleep 10; done 2>/dev/null || true
stage PERS-04 "after a reboot the cluster and components came back without up" \
  "timeout 1800 bash -c 'until systemctl is-active --quiet greenongrey-stand; do sleep 10; done' &&
   $H status --no-color && $PG psql -U postgres -d hammurapi -tAc 'select v from e2e' | grep -qx persist"
stage PERS-02 "a reboot and up: data and passwords are the same" \
  "$H up --no-color && $PG psql -U postgres -d hammurapi -tAc 'select v from e2e' | grep -qx persist &&
   kubectl --context greenongrey get secret -A -l app.kubernetes.io/managed-by=installer -o json | jq -S '[.items[] | {n: .metadata.name, d: .data}]' | diff -q - /tmp/secrets-before.json"

# CHK: the checks catch real failures.
stage CHK-01 "VictoriaLogs at 0: status code 15, logs do not reach it" \
  "kubectl --context greenongrey -n observability scale statefulset victoria-logs-victoria-logs-single-server --replicas=0 &&
   { $H status --no-color >/tmp/chk01.txt 2>&1; rc=\$?; }; grep -q 'logs do not reach VictoriaLogs' /tmp/chk01.txt && exit \$rc; exit 99" 15
stage CHK-03 "a wrong password in postgres-conn: Postgres authentication failed" \
  "kubectl --context greenongrey -n observability scale statefulset victoria-logs-victoria-logs-single-server --replicas=1 &&
   kubectl --context greenongrey -n storages patch secret postgres-conn -p '{\"data\":{\"password\":\"d3Jvbmc=\"}}' &&
   { $H status --no-color >/tmp/chk03.txt 2>&1; rc=\$?; }; grep -q 'Postgres: authentication failed' /tmp/chk03.txt && exit \$rc; exit 99" 15
stage CHK-04 "after the checks probe pods and Jobs are gone" \
  "sleep 15; ! kubectl --context greenongrey get pods -A -l app.kubernetes.io/managed-by=installer --no-headers 2>/dev/null | grep -q ."
stage UP-04 "up restores the stand after failures" "$H up --no-color"

stage CMD-04 "uninstall --yes: the profile is deleted" "$H uninstall --yes --no-color && ! minikube profile list 2>/dev/null | grep -q greenongrey"
stage PERS-03 "down and up: a clean stand, new passwords" \
  "$H up --no-color && kubectl --context greenongrey get secret -A -l app.kubernetes.io/managed-by=installer -o json | jq -S '[.items[] | {n: .metadata.name, d: .data}]' | ! diff -q - /tmp/secrets-before.json >/dev/null"

{
  echo
  echo "Failed: $FAILED."
} >>"$REPORT"
cat "$REPORT"
((FAILED == 0))
