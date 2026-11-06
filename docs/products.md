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

Hammurapi works on a repository of specifications through its GitHub App. Create one under **Settings → Developer settings → GitHub Apps → New GitHub App**:

- callback URL: `https://hammurapi-api.<domain>/api/v1/auth/callback`;
- webhook: off, because the repository webhook below is used;
- repository permissions: **Contents**, **Pull requests**, **Issues** and **Actions**: read and write; **Metadata**: read;
- install it on the repository of specifications and on the repositories of services.

Set:
- `HAMMURAPI_GITHUB_APP_ID` and `HAMMURAPI_GITHUB_CLIENT_ID`;
- the secrets `HAMMURAPI_GITHUB_CLIENT_SECRET` and `HAMMURAPI_GITHUB_APP_PRIVATE_KEY_FILE`, the path of the downloaded `.pem`;
- `HAMMURAPI_SPEC_REPO` (`owner/name`).

The wizard reads the `.pem` itself and does not keep its path. With `AUTH_PROVIDER=github`, people sign in to Hammurapi through this App.

After the install, add a webhook to the repository of specifications and to each service repository (or once to the organization):

- payload URL `https://hammurapi-api.<domain>/hooks/v1/git`, content type `application/json`;
- events: pushes, pull requests, pull request reviews, pull request review comments, issue comments;
- secret: the key `WEBHOOK_SECRET` of the secret `hammurapi/hammurapi-secrets`. The installer generates it once:

```sh
kubectl --context greenongrey -n hammurapi get secret hammurapi-secrets -o jsonpath='{.data.WEBHOOK_SECRET}' | base64 -d
```

The repository needs the rules of Hammurapi: see [the documentation of Hammurapi](https://github.com/GreenOnGrey/hammurapi/blob/main/docs/git-providers.md).

### Hammurapi and Nabu

- **Nabu of the same install**: Nabu creates the service client of Hammurapi itself. After the install, allow its service agents in **Nabu → Admin → Clients**.
- **Another Nabu** (`NABU_MODE=external`): register a client for Hammurapi in that Nabu (**Admin → Clients**). Set `NABU_URL`, the `https://` address of its API, `NABU_CLIENT_ID` and the secret `NABU_CLIENT_SECRET`. Before anything changes, `install` checks that this Nabu issues a token to the client (code `14` otherwise).

## Secrets of the products

The secrets above come from environment variables or `<KEY>_FILE`, never from the config file. The first `install` keeps them in the secret `installer/product-inputs`, so later runs need them only to change them.
