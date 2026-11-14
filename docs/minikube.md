# One machine with minikube

`INSTALL_TARGET=minikube` (the default) sets up the machine itself: Docker Engine, kubectl, Helm and minikube at pinned versions, one minikube profile, and systemd units that keep the stand running across reboots.

## Machine requirements

| | Minimum |
|---|---|
| OS | x86_64: Debian 13 (trixie), Ubuntu 24.04 (noble) or 26.04 (resolute) LTS, or RHEL, Rocky or AlmaLinux 9 and 10. SELinux may stay enforcing, ufw may stay on. Docker Engine already installed from packages (Docker CE, `docker.io` of Ubuntu or Debian), version 20.10 or newer, is used as it is: the installer neither replaces nor updates it. Without one, the installer sets up Docker CE, and what Docker CE would replace stops it: `podman` and `runc` on EL; `containerd`, `runc`, `podman-docker` on Debian and Ubuntu. The snap `docker` stops it always: the stand needs `docker.service`. A Docker CE whose packages are held (`apt-mark hold`, `dnf versionlock`) counts as the installer's own and follows its pinned version |
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

Components may request at most two thirds of the memory of the node. MCP servers add to this ([mcp.md](mcp.md#memory)). With the docker driver the node reports the memory of the machine, not `MK_MEMORY`, so the budget follows the machine: 12g holds the stand with all MCP servers on a 16 GB machine. If the servers do not fit, `install` exits with code `2` before anything changes. `MK_MEMORY` above the memory of the machine is code `10` before anything installs; the wizard offers no more than the machine has.

## Public access

With `PUBLIC_ACCESS=true` (the products need it), MetalLB gives Traefik an address inside the profile. The unit `<prefix>-ingress-forward` forwards ports 80 and 443 of the machine to that address. On RHEL with firewalld the forwarding uses `forward-port`. cert-manager requests one Let's Encrypt certificate for all public hosts.

Before the cluster changes, `install` checks that each host of `PUBLIC_BASE_DOMAIN` resolves to the external address of the machine (`PUBLIC_IP`, or the address an IP service reports). If one does not, `install` stops with code `19` and requests no certificate. The wizard asks instead whether to go on. Behind a proxy, whose address the hosts resolve to, set `PUBLIC_DNS_CHECK=false`.

Behind a load balancer that terminates TLS, set `TLS_TERMINATION=external`. Then no cert-manager is installed and the hosts resolve to the load balancer, which forwards HTTP to port 80 of the machine ([external-kubernetes.md](external-kubernetes.md#tls-on-a-load-balancer)).

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

## Registry mirrors

Images come from Docker Hub, `ghcr.io`, `quay.io` and `registry.k8s.io`. If the machine reaches them only through a pull-through proxy of your network, name it in `REGISTRY_MIRRORS`: for example `REGISTRY_MIRRORS="docker.io=https://mirror.example.com"`, where `mirror.example.com/migrate/migrate` serves `docker.io/migrate/migrate`. Several registries go space-separated. A proxy that serves a registry under a path (a Harbor project) takes the full path of its API: `docker.io=https://harbor.example.com/v2/dockerhub`. The names of images do not change: containerd of the node asks the mirror first and the registry itself after it.

`install` writes the mirrors before it waits for the node, whose network plugin also comes from Docker Hub, and restarts pods that were stuck pulling an image. The unit of the stand writes them again after each reboot. A registry removed from the list gets its default back. A proxy that needs a login is not supported yet.

## Uninstall

`./installer uninstall` asks for confirmation (`--yes` without a terminal). It then deletes the profile with all its data and removes the units and the port forwarding. Packages (Docker, kubectl, Helm, minikube) stay. External storages and their data stay.
