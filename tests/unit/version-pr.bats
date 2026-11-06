#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2016,SC2030,SC2031,SC2153,SC2329
# FTR.INFRA.INST-0001 R25: the PR of a version (.github/workflows/version-pr.yml), its step run against a local
# origin and a gh that keeps the open PRs in a file.

load helpers

setup() {
  command -v yq >/dev/null || skip "no yq"
  setup_stubs
  W=$BATS_TEST_TMPDIR
  yq -r '.jobs.pr.steps[] | select(.id == "pr") | .run' "$ROOT/.github/workflows/version-pr.yml" >"$W/pr.sh"
  git init -q --bare "$W/origin.git"
  git init -q -b main "$W/installer"
  mkdir -p "$W/installer/config"
  printf 'NABU_CORE_VERSION=v0.3.5\nNABU_WEB_VERSION=v0.3.4\nNABU_CHART_VERSION=0.3.0\nNABU_PI_VERSION=1.5.0\n' >"$W/installer/config/versions.env"
  git -C "$W/installer" add -A
  git -C "$W/installer" -c user.name=t -c user.email=t@example.com commit -q -m init
  git -C "$W/installer" remote add origin "$W/origin.git"
  git -C "$W/installer" push -q origin main
  PRS=$W/prs
  : >"$PRS"
  # gh: PRs as lines "number branch url"; list answers with JSON through the given --jq.
  stub gh '
prs=$PRS
case "$1 $2" in
  "api /users/"*) echo 42 ;;
  "pr create")
    while (($#)); do [[ $1 == --head ]] && head=$2; shift; done
    n=$(($(cat "$prs.n" 2>/dev/null || echo 10) + 1)); echo "$n" >"$prs.n"
    echo "$n $head https://github.com/o/installer/pull/$n" >>"$prs"
    echo "https://github.com/o/installer/pull/$n" ;;
  "pr close") grep -v "^$3 " "$prs" >"$prs.new" || true; mv "$prs.new" "$prs" ;;
  "pr list")
    head="" q=""
    while (($#)); do case $1 in --head) head=$2 ;; --jq) q=$2 ;; esac; shift; done
    awk -v h="$head" "h == \"\" || \$2 == h { printf \"{\\\"number\\\":%s,\\\"headRefName\\\":\\\"%s\\\",\\\"url\\\":\\\"%s\\\"}\\n\", \$1, \$2, \$3 }" "$prs" |
      jq -s . | jq -r "$q" ;;
esac'
  # deploy/versions.env of the component at its tag, as raw.githubusercontent.com serves it.
  PINNED=$W/pinned.env
  printf 'DEPLOY_WORKFLOW_REF=v0.1.3\nCHART_VERSION=0.3.0\nPI_VERSION=1.5.0\n' >"$PINNED"
  stub curl 'while (($#)); do [[ $1 == -o ]] && cp "$PINNED" "$2"; shift; done'
  export PRS PINNED
}

# pr <component> <tag> — the step, as the workflow runs it in the checkout of installer.
pr() {
  cd "$W/installer" || return
  git checkout -q main
  git reset -q --hard origin/main
  COMPONENT=$1 TAG=$2 APP_SLUG=gog-versions RUN_URL=https://github.com/o/nabu-core/actions/runs/1 CALLER=o/nabu-core \
    RUNNER_TEMP=$W GITHUB_STEP_SUMMARY=/dev/null run bash "$W/pr.sh"
  # Each run of the workflow starts from a fresh checkout of main.
  git reset -q --hard origin/main
}

branch_file() { git -C "$W/installer" show "origin/$1:config/versions.env"; }

@test "R25: a newer version on production opens one PR with one changed line, as the App" {
  pr nabu-core v0.3.6
  [ "$status" -eq 0 ]
  grep -q ' versions/nabu-core-v0.3.6 ' "$PRS"
  branch_file versions/nabu-core-v0.3.6 | grep -qx 'NABU_CORE_VERSION=v0.3.6'
  branch_file versions/nabu-core-v0.3.6 | grep -qx 'NABU_WEB_VERSION=v0.3.4'
  git -C "$W/installer" log -1 --format='%an %ae' origin/versions/nabu-core-v0.3.6 |
    grep -qx 'gog-versions\[bot\] 42+gog-versions\[bot\]@users.noreply.github.com'
  # The same rollout again: the PR is there, nothing new.
  pr nabu-core v0.3.6
  [ "$(wc -l <"$PRS")" -eq 1 ]
}

@test "R25: a branch of a failed attempt without a PR gets its PR, made anew from main" {
  git -C "$W/installer" push -q origin main:refs/heads/versions/nabu-core-v0.3.6
  pr nabu-core v0.3.6
  [ "$status" -eq 0 ]
  grep -q ' versions/nabu-core-v0.3.6 ' "$PRS"
  branch_file versions/nabu-core-v0.3.6 | grep -qx 'NABU_CORE_VERSION=v0.3.6'
}

@test "R25: the agent Pi comes with nabu-core; the chart only moves forward" {
  printf 'CHART_VERSION=0.2.0\nPI_VERSION=1.6.0\n' >"$PINNED"
  pr nabu-core v0.3.6
  [ "$status" -eq 0 ]
  branch_file versions/nabu-core-v0.3.6 | grep -qx 'NABU_PI_VERSION=1.6.0'
  branch_file versions/nabu-core-v0.3.6 | grep -qx 'NABU_CHART_VERSION=0.3.0'
  printf 'CHART_VERSION=0.4.0\nPI_VERSION=1.6.0\n' >"$PINNED"
  pr nabu-web v0.3.5
  branch_file versions/nabu-web-v0.3.5 | grep -qx 'NABU_CHART_VERSION=0.4.0'
  branch_file versions/nabu-web-v0.3.5 | grep -qx 'NABU_PI_VERSION=1.5.0'
}

@test "R25: a PR of a neighbour merged meanwhile: the branch is rebuilt on the new main" {
  pr nabu-core v0.3.6
  sed -i 's/^NABU_WEB_VERSION=.*/NABU_WEB_VERSION=v0.3.5/' "$W/installer/config/versions.env"
  git -C "$W/installer" -c user.name=t -c user.email=t@example.com commit -q -am web
  git -C "$W/installer" push -q origin main
  pr nabu-core v0.3.6
  [ "$status" -eq 0 ]
  branch_file versions/nabu-core-v0.3.6 | grep -qx 'NABU_WEB_VERSION=v0.3.5'
  [ "$(wc -l <"$PRS")" -eq 1 ]
}

@test "R25: a newer rollout supersedes the PR of the older one" {
  pr nabu-core v0.3.6
  pr nabu-core v0.3.7
  [ "$status" -eq 0 ]
  [ "$(awk '{print $2}' "$PRS")" = versions/nabu-core-v0.3.7 ]
  # Another component is left alone.
  pr nabu-web v0.3.5
  pr nabu-core v0.3.8
  grep -q ' versions/nabu-web-v0.3.5 ' "$PRS"
}

@test "R25: production goes back: no PR, and the PRs of newer versions are closed" {
  pr nabu-core v0.3.7
  pr nabu-core v0.3.4
  [ "$status" -eq 0 ]
  [[ $output == *"older than v0.3.5"* ]]
  [ ! -s "$PRS" ]
  pr nabu-core v0.3.7
  pr nabu-core v0.3.5
  [[ $output == *"already has"* ]]
  [ ! -s "$PRS" ]
}

@test "R25: the set got the version some other way: the PR of the same version closes too" {
  pr nabu-core v0.3.6
  sed -i 's/^NABU_CORE_VERSION=.*/NABU_CORE_VERSION=v0.3.6/' "$W/installer/config/versions.env"
  git -C "$W/installer" -c user.name=t -c user.email=t@example.com commit -q -am core
  git -C "$W/installer" push -q origin main
  pr nabu-core v0.3.6
  [[ $output == *"already has"* ]]
  [ ! -s "$PRS" ]
}

@test "R25: a component outside the set, a bad tag or an ambiguous line: an error, no PR" {
  pr nabu-agent v0.3.6
  [ "$status" -ne 0 ]
  pr nabu-core main
  [ "$status" -ne 0 ]
  printf 'NABU_CORE_VERSION=v0.3.5\nNABU_CORE_VERSION=v0.3.6\n' >>"$W/installer/config/versions.env"
  git -C "$W/installer" -c user.name=t -c user.email=t@example.com commit -q -am twice
  git -C "$W/installer" push -q origin main
  pr nabu-core v0.3.7
  [ "$status" -ne 0 ]
  [[ $output == *"exactly one line"* ]]
  [ ! -s "$PRS" ]
}
