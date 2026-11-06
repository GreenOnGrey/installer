# One machine with minikube

`INSTALL_TARGET=minikube` (the default) sets up the machine itself: Docker Engine, kubectl, Helm and minikube at pinned versions, one minikube profile, and systemd units that keep the stand running across reboots.

## Machine requirements

| | Minimum |
|---|---|
| OS | x86_64: Debian 13 (trixie), or RHEL, Rocky or AlmaLinux 9 and 10. SELinux may stay enforcing. `podman` and `runc` conflict with Docker CE: remove them first |
| CPU, memory | 4 vCPU, 16 GB (the default profile takes 3 CPU and 12 GB) |
| Disk | 80 GB free; a 100 GB disk is recommended |
| User | A regular user with passwordless `sudo`. Not root: minikube with the docker driver does not run as root |
| Network | Internet access for packages, images and charts; ports 80 and 443 open from outside for public access |

`install` checks all of this first and exits with code `10` without changing anything if the machine does not fit. The minimums are `HOST_MIN_CPUS`, `HOST_MIN_MEMORY_GB` and `HOST_MIN_DISK_GB`.

## What gets deployed

```text
machine ─ Docker ─ minikube (profile greenongrey, docker driver, 3 CPU / 12 GB)
  storages       Kafka (Strimzi, KRaft, 1 broker)     kafka.storages.svc:9092
                 Postgres (CloudNativePG, 1 instance)  postgres.storages.svc:5432
                 SeaweedFS (S3)                        s3.storages.svc:9000
  observability  VictoriaMetrics, VictoriaLogs, vmagent, Vector, Grafana
  ingress        Traefik, cert-manager, MetalLB (public access)
  installer      state of the install
  nabu, hammurapi, mcp   the products and MCP servers you chose
```

Versions are in [`config/versions.env`](../config/versions.env). The object storage is SeaweedFS, not MinIO, because MinIO community images are no longer published. Any S3-compatible storage can be connected as an external one ([resources.md](resources.md)).

## Size of the profile

`MK_CPUS`, `MK_MEMORY` and `MK_DISK` apply when the profile is created. To change them later, run `uninstall` and `install` again, which deletes the data of built-in storages: back up first.

Components may request at most two thirds of the memory of the node. MCP servers add to this ([mcp.md](mcp.md#memory)). If they do not fit, `install` names the `MK_MEMORY` they need and exits with code `2` before anything changes. The wizard suggests that size itself.

## Public access

With `PUBLIC_ACCESS=true` (the products need it), MetalLB gives Traefik an address inside the profile. The unit `<prefix>-ingress-forward` forwards ports 80 and 443 of the machine to that address. On RHEL with firewalld the forwarding uses `forward-port`. cert-manager requests one Let's Encrypt certificate for all public hosts.

Before the cluster changes, `install` checks that each host of `PUBLIC_BASE_DOMAIN` resolves to the external address of the machine (`PUBLIC_IP`, or the address an IP service reports). If one does not, `install` stops with code `19` and requests no certificate. The wizard asks instead whether to go on. Behind a proxy, whose address the hosts resolve to, set `PUBLIC_DNS_CHECK=false`.

Without a domain the hosts are `<host>.<IP with dashes>.sslip.io`. Let's Encrypt limits certificates per registered domain, and all users of sslip.io share one limit, so issuance may fail for days.

Grafana is at `https://grafana.<domain>` with public access, or through an SSH tunnel without it:

```sh
ssh -L 3000:localhost:3000 <user>@<machine>           # on your computer
kubectl --context greenongrey -n observability port-forward svc/grafana 3000:80   # on the machine
# http://localhost:3000; the password is in ./installer creds
```

## Reboots

`install` installs the unit `<prefix>-stand` (`STAND_AUTOSTART=true`). At boot it starts the profile and waits for the pods; at shutdown it stops the cluster cleanly. See its log with `journalctl -u greenongrey-stand`. `STAND_AUTOSTART=false` and `install` remove it.

minikube turns off image garbage collection in kubelet, so old images would fill the disk. `install` and the unit turn it back on: above `IMAGE_GC_HIGH` % of image disk usage, unused images are removed down to `IMAGE_GC_LOW` %, and an unused image older than `IMAGE_GC_MAX_AGE` is removed in any case.

## Uninstall

`./installer uninstall` asks for confirmation (`--yes` without a terminal). It then deletes the profile with all its data and removes the units and the port forwarding. Packages (Docker, kubectl, Helm, minikube) stay. External storages and their data stay.
