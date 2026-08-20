#!/usr/bin/env bash
set -Eeuo pipefail

printf '[onboard:codex] authenticating Codex with device auth\n'
bash -ilc 'codex login --device-auth'
bash -ilc 'codex login status'
