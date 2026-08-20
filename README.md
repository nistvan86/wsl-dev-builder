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

This isolation branch requests disabled automatic Windows filesystem mounts, `/etc/fstab` processing, Windows executable interop, and Windows PATH injection. GPU integration remains at its default for now; disabling it is intentionally deferred. The image also removes SUID/SGID bits from runtime files and rejects high-risk Linux file capabilities during provisioning. A normal image has no DrvFs mounted at `/mnt/c` or `/mnt/d` and Windows executables are not available through the normal command lookup; empty mountpoint directories may still exist. WSLInterop is a host-managed binfmt integration that may remain present despite the distro setting, so this is not a hard barrier against deliberately launching a Windows PE executable from the Linux filesystem. These settings do not prevent Linux root from manually mounting DrvFs; later hardening stages remove runtime privilege escalation and test that manual mounts fail for `ubuntu`.

This image enables systemd; the builder validates systemd as PID 1 and developer tooling is validated during build and onboarding. The reserved temporary WSL distro name is `__wsl_builder`. The builder may unregister exactly that name at startup or during cleanup, so do not use it for another purpose.

Run `.\files\host-isolation-audit.ps1` from PowerShell for a read-only report of WSL version/status, global `.wslconfig`, WSLg, networking mode, Hyper-V firewall visibility, and Docker Desktop indicators. The audit never changes host-wide settings. Docker Desktop WSL Integration must remain disabled for this distro; WSLg is reported as an optional host-wide integration surface.

## Install and test

```powershell
wsl --install --from-file .\ubuntu-dev-YYYY-MM-DD.wsl --name __wsl_poc_test
wsl -d __wsl_poc_test -- id
wsl -d __wsl_poc_test -- bash -lc 'command -v sudo && exit 1 || exit 0'
wsl -d __wsl_poc_test -- systemctl is-system-running
wsl -d __wsl_poc_test -- onboard-agent-distro

wsl --unregister __wsl_poc_test
```

`files/provision.sh` owns package selection, Ubuntu configuration, user setup, and Linux-side build validation. The editable base utility list is near the top of that file. The builder runs `files/isolation-runtime.sh` before exporting the artifact; the audit is not repeated after deployment.

The `ubuntu` Bash prompt evaluates `WSL_DISTRO_NAME` at runtime, so it shows the actual registered distro name. The reusable image contains no GitHub or Codex credentials.

## Create a developer distro

Install a built image directly with the WSL command line:

```powershell
wsl --install --from-file .\\ubuntu-dev-YYYY-MM-DD.wsl --name dev-foo --location D:\\WSL\\dev-foo
wsl -d dev-foo -- id
```

Image selection is intentionally a host-side choice; select the desired date-stamped `.wsl` file directly. WSL owns registration, naming, storage location, termination, and removal.

After installation, run the distro-owned onboarding command as the default `ubuntu` user:

```powershell
wsl -d dev-foo -- onboard-agent-distro
```

`onboard-agent-distro` performs interactive GitHub HTTPS login and Codex device authentication entirely inside the distro. It never reads Windows `gh` tokens, Windows environment variables, Windows credential files, or `/mnt/c`. Authentication is per developer instance; credentials are never copied into or seeded in `.wsl` artifacts. If onboarding fails, the distro remains registered so you can retry manually.

## Network policies

The default policy is **Normal Internet**: Codex and GitHub work, but the agent may reach services exposed by the Windows host. Runtime validation reports reachability of the default gateway, host-local SMB/SSH/Docker ports, and Docker TLS without failing on network results.

For a global offline policy, set `networkingMode=none` under `[wsl2]` in `%UserProfile%\\.wslconfig`. This affects every WSL 2 distro and prevents normal cloud-agent operation, so the project never applies it automatically. A host-firewall policy can restrict WSL loopback or outbound traffic, but Hyper-V firewall rules are associated with shared WSL infrastructure rather than reliably scoped to this distro; apply those rules only with explicit opt-in and review their global impact.

The runtime `ubuntu` user has no `sudo` executable and is rejected if it belongs to `sudo`, `wheel`, `docker`, `lxd`, `disk`, `libvirt`, or `kvm`. Root and ubuntu password authentication is locked; trusted Windows maintenance can still use `wsl -d <distro-name> -u root` explicitly.
