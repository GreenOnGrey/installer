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
# (режим unpack) или уже распакован (режим up).
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
    cd "$dir/current" 2>/dev/null || { echo '{"error":"нет развёрнутого релиза"}'; exit 1; }
    cfg=()
    [[ -f $dir/local.env ]] && cfg=(--config "$dir/local.env")
    bash ./hammurapi-infra.sh status --json --no-color "${cfg[@]}" 2>/dev/null
    ;;
  *)
    echo "режим: unpack | up | status" >&2
    exit 2
    ;;
esac
