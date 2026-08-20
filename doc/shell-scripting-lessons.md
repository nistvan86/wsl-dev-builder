# Shell scripting lessons

This note records the implementation and debugging rules that matter for this
project’s PowerShell, WSL, tar, and Bash boundaries.

## PowerShell to WSL boundaries

- Treat every `wsl.exe` invocation as an argument-passing boundary. PowerShell
  quoting, WSL argument parsing, and Bash parsing are separate layers.
- Avoid sending scripts or tokens through shell-constructed command strings.
  In particular, do not base64-encode content merely to push it through WSL.
- Prefer copying files into the disposable rootfs archive before importing it.
  For runtime commands, pass a short, literal command or execute a file already
  present in the Linux filesystem.
- A command that works in an interactive terminal may fail when invoked as
  `wsl.exe ... -- command`, because no interactive shell startup files are read.
  Use `bash -ilc` when the command intentionally depends on the user’s shell
  environment, or use an explicit absolute path when it does not.
- Do not assume the PowerShell process has the same PATH as the user’s normal
  host terminal. Resolve important host tools explicitly, with a standard-path
  fallback where appropriate. GitHub CLI, for example, may be installed at
  `C:\Program Files\GitHub CLI\gh.exe` while PATH lookup is incomplete.

## Rootfs and temporary paths

- Provisioning inputs must be added to the rootfs tar before `wsl --import`.
  Appending them after import changes only the archive, not the already-created
  filesystem.
- Use tar’s normal append/rewrite operations; do not edit tar headers manually.
  The Windows `tar.exe` available on this machine is bsdtar and preserves the
  Linux archive metadata when used before import.
- Do not use `/tmp` as the durable handoff location inside a WSL image. WSL may
  mount a tmpfs there, hiding archive-provided files. Put builder inputs under a
  dedicated path such as `/opt/wsl-dev-builder`.
- A disposable rootfs archive is the right place to inject provisioning files;
  the provisioner can remove its own `/opt/wsl-dev-builder` directory at the end.

## Bash startup and nvm

- nvm is shell state, not a system-wide installation. Installing Node in one
  shell does not make `node` available to later shells.
- The nvm installer appends its source block to `.bashrc`. Any project-managed
  `nvm use` block must be appended after that source block, or it may run before
  the `nvm` function exists.
- Validate both the provisioning shell and a genuinely fresh interactive user
  shell. The former can pass because it explicitly sources nvm; the latter
  catches missing startup activation.
- Keep a deterministic PATH fallback in the managed startup block by adding
  the default version’s `bin` directory after sourcing nvm. Also add
  `$HOME/.local/bin` for tools such as Codex installed by user-local installers.
- When a validation command uses a user-local tool, explicitly add its bin
  directory or source the appropriate interactive startup files. Do not rely on
  the environment inherited by `runuser`, `wsl.exe`, or PowerShell.
- nvm 0.40.6 can reference an unset variable while resolving an alias under
  `set -u`. Temporarily disable `nounset` around `nvm alias`/`nvm use`, then
  restore strict mode and check the real exit status.

## Provisioner cleanup

- A script can safely remove its own pathname and parent directory after Bash
  has opened it; the running shell has the script contents already loaded.
- Cleanup must be conditional on the installed image path. If a provisioner is
  run directly from a mounted development checkout for debugging, it must not
  delete the checkout or its configuration files.
- Validate that cleanup removed the builder inputs from the imported image, but
  leave externally supplied debug inputs intact.

## Authentication handoff

- Host GitHub authentication and Linux GitHub authentication are separate
  credential stores. If host `gh.exe auth token` is available, pass the token
  through stdin to `gh auth login --with-token`; never put it in command-line
  arguments or files.
- If host CLI discovery or token retrieval fails, make the fallback to
  interactive Linux authentication explicit.
- Codex authentication is also separate and requires `codex login --device-auth`.
  Invoke it through an interactive login shell when Codex is installed in the
  user’s local PATH.

## Validation workflow

1. Run parser and focused PowerShell tests.
2. Use the previous `.wsl` artifact and a disposable registered distro for
   iterative provisioning and shell checks.
3. Preserve the staging distro on failure so the exact filesystem and startup
   environment can be inspected without another full build.
4. Run one full build only after the staging checks pass.
5. Confirm the exported artifact, default user, systemd, fresh-shell tooling,
   and cleanup state.
