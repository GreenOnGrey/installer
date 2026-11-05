#!/usr/bin/env bash
# ssh-setup.sh — SSH access to the production machine (DEPLOY_TRANSPORT=ssh).
# Host key checking stays on: the fingerprint comes from the secret PROD_KNOWN_HOSTS.
# Environment: PROD_HOST, PROD_USER, PROD_SSH_KEY, PROD_KNOWN_HOSTS; SSH_DIR (default: ~/.ssh).
set -euo pipefail
dir=${SSH_DIR:-$HOME/.ssh}

# All missing settings at once, with a hint on where to set them.
missing=()
[[ -n ${PROD_HOST:-} ]] || missing+=("PROD_HOST (secret)")
[[ -n ${PROD_USER:-} ]] || missing+=("PROD_USER (variable)")
[[ -n ${PROD_SSH_KEY:-} ]] || missing+=("PROD_SSH_KEY (secret)")
[[ -n ${PROD_KNOWN_HOSTS:-} ]] || missing+=("PROD_KNOWN_HOSTS (secret; connecting without a host fingerprint is forbidden)")
if ((${#missing[@]})); then
  {
    echo "::error::production access settings are missing: $(
      IFS=,
      echo "${missing[*]}"
    )"
    echo "Set them in Settings → Environments → production (variables in the tab Variables, secrets in Secrets)."
    echo "Repository-level settings also work; the job does not see settings of another environment."
  } >&2
  exit 1
fi
mkdir -p "$dir"
chmod 700 "$dir" 2>/dev/null || true
umask 077
# \r from secrets pasted on Windows breaks key parsing.
printf '%s\n' "$PROD_SSH_KEY" | tr -d '\r' >"$dir/deploy_key"
printf '%s\n' "$PROD_KNOWN_HOSTS" | tr -d '\r' >"$dir/deploy_known_hosts"

# Diagnostics: the key is readable, and its public part can be compared with
# ~/.ssh/authorized_keys of the user on the machine.
if ! pub=$(ssh-keygen -y -P '' -f "$dir/deploy_key" 2>/dev/null); then
  echo "::error::PROD_SSH_KEY cannot be read as an OpenSSH private key without a passphrase (the whole file with BEGIN/END is required)" >&2
  exit 1
fi
echo "Rollout key: $(ssh-keygen -lf - <<<"$pub")"
echo "Its public part must be in ~$PROD_USER/.ssh/authorized_keys on $PROD_HOST:"
echo "  $pub"
if [[ $PROD_USER == *@* ]]; then
  echo "::warning::PROD_USER '$PROD_USER' contains @: it must be a Linux user name on the machine (such as deploy), not an address"
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
