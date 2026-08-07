#!/usr/bin/env bash
set -Eeuo pipefail

BASE_UTILITIES=(build-essential g++ git gh make mc wget curl bubblewrap pkg-config)
CONFIG_DIR="${1:-}"
if [[ -z "$CONFIG_DIR" || ! -d "$CONFIG_DIR" ]]; then echo 'provision.sh: configuration directory is required' >&2; exit 2; fi
log() { printf '[provision] %s\n' "$*"; }
die() { printf '[provision] ERROR: %s\n' "$*" >&2; exit 1; }
is_wsl_environment() { grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; }
[[ "$(id -u)" == 0 ]] || die 'must run as root'
command -v apt-get >/dev/null || die 'apt-get is unavailable'
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

log 'updating package indexes'; apt-get update
log 'upgrading the base image'; apt-get -y upgrade
command -v unminimize >/dev/null || die 'unminimize is unavailable in the supplied Ubuntu base image'
log 'unminimizing Ubuntu'
set +o pipefail; printf 'y\n' | unminimize; unminimize_status=${PIPESTATUS[1]}; set -o pipefail
(( unminimize_status == 0 )) || die "unminimize failed with status $unminimize_status"
log 'installing required packages'
apt-get install -y --no-install-recommends sudo locales systemd systemd-sysv dbus ca-certificates apt-utils "${BASE_UTILITIES[@]}"
log 'configuring locale'
if [[ -f /etc/locale.gen ]]; then sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen; locale-gen en_US.UTF-8; fi
update-locale LANG=en_US.UTF-8
getent passwd ubuntu >/dev/null || die 'required user ubuntu is missing'
ubuntu_uid=$(id -u ubuntu); ubuntu_gid=$(id -g ubuntu)
[[ "$ubuntu_uid" == 1000 && "$ubuntu_gid" == 1000 ]] || die 'ubuntu must have UID/GID 1000'
getent group ubuntu >/dev/null || die 'required group ubuntu is missing'; usermod -aG sudo ubuntu

if is_wsl_environment; then
  log 'configuring WSL-aware ubuntu prompt'
  runuser -u ubuntu -- env HOME=/home/ubuntu bash -c '
    set -Eeuo pipefail
    if ! grep -Fq "# wsl-dev-builder runtime WSL prompt" "$HOME/.bashrc"; then
      cat >> "$HOME/.bashrc" <<'EOF'

# wsl-dev-builder runtime WSL prompt
export PS1="\[\e]0;\u@\${WSL_DISTRO_NAME}: \w\a\]\[\033[01;32m\]\u@\${WSL_DISTRO_NAME}\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$"
EOF
    fi
  '
fi

log 'installing nvm, the latest Node.js LTS, and Codex CLI for ubuntu'
NVM_VERSION='v0.40.6'
runuser -u ubuntu -- env HOME=/home/ubuntu NVM_DIR=/home/ubuntu/.nvm bash -c '
  set -Eeuo pipefail
  mkdir -p "$NVM_DIR"
  installer=$(mktemp)
  trap "rm -f \"$installer\"" EXIT
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/'"$NVM_VERSION"'/install.sh" -o "$installer"
  bash "$installer"
  . "$NVM_DIR/nvm.sh"
  nvm install --lts
  set +e +u
  nvm alias default "lts/*"; status=$?
  if (( status == 0 )); then nvm use --lts >/dev/null; status=$?; fi
  set -Eeuo pipefail
  (( status == 0 )) || exit "$status"
  if ! grep -Fq "# wsl-dev-builder nvm" "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<EOF

# wsl-dev-builder nvm
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && . "\$NVM_DIR/bash_completion"
[ -s "\$NVM_DIR/nvm.sh" ] && nvm use --silent default >/dev/null 2>&1 || true
[ -s "\$NVM_DIR/nvm.sh" ] && export PATH="\$NVM_DIR/versions/node/\$(nvm version default)/bin:\$PATH"
EOF
  fi
  if ! grep -Fq "# wsl-dev-builder local bin" "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<EOF

# wsl-dev-builder local bin
export PATH="\$HOME/.local/bin:\$PATH"
EOF
  fi
  codex_install_script=$(mktemp)
  trap "rm -f \"$codex_install_script\"" EXIT
  curl -fsSL https://chatgpt.com/codex/install.sh -o "$codex_install_script"
  CODEX_NON_INTERACTIVE=1 sh "$codex_install_script"
'

runuser -u ubuntu -- env HOME=/home/ubuntu NVM_DIR=/home/ubuntu/.nvm bash -c 'set -Eeuo pipefail; export PATH="$HOME/.local/bin:$PATH"; . "$NVM_DIR/nvm.sh"; nvm use --silent default >/dev/null; nvm --version; node --version; npm --version; command -v codex; codex --version' >/dev/null || die 'ubuntu developer tooling validation failed'

log 'installing WSL configuration'
install -o root -g root -m 0644 "$CONFIG_DIR/wsl.conf" /etc/wsl.conf
install -o root -g root -m 0644 "$CONFIG_DIR/wsl-distribution.conf" /etc/wsl-distribution.conf
install -d -o root -g root -m 0755 /etc/sudoers.d
cat > /etc/sudoers.d/ubuntu <<'EOF'
ubuntu ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 /etc/sudoers.d/ubuntu
for unit in systemd-resolved.service systemd-networkd.service NetworkManager.service systemd-tmpfiles-setup.service systemd-tmpfiles-clean.service systemd-tmpfiles-clean.timer systemd-tmpfiles-setup-dev-early.service systemd-tmpfiles-setup-dev.service tmp.mount; do ln -sfn /dev/null "/etc/systemd/system/$unit"; done
log 'cleaning apt metadata'; rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
log 'validating the provisioned image'
source /etc/os-release; [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || die 'image is not Ubuntu 24.04'
for package in sudo dbus "${BASE_UTILITIES[@]}"; do dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || die "package is not installed: $package"; done
command -v systemd >/dev/null; command -v systemctl >/dev/null; visudo -cf /etc/sudoers >/dev/null; visudo -cf /etc/sudoers.d/ubuntu >/dev/null
[[ "$(stat -c '%u:%g:%a' /etc/wsl.conf)" == '0:0:644' ]] || die '/etc/wsl.conf has incorrect metadata'
[[ -z "$(dpkg --audit)" ]] || die 'dpkg reports unfinished transactions'
if is_wsl_environment; then grep -Fq WSL_DISTRO_NAME /home/ubuntu/.bashrc || die 'WSL prompt missing'; ! grep -Fq __wsl_builder /home/ubuntu/.bashrc || die 'staging name leaked'; fi

if [[ "$0" == '/opt/wsl-dev-builder/provision.sh' && "$CONFIG_DIR" == '/opt/wsl-dev-builder/files' ]]; then
  rm -rf /opt/wsl-dev-builder
else
  log 'leaving externally supplied provisioning inputs intact'
fi
log 'provisioning and Linux-side validation succeeded'
