#!/usr/bin/env bash
# shellcheck disable=SC2029,SC2016,SC2015 # commands for the machine are built here on purpose
# A real machine with RHEL's relatives (FTR.INFRA.INST-0001 R9, TGT-02, TGT-03, TGT-05, TGT-12): a Rocky cloud
# image under KVM, SELinux enforcing and firewalld running.
#
#   tests/el/el.sh <9|10> forward   # conflicts, dependencies, forwarding of ports (about 4 GB of memory)
#   tests/el/el.sh <9|10> full      # also up, the checks and a reboot (about 15 GB of memory)
#
# Needs qemu-system-x86_64, qemu-img, genisoimage, and /dev/kvm.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RELEASE=${1:?9 or 10}
MODE=${2:?forward or full}
WORK=${EL_WORK:-$ROOT/.work/el-$RELEASE}
SSH_PORT=${EL_SSH_PORT:-2222}
HTTP_PORT=${EL_HTTP_PORT:-8080}
MEMORY=${EL_MEMORY:-$([[ $MODE == full ]] && echo 15000 || echo 4000)}
CPUS=${EL_CPUS:-4}
WHOAMI_IMAGE=traefik/whoami:v1.11.0
mkdir -p "$WORK"

log() { echo "=== $*"; }
pass() { echo "✓ $*"; }
fail() {
  echo "✗ $*" >&2
  on_vm 'sudo ausearch -m avc -ts boot 2>/dev/null | tail -20
    for u in docker containerd greenongrey-ingress-forward greenongrey-stand; do sudo journalctl -u "$u" --no-pager -n 25 2>/dev/null; done
    sudo firewall-cmd --list-all; uname -r; sudo lsmod | grep -E "ip_tables|iptable|nf_tables|br_netfilter" | head' >&2 || true
  exit 1
}

key=$WORK/key
[[ -f $key ]] || ssh-keygen -q -t ed25519 -N '' -f "$key"
# The host key is ours, passed through cloud-init, so the machine is checked like any other.
host_key=$WORK/host_key
[[ -f $host_key ]] || ssh-keygen -q -t ed25519 -N '' -f "$host_key"
echo "[127.0.0.1]:$SSH_PORT $(cat "$host_key.pub")" >"$WORK/known_hosts"
SSH_OPTS=(-i "$key" -o "UserKnownHostsFile=$WORK/known_hosts" -o LogLevel=ERROR -o ConnectTimeout=5 -p "$SSH_PORT")
on_vm() { ssh "${SSH_OPTS[@]}" rocky@127.0.0.1 "$@"; }
wait_vm() {
  local n
  for ((n = 0; n < 90; n++)); do
    if on_vm true 2>/dev/null; then return 0; fi
    sleep 5
  done
  echo "the machine did not answer over SSH" >&2
  return 1
}

image=$WORK/base.qcow2
if [[ ! -f $image ]]; then
  log "downloading Rocky $RELEASE"
  base=https://dl.rockylinux.org/pub/rocky/$RELEASE/images/x86_64
  curl -fsSL --retry 5 "$base/Rocky-$RELEASE-GenericCloud-Base.latest.x86_64.qcow2" -o "$image.tmp"
  want=$(curl -fsSL --retry 5 "$base/CHECKSUM" | sed -n "s/^SHA256 (Rocky-$RELEASE-GenericCloud-Base.latest.x86_64.qcow2) = //p")
  [[ $(sha256sum "$image.tmp" | cut -d' ' -f1) == "$want" ]] || { echo "the checksum of the image does not match" >&2; exit 1; }
  mv "$image.tmp" "$image"
fi
disk=$WORK/disk.qcow2
rm -f "$disk"
qemu-img create -q -f qcow2 -F qcow2 -b "$image" "$disk" 100G
cat >"$WORK/user-data" <<EOF
#cloud-config
users:
  - name: rocky
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat "$key.pub")"]
growpart: { mode: auto, devices: ["/"] }
ssh_keys:
  ed25519_public: "$(cat "$host_key.pub")"
  ed25519_private: |
$(sed 's/^/    /' "$host_key")
EOF
echo "instance-id: el-$RELEASE" >"$WORK/meta-data"
genisoimage -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock "$WORK/user-data" "$WORK/meta-data"

log "starting Rocky $RELEASE: $MEMORY MB, $CPUS CPU"
qemu-system-x86_64 -enable-kvm -cpu host -m "$MEMORY" -smp "$CPUS" -display none -daemonize \
  -pidfile "$WORK/qemu.pid" -serial "file:$WORK/serial.log" \
  -drive "file=$disk,if=virtio" -drive "file=$WORK/seed.iso,if=virtio,format=raw,readonly=on" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$HTTP_PORT-:80" -device virtio-net-pci,netdev=n0
cleanup() { if [[ ${KEEP:-0} != 1 && -f $WORK/qemu.pid ]]; then kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true; fi; }
trap cleanup EXIT
wait_vm
on_vm 'cloud-init status --wait >/dev/null 2>&1 || true'

git -C "$ROOT" ls-files -z --cached --others --exclude-standard | tar -C "$ROOT" --null -T - -czf - | on_vm 'mkdir -p installer && tar -xzf - -C installer'
# The machine is smaller than the minimum of the stand, on purpose: the checks of size are not what this tests.
ENVS="HOST_MIN_MEMORY_GB=3 HOST_MIN_DISK_GB=20 HOST_MIN_CPUS=2"
RUN="cd installer && env $ENVS"

[[ $(on_vm getenforce) == Enforcing ]] || fail "the image does not start with SELinux enforcing"
on_vm 'sudo dnf install -y -q firewalld >/dev/null && sudo systemctl enable --now firewalld >/dev/null'
[[ $(on_vm 'sudo firewall-cmd --state') == running ]] || fail "firewalld does not run"

# TGT-05
on_vm 'sudo dnf install -y -q podman >/dev/null'
rc=0
on_vm "$RUN bash -c 'source ./installer; COLOR=0; setup_color; load_config \"\$PWD\" /dev/null; check_host'" >"$WORK/host.log" 2>&1 || rc=$?
[[ $rc == 10 ]] && grep -q "podman conflicts with Docker CE" "$WORK/host.log" || { cat "$WORK/host.log"; fail "TGT-05: code $rc"; }
on_vm 'rpm -q podman >/dev/null' || fail "TGT-05: podman was removed"
on_vm 'sudo dnf remove -y -q podman runc >/dev/null'
pass "TGT-05: podman gives code 10 and stays"

# Dependencies through the code of the installer. The group docker reaches this session only through sg.
on_vm "$RUN WORK_DIR=\$PWD/.work bash -c 'mkdir -p .work; source ./installer; COLOR=0; setup_color; load_config \"\$PWD\" /dev/null; check_host; install_prereqs'" >"$WORK/prereqs.log" 2>&1 ||
  { tail -20 "$WORK/prereqs.log"; fail "dependencies did not install"; }
for tool in docker kubectl helm minikube; do on_vm "command -v $tool >/dev/null" || fail "$tool is not installed"; done
on_vm 'sudo dnf versionlock list 2>/dev/null | grep -q docker-ce' || fail "docker-ce is not locked"
[[ $(on_vm getenforce) == Enforcing ]] || fail "SELinux left enforcing"
pass "dependencies install, the versions are locked, SELinux stays enforcing"

# TGT-12: the real unit and script, a container in place of Traefik in a network like that of minikube.
on_vm "sudo docker network create --subnet 192.168.49.0/24 minikube >/dev/null; sudo docker run -d --name whoami --restart=always --network minikube --ip 192.168.49.200 $WHOAMI_IMAGE >/dev/null"
on_vm "$RUN WORK_DIR=\$PWD/.work bash -c 'source ./installer; COLOR=0; setup_color; load_config \"\$PWD\" /dev/null; LB_IP=192.168.49.200; install_forward'" >"$WORK/forward.log" 2>&1 ||
  { cat "$WORK/forward.log"; fail "the forwarding unit did not start"; }
on_vm 'sudo firewall-cmd --list-forward-ports' | grep -q 'port=80:proto=tcp:toport=80:toaddr=192.168.49.200' || fail "no forward port in firewalld"
on_vm 'sudo firewall-cmd --permanent --list-forward-ports' | grep -q 'toaddr=192.168.49.200' || fail "the forward port is not permanent"
answer=""
for _ in 1 2 3 4 5 6; do
  answer=$(curl -sS -m 10 "http://127.0.0.1:$HTTP_PORT/" || true)
  [[ -n $answer ]] && break
  sleep 5
done
[[ -n $answer ]] || fail "TGT-12: port 80 of the machine does not reach the container"
client=$(sed -n 's/^RemoteAddr: \([0-9.]*\):.*/\1/p' <<<"$answer")
# QEMU's user network shows the client as 10.0.2.2; masquerading would show the address of the bridge.
[[ $client == 10.0.2.2 ]] || fail "TGT-12: the container sees $client, not the client"
pass "TGT-12: port 80 reaches the container, which sees the client $client"

on_vm 'sudo firewall-cmd --reload >/dev/null'
curl -sS -m 15 -o /dev/null "http://127.0.0.1:$HTTP_PORT/" || fail "the forwarding is lost after a reload of firewalld"
pass "the forwarding survives a reload of firewalld"
if on_vm 'sudo ausearch -m avc -ts boot 2>/dev/null' | grep -E 'ingress-forward|stand-autostart' >"$WORK/avc.log"; then
  cat "$WORK/avc.log"
  fail "SELinux denied the scripts of the installer"
fi
pass "no SELinux denial of the scripts of the installer"

# TGT-03: the forwarding comes back after a reboot, with SELinux enforcing.
on_vm 'sudo systemctl reboot' || true
sleep 30
wait_vm
[[ $(on_vm getenforce) == Enforcing ]] || fail "SELinux left enforcing after a reboot"
answer=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  answer=$(curl -sS -m 10 "http://127.0.0.1:$HTTP_PORT/" 2>/dev/null || true)
  [[ -n $answer ]] && break
  sleep 10
done
client=$(sed -n 's/^RemoteAddr: \([0-9.]*\):.*/\1/p' <<<"$answer")
[[ $client == 10.0.2.2 ]] || fail "TGT-03: after a reboot port 80 gives '$client', not the client"
pass "TGT-03: after a reboot port 80 reaches the container, which sees the client"

if [[ $MODE == forward ]]; then exit 0; fi

# TGT-02, TGT-03
on_vm 'sudo systemctl disable --now greenongrey-ingress-forward >/dev/null; sudo rm -f /etc/systemd/system/greenongrey-ingress-forward.service; sudo systemctl daemon-reload; sudo docker rm -f whoami >/dev/null; sudo docker network rm minikube >/dev/null'
FULL="HOST_MIN_MEMORY_GB=10 HOST_MIN_DISK_GB=20 MK_MEMORY=11g MK_CPUS=3 OBSERVABILITY=false"
on_vm "cd installer && env $FULL bash ./installer up --no-color" >"$WORK/up.log" 2>&1 || { tail -30 "$WORK/up.log"; fail "TGT-02: up failed"; }
[[ $(on_vm getenforce) == Enforcing ]] || fail "TGT-02: SELinux left enforcing"
on_vm "cd installer && env $FULL sg docker -c 'bash ./installer status --json --no-color'" 2>/dev/null | jq -e '.ok' >/dev/null || fail "TGT-02: the checks did not pass"
pass "TGT-02: up and the checks pass, SELinux enforcing"

on_vm 'sudo systemctl reboot' || true
sleep 30
wait_vm
on_vm 'n=0; until systemctl is-active --quiet greenongrey-stand; do n=$((n+1)); [ $n -lt 120 ] || exit 1; sleep 10; done' || fail "TGT-03: the stand did not come back"
on_vm "cd installer && env $FULL bash ./installer status --json --no-color" 2>/dev/null | jq -e '.ok' >/dev/null || fail "TGT-03: the checks did not pass after a reboot"
pass "TGT-03: after a reboot the cluster came back without up"
