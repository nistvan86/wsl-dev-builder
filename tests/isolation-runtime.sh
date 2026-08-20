#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf '[isolation] FAILED: %s\n' "$*" >&2; exit 1; }
require() { "$@" || fail "invariant failed: $*"; }

require test "$(id -un)" = ubuntu
require test "$(id -u)" = 1000
! command -v sudo >/dev/null 2>&1 || fail 'sudo executable is present'

for forbidden_group in sudo wheel docker lxd disk libvirt kvm; do
  if id -nG | tr ' ' '\n' | grep -Fxq "$forbidden_group"; then
    fail "forbidden group is present: $forbidden_group"
  fi
done

! findmnt -rn -t drvfs | grep -q . || fail 'a DrvFs filesystem is mounted'
test ! -e /mnt/c || fail '/mnt/c exists'
test ! -e /mnt/d || fail '/mnt/d exists'
test ! -e /proc/sys/fs/binfmt_misc/WSLInterop || fail 'WSLInterop registration exists'
for windows_executable in cmd.exe powershell.exe explorer.exe; do
  ! command -v "$windows_executable" >/dev/null 2>&1 || fail "Windows executable is available: $windows_executable"
done

mount_test="$HOME/.isolation-mount-test"
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

if find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print -quit 2>/dev/null | grep -q .; then
  fail 'SUID or SGID runtime file remains'
fi
if getcap -r / 2>/dev/null | grep -Eiq 'cap_(sys_admin|dac_override|dac_read_search|sys_ptrace|sys_module|sys_rawio|setuid|setgid)'; then
  fail 'high-risk Linux file capability detected'
fi

for tool in codex gh node npm bwrap; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is missing: $tool"
done

printf '[isolation] passed\n'
