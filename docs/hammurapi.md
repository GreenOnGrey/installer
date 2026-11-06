# Hammurapi on the stand: public access, build and rollout

Specification: `FTR.HMR.INFRA-0002`. The stand of `FTR.HMR.INFRA-0001` publishes web, API and Grafana over HTTPS, and `hammurapi-core` and `hammurapi-web` are released and rolled out to it by their own pipelines, from a tag to a running version, with no manual steps on the server.

```text
tag vX.Y.Z in hammurapi-core / hammurapi-web
  lint ∥ test → build (ghcr.io, SBOM, provenance, cosign signature) → scan (Trivy)
  → deploy-component.yml (hammurapi) → hammurapi-deploy on the machine → checks through the domains

browser, GitHub ──HTTPS──▶ :80/:443 of the machine ──iptables──▶ MetalLB ─▶ Traefik
  hammurapi.<domain>     → web
  hammurapi-api.<domain> → api: /api/, /admin/api/, /hooks/, /mcp/nabu
  nabu.<domain>          → Nabu web,  nabu-api.<domain> → Nabu api and relay (repository nabu)
  grafana.<domain>       → Grafana (sign-in through GitHub for organization members)
```

## 1. Public access of the stand

### 1.1 Google Cloud firewall

Only TCP 80 and 443 are needed from outside. SSH goes through IAP or from trusted addresses.

```sh
gcloud compute firewall-rules create hammurapi-web --network "$VPC" \
  --direction INGRESS --action allow --rules tcp:80,tcp:443 \
  --target-tags hammurapi-public --source-ranges 0.0.0.0/0
gcloud compute instances add-tags hammurapi --zone "$ZONE" --tags hammurapi-public
```

Service ports (`:9100`, `:8081`) stay closed: Traefik routes only the listed domains and paths.

### 1.2 GitHub OAuth app for Grafana

1. Organization settings → Developer settings → OAuth Apps → New OAuth App:
   - Homepage URL: `https://grafana.<base domain>`;
   - Authorization callback URL: `https://grafana.<base domain>/login/github`.
2. Generate a client secret. For production, set the variable `GRAFANA_GITHUB_CLIENT_ID` and the secret `GRAFANA_GITHUB_CLIENT_SECRET` in `installer` (the environment `production` or the repository level), and optionally the variable `GRAFANA_GITHUB_ORG` (default: `GreenOnGrey`). `deploy-prod` passes them to `up` through the stdin of the SSH session: they reach neither the machine's disk nor argv, and Grafana gets them through the Kubernetes secret `grafana-github-oauth`. They apply with the next tag rollout. A manual `up` on the machine takes them from `local.env`: the client ID as a line, the secret as a file (`GRAFANA_GITHUB_CLIENT_SECRET_FILE`, mode `600`). Without them such an `up` turns GitHub sign-in off until the next rollout.
3. Organization settings → Third-party access → OAuth app policy: allow the app access to the organization. Otherwise Grafana does not see the membership and rejects the sign-in.

### 1.3 Stand configuration

In production, public access parameters are GitHub variables of the repository `installer` (the environment `production` or the repository level), the same as Grafana sign-in (§1.2). `deploy-prod` passes them to `up` through stdin, and values from GitHub win over `local.env`.

| Variable | Value |
|---|---|
| `PUBLIC_ACCESS` | `true` |
| `ACME_EMAIL` | address for Let's Encrypt notices (required with `PUBLIC_ACCESS=true` and `INGRESS_MODE=internal`), kept as a secret in production |
| `ACME_ISSUER` | `letsencrypt` (default) or `letsencrypt-staging` for trials; with `INGRESS_MODE=external`, a `ClusterIssuer` of the cluster |
| `INGRESS_MODE`, `INGRESS_CLASS` | `internal` (default) or `external` with the ingress class of the cluster: see the README |
| `PUBLIC_BASE_DOMAIN` | empty means `<external IP with dashes>.sslip.io` |
| `PUBLIC_IP` | empty means it is detected automatically |
| `HAMMURAPI_WEB_HOST`, `HAMMURAPI_API_HOST` | `hammurapi`, `hammurapi-api`: subdomains of the Hammurapi site and API (`hammurapi.<domain>`, `hammurapi-api.<domain>`); the rollout passes them to the charts |
| `PUBLIC_EXTRA_HOSTS` | `nabu nabu-api web` on production: the subdomains of Nabu (FTR.NAB.CMN-0001) and of the GreenOnGrey site (FTR.LND.WEB-0001) in the shared certificate; the default has no `web` |

A manual `up` on the machine does not get these values and takes them from `local.env`. If they are not there, such an `up` skips the step `public`, and Traefik and the certificate already deployed stay.

`/opt/installer/local.env` (or `config/local.env` of a working copy) for a manual `up`:

```bash
PUBLIC_ACCESS=true
ACME_EMAIL=ops@example.org
# PUBLIC_BASE_DOMAIN=            # empty means <external IP with dashes>.sslip.io
# ACME_ISSUER=letsencrypt-staging  # for trials: spends no Let's Encrypt limits
# Grafana sign-in through GitHub: from GitHub in production (§1.2), here for a manual up.
# GRAFANA_GITHUB_CLIENT_ID=Ov23li…
# GRAFANA_GITHUB_CLIENT_SECRET_FILE=/secure/grafana-github-secret
# GRAFANA_GITHUB_ORG=GreenOnGrey
```

The next `up` (or a rollout of an `installer` tag) adds the step `public`:

1. MetalLB (a minikube addon) with the pool `<minikube subnet>.200–.209`.
2. cert-manager and the `ClusterIssuer`s `letsencrypt` and `letsencrypt-staging` (HTTP-01 through Traefik).
3. Traefik in the namespace `ingress`: a `LoadBalancer` service, HTTP → HTTPS, the default certificate `greenongrey-public`.
4. One certificate for `web.`, `api.`, `grafana.<domain>`: issued once and renewed by cert-manager.
5. Ingress of Grafana and sign-in through GitHub: organization members get the role Editor and others cannot sign in. The local administrator (`creds`) stays for emergency access.
6. The systemd unit `greenongrey-ingress-forward`: iptables rules forward 80/443 of the external interface to the Traefik address. The rules come back after a machine reboot and a Docker restart and create no duplicates.

`up` checks that `https://grafana.<domain>` answers with a certificate from `ACME_ISSUER` and that HTTP redirects to HTTPS. The summary and `status --json` show the domain and the Traefik address.

**Domain.** The default is the free `<IP>.sslip.io`, with nothing to register. If Let's Encrypt limits for `sslip.io` are exhausted, create a DuckDNS subdomain (`<name>.duckdns.org` with an A record for the external IP) and set `PUBLIC_BASE_DOMAIN`. No code changes.

The SSH tunnel to Grafana from `FTR.HMR.INFRA-0001` stays as a fallback.

## 2. The Hammurapi GitHub App and the specifications repository

1. Create a specifications repository, such as `GreenOnGrey/hammurapi-spec`, and copy `rules/` from the repository `hammurapi` into it.
2. Organization settings → Developer settings → GitHub Apps → New GitHub App:
   - Callback URL: `https://hammurapi-api.<base domain>/api/v1/auth/callback`;
   - Expire user authorization tokens: on;
   - Webhook: on, with any address, since the core rollout writes `https://hammurapi-api.<domain>/hooks/v1/git` and the secret itself;
   - Repository permissions: Contents — Read and write, Pull requests — Read and write, Issues — Read and write, Metadata — Read, Actions — Read and write;
   - Subscribe to events: Push, Pull request, Pull request review, Pull request review comment, Issue comment.
3. Generate a private key and a client secret. Install the app on `hammurapi-spec` and on the service repositories.

## 3. Configuration in GitHub

All Hammurapi configuration lives in secrets and variables of the **organization**, available only to `hammurapi-core` and `hammurapi-web` (Organization settings → Secrets and variables → Actions → Repository access: selected). It is not kept in git.

**Variables:**

| Name | Value |
|---|---|
| `DEPLOY_TRANSPORT` | `ssh` or `gcp-iap` |
| `PROD_HOST`, `PROD_USER` | machine address and rollout user (`ssh`) |
| `GCP_PROJECT`, `GCP_ZONE`, `GCP_INSTANCE`, `GCP_WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT` | for `gcp-iap` |
| `HAMMURAPI_GITHUB_APP_ID`, `HAMMURAPI_GITHUB_CLIENT_ID` | GitHub App |
| `HAMMURAPI_SPEC_REPO` | `GreenOnGrey/hammurapi-spec` |
| `HAMMURAPI_BOOTSTRAP_ADMINS` | login of the stand's owner, the first global administrator |
| `AUTO_DEPLOY` | `false`: Hammurapi drives the rollout by tag (R23); build and scan continue |

**Secrets:**

| Name | Value |
|---|---|
| `PROD_SSH_KEY`, `PROD_KNOWN_HOSTS` | SSH access (`ssh-keyscan -t ed25519 <address>`) |
| `HAMMURAPI_GITHUB_APP_PRIVATE_KEY` | private key of the GitHub App (the whole PEM) |
| `HAMMURAPI_GITHUB_CLIENT_SECRET`, `HAMMURAPI_WEBHOOK_SECRET` | GitHub App |
| `HAMMURAPI_TOKEN_ENCRYPTION_KEY` | `openssl rand -base64 32`; it must not change without `allow_key_rotation` |
| `HAMMURAPI_BOOTSTRAP_DEEPSEEK_API_KEY` | optional: a DeepSeek key for the first LLM connection; further connections and models are in Administration → Agent (FTR.HMR.CMN-0004) |
| `HAMMURAPI_GHCR_PULL_TOKEN` | a classic PAT with `read:packages`: images and charts on the machine |
| `HAMMURAPI_DEPLOY_CALLBACK_SECRET` | secret of the rollout webhook of the environment `production` in Hammurapi (Administration → Deploy) |

Each of the two repositories has the environment `production` (Settings → Environments) with rollout rules: allowed tags `v*.*.*`, and reviewers if you like. It holds no values of its own.

The reusable workflow `deploy-component.yml` lives in the public repository `hammurapi`, and `hammurapi-core` and `hammurapi-web` call it. No access to it needs configuring.

## 4. Releases and rollout

1. A release tag `vX.Y.Z` in `installer` runs `deploy-prod.yml`. First the charts `oci://ghcr.io/greenongrey/charts/{hammurapi,nabu}-{core,web}:X.Y.Z` are published (the chart version equals the stand's version). Then, only on success, the tag rolls out to the stand with `bin/hammurapi-deploy` and `bin/nabu-deploy`, and the machine takes the scripts from `/opt/installer/current`. A manual run from a tag (a repeat or a rollback) does not overwrite published chart versions.
2. A tag `vX.Y.Z` in `hammurapi`, if `deploy-component.yml` changed.
3. In `hammurapi-core` and `hammurapi-web`, set `DEPLOY_WORKFLOW_REF` (the `hammurapi` tag from step 2) and `CHART_VERSION` (step 1) in `deploy/versions.env`, and run `deploy/sync-ref.sh`.
4. A tag `vX.Y.Z` in `hammurapi-core`, then in `hammurapi-web`.

Nabu (`FTR.NAB.CMN-0001`) rolls out the same way. A tag of `nabu` is only a version of `deploy-component.yml` and puts nothing on the machine. In `nabu-core` and `nabu-web`, `deploy/versions.env` has `DEPLOY_WORKFLOW_REF` (the `nabu` tag) and `CHART_VERSION` (the stand's version). Then come tags of `nabu-core`, followed by `nabu-web`. Variables and secrets are in `nabu/docs/deployment.md`.

The GreenOnGrey site (`FTR.LND.WEB-0001`) rolls out similarly but more simply. A stand release publishes the chart `landing`, and the machine runs `bin/landing-deploy <tag> <chart version>`: namespace `landing`, host `web.<domain>`, no storages or secrets. The rollout workflow is in the repository `landing` itself (`release.yml`), and its `deploy/versions.env` has `CHART_VERSION` (the stand's version). The site needs the same machine access and registry read token as other components.

The site's own domain is set not on the stand but in the repository `landing` (the variable `SITE_DOMAIN`), and the workflow passes it to the stdin of `landing-deploy`. The chart then adds an Ingress for `<domain>` and `www.<domain>`, a separate Let's Encrypt certificate (`landing-domain` in the namespace `landing`, from the stand's issuer) and a redirect from `www.`. The address `web.<stand domain>` stays. Before any change in the cluster the script checks that both names point to the stand's public address, and afterwards it waits for the certificate. The registrar needs two A records: `@` and `www`.

| What | How |
|---|---|
| Rollout by tag | a tag push: lint ∥ test → build → scan → deploy |
| Manual rollout or rollback (R9) | Actions → release → Run workflow, `ref` = the tag; no rebuild, the signature is verified |
| Run by the contract of `FTR.HMR.CMN-0002` (R22) | Hammurapi calls `workflow_dispatch` with `service`, `ref`, `environment`, `run_id`, `callback_url`; webhooks `started` and `success`/`failure` |
| Turning off automatic rollout (R23) | the variable `AUTO_DEPLOY=false` |

In Hammurapi (Administration → Deploy → production), for rolling out itself: type `github-actions`, workflow `release.yml`, `ref` is `{ref}`, parameters `service={service}`, `ref={ref}`, `environment={environment}`, `run_id={run_id}`, `callback_url={callback_url}`.

**First install** is the same core rollout. If there is no release, `hammurapi-deploy` creates the namespace `hammurapi`, the configuration secrets and `ghcr-pull`, copies `*-conn` from `storages`, installs the chart (migrations run as a hook before `api` and `worker`) and configures the GitHub App: the webhook address and secret and a check of access to `hammurapi-spec`. Web does not roll out before core and answers "roll out hammurapi-core first".

**Agent (FTR.HMR.CMN-0007).** The core chart has no agent or runner: code tasks run in Nabu sandboxes, and the worker's MCP (`worker-mcp:8083`) is open only to the Nabu namespace.

**Checks after a rollout** run from a GitHub runner through the public domains: `/api/v1/config`, a signed `ping` to `/hooks/v1/git` (202), a closed `/metrics`, a redirect from HTTP to HTTPS, and for web the page, `config.json` with the API address, and CORS. On a failure Helm (`--atomic`) restores the previous revision, and diagnostics are attached to the run.

### Codes of `hammurapi-deploy`

| Code | Reason |
|---|---|
| 17 | a rollout of this component is running |
| 20 | the stand is not ready or public access is off |
| 21 | web without core: "roll out hammurapi-core first" |
| 22 | namespace |
| 23 | secrets and configuration |
| 24 | the token encryption key changed (run with `allow_key_rotation` to do it on purpose) |
| 25 | the Helm release was not deployed, the previous revision is restored |
| 26 | GitHub App: no access to `hammurapi-spec` (with an installation link), missing permissions, or not subscribed to events |
| 27 | pods are not ready |

## 5. Implementation decisions (recorded in FTR.HMR.INFRA-0002 v1.1)

- **Signature of the result webhook**: HMAC-SHA256 of the body, with the timestamp in the separate header `X-Hammurapi-Timestamp`. This is how `hammurapi-core` verifies it (`/hooks/v1/deploy`). The tech spec of `INFRA-0002` says `timestamp + "." + body`, but Hammurapi would reject a webhook signed that way.
- **Linter of web**: oxlint and `tsc --noEmit` instead of ESLint, since `typescript-eslint` does not support TypeScript 7, which web is built with.
- **External IP** is detected through public services (ipify, ifconfig.me), not cloud metadata: the stand's script does not depend on a cloud (PORT-01). `PUBLIC_IP` sets it explicitly.
- **Registry token** is also required by the web rollout: `hammurapi-deploy` expects `ghcrPullToken` or the secret `ghcr-pull`. The packages are public now, and this requirement goes away with the wizard (`FTR.INFRA.INST-0001`).
