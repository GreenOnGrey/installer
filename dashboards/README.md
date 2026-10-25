# Дашборды Grafana

JSON дашбордов хранится здесь и загружается в Grafana как ConfigMap (чарт
`charts/hammurapi-dashboards`, sidecar Grafana, папка «Hammurapi Infra»). Grafana
ничего не скачивает при запуске.

| Файл | Дашборд | Источник | Версия | Загружен |
|---|---|---|---|---|
| `kubernetes-cluster.json` | Kubernetes / Views / Global | [dotdc/grafana-dashboards-kubernetes](https://github.com/dotdc/grafana-dashboards-kubernetes), `dashboards/k8s-views-global.json` | v3.0.8 | 2026-09-29 |
| `node-exporter.json` | Node Exporter Full | [grafana.com/dashboards/1860](https://grafana.com/grafana/dashboards/1860) | ревизия 45 | 2026-09-29 |
| `victoriametrics.json` | VictoriaMetrics — single-node | [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics), `dashboards/victoriametrics.json` | v1.153.0 | 2026-09-29 |
| `kafka.json` | Strimzi Kafka | чарт `strimzi-kafka-operator`, `files/grafana-dashboards/strimzi-kafka.json` | 1.2.0 | 2026-09-29 |
| `postgres.json` | CloudNativePG | [cloudnative-pg/grafana-dashboards](https://github.com/cloudnative-pg/grafana-dashboards), `charts/cluster/grafana-dashboard.json` | cluster-v0.0.5 | 2026-09-29 |
| `s3.json` | SeaweedFS | чарт `seaweedfs`, `dashboards/seaweedfs-grafana-dashboard.json` | 4.48.0 | 2026-09-29 |
| `mcp.json` | MCP-серверы | собственный (FTR.NAB.CMN-0006 R18): поды namespace `mcp`, метрики прокси `nabu_mcp_proxy_*`; раздел «Документы» (FTR.NAB.CHAT-0003 R24) | — | 2026-10-24 |
| `nabu-agents.json` | Агенты Nabu | собственный: ходы и время до первого ответа, очередь за подом, модели (запросы, ошибки, токены, стоимость), вызовы MCP и операции песочниц, поды агентов, служебные агенты и задания, память, CPU, перезапуски и OOM namespace `nabu` и `nabu-agents` | — | 2026-10-25 |
| `nabu-sandboxes.json` | Песочницы Nabu | собственный (FTR.NAB.CMN-0008 R20): старт и сбои по профилям, загрузка образов на узлы, проверки собственных образов, сигналы недостающих библиотек. Алерт `NabuSandboxCustomStartFailing` — в `values/grafana.yaml` | — | 2026-10-24 |

Объектное хранилище стенда — SeaweedFS, а не MinIO: образы MinIO community больше не
публикуются (Docker Hub `minio/minio` удалён, quay.io требует авторизации). Поэтому вместо
дашборда MinIO — дашборд SeaweedFS.

## Добавление или обновление

```sh
curl -fsSL <адрес исходного JSON> -o /tmp/src.json
dashboards/normalize.sh /tmp/src.json <имя>      # → dashboards/<имя>.json
```

`normalize.sh`:

- заменяет ссылки на источник данных (`${DS_PROMETHEUS}`, `$ds`, `${datasource}` и т. п.)
  на UID `victoriametrics`, а выражения — на `__expr__`;
- удаляет переменные шаблона типа `datasource`, а также `__inputs`, `__requires`,
  `__elements` и `id`;
- задаёт стабильный `uid`: `hammurapi-<имя>`.

После обновления поправьте строку таблицы выше. Тест `tests/unit/dashboards.bats`
(OBS-06) проверяет, что в JSON нет других ссылок на источники и нет `__inputs`.

Метки, на которые опираются дашборды, добавляют задания сбора в `values/scrape/`:
`namespace`, `pod`, `strimzi_io_*`, `kubernetes_pod_name`, а метку `cluster=hammurapi`
vmagent ставит всем рядам при записи.
