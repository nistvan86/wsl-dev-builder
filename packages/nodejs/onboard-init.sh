#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/home/ubuntu/.local/bin:$PATH"
export NVM_DIR='/home/ubuntu/.nvm'
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  set +u
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
  set -u
  nvm use --silent default >/dev/null 2>&1 || true
  node_bin=$(command -v node || true)
  if [[ -n "$node_bin" ]]; then
    export PATH="$(dirname "$node_bin"):$PATH"
  fi
fi
