# Ubuntu 24.04 WSL development image builder

This proof of concept exports the official `ubuntu:24.04` OCI image with `crane.exe`, imports it into temporary WSL2 storage, provisions it in Linux, validates it, and publishes a date-stamped `.wsl` tar archive.

## Prerequisites

- Windows with current stable WSL 2 (WSL release 2.4.4 or newer is required for the modern `.wsl` format).
- PowerShell.
- `crane.exe` placed beside `build.ps1`.
- Network access for `crane` and Ubuntu APT repositories.

The script does not download or install `crane` and does not require Docker or Podman.

## Build

From this directory, run:

```powershell
.\build.ps1
```

The successful output is `ubuntu-dev-YYYY-MM-DD.wsl`. Existing artifacts are never overwritten; later builds on the same date receive `-2`, `-3`, and so on.

The reserved temporary WSL distro name is `__wsl_builder`. The builder may unregister exactly that name at startup or during cleanup, so do not use it for another purpose.

## Install and test

```powershell
wsl --install --from-file .\ubuntu-dev-YYYY-MM-DD.wsl --name __wsl_poc_test
wsl -d __wsl_poc_test -- id
wsl -d __wsl_poc_test -- sudo -n true
wsl -d __wsl_poc_test -- systemctl is-system-running
wsl --unregister __wsl_poc_test
```

`provision.sh` owns package selection, Ubuntu configuration, user setup, and Linux-side validation. The editable base utility list is near the top of that file. The PowerShell layer intentionally only handles Windows/WSL lifecycle and artifact handling.
