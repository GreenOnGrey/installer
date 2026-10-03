# Hammurapi на демо-стенде: публичный доступ, сборка и выкатка

Спецификация — `PLT.INFRA-0002`. Стенд `PLT.INFRA-0001` публикует web, API и Grafana по
HTTPS, а `hammurapi-core` и `hammurapi-web` выпускаются и выкатываются на него своими
пайплайнами — от тега до работающей версии, без ручных шагов на сервере.

```text
тег vX.Y.Z в hammurapi-core / hammurapi-web
  lint ∥ test → build (ghcr.io, SBOM, provenance, подпись cosign) → scan (Trivy)
  → deploy-component.yml (hammurapi) → hammurapi-deploy на машине → проверки по доменам

браузер, GitHub ──HTTPS──▶ :80/:443 машины ──iptables──▶ MetalLB ─▶ Traefik
  web.<домен>     → web
  api.<домен>     → api: /api/, /admin/api/, /hooks/
  grafana.<домен> → Grafana (вход через GitHub для участников организации)
```

## 1. Публичный доступ стенда

### 1.1 Межсетевой экран Google Cloud

Снаружи нужны только TCP 80 и 443. SSH — через IAP или с доверенных адресов.

```sh
gcloud compute firewall-rules create hammurapi-web --network "$VPC" \
  --direction INGRESS --action allow --rules tcp:80,tcp:443 \
  --target-tags hammurapi-public --source-ranges 0.0.0.0/0
gcloud compute instances add-tags hammurapi --zone "$ZONE" --tags hammurapi-public
```

Служебные порты (`:9100`, `:8081`) наружу не открываются: Traefik маршрутизирует только
перечисленные домены и пути.

### 1.2 OAuth-приложение GitHub для Grafana

1. Organization settings → Developer settings → OAuth Apps → New OAuth App:
   - Homepage URL: `https://grafana.<базовый домен>`;
   - Authorization callback URL: `https://grafana.<базовый домен>/login/github`.
2. Сгенерируйте client secret. На проде задайте в `hammurapi-infra` (окружение `production` или
   уровень репозитория) переменную `GRAFANA_GITHUB_CLIENT_ID` и секрет
   `GRAFANA_GITHUB_CLIENT_SECRET`; при желании — переменную `GRAFANA_GITHUB_ORG` (по умолчанию
   `GreenOnGrey`). `deploy-prod` передаёт их в `up` через stdin SSH-сессии: на диск машины и в
   argv они не попадают, Grafana получает их через секрет Kubernetes `grafana-github-oauth`.
   Применяются следующей выкаткой тега. Ручной `up` на машине берёт их из `local.env`: client ID
   — строкой, секрет — файлом (`GRAFANA_GITHUB_CLIENT_SECRET_FILE`, права `600`); без них такой
   `up` выключит вход через GitHub до следующей выкатки.
3. Organization settings → Third-party access → OAuth app policy: разрешите приложению доступ
   к организации. Иначе Grafana не видит членство, и вход отклоняется.

### 1.3 Конфигурация стенда

На проде параметры публичного доступа задаются переменными GitHub репозитория
`hammurapi-infra` (окружение `production` или уровень репозитория) — так же, как вход в Grafana
(п. 1.2): `deploy-prod` передаёт их в `up` через stdin, значения из GitHub важнее `local.env`.

| Переменная | Значение |
|---|---|
| `PUBLIC_ACCESS` | `true` |
| `ACME_EMAIL` | адрес для уведомлений Let's Encrypt (обязателен при `PUBLIC_ACCESS=true`) |
| `ACME_ISSUER` | `letsencrypt` (по умолчанию) или `letsencrypt-staging` — для проб |
| `PUBLIC_BASE_DOMAIN` | пусто — `<внешний IP с дефисами>.sslip.io` |
| `PUBLIC_IP` | пусто — определяется автоматически |

Ручной `up` на машине этих значений не получает и берёт их из `local.env`. Если их там нет,
такой `up` пропустит шаг `public`; уже развёрнутые Traefik и сертификат останутся.

`/opt/hammurapi-infra/local.env` (или `config/local.env` рабочей копии) для ручного `up`:

```bash
PUBLIC_ACCESS=true
ACME_EMAIL=ops@example.org
# PUBLIC_BASE_DOMAIN=            # пусто — <внешний IP с дефисами>.sslip.io
# ACME_ISSUER=letsencrypt-staging  # для проб: не тратит лимиты Let's Encrypt
# Вход в Grafana через GitHub: на проде — из GitHub (п. 1.2), здесь — для ручного up.
# GRAFANA_GITHUB_CLIENT_ID=Ov23li…
# GRAFANA_GITHUB_CLIENT_SECRET_FILE=/secure/grafana-github-secret
# GRAFANA_GITHUB_ORG=GreenOnGrey
```

Следующий `up` (или выкатка тега `hammurapi-infra`) добавляет шаг `public`:

1. MetalLB (дополнение minikube) с пулом `<подсеть minikube>.200–.209`.
2. cert-manager и `ClusterIssuer` `letsencrypt` и `letsencrypt-staging` (HTTP-01 через Traefik).
3. Traefik в namespace `ingress`: сервис `LoadBalancer`, HTTP → HTTPS, сертификат по
   умолчанию `hammurapi-public`.
4. Один сертификат на `web.`, `api.`, `grafana.<домен>`: выпускается один раз и продлевается
   cert-manager.
5. Ingress Grafana и вход через GitHub: участники организации — роль Editor, остальным вход
   запрещён; локальный администратор (`creds`) остаётся для экстренного доступа.
6. systemd-юнит `hammurapi-ingress-forward`: правила iptables пробрасывают 80/443 внешнего
   интерфейса на адрес Traefik. Правила восстанавливаются после перезагрузки машины и
   перезапуска Docker, дублей не создают.

`up` проверяет, что `https://grafana.<домен>` отвечает с сертификатом от `ACME_ISSUER`, а HTTP
перенаправляет на HTTPS. Сводка и `status --json` показывают домен и адрес Traefik.

**Домен.** По умолчанию — бесплатный `<IP>.sslip.io`, регистрировать ничего не нужно. Если
лимиты Let's Encrypt для `sslip.io` исчерпаны, заведите поддомен DuckDNS
(`<имя>.duckdns.org` с A-записью на внешний IP) и задайте `PUBLIC_BASE_DOMAIN`. Код не меняется.

SSH-туннель к Grafana из `PLT.INFRA-0001` остаётся резервным способом.

## 2. GitHub App Hammurapi и репозиторий спецификаций

1. Создайте репозиторий спецификаций, например `GreenOnGrey/hammurapi-spec`, и скопируйте в
   него `rules/` из репозитория `hammurapi`.
2. Organization settings → Developer settings → GitHub Apps → New GitHub App:
   - Callback URL: `https://api.<базовый домен>/api/v1/auth/callback`;
   - Expire user authorization tokens — включено;
   - Webhook — включён, адрес любой: выкатка core сама пропишет
     `https://api.<домен>/hooks/v1/git` и секрет;
   - Repository permissions: Contents — Read and write, Pull requests — Read and write,
     Issues — Read and write, Metadata — Read, Actions — Read and write;
   - Subscribe to events: Push, Pull request, Pull request review, Pull request review comment,
     Issue comment.
3. Сгенерируйте private key и client secret. Установите приложение на `hammurapi-spec` и на
   репозитории сервисов.

## 3. Конфигурация в GitHub

Вся конфигурация Hammurapi — в секретах и переменных **организации**, доступных только
`hammurapi-core` и `hammurapi-web` (Organization settings → Secrets and variables → Actions →
Repository access: selected). В git она не хранится.

**Переменные:**

| Имя | Значение |
|---|---|
| `DEPLOY_TRANSPORT` | `ssh` или `gcp-iap` |
| `PROD_HOST`, `PROD_USER` | адрес машины и пользователь выкатки (`ssh`) |
| `GCP_PROJECT`, `GCP_ZONE`, `GCP_INSTANCE`, `GCP_WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT` | для `gcp-iap` |
| `HAMMURAPI_GITHUB_APP_ID`, `HAMMURAPI_GITHUB_CLIENT_ID` | GitHub App |
| `HAMMURAPI_SPEC_REPO` | `GreenOnGrey/hammurapi-spec` |
| `HAMMURAPI_BOOTSTRAP_ADMINS` | логин владельца стенда — первый глобальный администратор |
| `AUTO_DEPLOY` | `false` — выкатку по тегу ведёт Hammurapi (R23); сборка и сканирование продолжаются |

**Секреты:**

| Имя | Значение |
|---|---|
| `PROD_SSH_KEY`, `PROD_KNOWN_HOSTS` | доступ по SSH (`ssh-keyscan -t ed25519 <адрес>`) |
| `HAMMURAPI_GITHUB_APP_PRIVATE_KEY` | закрытый ключ GitHub App (PEM целиком) |
| `HAMMURAPI_GITHUB_CLIENT_SECRET`, `HAMMURAPI_WEBHOOK_SECRET` | GitHub App |
| `HAMMURAPI_TOKEN_ENCRYPTION_KEY` | `openssl rand -base64 32`; менять нельзя без `allow_key_rotation` |
| `HAMMURAPI_BOOTSTRAP_DEEPSEEK_API_KEY` | необязательный: ключ DeepSeek для первого подключения к LLM; дальше подключения и модели — в «Администрирование → Агент» (PLT.HMR-0004) |
| `HAMMURAPI_GHCR_PULL_TOKEN` | classic PAT с `read:packages`: образы и чарты на машине |
| `HAMMURAPI_DEPLOY_CALLBACK_SECRET` | секрет вебхука выкатки окружения `production` в Hammurapi (Администрирование → Деплой) |

В каждом из двух репозиториев — окружение `production` (Settings → Environments) с правилами
выкатки: разрешённые теги `v*.*.*`, при желании ревьюеры. Своих значений в нём нет.

Переиспользуемый workflow `deploy-component.yml` лежит в публичном репозитории `hammurapi`:
workflow приватного `hammurapi-infra` нельзя вызвать из публичных `hammurapi-core` и
`hammurapi-web`. Настраивать доступ к нему не нужно.

## 4. Релизы и выкатка

1. Тег релиза `vX.Y.Z` в `hammurapi-infra` запускает `deploy-prod.yml`: сначала публикуются
   чарты `oci://ghcr.io/greenongrey/charts/hammurapi-{core,web}:X.Y.Z` (версия чартов совпадает с
   версией стенда), затем, только при успехе, тег выкатывается на стенд вместе с
   `bin/hammurapi-deploy` — на машине скрипт берётся из `/opt/hammurapi-infra/current`. Ручной
   запуск с тегом (повтор или откат) уже опубликованные версии чартов не перезаписывает.
2. Тег `vX.Y.Z` в `hammurapi`, если менялся `deploy-component.yml`.
3. В `hammurapi-core` и `hammurapi-web` в `deploy/versions.env` задайте `DEPLOY_WORKFLOW_REF`
   (тег `hammurapi` из п. 2) и `CHART_VERSION` (п. 1), выполните `deploy/sync-ref.sh`.
4. Тег `vX.Y.Z` в `hammurapi-core`, затем в `hammurapi-web`.

| Что | Как |
|---|---|
| Выкатка по тегу | push тега: lint ∥ test → build → scan → deploy |
| Ручная выкатка или откат (R9) | Actions → release → Run workflow, `ref` = тег; без пересборки, с проверкой подписи |
| Запуск по контракту `PLT.HMR-0002` (R22) | Hammurapi вызывает `workflow_dispatch` с `service`, `ref`, `environment`, `run_id`, `callback_url`; вебхуки `started` и `success`/`failure` |
| Автовыкатку выключить (R23) | переменная `AUTO_DEPLOY=false` |

В Hammurapi (Администрирование → Деплой → production) для выкатки самого себя: тип
`github-actions`, workflow `release.yml`, `ref` — `{ref}`, параметры
`service={service}`, `ref={ref}`, `environment={environment}`, `run_id={run_id}`,
`callback_url={callback_url}`.

**Первая установка** — та же выкатка core. Если релиза нет, `hammurapi-deploy` создаёт
namespace `hammurapi` и `hammurapi-runners`, секреты конфигурации и `ghcr-pull`, копирует
`*-conn` из `storages`, устанавливает чарт (миграции — хуком до `api` и `worker`) и
настраивает GitHub App: адрес вебхука и секрет, проверка доступа к `hammurapi-spec`. Web до
core не выкатывается: «сначала выкатите hammurapi-core».

**Агент (PLT.HMR-0004).** Чарт ставит оператор агента `agent` (по процессу Pi на сессию чата
или задачи, `:8090`), сервис `worker-mcp` (`:8083`, MCP фоновых сценариев) и сетевые политики:
к оператору — только `api`, `worker` и задачи runner, к серверу рабочей копии задачи (`:8095`) —
только оператор. Токен `AGENT_SERVICE_TOKEN` между ними `hammurapi-deploy` создаёт при первой
выкатке и сохраняет в `hammurapi-secrets`. Подключения к LLM, модели, скиллы и MCP-серверы
настраиваются в «Администрирование → Агент»; секрет `HAMMURAPI_BOOTSTRAP_DEEPSEEK_API_KEY`
создаёт первое подключение. Старый секрет `hammurapi-runner-agent` удаляется.

**Проверки после выкатки** — с раннера GitHub через публичные домены: `/api/v1/config`,
подписанный `ping` на `/hooks/v1/git` (202), закрытый `/metrics`, перенаправление HTTP →
HTTPS; для web — страница, `config.json` с адресом API и CORS. При ошибке Helm (`--atomic`)
возвращает прежнюю ревизию, диагностика прикладывается к запуску.

### Коды `hammurapi-deploy`

| Код | Причина |
|---|---|
| 17 | уже идёт выкатка этого компонента |
| 20 | стенд не готов или публичный доступ выключен |
| 21 | web без core: «сначала выкатите hammurapi-core» |
| 22 | namespace |
| 23 | секреты и конфигурация |
| 24 | изменён ключ шифрования токенов (запуск с `allow_key_rotation` — намеренно) |
| 25 | релиз Helm не развёрнут, возвращена прежняя ревизия |
| 26 | GitHub App: нет доступа к `hammurapi-spec` и ссылка на установку, нет прав, не подписан на события |
| 27 | поды не готовы |

## 5. Решения реализации (внесены в спецификацию PLT.INFRA-0002 v1.1)

- **Подпись вебхука результата** — HMAC-SHA256 тела, метка времени отдельным заголовком
  `X-Hammurapi-Timestamp`. Так проверяет `hammurapi-core` (`/hooks/v1/deploy`); в техспеке
  `INFRA-0002` указано `timestamp + "." + body`, но с такой подписью Hammurapi отклонил бы
  вебхук.
- **Линтер web** — oxlint и `tsc --noEmit` вместо ESLint: `typescript-eslint` не поддерживает
  TypeScript 7, на котором собран web.
- **Внешний IP** определяется через публичные сервисы (ipify, ifconfig.me), а не метаданные
  облака: скрипт стенда не зависит от облака (PORT-01). `PUBLIC_IP` задаёт его явно.
- **Токен реестра** нужен и для выкатки web: чарт берётся из приватного OCI-реестра.
