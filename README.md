# installer

Runs GreenOnGrey products with one command on a clean Debian 13 machine: a minikube cluster with storages (Kafka, Postgres, S3-compatible storage) and observability (VictoriaMetrics, VictoriaLogs, Grafana). Specifications: `FTR.HMR.INFRA-0001`, `FTR.INFRA.INST-0001`.

The stand does not depend on a cloud. Any storage can be replaced with a managed cloud service: the service address and connection secret stay the same, so consumers change nothing.

> This is a single-node stand without high availability or backups, not a production setup. Nothing is published outside by default.

## What gets deployed

```text
Debian 13 machine ─ Docker ─ minikube (profile hammurapi, docker driver, 3 CPU / 12 GB)
  namespace storages       Kafka 4.3 (Strimzi, KRaft, 1 broker)      kafka.storages.svc:9092
                           Postgres 18 (CloudNativePG, 1 instance)   postgres.storages.svc:5432
                           SeaweedFS (S3, one pod)                   s3.storages.svc:9000
                           secrets postgres-conn, kafka-conn, s3-conn
  namespace observability  VictoriaMetrics (metrics, 7 days)  VictoriaLogs (logs, 3 days)
                           vmagent + kube-state-metrics + node-exporter   Vector (logs of all pods)
                           Grafana: 2 data sources and dashboards in the folder "Hammurapi Infra"
  namespace installer      state of the install: version, public access, MCP settings
```

The object storage is SeaweedFS, not MinIO: MinIO community images are no longer published (Docker Hub `minio/minio` is gone, quay.io requires authorization). The `s3-conn` interface and the address `s3.storages.svc:9000` are the same. MinIO or any other S3-compatible storage can be connected as an external one.

Versions of all components and charts are in [`config/versions.env`](config/versions.env).

## Machine requirements

| | Minimum |
|---|---|
| OS | x86_64: Debian 13 (trixie), or RHEL, Rocky or AlmaLinux 9 and 10 (SELinux may stay enforcing; `podman` and `runc` conflict with Docker CE and must be removed first) |
| CPU / memory | 4 vCPU, 16 GB (default profile: minikube 3 CPU / 12 GB) |
| Disk | 80 GB free (a 100 GB disk is recommended) |
| Permissions | a regular user with passwordless `sudo`; do **not** run as root: minikube with the docker driver does not work as root |
| Network | internet access: packages, images, charts, the Grafana plugin |

The script checks all of this before installing and exits without changing anything if a check fails.

## Quick start

```sh
git clone https://github.com/GreenOnGrey/installer.git
cd installer
./installer install
```

`install` installs Docker Engine, kubectl, Helm and minikube at the required versions (leaving installed ones alone), starts the cluster, generates passwords, deploys the components, checks the stand and prints a summary. On a clean machine this takes about 15–20 minutes, a repeated run takes a couple of minutes.

Grafana opens through an SSH tunnel, since nothing is published outside:

```sh
# on your computer
ssh -L 3000:localhost:3000 <user>@<machine address>
# on the machine, in this session
kubectl --context greenongrey -n observability port-forward svc/grafana 3000:80
# then open http://localhost:3000; the username and password are in ./installer creds
```

## Commands

| Command | What it does |
|---|---|
| `./installer install` | Installs and deploys, asking nothing. A repeated run is safe: it brings the stand to the described state, keeps data and passwords, and applies changed versions. `up` is its old name |
| `./installer status [--json]` | State of the cluster, releases and pods, the deployed version, checks, requested memory |
| `./installer creds [--json]` | Service addresses, secret names, usernames and passwords of storages and Grafana |
| `./installer uninstall [--yes]` | Removes what the installer installed, after a confirmation (without a terminal `--yes` is required): on minikube the profile with all its data and the units; on an existing cluster the releases and namespaces of the installer and of the products, with the data of built-in storages. External Postgres, Kafka, S3 and their data stay. `down` is its old name |

Flags: `--config <file>` (default: `config/local.env`), `--verbose`, `--no-color`.

Exit codes: `0` success, `2` wrong call or configuration, `10` unsuitable machine, `11` a dependency is not installed or its checksum does not match, `12` the cluster did not start, `13` a release was not deployed, `14` an external storage is unreachable, `15` checks failed, `16` cancelled, `17` another run is changing the installation, `18` the external cluster does not fit. A missing parameter does not stop at the first one: code `2` names them all.

`install` and `uninstall` end stdout with one line of JSON, on success and on failure:

```json
{"status":"ok","command":"install","code":0,"durationSeconds":412,"installerVersion":"v0.4.0","updated":[],"failed":[],"skipped":[],"diagnostics":null}
```

The configuration file is `--config`, else `$INSTALLER_CONFIG`, else `/etc/greenongrey/installer.env` if it exists, else `config/local.env`.

**Machine reboots.** `install` installs the systemd unit `greenongrey-stand`. At boot it starts the minikube profile (its container has no restart policy) and waits for the pods. Components come back on their own, since their objects and volumes live in the profile. At shutdown the unit stops the cluster cleanly. See the outcome with `journalctl -u greenongrey-stand`. The unit `hammurapi-ingress-forward` restores port forwarding for public access. To turn autostart off, set `STAND_AUTOSTART=false` and run `install`. `uninstall` removes it and the forwarding unit.

**Old images.** minikube turns off image garbage collection in kubelet, so old tags of Nabu and Hammurapi pile up on the node's disk. `install` and the unit `greenongrey-stand` turn it back on in the kubelet configuration after every cluster start. When image disk usage goes above `IMAGE_GC_HIGH` % (85), unused images are removed down to `IMAGE_GC_LOW` % (80), and an unused image older than `IMAGE_GC_MAX_AGE` (`336h`, 14 days) is removed in any case. Images of running pods stay, including those preloaded by DaemonSets. Kubelet restarts only if the setting changed, and pods keep running.

The log of each `install` is `logs/<time>/run.log`. On failure `diagnostics/` sits next to it, with events, `describe` of failing pods and `helm status` of releases.

## Checks

At the end of `install` and in `status`, these are checked:

- all pods in `storages` and `observability` (if it is on) are ready;
- Grafana and both data sources answer;
- all metric scrape jobs are active (`up == 0` is empty);
- a test log line reaches VictoriaLogs with the fields namespace, pod, container, node;
- storages accept connections with the `*-conn` secrets: `select 1` in Postgres, writing and reading a message in Kafka, writing, reading and deleting an object in S3;
- every container has requests and limits, and total memory requests are at most two thirds of the node memory.

If something fails, the command exits with code 15 and says what failed.

## Connecting applications

Consumers use only stable addresses and secrets in the namespace `storages`, the same for built-in and external storages:

| Secret | Keys |
|---|---|
| `postgres-conn` | `host`, `port`, `database`, `username`, `password`, `sslmode`, `uri` |
| `kafka-conn` | `bootstrap_servers`, `security_protocol` (`PLAINTEXT` / `SASL_SSL`), `sasl_mechanism`, `username`, `password` |
| `s3-conn` | `endpoint`, `region`, `bucket`, `access_key`, `secret_key`, `path_style` |

Passwords of built-in storages are generated on the first `install` and kept only in Kubernetes secrets, never in the repository, values files or logs.

## Configuration

Overrides go in `config/local.env` (ignored by git), with an example in [`config/local.env.example`](config/local.env.example). Priority: `config/defaults.env` → `config/local.env` → environment variables → flags.

The main settings are minikube resources (`MK_CPUS`, `MK_MEMORY`, `MK_DISK`, applied when the profile is created), retention (`VM_RETENTION`, `VL_RETENTION`), volume sizes and storage modes.

### An existing cluster

`INSTALL_TARGET=external` with `KUBE_CONTEXT` installs into an existing cluster. The machine does not change: no packages, no systemd units, no minikube. It needs `kubectl`, `helm` and `jq`.

Before anything changes, `install` checks the cluster and reports all reasons together with code 18: Kubernetes from 1.35 (a version newer than the tested 1.37 gives only a warning), `kubectl` within one minor version of the server, cluster-admin rights and a default `StorageClass` when something is built in, the `INGRESS_CLASS` and `ACME_ISSUER` of an external ingress, and a real test of `NetworkPolicy` in both directions, on which the isolation of Nabu sandboxes rests. The test uses a temporary namespace `installer-preflight`.

`PUBLIC_BASE_DOMAIN` is required with public access. With the built-in ingress the cluster needs a provider of `LoadBalancer` services. On a new cluster the address appears only during `install`, so the first run stops at the certificate: point `*.<domain>` to the printed address and run `install` again. `uninstall` removes the releases and the namespaces the installer and `bin/*-deploy` labelled with `app.kubernetes.io/part-of` (`installer`, `nabu`, `hammurapi`, `landing`), and the `ClusterIssuer`s of the built-in ingress; CRDs stay. A namespace that existed before the installer, or that an older tag created, has no label: `uninstall` names it and leaves it. A default `StorageClass` is required, as there is no option to choose another one yet.

### Ingress

`INGRESS_MODE=internal` (the default) installs Traefik and cert-manager, and MetalLB and port forwarding on minikube.

`INGRESS_MODE=external` installs none of them, and uses what the cluster has. Set `INGRESS_CLASS`, `ACME_ISSUER` (a `ClusterIssuer` of cert-manager) and `PUBLIC_BASE_DOMAIN`. Each Ingress gets a certificate of its own in its namespace. Switching an existing stand to this mode does not remove its Traefik and cert-manager. Product Ingresses move on their next release, so release each product after switching. Set these keys in the config file: the keys passed from GitHub reach only `install`, not `status`. The site (`bin/landing-deploy`) needs the built-in Traefik.

### Observability

`OBSERVABILITY=false` installs no VictoriaMetrics, VictoriaLogs, collectors or Grafana: `install` removes them if they are installed. The volumes of metrics and logs stay, the data of Grafana is deleted, and the checks of Grafana, metrics and logs are skipped.

### External (managed) storages

Set `POSTGRES_MODE`, `KAFKA_MODE` or `S3_MODE` to `external`, separately for each storage. The built-in storage is then not deployed, the service `postgres`/`kafka`/`s3` points to the external host (`ExternalName` for a DNS name, a service with an `EndpointSlice` for an IP), and the `*-conn` secret is filled from the configuration.

Before the deploy, the Job `external-check` checks them from the cluster, and a failure stops `install` with code 14 and deploys no storages. Postgres needs the `vector` extension, and its owner needs `CREATEROLE` and `CREATEDB` (without `CREATEDB`, create the database of Nabu in advance). Kafka needs an answer to a metadata request. S3 needs the buckets `S3_BUCKET` and `S3_BUCKET_NABU` created in advance: the check writes, reads and deletes an object `.installer-check/<id>` in each.

Passwords and keys go only through files (`POSTGRES_PASSWORD_FILE=/secure/pg-password`) or environment variables. A password written directly in `local.env` stops the script with code 2.

For an external Kafka, the write and read check uses the topic `installer-probe`. Create it in advance if automatic topic creation is off. With `OAUTHBEARER` the probe checks only the TCP connection, because the application obtains the token itself.

An example for Google Cloud (Cloud SQL, Managed Service for Apache Kafka, Cloud Storage) is in [docs/gcp.md](docs/gcp.md).

## Products

`PRODUCTS=nabu` (the default) rolls out Nabu after the stand passes its checks, through the same `bin/nabu-deploy` that the CI of Nabu runs, at the versions of `config/versions.env` (`NABU_CORE_VERSION`, `NABU_WEB_VERSION`, `NABU_CHART_VERSION`). An empty `PRODUCTS` installs the stand only. Hammurapi follows in a later release.

Nabu needs `PUBLIC_ACCESS=true`, `AUTH_PROVIDER` and `BOOTSTRAP_ADMINS`:

- `github`: an OAuth App with the callback `https://nabu-api.<domain>/auth/callback`, `NABU_GITHUB_CLIENT_ID` and the secret `NABU_GITHUB_CLIENT_SECRET`; `GITHUB_ALLOWED_ORG` limits sign-in to an organization;
- `oidc`: `OIDC_ISSUER`, `OIDC_CLIENT_ID` and the secret `OIDC_CLIENT_SECRET`.

`BOOTSTRAP_LLM_API_KEY` is optional. Without it, add a model connection in the admin area of Nabu. Secrets come from the environment or `<key>_FILE`, never from the config file. The first `install` keeps them in the secret `installer/product-inputs`, so a later run needs them only to change them. `SECRETS_KEY` of Nabu is generated once and never changes on a rollout.

A component deployed by its own CI, with no record in the ConfigMap `installer/installer-products`, is left alone and listed in `skipped` of the JSON result. This is how production works: its products roll out from their repositories, and its `local.env` sets `PRODUCTS=` (empty).

## MCP servers

Optional MCP servers for Nabu agents (`FTR.NAB.CMN-0006`). Each one is enabled by its own option in `config/local.env`, and all are off by default. The chart, images and server descriptions are released by the repository [mcps](https://github.com/GreenOnGrey/mcps), and `MCP_CHART_VERSION` in `config/versions.env` pins the version.

Servers are installed by the release `mcp-servers` in the namespace `mcp` and are available only to the Nabu `api` (through network policies, enforced by the stand's kindnet). Nothing is published outside.

| Option | Server | Memory (request / limit) | Image, disk |
|---|---|---|---|
| `MCP_DOCLING=true` | Document conversion: `docling-serve` (CPU, OCR `ru`, `en`) and `docling-mcp` | ~1.5 / 5 GiB | ~4.4 GB |
| `MCP_SEARCH=true` | Web search: SearXNG and `mcp-searxng` | ~0.4 / 0.8 GiB | ~0.3 GB |
| `MCP_YANDEX_MAIL=true` | Read-only Yandex Mail: our own server `imap-mcp` | ~0.06 / 0.25 GiB | ~0.1 GB |
| `MCP_DOCGEN=true` | Creating, editing and converting documents (`FTR.NAB.CHAT-0003`): our own server `docgen-mcp` and `doc-convert` (Gotenberg, which is LibreOffice and Chromium without network, and the `legacy` sidecar); it also turns on the DOCX/XLSX/PPTX preview in Nabu | ~0.9 / 4 GiB | ~2.5 GB |

**Disabling a server.** `install` stores the MCP settings in the ConfigMap `installer/installer-config`, so a later `install` without them keeps the servers. Removing an option from the file does not turn a server off. Set `MCP_<NAME>=false` explicitly, and the next `install` removes the server.

Before the deploy, `install` checks the memory budget (two thirds of the node memory, like the `resources` check). If the servers do not fit, it exits with code 2 and says which `MK_MEMORY` is needed. The minikube profile with new memory is created anew (`uninstall`, then `install`). With document conversion on the default stand (12 GB), `MK_MEMORY=16g` is recommended.

Other parameters: `MCP_DOCLING_MAX_MB` is the document size limit of `docling-serve`, and `MCP_SEARCH_ENGINES` lists the SearXNG engines. Access keys are generated on the first `install` and kept in secrets of the namespace `mcp`. With `MCP_DOCGEN=true`, `install` creates the secret `nabu-docs-preview` in the namespace `nabu` (addresses and keys of `doc-convert` and `docgen`) and restarts the Nabu `api` if the secret changed. Without it the office file preview is off.

**Adding to the Nabu catalog.** `./installer creds` prints addresses and keys. In the Nabu admin area → Catalog → MCP server:

- **Documents**: address `http://docling-mcp.mcp.svc:8080/mcp`, platform, header `Authorization: Bearer <key>`. After the check, allow `convert_document_into_docling_document`, `export_docling_document_to_markdown`, `get_overview_of_document_anchors`, `search_for_text_in_document_anchors`, `get_text_of_document_item_at_anchor`, and mark the conversion argument `source` as a space file. Do not allow the other tools (listing and changing the cache, working with the server's disk).
- **Documents: creation**: `http://docgen.mcp.svc:8000/mcp`, platform, `Authorization: Bearer <key>`. After the check, allow all six tools and mark the arguments (`creds` prints them as a ready list):

  | Tool | What it does | Space file | Result path |
  |---|---|---|---|
  | `render_document` | Markdown → DOCX, PDF or PPTX; styled after a sample DOCX | `reference`, `images` (list) | `dest` |
  | `render_spreadsheet` | XLSX from a description of sheets: types, formulas, frozen panes, charts | `template` | `dest` |
  | `fill_template` | Fills a DOCX or XLSX template with data (`{{ … }}`, loops `{%tr … %}`) | `template` | `dest` |
  | `edit_document` | Edits DOCX and PPTX (replaces text and keeps the styling) and XLSX (cells, rows, sheets) | `source` | `dest` |
  | `convert` | DOCX/XLSX/PPTX → PDF, DOC/XLS/PPT → OOXML, HTML or a `.zip` with `index.html` → PDF | `source` | `dest` |
  | `pdf_tools` | PDF: merging, splitting into parts (`.zip`), rotating and extracting pages | `sources` (list) | `dest` |

  The file limit is 25 MB and the result limit is 50 MB. Mark all six tools as writing only to the space: in mail threads they run without a confirmation (overwriting a file asks for one).
- **Web search**: `http://search.mcp.svc:3000/mcp`, platform, `Authorization: Bearer <key>`.
- **Yandex Mail**: `http://yandex-mail.mcp.svc:8000/mcp`, personal, OAuth: authorize `https://oauth.yandex.ru/authorize`, token `https://oauth.yandex.ru/token`, the ClientID and Client secret of the Yandex app, scopes `mail:imap_ro login:email`. All tools of this server only read. The entry is checked with the administrator's personal access, so connect it under Connections first. To make Yandex Mail a source of the communications memory, in the Nabu admin area → Communications memory, choose the adapter `mail` for the entry and turn on Source. The entry must allow `list_folders`, `search_messages` and `read_thread`. The `mail` adapter is common for IMAP mail: another provider with OAuth for IMAP is another deployment of `imap-mcp` with its own `IMAP_HOST`, `USERINFO_*` and `WEB_LINK`.

**The Yandex OAuth app for Yandex Mail.** At [oauth.yandex.ru](https://oauth.yandex.ru), create an app of the type **For user authorization**. Do not use the type for API access or debugging: its Redirect URI is always `https://oauth.yandex.ru/verification_code` and cannot change, so the code shows on the Yandex page and never reaches Nabu. The app type cannot change after creation. The platform is Web services, and the Redirect URI is the OAuth callback of the entry from the Nabu catalog form (`https://<Nabu api>/api/v1/oauth/callback/<entry id>`). For data access, choose access to the email address (`login:email`) and, under other permissions, reading mail over IMAP (`mail:imap_ro`). With `mail:imap_ro`, Yandex itself forbids changing the mailbox. The server also opens folders read-only and does not mark messages as read. IMAP access to the mail must be on:

- *in the mailbox* (personal and in Yandex 360): the user opens the Yandex Mail settings, section Mail clients, block on allowing access to the mailbox through mail clients, and turns on access from the server imap.yandex.ru over IMAP and app passwords and OAuth tokens;
- *in a Yandex 360 organization*: an administrator can forbid employees mail clients or third-party apps through security policies at [admin.yandex.ru](https://admin.yandex.ru), and then must allow them (or the Nabu app). Item names depend on the plan and the console version, so check the Yandex 360 for Business help.

While access is off, the tools answer with an error saying what to turn on.

## Rollout to production

Production is a stand in Google Cloud. The workflow [`deploy-prod`](.github/workflows/deploy-prod.yml) rolls out a release tag:

- it runs on a push of a tag `vX.Y.Z`. A manual run from a tag repeats a rollout or returns to an earlier version (there is no automatic rollback), and `production` accepts only tags, so choose the tag under **Use workflow from**;
- it hands the production machine an export of the tag (`git archive`) over the same SSH, unpacks it into `/opt/installer/releases/<tag>` and runs `up` (the old name of `install`, which older tags know too, for a rollback). After a success `current` points to that tag, and the last 5 exports are kept. The production machine needs no access to GitHub, because deploy keys are forbidden by the organization's policy;
- `/opt/installer/local.env` and secret files stay on the machine and are not passed through the workflow. The exceptions are public access, Grafana sign-in through GitHub and MCP servers (below): their parameters reach `install` through the stdin of the SSH session and are not written to disk. Logs of all runs are in `/opt/installer/logs`;
- rollouts run one at a time (`concurrency`), and `/var/lock/installer.lock` blocks a parallel `install` on the machine (code 17);
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

## Hammurapi: public access and rollout

With `PUBLIC_ACCESS=true`, the stand publishes `web.`, `api.` and `grafana.<base domain>` over HTTPS (MetalLB, Traefik, Let's Encrypt certificates, with the domain `<IP>.sslip.io` by default). Organization members sign in to Grafana through GitHub. `hammurapi-core` and `hammurapi-web` roll out to the stand through their own pipelines, using the reusable workflow `deploy-component.yml` (in the public repository `hammurapi`) and the script `bin/hammurapi-deploy`. The charts `charts/hammurapi-core` and `charts/hammurapi-web` are published by a release tag `vX.Y.Z` with the version `X.Y.Z`.

The firewall, the OAuth app for Grafana, the GitHub App, organization secrets, first install and rollout codes are described in [docs/hammurapi.md](docs/hammurapi.md).

## Development

```text
installer                 entry point: install | status | creds | uninstall
lib/                      common, host, prereqs, cluster, secrets, state, deploy, external, checks, public, mcp
config/                   versions.env (versions), defaults.env, local.env.example
values/                   chart values; values/scrape/ holds vmagent scrape jobs
charts/hammurapi-storages CRs of Kafka and Postgres, stable services postgres, kafka, s3
charts/hammurapi-dashboards ConfigMaps of dashboards
dashboards/               dashboard JSON, normalize.sh, README with sources
tests/unit/               bats: script functions with external commands stubbed
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
