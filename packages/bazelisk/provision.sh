#!/usr/bin/env bash
set -Eeuo pipefail

requested_version="${1:-}"
BAZELISK_PATH='/usr/local/bin/bazelisk'

# Keep this list ordered from oldest to newest supported release. When no
# version is requested, select the last entry automatically.
supported_versions=(v1.29.0)
if [[ -z "$requested_version" ]]; then
  BAZELISK_VERSION="${supported_versions[${#supported_versions[@]}-1]}"
else
  case "$requested_version" in
    1.29.0|v1.29.0) BAZELISK_VERSION='v1.29.0' ;;
    *) printf '[bazelisk] unsupported requested version: %s\n' "$requested_version" >&2; exit 1 ;;
  esac
fi
if [[ -n "${WSL_DEV_BUILDER_RESOLVED_VERSION_FILE:-}" ]]; then
  printf '%s\n' "$BAZELISK_VERSION" > "$WSL_DEV_BUILDER_RESOLVED_VERSION_FILE"
fi

case "$BAZELISK_VERSION" in
  v1.29.0) BAZELISK_SHA256='5a408715e932c0250d28bd84555f12edbf70117de42f9181691c736eacc4a992' ;;
  *) printf '[bazelisk] missing checksum for supported version: %s\n' "$BAZELISK_VERSION" >&2; exit 1 ;;
esac
BAZELISK_URL="https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-amd64"

tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT

curl -fsSL "$BAZELISK_URL" -o "$tmp_file"
printf '%s  %s\n' "$BAZELISK_SHA256" "$tmp_file" | sha256sum -c -
install -o root -g root -m 0755 "$tmp_file" "$BAZELISK_PATH"
version_output=$("$BAZELISK_PATH" bazeliskVersion)
if ! printf '%s\n' "$version_output" | grep -Eq '(^|[^0-9])v?1\.29\.0([^0-9]|$)'; then
  printf '[bazelisk] installed binary reported an unexpected version: %s\n' "$version_output" >&2
  exit 1
fi
