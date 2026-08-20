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
apt-get install -y --no-install-recommends locales systemd systemd-sysv dbus libcap2-bin ca-certificates apt-utils "${BASE_UTILITIES[@]}"
log 'configuring locale'
if [[ -f /etc/locale.gen ]]; then sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen; locale-gen en_US.UTF-8; fi
update-locale LANG=en_US.UTF-8
getent passwd ubuntu >/dev/null || die 'required user ubuntu is missing'
ubuntu_uid=$(id -u ubuntu); ubuntu_gid=$(id -g ubuntu)
[[ "$ubuntu_uid" == 1000 && "$ubuntu_gid" == 1000 ]] || die 'ubuntu must have UID/GID 1000'
getent group ubuntu >/dev/null || die 'required group ubuntu is missing'
for forbidden_group in sudo wheel docker lxd disk libvirt kvm; do
  if id -nG ubuntu | tr ' ' '\n' | grep -Fxq "$forbidden_group"; then die "ubuntu is a member of forbidden group: $forbidden_group"; fi
done
passwd -l root >/dev/null || die 'failed to lock root password'
passwd -l ubuntu >/dev/null || die 'failed to lock ubuntu password'

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

log 'installing isolated-agent bubblewrap launcher'
install -d -o root -g root -m 0755 /usr/local/bin /usr/local/lib/wsl-dev-builder
install -d -o ubuntu -g ubuntu -m 0755 /home/ubuntu/work /home/ubuntu/.codex /home/ubuntu/.cache
cat > /usr/local/bin/isolated-agent <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == '--help' ]]; then
  printf 'Usage: isolated-agent [agent-command [argument...]]\n'
  printf 'Runs the command, or codex by default, inside a bubblewrap sandbox.\n'
  exit 0
fi
command=("$@")
if (( ${#command[@]} == 0 )); then command=(codex); fi
exec bwrap \
  --die-with-parent \
  --new-session \
  --unshare-pid \
  --unshare-uts \
  --unshare-ipc \
  --unshare-user-try \
  --ro-bind /usr /usr \
  --ro-bind /bin /bin \
  --ro-bind /lib /lib \
  --ro-bind /lib64 /lib64 \
  --ro-bind /etc /etc \
  --ro-bind /usr/local /usr/local \
  --ro-bind /home/ubuntu /home/ubuntu \
  --bind /home/ubuntu/work /home/ubuntu/work \
  --bind /home/ubuntu/.codex /home/ubuntu/.codex \
  --bind /home/ubuntu/.cache /home/ubuntu/.cache \
  --proc /proc \
  --dev /dev \
  --tmpfs /run \
  --tmpfs /tmp \
  --chdir /home/ubuntu/work \
  --setenv HOME /home/ubuntu \
  --setenv PATH /home/ubuntu/.local/bin:/home/ubuntu/.nvm/versions/node/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -- "${command[@]}"
EOF
chmod 0755 /usr/local/bin/isolated-agent
chown root:root /usr/local/bin/isolated-agent

log 'auditing and stripping SUID/SGID runtime files'
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod u-s,g-s {} +
if find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print -quit | grep -q .; then die 'SUID or SGID runtime file remains'; fi
log 'auditing Linux file capabilities'
capability_audit=$(getcap -r / 2>/dev/null || true)
printf '%s\n' "$capability_audit"
if printf '%s\n' "$capability_audit" | grep -Eiq 'cap_(sys_admin|dac_override|dac_read_search|sys_ptrace|sys_module|sys_rawio|setuid|setgid)'; then die 'high-risk Linux file capability detected'; fi
log 'installing WSL configuration'
install -o root -g root -m 0644 "$CONFIG_DIR/wsl.conf" /etc/wsl.conf
install -o root -g root -m 0644 "$CONFIG_DIR/wsl-distribution.conf" /etc/wsl-distribution.conf
if [[ -f "$CONFIG_DIR/isolation-runtime.sh" ]]; then
  install -o root -g root -m 0755 "$CONFIG_DIR/isolation-runtime.sh" /usr/local/lib/wsl-dev-builder/isolation-runtime.sh
  runuser -u ubuntu -- isolated-agent /usr/local/lib/wsl-dev-builder/isolation-runtime.sh || die 'bubblewrap isolation validation failed'
  runuser -u ubuntu -- isolated-agent bash -lc 'test ! -e /root && test ! -e /opt' || die 'bubblewrap filesystem visibility validation failed'
fi
validate_isolation_config() {
  local section=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "["*"]") section="$line" ;;
      enabled=false) [[ "$section" == '[automount]' ]] && automount_enabled=false ;;
      mountFsTab=false) [[ "$section" == '[automount]' ]] && automount_fstab=false ;;
      appendWindowsPath=false) [[ "$section" == '[interop]' ]] && interop_path=false ;;
    esac
    [[ "$section" == '[interop]' && "$line" == 'enabled=false' ]] && interop_enabled=false
  done < /etc/wsl.conf
  [[ "${automount_enabled:-true}" == false && "${automount_fstab:-true}" == false && "${interop_enabled:-true}" == false && "${interop_path:-true}" == false ]] || die '/etc/wsl.conf does not disable automount and Windows interop'
}
validate_isolation_config
for unit in systemd-resolved.service systemd-networkd.service NetworkManager.service systemd-tmpfiles-setup.service systemd-tmpfiles-clean.service systemd-tmpfiles-clean.timer systemd-tmpfiles-setup-dev-early.service systemd-tmpfiles-setup-dev.service tmp.mount; do ln -sfn /dev/null "/etc/systemd/system/$unit"; done

log 'cleaning apt metadata'; rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
log 'validating the provisioned image'
source /etc/os-release; [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || die 'image is not Ubuntu 24.04'
for package in systemd systemd-sysv dbus libcap2-bin "${BASE_UTILITIES[@]}"; do dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || die "package is not installed: $package"; done
command -v getcap >/dev/null || die 'getcap is unavailable'
command -v systemd >/dev/null; command -v systemctl >/dev/null
! command -v sudo || die 'sudo must not be installed'
for forbidden_group in sudo wheel docker lxd disk libvirt kvm; do
  if id -nG ubuntu | tr ' ' '\n' | grep -Fxq "$forbidden_group"; then die "ubuntu is a member of forbidden group: $forbidden_group"; fi
done
[[ "$(passwd -S root | awk '{print $2}')" == L* ]] || die 'root password is not locked'
[[ "$(passwd -S ubuntu | awk '{print $2}')" == L* ]] || die 'ubuntu password is not locked'
[[ "$(stat -c '%u:%g:%a' /etc/wsl.conf)" == '0:0:644' ]] || die '/etc/wsl.conf has incorrect metadata'
[[ -z "$(dpkg --audit)" ]] || die 'dpkg reports unfinished transactions'
if is_wsl_environment; then grep -Fq WSL_DISTRO_NAME /home/ubuntu/.bashrc || die 'WSL prompt missing'; ! grep -Fq __wsl_builder /home/ubuntu/.bashrc || die 'staging name leaked'; fi

if [[ "$0" == '/opt/wsl-dev-builder/provision.sh' && "$CONFIG_DIR" == '/opt/wsl-dev-builder/files' ]]; then
  rm -rf /opt/wsl-dev-builder
else
  log 'leaving externally supplied provisioning inputs intact'
fi
log 'provisioning and Linux-side validation succeeded'
