#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" == 0 ]] || { printf '[windows-scratch] root is required\n' >&2; exit 1; }
[[ -f /usr/local/lib/wsl-dev-builder/windows-scratch-enabled ]] || { printf '[windows-scratch] image is not scratch-enabled\n' >&2; exit 1; }
[[ $# == 1 ]] || { printf '[windows-scratch] one Windows directory path is required\n' >&2; exit 1; }
source_path=$1
[[ ${#source_path} -ge 4 && "${source_path:1:2}" == ':\' && "${source_path:0:1}" =~ ^[A-Za-z]$ ]] || { printf '[windows-scratch] expected an absolute drive-letter path\n' >&2; exit 1; }
[[ "$source_path" != *$'\n'* && "$source_path" != *$'\r'* ]] || { printf '[windows-scratch] invalid path characters\n' >&2; exit 1; }

config_dir=/etc/wsl-dev-builder
install -d -o root -g root -m 0755 "$config_dir"
temp_path=$(mktemp "$config_dir/windows-scratch-path.XXXXXX")
trap 'rm -f "$temp_path"' EXIT
printf '%s\n' "$source_path" > "$temp_path"
chown root:root "$temp_path"
chmod 0644 "$temp_path"
mv -f "$temp_path" "$config_dir/windows-scratch-path"
