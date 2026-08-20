---
name: wsl-dev-instance
description: Build or reuse a WSL developer image from this project, install it as a uniquely named WSL 2 distro, and launch it interactively for first-run onboarding. Use when a user asks for a new developer WSL environment or a project-specific WSL instance.
---

# Build and launch a WSL developer instance

Use this skill only from this repository. Follow `AGENTS.md` as the authoritative build and isolation policy.

## 1. Understand the requested environment

1. Extract any explicit requirements from the user: project purpose, repository path or URL, language/runtime, build system, tools, image name, image comment, distro name, and install location.
2. If the user supplied a concrete Git repository, inspect its developer-facing documentation before choosing a build target. Check, in this order when available:
   - `README*`, `CONTRIBUTING*`, `DEVELOPMENT*`, `docs/`, and setup guides;
   - package/build manifests such as `package.json`, `pyproject.toml`, `requirements*.txt`, `Cargo.toml`, `go.mod`, `CMakeLists.txt`, `Makefile`, and project toolchain files.
3. Infer only clearly documented requirements. Do not invent packages from an unfamiliar project. Ask the user if an essential toolchain choice remains ambiguous.
4. If no specific requirements were provided, use the repository default profile from `build.settings.psd1` when it exists, otherwise use the defaults in `build.ps1`.

## 2. Map requirements to this builder

Use existing modules and base utilities whenever possible:

| Requirement | Builder selection |
| --- | --- |
| GitHub CLI/login | `github` module |
| Node.js/npm | `nodejs` module |
| Codex CLI | `codex` module; it automatically includes `nodejs` and Bubblewrap |
| C/C++ compiler | default `build-essential`, `g++` |
| CMake | `-AddBaseUtilities cmake` |
| Ninja | `-AddBaseUtilities ninja-build` |
| Python | `-AddBaseUtilities python3,python3-venv,pipx` when the project documentation requires it |
| Rust | `-AddBaseUtilities rustc,cargo` when required |
| Go | `-AddBaseUtilities golang-go` when required |

For a reusable project-specific capability not represented by an existing module, add a `packages/<name>/` module before building. Declare all APT dependencies in `system-packages.txt`, dependencies on other modules in `dependencies.txt`, tools in `required-tools.txt`, and use optional `provision.sh`/`onboard.sh` contributors only when necessary. Do not hide package dependencies in `build.ps1`.

Use `-Packages` or `-BaseUtilities` to fully replace the configured selection. Use `-AddPackages` or `-AddBaseUtilities` to extend it. Use `-DistributionDirectory`, `-ImageName`, and `-ImageComment` for a specific build target.

## 3. Reuse a suitable existing artifact first

Before building, inspect `dist/*.wsl.txt` companion manifests. For each candidate, read:

- `Ubuntu base image`
- `Image comment`, when present
- `Installed modules`
- `Base utilities`

An artifact is suitable only when its modules and base utilities cover the documented/requested requirements. Prefer the newest suitable artifact with a useful matching image comment. Do not treat a matching filename alone as sufficient.

If a suitable artifact exists, reuse it; do not rebuild it. If no suitable artifact exists, choose:

- a short distinguishing `-ImageName`, such as `ubuntu-dev-web` or `ubuntu-dev-retroos`;
- an `-ImageComment` that states the target project/purpose and the reason for non-default additions.

The comment must help a later agent decide whether the artifact is suitable. For example:

```powershell
-ImageName ubuntu-dev-retroos `
  -ImageComment 'RetroOS game project: C/C++ build tools plus CMake and Ninja.'
```

If no special target is requested, use the default image name and no comment.

## 4. Build when required

Run `build.ps1` from the project root. Keep artifact selection explicit. Examples:

```powershell
# Default configured profile
.\build.ps1

# Extend the configured profile for a CMake/Ninja project
.\build.ps1 `
  -AddBaseUtilities cmake,ninja-build `
  -ImageName ubuntu-dev-cmake `
  -ImageComment 'CMake and Ninja development environment for <project>.'

# Replace the configured module selection
.\build.ps1 -Packages github,nodejs -ImageName ubuntu-dev-node
```

Do not use `-KeepStagingOnFailure` unless inspecting a build failure. A failed build must not be used as an artifact.

## 5. Install a new distro safely

1. Determine the artifact path selected or built.
2. Choose a short distro name. Honor an explicit user-provided name. Otherwise derive a unique name such as `dev-web`, `dev-retroos`, or `dev-node`.
3. Check registered distributions with `wsl --list --quiet`. Never overwrite, terminate, or unregister an unrelated distro. If the desired name already exists, choose a deterministic suffix such as `-2`.
4. Install from the selected artifact. Include `--location <path>` only when the user supplied or approved that location:

```powershell
wsl --install --from-file <artifact.wsl> --name <distro-name>
```

5. Start the distro **interactively** after installation:

```powershell
wsl -d <distro-name>
```

Do not add `-- command` to this launch. The image’s `[oobe]` configuration automatically runs `onboard-agent-distro` on the first interactive launch, where the user completes GitHub and Codex authentication. If onboarding fails, leave the distro registered; WSL will retry OOBE at the next interactive launch.

## 6. Report the result

Report the artifact reused or built, its companion manifest path, the distro name, any selected overrides, and that the interactive launch is performing or has performed onboarding. Never report that onboarding succeeded unless it actually completed.
