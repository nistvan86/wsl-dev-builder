# Implementation brief: reproducible Ubuntu 24.04 `.wsl` template builder

## Goal

Build a small proof-of-concept tool that reproducibly creates an up-to-date Ubuntu 24.04 WSL template from the official `ubuntu:24.04` OCI/Docker image without requiring Docker.

The output must be a native `.wsl` root-filesystem template suitable for repeated installation with commands such as:

```powershell
wsl --install --from-file .\ubuntu-dev-YYYY-MM-DD.wsl --name dev-example
```

Use stable WSL2 today. Use `crane.exe` only for obtaining the OCI image root filesystem. Structure the implementation so that the OCI/staging backend can later be replaced with `wslc build/create/export` when WSL Containers reaches stable release.

## Deliverables

Create these files:

```text
build.ps1                 # thin Windows orchestration layer
provision.sh              # authoritative Linux-side provisioning logic
files/
  wsl.conf
  wsl-distribution.conf
README.md                 # prerequisites, build and install usage
```

Do not add code for downloading or installing `crane`. The user will place `crane.exe` beside `build.ps1`.

## Design principle

Keep PowerShell responsible only for Windows/WSL lifecycle operations that cannot sensibly live in Linux. Put package selection, package installation, Ubuntu configuration, user configuration, validation, and as much future-reusable provisioning logic as practical in `provision.sh`.

The intention is for `provision.sh` to remain useful later if the outer environment becomes WSLC, an LXC container, or another Linux-side isolated build environment.

Avoid baking assumptions about `crane` into `provision.sh`.

## Build pipeline

Implement approximately this pipeline:

1. Validate prerequisites before destructive actions:
   - `wsl.exe` exists.
   - WSL supports the commands/options used by the script.
   - `crane.exe` exists in the same directory as `build.ps1` and is executable.
   - The reserved staging distro name `__wsl_builder` is not an unrelated user distro. This name is explicitly reserved by this project, and the script is authorized to unregister an existing distro with exactly this name.
2. If `__wsl_builder` already exists, terminate it if necessary and unregister it. Never wildcard or partially match distro names.
3. Create a unique temporary working directory.
4. Fetch and flatten the official `ubuntu:24.04` container filesystem with local `crane.exe`, producing a rootfs tar. Prefer an explicit Linux platform matching the Windows/WSL machine architecture when needed rather than relying on an ambiguous multi-platform default.
5. Import that tar as WSL2 under the exact temporary distro name `__wsl_builder`, with its VHD/storage placed inside the temporary working directory.
6. Run `provision.sh` inside `__wsl_builder` explicitly as root. Pass/copy required configuration files in a way that does not make the Linux provisioning script dependent on a fixed Windows drive letter or user profile path.
7. If provisioning exits nonzero, fail the entire build. Do not export a `.wsl` file.
8. Run final Linux-side validation. Any validation failure must fail the build and prevent export.
9. Terminate `__wsl_builder` cleanly before exporting it.
10. Export it with WSL's tar/tar.gz export support into the modern `.wsl` artifact. The archive must contain the WSL configuration files at their correct rootfs paths.
11. Name successful artifacts using the build date so an earlier successful artifact is not overwritten, for example `ubuntu-dev-2026-08-07.wsl`.
12. If an artifact with today's name already exists, do not overwrite it. Choose a deterministic additional suffix such as `ubuntu-dev-2026-08-07-2.wsl`, `-3`, etc.
13. On normal completion, unregister `__wsl_builder` and remove temporary build files.
14. On failure, also make a best effort to terminate/unregister exactly `__wsl_builder` and remove temporary build files, while preserving the original build/provisioning error and returning a nonzero exit status.

Cleanup must never delete or unregister any distro other than the exact reserved name `__wsl_builder`.

## PowerShell requirements (`build.ps1`)

Use strict, fail-fast behavior appropriate for PowerShell. Check exit codes from every external executable. A failed `crane`, `wsl`, import, provisioning, validation, terminate, or export command must not be silently ignored.

Resolve all project-relative files relative to the script's own directory, not the caller's current directory.

Keep this layer deliberately thin. It should primarily implement:

- prerequisite checks;
- exact-name staging-distro cleanup;
- temporary-directory lifecycle;
- `crane export`;
- `wsl --import`;
- invocation of `provision.sh` inside the staging distro;
- termination and `wsl --export`;
- final cleanup;
- unique date-based artifact naming.

Do not implement Ubuntu package or user configuration in PowerShell.

Do not download `crane.exe` or invoke Docker/Podman.

Make the image reference easy to locate/change, but default it to exactly:

```text
ubuntu:24.04
```

## Linux provisioning requirements (`provision.sh`)

Use strict/fail-fast Bash behavior. Provisioning must be idempotent enough to rerun safely on a fresh staging image, and any failed required operation must make the script exit nonzero.

### Package update and unminimize

Start from the state supplied by `ubuntu:24.04` and bring it up to date using Ubuntu's normal APT tooling. The produced image should contain current repository updates available at build time.

Run Ubuntu's `unminimize` operation successfully so the resulting system is appropriate for interactive development rather than remaining a minimized container filesystem. Automate its confirmation safely. Be careful that a `yes | command` pipeline combined with `pipefail` can report the `yes` process's expected SIGPIPE as failure; use a robust noninteractive invocation rather than masking genuine `unminimize` failure.

Do not continue if `apt update`, the upgrade, `unminimize`, or any required package installation fails.

### Base utilities

Put the user-editable base package list in one obvious, documented block near the top of `provision.sh`, so it can be expanded later without touching orchestration logic.

For this proof of concept install:

```text
build-essential
g++
git
gh
mc
wget
curl
```

`build-essential` is intentionally singular because that is the Ubuntu package name.

Install the packages as required dependencies, not best-effort suggestions. If any package is unavailable or cannot be installed, the build must fail.

Install whatever additional minimal packages are genuinely required for a well-behaved interactive WSL Ubuntu environment, such as `sudo`, locale support, systemd components, and certificates, but keep optional developer tooling confined to the clearly marked base-utilities block.

Clean APT cache/list material that is safe to regenerate after all package operations have succeeded, to avoid unnecessary template size.

### Preserve the Ubuntu user

The official Ubuntu 24.04 container image currently supplies the account:

```text
ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash
```

Do not delete, rename, or recreate it. Validate that:

- user `ubuntu` exists;
- its UID is exactly `1000`;
- its primary GID is exactly `1000`.

Treat a mismatch as an unsupported base-image change and fail the build instead of trying to repair it heuristically.

Make `ubuntu` an appropriate sudo-capable development user and configure passwordless sudo through a dedicated file under `/etc/sudoers.d/`. Set safe ownership and mode on that file and validate it with `visudo` if available/installed. Do not set a known/default password.

### WSL configuration

Install `/etc/wsl.conf` with at least the settings required to:

- enable systemd;
- select `ubuntu` as the default user.

Install `/etc/wsl-distribution.conf` for the modern `.wsl` format. It must at minimum establish:

- default UID `1000`;
- a sensible default distribution name such as `Ubuntu-Dev`.

There is no need for an interactive OOBE account-creation command because UID/GID 1000 user `ubuntu` is deliberately already present in the template.

Follow Microsoft's current `.wsl` requirements for these files, including `root:root` ownership and mode `0644`.

Avoid adding Start Menu icons or terminal-profile assets unless they are actually required for a valid `.wsl` file. Keep the POC small.

## Validation before export

Validation is part of the build, not a warning/reporting phase. At minimum verify from inside the staging distro that:

- `/etc/os-release` identifies Ubuntu 24.04;
- `ubuntu` exists at UID 1000 and primary GID 1000;
- all requested base utility packages are installed according to `dpkg-query`/APT state;
- `sudo` is installed;
- the passwordless sudoers configuration is syntactically valid;
- `/etc/wsl.conf` and `/etc/wsl-distribution.conf` exist with expected ownership/mode and critical values;
- systemd packages/binaries needed for `[boot] systemd=true` are installed;
- there are no unfinished/broken dpkg transactions (`dpkg --audit` or equivalent appropriate validation).

Do not attempt to declare systemd or WSLg operational merely from the container-derived rootfs while provisioning. Those behaviors require a real WSL launch. The staging distro itself is a real WSL instance, so if a restart is required to meaningfully validate systemd/default-user behavior, the PowerShell orchestrator may perform a controlled terminate/relaunch validation pass before final export. Keep such WSL lifecycle validation outside the portable Linux provisioning policy where appropriate.

If practical, after provisioning and restart, verify that a normal `wsl -d __wsl_builder` command resolves to UID 1000/`ubuntu` rather than root, and that systemd is PID 1. Failure must prevent export.

Do not make WSLg GUI/audio testing a required POC build step, but preserve UID 1000 specifically for correct WSL/WSLg integration.

## Output rules

Only publish/leave behind an artifact after every required step and validation has passed.

Examples:

```text
ubuntu-dev-2026-08-07.wsl
ubuntu-dev-2026-08-07-2.wsl
```

Never truncate or replace a prior successful `.wsl` artifact.

A partially written output should use a temporary filename/location and only be moved/renamed to its final `.wsl` name after `wsl --export` succeeds.

## Failure semantics

The implementation should make failure boring and obvious:

- print which high-level phase failed;
- propagate a nonzero exit code;
- never convert an APT/provisioning error into a successful artifact;
- never leave a newly generated file with the intended final `.wsl` name after a failed export;
- best-effort cleanup must not hide the primary error;
- stale `__wsl_builder` from this tool may always be destroyed at the start or end of a build.

## Future WSLC migration

Keep the boundary between acquiring/staging the Linux rootfs and provisioning it explicit.

Current backend:

```text
crane export ubuntu:24.04 -> rootfs.tar
wsl --import -> __wsl_builder
provision.sh inside WSL
wsl --export -> .wsl
```

Expected future direction once WSLC is stable:

```text
wslc build/create using Ubuntu 24.04
Linux provisioning logic reused from provision.sh
wslc export container filesystem -> .wsl-compatible rootfs
```

Do not prematurely add WSLC support to this POC. Instead, keep `provision.sh`, configuration assets, package definitions, validation logic, and artifact semantics sufficiently independent that switching the staging backend does not require rewriting the Linux setup.

## POC acceptance test

The agent implementing this brief should actually test the safe portions available in its environment where possible. On an appropriate Windows host with stable WSL and `crane.exe` beside the script, the intended end-to-end acceptance flow is:

```powershell
.\build.ps1

wsl --install --from-file .\ubuntu-dev-YYYY-MM-DD.wsl --name __wsl_poc_test
wsl -d __wsl_poc_test -- id
wsl -d __wsl_poc_test -- sudo -n true
wsl -d __wsl_poc_test -- systemctl is-system-running
```

The installed template should start as `ubuntu`/UID 1000, `sudo -n true` should succeed, required utilities should exist, and systemd should be PID 1/running sufficiently for a normal WSL developer distribution.

Any test distro created by the implementer should be explicitly named and cleaned up without touching unrelated user distributions.

## Authoritative references

Before implementation, check the current Microsoft documentation for the modern `.wsl` distribution format and current WSL CLI flags rather than assuming preview-era syntax remains unchanged:

- Microsoft: https://learn.microsoft.com/windows/wsl/build-custom-distro
- Microsoft: https://learn.microsoft.com/windows/wsl/basic-commands
- Microsoft: https://learn.microsoft.com/windows/wsl/wsl-config
- `crane export`: https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane_export.md

The goal is a proof of concept, so favor clarity, determinism, strict validation, and easy future modification over a large framework or GUI.
