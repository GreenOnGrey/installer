#!/usr/bin/env bash
# remote.sh <command> — runs a command on the production machine through the chosen
# transport (DEPLOY_TRANSPORT): ssh (host prod from ssh-setup.sh) or gcp-iap
# (gcloud compute ssh through IAP; GCP_PROJECT, GCP_ZONE, GCP_INSTANCE).
set -euo pipefail
cmd=${1:?command}
case ${DEPLOY_TRANSPORT:-ssh} in
  ssh)
    exec ssh -F "${SSH_DIR:-$HOME/.ssh}/config" prod -- "$cmd"
    ;;
  gcp-iap)
    exec gcloud compute ssh "${GCP_INSTANCE:?}" --project "${GCP_PROJECT:?}" --zone "${GCP_ZONE:?}" \
      --tunnel-through-iap --quiet --command "$cmd"
    ;;
  *)
    echo "::error::DEPLOY_TRANSPORT must be ssh or gcp-iap" >&2
    exit 1
    ;;
esac
