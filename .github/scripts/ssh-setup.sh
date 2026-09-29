#!/usr/bin/env bash
# ssh-setup.sh — доступ к машине прода по SSH (DEPLOY_TRANSPORT=ssh).
# Проверка ключа хоста не отключается: отпечаток — из секрета PROD_KNOWN_HOSTS.
# Окружение: PROD_HOST, PROD_USER, PROD_SSH_KEY, PROD_KNOWN_HOSTS; SSH_DIR (по умолчанию ~/.ssh).
set -euo pipefail
dir=${SSH_DIR:-$HOME/.ssh}

# Все пропущенные настройки сразу, с подсказкой, где их задать.
missing=()
[[ -n ${PROD_HOST:-} ]] || missing+=("PROD_HOST (переменная)")
[[ -n ${PROD_USER:-} ]] || missing+=("PROD_USER (переменная)")
[[ -n ${PROD_SSH_KEY:-} ]] || missing+=("PROD_SSH_KEY (секрет)")
[[ -n ${PROD_KNOWN_HOSTS:-} ]] || missing+=("PROD_KNOWN_HOSTS (секрет; без отпечатка хоста подключение запрещено)")
if ((${#missing[@]})); then
  {
    echo "::error::не заданы настройки доступа к проду: $(
      IFS=,
      echo "${missing[*]}"
    )"
    echo "Задайте их в Settings → Environments → production (переменные — во вкладке Variables, секреты — в Secrets)."
    echo "Настройки уровня репозитория тоже подходят; настройки другого окружения job не видит."
  } >&2
  exit 1
fi
mkdir -p "$dir"
chmod 700 "$dir" 2>/dev/null || true
umask 077
# \r из секретов, вставленных из Windows, ломает разбор ключа.
printf '%s\n' "$PROD_SSH_KEY" | tr -d '\r' >"$dir/deploy_key"
printf '%s\n' "$PROD_KNOWN_HOSTS" | tr -d '\r' >"$dir/deploy_known_hosts"

# Диагностика: ключ читается, и его открытую часть можно сравнить с
# ~/.ssh/authorized_keys пользователя на машине.
if ! pub=$(ssh-keygen -y -P '' -f "$dir/deploy_key" 2>/dev/null); then
  echo "::error::PROD_SSH_KEY не читается как закрытый ключ OpenSSH без пароля (нужен весь файл с BEGIN/END)" >&2
  exit 1
fi
echo "Ключ выкатки: $(ssh-keygen -lf - <<<"$pub")"
echo "Его открытая часть должна быть в ~$PROD_USER/.ssh/authorized_keys на $PROD_HOST:"
echo "  $pub"
if [[ $PROD_USER == *@* ]]; then
  echo "::warning::PROD_USER «$PROD_USER» содержит @ — нужно имя пользователя Linux на машине (например, deploy), а не адрес"
fi
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
