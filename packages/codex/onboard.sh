#!/usr/bin/env bash
set -Eeuo pipefail

printf '[onboard:codex] authenticating Codex with device auth\n'
run_on_tty() {
  if [[ -c /dev/tty ]]; then
    "$@" </dev/tty >/dev/tty 2>/dev/tty
  else
    "$@"
  fi
}
run_on_tty codex login --device-auth
run_on_tty codex login status
