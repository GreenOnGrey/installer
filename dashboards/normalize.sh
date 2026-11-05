#!/usr/bin/env bash
# Normalizes a dashboard before adding it to the repository (tech, §8):
#   - data source references (variables ${DS_…}, $ds and so on) → UID victoriametrics;
#   - Grafana expressions (${DS_EXPRESSION}) → __expr__;
#   - template variables of type datasource, __inputs, __requires, __elements, id are removed;
#   - the dashboard uid is stable: hammurapi-<file name>.
# Usage: dashboards/normalize.sh <source.json> <name>  → dashboards/<name>.json
set -euo pipefail

src=${1:?source JSON}
name=${2:?dashboard name, such as kafka}
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

jq --arg uid "hammurapi-$name" '
  def vm: {type: "prometheus", uid: "victoriametrics"};
  def expr: {type: "__expr__", uid: "__expr__"};
  def builtin: (. == "grafana" or . == "-- Grafana --" or . == "-- Mixed --" or . == "-- Dashboard --");
  def fixds:
    if type == "string" then
      if builtin then .
      elif test("EXPR"; "i") then expr
      else vm end
    elif type == "object" then
      if ((.uid // "") | builtin) or (.type // "") == "datasource" or (.type // "") == "grafana" then .
      elif (.type // "") == "__expr__" or ((.uid // "") | test("EXPR"; "i")) then expr
      else vm end
    else . end;
  del(.__inputs, .__requires, .__elements, .id)
  | .uid = $uid
  | .templating.list = [(.templating.list // [])[] | select(.type != "datasource")]
  | walk(if type == "object" and has("datasource") and .datasource != null then .datasource |= fixds else . end)
' "$src" >"$dir/$name.json.tmp"
mv "$dir/$name.json.tmp" "$dir/$name.json"
echo "dashboards/$name.json: $(jq -r .title "$dir/$name.json")"
