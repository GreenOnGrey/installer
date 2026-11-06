# Quick start

This page installs Nabu (and, if you want, Hammurapi) on one clean machine with minikube. For an existing Kubernetes cluster, read [external-kubernetes.md](external-kubernetes.md) first; the steps are the same.

## 1. Prepare

- A machine of [minikube.md](minikube.md#machine-requirements): Debian 13, or RHEL, Rocky or AlmaLinux 9 and 10, x86_64, 4 vCPU, 16 GB of memory, 80 GB of free disk. Log in as a regular user with passwordless `sudo`, not as root.
- Ports 80 and 443 of the machine open from the internet: Let's Encrypt checks them before issuing certificates.
- A domain whose hosts point to the machine: `nabu.<domain>`, `nabu-api.<domain>`, `grafana.<domain>`, and `hammurapi.<domain>`, `hammurapi-api.<domain>` for Hammurapi. A wildcard record `*.<domain>` covers them all. Without a domain the installer uses `<IP>.sslip.io`, which shares the limits of Let's Encrypt with everyone else.
- A way for people to sign in: a GitHub OAuth app, or an OpenID Connect client ([products.md](products.md#sign-in)). For Hammurapi, also its GitHub App ([products.md](products.md#hammurapi)).

## 2. Download

```sh
curl -fsSL https://github.com/GreenOnGrey/installer/releases/latest/download/installer.tar.gz | tar xz
```

To check the archive first, see [security.md](security.md#verifying-a-release). `git clone --branch vX.Y.Z https://github.com/GreenOnGrey/installer.git` gives the same files.

## 3. Run the wizard

```sh
./installer/installer
```

The wizard asks:

1. where to install: this machine (minikube) or an existing cluster;
2. the products: Nabu, Nabu and Hammurapi, or Hammurapi with a Nabu that runs elsewhere;
3. the domain and an e-mail for Let's Encrypt;
4. how people sign in, and the first administrators;
5. for Hammurapi, its GitHub App and the repository of specifications;
6. Postgres, Kafka and S3: built in or external ([resources.md](resources.md));
7. metrics, logs and Grafana;
8. MCP servers for agents, with the memory each one needs ([mcp.md](mcp.md));
9. the model key of the first connection of Nabu, optional, and the size of minikube.

Enter keeps the value in brackets. Passwords and keys are typed hidden.

The wizard then shows a summary without secrets. After `yes`, it writes `/etc/greenongrey/installer.env` and runs `./installer install --config /etc/greenongrey/installer.env`, the same command CI runs. Nothing changes before that `yes`.

The secrets you type do not go to the file. `install` keeps them in Kubernetes secrets, so later runs do not ask for them again.

On a clean machine the install takes about 15–20 minutes. `install` installs Docker Engine, kubectl, Helm and minikube at pinned versions, and leaves the ones already installed alone. Then it starts the cluster, deploys the storages, observability and products, and checks the result. It ends with the addresses of the products and what is left to do by hand.

## 4. After the install

- Open `https://nabu.<domain>` and sign in as one of the administrators.
- Add a model connection in the admin area of Nabu, unless you gave a model key.
- With Hammurapi:
  - add the repository webhook that the summary prints;
  - allow the service agents of Hammurapi to its client in **Nabu → Admin → Clients**.
- `./installer/installer status` shows the state and runs the checks. `./installer/installer creds` prints passwords of storages and Grafana, and the addresses of MCP servers.

## 5. Change, update, remove

- Run `./installer/installer` again to change a resource or turn on an MCP server. It fills in the current values; a kept secret shows as `set`.
- A new release: download it, then run `./installer/installer update` ([update.md](update.md)).
- `./installer/installer uninstall` removes the install: on minikube the cluster with all its data. Back up first ([resources.md](resources.md#backups)).

Without the wizard, for CI or scripts: [ci-cd.md](ci-cd.md).
