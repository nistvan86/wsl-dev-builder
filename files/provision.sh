#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${1:-}"
BASE_UTILITIES_FILE="${2:-}"
SELECTED_PACKAGES_FILE="${3:-}"
PACKAGES_DIR="${4:-}"

log() { printf '[provision] %s\n' "$*"; }
die() { printf '[provision] ERROR: %s\n' "$*" >&2; exit 1; }
is_wsl_environment() { grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; }

[[ "$(id -u)" == 0 ]] || die 'must run as root'
command -v apt-get >/dev/null || die 'apt-get is unavailable'
[[ -d "$CONFIG_DIR" ]] || die 'configuration directory is required'
[[ -f "$BASE_UTILITIES_FILE" ]] || die 'base utilities file is required'
[[ -f "$SELECTED_PACKAGES_FILE" ]] || die 'selected packages file is required'
[[ -d "$PACKAGES_DIR" ]] || die 'packages directory is required'
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

read_list_file() {
  local file="$1" item
  while IFS= read -r item || [[ -n "$item" ]]; do
    item="${item%%#*}"
    item="${item//[$'\t\r ']/}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done < "$file"
}

validate_package_name() {
  [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid package module name: $1"
}

mapfile -t BASE_UTILITIES < <(read_list_file "$BASE_UTILITIES_FILE")
(( ${#BASE_UTILITIES[@]} > 0 )) || die 'at least one base utility is required'
for system_package in "${BASE_UTILITIES[@]}"; do
  [[ "$system_package" =~ ^[A-Za-z0-9.+:-]+$ ]] || die "invalid base utility package: $system_package"
done

# Resolve module dependencies depth-first. A module can supply newline-delimited
# dependencies.txt, system-packages.txt, and required-tools.txt plus optional
# provision.sh and onboard.sh contributors.
declare -A PACKAGE_STATE=()
declare -a RESOLVED_PACKAGES=()
declare -a MODULE_SYSTEM_PACKAGES=()
declare -a REQUIRED_TOOLS=()

add_unique() {
  local item="$1" existing
  shift
  for existing in "$@"; do [[ "$existing" == "$item" ]] && return; done
  return 1
}

append_unique_system_package() {
  local item="$1"
  [[ "$item" =~ ^[A-Za-z0-9.+:-]+$ ]] || die "invalid module system package: $item"
  if add_unique "$item" "${MODULE_SYSTEM_PACKAGES[@]}"; then MODULE_SYSTEM_PACKAGES+=("$item"); fi
}

append_unique_required_tool() {
  local item="$1"
  [[ "$item" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid required tool: $item"
  if add_unique "$item" "${REQUIRED_TOOLS[@]}"; then REQUIRED_TOOLS+=("$item"); fi
}

resolve_package() {
  local package="$1" dependency file
  validate_package_name "$package"
  case "${PACKAGE_STATE[$package]:-}" in
    done) return ;;
    visiting) die "package dependency cycle includes: $package" ;;
  esac
  [[ -d "$PACKAGES_DIR/$package" ]] || die "unknown package module: $package"
  PACKAGE_STATE["$package"]=visiting

  file="$PACKAGES_DIR/$package/dependencies.txt"
  if [[ -f "$file" ]]; then
    while IFS= read -r dependency; do resolve_package "$dependency"; done < <(read_list_file "$file")
  fi

  file="$PACKAGES_DIR/$package/system-packages.txt"
  if [[ -f "$file" ]]; then
    while IFS= read -r dependency; do append_unique_system_package "$dependency"; done < <(read_list_file "$file")
  fi

  file="$PACKAGES_DIR/$package/required-tools.txt"
  if [[ -f "$file" ]]; then
    while IFS= read -r dependency; do append_unique_required_tool "$dependency"; done < <(read_list_file "$file")
  fi

  PACKAGE_STATE["$package"]=done
  RESOLVED_PACKAGES+=("$package")
}

while IFS= read -r package; do resolve_package "$package"; done < <(read_list_file "$SELECTED_PACKAGES_FILE")

log 'selected package modules:' "${RESOLVED_PACKAGES[*]:-none}"
log 'updating package indexes'; apt-get update
log 'upgrading the base image'; apt-get -y upgrade
command -v unminimize >/dev/null || die 'unminimize is unavailable in the supplied Ubuntu base image'
log 'unminimizing Ubuntu'
set +o pipefail; printf 'y\n' | unminimize; unminimize_status=${PIPESTATUS[1]}; set -o pipefail
(( unminimize_status == 0 )) || die "unminimize failed with status $unminimize_status"

CORE_SYSTEM_PACKAGES=(locales systemd systemd-sysv dbus ca-certificates apt-utils)
BUILD_AUDIT_PACKAGES=(libcap2-bin)
log 'installing base utilities and module system dependencies'
apt-get install -y --no-install-recommends "${CORE_SYSTEM_PACKAGES[@]}" "${BUILD_AUDIT_PACKAGES[@]}" "${BASE_UTILITIES[@]}" "${MODULE_SYSTEM_PACKAGES[@]}"

log 'configuring locale'
if [[ -f /etc/locale.gen ]]; then sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen; locale-gen en_US.UTF-8; fi
update-locale LANG=en_US.UTF-8

getent passwd ubuntu >/dev/null || die 'required user ubuntu is missing'
ubuntu_uid=$(id -u ubuntu); ubuntu_gid=$(id -g ubuntu)
[[ "$ubuntu_uid" == 1000 && "$ubuntu_gid" == 1000 ]] || die 'ubuntu must have UID/GID 1000'
getent group ubuntu >/dev/null || die 'required group ubuntu is missing'
for forbidden_group in sudo wheel docker lxd disk libvirt kvm; do
  if id -nG ubuntu | tr ' ' '\n' | grep -Fxq "$forbidden_group"; then
    gpasswd -d ubuntu "$forbidden_group" >/dev/null || die "failed to remove ubuntu from forbidden group: $forbidden_group"
  fi
done
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
      cat >> "$HOME/.bashrc" <<'"'"'EOF'"'"'

# wsl-dev-builder runtime WSL prompt
export PS1="\[\e]0;\u@\${WSL_DISTRO_NAME}: \w\a\]\[\033[01;32m\]\u@\${WSL_DISTRO_NAME}\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$"
EOF
    fi
  '
fi

for package in "${RESOLVED_PACKAGES[@]}"; do
  contributor="$PACKAGES_DIR/$package/provision.sh"
  if [[ -f "$contributor" ]]; then
    log "running provision contributor: $package"
    bash "$contributor"
  fi
done

install -d -o root -g root -m 0755 /usr/local/lib/wsl-dev-builder/onboard.d
: > /usr/local/lib/wsl-dev-builder/required-tools.txt
for package in "${RESOLVED_PACKAGES[@]}"; do
  contributor="$PACKAGES_DIR/$package/onboard.sh"
  if [[ -f "$contributor" ]]; then
    install -o root -g root -m 0755 "$contributor" "/usr/local/lib/wsl-dev-builder/onboard.d/$package.sh"
  fi
done
for tool in "${REQUIRED_TOOLS[@]}"; do printf '%s\n' "$tool"; done > /usr/local/lib/wsl-dev-builder/required-tools.txt

log 'auditing and stripping SUID/SGID runtime files'
suid_sgid_files=()
while IFS= read -r -d '' file; do suid_sgid_files+=("$file"); done < <(find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print0)
printf '[provision] SUID/SGID files selected for stripping: %d\n' "${#suid_sgid_files[@]}"
if (( ${#suid_sgid_files[@]} > 0 )); then
  printf '[provision] stripping SUID/SGID: %s\n' "${suid_sgid_files[@]}"
  chmod u-s,g-s "${suid_sgid_files[@]}"
fi
if find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print -quit | grep -q .; then die 'SUID or SGID runtime file remains'; fi
log 'SUID/SGID stripping validation passed'

log 'auditing Linux file capabilities'
capability_roots=(/bin /sbin /usr /lib /lib64 /opt)
capability_audit=$(getcap -r "${capability_roots[@]}" 2>/dev/null || true)
printf '%s\n' "$capability_audit"
if printf '%s\n' "$capability_audit" | grep -Eiq 'cap_(sys_admin|dac_override|dac_read_search|sys_ptrace|sys_module|sys_rawio|setuid|setgid)'; then die 'high-risk Linux file capability detected'; fi
log 'removing build-only capability audit tooling'
apt-get purge -y --auto-remove libcap2-bin

log 'installing WSL configuration'
install -o root -g root -m 0644 "$CONFIG_DIR/wsl.conf" /etc/wsl.conf
install -o root -g root -m 0644 "$CONFIG_DIR/wsl-distribution.conf" /etc/wsl-distribution.conf
install -d -o root -g root -m 0755 /usr/local/lib/wsl-dev-builder
install -o root -g root -m 0755 "$CONFIG_DIR/isolation-runtime.sh" /usr/local/lib/wsl-dev-builder/isolation-runtime.sh
install -o root -g root -m 0755 "$CONFIG_DIR/onboard-agent-distro" /usr/local/bin/onboard-agent-distro

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
for system_package in "${CORE_SYSTEM_PACKAGES[@]}" "${BASE_UTILITIES[@]}" "${MODULE_SYSTEM_PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$system_package" 2>/dev/null | grep -q 'install ok installed' || die "package is not installed: $system_package"
done
! command -v getcap || die 'build-only getcap tooling remains installed'
command -v systemd >/dev/null; command -v systemctl >/dev/null
! command -v sudo || die 'sudo must not be installed'
for forbidden_group in sudo wheel docker lxd disk libvirt kvm; do
  if id -nG ubuntu | tr ' ' '\n' | grep -Fxq "$forbidden_group"; then die "ubuntu is a member of forbidden group: $forbidden_group"; fi
done
[[ "$(passwd -S root | awk '{print $2}')" == L* ]] || die 'root password is not locked'
[[ "$(passwd -S ubuntu | awk '{print $2}')" == L* ]] || die 'ubuntu password is not locked'
[[ "$(stat -c '%u:%g:%a' /etc/wsl.conf)" == '0:0:644' ]] || die '/etc/wsl.conf has incorrect metadata'
[[ -z "$(dpkg --audit)" ]] || die 'dpkg reports unfinished transactions'
manifest_directory=/usr/local/lib/wsl-dev-builder
printf '%s\n' "${RESOLVED_PACKAGES[@]}" > "$manifest_directory/image-modules.txt"
dpkg-query -W -f='${binary:Package}\n' | LC_ALL=C sort > "$manifest_directory/installed-system-packages.txt"
if is_wsl_environment; then grep -Fq WSL_DISTRO_NAME /home/ubuntu/.bashrc || die 'WSL prompt missing'; ! grep -Fq __wsl_builder /home/ubuntu/.bashrc || die 'staging name leaked'; fi

if [[ "$0" == '/opt/wsl-dev-builder/provision.sh' && "$CONFIG_DIR" == '/opt/wsl-dev-builder/files' ]]; then
  rm -rf /opt/wsl-dev-builder
else
  log 'leaving externally supplied provisioning inputs intact'
fi
log 'provisioning and Linux-side validation succeeded'
