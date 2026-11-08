# Updates

Each release of the installer is a tested set of versions: the stand, the products and the MCP servers, pinned in [`config/versions.env`](../config/versions.env). The set holds only versions that already run on our own production.

## Update to a new release

Back up the built-in storages first ([resources.md](resources.md#backups)): an update has no rollback. Then:

```sh
mv installer installer.previous   # unpack into a clean directory: files a release removed must not stay
curl -fsSL https://github.com/GreenOnGrey/installer/releases/latest/download/installer.tar.gz | tar xz
./installer/installer update
```

The config file `/etc/greenongrey/installer.env` stays where it is, and secrets stay in the cluster. A config file inside the old directory (`config/local.env`) has to be copied over. `installer.previous/logs/` keeps the logs of earlier runs.

`update`:

1. checks the stand. With a problem it stops with code `15` and changes nothing;
2. shows the plan: each service with its installed and target version, and a reminder about backups;
3. asks for confirmation. Without a terminal `--yes` is required; `--dry-run` only shows the plan;
4. removes all pins (below) and runs the whole `install` with the versions of this release.

A failed service stops the update. Nothing is rolled back. The JSON result lists what was `updated`, what `failed` and what was `skipped`. Fix the cause and run `update` again.

## One service

```sh
./installer/installer update nabu-core                 # to the version of this release
./installer/installer update nabu-core --to v0.3.6     # to another version: a pin
```

Services: `nabu-core`, `nabu-web`, `hammurapi-core`, `hammurapi-web`, `mcp-servers` (a chart version `X.Y.Z`). Only that service rolls out, and then the checks of the stand run.

A version given with `--to` is a **pin**. `install` keeps it and `status` shows it. `update <service>` without `--to` removes the pin of that service, and `update` without a service removes all of them. A pin is stored only after its rollout succeeded.

## Going back

A version below the running one may need a database the old version cannot read. A product allows going back only through the annotation `greenongrey.tech/downgrade-safe-to: vX.Y.Z` of its chart: any version from it up is safe. Without the annotation, or below it, `update` refuses with code `2` and changes nothing.

This applies to `update` without a service too: after a pin above the set, returning to the set is going back.

## Production of a product

The CI of each product rolls its tags out to our production directly; an installer release is not needed for that. After a successful rollout, `deploy-component.yml` of `nabu` and `hammurapi` calls [`version-pr.yml`](../.github/workflows/version-pr.yml) of this repository. It opens a PR that moves the version in `config/versions.env`, with the agent Pi and the chart the component ran with, so the set follows what runs on production. `versions-auto-merge.yml` turns on auto-merge of such a PR with the token of the App, and GitHub merges it once the required checks of `main` pass; a commit pushed to the branch by anybody else turns auto-merge off, so a person reviews it. Without Allow auto-merge in the settings of the repository the PR waits for a person; the protection of `main` must not require branches to be up to date. A tag of the installer is still a decision of its own: it publishes the release that users download. Whenever `config/versions.env` changes on `main`, by a merged PR or by hand, `versions-rebuild.yml` makes each open one that now conflicts with `main` anew from it, since two PRs often change neighbouring lines, and closes those whose version the set already has. Commits added by hand to these branches are lost. A component deployed by its own CI is left alone by `install` and `update`, which list it in `skipped`.
