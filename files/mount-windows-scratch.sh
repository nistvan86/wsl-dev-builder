#!/usr/bin/env bash
set -Eeuo pipefail

config=/etc/wsl-dev-builder/windows-scratch-path
target=/mnt/windows-scratch

# The reusable image has no instance path. install.ps1 supplies it after install.
[[ -e "$config" ]] || exit 0
[[ "$(id -u)" == 0 ]] || { printf '[windows-scratch] root is required\n' >&2; exit 1; }
[[ -f "$config" && ! -L "$config" ]] || { printf '[windows-scratch] invalid path file\n' >&2; exit 1; }
mapfile -t paths < "$config"
[[ ${#paths[@]} == 1 && -n "${paths[0]}" ]] || { printf '[windows-scratch] path file must have one line\n' >&2; exit 1; }
source_path=${paths[0]}

install -d -o root -g root -m 0755 "$target"
if findmnt -n -M "$target" >/dev/null; then
  mounted_source=$(findmnt -n -M "$target" -o SOURCE)
  [[ "${mounted_source,,}" == "${source_path,,}" ]] || { printf '[windows-scratch] mountpoint has a different source\n' >&2; exit 1; }
  exit 0
fi

mount -t drvfs "$source_path" "$target"
mounted_source=$(findmnt -n -M "$target" -o SOURCE)
[[ "${mounted_source,,}" == "${source_path,,}" ]] || { printf '[windows-scratch] mounted source differs from configured path\n' >&2; exit 1; }
