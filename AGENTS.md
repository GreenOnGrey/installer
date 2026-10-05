# AGENTS.md — hammurapi-infra

Guide for coding agents and developers working in this repository.

## Workspace

Hammurapi is five repositories checked out side by side: `hammurapi-core` (Go backend),
`hammurapi-web` (SPA), `hammurapi` (public docs, demo stack, reusable deploy workflow),
`hammurapi-infra` (this one, private: the stand, the charts of Hammurapi and of Nabu) and
`hammurapi-specs`. Nabu (`nabu-core`, `nabu-web`, `nabu` — FTR.NAB.CMN-0001) runs on the same stand;
its charts and `bin/nabu-deploy` live here too, exactly like those of Hammurapi.

- The stand is specified in `hammurapi-specs/specs/HMR/INFRA/FTR.HMR.INFRA-0001` (stand) and
  `FTR.HMR.INFRA-0002` (Hammurapi on the stand); product features in `…/CMN/FTR.HMR.CMN-NNNN`.
  Refer to them as `FTR.HMR.INFRA-0002 R19` (old `PLT.INFRA-…` is obsolete). Deviations are
  written into the spec.
- Docs, comments and CLI messages of this repository are in Russian.
- Do not commit, tag or push unless asked. One-off production setup (firewall, `local.env`) is done
  by the maintainer by hand, not automated in workflows.

## Contents

```text
hammurapi-infra.sh       CLI: up | status | creds | down — a minikube stand with storages,
                         observability, public access (MetalLB, Traefik, cert-manager)
lib/*.sh                 functions sourced by the CLI (common, host, prereqs, cluster, deploy, public, …)
bin/hammurapi-deploy     deploys hammurapi-core/web on the stand; reads one JSON from stdin
bin/nabu-deploy          deploys nabu-core/web (namespaces nabu, nabu-sandboxes; its DB, bucket, hosts)
bin/stand-autostart      systemd unit hammurapi-stand: the stand starts after a VM reboot
charts/hammurapi-core    api, worker, agent operator, migrate, cleaner, network policies
charts/hammurapi-web     the SPA
charts/nabu-core         Nabu: api, worker, agent, relay, migrate, cleaner, RBAC for sandboxes
charts/nabu-web          the SPA of Nabu
config/                  defaults.env, versions.env (chart and tool versions)
values/                  Helm values of the stand's components
dashboards/              Grafana dashboards
tests/unit/*.bats        unit tests (Linux); tests/manifests.sh — rendered manifests; tests/e2e
```

## Commands

```sh
shellcheck -x hammurapi-infra.sh                       # CI pins shellcheck v0.11.0
shellcheck -x tests/manifests.sh tests/e2e/*.sh bin/hammurapi-deploy bin/nabu-deploy bin/ingress-forward bin/stand-autostart
bats tests/unit                                        # Linux; needs jq, yq for some tests
bash tests/manifests.sh                                # helm, kubeconform, jq, yq, network
helm lint charts/hammurapi-core --set image.tag=v1 --set publicBaseDomain=x.example
```

## Rules

- **Shell, YAML and Helm templates are edited by hand.** A formatter once replaced `lib/*.sh` with
  the content of `tests/manifests.sh` (endless recursion → segfault of `up` and of the manifest
  check) and re-indented `values/scrape/hammurapi.yaml`. After bulk edits, diff every file.
- Scripts are `set -euo pipefail`; `lib/*.sh` start with `# shellcheck shell=bash` and are sourced
  with `# shellcheck source=…`.
- **Secrets** come through stdin (`hammurapi-deploy`, `deploy-remote.sh up`) or the environment —
  never argv, logs or files; tests check this. Never disable SSH host key checking.
- `hammurapi-deploy` keeps its exit codes and the last line of JSON output (the deploy contract);
  `AGENT_SERVICE_TOKEN` is created once and kept in `hammurapi-secrets`.
- The chart of core gives the agent operator only its token (no storages, no other secrets) and
  network policies: to the operator only api, worker and runner pods; to a runner's workspace port
  only the operator.
- `tests/unit/public.bats` runs the config step of `deploy-component.yml` from `hammurapi` `main`;
  keep it working with the workflow both before and after a change there.

## Releases

A tag `vX.Y.Z` (`deploy-prod.yml`) publishes the charts with version `X.Y.Z` to
`oci://ghcr.io/greenongrey/charts` (existing versions are skipped), then deploys the stand: the code
is copied over SSH to `/opt/hammurapi-infra/releases/<tag>`, `up` runs, and `current` switches to the
tag only after `up` succeeds. Core and web install a chart by `CHART_VERSION` in their
`deploy/versions.env`. A broken tag is fixed by a new tag, not by moving the old one.
