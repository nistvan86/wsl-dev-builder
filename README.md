# Ubuntu 24.04 WSL development image builder

Builds a reusable Ubuntu 24.04 `.wsl` image for an isolated developer/agent environment. It uses `crane.exe` to export the official `ubuntu:24.04` OCI image, provisions and validates it in a temporary WSL 2 distro, then exports a date-versioned artifact. Docker and Podman are not required.

## Prerequisites

- Windows with current WSL 2 and PowerShell.
- `crane.exe` beside `build.ps1`. Download the Windows binary from the [go-containerregistry releases](https://github.com/google/go-containerregistry/releases).
- `tar.exe` (normally included with Windows; a local `tar.exe` beside `build.ps1` is also accepted).
- Network access for the base image, Ubuntu packages, nvm, and Codex.

## Configure and build

Copy the template to create local settings:

```powershell
Copy-Item .\build.settings.psd1.example .\build.settings.psd1
```

The settings file selects base Ubuntu utilities, package modules, and the artifact directory. Defaults install `github`, `nodejs`, and `codex`, use `build-essential`, `g++`, `git`, `gh`, `make`, `mc`, `wget`, `curl`, and `pkg-config`, and write artifacts to `./dist`.

```powershell
.\build.ps1
```

Use parameters to replace or extend settings for one build:

```powershell
# Replace the configured module/base-utility selections.
.\build.ps1 -Packages github,nodejs -BaseUtilities git,make,curl

# Add to the configured selections and choose another artifact directory.
.\build.ps1 -AddPackages my-module -AddBaseUtilities cmake -DistributionDirectory D:\WSL\images
```

Package modules live in `packages/<name>/`; Codex automatically selects its Node.js dependency. The result is `ubuntu-dev-YYYY-MM-DD.wsl`. Existing artifacts are never overwritten; subsequent builds use `-2`, `-3`, and so on. The builder reserves `__wsl_builder` as a disposable staging distro and may unregister exactly that distro during cleanup.

## Install and onboard

Install the artifact you choose directly with WSL:

```powershell
wsl --install --from-file .\dist\ubuntu-dev-YYYY-MM-DD.wsl --name dev-foo --location D:\WSL\dev-foo
wsl -d dev-foo -- id
wsl -d dev-foo -- onboard-agent-distro
```

`onboard-agent-distro` performs GitHub HTTPS authentication and Codex device authentication inside the installed distro. Credentials are per-distro and are never included in the image or copied from Windows.

Selected modules contribute their own tooling and onboarding steps. The default selection provides GitHub CLI, Node.js LTS through nvm, and Codex CLI. The image uses `ubuntu` (UID 1000), enables systemd, removes runtime `sudo`, disables automatic Windows-drive mounts and Windows PATH injection, and runs build-time privilege/isolation checks.


This configuration reduces accidental Windows integration but is not a hard host-security boundary: WSLInterop is host-managed, and trusted maintenance can explicitly run `wsl -d dev-foo -u root`.
