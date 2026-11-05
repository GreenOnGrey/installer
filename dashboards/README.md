# Grafana dashboards

Dashboard JSON is kept here and loaded into Grafana as ConfigMaps (the chart `charts/hammurapi-dashboards`, the Grafana sidecar, the folder "Hammurapi Infra"). Grafana downloads nothing at start.

| File | Dashboard | Source | Version | Loaded |
|---|---|---|---|---|
| `kubernetes-cluster.json` | Kubernetes / Views / Global | [dotdc/grafana-dashboards-kubernetes](https://github.com/dotdc/grafana-dashboards-kubernetes), `dashboards/k8s-views-global.json` | v3.0.8 | 2026-09-29 |
| `node-exporter.json` | Node Exporter Full | [grafana.com/dashboards/1860](https://grafana.com/grafana/dashboards/1860) | revision 45 | 2026-09-29 |
| `victoriametrics.json` | VictoriaMetrics — single-node | [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics), `dashboards/victoriametrics.json` | v1.153.0 | 2026-09-29 |
| `kafka.json` | Strimzi Kafka | chart `strimzi-kafka-operator`, `files/grafana-dashboards/strimzi-kafka.json` | 1.2.0 | 2026-09-29 |
| `postgres.json` | CloudNativePG | [cloudnative-pg/grafana-dashboards](https://github.com/cloudnative-pg/grafana-dashboards), `charts/cluster/grafana-dashboard.json` | cluster-v0.0.5 | 2026-09-29 |
| `s3.json` | SeaweedFS | chart `seaweedfs`, `dashboards/seaweedfs-grafana-dashboard.json` | 4.48.0 | 2026-09-29 |
| `nabu-agents.json` | Nabu agents | our own: turns and time to the first answer, the queue for a pod, models (requests, errors, tokens, cost), MCP calls and sandbox operations, agent pods, service agents and jobs, memory, CPU, restarts and OOM of the namespaces `nabu` and `nabu-agents` | — | 2026-10-25 |
| `nabu-sandboxes.json` | Nabu sandboxes | our own (FTR.NAB.CMN-0008 R20): starts and failures by profile, image loading on nodes, checks of custom images, signals of missing libraries. The alert `NabuSandboxCustomStartFailing` is in `values/grafana.yaml` | — | 2026-10-24 |

The MCP server dashboard ships in the chart `mcp-servers` of the repository [mcps](https://github.com/GreenOnGrey/mcps) and appears when a server is enabled.

The stand's object storage is SeaweedFS, not MinIO: MinIO community images are no longer published (Docker Hub `minio/minio` is gone, quay.io requires authorization). That is why there is a SeaweedFS dashboard instead of a MinIO one.

## Adding or updating

```sh
curl -fsSL <address of the source JSON> -o /tmp/src.json
dashboards/normalize.sh /tmp/src.json <name>      # → dashboards/<name>.json
```

`normalize.sh`:

- replaces data source references (`${DS_PROMETHEUS}`, `$ds`, `${datasource}` and so on) with the UID `victoriametrics`, and those of expressions with `__expr__`;
- removes template variables of the type `datasource`, as well as `__inputs`, `__requires`, `__elements` and `id`;
- sets a stable `uid`: `hammurapi-<name>`.

After an update, fix the table row above. The test OBS-06 in `tests/unit/repo.bats` checks that the JSON has no other data source references and no `__inputs`.

The scrape jobs in `values/scrape/` add the labels dashboards rely on: `namespace`, `pod`, `strimzi_io_*`, `kubernetes_pod_name`. vmagent puts the label `cluster=hammurapi` on all series when writing.
