# Reference

Commands, parameters, exit codes and the JSON result of `./installer`. The defaults live in [`config/defaults.env`](../config/defaults.env) and the pinned versions in [`config/versions.env`](../config/versions.env). `tests/unit/docs.bats` checks that every key of `defaults.env` and every exit code appears in this page.

## Commands

| Command | What it does |
|---|---|
| `./installer` | The wizard. It needs a terminal: without one, code `2` and the help. It writes the config file, then runs `install --config` with it ([quickstart.md](quickstart.md)) |
| `./installer install [--config <file>]` | Installs and deploys without questions. A repeated run brings the install to the configuration and keeps data and passwords. `up` is a hidden synonym |
| `./installer update [<service>] [--to <version>] [--dry-run] [--yes]` | Brings the install to the versions of this release, or one service to a version of its own ([update.md](update.md)) |
| `./installer status [--json]` | Cluster, releases, pods, deployed version, pins, checks, requested memory |
| `./installer creds [--json]` | Addresses, secret names, usernames and passwords of storages, Grafana and MCP servers |
| `./installer uninstall [--yes]` | Removes what the installer installed. External storages and their data stay. `down` is a hidden synonym |
| `./installer help` | The help |

Services of `update`: `nabu-core`, `nabu-web`, `hammurapi-core`, `hammurapi-web`, `mcp-servers`.

| Flag | Commands | Meaning |
|---|---|---|
| `--config <file>` | all | The config file. Without it: `$INSTALLER_CONFIG`, then `/etc/greenongrey/installer.env` if it exists, then `config/local.env` |
| `--yes` | `update`, `uninstall` | No confirmation; required without a terminal |
| `--dry-run` | `update` | Shows the plan, changes nothing |
| `--to <version>` | `update <service>` | Pins the service: `vX.Y.Z`, or `X.Y.Z` for `mcp-servers` |
| `--json` | `status`, `creds` | One JSON document |
| `--verbose` | all | Prints the commands being run |
| `--no-color` | all | No colors (automatic when the output is not a terminal) |

## Configuration

Priority, lowest first: `config/defaults.env`, the config file, environment variables, flags. [`config/local.env.example`](../config/local.env.example) is an example of a config file. Secrets never go in the config file: a secret written there stops the run with code `2`. Give a secret as an environment variable or as `<KEY>_FILE`, the path of a file that holds it. `install` keeps secrets in the cluster, so later runs need them only to change them ([security.md](security.md)).

### Target and machine

| Key | Default | Meaning |
|---|---|---|
| `INSTALL_TARGET` | `minikube` | `minikube`: this machine. `external`: an existing cluster ([external-kubernetes.md](external-kubernetes.md)) |
| `KUBE_CONTEXT` | empty | The kubeconfig context of `external`; required there. Empty on minikube: the context of the profile |
| `MK_PROFILE` | `greenongrey` | The minikube profile |
| `MK_CPUS` | `3` | CPUs of the profile, applied when it is created |
| `MK_MEMORY` | `12g` | Memory of the profile (`g` or `m`), applied when it is created |
| `MK_DISK` | `60g` | Disk of the profile, applied when it is created |
| `HOST_MIN_CPUS` | `4` | Machine minimum checked before installing |
| `HOST_MIN_MEMORY_GB` | `15` | Machine minimum, GB |
| `HOST_MIN_DISK_GB` | `80` | Free disk minimum, GB |
| `UNIT_PREFIX` | `greenongrey` | Prefix of the systemd units `<prefix>-stand` and `<prefix>-ingress-forward` |
| `STAND_AUTOSTART` | `true` | The stand starts after a reboot and stops cleanly at shutdown ([minikube.md](minikube.md)) |
| `IMAGE_GC_HIGH` | `85` | Image disk usage, %, above which kubelet removes unused images |
| `IMAGE_GC_LOW` | `80` | Usage, %, it removes them down to |
| `IMAGE_GC_MAX_AGE` | `336h` | An unused image older than this is removed in any case |
| `REGISTRY_MIRRORS` | empty | Pull-through mirrors of image registries for minikube, space-separated `<registry>=<URL>`, such as `docker.io=https://mirror.example.com` ([minikube.md](minikube.md#registry-mirrors)) |
| `LOCK_FILE` | `/var/lock/installer.lock` | Blocks a second run on the machine (code `17`) |
| `HELM_TIMEOUT` | `10m` | Timeout of a release |
| `CHECK_TIMEOUT` | `5m` | Timeout of the checks |

### Namespaces, retention, volumes

| Key | Default | Meaning |
|---|---|---|
| `NS_STORAGES` | `storages` | Storages and their `*-conn` secrets |
| `NS_OBSERVABILITY` | `observability` | Metrics, logs, Grafana |
| `NS_STATE` | `installer` | State of the install: version, pins, products, MCP settings |
| `NS_MCP` | `mcp` | MCP servers |
| `OBSERVABILITY` | `true` | `false` installs no metrics, logs or Grafana and removes them |
| `VM_RETENTION` | `7d` | Metrics retention |
| `VL_RETENTION` | `3d` | Logs retention |
| `VM_STORAGE` | `10Gi` | Volume of metrics |
| `VL_STORAGE` | `10Gi` | Volume of logs |
| `GRAFANA_STORAGE` | `1Gi` | Volume of Grafana |
| `GRAFANA_LOCAL_PORT` | `3000` | Local port of the Grafana tunnel in hints |
| `KAFKA_STORAGE` | `10Gi` | Volume of the built-in Kafka |
| `PG_STORAGE` | `10Gi` | Volume of the built-in Postgres |
| `S3_STORAGE` | `10Gi` | Volume of the built-in S3 |

### Storages

Built-in or external, each on its own ([resources.md](resources.md)).

| Key | Default | Meaning |
|---|---|---|
| `POSTGRES_MODE` | `internal` | `internal` or `external` |
| `KAFKA_MODE` | `internal` | `internal` or `external` |
| `S3_MODE` | `internal` | `internal` or `external` |
| `PG_DATABASE` | `hammurapi` | Database of the built-in Postgres |
| `PG_USER` | `hammurapi` | Its owner |
| `S3_BUCKET` | `hammurapi` | Bucket of Hammurapi (built-in or external) |
| `S3_BUCKET_NABU` | `nabu` | Bucket of Nabu |
| `S3_REGION` | `us-east-1` | Region |
| `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DATABASE`, `POSTGRES_USER`, `POSTGRES_SSLMODE` | — | External Postgres; all required |
| `POSTGRES_PASSWORD` | secret | External Postgres |
| `KAFKA_BOOTSTRAP`, `KAFKA_SECURITY_PROTOCOL` | — | External Kafka: `host:port,…` and `PLAINTEXT` or `SASL_SSL` |
| `KAFKA_SASL_MECHANISM`, `KAFKA_USERNAME` | — | With `SASL_SSL`: `PLAIN`, `SCRAM-SHA-512` or `OAUTHBEARER`, and the user |
| `KAFKA_PASSWORD` | secret | With `SASL_SSL` |
| `S3_ENDPOINT`, `S3_PATH_STYLE` | — | External S3: the `http(s)://` address and `true` for path-style addresses |
| `S3_ACCESS_KEY`, `S3_SECRET_KEY` | secrets | External S3 |

### Public access and domain

| Key | Default | Meaning |
|---|---|---|
| `PUBLIC_ACCESS` | `false` | `true` publishes the products and Grafana over HTTPS; the products require it |
| `PUBLIC_BASE_DOMAIN` | empty | The domain. Empty on minikube: `<IP>.sslip.io`. Required on `external` |
| `PUBLIC_DNS_CHECK` | `true` | On minikube, each host must resolve to the machine (code `19`); `false` behind a proxy |
| `PUBLIC_IP` | empty | The external address of the machine; empty: detected. With `TLS_TERMINATION=external`, the address of the load balancer, which the DNS check compares the hosts with |
| `HAMMURAPI_WEB_HOST` | `hammurapi` | Host of the site of Hammurapi |
| `HAMMURAPI_API_HOST` | `hammurapi-api` | Host of its API |
| `PUBLIC_EXTRA_HOSTS` | `nabu nabu-api` | Other hosts of the certificate; the wizard sets those of the products |
| `CERT_NAME` | `greenongrey-public` | The shared certificate of the built-in ingress |
| `TLS_TERMINATION` | `ingress` | `ingress`: TLS on the ingress, with certificates of Let's Encrypt or of `ACME_ISSUER`. `external`: a load balancer in front terminates TLS and sends HTTP to port 80; no cert-manager, no certificates ([external-kubernetes.md](external-kubernetes.md#tls-on-a-load-balancer)) |
| `TLS_PROXY_CIDRS` | empty | With `TLS_TERMINATION=external` and the built-in Traefik: addresses or CIDRs of the load balancer, comma-separated; Traefik trusts their `X-Forwarded-*` only |
| `ACME_EMAIL` | empty | Address for Let's Encrypt; required with the built-in ingress and TLS on it |
| `ACME_ISSUER` | `letsencrypt` | `letsencrypt` or `letsencrypt-staging`; with `INGRESS_MODE=external`, a `ClusterIssuer` of the cluster |
| `INGRESS_MODE` | `internal` | `internal`: Traefik and cert-manager (and MetalLB on minikube). `external`: those of the cluster |
| `INGRESS_CLASS` | `traefik` | The ingress class; with `external`, an existing one |
| `METALLB_RANGE` | empty | Address pool of MetalLB on minikube; empty: `.200`–`.209` of the minikube subnet |
| `GRAFANA_GITHUB_CLIENT_ID` | empty | GitHub OAuth app of Grafana sign-in |
| `GRAFANA_GITHUB_CLIENT_SECRET` | secret | Its secret |
| `GRAFANA_GITHUB_ORG` | `GreenOnGrey` | Only its members sign in to Grafana |

### Products

[products.md](products.md) explains each of them.

| Key | Default | Meaning |
|---|---|---|
| `PRODUCTS` | `nabu` | `nabu`, `nabu,hammurapi`, `hammurapi` (with `NABU_MODE=external`), or empty for the stand only |
| `NABU_MODE` | `internal` | `external`: Hammurapi connects to another Nabu |
| `NABU_URL`, `NABU_CLIENT_ID` | empty | That Nabu: the `https://` address of its API and the client of Hammurapi |
| `NABU_CLIENT_SECRET` | secret | The secret of that client |
| `AUTH_PROVIDER` | empty | `github` or `oidc` |
| `BOOTSTRAP_ADMINS` | empty | Logins or e-mails of the first administrators, comma-separated |
| `NABU_GITHUB_CLIENT_ID` | empty | GitHub OAuth app of Nabu |
| `NABU_GITHUB_CLIENT_SECRET` | secret | Its secret |
| `GITHUB_ALLOWED_ORG` | empty | Only members of this organization sign in |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID` | empty | The OIDC client of all products |
| `OIDC_CLIENT_SECRET` | secret | Its secret |
| `OIDC_PROVIDER_NAME` | empty | The name on the sign-in button |
| `DEFAULT_LANGUAGE` | `en` | Language of new users |
| `DEFAULT_TIMEZONE` | `UTC` | Time zone of new users |
| `SPEC_LANGUAGE` | empty | Hammurapi: the language of the specifications, `ru` or `en`; empty — `DEFAULT_LANGUAGE` when it is `ru` or `en`, otherwise `en` |
| `BOOTSTRAP_LLM_API_KEY` | secret, optional | The model key of the first connection of Nabu |
| `HAMMURAPI_GIT_PROVIDER` | `github` | Where the repositories of Hammurapi live: `github` or `gitlab` |
| `HAMMURAPI_GITHUB_APP_ID`, `HAMMURAPI_GITHUB_CLIENT_ID` | empty | The GitHub App of Hammurapi |
| `HAMMURAPI_GITHUB_APP_PRIVATE_KEY` | secret | Its private key; usually `HAMMURAPI_GITHUB_APP_PRIVATE_KEY_FILE` with the `.pem` |
| `HAMMURAPI_GITHUB_CLIENT_SECRET` | secret | Its client secret |
| `HAMMURAPI_GITLAB_URL` | empty | `gitlab`: the address of GitLab; empty — `https://gitlab.com` |
| `HAMMURAPI_GITLAB_CLIENT_ID` | empty | `gitlab`: the OAuth application of Hammurapi in GitLab |
| `HAMMURAPI_GITLAB_CLIENT_SECRET` | secret | Its secret |
| `HAMMURAPI_GITLAB_BOT_TOKEN` | secret | `gitlab`: the token of the bot, scope `api`, a Maintainer of the project of specifications |
| `HAMMURAPI_SPEC_REPO` | empty | The repository of specifications: `owner/name` on GitHub, `group/project` (subgroups too) on GitLab |
| `NABU_WHISPER` | `true` | Speech recognition of Nabu |
| `NABU_WHISPER_MODEL` | `small` | `tiny`, `base`, `small`, `medium`, `large-v3` or `large-v3-turbo` |
| `NABU_SANDBOX_CUSTOM_IMAGES` | `false` | Administrators may create sandbox profiles from custom images |
| `NABU_SANDBOX_IMAGE_PREFIXES` | empty | Allowed prefixes of those images, comma-separated, each ending with `/` |
| `NABU_SANDBOX_PULL_SECRETS` | empty | Registry secrets of the sandbox namespace |

### MCP servers

[mcp.md](mcp.md) has the details.

| Key | Default | Meaning |
|---|---|---|
| `MCP_DOCLING` | `false` | Document conversion |
| `MCP_SEARCH` | `false` | Web search |
| `MCP_YANDEX_MAIL` | `false` | Read-only Yandex Mail |
| `MCP_DOCGEN` | `false` | Creating and converting documents, office file preview |
| `MCP_DOCLING_MAX_MB` | `25` | Largest document of `docling-serve`, MB |
| `MCP_SEARCH_ENGINES` | `duckduckgo,bing,brave,wikipedia,github,stackoverflow,arxiv` | SearXNG engines |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Unexpected error |
| `2` | Wrong call or configuration; all missing parameters are named at once |
| `10` | The machine does not fit |
| `11` | A dependency is not installed or its checksum does not match |
| `12` | The cluster did not start or does not answer |
| `13` | A release was not deployed |
| `14` | An external resource is unreachable or does not fit |
| `15` | Checks failed |
| `16` | Cancelled |
| `17` | Another run is changing the install |
| `18` | The external cluster does not fit |
| `19` | DNS of the domain does not point to the machine |
| `20`–`29` | Codes of `bin/*-deploy`, the rollout of a product |

## JSON result

`install`, `update` and `uninstall` end stdout with one line of JSON on every exit:

```json
{"status":"ok","command":"install","code":0,"durationSeconds":412,"installerVersion":"v0.3.8","updated":[],"failed":[],"skipped":[],"diagnostics":null}
```

| Field | Meaning |
|---|---|
| `status` | `ok` or `failed` |
| `command` | `install`, `update` or `uninstall` |
| `code` | The exit code |
| `durationSeconds` | Duration of the run |
| `installerVersion` | The tag of this installer, or `dev` |
| `updated` | Components rolled out by this run |
| `failed` | Releases and components that failed |
| `skipped` | Components left alone: owned by their own CI, or not reached after a failure |
| `diagnostics` | On failure, the run log; `diagnostics/` sits next to it |

The log of each run is `logs/<time>/run.log` of the installer directory.
