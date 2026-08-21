#!/usr/bin/env bash
set -Eeuo pipefail

completion_file='/usr/share/bash-completion/completions/git'
[[ -f "$completion_file" ]] || {
  printf '[git-completion] missing completion file: %s\n' "$completion_file" >&2
  exit 1
}

runuser -u ubuntu -- env HOME=/home/ubuntu COMPLETION_FILE="$completion_file" bash -s <<'USER_SCRIPT'
set -Eeuo pipefail

mkdir -p "$HOME"
touch "$HOME/.bashrc"
if ! grep -Fqx "source $COMPLETION_FILE" "$HOME/.bashrc"; then
  printf '\nsource %s\n' "$COMPLETION_FILE" >> "$HOME/.bashrc"
fi
USER_SCRIPT
