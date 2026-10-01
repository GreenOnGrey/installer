# hammurapi-infra

Демо-стенд для запуска и отладки [Hammurapi](../hammurapi) одной командой на чистой машине
с Debian 13: кластер minikube с хранилищами (Kafka, Postgres, S3-совместимое хранилище) и
наблюдаемостью (VictoriaMetrics, VictoriaLogs, Grafana). Спецификация — `PLT.INFRA-0001`.

Стенд не зависит от облака. Любое хранилище можно заменить на managed-сервис облака:
адрес сервиса и секрет подключения остаются теми же, потребители ничего не меняют.

> Это демо-стенд, а не продакшен: одна нода, без отказоустойчивости и резервного копирования,
> наружу ничего не публикуется.

## Что разворачивается

```text
машина Debian 13 ─ Docker ─ minikube (профиль hammurapi, драйвер docker, 3 CPU / 12 ГБ)
  namespace storages       Kafka 4.3 (Strimzi, KRaft, 1 брокер)      kafka.storages.svc:9092
                           Postgres 18 (CloudNativePG, 1 экземпляр)  postgres.storages.svc:5432
                           SeaweedFS (S3, один под)                  s3.storages.svc:9000
                           секреты postgres-conn, kafka-conn, s3-conn
  namespace observability  VictoriaMetrics (метрики, 7 дней)  VictoriaLogs (логи, 3 дня)
                           vmagent + kube-state-metrics + node-exporter   Vector (логи всех подов)
                           Grafana: 2 источника данных и 6 дашбордов в папке «Hammurapi Infra»
```

Объектное хранилище — SeaweedFS, а не MinIO, как в архитектуре: образы MinIO community больше
не публикуются (Docker Hub `minio/minio` удалён, quay.io требует авторизации). Это запасной
вариант, предусмотренный архитектурой (п. 17); интерфейс `s3-conn` и адрес `s3.storages.svc:9000`
не меняются.

Версии всех компонентов и чартов — в [`config/versions.env`](config/versions.env).

## Требования к машине

| | Минимум |
|---|---|
| ОС | Debian 13 (trixie), x86_64 |
| CPU / память | 4 vCPU, 16 ГБ (профиль по умолчанию: minikube 3 CPU / 12 ГБ) |
| Диск | 80 ГБ свободно (рекомендуется диск 100 ГБ) |
| Права | обычный пользователь с `sudo` без пароля; запускать **не** от root — minikube с драйвером docker не работает от root |
| Сеть | доступ в интернет: пакеты, образы, чарты, плагин Grafana |

Скрипт проверяет всё это перед установкой и при несоответствии завершается, ничего не меняя.

## Быстрый старт

```sh
git clone https://github.com/GreenOnGrey/hammurapi-infra.git
cd hammurapi-infra
./hammurapi-infra.sh up
```

`up` ставит Docker Engine, kubectl, Helm и minikube нужных версий (уже установленные не
трогает), запускает кластер, генерирует пароли, разворачивает компоненты, проверяет стенд и
выводит сводку. На чистой машине это занимает около 15–20 минут, повторный запуск — пару минут.

Grafana открывается через SSH-туннель — наружу ничего не публикуется:

```sh
# на своей машине
ssh -L 3000:localhost:3000 <пользователь>@<адрес машины>
# на машине стенда, в этой сессии
kubectl --context hammurapi -n observability port-forward svc/grafana 3000:80
# затем откройте http://localhost:3000; логин и пароль — ./hammurapi-infra.sh creds
```

## Команды

| Команда | Что делает |
|---|---|
| `./hammurapi-infra.sh up` | Установка и развёртывание. Повторный запуск безопасен: доводит стенд до описанного состояния, не теряет данные и не меняет пароли; применяет изменённые версии |
| `./hammurapi-infra.sh status [--json]` | Состояние кластера, релизов и подов, развёрнутая версия, проверки стенда, запрошенная память |
| `./hammurapi-infra.sh creds [--json]` | Адреса сервисов, имена секретов, логины и пароли хранилищ и Grafana |
| `./hammurapi-infra.sh down [--yes]` | Удаление профиля minikube со всеми данными — с подтверждением |

Флаги: `--config <файл>` (по умолчанию `config/local.env`), `--verbose`, `--no-color`.

Коды выхода: `0` успех, `2` неверный вызов или конфигурация, `10` машина не подходит,
`11` зависимость не установлена или не сошлась контрольная сумма, `12` кластер не запустился,
`13` релиз не развёрнут, `14` внешнее хранилище недоступно, `15` проверки стенда не прошли,
`16` отменено, `17` уже выполняется другой `up`.

Журнал каждого `up` — `logs/<время>/run.log`; при ошибке рядом — `diagnostics/` (события,
`describe` проблемных подов, `helm status` релизов).

## Проверки стенда

В конце `up` и в `status` проверяются:

- все поды в `storages` и `observability` готовы;
- Grafana и оба источника данных отвечают;
- все задания сбора метрик активны (`up == 0` пуст);
- тестовая строка лога доходит до VictoriaLogs с полями namespace, pod, container, node;
- хранилища принимают подключение по секретам `*-conn`: `select 1` в Postgres, запись и чтение
  сообщения в Kafka, запись, чтение и удаление объекта в S3;
- у каждого контейнера заданы запросы и лимиты, а сумма запросов памяти не больше двух третей
  памяти ноды.

Если что-то не прошло, команда завершается с кодом 15 и пишет, что именно.

## Подключение приложений

Потребители (в том числе Hammurapi в следующих фичах) используют только стабильные адреса и
секреты в namespace `storages` — одинаковые для встроенного и внешнего хранилища:

| Секрет | Ключи |
|---|---|
| `postgres-conn` | `host`, `port`, `database`, `username`, `password`, `sslmode`, `uri` |
| `kafka-conn` | `bootstrap_servers`, `security_protocol` (`PLAINTEXT` / `SASL_SSL`), `sasl_mechanism`, `username`, `password` |
| `s3-conn` | `endpoint`, `region`, `bucket`, `access_key`, `secret_key`, `path_style` |

Пароли встроенных хранилищ генерируются при первом `up` и хранятся только в секретах
Kubernetes; в репозитории, файлах значений и журналах их нет.

## Настройка

Переопределения — в `config/local.env` (в `.gitignore`), пример —
[`config/local.env.example`](config/local.env.example). Приоритет:
`config/defaults.env` → `config/local.env` → переменные окружения → флаги.

Основное: ресурсы minikube (`MK_CPUS`, `MK_MEMORY`, `MK_DISK` — применяются при создании
профиля), сроки хранения (`VM_RETENTION`, `VL_RETENTION`), размеры томов, режимы хранилищ.

### Внешние (managed) хранилища

Для каждого хранилища отдельно — `POSTGRES_MODE`, `KAFKA_MODE`, `S3_MODE` = `external`.
Встроенное хранилище тогда не разворачивается, сервис `postgres`/`kafka`/`s3` указывает на
внешний хост (`ExternalName` для DNS-имени, сервис с `EndpointSlice` для IP), а секрет `*-conn`
заполняется из конфигурации. Перед развёртыванием Job `external-check` проверяет доступность
(`pg_isready`, метаданные Kafka, `HEAD` бакета); если хост недоступен, `up` останавливается
с кодом 14.

Пароли и ключи — только через файлы (`POSTGRES_PASSWORD_FILE=/secure/pg-password`) или
переменные окружения; пароль, записанный прямо в `local.env`, останавливает скрипт с кодом 2.

Для внешней Kafka проверка записи и чтения использует топик `hammurapi-infra-probe` — создайте
его заранее, если автосоздание топиков выключено. С `OAUTHBEARER` проба проверяет только
TCP-подключение: токен получает само приложение.

Пример для Google Cloud (Cloud SQL, Managed Service for Apache Kafka, Cloud Storage) —
[docs/gcp.md](docs/gcp.md).

## Выкатка на прод

Прод — демо-стенд в Google Cloud. Workflow [`deploy-prod`](.github/workflows/deploy-prod.yml)
выкатывает тег релиза:

- срабатывает на push тега `vX.Y.Z`; ручной запуск с тегом — для повторной выкатки или возврата
  на прежнюю версию (автоматического отката нет);
- передаёт машине прода выгрузку тега (`git archive`) по тому же SSH, раскладывает её в
  `/opt/hammurapi-infra/releases/<тег>` и выполняет `up`; после успеха `current` указывает на этот
  тег, хранятся последние 5 выгрузок. Машине прода не нужен доступ к GitHub — deploy keys
  запрещены политикой организации;
- `/opt/hammurapi-infra/local.env` и файлы секретов остаются на машине и в workflow не
  передаются; журналы всех запусков — в `/opt/hammurapi-infra/logs`;
- выкатки идут по одной (`concurrency`), параллельный `up` на машине блокирует
  `/var/lock/hammurapi-infra.lock` (код 17);
- итог — сводка `status` в отчёте запуска; развёрнутый тег виден в `status`
  (ConfigMap `hammurapi-infra-version`); при провале журнал прикладывается артефактом `deploy-logs`.

Настройки окружения GitHub `production`:

| Имя | Тип | Когда | Назначение |
|---|---|---|---|
| `DEPLOY_TRANSPORT` | переменная | всегда | `ssh` (по умолчанию) или `gcp-iap` |
| `PROD_HOST`, `PROD_USER` | переменные | `ssh` | Адрес и пользователь машины |
| `PROD_SSH_KEY` | секрет | `ssh` | Закрытый ключ пользователя выкатки |
| `PROD_KNOWN_HOSTS` | секрет | `ssh` | Отпечаток хоста (`ssh-keyscan -t ed25519 <адрес>`); проверка хоста не отключается |
| `GCP_PROJECT`, `GCP_ZONE`, `GCP_INSTANCE` | переменные | `gcp-iap` | Машина прода |
| `GCP_WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT` | переменные | `gcp-iap` | Workload Identity Federation |

Подготовка машины прода — в [docs/gcp.md](docs/gcp.md#машина-прода).

## Hammurapi: публичный доступ и выкатка

С `PUBLIC_ACCESS=true` стенд публикует по HTTPS `web.`, `api.` и `grafana.<базовый домен>`
(MetalLB, Traefik, сертификаты Let's Encrypt, по умолчанию домен `<IP>.sslip.io`); вход в
Grafana — через GitHub для участников организации. `hammurapi-core` и `hammurapi-web`
выкатываются на стенд своими пайплайнами через переиспользуемый workflow
`deploy-component.yml` (в публичном репозитории `hammurapi`) и скрипт `bin/hammurapi-deploy`; чарты — `charts/hammurapi-core` и
`charts/hammurapi-web`, публикуются по тегу `charts-vX.Y.Z`.

Настройка — межсетевой экран, OAuth-приложение для Grafana, GitHub App, секреты организации,
первая установка и коды выкатки — в [docs/hammurapi.md](docs/hammurapi.md).

## Разработка

```text
hammurapi-infra.sh        точка входа: up | status | creds | down
lib/                      common, host, prereqs, cluster, secrets, deploy, external, checks
config/                   versions.env (версии), defaults.env, local.env.example
values/                   значения чартов; values/scrape/ — задания сбора метрик vmagent
charts/hammurapi-storages CR Kafka и Postgres, стабильные сервисы postgres, kafka, s3
charts/hammurapi-dashboards ConfigMap дашбордов
dashboards/               JSON дашбордов, normalize.sh, README с источниками
tests/unit/               bats: функции скрипта с подменой внешних команд
tests/manifests.sh        рендер релизов для 8 комбинаций режимов, kubeconform, ресурсы
tests/e2e/e2e.sh          e2e на временной машине Google Cloud
.github/workflows/        checks (каждый PR), e2e (вручную), deploy-prod (теги)
```

```sh
shellcheck -x hammurapi-infra.sh tests/manifests.sh tests/e2e/*.sh dashboards/normalize.sh .github/scripts/*.sh
bats tests/unit             # bats-core ≥ 1.5
tests/manifests.sh          # helm ≥ 3.17, kubeconform, jq, yq
```

e2e (`.github/workflows/e2e.yml`, запуск вручную) создаёт машину `e2-standard-4` с чистым
Debian 13, прогоняет `up`, повторный `up`, перезагрузку, отказные сценарии и `down`, пишет время
этапов в отчёт и удаляет машину. Его запускают перед релизом репозитория и при изменении
`config/versions.env`, `values/` или `charts/`.
