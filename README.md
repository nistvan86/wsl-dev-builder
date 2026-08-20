# Ubuntu 24.04 WSL development image builder

This proof of concept exports the official `ubuntu:24.04` OCI image with `crane.exe`, imports it into temporary WSL2 storage, provisions it in Linux, validates it, and publishes a date-stamped `.wsl` tar archive.

## Prerequisites

- Windows with current stable WSL 2 (WSL release 2.4.4 or newer is required for the modern `.wsl` format).
- PowerShell.
- `crane.exe` placed beside `build.ps1`.
- Network access for `crane` and Ubuntu APT repositories.

### Obtaining `crane.exe`

Download the Windows `crane` binary matching your machine architecture from the official [go-containerregistry releases](https://github.com/google/go-containerregistry/releases), rename it to `crane.exe` if necessary, and place it beside `build.ps1`. This project does not download or install `crane` automatically.

The script does not download or install `crane` and does not require Docker or Podman.

## Build

From this directory, run:

```powershell
.\build.ps1
```

The successful output is `ubuntu-dev-YYYY-MM-DD.wsl`. Existing artifacts are never overwritten; later builds on the same date receive `-2`, `-3`, and so on. Each image includes Codex CLI from OpenAI's official standalone installer, the latest Node.js LTS installed through `nvm` for the `ubuntu` user, and `bubblewrap`, `make`, and `pkg-config`. Node is intentionally included for general developer tooling, skills, and documentation workflows; Codex itself is not installed with npm.

This isolation branch disables automatic Windows filesystem mounts, `/etc/fstab` processing, Windows executable interop, and Windows PATH injection. GPU integration remains at its default for now; disabling it is intentionally deferred. The image also removes SUID/SGID bits from runtime files and rejects high-risk Linux file capabilities during provisioning. A normal image therefore has no `/mnt/c` or `/mnt/d` and cannot launch Windows executables. These settings do not prevent Linux root from manually mounting DrvFs; later hardening stages remove runtime privilege escalation and test that manual mounts fail for `ubuntu`.

This image enables systemd; the builder validates systemd as PID 1 and developer tooling is validated during build and bootstrap. The reserved temporary WSL distro name is `__wsl_builder`. The builder may unregister exactly that name at startup or during cleanup, so do not use it for another purpose.

Run `./host-isolation-audit.ps1` from PowerShell for a read-only report of WSL version/status, global `.wslconfig`, WSLg, networking mode, Hyper-V firewall visibility, and Docker Desktop indicators. The audit never changes host-wide settings. Docker Desktop WSL Integration must remain disabled for this distro; WSLg is reported as an optional host-wide integration surface.

## Install and test

```powershell
wsl --install --from-file .\ubuntu-dev-YYYY-MM-DD.wsl --name __wsl_poc_test
wsl -d __wsl_poc_test -- id
wsl -d __wsl_poc_test -- bash -lc 'command -v sudo && exit 1 || exit 0'
wsl -d __wsl_poc_test -- systemctl is-system-running

wsl --unregister __wsl_poc_test
```

`provision.sh` owns package selection, Ubuntu configuration, user setup, and Linux-side validation. The editable base utility list is near the top of that file. The PowerShell layer intentionally only handles Windows/WSL lifecycle and artifact handling.

The `ubuntu` Bash prompt evaluates `WSL_DISTRO_NAME` at runtime, so it shows the actual registered distro name. The reusable image contains no GitHub or Codex credentials. Both the builder and bootstrap run `tests/isolation-runtime.sh` before any artifact export or authentication; a failure stops the operation and bootstrap leaves the distro registered for inspection.

## Create a developer distro

Use `bootstrap.ps1` to install the newest image as a named distro at a chosen storage location:

```powershell
.\bootstrap.ps1 -Name dev-foo -Location D:\WSL\dev-foo
```

Image selection compares the date and same-day build number in the filename, not file timestamps. Override it explicitly when needed:

```powershell
.\bootstrap.ps1 -Name dev-foo -Location D:\WSL\dev-foo `
    -ImagePath .\ubuntu-dev-2026-08-07.wsl
```

For GitHub, bootstrap always runs GitHub CLI's interactive HTTPS login inside the new distro, then configures and validates Git operations. It never reads a Windows `gh` token or Windows credential store. Codex authentication always runs interactively inside the distro with `codex login --device-auth`, followed by `codex login status`.

Authentication is per developer instance; credentials are never copied into or seeded in `.wsl` artifacts. If authentication fails after WSL installation, bootstrap returns a failure but intentionally leaves the created distro registered so you can fix the login and retry.

## Network policies

The default policy is **Normal Internet**: Codex and GitHub work, but the agent may reach services exposed by the Windows host. Runtime validation reports reachability of the default gateway, host-local SMB/SSH/Docker ports, and Docker TLS without failing on network results.

For a global offline policy, set `networkingMode=none` under `[wsl2]` in `%UserProfile%\\.wslconfig`. This affects every WSL 2 distro and prevents normal cloud-agent operation, so the project never applies it automatically. A host-firewall policy can restrict WSL loopback or outbound traffic, but Hyper-V firewall rules are associated with shared WSL infrastructure rather than reliably scoped to this distro; apply those rules only with explicit opt-in and review their global impact.

The runtime `ubuntu` user has no `sudo` executable and is rejected if it belongs to `sudo`, `wheel`, `docker`, `lxd`, `disk`, `libvirt`, or `kvm`. Root and ubuntu password authentication is locked; trusted Windows maintenance can still use `wsl -d <distro-name> -u root` explicitly.

For defense in depth, `/usr/local/bin/isolated-agent` runs `codex` (or an explicitly supplied command) through bubblewrap. System paths are read-only; only `/home/ubuntu/work`, `.codex`, `.cache`, and `/tmp` are writable, with PID, IPC, UTS, and user namespaces enabled where supported. Bootstrap prints `Run the AI agent through: isolated-agent` but does not replace the user shell automatically. The launcher smoke test reruns the isolation invariants inside the sandbox.
