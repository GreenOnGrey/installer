# installer

Installs GreenOnGrey products, Nabu and Hammurapi, with one command. It installs either on one clean machine with minikube or into an existing Kubernetes cluster. Storages (Postgres, Kafka, S3) and observability (VictoriaMetrics, VictoriaLogs, Grafana) are either built in or external, and MCP servers for agents are optional. A wizard asks the questions in a terminal. CI runs the same install with a config file. Specification: `FTR.INFRA.INST-0001`.

## Quick start

On Debian 13, or RHEL, Rocky or AlmaLinux 9 and 10, as a user with `sudo`:

```sh
curl -fsSL https://github.com/GreenOnGrey/installer/releases/latest/download/installer.tar.gz | tar xz && ./installer/installer
```

The wizard asks for the target, the products, the domain, the sign-in, the storages and the MCP servers. It then shows a summary and, after a `yes`, installs. The details are in [docs/quickstart.md](docs/quickstart.md), and how to verify the archive with its checksum and cosign signature is in [docs/security.md](docs/security.md#verifying-a-release).

## Documentation

| | |
|---|---|
| [quickstart.md](docs/quickstart.md) | From a clean machine to a running product |
| [minikube.md](docs/minikube.md) | One machine: requirements, what gets deployed, public access, reboots |
| [external-kubernetes.md](docs/external-kubernetes.md) | An existing cluster: requirements, checks, ingress, uninstall |
| [resources.md](docs/resources.md) | Built-in and external storages, backups, observability, checks |
| [products.md](docs/products.md) | Nabu and Hammurapi: sign-in, the GitHub App, connecting them |
| [mcp.md](docs/mcp.md) | MCP servers: options, memory, the Nabu catalog |
| [update.md](docs/update.md) | Updates, pins of one service, going back |
| [ci-cd.md](docs/ci-cd.md) | Running from CI: configuration, secrets, the JSON result |
| [reference.md](docs/reference.md) | Commands, every parameter, exit codes, the JSON result |
| [security.md](docs/security.md) | Verifying a release, secrets, network, what changes on the machine |
| [gcp.md](docs/gcp.md) | Google Cloud: managed storages and the production machine |
| [hammurapi.md](docs/hammurapi.md) | Our production: public access and the rollout of Hammurapi from its CI |

## Rollout to production

Production is a stand in Google Cloud. The workflow [`deploy-prod`](.github/workflows/deploy-prod.yml) rolls out a release tag:

- it runs on a push of a tag `vX.Y.Z`. A manual run from a tag repeats a rollout or returns to an earlier version (there is no automatic rollback), and `production` accepts only tags, so choose the tag under **Use workflow from**;
- it hands the production machine an export of the tag (`git archive`) over the same SSH, unpacks it into `/opt/installer/releases/<tag>` and runs `up` (the old name of `install`, which older tags know too, for a rollback). After a success `current` points to that tag, and the last 5 exports are kept. The production machine needs no access to GitHub, because deploy keys are forbidden by the organization's policy;
- `/opt/installer/local.env` and secret files stay on the machine and are not passed through the workflow. The exceptions are public access, Grafana sign-in through GitHub and MCP servers (below): their parameters reach `install` through the stdin of the SSH session and are not written to disk. Logs of all runs are in `/opt/installer/logs`;
- rollouts run one at a time (`concurrency`), and `/var/lock/installer.lock` blocks a parallel `install` on the machine (code 17);
- after a pushed tag succeeds on production, the job `release` publishes the GitHub Release of the tag: `installer.tar.gz` (`.github/scripts/release-archive.sh`: the tag without `.github` and tests, with a file `RELEASE` that names the tag and commit), its `.sha256` and the cosign bundle `.sigstore.json`. A manual run publishes nothing, so an old tag never becomes the latest release;
- the outcome is the `status` summary in the run's report. The deployed tag shows in `status` (ConfigMap `installer/installer-version`). The log of each run stays on the machine: the repository is public, so logs are not uploaded as artifacts.

Settings of the GitHub environment `production`:

| Name | Type | When | Purpose |
|---|---|---|---|
| `DEPLOY_TRANSPORT` | variable | always | `ssh` (default) or `gcp-iap` |
| `PROD_HOST` | secret | `ssh` | Machine address (a secret, so it stays out of public logs) |
| `PROD_USER` | variable | `ssh` | Machine user |
| `PROD_SSH_KEY` | secret | `ssh` | Private key of the rollout user |
| `PROD_KNOWN_HOSTS` | secret | `ssh` | Host fingerprint (`ssh-keyscan -t ed25519 <address>`); host checking stays on |
| `GCP_PROJECT`, `GCP_ZONE`, `GCP_INSTANCE` | variables | `gcp-iap` | The production machine |
| `GCP_WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT` | variables | `gcp-iap` | Workload Identity Federation |
| `PUBLIC_ACCESS` | variable | public access | `true` |
| `ACME_EMAIL` | secret | public access | Address for Let's Encrypt |
| `GRAFANA_GITHUB_CLIENT_ID`, `GRAFANA_GITHUB_ORG` | variables | Grafana sign-in through GitHub | The organization's OAuth app; the default organization is `GreenOnGrey` ([docs/hammurapi.md](docs/hammurapi.md#12-github-oauth-app-for-grafana)) |
| `GRAFANA_GITHUB_CLIENT_SECRET` | secret | Grafana sign-in through GitHub | Client secret of the OAuth app |
| `MCP_DOCLING`, `MCP_SEARCH`, `MCP_YANDEX_MAIL`, `MCP_DOCGEN` | variables | MCP servers | `true` enables a server, `false` disables it; an unset variable keeps the value from `local.env` or the cluster |
| `MCP_DOCLING_MAX_MB`, `MCP_SEARCH_ENGINES` | variables | MCP servers | Server parameters |

Preparing the production machine is described in [docs/gcp.md](docs/gcp.md#production-machine).

The products roll out to production from their own pipelines, through the reusable workflow `deploy-component.yml` of `nabu` and `hammurapi` and the scripts `bin/nabu-deploy` and `bin/hammurapi-deploy`. A release tag `vX.Y.Z` of this repository publishes the charts of the products with the version `X.Y.Z`. The firewall, the OAuth app of Grafana, the GitHub App and the codes of the rollout are in [docs/hammurapi.md](docs/hammurapi.md).

## Development

```text
installer                 entry point: the wizard | install | update | status | creds | uninstall
lib/                      common, host, prereqs, cluster, secrets, state, deploy, external, checks, public, mcp,
                          product, update, uninstall, preflight, wizard
config/                   versions.env (versions), defaults.env, local.env.example, mcp-servers.tsv
docs/                     the documentation of users
values/                   chart values; values/scrape/ holds vmagent scrape jobs
charts/hammurapi-storages CRs of Kafka and Postgres, stable services postgres, kafka, s3
charts/hammurapi-dashboards ConfigMaps of dashboards
dashboards/               dashboard JSON, normalize.sh, README with sources
tests/unit/               bats: script functions with external commands stubbed; docs.bats checks docs/reference.md
tests/manifests.sh        renders releases for 8 combinations of modes, kubeconform, resources
tests/e2e/e2e.sh          e2e on a temporary Google Cloud machine
.github/workflows/        checks (every PR), e2e (manual), deploy-prod (tags)
```

```sh
shellcheck -x installer tests/manifests.sh tests/e2e/*.sh dashboards/normalize.sh .github/scripts/*.sh
bats tests/unit             # bats-core ≥ 1.5
tests/manifests.sh          # helm ≥ 3.17, kubeconform, jq, yq
```

The e2e workflow (`.github/workflows/e2e.yml`, run manually) creates an `e2-standard-4` machine with a clean Debian 13, runs `install`, a repeated `install`, a reboot, failure scenarios and `uninstall`, writes stage times to a report and deletes the machine. Run it before a release of this repository and when `config/versions.env`, `values/` or `charts/` change.
