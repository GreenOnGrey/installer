#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.HMR.INFRA-0002: public access, port forwarding, checks of the rollout configuration.

load helpers

FORWARD="$BATS_TEST_DIRNAME/../../bin/ingress-forward"

setup() {
  setup_stubs
}

# --- ingress-forward (R17, PUB-07, PUB-08) ---

# An iptables stub with state: rules live in a file, and -S prints them.
iptables_stub() {
  export RULES=$BATS_TEST_TMPDIR/rules
  : >"$RULES"
  stub iptables '
t=filter; args=("$@")
[[ $1 == -t ]] && { t=$2; args=("${@:3}"); }
case ${args[0]} in
  -S) grep "^$t ${args[1]} " "$RULES" | sed "s/^$t ${args[1]} /-A ${args[1]} /" ;;
  -A|-I) echo "$t ${args[1]} ${args[*]:2}" >>"$RULES" ;;
  -D) rest="${args[*]:2}"; grep -vxF "$t ${args[1]} $rest" "$RULES" >"$RULES.new"; mv "$RULES.new" "$RULES" ;;
  -N) exit 0 ;;
esac'
  export IPTABLES=iptables
}

@test "PUB-01: apply: DNAT of 80/443 to the Traefik address and an allow rule in DOCKER-USER" {
  iptables_stub
  LB_IP=192.168.49.200 EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$status" -eq 0 ]
  grep -q "^nat PREROUTING -i ens4 -p tcp -m multiport --dports 80,443 -m comment --comment hammurapi-ingress -j DNAT --to-destination 192.168.49.200$" "$RULES"
  grep -q "^filter DOCKER-USER -d 192.168.49.200 -p tcp -m multiport --dports 80,443 -m comment --comment hammurapi-ingress -j ACCEPT$" "$RULES"
}

@test "PUB-08: a repeated apply (a Docker restart) creates no duplicates" {
  iptables_stub
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  [ "$(grep -c hammurapi-ingress "$RULES")" -eq 2 ]
}

@test "PUB-07: after a reboot the address comes from the cache of up" {
  iptables_stub
  export FORWARD_STATE=$BATS_TEST_TMPDIR/state
  mkdir -p "$FORWARD_STATE"
  echo 192.168.49.201 >"$FORWARD_STATE/lb-ip"
  EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$status" -eq 0 ]
  grep -q "to-destination 192.168.49.201" "$RULES"
}

@test "a change of the Traefik address: old rules are replaced" {
  iptables_stub
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.205 EXT_IF=ens4 bash "$FORWARD" apply
  not_grep -q 192.168.49.200 "$RULES"
  [ "$(grep -c 192.168.49.205 "$RULES")" -eq 2 ]
}

@test "remove takes only its own rules" {
  iptables_stub
  echo "nat PREROUTING -i ens4 -p tcp --dport 22 -j ACCEPT" >>"$RULES"
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  run bash "$FORWARD" remove
  [ "$status" -eq 0 ]
  not_grep -q hammurapi-ingress "$RULES"
  grep -q -- "--dport 22" "$RULES"
}

@test "without a Traefik address: an error, rules stay" {
  iptables_stub
  FORWARD_STATE=$BATS_TEST_TMPDIR/none EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$status" -eq 1 ]
  [ ! -s "$RULES" ]
}

# --- The MetalLB pool in the minikube profile survives minikube start (R16, R17) ---

# mk_profile <start> <end> — a minikube profile with a MetalLB pool.
mk_profile() {
  mkdir -p "$MINIKUBE_HOME/profiles/hammurapi"
  printf '{"KubernetesConfig":{"LoadBalancerStartIP":"%s","LoadBalancerEndIP":"%s"}}\n' "$1" "$2" \
    >"$MINIKUBE_HOME/profiles/hammurapi/config.json"
}

@test "AUTO-10: the MetalLB pool is saved in the profile: answers to minikube prompts one by one" {
  load_script
  mk_profile "" ""
  # Like minikube 1.39: each answer is read separately; the pool goes to the profile.
  stub minikube 'case "$*" in
    *"addons configure metallb"*) read -r s; read -r e
      printf "{\"KubernetesConfig\":{\"LoadBalancerStartIP\":\"%s\",\"LoadBalancerEndIP\":\"%s\"}}" "$s" "$e" \
        >"$MINIKUBE_HOME/profiles/hammurapi/config.json" ;;
  esac'
  run metallb_addon 192.168.49.200 192.168.49.209
  [ "$status" -eq 0 ]
  called "minikube addons configure metallb -p hammurapi"
  [ "$(metallb_pool)" = 192.168.49.200-192.168.49.209 ]
}

@test "AUTO-10: the pool is already in the profile: only enabling the addon" {
  load_script
  mk_profile 192.168.49.200 192.168.49.209
  run metallb_addon 192.168.49.200 192.168.49.209
  [ "$status" -eq 0 ]
  called "minikube addons enable metallb -p hammurapi"
  not_called "addons configure"
}

@test "AUTO-10: the pool was not saved: an error of the step public" {
  load_script
  mk_profile "" ""
  sleep() { :; }
  export -f sleep
  run metallb_addon 192.168.49.200 192.168.49.209
  [ "$status" -eq "$E_DEPLOY" ]
  [[ $output == *"failed to save the MetalLB pool 192.168.49.200-192.168.49.209"* ]]
}

# --- Public access configuration (R18, R21) ---

@test "PUB-12: PUBLIC_ACCESS=false: the public access step does not run" {
  load_script
  PUBLIC_ACCESS=false
  run deploy_public
  [ "$status" -eq 0 ]
  not_called "addons enable metallb"
  not_called "upgrade --install traefik"
}

@test "PUB-13: PUBLIC_ACCESS=true without ACME_EMAIL: code 2 with the parameter name" {
  load_script
  PUBLIC_ACCESS=true ACME_EMAIL=""
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"ACME_EMAIL"* ]]
}

@test "PUB-13: Grafana sign-in through GitHub without a secret: code 2" {
  load_script
  PUBLIC_ACCESS=true ACME_EMAIL=ops@example.org GRAFANA_GITHUB_CLIENT_ID=Iv1.x
  unset GRAFANA_GITHUB_CLIENT_SECRET GRAFANA_GITHUB_CLIENT_SECRET_FILE
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"GRAFANA_GITHUB_CLIENT_SECRET"* ]]
}

@test "PUB-03: without PUBLIC_BASE_DOMAIN: <IP with dashes>.sslip.io; with it: the set domain" {
  load_script
  PUBLIC_BASE_DOMAIN=""
  [ "$(public_domain 34.12.5.6)" = 34-12-5-6.sslip.io ]
  PUBLIC_BASE_DOMAIN=hammurapi.duckdns.org
  [ "$(public_domain 34.12.5.6)" = hammurapi.duckdns.org ]
}

@test "R20: Grafana values: Ingress, root_url and sign-in of organization members with the role Editor" {
  load_script
  PUBLIC_DOMAIN=34-12-5-6.sslip.io GRAFANA_GITHUB_CLIENT_ID=Iv1.x GRAFANA_GITHUB_ORG=GreenOnGrey
  grafana_public_values "$BATS_TEST_TMPDIR/g.yaml"
  grep -q 'hosts: \["grafana.34-12-5-6.sslip.io"\]' "$BATS_TEST_TMPDIR/g.yaml"
  grep -q 'root_url: "https://grafana.34-12-5-6.sslip.io"' "$BATS_TEST_TMPDIR/g.yaml"
  grep -q 'allowed_organizations: GreenOnGrey' "$BATS_TEST_TMPDIR/g.yaml"
  grep -q "role_attribute_path: \"'Editor'\"" "$BATS_TEST_TMPDIR/g.yaml"
  grep -q 'disable_login_form: false' "$BATS_TEST_TMPDIR/g.yaml"
  grep -q 'envFromSecret: grafana-github-oauth' "$BATS_TEST_TMPDIR/g.yaml"
}

@test "R20: a change of the client ID or secret of the OAuth app restarts Grafana" {
  load_script
  PUBLIC_DOMAIN=34-12-5-6.sslip.io GRAFANA_GITHUB_ORG=GreenOnGrey
  checksum() {
    GRAFANA_GITHUB_CLIENT_ID=$1 GRAFANA_GITHUB_CLIENT_SECRET=$2 grafana_public_values "$BATS_TEST_TMPDIR/g.yaml"
    sed -n 's/^  checksum\/github-oauth: //p' "$BATS_TEST_TMPDIR/g.yaml"
  }
  local a b c d
  a=$(checksum Iv23li1 s1)
  b=$(checksum Ov23ct1 s1)
  c=$(checksum Ov23ct1 s2)
  d=$(checksum Ov23ct1 s2)
  [[ $a =~ ^[0-9a-f]{64}$ ]]
  [ "$a" != "$b" ] && [ "$b" != "$c" ] && [ "$c" = "$d" ]
  not_grep -q s2 "$BATS_TEST_TMPDIR/g.yaml"
}

# --- deploy-component.yml: the configuration check before connecting (INS-05) ---
# The workflow is in the public repository hammurapi (a sibling directory; in CI, DEPLOY_WORKFLOW).

config_step() {
  command -v yq >/dev/null || skip "no yq"
  local wf=${DEPLOY_WORKFLOW:-$ROOT/../hammurapi/.github/workflows/deploy-component.yml}
  [[ -f $wf ]] || skip "no $wf"
  yq -r '.jobs.deploy.steps[] | select(.id == "config") | .run' "$wf" >"$BATS_TEST_TMPDIR/config.sh"
  export GITHUB_OUTPUT=$BATS_TEST_TMPDIR/out COMPONENT=hammurapi-core DEPLOY_TRANSPORT=ssh CALLBACK_URL="" TAG=v1.8.0
  : >"$GITHUB_OUTPUT"
  export PROD_HOST=h PROD_USER=u HAS_PROD_SSH_KEY=true HAS_PROD_KNOWN_HOSTS=true HAS_HAMMURAPI_GHCR_PULL_TOKEN=true
  export HAMMURAPI_GITHUB_APP_ID=1 HAMMURAPI_GITHUB_CLIENT_ID=c HAMMURAPI_SPEC_REPO=o/r HAMMURAPI_BOOTSTRAP_ADMINS=a
  export HAS_HAMMURAPI_GITHUB_APP_PRIVATE_KEY=true HAS_HAMMURAPI_GITHUB_CLIENT_SECRET=true HAS_HAMMURAPI_WEBHOOK_SECRET=true
  export HAS_HAMMURAPI_TOKEN_ENCRYPTION_KEY=true
  export HAMMURAPI_NABU_URL=https://nabu-api.x HAMMURAPI_NABU_CLIENT_ID=hmr HAS_HAMMURAPI_NABU_CLIENT_SECRET=true
  mkdir -p "$BATS_TEST_TMPDIR/w/deploy"
  echo CHART_VERSION=0.4.0 >"$BATS_TEST_TMPDIR/w/deploy/versions.env"
}

@test "INS-05: no HAMMURAPI_WEBHOOK_SECRET: an error before connecting, with the secret name" {
  config_step
  export HAS_HAMMURAPI_WEBHOOK_SECRET=false HAS_PROD_KNOWN_HOSTS=false
  cd "$BATS_TEST_TMPDIR/w"
  run bash -e "$BATS_TEST_TMPDIR/config.sh"
  [ "$status" -eq 1 ]
  # Both languages until deploy-component.yml of every tag in use is in English.
  [[ $output =~ HAMMURAPI_WEBHOOK_SECRET\ \((секрет|secret)\) && $output =~ PROD_KNOWN_HOSTS\ \((секрет|secret)\) ]]
}

@test "FTR.HMR.CMN-0007 R1: core without Nabu: an error before connecting, with the setting names" {
  config_step
  unset HAMMURAPI_NABU_URL HAMMURAPI_NABU_CLIENT_ID HAS_HAMMURAPI_NABU_CLIENT_SECRET
  cd "$BATS_TEST_TMPDIR/w"
  run bash -e "$BATS_TEST_TMPDIR/config.sh"
  [ "$status" -eq 1 ]
  [[ $output =~ HAMMURAPI_NABU_URL\ \((переменная|variable)\) && $output =~ HAMMURAPI_NABU_CLIENT_ID\ \((переменная|variable)\) && $output =~ HAMMURAPI_NABU_CLIENT_SECRET\ \((секрет|secret)\) ]]
}

@test "INS-05: a complete core configuration: the chart version from deploy/versions.env" {
  config_step
  cd "$BATS_TEST_TMPDIR/w"
  run bash -e "$BATS_TEST_TMPDIR/config.sh"
  [ "$status" -eq 0 ]
  grep -qx "chart=0.4.0" "$GITHUB_OUTPUT"
}

@test "INS-05: web needs no core configuration" {
  config_step
  export COMPONENT=hammurapi-web
  unset HAMMURAPI_GITHUB_APP_ID HAMMURAPI_SPEC_REPO HAS_HAMMURAPI_WEBHOOK_SECRET
  cd "$BATS_TEST_TMPDIR/w"
  run bash -e "$BATS_TEST_TMPDIR/config.sh"
  [ "$status" -eq 0 ]
}

@test "CTR: a run by contract requires the secret signing the result webhook" {
  config_step
  export CALLBACK_URL=https://api.example.org/hooks/v1/deploy HAS_HAMMURAPI_DEPLOY_CALLBACK_SECRET=false
  cd "$BATS_TEST_TMPDIR/w"
  run bash -e "$BATS_TEST_TMPDIR/config.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"HAMMURAPI_DEPLOY_CALLBACK_SECRET"* ]]
}

@test "QUAL-03: GitHub Actions are pinned by SHA" {
  local bad wf=${DEPLOY_WORKFLOW:-$ROOT/../hammurapi/.github/workflows/deploy-component.yml} files=("$ROOT"/.github/workflows/*.yml)
  [[ -f $wf ]] && files+=("$wf")
  bad=$(grep -hE '^\s*(-\s*)?uses:\s*[^./]' "${files[@]}" | grep -vE '@[0-9a-f]{40}(\s|$)' || true)
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}
