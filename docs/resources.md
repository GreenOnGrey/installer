# Storages and observability

The products need Postgres, Kafka and S3-compatible storage. Each one is either built into the install or external (a managed cloud service or your own), chosen separately: `POSTGRES_MODE`, `KAFKA_MODE`, `S3_MODE` = `internal` | `external`.

Consumers see the same stable addresses and secrets in the namespace `storages` either way, so switching a storage changes nothing in the products:

| Service | Secret | Keys |
|---|---|---|
| `postgres.storages.svc:5432` | `postgres-conn` | `host`, `port`, `database`, `username`, `password`, `sslmode`, `uri` |
| `kafka.storages.svc:9092` | `kafka-conn` | `bootstrap_servers`, `security_protocol`, `sasl_mechanism`, `username`, `password` |
| `s3.storages.svc:9000` | `s3-conn` | `endpoint`, `region`, `bucket`, `access_key`, `secret_key`, `path_style` |

`./installer creds` prints them.

## Built-in storages

Postgres 18 (CloudNativePG, one instance), Kafka 4 (Strimzi, KRaft, one broker) and SeaweedFS (S3, one pod) run in the cluster with volumes of `PG_STORAGE`, `KAFKA_STORAGE` and `S3_STORAGE`. Their passwords are generated on the first `install` and kept only in Kubernetes secrets.

They are single instances without high availability and without backups of their own.

## Backups

Neither `update` nor `uninstall` has a rollback. Before an update, before `uninstall` and before resizing minikube, back up the built-in storages, for example:

```sh
ctx=greenongrey   # on an existing cluster: your KUBE_CONTEXT
pod=$(kubectl --context $ctx -n storages get pods -l cnpg.io/instanceRole=primary -o name)
kubectl --context $ctx -n storages exec "$pod" -c postgres -- pg_dumpall -U postgres >postgres.sql
```

Copy the buckets with any S3 client, using the endpoint and keys of `./installer creds`. Kafka holds events in flight, not data of record.

External storages are backed up by their own means; the installer never changes their data.

## External storages

Set the mode to `external` and the parameters of the storage ([reference.md](reference.md#storages)). The built-in storage is then not deployed. The service of the same name points to the external host: an `ExternalName` for a DNS name, or a service with an `EndpointSlice` for an IP. The `*-conn` secret is filled from the configuration.

Before anything is deployed, the Job `external-check` checks each external storage from inside the cluster. A failure stops `install` with code `14` and names the storage:

| Storage | Needs |
|---|---|
| Postgres | The extension `vector`. The owner (`POSTGRES_USER`) with `CREATEROLE`, and `CREATEDB` or an existing database of Nabu |
| Kafka | An answer to a metadata request; writing and reading the topic `installer-probe` (create it if automatic creation is off). With `OAUTHBEARER` only the TCP connection is checked |
| S3 | The buckets `S3_BUCKET` and `S3_BUCKET_NABU`, created in advance: the check writes, reads and deletes `.installer-check/<id>` in each |

Passwords and keys come from environment variables or `<KEY>_FILE` files, never from the config file. A later run without them reuses the ones kept in the `*-conn` secret, as long as the storage is the same: the same host and user for Postgres and Kafka, the same endpoint and bucket for S3. A new value replaces the kept one.

An example with Google Cloud (Cloud SQL, Managed Service for Apache Kafka, Cloud Storage) is in [gcp.md](gcp.md).

## Observability

`OBSERVABILITY=true` (the default) installs:
- VictoriaMetrics, keeping metrics for `VM_RETENTION`;
- VictoriaLogs, keeping logs for `VL_RETENTION`;
- vmagent with kube-state-metrics and node-exporter;
- Vector, which collects the logs of all pods;
- Grafana, with its dashboards and alert rules.

`OBSERVABILITY=false` installs none of them and removes them if they are installed. The volumes of metrics and logs stay; the data of Grafana is deleted.

## Checks

At the end of `install` and in `status`:

- the pods of `storages` and `observability` are ready;
- Grafana and its data sources answer, every scrape job is up, and a test log line reaches VictoriaLogs;
- the storages work with their `*-conn` secrets: `select 1` in Postgres, a message in Kafka, an object in S3;
- every container has requests and limits, and memory requests are at most two thirds of the node memory;
- public access, the products and the MCP servers answer.

A failure ends with code `15` and names the check. A check that depends on a service outside the install only warns: when the search engines refuse SearXNG, `mcp-search-query` shows `!`, and the run goes on.
