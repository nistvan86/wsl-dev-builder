# WSL Dev Builder - Staged Agent Isolation Implementation Plan

## Goal

Create an isolated-agent version of `wsl-dev-builder` based on the current `main` branch.

The resulting WSL distro should progressively protect the Windows host from an AI agent running inside the distro.

The stages are deliberately cumulative. Complete them in order. Each stage is a valid stopping point.

Do not rename the `ubuntu` user, change artifact naming, or introduce build profiles during the early stages. Those changes add complexity without improving isolation.

## Threat model

Assume:

- The AI agent runs as the default `ubuntu` Linux user.
- The agent can execute arbitrary shell commands as that user.
- The agent may be prompt-injected into running malicious commands.
- The agent must not have `sudo`.
- The agent must not automatically or manually access Windows drives.
- The agent must not execute Windows programs.
- The agent may have normal Internet access unless a later stage removes it.
- The Windows user remains trusted and may intentionally run `wsl.exe -d <name> -u root` for maintenance.
- The agent itself must not be given an external Windows shell, Windows filesystem tool, Docker Desktop API, MCP tool, IDE integration, or other host-side capability that bypasses WSL.

The last point is important. These changes isolate a process running inside WSL. They cannot protect Windows if the agent is separately given a Windows-side execution tool.

---

# Stage 0 - Establish the isolated branch and baseline

Complexity: very low.

Security improvement: none. This creates a controlled starting point.

## 0.1 Start from current `main`

Run:

```powershell
git checkout main
git pull --ff-only
git status
git checkout -b agent-isolation
```

Require a clean working tree before continuing.

The public repository currently has `main` as its default branch.

## 0.2 Record the current architecture

Do not redesign it.

Keep:

- `build.ps1` as the Windows-side image builder.
- `provision.sh` as the Linux provisioning script.
- `files/wsl.conf` as distro-specific WSL configuration.
- `files/wsl-distribution.conf`.
- Direct `wsl.exe --install --from-file` for distro installation.
- `/usr/local/bin/onboard-agent-distro` for in-distro authentication.
- Ubuntu 24.04.
- UID/GID 1000 user named `ubuntu`.
- Existing Node.js, Codex, GitHub CLI and bubblewrap installation.

The current builder already separates Windows lifecycle handling from Linux provisioning, so preserve this separation. Host users install the artifact directly with `wsl --install --from-file`; the image provides `/usr/local/bin/onboard-agent-distro` for in-distro authentication.

**Implemented status:** Stage 0 preserved the Windows builder/Linux provisioning separation on the `agent-isolation` branch. The original lightweight bootstrap-selection test passed before the bootstrap wrapper was removed. The unchanged baseline build was attempted, but WSL initially blocked import because the stale `__wsl_builder` registration was stuck in `Uninstalling` state; later builds exposed and fixed repository line-ending and runtime validation issues.

## 0.3 Run the existing lightweight test

The former bootstrap-selection test was removed with `bootstrap.ps1`. Artifact selection is now an explicit user choice when invoking `wsl --install --from-file`.

## 0.4 Build one unchanged baseline image

Run:

```powershell
.\build.ps1
```

Install it temporarily and confirm the current behavior before changing anything.

Do not commit generated `.wsl` artifacts.

## Stage 0 commit

```text
chore: establish agent isolation branch
```

---

# Stage 1 - Disable Windows filesystem mounting and Windows interop

Complexity: low.

Security improvement: high against accidental host filesystem damage.

This is the first useful cut point.

**Implemented status:** `files/wsl.conf` disables automounting, fstab processing, Windows interop, and Windows PATH injection. `provision.sh` validates the exact settings. `build.ps1` checks the restarted default user, DrvFs mounts, that `/mnt/c` and `/mnt/d` are not mounted (empty mountpoint directories are tolerated), Windows executables, WSLInterop, and manual C: mounting. README guidance documents the resulting boundary and its root-user limitation.

WSL supports disabling automatic DrvFs mounts and Windows executable interop on a per-distro basis. `automount.enabled=false` does not disable DrvFs itself, so the non-root requirement in Stage 2 remains necessary.

## 1.1 Modify `files/wsl.conf`

Change it from:

```ini
[boot]
systemd=true

[user]
default=ubuntu
```

to:

```ini
[boot]
systemd=true

[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=ubuntu
```

Do not modify global `%UserProfile%\.wslconfig` in this stage.

Microsoft documents:

- `automount.enabled=false` prevents automatic C:/D: DrvFs mounts.
- `mountFsTab=false` prevents `/etc/fstab` processing at WSL startup.
- `interop.enabled=false` prevents launching Windows processes.
- `appendWindowsPath=false` prevents Windows executable paths being appended to Linux `$PATH`.

## 1.2 Add static validation to `provision.sh`

After installing `/etc/wsl.conf`, validate that it contains all four settings.

Do not use a loose test such as only checking that the file exists.

Validate exact configuration semantics, for example with `grep` or a small shell helper.

The build must fail if any of these are missing:

```text
[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false
```

## 1.3 Add runtime validation to `build.ps1`

After the existing distro termination/restart step, execute tests as the default `ubuntu` user.

Require all of the following:

```bash
test "$(id -u)" = 1000
test "$(id -un)" = ubuntu

! findmnt -rn -t drvfs | grep -q .

test ! -e /mnt/c
test ! -e /mnt/d

! command -v cmd.exe
! command -v powershell.exe
! command -v explorer.exe
```

Also test the WSL interop registration if present on the installed WSL version:

```bash
test ! -e /proc/sys/fs/binfmt_misc/WSLInterop
```

Do not make the test depend only on `$PATH`.

## 1.4 Test manual DrvFs mounting as `ubuntu`

Create a temporary directory:

```bash
mkdir -p "$HOME/.isolation-mount-test"
```

Attempt:

```bash
mount -t drvfs C: "$HOME/.isolation-mount-test"
```

The command must fail.

Remove the directory afterwards.

The test should explicitly fail the build if the mount unexpectedly succeeds.

## 1.5 Update README

Document that this branch/image intentionally has:

```text
No /mnt/c or /mnt/d
No automatic fstab mounts
No Windows executable interop
No Windows PATH injection
```

Also document that Linux root could still manually mount DrvFs, which is why Stage 2 removes runtime privilege escalation. Microsoft explicitly states that DrvFs drives can still be manually mounted when automount is disabled.

## Stage 1 commit

```text
feat: disable Windows mounts and interop
```

### Cut point after Stage 1

Good protection against accidental commands such as:

```bash
rm -rf /mnt/c/Users/...
```

Not sufficient if the agent can become Linux root.

---

# Stage 2 - Remove runtime root access

Complexity: low to medium.

Security improvement: critical.

This is the minimum stage recommended for actually running an autonomous agent.

The current `provision.sh` installs `sudo`, puts `ubuntu` in the `sudo` group, and creates `ubuntu ALL=(ALL) NOPASSWD:ALL`. Remove all three behaviors.

**Implemented status:** `provision.sh` no longer installs or configures sudo, locks root and ubuntu passwords, and rejects sudo, wheel, docker, lxd, disk, libvirt, and kvm group membership. `build.ps1` repeats the forbidden-group and absent-sudo checks, and README examples use a negative sudo test.

## 2.1 Stop installing `sudo`

Change:

```bash
apt-get install -y --no-install-recommends sudo locales systemd systemd-sysv dbus ca-certificates apt-utils "${BASE_UTILITIES[@]}"
```

to remove `sudo`.

Do not add another privilege escalation tool as a replacement.

## 2.2 Remove sudo group membership configuration

Delete:

```bash
usermod -aG sudo ubuntu
```

After user validation, explicitly ensure that `ubuntu` is not a member of dangerous groups.

At minimum reject:

```text
sudo
wheel
docker
lxd
disk
libvirt
kvm
```

Do not blindly replace all supplementary groups. Validate and fail instead.

## 2.3 Delete passwordless sudo configuration

Delete creation of:

```text
/etc/sudoers.d/ubuntu
```

Delete the corresponding `chmod`.

Delete `visudo` validation that only exists for this file.

## 2.4 Explicitly lock password-based privilege paths

During provisioning, run as root:

```bash
passwd -l root
passwd -l ubuntu
```

The WSL default-user mechanism does not require a Linux login password.

The trusted Windows user can still intentionally enter the distro as root using:

```powershell
wsl -d <distro-name> -u root
```

That is acceptable under this threat model.

## 2.5 Update package validation

Remove `sudo` from:

```bash
for package in ...
```

Remove tests requiring `visudo`.

Add:

```bash
! command -v sudo
```

as a runtime requirement.

## 2.6 Update README examples

The current README includes:

```powershell
wsl -d __wsl_poc_test -- sudo -n true
```

Remove it.

Replace it with a negative privilege test, for example:

```powershell
wsl -d __wsl_poc_test -- bash -lc 'command -v sudo && exit 1 || exit 0'
```

## 2.7 Add group validation to `build.ps1`

As `ubuntu`, collect:

```bash
id
id -nG
```

Fail if any forbidden group is present.

## Stage 2 commit

```text
security: remove runtime sudo and privileged groups
```

### Cut point after Stage 2

At this point:

- Windows drives are not mounted.
- Windows programs cannot be launched normally.
- The agent cannot simply run `sudo`.
- A manual `mount -t drvfs C:` attempt as the agent should fail.

Residual risk is primarily Linux local privilege escalation and alternate WSL integration surfaces.

---

# Stage 3 - Stop inheriting Windows credentials and add mandatory isolation tests

Complexity: medium.

Security improvement: high for prompt-injected agents.

The former Windows bootstrap wrapper reused an authenticated Windows `gh.exe` token and sent it into the distro through stdin. The current design removes that wrapper and performs onboarding inside the installed distro.

**Implemented status:** `bootstrap.ps1` was removed. GitHub login and Codex device authentication are provided by `/usr/local/bin/onboard-agent-distro`, which runs inside the registered distro and never reads Windows credentials. `tests/isolation-runtime.sh` validates identity, mounts, interop, daemon sockets, protected paths, and developer tools during `build.ps1` before export; it is not run after `.wsl` deployment.

## 3.1 Remove Windows GitHub token reuse

The former PowerShell authentication helper was removed with `bootstrap.ps1`. Authentication is now implemented by the distro-owned `onboard-agent-distro` command.

Delete:

- Discovery of Windows `gh.exe`.
- `gh auth token` execution on Windows.
- `$hostToken`.
- The `--with-token` branch.

Always perform authentication inside the isolated distro.

Keep authentication associated only with the `ubuntu` account inside that distro.

Do not read credentials from:

```text
Windows gh
Windows environment variables
Windows credential files
/mnt/c
```

## 3.2 Keep Codex device authentication

`onboard-agent-distro` runs the existing model inside the distro:

```bash
codex login --device-auth
```

Authentication remains interactive and associated with the `ubuntu` account.

## 3.3 Create `tests/isolation-runtime.sh`

Add a dedicated test script.

Requirements:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
```

The script must fail if any invariant is violated.

Test:

```text
default user is ubuntu
UID is 1000
sudo executable is absent
forbidden groups are absent
no drvfs filesystem is mounted
/mnt/c is absent
/mnt/d is absent
WSLInterop is absent
Windows executables are unavailable
manual drvfs mount as ubuntu fails
Docker socket is not accessible
Podman socket is not accessible
containerd socket is not accessible
/etc is not writable by ubuntu
/usr is not writable by ubuntu
/opt is not writable by ubuntu
Codex exists
gh exists
node exists
npm exists
bwrap exists
```

For daemon sockets inspect at least:

```text
/run/docker.sock
/var/run/docker.sock
/run/podman/podman.sock
/run/containerd/containerd.sock
```

A socket may exist for some host integration reason. Fail when the `ubuntu` user can actually read/write it.

## 3.4 Run the isolation test from `build.ps1`

After restarting the staging distro and before export:

```text
run tests/isolation-runtime.sh as ubuntu
```

The image must not be exported if the test fails.

## 3.5 Post-install isolation audit

**Deferred by design:** The isolation audit is build-time-only. The installed `.wsl` image is not re-audited by the onboarding command. Users can run the commands in the final regression section manually when they need post-install verification.

## 3.6 Ensure validation failure is fail-closed

If isolation validation fails:

- Print the failed invariant.
- Do not authenticate GitHub.
- Do not authenticate Codex.
- Leave the distro registered for manual inspection, matching WSL's direct installation behavior.
- Return non-zero.

## Stage 3 commit

```text
security: add mandatory runtime isolation validation
```

### Cut point after Stage 3

This is a strong practical stopping point for protection against accidental destructive behavior and common prompt-injection paths.

---

# Stage 4 - Reduce Linux local privilege-escalation surface

Complexity: medium.

Security improvement: medium to high.

This stage makes it harder for a hostile process to turn the non-root `ubuntu` account into root.

**Current implementation note:** The `unminimize` removal and GPU integration disablement are intentionally deferred. Provisioning continues to run `unminimize`, and `files/wsl.conf` does not disable GPU integration, while the image's package, runtime, and host-integration behavior are evaluated. SUID/SGID, capability, and privileged-path hardening remain active in this branch.

**Implemented status:** `provision.sh` keeps the explicit package list, temporarily installs `libcap2-bin`, records and strips SUID/SGID bits, audits system/runtime roots for high-risk file capabilities, then purges the build-only capability tooling before final validation. The runtime test does not repeat SUID/SGID or capability audits. The capability scan intentionally excludes the large user data tree under `/home` to avoid an unbounded build scan. GPU integration remains at its default.

## 4.1 Remove `unminimize`

The current provisioning explicitly runs Ubuntu's `unminimize` before installing the required development packages.

Delete:

```bash
command -v unminimize ...
printf 'y\n' | unminimize
...
```

Keep explicit `apt-get install --no-install-recommends` package installation.

The goal is to install only what this development image actually needs.

## 4.2 Keep the existing explicit package list initially

Do not aggressively remove development tools yet.

Keep:

```text
build-essential
g++
git
gh
make
mc
wget
curl
bubblewrap
pkg-config
```

First establish that removing `unminimize` does not break expected use. This comparison is deferred until the current image behavior has been evaluated.

Further package reduction can happen later.

## 4.3 Strip SUID and SGID bits from runtime binaries

After all packages and developer tools have been installed, enumerate:

```bash
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print
```

Record the list in build output.

For the isolated-agent image, remove SUID/SGID from regular files unless there is a documented requirement for one.

A simple hardened policy is:

```bash
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod u-s,g-s {} +
```

Then validate:

```bash
! find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print -quit | grep -q .
```

Do this only in this isolation branch/image, not in a general-purpose Ubuntu image.

## 4.4 Audit Linux file capabilities

Install `libcap2-bin` temporarily for the build-time audit, then purge it before the final image validation. It is not a runtime dependency.

Run:

```bash
getcap -r /bin /sbin /usr /lib /lib64 /opt 2>/dev/null
```

Fail if ordinary runtime binaries have high-risk capabilities such as:

```text
cap_sys_admin
cap_dac_override
cap_dac_read_search
cap_sys_ptrace
cap_sys_module
cap_sys_rawio
cap_setuid
cap_setgid
```

Do not silently allow a new capability after package updates.

## 4.5 Validate privileged paths are not writable

As `ubuntu`:

```bash
find /etc /usr /opt -xdev -type f -writable -print
```

Expected output: empty.

Also inspect writable directories under those roots.

## 4.6 Disable GPU integration for this distro

Add to `files/wsl.conf`:

```ini
[gpu]
enabled=false
```

Microsoft documents this as the per-distro switch controlling access to the Windows GPU through paravirtualization.

This is not required for filesystem protection, but removes an unnecessary host integration surface for a headless coding agent. **Deferred in the current implementation:** GPU integration remains at its default because disabling it is intentionally postponed.

## Stage 4 commit

```text
security: reduce local privilege escalation surface
```

### Cut point after Stage 4

This is the preferred WSL-only stopping point when the agent may execute untrusted project content.

---

# Stage 5 - Remove unnecessary root services

Complexity: medium to high.

Security improvement: moderate.

This changes one of the repository's current design assumptions, so keep it separate.

The current image deliberately enables systemd and validates that PID 1 is systemd.

**Current implementation note:** The systemd removal is intentionally deferred. This branch continues to install and run systemd, retains the systemd-specific provisioning and masks, and validates systemd as PID 1. Revisit this stage only after testing the agent workflow without systemd.

**Implemented status:** `files/wsl.conf` retains `systemd=true`; `provision.sh` installs systemd, systemd-sysv, and dbus, restores the systemd unit masks, and validates the packages and commands. `build.ps1` checks systemd as PID 1, and README retains the systemctl installation check.

## 5.1 Determine whether the agent actually needs systemd

Test these without systemd:

```text
codex
gh
git
node
npm
make
g++
bubblewrap
```

If they work, proceed.

## 5.2 Disable systemd

Change:

```ini
[boot]
systemd=true
```

to:

```ini
[boot]
systemd=false
```

WSL supports distro authors selecting systemd true or false in `/etc/wsl.conf`.

## 5.3 Stop explicitly installing systemd runtime packages

Review removing explicit installation of:

```text
systemd
systemd-sysv
dbus
```

Do not blindly purge libraries required by other packages.

The goal is to stop running unnecessary privileged daemons, not to force package removal if dependencies need shared libraries.

## 5.4 Remove systemd-specific provisioning

Delete or simplify the block that masks:

```text
systemd-resolved.service
systemd-networkd.service
NetworkManager.service
systemd-tmpfiles...
tmp.mount
```

These masks are unnecessary when systemd is not the runtime init system.

## 5.5 Update build validation

Delete:

```bash
ps -p 1 -o comm= | grep -qx systemd
```

Replace with validation that the expected WSL init environment starts successfully and developer tools work.

## 5.6 Update README

Remove:

```powershell
systemctl is-system-running
```

from installation tests.

## Stage 5 commit

```text
security: remove unnecessary systemd runtime services
```

---

# Stage 6 - Audit host-wide WSL integrations

Complexity: medium.

Security improvement: situational.

Important: do not automatically modify global WSL settings from `build.ps1` or onboarding.

**Implemented status:** `host-isolation-audit.ps1` is read-only and reports WSL/Windows versions, `.wslconfig`, WSLg, networking, Hyper-V firewall visibility, and Docker Desktop indicators. Runtime validation reports `/mnt/wslg`, rejects Docker availability, and checks daemon sockets; no host-wide setting is changed automatically.

Microsoft documents that `.wslconfig` applies globally to all WSL 2 distributions, unlike `/etc/wsl.conf`, which is per distro.

## 6.1 Add `host-isolation-audit.ps1`

Create a read-only Windows-side audit script.

It should inspect and report:

```text
WSL version
Windows version
global .wslconfig existence
WSLg configuration
networking mode
Hyper-V firewall status
Docker Desktop presence
Docker WSL integration risk
```

Do not change anything automatically.

## 6.2 Detect Docker Desktop exposure

Docker Desktop allows WSL integration to be enabled for individual distributions and exposes Docker functionality inside those distributions.

After onboarding, ensure isolation validation has already passed at build time and fail the manual deployment check if the agent can use:

```bash
docker
```

or access:

```text
/run/docker.sock
/var/run/docker.sock
```

Document:

```text
Docker Desktop -> Settings -> Resources -> WSL Integration
```

The isolated distro must not be enabled there.

## 6.3 Handle WSLg as an optional host-wide hardening measure

Microsoft exposes:

```ini
[wsl2]
guiApplications=false
```

only through global `.wslconfig`.

Because that affects other WSL distributions:

- Report it in `host-isolation-audit.ps1`.
- Do not change it automatically.
- Document that disabling WSLg reduces host integration if the machine does not need Linux GUI applications.

## 6.4 Report `/mnt/wslg`

The runtime isolation test should report whether:

```text
/mnt/wslg
```

exists.

Do not treat it as equivalent to `/mnt/c`.

At this stage it may become a hard failure if the user's chosen policy is "no unnecessary WSL host integration."

## Stage 6 commit

```text
security: audit host WSL integration surfaces
```

---

# Stage 7 - Network containment

Complexity: high.

Security improvement: high against host-service attacks.

This is where WSL-specific limitations become significant.

**Implemented status:** No firewall rules are applied. README documents Normal Internet, global `networkingMode=none`, and explicit host-firewall policies, including their shared/global scope. Runtime validation reports default-gateway, host SMB/SSH, and common Docker-port reachability without failing by default.

## 7.1 Do not assume Hyper-V firewall policy is per distro

Microsoft documents WSL Hyper-V firewall policy under the shared WSL `VMCreatorId`:

```text
{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}
```

and notes that host/container loopback is enabled by default.

Therefore do not silently install firewall rules and claim they affect only this isolated distro.

## 7.2 Add network modes to documentation

Define three supported policies.

### Policy A - Normal Internet

Default.

Agent can access Internet and potentially network services exposed by Windows.

Use for normal Codex/GitHub operation.

### Policy B - No WSL networking

Global `.wslconfig`:

```ini
[wsl2]
networkingMode=none
```

Microsoft documents that `networkingMode=none` disconnects WSL networking, but `.wslconfig` applies to all WSL 2 distributions.

This prevents normal cloud-agent operation.

Do not apply automatically.

### Policy C - Host firewall hardening

Use Windows Hyper-V firewall to restrict WSL-host communication.

Possible host-side controls include disabling WSL loopback and changing outbound policy, but these settings affect WSL as a VM creator rather than this one distro.

Require explicit user opt-in before generating or applying such rules.

## 7.3 Add network probes to isolation validation

Test and report whether the distro can reach:

```text
its default gateway
Windows host localhost
common Docker daemon ports if relevant
SMB port 445 on the host
SSH port 22 on the host
```

Report results rather than failing by default.

The user can later convert individual probes into mandatory failures according to their network policy.

## Stage 7 commit

```text
security: add optional WSL network containment policy
```

---

# Stage 8 - Add a second process-level sandbox around the AI agent

Complexity: high.

Security improvement: defense in depth.

The image already installs `bubblewrap`.

**Current implementation note:** Stage 8 is intentionally deferred and is not part of the current image. The WSL user, filesystem, host-integration, and runtime validation stages are the current stopping point; bubblewrap is not used to wrap Zed or another remote agent automatically.

**Implemented status:** The launcher and its provisioning smoke tests were added and then completely removed. `bubblewrap` remains in the base utility list and is checked as available developer tooling, but no process-level sandbox is installed or invoked.

Use it as an additional containment layer rather than relying only on the Linux user account.

## 8.1 Create an agent launcher

Add:

```text
/usr/local/bin/isolated-agent
```

Root ownership:

```text
root:root
0755
```

The launcher should start the AI agent under bubblewrap.

## 8.2 Restrict filesystem visibility

Expose read-only:

```text
/usr
/bin
/lib
/lib64
/etc
```

Expose writable only what the agent actually needs, for example:

```text
/home/ubuntu/work
/home/ubuntu/.codex
/home/ubuntu/.cache
/tmp
```

Do not expose arbitrary Linux directories just for convenience.

## 8.3 Unshare namespaces

Use bubblewrap isolation for:

```text
mount namespace
PID namespace
IPC namespace
UTS namespace
user namespace where supported
```

Keep network shared initially because Codex and GitHub need Internet access.

A separate no-network launcher can additionally unshare networking for offline tasks.

## 8.4 Make onboarding print the intended invocation

After successful installation:

```text
Run the AI agent through: isolated-agent
```

Do not automatically replace the user's shell until this mechanism has been tested.

## 8.5 Test sandbox escape assumptions

Inside the launcher verify that the agent cannot see filesystem paths that were intentionally omitted.

Also rerun all Stage 3 isolation tests from inside the bubblewrap environment.

## Stage 8 commit

```text
security: add process-level bubblewrap confinement
```

---

# Stage 9 - Hard security boundary

Complexity: architectural change.

Security improvement: strongest.

Stop extending the WSL implementation here.

WSL 2 distributions share WSL infrastructure and the Linux kernel, and WSL intentionally contains host integration features. Docker's current WSL security documentation similarly notes the shared-kernel limitation and recommends stronger VM isolation where maximum security is required.

If the requirement becomes:

```text
Even a successful Linux root exploit must not allow the agent to access Windows.
```

create a separate Hyper-V VM builder instead of adding more WSL configuration.

Do not claim the WSL branch provides that guarantee.

---

# Required final regression test

Before merging any chosen stopping stage:

```powershell
.\build.ps1
```

Install a temporary distro:

```powershell
wsl --install --from-file .\ubuntu-dev-YYYY-MM-DD.wsl --name __wsl_agent_test --location <temporary-location>
wsl -d __wsl_agent_test -- onboard-agent-distro
```

As the default user verify:

```bash
id

findmnt
findmnt -t drvfs

ls -la /mnt

command -v sudo
command -v cmd.exe
command -v powershell.exe

cat /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null || true

mkdir -p ~/mount-test
mount -t drvfs C: ~/mount-test && exit 1 || true
rmdir ~/mount-test

id -nG

find /etc /usr /opt -xdev -type f -writable -print

find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null

find /run /var/run -type s -ls 2>/dev/null

codex --version
gh --version
node --version
npm --version
bwrap --version
```

Expected security properties:

```text
ubuntu UID 1000
no sudo
no privileged groups
no DrvFs mounts
no /mnt/c
manual C: mount fails
no WSLInterop registration
no Windows executables
no accessible Docker/Podman/containerd daemon
no writable privileged configuration/program files
developer tooling still functions
```

From Windows, confirm trusted maintenance access still works:

```powershell
wsl -d __wsl_agent_test -u root -- id
```

Then remove the temporary distro:

```powershell
wsl --unregister __wsl_agent_test
```

Do not merge if any security invariant fails.

# Suggested stopping points

| Cut | Completed stages | Intended use |
|---|---|---|
| A | 0-2 | Protect against accidental host filesystem destruction |
| B | 0-3 | Autonomous agent with mandatory isolation regression tests |
| C | 0-4 | Untrusted/prompt-injected workloads with reduced Linux escalation surface |
| D | 0-6 | Headless hardened WSL agent distro with host integration auditing |
| E | 0-8 | Maximum practical WSL defense in depth |
| VM boundary | 9 | Treat malicious root compromise as part of the threat model |