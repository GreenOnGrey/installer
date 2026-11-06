# An existing Kubernetes cluster

`INSTALL_TARGET=external` with `KUBE_CONTEXT` installs into a cluster of your kubeconfig. The machine you run the installer on does not change: no packages, no systemd units, no minikube.

## Requirements

- On the machine: `kubectl`, `helm` and `jq`. The installer does not install them for this target.
- Kubernetes 1.35 or newer. Versions above the tested 1.37 run with a warning.
- `kubectl` within one minor version of the server.
- Cluster-admin rights and a default `StorageClass` when anything is built in (storages, observability, ingress).
- A `NetworkPolicy` that the network plugin enforces. The isolation of Nabu sandboxes rests on it.
- A domain (`PUBLIC_BASE_DOMAIN`). There is no sslip.io fallback here, because the address of the ingress is not known in advance.

## Checks before anything changes

`install` checks the cluster first and reports every problem at once with code `18`:

| Check | How |
|---|---|
| Context | The cluster answers |
| Version | From 1.35; above 1.37 a warning |
| Tools | `kubectl`, `helm`, `jq` on the machine; the minor version of `kubectl` |
| Rights | `kubectl auth can-i '*' '*'` when anything is built in |
| StorageClass | A default one when anything is built in |
| NetworkPolicy | A real test in a temporary namespace `installer-preflight`: traffic flows before the policy and stops after it, in both directions |
| Ingress | With `INGRESS_MODE=external`: `INGRESS_CLASS` and the `ClusterIssuer` `ACME_ISSUER` exist |

External storages are checked from inside the cluster too, with code `14` ([resources.md](resources.md#external-storages)).

## Ingress and certificates

- **`INGRESS_MODE=internal`** (the default) installs Traefik and cert-manager into the cluster. The cluster needs a provider of `LoadBalancer` services. The address appears only during the first `install`, so that run stops at the certificate: point `*.<domain>` to the printed address and run `install` again.
- **`INGRESS_MODE=external`** installs neither. Set `INGRESS_CLASS` and `ACME_ISSUER` (a cert-manager `ClusterIssuer`) in the config file, so `status` reads them too. Each Ingress gets a certificate of its own in its namespace.

Switching an existing install to `external` does not remove its Traefik and cert-manager. The Ingresses of the products move on their next rollout.

## TLS on a load balancer

When a load balancer in front of the install terminates TLS, for example one your team runs, and sends plain HTTP to port 80 of the ingress, set `TLS_TERMINATION=external`. It works on both targets and with both ingress modes:

- The installer installs no cert-manager and no `ClusterIssuer`, and requests no certificate. A cert-manager left from an earlier install stays.
- Traefik of the install serves HTTP and does not redirect to HTTPS; the load balancer does that. It trusts the headers `X-Forwarded-*` only from `TLS_PROXY_CIDRS`, the addresses of the load balancer, so the products see that the request came over HTTPS while a client past the load balancer cannot claim it. With the ingress of the cluster (`INGRESS_MODE=external`) only `INGRESS_CLASS` is needed, and your team configures the controller to trust the load balancer.
- The Ingresses of Grafana and of the products have no `tls` section. The addresses of the products stay `https://`.
- `PUBLIC_BASE_DOMAIN` is required. `PUBLIC_IP` is the address of the load balancer: the DNS check compares the hosts with it (code `19`). Without it, DNS is not checked.
- The products need their charts from version 0.3.10, which leave `tls` out of their Ingresses. With an older `NABU_CHART_VERSION` or `HAMMURAPI_CHART_VERSION`, `install` stops with code 2 and names the version, and the wizard sets it itself.
- The check of public access asks Traefik over HTTP and expects 200 or a redirect to sign-in. The load balancer and its certificate are not checked: they are not part of the install.

```sh
TLS_TERMINATION=external
TLS_PROXY_CIDRS=10.0.0.0/24
PUBLIC_BASE_DOMAIN=apps.example.com
PUBLIC_IP=203.0.113.9
```

The wizard asks where TLS terminates on the step of the domain.

## What `uninstall` removes

Only what the installer created:
- the releases;
- the namespaces labelled `app.kubernetes.io/part-of` (`installer`, `nabu`, `hammurapi`, `landing`), with the data of built-in storages;
- the `ClusterIssuer`s of the built-in ingress.

CRDs stay. A namespace that existed before the installer has no label, and neither has one an older installer created: `uninstall` names such a namespace and leaves it. External storages and their data stay.

## Example

```sh
cat >installer.env <<'EOF'
INSTALL_TARGET=external
KUBE_CONTEXT=prod-cluster
PUBLIC_ACCESS=true
PUBLIC_BASE_DOMAIN=apps.example.com
INGRESS_MODE=external
INGRESS_CLASS=nginx
ACME_ISSUER=letsencrypt-prod
POSTGRES_MODE=external
POSTGRES_HOST=db.example.com
POSTGRES_PORT=5432
POSTGRES_DATABASE=greenongrey
POSTGRES_USER=greenongrey
POSTGRES_SSLMODE=require
PRODUCTS=nabu
AUTH_PROVIDER=oidc
OIDC_ISSUER=https://id.example.com/realms/main
OIDC_CLIENT_ID=greenongrey
BOOTSTRAP_ADMINS=alice@example.com
EOF
POSTGRES_PASSWORD_FILE=/secure/pg OIDC_CLIENT_SECRET_FILE=/secure/oidc \
  ./installer/installer install --config installer.env
```

The wizard asks the same questions and lists the contexts of kubeconfig.
