#!/usr/bin/env bash
set -Eeuo pipefail

runuser -u ubuntu -- env HOME=/home/ubuntu bash -c '
  set -Eeuo pipefail
  installer=$(mktemp)
  trap "rm -f \"$installer\"" EXIT
  curl -fsSL https://chatgpt.com/codex/install.sh -o "$installer"
  CODEX_NON_INTERACTIVE=1 sh "$installer"
'
