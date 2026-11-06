# CI/CD and scripts

Every command runs without a terminal. `install` never asks anything. `update` and `uninstall` need `--yes`. The wizard needs a terminal: without one, `./installer` ends with code `2` and the help. The wizard only writes the config file and runs `install --config`, so a file written by hand gives the same install.

## Configuration

- **Parameters**: in a config file (`--config`, or `INSTALLER_CONFIG`) or in environment variables, which win over the file. The keys are in [reference.md](reference.md#configuration).
- **Secrets**: only in environment variables or in `<KEY>_FILE` files. A secret written in the config file stops the run with code `2`. Secrets never reach command arguments or logs: `install` passes them to `kubectl` through stdin.
- **Missing parameters**: all are named at once, with code `2`, so one run shows everything to fix.

`install` keeps the secrets in the cluster. A later run without them reuses the kept ones:
- secrets of products stay as long as nothing replaces them;
- secrets of external storages stay as long as the storage is the same.

## Result

The last line of stdout of `install`, `update` and `uninstall` is one JSON object, on success and on every failure:

```json
{"status":"failed","command":"update","code":13,"durationSeconds":95,"installerVersion":"v0.3.8","updated":["nabu-core"],"failed":["nabu-web"],"skipped":["hammurapi-core","hammurapi-web"],"diagnostics":"/opt/installer/logs/20261106T101500Z/run.log"}
```

Read it with `tail -1 | jq`. The fields and the exit codes are in [reference.md](reference.md#json-result). `status --json` and `creds --json` print one JSON document.

`install` is idempotent: a repeated run with the same configuration keeps data and passwords and changes only what differs. A second run on the same machine waits for nothing: it exits with code `17` while another one holds `LOCK_FILE`.

## Example: GitHub Actions

A runner that reaches the cluster (for an existing cluster), or the machine itself through SSH (for minikube):

```yaml
jobs:
  install:
    runs-on: [self-hosted, greenongrey]
    environment: production
    steps:
      - name: Download a release
        env: { VERSION: v0.3.8 }
        run: |
          base=https://github.com/GreenOnGrey/installer/releases/download/$VERSION
          curl -fsSLO "$base/installer.tar.gz" -O "$base/installer.tar.gz.sha256"
          sha256sum -c installer.tar.gz.sha256
          tar xzf installer.tar.gz
      - name: Install
        env:
          OIDC_CLIENT_SECRET: ${{ secrets.OIDC_CLIENT_SECRET }}
          POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
        run: |
          ./installer/installer install --config deploy/installer.env --no-color | tee install.log
          tail -1 install.log | jq -e '.status == "ok"'
```

To move to a newer release, change `VERSION` and run `update --yes` instead of `install`.

## Rolling out a product from its own CI

The products deploy their own tags with `bin/nabu-deploy` and `bin/hammurapi-deploy`. Each script reads one JSON from stdin and prints a JSON result on its last line. The reusable workflows `deploy-component.yml` of the repositories `nabu` and `hammurapi` call them over SSH. A component deployed this way belongs to its CI, and `install` leaves it alone.
