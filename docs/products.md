# Products

`PRODUCTS` chooses what runs on the install:

| `PRODUCTS` | Result |
|---|---|
| `nabu` (the default) | Nabu |
| `nabu,hammurapi` | Nabu and Hammurapi, connected to each other |
| `hammurapi` with `NABU_MODE=external` | Hammurapi, connected to a Nabu that runs elsewhere. Without `NABU_MODE=external`, Nabu is installed too |
| empty | The storages and observability only |

The products roll out after the stand passes its checks. They use the same `bin/nabu-deploy` and `bin/hammurapi-deploy` that the CI of each product runs, at the versions of [`config/versions.env`](../config/versions.env). They need public access (`PUBLIC_ACCESS=true`) for HTTPS and OAuth callbacks. Each product gets its hosts of the domain:

- Nabu: `nabu.` for the site and `nabu-api.` for the API;
- Hammurapi: `hammurapi.` and `hammurapi-api.`.

A component that its own CI has deployed, with no record of the installer in the ConfigMap `installer/installer-products`, is left alone. It is listed in `skipped` of the JSON result.

## Sign-in

`AUTH_PROVIDER` and `BOOTSTRAP_ADMINS` (logins or e-mails of the first administrators, comma-separated) are required. The administrators get their rights at their first sign-in.

- **GitHub** (`AUTH_PROVIDER=github`): create an OAuth App for Nabu under **Settings → Developer settings → OAuth Apps**, with the callback `https://nabu-api.<domain>/auth/callback`. Set `NABU_GITHUB_CLIENT_ID` and the secret `NABU_GITHUB_CLIENT_SECRET`. `GITHUB_ALLOWED_ORG` limits sign-in to the members of an organization. Hammurapi signs people in through its own GitHub App, described below.
- **OpenID Connect** (`AUTH_PROVIDER=oidc`): one client for all products, with the callbacks `https://nabu-api.<domain>/auth/callback` and `https://hammurapi-api.<domain>/api/v1/auth/callback`. Set `OIDC_ISSUER`, `OIDC_CLIENT_ID`, the secret `OIDC_CLIENT_SECRET` and, for the sign-in button, `OIDC_PROVIDER_NAME`.

## Nabu

The model key of the first connection, `BOOTSTRAP_LLM_API_KEY`, is optional. Without it, add a model connection in the admin area of Nabu.

The encryption key of Nabu (`SECRETS_KEY`) is generated once and never changes on a rollout. Speech recognition (`NABU_WHISPER`) and custom sandbox images (`NABU_SANDBOX_*`) are in [reference.md](reference.md#products).

## Hammurapi

`HAMMURAPI_GIT_PROVIDER` says where the repositories of Hammurapi live: `github` (the default, below) or
`gitlab` ([Hammurapi on GitLab](#hammurapi-on-gitlab)).

Hammurapi works on a repository of specifications through its GitHub App. Create one under **Settings → Developer settings → GitHub Apps → New GitHub App** of the organization:

- callback URL: `https://hammurapi-api.<domain>/api/v1/auth/callback`; expire user authorization tokens: on;
- webhook: active, with the URL `https://hammurapi-api.<domain>/hooks/v1/git` and no secret: the rollout of `hammurapi-core` writes the address and the secret into the App itself;
- repository permissions: **Contents**, **Pull requests**, **Issues**, **Actions** and **Workflows**: read and write; **Checks**, **Commit statuses** and **Metadata**: read (**Workflows** lets Hammurapi propose the check of speclint in `.github/workflows/`, FTR.HMR.SPEC-0002);
- events: push, pull request, pull request review, pull request review comment, issue comment, check suite, status; the rollout stops with code 26 without push and pull request;
- install it on the repository of specifications and on the repositories of services: the webhook of the App covers them all.

Set:
- `HAMMURAPI_GITHUB_APP_ID` and `HAMMURAPI_GITHUB_CLIENT_ID`;
- the secrets `HAMMURAPI_GITHUB_CLIENT_SECRET` and `HAMMURAPI_GITHUB_APP_PRIVATE_KEY_FILE`, the path of the downloaded `.pem`;
- `HAMMURAPI_SPEC_REPO` (`owner/name`).

The wizard shows these steps with the addresses of the install and reads the `.pem` itself, without keeping its path. With `AUTH_PROVIDER=github`, people sign in to Hammurapi through this App.

The repository needs the rules of Hammurapi: see [the documentation of Hammurapi](https://github.com/GreenOnGrey/hammurapi/blob/main/docs/git-providers.md).

### Hammurapi on GitLab

With `HAMMURAPI_GIT_PROVIDER=gitlab`, people sign in with OpenID Connect (`AUTH_PROVIDER=oidc`; Keycloak, or GitLab
itself as the issuer), and each links their GitLab account in Hammurapi, so commits and merge requests are theirs.

1. In GitLab, **User settings → Applications** (or those of a group or of the instance): an application with the
   redirect URI `https://hammurapi-api.<domain>/api/v1/auth/git/callback`, confidential, scopes `api` and `read_user`.
2. The bot: a user (e.g. `hammurapi-bot`), or a project or group access token, with the scope `api` and the role
   **Maintainer** of the project of specifications: it merges into the protected default branch at a release.
3. Set:
   - `HAMMURAPI_GITLAB_URL` (empty for `https://gitlab.com`) and `HAMMURAPI_GITLAB_CLIENT_ID`;
   - the secrets `HAMMURAPI_GITLAB_CLIENT_SECRET` and `HAMMURAPI_GITLAB_BOT_TOKEN`;
   - `HAMMURAPI_SPEC_REPO` (`group/project`, subgroups too).

The rollout of `hammurapi-core` checks the token and the role of the bot and adds the webhook of the project of
specifications (pushes, tag pushes, merge requests, comments, pipelines, with the secret `WEBHOOK_SECRET`); a refusal is
code 26. GitLab must be reachable from the machine of the install and from the cluster.

A self-hosted GitLab refuses webhooks to private addresses by default. When `hammurapi-api.<domain>` resolves to
one (a load balancer of the internal network), an administrator of GitLab allows it in **Admin → Settings → Network →
Outbound requests**: *Allow requests to the local network from webhooks and integrations*, or the host in the
allowlist. Otherwise the rollout stops with code 26 on the webhook. If the certificate of GitLab is issued by an
internal CA, the machine of the install must trust it; and GitLab checks the certificate of `hammurapi-api.<domain>`
when it delivers events: with a certificate of an internal CA (a load balancer, a ClusterIssuer of the company), GitLab
must trust that CA, or its deliveries fail (see the log of the webhook in the project). Add the same webhook to the
projects of services, or once to their group (group webhooks need GitLab Premium): URL `https://hammurapi-api.<domain>/hooks/v1/git`, the triggers above,
and the secret token the installer generated:

```sh
kubectl -n hammurapi get secret hammurapi-secrets -o jsonpath='{.data.WEBHOOK_SECRET}' | base64 -d
```

The wizard shows each of these steps with the links of your GitLab and the addresses of the install.

### Hammurapi and Nabu

- **Nabu of the same install**: Nabu creates the service client of Hammurapi itself. After the install, allow its service agents in **Nabu → Admin → Clients**.
- **Another Nabu** (`NABU_MODE=external`): register a client for Hammurapi in that Nabu (**Admin → Clients**). Set `NABU_URL`, the `https://` address of its API, `NABU_CLIENT_ID` and the secret `NABU_CLIENT_SECRET`. Before anything changes, `install` checks that this Nabu issues a token to the client (code `14` otherwise).

## Secrets of the products

The secrets above come from environment variables or `<KEY>_FILE`, never from the config file. The first `install` keeps them in the secret `installer/product-inputs`, so later runs need them only to change them.
