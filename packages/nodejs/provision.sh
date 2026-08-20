#!/usr/bin/env bash
set -Eeuo pipefail

NVM_VERSION='v0.40.6'
runuser -u ubuntu -- env HOME=/home/ubuntu NVM_DIR=/home/ubuntu/.nvm bash -c '
  set -Eeuo pipefail
  mkdir -p "$NVM_DIR"
  installer=$(mktemp)
  trap "rm -f \"$installer\"" EXIT
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/'"$NVM_VERSION"'/install.sh" -o "$installer"
  bash "$installer"
  . "$NVM_DIR/nvm.sh"
  nvm install --lts
  set +e +u
  nvm alias default "lts/*"; status=$?
  if (( status == 0 )); then nvm use --lts >/dev/null; status=$?; fi
  set -Eeuo pipefail
  (( status == 0 )) || exit "$status"
  if ! grep -Fq "# wsl-dev-builder nvm" "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<EOF

# wsl-dev-builder nvm
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && . "\$NVM_DIR/bash_completion"
[ -s "\$NVM_DIR/nvm.sh" ] && nvm use --silent default >/dev/null 2>&1 || true
[ -s "\$NVM_DIR/nvm.sh" ] && export PATH="\$NVM_DIR/versions/node/\$(nvm version default)/bin:\$PATH"
EOF
  fi
  if ! grep -Fq "# wsl-dev-builder local bin" "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<EOF

# wsl-dev-builder local bin
export PATH="\$HOME/.local/bin:\$PATH"
EOF
  fi
'
