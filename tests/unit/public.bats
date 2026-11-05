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
  grep -q "^nat PREROUTING -i ens4 -p tcp -m multiport --dports 80,443 -m comment --comment greenongrey-ingress -j DNAT --to-destination 192.168.49.200$" "$RULES"
  grep -q "^filter DOCKER-USER -d 192.168.49.200 -p tcp -m multiport --dports 80,443 -m comment --comment greenongrey-ingress -j ACCEPT$" "$RULES"
}

@test "PUB-08: a repeated apply (a Docker restart) creates no duplicates" {
  iptables_stub
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  [ "$(grep -c greenongrey-ingress "$RULES")" -eq 2 ]
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
  not_grep -q greenongrey-ingress "$RULES"
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
  mkdir -p "$MINIKUBE_HOME/profiles/greenongrey"
  printf '{"KubernetesConfig":{"LoadBalancerStartIP":"%s","LoadBalancerEndIP":"%s"}}\n' "$1" "$2" \
    >"$MINIKUBE_HOME/profiles/greenongrey/config.json"
}

@test "AUTO-10: the MetalLB pool is saved in the profile: answers to minikube prompts one by one" {
  load_script
  mk_profile "" ""
  # Like minikube 1.39: each answer is read separately; the pool goes to the profile.
  stub minikube 'case "$*" in
    *"addons configure metallb"*) read -r s; read -r e
      printf "{\"KubernetesConfig\":{\"LoadBalancerStartIP\":\"%s\",\"LoadBalancerEndIP\":\"%s\"}}" "$s" "$e" \
        >"$MINIKUBE_HOME/profiles/greenongrey/config.json" ;;
  esac'
  run metallb_addon 192.168.49.200 192.168.49.209
  [ "$status" -eq 0 ]
  called "minikube addons configure metallb -p greenongrey"
  [ "$(metallb_pool)" = 192.168.49.200-192.168.49.209 ]
}

@test "AUTO-10: the pool is already in the profile: only enabling the addon" {
  load_script
  mk_profile 192.168.49.200 192.168.49.209
  run metallb_addon 192.168.49.200 192.168.49.209
  [ "$status" -eq 0 ]
  called "minikube addons enable metallb -p greenongrey"
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

@test "FTR.INFRA.INST-0001 R28: the rule comment follows UNIT_PREFIX: an upgrade of prod replaces its rules" {
  iptables_stub
  export FORWARD_STATE=$BATS_TEST_TMPDIR/state
  mkdir -p "$FORWARD_STATE"
  echo hammurapi >"$FORWARD_STATE/unit-prefix"
  LB_IP=192.168.49.200 EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--comment hammurapi-ingress' "$RULES")" -eq 2 ]
  LB_IP=192.168.49.200 EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$(grep -c -- '--comment hammurapi-ingress' "$RULES")" -eq 2 ]
  not_grep -q greenongrey-ingress "$RULES"
}

@test "FTR.INFRA.INST-0001 R28: CERT_NAME names the certificate and its secret" {
  load_script
  CERT_NAME=hammurapi-public PUBLIC_DOMAIN=x.example run public_certificate
  [ "$status" -eq 0 ]
  [[ $output == *"name: hammurapi-public"* && $output == *"secretName: hammurapi-public"* ]]
}

@test "FTR.INFRA.INST-0001 R17: without Grafana a fault of a product does not fail the stand" {
  load_script
  OBSERVABILITY=false PUBLIC_ACCESS=true PUBLIC_DOMAIN=x.example LB_IP=192.168.49.200
  stub kubectl '[[ $* == *" certificate "* ]] && echo True; exit 0'
  public_curl() { [[ $2 == http ]] && echo "308 https://$1/" || echo 503; }
  check_public
  [[ ${CHECK_RESULTS[*]} == "public|ok|certificate greenongrey-public is ready"* ]]
}

@test "FTR.INFRA.INST-0001 R17: without Grafana a certificate that is not ready fails the check" {
  load_script
  OBSERVABILITY=false PUBLIC_ACCESS=true PUBLIC_DOMAIN=x.example LB_IP=192.168.49.200
  stub kubectl '[[ $* == *" certificate "* ]] && echo False; exit 0'
  public_curl() { echo "308 https://$1/"; }
  check_public
  [[ ${CHECK_RESULTS[*]} == "public|fail|certificate ingress/greenongrey-public is not ready"* ]]
}

@test "FTR.INFRA.INST-0001 R17: with Grafana the check still asks Grafana" {
  load_script
  PUBLIC_ACCESS=true PUBLIC_DOMAIN=x.example LB_IP=192.168.49.200
  public_curl() { [[ $1 == grafana.x.example ]] || return 1; [[ $2 == http ]] && echo "308 https://$1/" || echo 503; }
  check_public
  [[ ${CHECK_RESULTS[*]} == "public|fail|https://grafana.x.example answers '503'"* ]]
}

# --- INGRESS_MODE (FTR.INFRA.INST-0001 R17, RES-06) ---

# validate_public_strict — as validate_config reports: missing parameters give code 2.
validate_public_strict() {
  CONFIG_MISSING=()
  validate_public_config
  die_if_missing
}

external_ingress() {
  INGRESS_MODE=external INGRESS_CLASS=nginx ACME_ISSUER=corp PUBLIC_ACCESS=true PUBLIC_BASE_DOMAIN=x.example
  CONFIG_EXPLICIT[INGRESS_CLASS]=1 CONFIG_EXPLICIT[ACME_ISSUER]=1
}

@test "RES-06 (U): external needs a class, an issuer and a domain; no ACME_EMAIL" {
  load_script
  external_ingress
  ACME_EMAIL=
  run validate_public_strict
  [ "$status" -eq 0 ]
  unset 'CONFIG_EXPLICIT[INGRESS_CLASS]'
  run validate_public_strict
  [ "$status" -eq 2 ]
  [[ $output == *INGRESS_CLASS* ]]
  external_ingress
  PUBLIC_BASE_DOMAIN=
  run validate_public_strict
  [ "$status" -eq 2 ]
  [[ $output == *PUBLIC_BASE_DOMAIN* ]]
}

@test "RES-06 (U): internal installs Traefik: another class or mode is an error" {
  load_script
  PUBLIC_ACCESS=true ACME_EMAIL=a@b.example INGRESS_CLASS=nginx
  run validate_public_strict
  [ "$status" -eq 2 ]
  INGRESS_CLASS=traefik INGRESS_MODE=other
  run validate_public_strict
  [ "$status" -eq 2 ]
  [[ $output == *INGRESS_MODE* ]]
}

@test "RES-06 (U): external installs no Traefik, cert-manager, MetalLB or forwarding" {
  load_script
  external_ingress
  PUBLIC_DOMAIN=x.example
  stub kubectl '[[ $* == *" certificate "* ]] && echo True; exit 0'
  run deploy_public
  [ "$status" -eq 0 ]
  not_called "upgrade --install"
  not_called "minikube"
  not_called "systemctl"
  called "certificate grafana-tls"
}

@test "RES-06 (U): Grafana in external mode: the class, the issuer and a secret of its own" {
  load_script
  external_ingress
  PUBLIC_DOMAIN=x.example
  grafana_public_values "$BATS_TEST_TMPDIR/g.yaml"
  grep -q 'ingressClassName: nginx' "$BATS_TEST_TMPDIR/g.yaml"
  grep -q 'cert-manager.io/cluster-issuer: "corp"' "$BATS_TEST_TMPDIR/g.yaml"
  grep -q 'secretName: grafana-tls' "$BATS_TEST_TMPDIR/g.yaml"
}

@test "RES-06 (U): a certificate that appears later is waited for, one that never does is an error" {
  load_script
  external_ingress
  PUBLIC_DOMAIN=x.example
  stub kubectl '[[ $* == *" certificate "* ]] && { n=$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); echo $((n + 1)) >"$BATS_TEST_TMPDIR/n"; ((n >= 1)) && echo True; }; exit 0'
  sleep() { :; }
  run wait_certificate observability grafana-tls
  [ "$status" -eq 0 ]
  stub kubectl 'exit 1'
  CERT_TIMEOUT=0 run deploy_public
  [ "$status" -eq 13 ]
  [[ $output == *"did not issue the certificate of Grafana"* ]]
}

@test "RES-06 (U): a rollout takes the ingress from what up recorded; an older record means internal" {
  load_script
  ingress_from_status '{"public":{"enabled":true,"ingressMode":"external","ingressClass":"nginx","issuer":"corp"}}'
  [ "$INGRESS_MODE" = external ] && [ "$INGRESS_CLASS" = nginx ] && [ "$ACME_ISSUER" = corp ]
  ingress_from_status '{"public":{"enabled":true,"issuer":"letsencrypt"}}'
  [ "$INGRESS_MODE" = internal ] && [ "$INGRESS_CLASS" = traefik ] && [ "$ACME_ISSUER" = letsencrypt ]
}

@test "RES-06 (U): values of a product chart follow the mode" {
  load_script
  [ "$(ingress_helm_args | paste -sd' ')" = "--set-string ingress.className=traefik" ]
  external_ingress
  [ "$(ingress_helm_args | paste -sd' ')" = "--set-string ingress.className=nginx --set-string ingress.clusterIssuer=corp" ]
}

@test "RES-06 (U): the check of external mode looks at the class, the issuer and the certificate" {
  load_script
  external_ingress
  stub kubectl '[[ $* == *"get ingressclass"* ]] && exit 0; [[ $* == *"get clusterissuer"* ]] && echo True; [[ $* == *" certificate "* ]] && echo True; exit 0'
  curl() { echo "unexpected curl" >&2; return 1; }
  check_public
  [[ ${CHECK_RESULTS[*]} == "public|ok|ingress class nginx, ClusterIssuer corp" ]]
  CHECK_RESULTS=()
  stub kubectl '[[ $* == *"get ingressclass"* ]] && exit 1; exit 0'
  check_public
  [[ ${CHECK_RESULTS[*]} == "public|fail|ingress class nginx does not exist" ]]
  CHECK_RESULTS=()
  stub kubectl '[[ $* == *"get clusterissuer"* ]] && echo False; exit 0'
  check_public
  [[ ${CHECK_RESULTS[*]} == "public|fail|ClusterIssuer corp is not ready ('False')" ]]
}

# --- firewalld (FTR.INFRA.INST-0001 R9, tech §5) ---

firewalld_stub() {
  export FW=$BATS_TEST_TMPDIR/fw
  : >"$FW"
  stub firewall-cmd '
scope=runtime; args=("$@")
[[ $1 == --permanent ]] && { scope=permanent; args=("${@:2}"); }
case "${args[*]}" in
  --state) exit 0 ;;
  --get-zone-of-interface=*) echo public ;;
  --get-zones) echo public trusted ;;
  *--list-forward-ports*) { grep "^$scope " "$FW" || true; } | cut -d" " -f2 ;;
  *--add-forward-port=*) r=${args[1]#--add-forward-port=}; echo "$scope $r" >>"$FW" ;;
  *--remove-forward-port=*) r=${args[1]#--remove-forward-port=}; grep -vxF "$scope $r" "$FW" >"$FW.new" || true; mv "$FW.new" "$FW" ;;
esac'
  export FIREWALL_CMD=firewall-cmd FORWARD_STATE=$BATS_TEST_TMPDIR/state
  mkdir -p "$FORWARD_STATE"
}

@test "R9: firewalld runs: forward-port in both configurations, no masquerade, no DNAT of iptables" {
  iptables_stub
  firewalld_stub
  LB_IP=192.168.49.200 EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$status" -eq 0 ]
  grep -qx "runtime port=80:proto=tcp:toport=80:toaddr=192.168.49.200" "$FW"
  grep -qx "permanent port=443:proto=tcp:toport=443:toaddr=192.168.49.200" "$FW"
  not_grep -q masquerade "$CALLS"
  not_grep -q '^nat PREROUTING' "$RULES"
  # Docker drops what it did not publish without this rule.
  grep -q '^filter DOCKER-USER -d 192.168.49.200' "$RULES"
}

@test "R9: a new address replaces the old rules, a repeat adds nothing" {
  iptables_stub
  firewalld_stub
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.201 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.201 EXT_IF=ens4 bash "$FORWARD" apply
  [ "$(wc -l <"$FW")" -eq 4 ]
  not_grep -q 192.168.49.200 "$FW"
}

@test "R9: remove clears both configurations; forwards of the user stay, also on ports 80 and 443" {
  iptables_stub
  firewalld_stub
  printf 'permanent port=8080:proto=tcp:toport=80:toaddr=10.0.0.5\nruntime port=80:proto=tcp:toport=80:toaddr=10.0.0.6\n' >"$FW"
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  EXT_IF=ens4 run bash "$FORWARD" remove
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FW")" -eq 2 ]
  not_grep -q 192.168.49.200 "$FW"
  grep -q toaddr=10.0.0.6 "$FW"
}

@test "R9: firewalld is installed but stopped: iptables, as on Debian" {
  iptables_stub
  stub firewall-cmd 'exit 252'
  export FIREWALL_CMD=firewall-cmd
  LB_IP=192.168.49.200 EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$status" -eq 0 ]
  grep -q '^nat PREROUTING' "$RULES"
}
