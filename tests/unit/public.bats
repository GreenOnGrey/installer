#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# HMR.INFRA-0002: публичный доступ стенда, проброс портов, проверка конфигурации выкатки.

load helpers

FORWARD="$BATS_TEST_DIRNAME/../../bin/ingress-forward"

setup() {
  setup_stubs
}

# --- ingress-forward (R17, PUB-07, PUB-08) ---

# iptables-заглушка с состоянием: правила хранятся в файле, -S их печатает.
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

@test "PUB-01: apply — DNAT 80/443 на адрес Traefik и разрешение в DOCKER-USER" {
  iptables_stub
  LB_IP=192.168.49.200 EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$status" -eq 0 ]
  grep -q "^nat PREROUTING -i ens4 -p tcp -m multiport --dports 80,443 -m comment --comment hammurapi-ingress -j DNAT --to-destination 192.168.49.200$" "$RULES"
  grep -q "^filter DOCKER-USER -d 192.168.49.200 -p tcp -m multiport --dports 80,443 -m comment --comment hammurapi-ingress -j ACCEPT$" "$RULES"
}

@test "PUB-08: повторный apply (перезапуск Docker) не создаёт дублей" {
  iptables_stub
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  [ "$(grep -c hammurapi-ingress "$RULES")" -eq 2 ]
}

@test "PUB-07: после перезагрузки адрес берётся из кэша up" {
  iptables_stub
  export FORWARD_STATE=$BATS_TEST_TMPDIR/state
  mkdir -p "$FORWARD_STATE"
  echo 192.168.49.201 >"$FORWARD_STATE/lb-ip"
  EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$status" -eq 0 ]
  grep -q "to-destination 192.168.49.201" "$RULES"
}

@test "смена адреса Traefik: старые правила заменяются" {
  iptables_stub
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  LB_IP=192.168.49.205 EXT_IF=ens4 bash "$FORWARD" apply
  not_grep -q 192.168.49.200 "$RULES"
  [ "$(grep -c 192.168.49.205 "$RULES")" -eq 2 ]
}

@test "remove снимает только свои правила" {
  iptables_stub
  echo "nat PREROUTING -i ens4 -p tcp --dport 22 -j ACCEPT" >>"$RULES"
  LB_IP=192.168.49.200 EXT_IF=ens4 bash "$FORWARD" apply
  run bash "$FORWARD" remove
  [ "$status" -eq 0 ]
  not_grep -q hammurapi-ingress "$RULES"
  grep -q -- "--dport 22" "$RULES"
}

@test "без адреса Traefik — ошибка, правила не трогаются" {
  iptables_stub
  FORWARD_STATE=$BATS_TEST_TMPDIR/none EXT_IF=ens4 run bash "$FORWARD" apply
  [ "$status" -eq 1 ]
  [ ! -s "$RULES" ]
}

# --- Пул MetalLB в профиле minikube: переживает minikube start (R16, R17) ---

# mk_profile <начало> <конец> — профиль minikube с пулом MetalLB.
mk_profile() {
  mkdir -p "$MINIKUBE_HOME/profiles/hammurapi"
  printf '{"KubernetesConfig":{"LoadBalancerStartIP":"%s","LoadBalancerEndIP":"%s"}}\n' "$1" "$2" \
    >"$MINIKUBE_HOME/profiles/hammurapi/config.json"
}

@test "AUTO-10: пул MetalLB сохраняется в профиле — ответы на вопросы minikube по одному" {
  load_script
  mk_profile "" ""
  # Как minikube 1.39: каждый ответ читается отдельно; пул пишется в профиль.
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

@test "AUTO-10: пул уже в профиле — только включение дополнения" {
  load_script
  mk_profile 192.168.49.200 192.168.49.209
  run metallb_addon 192.168.49.200 192.168.49.209
  [ "$status" -eq 0 ]
  called "minikube addons enable metallb -p hammurapi"
  not_called "addons configure"
}

@test "AUTO-10: пул не сохранился — ошибка шага public" {
  load_script
  mk_profile "" ""
  sleep() { :; }
  export -f sleep
  run metallb_addon 192.168.49.200 192.168.49.209
  [ "$status" -eq "$E_DEPLOY" ]
  [[ $output == *"не удалось сохранить пул MetalLB 192.168.49.200-192.168.49.209"* ]]
}

# --- Конфигурация публичного доступа (R18, R21) ---

@test "PUB-12: PUBLIC_ACCESS=false — шаг публичного доступа не выполняется" {
  load_script
  PUBLIC_ACCESS=false
  run deploy_public
  [ "$status" -eq 0 ]
  not_called "addons enable metallb"
  not_called "upgrade --install traefik"
}

@test "PUB-13: PUBLIC_ACCESS=true без ACME_EMAIL — код 2 с именем параметра" {
  load_script
  PUBLIC_ACCESS=true ACME_EMAIL=""
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"ACME_EMAIL"* ]]
}

@test "PUB-13: вход в Grafana через GitHub без секрета — код 2" {
  load_script
  PUBLIC_ACCESS=true ACME_EMAIL=ops@example.org GRAFANA_GITHUB_CLIENT_ID=Iv1.x
  unset GRAFANA_GITHUB_CLIENT_SECRET GRAFANA_GITHUB_CLIENT_SECRET_FILE
  run validate_config
  [ "$status" -eq 2 ]
  [[ $output == *"GRAFANA_GITHUB_CLIENT_SECRET"* ]]
}

@test "PUB-03: без PUBLIC_BASE_DOMAIN — <IP с дефисами>.sslip.io; с ним — заданный домен" {
  load_script
  PUBLIC_BASE_DOMAIN=""
  [ "$(public_domain 34.12.5.6)" = 34-12-5-6.sslip.io ]
  PUBLIC_BASE_DOMAIN=hammurapi.duckdns.org
  [ "$(public_domain 34.12.5.6)" = hammurapi.duckdns.org ]
}

@test "R20: значения Grafana — Ingress, root_url и вход участников организации с ролью Editor" {
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

@test "R20: смена client ID или секрета OAuth-приложения перезапускает Grafana" {
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

# --- deploy-component.yml: проверка конфигурации до подключения (INS-05) ---
# Workflow лежит в публичном репозитории hammurapi (соседний каталог; в CI — DEPLOY_WORKFLOW).

config_step() {
  command -v yq >/dev/null || skip "нет yq"
  local wf=${DEPLOY_WORKFLOW:-$ROOT/../hammurapi/.github/workflows/deploy-component.yml}
  [[ -f $wf ]] || skip "нет $wf"
  yq -r '.jobs.deploy.steps[] | select(.id == "config") | .run' "$wf" >"$BATS_TEST_TMPDIR/config.sh"
  export GITHUB_OUTPUT=$BATS_TEST_TMPDIR/out COMPONENT=hammurapi-core DEPLOY_TRANSPORT=ssh CALLBACK_URL="" TAG=v1.8.0
  : >"$GITHUB_OUTPUT"
  export PROD_HOST=h PROD_USER=u HAS_PROD_SSH_KEY=true HAS_PROD_KNOWN_HOSTS=true HAS_HAMMURAPI_GHCR_PULL_TOKEN=true
  export HAMMURAPI_GITHUB_APP_ID=1 HAMMURAPI_GITHUB_CLIENT_ID=c HAMMURAPI_SPEC_REPO=o/r HAMMURAPI_BOOTSTRAP_ADMINS=a
  export HAS_HAMMURAPI_GITHUB_APP_PRIVATE_KEY=true HAS_HAMMURAPI_GITHUB_CLIENT_SECRET=true HAS_HAMMURAPI_WEBHOOK_SECRET=true
  export HAS_HAMMURAPI_TOKEN_ENCRYPTION_KEY=true
  # Required only by deploy-component.yml before HMR.CMN-0004 (ACP agent): the
  # workflow comes from hammurapi main, which may lag behind this repository.
  export HAMMURAPI_AGENT_COMMAND=x HAS_HAMMURAPI_AGENT_ENV=true
  mkdir -p "$BATS_TEST_TMPDIR/w/deploy"
  echo CHART_VERSION=0.4.0 >"$BATS_TEST_TMPDIR/w/deploy/versions.env"
}

@test "INS-05: нет HAMMURAPI_WEBHOOK_SECRET — ошибка до подключения с именем секрета" {
  config_step
  export HAS_HAMMURAPI_WEBHOOK_SECRET=false HAS_PROD_KNOWN_HOSTS=false
  cd "$BATS_TEST_TMPDIR/w"
  run bash -e "$BATS_TEST_TMPDIR/config.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"HAMMURAPI_WEBHOOK_SECRET (секрет)"* && $output == *"PROD_KNOWN_HOSTS (секрет)"* ]]
}

@test "INS-05: полная конфигурация core — версия чарта из deploy/versions.env" {
  config_step
  cd "$BATS_TEST_TMPDIR/w"
  run bash -e "$BATS_TEST_TMPDIR/config.sh"
  [ "$status" -eq 0 ]
  grep -qx "chart=0.4.0" "$GITHUB_OUTPUT"
}

@test "INS-05: web не требует конфигурации core" {
  config_step
  export COMPONENT=hammurapi-web
  unset HAMMURAPI_GITHUB_APP_ID HAMMURAPI_SPEC_REPO HAS_HAMMURAPI_WEBHOOK_SECRET
  cd "$BATS_TEST_TMPDIR/w"
  run bash -e "$BATS_TEST_TMPDIR/config.sh"
  [ "$status" -eq 0 ]
}

@test "CTR: запуск по контракту требует секрет подписи вебхука результата" {
  config_step
  export CALLBACK_URL=https://api.example.org/hooks/v1/deploy HAS_HAMMURAPI_DEPLOY_CALLBACK_SECRET=false
  cd "$BATS_TEST_TMPDIR/w"
  run bash -e "$BATS_TEST_TMPDIR/config.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"HAMMURAPI_DEPLOY_CALLBACK_SECRET"* ]]
}

@test "QUAL-03: действия GitHub Actions зафиксированы по SHA" {
  local bad wf=${DEPLOY_WORKFLOW:-$ROOT/../hammurapi/.github/workflows/deploy-component.yml} files=("$ROOT"/.github/workflows/*.yml)
  [[ -f $wf ]] && files+=("$wf")
  bad=$(grep -hE '^\s*(-\s*)?uses:\s*[^./]' "${files[@]}" | grep -vE '@[0-9a-f]{40}(\s|$)' || true)
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}
