# Follow-up implementation plan: Codex-ready WSL image and developer bootstrap

## Goal

Extend the existing `wsl-dev-builder` project at:

https://github.com/nistvan86/wsl-dev-builder/tree/main

The current repository already builds a date-stamped Ubuntu 24.04 `.wsl` image from `ubuntu:24.04` using `crane.exe`, a temporary `__wsl_builder` distro, `build.ps1`, and portable Linux provisioning in `provision.sh`.

Implement the next stage without changing that basic architecture:

1. Put Codex CLI and the Linux tooling it needs into every newly built `.wsl` image.
2. Install Node.js LTS through `nvm` for the `ubuntu` user, as general Codex/developer tooling for skills and documentation workflows. Do not use npm to install Codex itself.
3. Install `bubblewrap`, `make`, and `pkg-config` from Ubuntu packages.
4. Make the built image's `ubuntu` shell prompt show the actual WSL distro name from `WSL_DISTRO_NAME`.
5. Add a separate `bootstrap.ps1` that creates a named developer distro from the newest built image, at a caller-supplied storage location, then authenticates GitHub CLI and Codex inside that instance.
6. Never put GitHub or Codex credentials into the reusable `.wsl` image.

All existing fail-fast behavior is important. A failed dependency install, Codex install, validation, WSL install, or authentication step must return failure instead of reporting a partially completed operation as successful.

## Current repository structure

Work with the repository as it exists now:

- `build.ps1`: Windows orchestration, `crane`, temporary WSL lifecycle, validation, export.
- `provision.sh`: portable Linux provisioning and Linux-side validation.
- `files/wsl.conf`: systemd and default-user configuration.
- `files/wsl-distribution.conf`: `.wsl` distribution metadata.
- Output naming: `ubuntu-dev-YYYY-MM-DD.wsl`, with `-2`, `-3`, etc. for later same-day builds.

Do not rewrite the builder unnecessarily. Make focused changes and retain its cleanup/error semantics.

## 1. Linux image additions in `provision.sh`

Keep portable Linux developer-environment setup here.

### Ubuntu package additions

Add `bubblewrap`, `make`, and `pkg-config` to the explicitly installed developer packages. `make` is already a dependency of `build-essential`, but keep it explicit because it is part of the intended developer tool contract. Ensure `curl` and `ca-certificates` remain installed because the upstream installers require HTTPS downloads.

Validate at the end of provisioning that:

```bash
command -v bwrap
command -v make
command -v pkg-config
```

succeeds as well as the existing dpkg validation for installed packages.

### Install nvm and latest Node LTS

Install `nvm` into `/home/ubuntu/.nvm`, owned by `ubuntu`, and install the latest Node.js LTS available at build time. This is deliberately part of the image so a freshly rebuilt template gets the current LTS.

Requirements:

- Perform the nvm and Node installation as the `ubuntu` user, with `HOME=/home/ubuntu` and the correct `NVM_DIR`.
- Use the official `nvm-sh/nvm` installation mechanism. Do not install Ubuntu's `nodejs` package as a substitute.
- Do not assume an interactive/login shell while provisioning. Explicitly source `nvm.sh` for build-time commands.
- Use nvm's LTS selector, for example `nvm install --lts`, then make that installed LTS the default.
- Ensure a normal future interactive Bash session for `ubuntu` loads nvm and resolves `node` and `npm` without manual setup.
- Fail the build if nvm installation, Node LTS installation, or validation fails.

The nvm upstream installer uses versioned install URLs. Do not hard-code a stale version from this plan. At implementation time use the current stable nvm release in the install URL, and keep that version in one clearly named variable near the nvm install code so it is easy to update. As of 2026-08-07 the latest upstream release is `v0.40.6`, but verify upstream before implementation.

Validate as `ubuntu`, not root, in a shell that explicitly loads nvm:

```bash
nvm --version
node --version
npm --version
```

Also validate that a normal interactive Bash environment exposes the expected Node installation.

### Install Codex CLI

Use OpenAI's current standalone Linux installer, executed as the `ubuntu` user:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

Do not install Codex through npm merely because Node is present. Node LTS is being installed for developer/Codex skill workflows, not as the Codex distribution mechanism.

Requirements:

- Run the Codex installer with `HOME=/home/ubuntu` so the installation belongs to the intended default user rather than root.
- Make sure the installed executable is on `ubuntu`'s PATH in a fresh normal shell.
- Fail immediately if the installer fails.
- Validate `command -v codex` and `codex --version` as `ubuntu` before export.
- Print or otherwise retain the installed Codex version in the build output so a build can be identified later.
- Do not run `codex login` while building the image.

The standalone installer is intentionally fetched at build time so a fresh `.wsl` build gets the current Codex CLI. Do not silently fall back to an older or npm-installed Codex if that download/install fails.

## 2. WSL-aware Bash prompt, owned by `build.ps1`

The WSL-specific prompt customization must be orchestrated by `build.ps1`, not added to `provision.sh`. This preserves the goal that the Linux provisioning script can later be reused for LXC or another Linux-side environment.

After portable Linux provisioning succeeds, have `build.ps1` run a command inside the staging WSL distro as `ubuntu` that adds this prompt definition to `/home/ubuntu/.bashrc`:

```bash
echo -e '\nexport PS1="\[\e]0;\u@\${WSL_DISTRO_NAME}: \w\a\]${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\${WSL_DISTRO_NAME}\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$"' >> ~/.bashrc
```

Preserve the literal `${WSL_DISTRO_NAME}` expression so it is evaluated when the user opens that particular distro, not while building `__wsl_builder`.

Prefer a small clearly marked managed block or a marker check so the operation is idempotent if the staging step is ever retried. Do not let PowerShell interpolate the Bash `$` expressions. Validate after injection that `.bashrc` contains the literal `WSL_DISTRO_NAME` reference and is still owned by `ubuntu:ubuntu`.

This prompt modification is the intentional Windows/WSL-specific exception to the normal `provision.sh` ownership of Linux configuration.

## 3. New `bootstrap.ps1`

Create a separate PowerShell script beside `build.ps1` named `bootstrap.ps1`.

Its purpose is to instantiate a developer distro from an existing built image and perform per-instance authentication. It must not rebuild or mutate the source `.wsl` template.

### Parameters

Provide at least:

```powershell
./bootstrap.ps1 -Name <distro-name> -Location <storage-directory>
```

Both `-Name` and `-Location` are required.

Also provide an optional image override, for example:

```powershell
./bootstrap.ps1 -Name dev-foo -Location D:\WSL\dev-foo -ImagePath .\ubuntu-dev-2026-08-07.wsl
```

Without `-ImagePath`, select the newest artifact beside the script matching the project's existing names:

```text
ubuntu-dev-YYYY-MM-DD.wsl
ubuntu-dev-YYYY-MM-DD-N.wsl
```

Define "newest" by parsing and comparing the date first and the optional same-day numeric suffix second, where no suffix is build 1. Do not use filesystem modification time as the primary ordering because copied files can have misleading timestamps. Fail clearly if no matching artifact exists.

### Preflight and WSL installation

Before making changes:

- Require `wsl.exe`.
- Confirm the installed stable WSL advertises the options used by the script, including `--install`, `--from-file`, `--name`, and `--location`.
- Resolve and validate the selected `.wsl` file.
- Reject an empty/invalid `Name`.
- Fail if a distro with exactly that name is already registered. Do not unregister or overwrite an existing developer distro.
- Fail if the requested storage location would collide with an existing non-empty instance location rather than deleting anything.

Create the distro using the stable WSL `.wsl` install path, conceptually:

```powershell
wsl.exe --install --from-file <image> --name <name> --location <location>
```

Use checked native-process invocation and verify the exit code, consistent with `build.ps1`.

After installation, start the new distro and validate that its default identity is `ubuntu` with UID 1000. Validate `gh`, `codex`, `node`, `npm`, and `bwrap` inside the instance before attempting authentication.

The instance should remain registered if a later authentication step fails. Report failure and the phase that failed so the user can fix the problem or rerun bootstrap without losing the newly created filesystem. Do not automatically unregister a developer instance on an auth failure.

Make the per-instance portion reasonably rerunnable. If the requested distro already exists at initial creation time, still fail rather than assuming it is the correct instance. Authentication helpers themselves may safely recognize already-authenticated state where useful.

## 4. GitHub authentication in `bootstrap.ps1`

All GitHub authentication is per developer instance and runs after WSL creation.

Target `github.com` and configure Git operations for HTTPS.

### Preferred path: reuse an authenticated Windows `gh`

Check for a usable host-side GitHub CLI with `Get-Command gh`/`gh.exe`.

Do not consider its mere presence sufficient. It is usable only if the Windows CLI has a working active authentication for `github.com` and:

```powershell
gh auth token --hostname github.com
```

succeeds and produces a non-empty token.

When usable, transfer that token through a process pipe/stdin into `gh` inside the new WSL distro as `ubuntu`, using the equivalent of:

```text
gh auth token --hostname github.com
    | WSL stdin -> gh auth login --hostname github.com --git-protocol https --with-token
```

Security requirements:

- Never put the GitHub token in a command-line argument.
- Never write it to a temporary file.
- Never print it or include it in logs/error messages.
- Avoid retaining it in a long-lived PowerShell variable if direct stdin piping can be implemented robustly.
- Do not copy the Windows `gh` configuration files wholesale. Transfer only the token through the supported `gh auth login --with-token` interface.

If Windows `gh` exists but is not authenticated, cannot return a token, or otherwise is not usable, use the interactive fallback below.

If Windows `gh` passes the usable-token check but token injection into WSL fails, treat that as an error rather than silently changing authentication strategy and masking a transfer bug.

### Fallback path: authenticate inside WSL

Run interactively as `ubuntu`:

```bash
gh auth login --hostname github.com --git-protocol https
```

Allow GitHub CLI's supported interactive authentication flow. Do not select SSH.

### Final GitHub setup and validation

In either path, run inside WSL as `ubuntu`:

```bash
gh auth setup-git --hostname github.com
gh auth status --hostname github.com
```

Both commands must succeed. This ensures Git uses GitHub CLI as its credential helper for `github.com` and the instance has usable authentication.

## 5. Codex authentication in `bootstrap.ps1`

Codex authentication must always happen inside the new WSL instance as `ubuntu` using device authentication:

```bash
codex login --device-auth
```

Do not copy Codex credentials, `auth.json`, `.codex`, browser cookies, or tokens from Windows or from another distro. Do not offer a different Codex login mechanism in this bootstrap script.

The command must remain attached to the interactive console so the user can see the device URL/code and finish approval in a browser.

After it returns successfully, validate:

```bash
codex login status
```

If device-code authentication is disabled for the user's ChatGPT account/workspace or login otherwise fails, return a clear nonzero error while leaving the new distro intact.

## 6. Failure behavior and credentials

Retain the project's current fail-fast philosophy.

### Image build

Any failure in APT, `unminimize`, nvm, Node LTS, bubblewrap, Codex install, prompt injection, configuration, or validation must prevent the final `.wsl` artifact from being published. Keep the existing `__wsl_builder` cleanup semantics.

### Developer bootstrap

Before WSL installation fails: make no distro changes where possible.

After the new distro has been successfully installed: authentication failure should stop with nonzero status but should not unregister or destroy the developer distro. Clearly identify the failed phase so the user can retry the relevant login.

The reusable `.wsl` artifact must contain no GitHub or Codex credentials. Add explicit validation/documentation for that rule rather than attempting to seed credentials at build time.

## 7. Documentation changes

Update `README.md` to cover:

- Codex CLI is preinstalled by the official standalone installer.
- Node LTS is installed through nvm for `ubuntu` and why it is intentionally present.
- `bubblewrap`, `make`, and `pkg-config` are preinstalled.
- The Bash prompt displays the runtime WSL distro name.
- How to build the template as before.
- How to instantiate the latest image with `bootstrap.ps1` using `-Name` and `-Location`.
- How to override the selected image with `-ImagePath`.
- GitHub token reuse from authenticated Windows `gh`, with interactive HTTPS login fallback.
- Codex uses only `codex login --device-auth` during bootstrap.
- Credentials live only in the created developer instance, never in `.wsl` artifacts.
- A bootstrap auth failure intentionally leaves the created distro in place.

Include concrete PowerShell examples.

## 8. Verification and acceptance criteria

The implementation is complete only after checking the following where practical on Windows with stable WSL:

### Build-time checks

- A fresh `build.ps1` run succeeds from `ubuntu:24.04`.
- It still uses only the reserved `__wsl_builder` name for staging.
- `bubblewrap` is installed and `bwrap` resolves.
- `make` and `pkg-config` are explicitly installed and both commands resolve.
- nvm is installed in the `ubuntu` user's home.
- `nvm --version`, `node --version`, and `npm --version` succeed as `ubuntu`.
- Installed Node is an LTS release selected by nvm and is the default for future shells.
- `codex --version` succeeds as `ubuntu` from a fresh shell.
- `.bashrc` contains the literal runtime `${WSL_DISTRO_NAME}` prompt expression and does not bake in `__wsl_builder`.
- The date-stamped `.wsl` artifact is produced only after every validation passes.
- The staging distro is unregistered after success and after a failed image build.

### Bootstrap checks

- With two or more artifacts present, omitted `-ImagePath` selects the highest date and same-day build index.
- Explicit `-ImagePath` overrides automatic selection.
- The supplied distro name and location are honored.
- Existing distro names are never overwritten/unregistered.
- The created distro defaults to `ubuntu` UID 1000.
- On a Windows host with authenticated `gh`, the token is imported into WSL without appearing in arguments, files, or output.
- Without usable Windows `gh`, interactive `gh auth login --hostname github.com --git-protocol https` runs inside WSL.
- `gh auth setup-git --hostname github.com` and `gh auth status --hostname github.com` succeed afterward.
- Codex authentication always uses `codex login --device-auth` inside WSL.
- `codex login status` succeeds after authentication.
- Authentication failure returns nonzero but does not delete the created developer distro.
- No generated `.wsl` file contains credentials from either authentication mechanism.

Where the development environment cannot execute WSL itself, implement deterministic unit-style tests for pure PowerShell logic such as artifact filename parsing/selection and perform syntax/static checks. Document which Windows-only acceptance checks remain for manual execution rather than claiming they passed.

## 9. Scope boundaries

Do not:

- add Docker or require Docker Desktop;
- download `crane.exe` automatically;
- migrate the stable builder to `wslc` yet;
- install Codex via npm unless OpenAI's official installation guidance changes and the implementation documents that change;
- install Node from Ubuntu's `nodejs` package instead of nvm;
- move the WSL prompt customization into `provision.sh`;
- bake credentials into the template;
- copy host Codex credentials into the instance;
- use SSH as the GitHub protocol in the bootstrap flow;
- unregister an existing or newly bootstrapped developer distro as error cleanup.

Keep Linux provisioning as portable as possible so it can later be adapted for LXC or another Linux isolation environment. Keep WSL-specific lifecycle and prompt work in PowerShell.

## Current authoritative references

- Existing project: https://github.com/nistvan86/wsl-dev-builder/tree/main
- Codex CLI install: https://learn.chatgpt.com/docs/codex/cli
- Codex authentication: https://learn.chatgpt.com/docs/auth
- nvm upstream: https://github.com/nvm-sh/nvm
- nvm releases: https://github.com/nvm-sh/nvm/releases
- Ubuntu 24.04 `bubblewrap`: https://packages.ubuntu.com/noble/bubblewrap
- GitHub CLI `gh auth login`: https://cli.github.com/manual/gh_auth_login
- GitHub CLI `gh auth token`: https://cli.github.com/manual/gh_auth_token
- GitHub CLI `gh auth setup-git`: https://cli.github.com/manual/gh_auth_setup-git
- GitHub CLI `gh auth status`: https://cli.github.com/manual/gh_auth_status
- WSL basic commands: https://learn.microsoft.com/windows/wsl/basic-commands
