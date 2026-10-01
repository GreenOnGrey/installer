#!/usr/bin/env bash
# deploy-remote.sh — выполняется на машине прода (через remote.sh, bash -s).
# Раскладывает выгрузку тега, полученную workflow, и запускает `up`.
# Машине не нужен доступ к GitHub: код приходит от раннера по тому же SSH.
#
#   /opt/hammurapi-infra/
#     local.env            конфигурация прода (не из git, не меняется выкаткой)
#     logs/                журналы всех запусков up
#     releases/<тег>/      выгрузки тегов, последние KEEP_RELEASES
#     current -> releases/<тег>   успешно развёрнутый тег
#
# Аргументы: <каталог прода> <тег> <коммит> <инициатор>; архив tar.gz — в stdin
# (режим unpack) или уже распакован (режим up; в stdin — параметры стенда из GitHub).
set -euo pipefail
mode=$1 dir=$2 tag=$3
keep=${KEEP_RELEASES:-5}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "недопустимый тег $tag" >&2; exit 1; }

case $mode in
  unpack)
    mkdir -p "$dir/releases" "$dir/logs"
    rm -rf "$dir/releases/$tag.tmp"
    mkdir -p "$dir/releases/$tag.tmp"
    tar -xzf - -C "$dir/releases/$tag.tmp"
    rm -rf "$dir/releases/$tag"
    mv "$dir/releases/$tag.tmp" "$dir/releases/$tag"
    echo "выгрузка $tag: $dir/releases/$tag"
    ;;
  up)
    commit=$4 actor=$5
    # Параметры стенда из переменных и секретов GitHub — строки KEY=VALUE в stdin.
    # Только ключи из списка и только в окружение up: на диск не пишутся, в argv не
    # попадают; окружение важнее local.env (load_config).
    allowed=" PUBLIC_ACCESS ACME_EMAIL ACME_ISSUER PUBLIC_BASE_DOMAIN PUBLIC_IP"
    allowed+=" GRAFANA_GITHUB_CLIENT_ID GRAFANA_GITHUB_CLIENT_SECRET GRAFANA_GITHUB_ORG "
    if [[ ! -t 0 ]]; then
      while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line ]] && continue
        key=${line%%=*}
        [[ $allowed == *" $key "* ]] || { echo "параметр «$key» из GitHub не поддерживается" >&2; exit 2; }
        export "$key=${line#*=}"
        echo "параметр из GitHub: $key"
      done
    fi
    cd "$dir/releases/$tag"
    ln -sfn "$dir/logs" logs
    cfg=()
    [[ -f $dir/local.env ]] && cfg=(--config "$dir/local.env")
    INFRA_TAG=$tag INFRA_COMMIT=$commit DEPLOYED_BY=$actor bash ./hammurapi-infra.sh up --no-color "${cfg[@]}"
    ln -sfn "releases/$tag" "$dir/current"
    # Храним текущую выгрузку и ещё keep-1 последних; имена — проверенные теги.
    n=1
    # shellcheck disable=SC2012
    while IFS= read -r d; do
      [[ $d == "$dir/releases/$tag" ]] && continue
      n=$((n + 1))
      ((n > keep)) && rm -rf "$d"
    done < <(ls -1dt "$dir"/releases/v* 2>/dev/null)
    true
    ;;
  status)
    # После неудачной выкатки current ещё нет — состояние кластера всё равно полезно.
    cd "$dir/current" 2>/dev/null || cd "$dir/releases/$tag" 2>/dev/null ||
      { echo '{"error":"нет выгрузки релиза на машине"}'; exit 1; }
    cfg=()
    [[ -f $dir/local.env ]] && cfg=(--config "$dir/local.env")
    bash ./hammurapi-infra.sh status --json --no-color "${cfg[@]}" 2>/dev/null
    ;;
  *)
    echo "режим: unpack | up | status" >&2
    exit 2
    ;;
esac
