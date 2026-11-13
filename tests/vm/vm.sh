#!/usr/bin/env bash
# shellcheck disable=SC2029,SC2016,SC2015 # commands for the machine are built here on purpose
# A real machine of a supported OS under KVM (FTR.INFRA.INST-0001 R9, TGT-02, TGT-03, TGT-05, TGT-12, TGT-13):
# a cloud image of Rocky with SELinux enforcing and firewalld running, or of Ubuntu LTS with ufw on.
#
#   tests/vm/vm.sh <rocky|ubuntu> <release> forward   # conflicts, dependencies, forwarding of ports (about 4 GB of memory)
#   tests/vm/vm.sh <rocky|ubuntu> <release> full      # also up, the checks and a reboot (about 15 GB of memory)
#
# Releases: rocky 9, 10; ubuntu 24.04, 26.04. Needs qemu-system-x86_64, qemu-img, genisoimage, and /dev/kvm.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OS=${1:?rocky or ubuntu}
RELEASE=${2:?the release: 9, 10, 24.04, 26.04}
MODE=${3:?forward or full}
WORK=${VM_WORK:-$ROOT/.work/vm-$OS-$RELEASE}
SSH_PORT=${VM_SSH_PORT:-2222}
HTTP_PORT=${VM_HTTP_PORT:-8080}
MEMORY=${VM_MEMORY:-$([[ $MODE == full ]] && echo 15000 || echo 4000)}
CPUS=${VM_CPUS:-4}
WHOAMI_IMAGE=traefik/whoami:v1.11.0
mkdir -p "$WORK"

case $OS:$RELEASE in
  rocky:9 | rocky:10)
    IMAGE_BASE=https://dl.rockylinux.org/pub/rocky/$RELEASE/images/x86_64
    IMAGE_NAME=Rocky-$RELEASE-GenericCloud-Base.latest.x86_64.qcow2
    image_sha() { curl -fsSL --retry 5 "$IMAGE_BASE/CHECKSUM" | sed -n "s/^SHA256 ($IMAGE_NAME) = //p"; }
    ;;
  ubuntu:24.04 | ubuntu:26.04)
    suite=$([[ $RELEASE == 24.04 ]] && echo noble || echo resolute)
    IMAGE_BASE=https://cloud-images.ubuntu.com/$suite/current
    IMAGE_NAME=$suite-server-cloudimg-amd64.img
    image_sha() { curl -fsSL --retry 5 "$IMAGE_BASE/SHA256SUMS" | sed -n "s/^\([0-9a-f]*\) \*$IMAGE_NAME\$/\1/p"; }
    ;;
  *) echo "unknown machine: $OS $RELEASE" >&2; exit 2 ;;
esac

log() { echo "=== $*"; }
pass() { echo "✓ $*"; }
fail() {
  echo "✗ $*" >&2
  on_vm 'sudo ausearch -m avc -ts boot 2>/dev/null | tail -20
    for u in docker containerd greenongrey-ingress-forward greenongrey-stand; do sudo journalctl -u "$u" --no-pager -n 25 2>/dev/null; done
    sudo firewall-cmd --list-all 2>/dev/null; sudo ufw status verbose 2>/dev/null; sudo iptables -S FORWARD 2>/dev/null
    uname -r; sudo lsmod | grep -E "ip_tables|iptable|nf_tables|br_netfilter" | head' >&2 || true
  exit 1
}

key=$WORK/key
[[ -f $key ]] || ssh-keygen -q -t ed25519 -N '' -f "$key"
# The host key is ours, passed through cloud-init, so the machine is checked like any other.
host_key=$WORK/host_key
[[ -f $host_key ]] || ssh-keygen -q -t ed25519 -N '' -f "$host_key"
echo "[127.0.0.1]:$SSH_PORT $(cat "$host_key.pub")" >"$WORK/known_hosts"
SSH_OPTS=(-i "$key" -o "UserKnownHostsFile=$WORK/known_hosts" -o LogLevel=ERROR -o ConnectTimeout=5 -p "$SSH_PORT")
on_vm() { ssh "${SSH_OPTS[@]}" tester@127.0.0.1 "$@"; }
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
  log "downloading $IMAGE_NAME"
  curl -fsSL --retry 5 "$IMAGE_BASE/$IMAGE_NAME" -o "$image.tmp"
  want=$(image_sha)
  [[ -n $want && $(sha256sum "$image.tmp" | cut -d' ' -f1) == "$want" ]] || { echo "the checksum of the image does not match" >&2; exit 1; }
  mv "$image.tmp" "$image"
fi
disk=$WORK/disk.qcow2
rm -f "$disk"
qemu-img create -q -f qcow2 -F qcow2 -b "$image" "$disk" 100G
cat >"$WORK/user-data" <<EOF
#cloud-config
users:
  - name: tester
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat "$key.pub")"]
growpart: { mode: auto, devices: ["/"] }
ssh_keys:
  ed25519_public: "$(cat "$host_key.pub")"
  ed25519_private: |
$(sed 's/^/    /' "$host_key")
EOF
echo "instance-id: vm-$OS-$RELEASE" >"$WORK/meta-data"
genisoimage -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock "$WORK/user-data" "$WORK/meta-data"

log "starting $OS $RELEASE: $MEMORY MB, $CPUS CPU"
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
CHECK_HOST="$RUN bash -c 'source ./installer; COLOR=0; setup_color; load_config \"\$PWD\" /dev/null; check_host'"

# state_ok — what the machine keeps through the run: SELinux enforcing on Rocky, ufw active on Ubuntu.
if [[ $OS == rocky ]]; then
  state_ok() { [[ $(on_vm getenforce) == Enforcing ]]; }
  STATE="SELinux enforcing"
  state_ok || fail "the image does not start with SELinux enforcing"
  on_vm 'sudo dnf install -y -q firewalld >/dev/null && sudo systemctl enable --now firewalld >/dev/null'
  [[ $(on_vm 'sudo firewall-cmd --state') == running ]] || fail "firewalld does not run"
else
  state_ok() { on_vm 'sudo ufw status' | grep -q '^Status: active'; }
  STATE="ufw active"
  on_vm 'sudo ufw allow OpenSSH >/dev/null && sudo ufw --force enable >/dev/null'
  state_ok || fail "ufw does not run"
fi

APT='sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300'
# TGT-14: Docker Engine of the distribution is used as it is: the checks pass, Docker CE does not install, nothing is held.
if [[ $OS == ubuntu ]]; then
  on_vm "$APT update -qq && $APT install -y -qq docker.io >/dev/null" || fail "docker.io did not install"
  on_vm "$RUN WORK_DIR=\$PWD/.work bash -c 'mkdir -p .work; source ./installer; COLOR=0; setup_color; load_config \"\$PWD\" /dev/null; check_host; install_docker'" >"$WORK/host.log" 2>&1 ||
    { cat "$WORK/host.log"; fail "TGT-14: docker.io is not taken"; }
  grep -q "of the machine is used as it is" "$WORK/host.log" || { cat "$WORK/host.log"; fail "TGT-14: docker.io is not used as it is"; }
  on_vm 'dpkg -s docker.io >/dev/null 2>&1 && ! dpkg -s docker-ce >/dev/null 2>&1 && [ -z "$(apt-mark showhold)" ] && sudo docker info >/dev/null' ||
    fail "TGT-14: docker.io was replaced, held, or does not run"
  on_vm "$APT purge -y -qq docker.io containerd runc >/dev/null && $APT autoremove -y -qq >/dev/null"
  pass "TGT-14: docker.io of Ubuntu is used as it is"
fi

# TGT-05: without a Docker Engine, what docker-ce would replace stops the run and stays.
if [[ $OS == rocky ]]; then
  on_vm 'sudo dnf install -y -q podman >/dev/null'
  conflict=podman keep='rpm -q podman' remove='sudo dnf remove -y -q podman runc'
else
  on_vm "$APT install -y -qq runc >/dev/null" || fail "TGT-05: runc did not install"
  conflict=runc keep='dpkg -s runc' remove="$APT purge -y -qq runc >/dev/null"
fi
rc=0
on_vm "$CHECK_HOST" >"$WORK/host.log" 2>&1 || rc=$?
[[ $rc == 10 ]] && grep -q "$conflict.* conflicts with Docker CE" "$WORK/host.log" || { cat "$WORK/host.log"; fail "TGT-05: code $rc"; }
on_vm "$keep >/dev/null 2>&1" || fail "TGT-05: $conflict was removed"
on_vm "$remove"
pass "TGT-05: $conflict gives code 10 and stays"

# Dependencies through the code of the installer. The group docker reaches this session only through sg.
on_vm "$RUN WORK_DIR=\$PWD/.work bash -c 'mkdir -p .work; source ./installer; COLOR=0; setup_color; load_config \"\$PWD\" /dev/null; check_host; install_prereqs'" >"$WORK/prereqs.log" 2>&1 ||
  { tail -20 "$WORK/prereqs.log"; fail "dependencies did not install"; }
for tool in docker kubectl helm minikube; do on_vm "command -v $tool >/dev/null" || fail "$tool is not installed"; done
if [[ $OS == rocky ]]; then
  on_vm 'sudo dnf versionlock list 2>/dev/null | grep -q docker-ce' || fail "docker-ce is not locked"
else
  on_vm 'apt-mark showhold | grep -qx docker-ce' || fail "docker-ce is not held"
fi
state_ok || fail "$STATE did not stay"
pass "dependencies install, the versions are locked, $STATE"

# TGT-12: the real unit and script, a container in place of Traefik in a network like that of minikube.
on_vm "sudo docker network create --subnet 192.168.49.0/24 minikube >/dev/null && sudo docker run -d --name whoami --restart=always --network minikube --ip 192.168.49.200 $WHOAMI_IMAGE >/dev/null" ||
  fail "Docker does not run after the dependencies: $(on_vm 'systemctl is-enabled docker; systemctl is-active docker' 2>&1 | tr '\n' ' ')"
on_vm "$RUN WORK_DIR=\$PWD/.work bash -c 'source ./installer; COLOR=0; setup_color; load_config \"\$PWD\" /dev/null; LB_IP=192.168.49.200; install_forward'" >"$WORK/forward.log" 2>&1 ||
  { cat "$WORK/forward.log"; fail "the forwarding unit did not start"; }
if [[ $OS == rocky ]]; then
  on_vm 'sudo firewall-cmd --list-forward-ports' | grep -q 'port=80:proto=tcp:toport=80:toaddr=192.168.49.200' || fail "no forward port in firewalld"
  on_vm 'sudo firewall-cmd --permanent --list-forward-ports' | grep -q 'toaddr=192.168.49.200' || fail "the forward port is not permanent"
else
  on_vm 'sudo iptables -t nat -S PREROUTING' | grep -q -- '--to-destination 192.168.49.200' || fail "no DNAT in nat/PREROUTING"
fi
# get_client <tries> <pause> — the address the container sees; QEMU's user network shows the client as 10.0.2.2,
# masquerading would show the address of the bridge.
get_client() {
  local answer="" n
  for ((n = 0; n < $1; n++)); do
    answer=$(curl -sS -m 10 "http://127.0.0.1:$HTTP_PORT/" 2>/dev/null || true)
    [[ -n $answer ]] && break
    sleep "$2"
  done
  sed -n 's/^RemoteAddr: \([0-9.]*\):.*/\1/p' <<<"$answer"
}
client=$(get_client 6 5)
[[ -n $client ]] || fail "TGT-12: port 80 of the machine does not reach the container"
[[ $client == 10.0.2.2 ]] || fail "TGT-12: the container sees $client, not the client"
pass "TGT-12: port 80 reaches the container, which sees the client $client ($STATE)"

if [[ $OS == rocky ]]; then
  on_vm 'sudo firewall-cmd --reload >/dev/null'
  curl -sS -m 15 -o /dev/null "http://127.0.0.1:$HTTP_PORT/" || fail "the forwarding is lost after a reload of firewalld"
  pass "the forwarding survives a reload of firewalld"
  if on_vm 'sudo ausearch -m avc -ts boot 2>/dev/null' | grep -E 'ingress-forward|stand-autostart' >"$WORK/avc.log"; then
    cat "$WORK/avc.log"
    fail "SELinux denied the scripts of the installer"
  fi
  pass "no SELinux denial of the scripts of the installer"
else
  on_vm 'sudo ufw reload >/dev/null'
  curl -sS -m 15 -o /dev/null "http://127.0.0.1:$HTTP_PORT/" || fail "the forwarding is lost after a reload of ufw"
  pass "the forwarding survives a reload of ufw"
fi

# TGT-03: the forwarding comes back after a reboot.
on_vm 'sudo systemctl reboot' || true
sleep 30
wait_vm
state_ok || fail "$STATE did not stay after a reboot"
client=$(get_client 12 10)
[[ $client == 10.0.2.2 ]] || fail "TGT-03: after a reboot port 80 gives '$client', not the client"
pass "TGT-03: after a reboot port 80 reaches the container, which sees the client ($STATE)"

if [[ $MODE == forward ]]; then exit 0; fi

# TGT-02, TGT-13: up and the checks; TGT-03: the stand comes back after a reboot.
on_vm 'sudo systemctl disable --now greenongrey-ingress-forward >/dev/null; sudo rm -f /etc/systemd/system/greenongrey-ingress-forward.service; sudo systemctl daemon-reload; sudo docker rm -f whoami >/dev/null; sudo docker network rm minikube >/dev/null'
FULL="HOST_MIN_MEMORY_GB=10 HOST_MIN_DISK_GB=20 MK_MEMORY=11g MK_CPUS=3 OBSERVABILITY=false PRODUCTS="
on_vm "cd installer && env $FULL bash ./installer up --no-color" >"$WORK/up.log" 2>&1 || { tail -30 "$WORK/up.log"; fail "up failed"; }
state_ok || fail "$STATE did not stay after up"
on_vm "cd installer && env $FULL sg docker -c 'bash ./installer status --json --no-color'" 2>/dev/null | jq -e '.ok' >/dev/null || fail "the checks did not pass"
pass "up and the checks pass on $OS $RELEASE, $STATE"

on_vm 'sudo systemctl reboot' || true
sleep 30
wait_vm
on_vm 'n=0; until systemctl is-active --quiet greenongrey-stand; do n=$((n+1)); [ $n -lt 120 ] || exit 1; sleep 10; done' || fail "TGT-03: the stand did not come back"
state_ok || fail "TGT-03: $STATE did not stay after a reboot with the stand"
on_vm "cd installer && env $FULL bash ./installer status --json --no-color" 2>/dev/null | jq -e '.ok' >/dev/null || fail "TGT-03: the checks did not pass after a reboot"
pass "TGT-03: after a reboot the cluster came back without up"
