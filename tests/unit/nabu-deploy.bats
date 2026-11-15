#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.NAB.CMN-0001 R29, INST arch §1: bin/nabu-deploy rolls out without a GHCR token. The images and charts are
# public, and a stand whose secret ghcr-pull was never created pulls anonymously — not a failure of the rollout.

load helpers

DEPLOY="$BATS_TEST_DIRNAME/../../bin/nabu-deploy"

setup() {
  setup_stubs
  export DEPLOY_LOCK_DIR=$BATS_TEST_TMPDIR/lock INSTALLER_CONFIG=/dev/null PUBLIC_ACCESS=true
  mkdir -p "$DEPLOY_LOCK_DIR"
  # The stand answers; TLS terminated in front, so no certificate is awaited.
  cat >"$STUBS/status.sh" <<'EOF'
jq -cn '{ok: true, checks: [], public: {enabled: true, baseDomain: "34-12-5-6.sslip.io",
  ingressMode: "internal", ingressClass: "traefik", issuer: "letsencrypt", tlsTermination: "external"}}'
EOF
  export STATUS_CMD=$STUBS/status.sh
  # kubectl: GHCR_SECRET says whether the stand has ghcr-pull, GHCR_CONFIG its dockerconfigjson in base64.
  export GHCR_SECRET=false GHCR_CONFIG=""
  stub kubectl '
case "$*" in
  *"get secret ghcr-pull"*)
    [[ ${GHCR_SECRET:-false} == true ]] || exit 1
    [[ "$*" == *jsonpath* ]] && printf "%s" "${GHCR_CONFIG:-}"
    exit 0
    ;;
  *"create namespace"*) echo "kind: Namespace" ;;
  # The stubs read their stdin: a manifest pipeline must not die of SIGPIPE.
  *"label --local -f -"*) cat >/dev/null; echo "kind: Namespace" ;;
  *"apply -f -"*) cat >/dev/null ;;
  *) exit 0 ;;
esac'
  # helm: nabu-core exists, so nabu-web may roll out.
  stub helm '
case "$*" in
  *"status nabu-core"*) exit 0 ;;
  *"-o json"*) echo "{\"version\":4}" ;;
  *) exit 0 ;;
esac'
  PAYLOAD=$(jq -cn '{image: "ghcr.io/greenongrey/nabu-web", config: {}, secrets: {}}')
  export PAYLOAD
}

deploy() { printf '%s' "$PAYLOAD" | bash "$DEPLOY" "$@"; }

@test "PRD-12: without a GHCR token and without ghcr-pull the product rolls out anonymously" {
  run deploy nabu-web v0.3.12 0.3.10
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ $output == *"nabu-web v0.3.12 is ready"* ]]
  [[ $output != *"code 1"* ]]
  not_called "registry login"
  [[ $(tail -n 1 <<<"$output" | jq -r '.status') == success ]]
}

@test "PRD-12: a ghcr-pull secret kept by an earlier rollout still signs in to the registry" {
  GHCR_SECRET=true
  GHCR_CONFIG=$(printf '{"auths":{"ghcr.io":{"password":"ghp_kept"}}}' | base64 -w0)
  export GHCR_SECRET GHCR_CONFIG
  run deploy nabu-web v0.3.12 0.3.10
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  called "registry login ghcr.io"
}
