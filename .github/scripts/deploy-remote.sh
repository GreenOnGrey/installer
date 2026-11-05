#!/usr/bin/env bash
# deploy-remote.sh runs on the production machine (through remote.sh, bash -s).
# It unpacks the tag export received from the workflow and runs `up`.
# The machine needs no access to GitHub: the code comes from the runner over the same SSH.
#
#   /opt/hammurapi-infra/
#     local.env            production configuration (not from git, a rollout does not change it)
#     logs/                logs of all up runs
#     releases/<tag>/      tag exports, the last KEEP_RELEASES
#     current -> releases/<tag>   the successfully deployed tag
#
# Arguments: <production directory> <tag> <commit> <initiator>; a tar.gz archive on stdin
# (mode unpack) or already unpacked (mode up; stdin holds stand parameters from GitHub).
set -euo pipefail
mode=$1 dir=$2 tag=$3
keep=${KEEP_RELEASES:-5}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid tag $tag" >&2; exit 1; }

# cli — the CLI of the export in the current directory. Exports of tags before the rename hold
# hammurapi-infra.sh, while this script is new on a rollback to such a tag.
cli() { if [[ -f ./installer ]]; then echo ./installer; else echo ./hammurapi-infra.sh; fi; }

case $mode in
  unpack)
    mkdir -p "$dir/releases" "$dir/logs"
    rm -rf "$dir/releases/$tag.tmp"
    mkdir -p "$dir/releases/$tag.tmp"
    tar -xzf - -C "$dir/releases/$tag.tmp"
    rm -rf "$dir/releases/$tag"
    mv "$dir/releases/$tag.tmp" "$dir/releases/$tag"
    echo "export $tag: $dir/releases/$tag"
    ;;
  up)
    commit=$4 actor=$5
    # Stand parameters from GitHub variables and secrets: KEY=VALUE lines on stdin.
    # Only listed keys, and only into the environment of up: not written to disk, not in
    # argv; the environment wins over local.env (load_config).
    allowed=" PUBLIC_ACCESS ACME_EMAIL ACME_ISSUER PUBLIC_BASE_DOMAIN PUBLIC_IP"
    allowed+=" GRAFANA_GITHUB_CLIENT_ID GRAFANA_GITHUB_CLIENT_SECRET GRAFANA_GITHUB_ORG"
    # MCP servers of the stand (FTR.NAB.CMN-0006, FTR.NAB.CHAT-0003)
    allowed+=" MCP_DOCLING MCP_SEARCH MCP_YANDEX_MAIL MCP_DOCGEN MCP_DOCLING_MAX_MB MCP_SEARCH_ENGINES "
    if [[ ! -t 0 ]]; then
      while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line ]] && continue
        key=${line%%=*}
        [[ $allowed == *" $key "* ]] || { echo "parameter '$key' from GitHub is not supported" >&2; exit 2; }
        export "$key=${line#*=}"
        echo "parameter from GitHub: $key"
      done
    fi
    cd "$dir/releases/$tag"
    ln -sfn "$dir/logs" logs
    cfg=()
    [[ -f $dir/local.env ]] && cfg=(--config "$dir/local.env")
    INFRA_TAG=$tag INFRA_COMMIT=$commit DEPLOYED_BY=$actor bash "$(cli)" up --no-color "${cfg[@]}"
    ln -sfn "releases/$tag" "$dir/current"
    # Keep the current export and keep-1 more; names are verified tags.
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
    # After a failed rollout there is no current yet, but the cluster state is still useful.
    cd "$dir/current" 2>/dev/null || cd "$dir/releases/$tag" 2>/dev/null ||
      { echo '{"error":"no release export on the machine"}'; exit 1; }
    cfg=()
    [[ -f $dir/local.env ]] && cfg=(--config "$dir/local.env")
    bash "$(cli)" status --json --no-color "${cfg[@]}" 2>/dev/null
    ;;
  *)
    echo "mode: unpack | up | status" >&2
    exit 2
    ;;
esac
