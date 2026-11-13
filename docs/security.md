# Security

## Verifying a release

Each release `vX.Y.Z` has `installer.tar.gz`, its SHA-256 and a keyless [cosign](https://docs.sigstore.dev/) signature. The release workflow of this repository makes them, and only after our own production has taken the tag.

```sh
base=https://github.com/GreenOnGrey/installer/releases/latest/download
curl -fsSLO "$base/installer.tar.gz" -O "$base/installer.tar.gz.sha256" -O "$base/installer.tar.gz.sigstore.json"
sha256sum -c installer.tar.gz.sha256
cosign verify-blob installer.tar.gz --bundle installer.tar.gz.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/GreenOnGrey/installer/\.github/workflows/deploy-prod\.yml@refs/tags/v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
tar xzf installer.tar.gz
```

The archive holds the file `RELEASE` with its tag and commit, which `status` reports. The images of Nabu, Hammurapi and our MCP servers are signed with cosign by the release workflows of their repositories, and scanned by Trivy before release.

## Secrets

- Secrets come from environment variables, `<KEY>_FILE` files or the hidden input of the wizard. They never go into the config file: one written there stops the run with code `2`.
- They never reach command arguments or logs. `install` passes them to `kubectl` through stdin, and the tests check argv and logs for them.
- They are kept only in Kubernetes secrets:
  - `storages/*-conn` for the storages;
  - `installer/product-inputs` for what you gave the products;
  - the namespaces of the products for the keys generated once (encryption keys, webhook secret).
- The passwords of built-in storages and the keys of MCP servers are generated on the first `install`. A repeated run keeps them.
- The config file `/etc/greenongrey/installer.env` holds no secrets and is readable (`0644`).

Anyone with access to the cluster can read these secrets. Limit access to the kubeconfig, or to the machine on minikube.

## Network

- **Published from outside**, with public access: only ports 80 and 443 of the ingress. Traefik routes only the hosts and paths of the products and Grafana. Service ports stay inside the cluster.
- **Certificates**: Let's Encrypt through cert-manager, or the `ClusterIssuer` of your cluster. With `TLS_TERMINATION=external` the load balancer in front holds them, and the traffic from it to the ingress is plain HTTP: keep that network private, and give Traefik only the addresses of the load balancer (`TLS_PROXY_CIDRS`).
- **Sandboxes of Nabu**: agents run code in sandboxes isolated by `NetworkPolicy`. On an existing cluster, `install` tests that the network plugin enforces it before anything changes (code `18` otherwise). Their outgoing traffic goes through the egress proxy of Nabu.
- **MCP servers**: reachable only from the components of Nabu and the checks of the stand, again through network policies. Platform servers also require a key.
- **Grafana**: through an SSH tunnel, or with public access through GitHub sign-in limited to `GRAFANA_GITHUB_ORG`.

## What the installer changes

**On minikube**:
- packages: Docker Engine (unless the machine has one already: that one stays as it is), kubectl, Helm, minikube;
- the systemd units `<prefix>-stand` and `<prefix>-ingress-forward`;
- the forwarding of ports 80 and 443 (iptables, or `forward-port` with firewalld);
- the minikube profile.

It runs with `sudo` and never as root itself.

**On an existing cluster**: only the namespaces it labels, their releases, and the `ClusterIssuer`s of the built-in ingress. External storages are only read and checked, never changed.

## Reporting a vulnerability

Report it privately through **Security → Report a vulnerability** of the repository on GitHub, not as a public issue.
