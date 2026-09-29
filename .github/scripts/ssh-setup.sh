#!/usr/bin/env bash
# ssh-setup.sh — доступ к машине прода по SSH (DEPLOY_TRANSPORT=ssh).
# Проверка ключа хоста не отключается: отпечаток — из секрета PROD_KNOWN_HOSTS.
# Окружение: PROD_HOST, PROD_USER, PROD_SSH_KEY, PROD_KNOWN_HOSTS; SSH_DIR (по умолчанию ~/.ssh).
set -euo pipefail
dir=${SSH_DIR:-$HOME/.ssh}
: "${PROD_HOST:?не задан PROD_HOST}" "${PROD_USER:?не задан PROD_USER}"
if [[ -z ${PROD_SSH_KEY:-} ]]; then
  echo "::error::не задан секрет PROD_SSH_KEY" >&2
  exit 1
fi
if [[ -z ${PROD_KNOWN_HOSTS:-} ]]; then
  echo "::error::не задан секрет PROD_KNOWN_HOSTS: без отпечатка хоста подключение запрещено" >&2
  exit 1
fi
mkdir -p "$dir"
chmod 700 "$dir" 2>/dev/null || true
umask 077
printf '%s\n' "$PROD_SSH_KEY" >"$dir/deploy_key"
printf '%s\n' "$PROD_KNOWN_HOSTS" >"$dir/deploy_known_hosts"
cat >"$dir/config" <<EOF
Host prod
  HostName $PROD_HOST
  User $PROD_USER
  IdentityFile $dir/deploy_key
  IdentitiesOnly yes
  UserKnownHostsFile $dir/deploy_known_hosts
  StrictHostKeyChecking yes
  ServerAliveInterval 30
  ServerAliveCountMax 10
EOF
