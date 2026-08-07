#!/usr/bin/env bash
set -Eeuo pipefail

# Keep optional developer tooling in this list. Add or remove packages here without
# changing the orchestration layer.
BASE_UTILITIES=(
  build-essential
  g++
  git
  gh
  mc
  wget
  curl
)

CONFIG_DIR="${1:-}"
if [[ -z "$CONFIG_DIR" || ! -d "$CONFIG_DIR" ]]; then
  echo "provision.sh: configuration directory is required" >&2
  exit 2
fi

log() { printf '[provision] %s\n' "$*"; }
die() { printf '[provision] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" == 0 ]] || die 'must run as root'
command -v apt-get >/dev/null || die 'apt-get is unavailable'

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log 'updating package indexes'
apt-get update

log 'upgrading the base image'
apt-get -y upgrade

if ! command -v unminimize >/dev/null; then
  die 'unminimize is unavailable in the supplied Ubuntu base image'
fi

log 'unminimizing Ubuntu'
# unminimize asks for confirmation. Avoid yes(1)'s expected SIGPIPE under pipefail
# while still checking unminimize's actual exit status.
set +o pipefail
printf 'y\n' | unminimize
unminimize_status=${PIPESTATUS[1]}
set -o pipefail
(( unminimize_status == 0 )) || die "unminimize failed with status $unminimize_status"

log 'installing required packages'
apt-get install -y --no-install-recommends \
  sudo locales systemd systemd-sysv dbus ca-certificates apt-utils \
  "${BASE_UTILITIES[@]}"

log 'configuring locale'
if [[ -f /etc/locale.gen ]]; then
  sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  locale-gen en_US.UTF-8
fi
update-locale LANG=en_US.UTF-8

getent passwd ubuntu >/dev/null || die 'required user ubuntu is missing'
ubuntu_uid=$(id -u ubuntu)
ubuntu_gid=$(id -g ubuntu)
[[ "$ubuntu_uid" == 1000 ]] || die "ubuntu UID is $ubuntu_uid, expected 1000"
[[ "$ubuntu_gid" == 1000 ]] || die "ubuntu primary GID is $ubuntu_gid, expected 1000"
getent group ubuntu >/dev/null || die 'required group ubuntu is missing'
usermod -aG sudo ubuntu

log 'installing WSL configuration'
install -o root -g root -m 0644 "$CONFIG_DIR/wsl.conf" /etc/wsl.conf
install -o root -g root -m 0644 "$CONFIG_DIR/wsl-distribution.conf" /etc/wsl-distribution.conf

install -d -o root -g root -m 0755 /etc/sudoers.d
cat > /etc/sudoers.d/ubuntu <<'EOF'
ubuntu ALL=(ALL) NOPASSWD:ALL
EOF
chown root:root /etc/sudoers.d/ubuntu
chmod 0440 /etc/sudoers.d/ubuntu

# WSL owns networking and several mounts. These units are documented by Microsoft
# as problematic when systemd is enabled inside WSL.
for unit in systemd-resolved.service systemd-networkd.service NetworkManager.service \
    systemd-tmpfiles-setup.service systemd-tmpfiles-clean.service systemd-tmpfiles-clean.timer \
    systemd-tmpfiles-setup-dev-early.service systemd-tmpfiles-setup-dev.service tmp.mount; do
  ln -sfn /dev/null "/etc/systemd/system/$unit"
done

log 'cleaning apt metadata'
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/archives/*

log 'validating the provisioned image'
source /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || die 'image is not Ubuntu 24.04'
[[ "$ubuntu_uid" == 1000 && "$ubuntu_gid" == 1000 ]] || die 'ubuntu identity changed during provisioning'
for package in sudo dbus "${BASE_UTILITIES[@]}"; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || die "package is not installed: $package"
done
command -v systemd >/dev/null || die 'systemd binary is missing'
command -v systemctl >/dev/null || die 'systemctl binary is missing'
visudo -cf /etc/sudoers >/dev/null
visudo -cf /etc/sudoers.d/ubuntu >/dev/null
[[ "$(stat -c '%u:%g:%a' /etc/wsl.conf)" == '0:0:644' ]] || die '/etc/wsl.conf has incorrect ownership or mode'
[[ "$(stat -c '%u:%g:%a' /etc/wsl-distribution.conf)" == '0:0:644' ]] || die '/etc/wsl-distribution.conf has incorrect ownership or mode'
grep -Eq '^systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' /etc/wsl.conf || die 'systemd is not enabled in wsl.conf'
grep -Eq '^default[[:space:]]*=[[:space:]]*ubuntu[[:space:]]*$' /etc/wsl.conf || die 'ubuntu is not the default WSL user'
grep -Eq '^defaultUid[[:space:]]*=[[:space:]]*1000[[:space:]]*$' /etc/wsl-distribution.conf || die 'defaultUid is not 1000'
grep -Eq '^defaultName[[:space:]]*=[[:space:]]*Ubuntu-Dev[[:space:]]*$' /etc/wsl-distribution.conf || die 'defaultName is incorrect'
[[ -z "$(dpkg --audit)" ]] || die 'dpkg reports unfinished or broken transactions'

# The orchestrator copies these inputs into the staging instance. Do not carry
# builder implementation details into the distributable root filesystem.
rm -f "$0"
rm -rf "$CONFIG_DIR"

log 'provisioning and Linux-side validation succeeded'
