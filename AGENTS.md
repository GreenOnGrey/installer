# AGENTS.md — hammurapi-infra

Guide for coding agents and developers working in this repository.

## Workspace

Hammurapi is five repositories checked out side by side: `hammurapi-core` (Go backend),
`hammurapi-web` (SPA), `hammurapi` (public docs, Helm chart, reusable deploy workflow),
`hammurapi-infra` (this one, private: the stand, the charts of Hammurapi, of Nabu and of the site) and
`hammurapi-specs`. Nabu (`nabu-core`, `nabu-web`, `nabu` — FTR.NAB.CMN-0001) runs on the same stand;
its charts and `bin/nabu-deploy` live here too, exactly like those of Hammurapi. The site of GreenOnGrey
(`landing` — FTR.LND.WEB-0001) runs here as well: namespace `landing`, host `web.<domain>`.

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
bin/landing-deploy       deploys the site of GreenOnGrey (namespace landing, host web.<domain>; no storages;
                         an optional domain of its own with a certificate and a redirect from www.)
bin/stand-autostart      systemd unit hammurapi-stand: the stand starts after a VM reboot; kubelet-gc mode
                         turns on kubelet image garbage collection (IMAGE_GC_* options)
charts/hammurapi-core    api, worker, migrate, cleaner, network policies; no agent or runner — code tasks run in Nabu
charts/hammurapi-web     the SPA
charts/nabu-core         Nabu: api, worker, agent, relay, egress, migrate, cleaner, RBAC for sandboxes and the
                         DaemonSet of preloaded sandbox images; sandboxes.profiles — images of sandbox profiles
charts/nabu-web          the SPA of Nabu
charts/landing           the site of GreenOnGrey: nginx with static pages
charts/mcp-servers       optional MCP servers of the stand (FTR.NAB.CMN-0006): docling, search, yandex-mail,
                         docgen (FTR.NAB.CHAT-0003: docgen-mcp and doc-convert — Gotenberg with a legacy
                         sidecar); lib/mcp.sh deploys them by MCP_* options, images/ builds docling-mcp,
                         imap-mcp (our own read-only IMAP server), docgen-mcp and doc-convert; each has
                         python -m unittest and/or images/*/test.sh
config/                  defaults.env, versions.env (chart and tool versions)
values/                  Helm values of the stand's components
dashboards/              Grafana dashboards; alert rules are in values/grafana.yaml (alerting)
tests/unit/*.bats        unit tests (Linux); tests/manifests.sh — rendered manifests; tests/e2e
```

## Commands

```sh
shellcheck -x hammurapi-infra.sh                       # CI pins shellcheck v0.11.0
shellcheck -x tests/manifests.sh tests/e2e/*.sh bin/hammurapi-deploy bin/nabu-deploy bin/landing-deploy bin/ingress-forward bin/stand-autostart images/publish.sh images/*/test.sh
bats tests/unit                                        # Linux; needs jq, yq for some tests
bash tests/manifests.sh                                # helm, kubeconform, jq, yq, network
helm lint charts/hammurapi-core --set image.tag=v1 --set publicBaseDomain=x.example
helm lint charts/landing --set image.tag=v1 --set publicBaseDomain=x.example
```

## Checks before a commit

A change is ready when every job of `.github/workflows/checks.yml` passes locally at the versions the workflow pins, plus the
matching lines below. Read the workflow for the exact commands. Install a missing tool outside the repository
at the pinned version. Name any job you could not run in your report, with the reason.

- Always: `shellcheck` on the file list of `checks.yml`, `actionlint`, `bats tests/unit` with `../hammurapi` checked out beside this repository (its `deploy-component.yml` is under test).
- `charts/**`: `bash tests/manifests.sh`.
- `images/**`: `images/publish.sh --test-only`.
- A chart change also has to survive an upgrade of the live release, which `helm template` cannot show. A dropped field can come back through its deprecated twin (`serviceAccountName`/`serviceAccount`), so set the new value explicitly; a dropped object is deleted after the new pods start. Compare with `kubectl patch --dry-run=server` on the live resource.
- A changed public route: update the post-deploy checks of `deploy-component.yml` in `nabu` and `hammurapi`, and tag them before the release of the component.
- Always, after the checks pass: run the `code-review` skill on the diff to be committed. Fix each finding, or name it in your report with the reason it stays. Ask the user when you doubt a finding.

## Rules

- **Shell, YAML and Helm templates are edited by hand.** A formatter once replaced `lib/*.sh` with
  the content of `tests/manifests.sh` (endless recursion → segfault of `up` and of the manifest
  check) and re-indented `values/scrape/hammurapi.yaml`. After bulk edits, diff every file.
- Scripts are `set -euo pipefail`; `lib/*.sh` start with `# shellcheck shell=bash` and are sourced
  with `# shellcheck source=…`.
- **Secrets** come through stdin (`hammurapi-deploy`, `deploy-remote.sh up`) or the environment —
  never argv, logs or files; tests check this. Never disable SSH host key checking.
- `hammurapi-deploy` keeps its exit codes and the last line of JSON output (the deploy contract).
- The chart of core has no agent and no runner (FTR.HMR.CMN-0007): code tasks run in the sandboxes of
  Nabu; the MCP of the worker (`worker-mcp:8083`) is open only to the namespace of Nabu.
- **Images of `images/` are published once per version** (`images/publish.sh` skips a tag that exists): a change
  of `images/imap-mcp` needs a new `IMAP_MCP_VERSION` (`DOCGEN_MCP_VERSION`, `DOC_CONVERT_VERSION` for the others; and
  the tag in `charts/mcp-servers/values.yaml`), or the stand
  keeps running the old image.
- `tests/unit/public.bats` runs the config step of `deploy-component.yml` from `hammurapi` `main`;
  keep it working with the workflow both before and after a change there.

## Releases

A tag `vX.Y.Z` (`deploy-prod.yml`) publishes the charts with version `X.Y.Z` to
`oci://ghcr.io/greenongrey/charts` (existing versions are skipped), then deploys the stand: the code
is copied over SSH to `/opt/hammurapi-infra/releases/<tag>`, `up` runs, and `current` switches to the
tag only after `up` succeeds. Core and web install a chart by `CHART_VERSION` in their
`deploy/versions.env`. A broken tag is fixed by a new tag, not by moving the old one.
