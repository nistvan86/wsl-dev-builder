#!/usr/bin/env bash
set -Eeuo pipefail

printf '[onboard:github] authenticating GitHub inside this distro\n'
if [[ -c /dev/tty ]]; then
  gh auth login --hostname github.com --git-protocol https < /dev/tty
else
  gh auth login --hostname github.com --git-protocol https
fi
gh auth setup-git --hostname github.com
gh auth status --hostname github.com
