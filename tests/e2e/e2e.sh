#!/usr/bin/env bash
# End-to-end на временной машине Google Cloud (QA, уровень E). Запуск вручную:
# перед релизом репозитория и при изменении config/versions.env, values/, charts/.
#
#   GCP_PROJECT=… GCP_ZONE=europe-west1-b tests/e2e/e2e.sh
#
# Создаёт машину e2-standard-4 с чистым Debian 13, копирует рабочую копию,
# прогоняет сценарии и удаляет машину. Время этапов — в отчёте (метрики успеха).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${GCP_PROJECT:?}" "${GCP_ZONE:?}"
INSTANCE=${GCP_INSTANCE:-hammurapi-infra-e2e-$(date -u +%Y%m%d%H%M%S)}
MACHINE_TYPE=${MACHINE_TYPE:-e2-standard-4}
REPORT=${REPORT:-$ROOT/.work/e2e-report.md}
KEEP=${KEEP:-0}
REMOTE_DIR=hammurapi-infra
FAILED=0

mkdir -p "$(dirname "$REPORT")"
{
  echo "# e2e hammurapi-infra — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Машина: $MACHINE_TYPE, Debian 13, $GCP_ZONE. Коммит: $(git -C "$ROOT" rev-parse --short HEAD)."
  echo
  echo "| ID | Сценарий | Итог | Время, с |"
  echo "|---|---|---|---|"
} >"$REPORT"

g() { gcloud --project "$GCP_PROJECT" --quiet "$@"; }
# E2E_IAP=1 — вход через IAP (порт 22 машины наружу закрыт).
IAP_ARGS=()
[[ ${E2E_IAP:-0} == 1 ]] && IAP_ARGS=(--tunnel-through-iap)
on_vm() { g compute ssh "$INSTANCE" --zone "$GCP_ZONE" "${IAP_ARGS[@]}" --command "cd $REMOTE_DIR && $1"; }

# stage <ID> <описание> <команда на машине> [ожидаемый код]
stage() {
  local id=$1 title=$2 cmd=$3 expect=${4:-0} start rc=0 took mark
  echo "=== $id: $title"
  start=$SECONDS
  on_vm "$cmd" || rc=$?
  took=$((SECONDS - start))
  if [[ $rc == "$expect" ]]; then mark="✓"; else
    mark="✗ (код $rc, ожидался $expect)"
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

echo "=== создание машины $INSTANCE"
g compute instances create "$INSTANCE" --zone "$GCP_ZONE" --machine-type "$MACHINE_TYPE" \
  --image-family debian-13 --image-project debian-cloud --boot-disk-size 100GB --boot-disk-type pd-balanced \
  --metadata enable-oslogin=TRUE >/dev/null
for _ in $(seq 1 30); do on_vm true 2>/dev/null && break || sleep 10; done 2>/dev/null || true
git -C "$ROOT" archive --format=tar.gz --prefix="$REMOTE_DIR/" HEAD >"$ROOT/.work/e2e.tar.gz"
g compute scp "$ROOT/.work/e2e.tar.gz" "$INSTANCE:e2e.tar.gz" --zone "$GCP_ZONE" "${IAP_ARGS[@]}"
g compute ssh "$INSTANCE" --zone "$GCP_ZONE" "${IAP_ARGS[@]}" --command "tar -xzf e2e.tar.gz && rm e2e.tar.gz"

H="bash ./hammurapi-infra.sh"
stage UP-01 "up на чистой машине (цель ≤ 20 мин)" "$H up --no-color"
stage CMD-01 "status --json" "$H status --json --no-color | jq -e '.ok and (.checks | length) >= 6'"
stage CMD-02 "creds: адреса и пароли всех хранилищ и Grafana" \
  "$H creds --json | jq -e '.postgres.password != \"\" and .s3.secret_key != \"\" and .grafana.password != \"\" and .kafka.bootstrap_servers != \"\"'"
stage OBS-04 "семь дашбордов в папке Hammurapi Infra" \
  "kubectl --context hammurapi -n observability get cm -l grafana_dashboard=1 -o name | wc -l | grep -qx 7"
stage OBS-05 "вход в Grafana без пароля запрещён" \
  "kubectl --context hammurapi -n observability run gf-anon --rm -i --restart=Never --image=curlimages/curl:8.22.0 -- \
     curl -s -o /dev/null -w '%{http_code}' http://grafana/api/dashboards/uid/hammurapi-kafka | grep -qx 401"

# UP-02, SEC-02: повторный up — ни один под не перезапущен, пароли прежние.
on_vm "kubectl --context hammurapi get pods -A -o json | jq -S '[.items[] | {n: .metadata.name, uid: .metadata.uid, r: [.status.containerStatuses[]?.restartCount]}]' >/tmp/pods-before.json;
  kubectl --context hammurapi get secret -A -l app.kubernetes.io/managed-by=hammurapi-infra -o json | jq -S '[.items[] | {n: .metadata.name, d: .data}]' >/tmp/secrets-before.json" || true
stage UP-02 "повторный up без изменений (цель ≤ 3 мин)" "$H up --no-color"
stage SEC-02 "повторный up не меняет пароли и поды" \
  "kubectl --context hammurapi get secret -A -l app.kubernetes.io/managed-by=hammurapi-infra -o json | jq -S '[.items[] | {n: .metadata.name, d: .data}]' | diff -q - /tmp/secrets-before.json &&
   kubectl --context hammurapi get pods -A -o json | jq -S '[.items[] | {n: .metadata.name, uid: .metadata.uid, r: [.status.containerStatuses[]?.restartCount]}]' | diff -q - /tmp/pods-before.json"

# PERS: данные переживают minikube stop/start и перезагрузку машины.
PG="kubectl --context hammurapi -n storages exec hammurapi-pg-1 -c postgres --"
stage PERS-01a "запись данных в Postgres" "$PG psql -U postgres -d hammurapi -c 'create table if not exists e2e(v text); insert into e2e values (\$\$persist\$\$)'"
stage PERS-01 "minikube stop и up — данные на месте" \
  "minikube stop -p hammurapi && $H up --no-color && $PG psql -U postgres -d hammurapi -tAc 'select v from e2e' | grep -qx persist"
echo "=== перезагрузка машины"
g compute instances reset "$INSTANCE" --zone "$GCP_ZONE" >/dev/null
sleep 60
for _ in $(seq 1 30); do on_vm true 2>/dev/null && break || sleep 10; done 2>/dev/null || true
stage PERS-04 "после перезагрузки кластер и компоненты поднялись сами, без up" \
  "timeout 1800 bash -c 'until systemctl is-active --quiet hammurapi-stand; do sleep 10; done' &&
   $H status --no-color && $PG psql -U postgres -d hammurapi -tAc 'select v from e2e' | grep -qx persist"
stage PERS-02 "перезагрузка и up — данные и пароли прежние" \
  "$H up --no-color && $PG psql -U postgres -d hammurapi -tAc 'select v from e2e' | grep -qx persist &&
   kubectl --context hammurapi get secret -A -l app.kubernetes.io/managed-by=hammurapi-infra -o json | jq -S '[.items[] | {n: .metadata.name, d: .data}]' | diff -q - /tmp/secrets-before.json"

# CHK: проверки ловят реальные отказы.
stage CHK-01 "VictoriaLogs в 0 — status код 15 «логи не поступают»" \
  "kubectl --context hammurapi -n observability scale statefulset victoria-logs-victoria-logs-single-server --replicas=0 &&
   { $H status --no-color >/tmp/chk01.txt 2>&1; rc=\$?; }; grep -q 'логи не поступают в VictoriaLogs' /tmp/chk01.txt && exit \$rc; exit 99" 15
stage CHK-03 "неверный пароль в postgres-conn — «Postgres: ошибка аутентификации»" \
  "kubectl --context hammurapi -n observability scale statefulset victoria-logs-victoria-logs-single-server --replicas=1 &&
   kubectl --context hammurapi -n storages patch secret postgres-conn -p '{\"data\":{\"password\":\"d3Jvbmc=\"}}' &&
   { $H status --no-color >/tmp/chk03.txt 2>&1; rc=\$?; }; grep -q 'Postgres: ошибка аутентификации' /tmp/chk03.txt && exit \$rc; exit 99" 15
stage CHK-04 "после проверок пробные поды и Job удалены" \
  "sleep 15; ! kubectl --context hammurapi get pods -A -l app.kubernetes.io/managed-by=hammurapi-infra --no-headers 2>/dev/null | grep -q ."
stage UP-04 "up восстанавливает стенд после сбоев" "$H up --no-color"

stage CMD-04 "down --yes — профиль удалён" "$H down --yes --no-color && ! minikube profile list 2>/dev/null | grep -q hammurapi"
stage PERS-03 "down и up — чистый стенд, новые пароли" \
  "$H up --no-color && kubectl --context hammurapi get secret -A -l app.kubernetes.io/managed-by=hammurapi-infra -o json | jq -S '[.items[] | {n: .metadata.name, d: .data}]' | ! diff -q - /tmp/secrets-before.json >/dev/null"

{
  echo
  echo "Не прошло: $FAILED."
} >>"$REPORT"
cat "$REPORT"
((FAILED == 0))
