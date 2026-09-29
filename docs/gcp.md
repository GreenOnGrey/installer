# Google Cloud: машина стенда и managed-хранилища

Скрипт стенда не использует API облака — всё облачное задаётся параметрами внешних хранилищ в
`config/local.env`. Здесь — пример для Google Cloud. Для другого облака нужны только машина с
Debian 13 и адреса с учётными данными его managed-сервисов.

## Машина

`e2-standard-4` (4 vCPU, 16 ГБ), Debian 13, диск 100 ГБ. Если стенд будет ходить в Cloud SQL
или Managed Kafka по приватным адресам, машина должна быть в той же VPC: поды minikube выходят
к адресам VPC через NAT ноды и Docker-сети машины.

```sh
gcloud compute instances create hammurapi-demo \
  --project "$PROJECT" --zone europe-west1-b \
  --machine-type e2-standard-4 \
  --image-family debian-13 --image-project debian-cloud \
  --boot-disk-size 100GB --boot-disk-type pd-balanced \
  --network "$VPC" --subnet "$SUBNET" \
  --metadata enable-oslogin=TRUE
```

Порты наружу открывать не нужно: Grafana открывается через SSH-туннель.

```sh
gcloud compute ssh hammurapi-demo --zone europe-west1-b -- -L 3000:localhost:3000
git clone https://github.com/GeenOnGrey/hammurapi-infra.git && cd hammurapi-infra
./hammurapi-infra.sh up
kubectl --context hammurapi -n observability port-forward svc/grafana 3000:80
```

## Cloud SQL for PostgreSQL

Экземпляр с приватным IP в VPC машины, база и пользователь `hammurapi`.

```bash
POSTGRES_MODE=external
POSTGRES_HOST=10.20.0.5            # приватный IP экземпляра → сервис с EndpointSlice
POSTGRES_PORT=5432
POSTGRES_DATABASE=hammurapi
POSTGRES_USER=hammurapi
POSTGRES_PASSWORD_FILE=/secure/pg-password
POSTGRES_SSLMODE=require
```

## Managed Service for Apache Kafka

Кластер в той же VPC; доступ — SASL/PLAIN по ключу сервисного аккаунта с ролью
`roles/managedkafka.client` (логин — e-mail сервисного аккаунта, пароль — JSON-ключ в base64) или
OAUTHBEARER.

```bash
KAFKA_MODE=external
KAFKA_BOOTSTRAP=bootstrap.hammurapi.europe-west1.managedkafka.PROJECT.cloud.goog:9092
KAFKA_SECURITY_PROTOCOL=SASL_SSL
KAFKA_SASL_MECHANISM=PLAIN
KAFKA_USERNAME=hammurapi-kafka@PROJECT.iam.gserviceaccount.com
KAFKA_PASSWORD_FILE=/secure/kafka-password
```

Проверки стенда пишут и читают сообщение в топике `hammurapi-infra-probe` — создайте его:

```sh
gcloud managed-kafka topics create hammurapi-infra-probe --cluster hammurapi \
  --location europe-west1 --partitions 1 --replication-factor 3
```

## Cloud Storage через S3-совместимый интерфейс

Бакет и HMAC-ключ сервисного аккаунта с доступом к нему
(`gcloud storage hmac create SA_EMAIL`).

```bash
S3_MODE=external
S3_ENDPOINT=https://storage.googleapis.com
S3_REGION=europe-west1
S3_BUCKET=hammurapi-demo
S3_ACCESS_KEY_FILE=/secure/s3-access-key
S3_SECRET_KEY_FILE=/secure/s3-secret-key
S3_PATH_STYLE=false
```

Файлы в `/secure/` — вне репозитория, с правами `600`. Метрики managed-хранилищ стенд не
собирает — они остаются в Cloud Monitoring.

## Машина прода

Прод — такая же машина, на которую workflow `deploy-prod` выкатывает теги.

1. Пользователь выкатки (например, `github`, созданный из ключа в метаданных ВМ) — с `sudo` без
   пароля и владельцем каталога прода:

   ```sh
   sudo install -d -o github -g github /opt/hammurapi-infra
   ```

   Клонировать репозиторий на машину не нужно: workflow сам передаёт выгрузку тега по SSH и
   раскладывает её в `/opt/hammurapi-infra/releases/<тег>` (ссылка `current` — на развёрнутый).
   Доступ машины к GitHub не требуется — deploy keys запрещены политикой организации.
2. `/opt/hammurapi-infra/local.env` и файлы секретов внешних хранилищ кладутся на машину один
   раз и между выкатками не меняются; в GitHub они не хранятся. Журналы — в
   `/opt/hammurapi-infra/logs`.
3. Доступ из GitHub Actions — одним из способов:
   - **`ssh`** (по умолчанию, не зависит от облака): ключ пользователя выкатки в секрете
     `PROD_SSH_KEY`, отпечаток хоста в `PROD_KNOWN_HOSTS`
     (`ssh-keyscan -t ed25519 <адрес>`), порт 22 открыт для раннеров GitHub;
   - **`gcp-iap`**: `gcloud compute ssh --tunnel-through-iap` с Workload Identity Federation.
     Ключи сервисного аккаунта не хранятся, порт 22 наружу закрыт — открыт только для диапазона
     IAP `35.235.240.0/20`. Сервисному аккаунту нужны `roles/iap.tunnelResourceAccessor`,
     `roles/compute.osAdminLogin` и `roles/iam.serviceAccountUser` на машине. Пользователь выкатки
     в этом случае — OS Login-пользователь сервисного аккаунта (`sa_<id>`): сделайте его
     владельцем `/opt/hammurapi-infra`.

Workload Identity Federation для репозитория:

```sh
gcloud iam workload-identity-pools create github --location global
gcloud iam workload-identity-pools providers create-oidc hammurapi-infra --location global \
  --workload-identity-pool github --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping google.subject=assertion.sub,attribute.repository=assertion.repository \
  --attribute-condition "assertion.repository == 'GeenOnGrey/hammurapi-infra'"
gcloud iam service-accounts add-iam-policy-binding deploy@PROJECT.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/GeenOnGrey/hammurapi-infra"
```

## e2e

Workflow `e2e` использует тот же способ входа (окружение GitHub `e2e`: `GCP_PROJECT`,
`GCP_WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT`). Сервисному аккаунту e2e нужны права создавать и
удалять машины (`roles/compute.instanceAdmin.v1`) и входить на них
(`roles/compute.osAdminLogin`, `roles/iap.tunnelResourceAccessor`).
