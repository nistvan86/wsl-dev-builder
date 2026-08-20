#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf '[isolation] FAILED: %s\n' "$*" >&2; exit 1; }
require() { "$@" || fail "invariant failed: $*"; }

# This validator is executed directly, not through an interactive shell. Make
# user-local tools and the provisioned nvm Node.js installation explicit.
export PATH="/home/ubuntu/.local/bin:$PATH"
for node_bin in /home/ubuntu/.nvm/versions/node/*/bin; do
  if [[ -x "$node_bin/node" ]]; then
    export PATH="$node_bin:$PATH"
    break
  fi
done

require test "$(id -un)" = ubuntu
require test "$(id -u)" = 1000
! command -v sudo >/dev/null 2>&1 || fail 'sudo executable is present'

for forbidden_group in sudo wheel docker lxd disk libvirt kvm; do
  if id -nG | tr ' ' '\n' | grep -Fxq "$forbidden_group"; then
    fail "forbidden group is present: $forbidden_group"
  fi
done

! findmnt -rn -t drvfs | grep -q . || fail 'a DrvFs filesystem is mounted'
if [[ -e /mnt/c ]] && findmnt -rn /mnt/c >/dev/null; then fail '/mnt/c is mounted'; fi
if [[ -e /mnt/d ]] && findmnt -rn /mnt/d >/dev/null; then fail '/mnt/d is mounted'; fi
for windows_executable in cmd.exe powershell.exe explorer.exe; do
  ! command -v "$windows_executable" >/dev/null 2>&1 || fail "Windows executable is available: $windows_executable"
done

mount_test=/tmp/wsl-dev-builder-mount-test
mkdir -p "$mount_test"
trap 'rmdir "$mount_test" 2>/dev/null || true' EXIT
if mount -t drvfs C: "$mount_test" 2>/dev/null; then
  fail 'manual DrvFs mount unexpectedly succeeded'
fi

for socket in /run/docker.sock /var/run/docker.sock /run/podman/podman.sock /run/containerd/containerd.sock; do
  if [[ -S "$socket" ]] && { [[ -r "$socket" ]] || [[ -w "$socket" ]]; }; then
    fail "agent can access daemon socket: $socket"
  fi
done

for privileged_path in /etc /usr /opt; do
  [[ ! -w "$privileged_path" ]] || fail "privileged path is writable: $privileged_path"
  if find "$privileged_path" -xdev \( -type f -o -type d \) -writable -print -quit | grep -q .; then
    fail "writable privileged path exists below: $privileged_path"
  fi
done

for tool in codex gh node npm bwrap; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is missing: $tool"
done

if [[ -e /mnt/wslg ]]; then
  printf '[isolation] report: /mnt/wslg exists (WSLg host integration is present)\n'
else
  printf '[isolation] report: /mnt/wslg is absent\n'
fi

probe_tcp() {
  local label="$1" host="$2" port="$3"
  if timeout 2 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1; then
    printf '[isolation] network probe: %s reachable\n' "$label"
  else
    printf '[isolation] network probe: %s unavailable\n' "$label"
  fi
}
default_gateway=$(ip route 2>/dev/null | awk '$1 == "default" { print $3; exit }' || true)
if [[ -n "$default_gateway" ]]; then probe_tcp 'default gateway DNS' "$default_gateway" 53; else printf '[isolation] network probe: default gateway unavailable\n'; fi
probe_tcp 'host localhost SMB' 127.0.0.1 445
probe_tcp 'host localhost SSH' 127.0.0.1 22
probe_tcp 'host localhost Docker' 127.0.0.1 2375
probe_tcp 'host localhost Docker TLS' 127.0.0.1 2376
! command -v docker >/dev/null 2>&1 || fail 'docker executable is available'
printf '[isolation] passed\n'
