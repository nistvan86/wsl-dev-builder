# Project guide

## Purpose

This project builds a reusable Ubuntu 24.04 WSL development and agent image. `build.ps1` exports the official `ubuntu:24.04` OCI filesystem with a user-supplied `crane.exe`, provisions it in a temporary WSL distro, validates it, and exports a date-versioned `.wsl` artifact.

The current target is **reduced accidental Windows integration and reduced Linux privilege escalation**, not a hard VM-grade security boundary.

## Architecture

- `build.ps1` is the thin Windows orchestration layer. It owns prerequisite checks, WSL lifecycle operations, archive staging, export, artifact naming, and cleanup.
- `files/provision.sh` is the authoritative portable Linux provisioning policy. Keep package selection, Ubuntu configuration, user configuration, and Linux-side validation here.
- `files/` contains all non-PowerShell operational scripts and WSL configuration:
  - `provision.sh`
  - `isolation-runtime.sh`
  - `onboard-agent-distro`
  - `host-isolation-audit.ps1`
  - `wsl.conf`
  - `wsl-distribution.conf`
- The staging distro is exactly `__wsl_builder`. It is reserved for this project. Cleanup may terminate or unregister only that exact name; never use partial or wildcard matching.
- The base image is `ubuntu:24.04`. `crane.exe` is supplied beside `build.ps1`; do not download it automatically and do not add Docker or Podman as a build dependency.
- Keep the acquisition/staging boundary separate from provisioning so the backend can later change without rewriting Linux policy. Do not add WSLC support until it is stable and explicitly requested.

## Build and artifact invariants

- Resolve project-relative paths from the script location, never the caller's working directory.
- Use strict, fail-fast PowerShell and Bash behavior. Check every native command exit status.
- Provisioning and every required validation are fail-closed: a failure must prevent export.
- Export to a temporary location first; only move a successful export to its final artifact name.
- Name artifacts `ubuntu-dev-YYYY-MM-DD.wsl`, then use deterministic `-2`, `-3`, … suffixes. Never overwrite an existing artifact.
- On ordinary failure, clean temporary files and `__wsl_builder` without masking the primary error. `build.ps1 -KeepStagingOnFailure` is the supported debugging path when the staging filesystem must be inspected.
- Preserve the pre-existing `ubuntu` account. It must remain UID/GID `1000`; do not rename or recreate it.

## Image policy

### Developer tooling

- Keep the explicit editable base package list near the top of `files/provision.sh`.
- The image currently includes Git/GitHub CLI, compiler and build tooling, `mc`, `wget`, `curl`, `bubblewrap`, `make`, and `pkg-config`.
- Install the latest Node.js LTS through nvm for `ubuntu`.
- Install Codex with its official standalone installer, **not npm**.
- Validate tooling both during provisioning and from a fresh interactive `ubuntu` shell.
- Keep the prompt dynamic: it must evaluate `WSL_DISTRO_NAME` at runtime and must never embed `__wsl_builder`.

### Authentication and onboarding

- Reusable `.wsl` artifacts must contain no GitHub or Codex credentials.
- Authentication happens only inside each installed distro as `ubuntu`, through `/usr/local/bin/onboard-agent-distro`.
- GitHub uses HTTPS device/login flow; Codex uses `codex login --device-auth`.
- Never inspect, reuse, transfer, or seed Windows GitHub/Codex tokens, environment variables, credential files, or `/mnt/c` content.
- Do not recreate `bootstrap.ps1`; users select and install an artifact directly with `wsl --install --from-file`.

### Isolation policy

- Keep `/etc/wsl.conf` configured with:
  - DrvFs automount disabled;
  - `/etc/fstab` processing disabled;
  - Windows interop disabled;
  - Windows PATH injection disabled;
  - systemd enabled;
  - `ubuntu` as the default user.
- Keep `sudo` absent. `ubuntu` must not belong to `sudo`, `wheel`, `docker`, `lxd`, `disk`, `libvirt`, or `kvm`.
- Keep root and `ubuntu` passwords locked. A trusted host user may deliberately run `wsl -d <name> -u root` for maintenance.
- Keep build-time validation for identity, groups, sudo absence, DrvFs mounts, `/mnt/c` and `/mnt/d` mounts, normal Windows executable lookup, failed manual DrvFs mounting, inaccessible Docker/Podman/containerd sockets, protected-path writability, and required tooling.
- Keep SUID/SGID stripping and high-risk Linux capability auditing. `libcap2-bin` is build-only tooling and must be removed before export.
- Do not make network probe results build failures by default; report them.
- Do not give the agent separate Windows-side capabilities—such as Docker APIs, MCP/IDE host tools, or host credential access—that would bypass the WSL policy.

### Known WSL limitations and deliberate deferrals

- `WSLInterop` is host-managed and can remain registered despite `interop.enabled=false`. Do not make its presence a build failure and do not claim WSL prevents deliberate execution of a Windows PE binary stored on the Linux filesystem.
- WSL-only controls are not a hard boundary against a successful Linux-root compromise. Use a separate VM if that guarantee is required.
- `unminimize`, systemd, and default GPU integration intentionally remain enabled.
- `bubblewrap` remains available as a tool, but do not add an automatic Bubblewrap launcher or process-level agent sandbox unless explicitly requested.
- Do not change global `.wslconfig`, WSLg, networking, or Hyper-V firewall policy automatically. `files/host-isolation-audit.ps1` is read-only. Any host-wide hardening requires explicit user opt-in.
- Docker Desktop WSL integration must remain disabled for distros built from this image.

## PowerShell, WSL, tar, and Bash rules

- Treat PowerShell → `wsl.exe` → Bash as separate argument-parsing boundaries.
- Do not send generated scripts, complex tokens, or credentials through shell-constructed command strings. Prefer a short literal command or a file already injected into the Linux filesystem.
- Add provisioning inputs to the rootfs tar **before** `wsl --import`; modifying the archive afterward does not modify the imported filesystem.
- Use normal `tar.exe` append/rewrite operations. Do not edit tar headers manually.
- Do not use `/tmp` for durable image handoff files; use `/opt/wsl-dev-builder`. Temporary runtime test directories under `/tmp` are acceptable when cleaned up.
- Provisioner cleanup may remove only its injected `/opt/wsl-dev-builder` input directory. It must not delete a mounted development checkout when run for debugging.
- nvm is shell state. Commands needing nvm or user-local tools must explicitly source/configure the environment or use a deliberately interactive shell. Keep deterministic PATH support for `$HOME/.local/bin` and the selected nvm Node binary.
- nvm may reference unset variables under `set -u`; temporarily relax `nounset` only around its alias/use calls and restore strict mode immediately.

## Validation workflow

1. Run parser checks and focused tests first.
2. Use a prior artifact and a disposable distro for iterative shell/provisioning tests when possible.
3. Preserve `__wsl_builder` on failure only when inspection is needed, then unregister it explicitly.
4. Run a full build after focused checks pass.
5. Confirm the exported artifact, default user, systemd, fresh-shell tooling, isolation validation, and cleanup state.

Do not change unrelated user modifications, generated artifacts, or registered WSL distros.
