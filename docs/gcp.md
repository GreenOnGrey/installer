# Google Cloud: the stand's machine and managed storages

The stand's script uses no cloud API: everything cloud-related is set through external storage parameters in `config/local.env`. This is an example for Google Cloud. Another cloud needs only a machine with Debian 13 and the addresses and credentials of its managed services.

## Machine

`e2-standard-4` (4 vCPU, 16 GB), Debian 13, a 100 GB disk. If the stand reaches Cloud SQL or Managed Kafka through private addresses, the machine must be in the same VPC: minikube pods reach VPC addresses through the NAT of the node and the machine's Docker network.

```sh
gcloud compute instances create hammurapi-demo \
  --project "$PROJECT" --zone europe-west1-b \
  --machine-type e2-standard-4 \
  --image-family debian-13 --image-project debian-cloud \
  --boot-disk-size 100GB --boot-disk-type pd-balanced \
  --network "$VPC" --subnet "$SUBNET" \
  --metadata enable-oslogin=TRUE
```

Without public access no ports need opening, because Grafana opens through an SSH tunnel. With `PUBLIC_ACCESS=true`, open TCP 80 and 443: see [hammurapi.md](hammurapi.md#11-google-cloud-firewall).

```sh
gcloud compute ssh hammurapi-demo --zone europe-west1-b -- -L 3000:localhost:3000
git clone https://github.com/GreenOnGrey/installer.git && cd installer
./installer up
kubectl --context greenongrey -n observability port-forward svc/grafana 3000:80
```

## Cloud SQL for PostgreSQL

An instance with a private IP in the machine's VPC, the `vector` extension, and the database and user `hammurapi`. The user needs `CREATEROLE` and `CREATEDB` for the database and role of Nabu.

```bash
POSTGRES_MODE=external
POSTGRES_HOST=10.20.0.5            # private IP of the instance → a service with an EndpointSlice
POSTGRES_PORT=5432
POSTGRES_DATABASE=hammurapi
POSTGRES_USER=hammurapi
POSTGRES_PASSWORD_FILE=/secure/pg-password
POSTGRES_SSLMODE=require
```

## Managed Service for Apache Kafka

A cluster in the same VPC. Access is SASL/PLAIN with a key of a service account with the role `roles/managedkafka.client` (the username is the service account's email, the password is the JSON key in base64), or OAUTHBEARER.

```bash
KAFKA_MODE=external
KAFKA_BOOTSTRAP=bootstrap.hammurapi.europe-west1.managedkafka.PROJECT.cloud.goog:9092
KAFKA_SECURITY_PROTOCOL=SASL_SSL
KAFKA_SASL_MECHANISM=PLAIN
KAFKA_USERNAME=hammurapi-kafka@PROJECT.iam.gserviceaccount.com
KAFKA_PASSWORD_FILE=/secure/kafka-password
```

The stand's checks write and read a message in the topic `installer-probe`, so create it:

```sh
gcloud managed-kafka topics create installer-probe --cluster hammurapi \
  --location europe-west1 --partitions 1 --replication-factor 3
```

## Cloud Storage through the S3-compatible interface

Two buckets, for Hammurapi and for Nabu, and an HMAC key of a service account with access to them (`gcloud storage hmac create SA_EMAIL`). Bucket names are global, so the default `nabu` will not do.

```bash
S3_MODE=external
S3_ENDPOINT=https://storage.googleapis.com
S3_REGION=europe-west1
S3_BUCKET=hammurapi-demo
S3_BUCKET_NABU=nabu-demo
S3_ACCESS_KEY_FILE=/secure/s3-access-key
S3_SECRET_KEY_FILE=/secure/s3-secret-key
S3_PATH_STYLE=false
```

Files in `/secure/` stay outside the repository, with mode `600`. The stand does not collect metrics of managed storages, which stay in Cloud Monitoring.

## Production machine

Production is the same kind of machine, to which the workflow `deploy-prod` rolls out tags.

1. The rollout user (such as `github`, created from a key in the VM metadata) has passwordless `sudo` and owns the production directory:

   ```sh
   sudo install -d -o github -g github /opt/installer
   ```

   There is no need to clone the repository on the machine: the workflow passes an export of the tag over SSH and unpacks it into `/opt/installer/releases/<tag>` (the link `current` points to the deployed one). The machine needs no access to GitHub, because deploy keys are forbidden by the organization's policy.
2. `/opt/installer/local.env` and the secret files of external storages go on the machine once and do not change between rollouts. They are not kept in GitHub. Logs are in `/opt/installer/logs`.
3. Access from GitHub Actions, in one of these ways:
   - **`ssh`** (default, independent of a cloud): the rollout user's key in the secret `PROD_SSH_KEY`, the host fingerprint in `PROD_KNOWN_HOSTS` (`ssh-keyscan -t ed25519 <address>`), and port 22 open to GitHub runners;
   - **`gcp-iap`**: `gcloud compute ssh --tunnel-through-iap` with Workload Identity Federation. No service account keys are stored, and port 22 is closed outside, open only to the IAP range `35.235.240.0/20`. The service account needs `roles/iap.tunnelResourceAccessor`, `roles/compute.osAdminLogin` and `roles/iam.serviceAccountUser` on the machine. The rollout user is then the service account's OS Login user (`sa_<id>`), so make it the owner of `/opt/installer`.

Workload Identity Federation for the repository:

```sh
gcloud iam workload-identity-pools create github --location global
gcloud iam workload-identity-pools providers create-oidc installer --location global \
  --workload-identity-pool github --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping google.subject=assertion.sub,attribute.repository=assertion.repository \
  --attribute-condition "assertion.repository == 'GreenOnGrey/installer'"
gcloud iam service-accounts add-iam-policy-binding deploy@PROJECT.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/GreenOnGrey/installer"
```

## e2e

The workflow `e2e` uses the same sign-in (the GitHub environment `e2e`: `GCP_PROJECT`, `GCP_WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT`). The e2e service account needs rights to create and delete machines (`roles/compute.instanceAdmin.v1`) and to sign in to them (`roles/compute.osAdminLogin`, `roles/iap.tunnelResourceAccessor`).
