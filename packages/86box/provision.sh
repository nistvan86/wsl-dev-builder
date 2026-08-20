#!/usr/bin/env bash
set -Eeuo pipefail

requested_version="${1:-}"
api_url='https://api.github.com/repos/86Box/86Box/releases'
roms_api_url='https://api.github.com/repos/86Box/roms/releases'

# Release metadata is resolved from the official APIs. The AppImage digest is
# published by GitHub; the ROM repository publishes its ROM set as source.
release_json=$(mktemp)
roms_release_json=$(mktemp)
appimage_tmp=$(mktemp)
roms_tmp=$(mktemp)
roms_extract_dir=$(mktemp -d)
trap 'rm -f "$release_json" "$roms_release_json" "$appimage_tmp" "$roms_tmp"; rm -rf "$roms_extract_dir"' EXIT

if [[ -z "$requested_version" ]]; then
  curl -fsSL -H 'Accept: application/vnd.github+json' "$api_url/latest" -o "$release_json"
  release_version=$(python3 - "$release_json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    release = json.load(stream)
print(release['tag_name'])
PY
)
else
  release_version="${requested_version#v}"
  release_version="v${release_version}"
  curl -fsSL -H 'Accept: application/vnd.github+json' "$api_url/tags/${release_version}" -o "$release_json"
fi

readarray -t release_metadata < <(python3 - "$release_json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    release = json.load(stream)
asset = next((item for item in release.get('assets', [])
              if item['name'].startswith('86Box-Linux-x86_64-')
              and item['name'].endswith('.AppImage')), None)
if asset is None:
    raise SystemExit('no official x86_64 86Box AppImage in release')
digest = asset.get('digest', '')
if not digest.startswith('sha256:'):
    raise SystemExit('86Box AppImage has no published SHA-256 digest')
print(release['tag_name'])
print(asset['name'])
print(asset['browser_download_url'])
print(digest.removeprefix('sha256:'))
PY
)
(( ${#release_metadata[@]} == 4 )) || { printf '[86box] invalid release metadata\n' >&2; exit 1; }
release_version="${release_metadata[0]}"
appimage_name="${release_metadata[1]}"
appimage_url="${release_metadata[2]}"
appimage_sha256="${release_metadata[3]}"

curl -fsSL "$appimage_url" -o "$appimage_tmp"
printf '%s  %s\n' "$appimage_sha256" "$appimage_tmp" | sha256sum -c -

curl -fsSL -H 'Accept: application/vnd.github+json' "$roms_api_url/tags/${release_version}" -o "$roms_release_json"
roms_version=$(python3 - "$roms_release_json" "$release_version" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    release = json.load(stream)
if release.get('tag_name') != sys.argv[2]:
    raise SystemExit('ROM release tag does not match 86Box release')
print(release['tag_name'])
PY
)
[[ "$roms_version" == "$release_version" ]] || { printf '[86box] ROM release mismatch\n' >&2; exit 1; }

roms_url="https://github.com/86Box/roms/archive/refs/tags/${release_version}.tar.gz"
curl -fsSL "$roms_url" -o "$roms_tmp"
tar -xzf "$roms_tmp" -C "$roms_extract_dir"
roms_root=$(find "$roms_extract_dir" -mindepth 1 -maxdepth 1 -type d -name 'roms-*' -print -quit)
[[ -n "$roms_root" ]] || { printf '[86box] ROM archive has no roms-* top-level directory\n' >&2; exit 1; }
chmod -R a+rX "$roms_extract_dir"

if [[ -n "${WSL_DEV_BUILDER_RESOLVED_VERSION_FILE:-}" ]]; then
  printf '%s\n' "$release_version" > "$WSL_DEV_BUILDER_RESOLVED_VERSION_FILE"
fi

chmod 0644 "$appimage_tmp"
runuser -u ubuntu -- env HOME=/home/ubuntu APPIMAGE_TMP="$appimage_tmp" ROMS_ROOT="$roms_root" bash -s <<'USER_SCRIPT'
set -Eeuo pipefail
mkdir -p "$HOME/bin" "$HOME/.local/share/86Box"
install -m 0755 "$APPIMAGE_TMP" "$HOME/bin/86Box.AppImage"
rm -rf "$HOME/.local/share/86Box/roms"
install -d "$HOME/.local/share/86Box/roms"
cp -a "$ROMS_ROOT"/. "$HOME/.local/share/86Box/roms/"
if ! grep -Fq '# 86Box package user-local PATH' "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<'EOF'

# 86Box package user-local PATH
export PATH="$HOME/bin:$PATH"
EOF
fi
USER_SCRIPT

printf '[86box] installed %s (%s) and matching ROMs\n' "$release_version" "$appimage_name"
