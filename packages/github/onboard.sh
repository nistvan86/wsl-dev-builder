#!/usr/bin/env bash
set -Eeuo pipefail

printf '[onboard:github] authenticating GitHub inside this distro\n'
gh auth login --hostname github.com --git-protocol https
gh auth setup-git --hostname github.com
gh auth status --hostname github.com
