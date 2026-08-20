# Ubuntu 24.04 WSL development image builder

Builds a reusable Ubuntu 24.04 `.wsl` image for an isolated developer/agent environment. It uses `crane.exe` to export the official `ubuntu:24.04` OCI image, provisions and validates it in a temporary WSL 2 distro, then exports a date-versioned artifact. Docker and Podman are not required.

## Prerequisites

- Windows with current WSL 2 and PowerShell.
- `crane.exe` beside `build.ps1`. Download the Windows binary from the [go-containerregistry releases](https://github.com/google/go-containerregistry/releases).
- `tar.exe` (normally included with Windows; a local `tar.exe` beside `build.ps1` is also accepted).
- Network access to download dependencies.

## Configure and build

Copy the template to create local settings:

```powershell
Copy-Item .\build.settings.psd1.example .\build.settings.psd1
```

The settings file selects base Ubuntu utilities, package modules, and the artifact directory. Relative `DistributionDirectory` values are resolved from `build.ps1`, not the current PowerShell directory. Defaults install `github`, `nodejs`, and `codex`, use `build-essential`, `g++`, `git`, `gh`, `make`, `mc`, `wget`, `curl`, and `pkg-config`, and write artifacts to `./dist`.

```powershell
.\build.ps1
```

Use parameters to replace or extend settings for one build:

```powershell
# Replace the configured module/base-utility selections.
.\build.ps1 -Packages github,nodejs -BaseUtilities git,make,curl

# Add to the configured selections, choose another artifact directory, and name the image.
.\build.ps1 -AddPackages my-module -AddBaseUtilities cmake -DistributionDirectory D:\WSL\images -ImageName ubuntu-dev-retroos

# Add purpose/context to the companion manifest.
.\build.ps1 -ImageComment @'
Retro game development environment with the retroos toolchain.
'@
```

Package modules live in `packages/<name>/`; Codex automatically selects its Node.js dependency. Use `-ImageName` to replace the default `ubuntu-dev` artifact-name prefix. Each image has an adjacent `.wsl.txt` manifest listing its Ubuntu base image, resolved modules, selected base utilities, an optional `-ImageComment`, and a fully resolved `build.ps1` replay command that does not depend on local settings. Project-contained output directories are recorded relative to `build.ps1` in that command. A target image or manifest conflict stops the build; pass `-Rebuild` only when intentionally refreshing that exact image. The builder reserves `__wsl_dev_builder` as a disposable staging distro and may unregister exactly that distro during cleanup.

## Install and onboard

Copy the optional instance-location template when you want newly installed distro storage under a specific absolute Windows path:

```powershell
Copy-Item .\install.settings.psd1.example .\install.settings.psd1
```

Set `InstanceDirectory` in that ignored file, such as `D:\WSL\instances`. Leave it empty or omit the file to let WSL choose its default location.

Install an artifact by filename from `dist/`. The wrapper validates the image, ensures the distro name is unused, creates `<InstanceDirectory>\<DistroName>` when configured, and does not launch the distro:

```powershell
.\install.ps1 -ImageName ubuntu-dev.wsl -DistroName dev-foo

# Override the configured/default location for one instance.
.\install.ps1 -ImageName ubuntu-dev-retroos.wsl -DistroName dev-retroos -InstanceDirectory D:\WSL\instances
```

Launch the installed distro explicitly with `wsl.exe -d <distro-name>`. The first interactive launch automatically runs the distro-owned onboarding flow, which performs GitHub HTTPS authentication and Codex device authentication inside the installed distro. Credentials are per-distro and are never included in the image or copied from Windows. If onboarding is interrupted or fails, WSL keeps OOBE incomplete and retries it on the next interactive launch.

## Agent-assisted instances

This repository includes the project-local `wsl-dev-instance` agent skill. Ask an agent for a new developer distribution and describe the target project or required tooling; it inspects existing image manifests, reuses a suitable image when possible, or builds and installs a purpose-specific instance.

Selected modules contribute their own tooling and onboarding steps. The default selection provides GitHub CLI, Node.js LTS through nvm, and Codex CLI. The image uses `ubuntu` (UID 1000), enables systemd, removes runtime `sudo`, disables automatic Windows-drive mounts and Windows PATH injection, and runs build-time privilege/isolation checks.


This configuration reduces accidental Windows integration but is not a hard host-security boundary: WSLInterop is host-managed, and trusted maintenance can explicitly run `wsl -d dev-foo -u root`.
