#!/usr/bin/env bash
# remote.sh <команда> — выполняет команду на машине прода через выбранный
# транспорт (DEPLOY_TRANSPORT): ssh (хост prod из ssh-setup.sh) или gcp-iap
# (gcloud compute ssh через IAP; GCP_PROJECT, GCP_ZONE, GCP_INSTANCE).
set -euo pipefail
cmd=${1:?команда}
case ${DEPLOY_TRANSPORT:-ssh} in
  ssh)
    exec ssh -F "${SSH_DIR:-$HOME/.ssh}/config" prod -- "$cmd"
    ;;
  gcp-iap)
    exec gcloud compute ssh "${GCP_INSTANCE:?}" --project "${GCP_PROJECT:?}" --zone "${GCP_ZONE:?}" \
      --tunnel-through-iap --quiet --command "$cmd"
    ;;
  *)
    echo "::error::DEPLOY_TRANSPORT должен быть ssh или gcp-iap" >&2
    exit 1
    ;;
esac
