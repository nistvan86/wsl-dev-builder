# Replace crane with WSL containers

Status: implemented and validated on 2026-10-27. The pre-migration state is tagged `crane`.

Validation: PowerShell parser and diff checks passed. One default build on amd64 with WSL/WSLC 3.0.3.0 completed acquisition, tar injection, import, provisioning, existing restart/isolation checks, and export as `dist/ubuntu-dev-wslc-validation.wsl`. No separate installation or mode matrix was run.

## Verified starting point

- Microsoft announced WSL containers general availability on September 29, 2026, in the WSL 3.0.1 release. Use 3.0.1 as the initial minimum supported stable release, plus capability checks.
- This machine reports WSL 3.0.3.0 and `wslc 3.0.3.0`; the executable resolves to `C:\Program Files\WSL\wslc.exe`.
- Local help confirms `create --cidfile --pull`, `export --output`, `image inspect --format json`, and `rm`. Neither `create` nor `image pull` advertises `--platform`.
- These checks establish CLI availability only. Container service access, image pulling, export fidelity, and import compatibility still need the focused experiment below.
- The existing backend boundary is already suitable: `build.ps1` produces `rootfs.tar`, injects LF-normalized provisioning inputs, imports `__wsl_dev_builder`, provisions and validates it, then exports the final artifact.

Sources:

- [Microsoft GA announcement](https://blogs.windows.com/windowsdeveloper/2026/09/29/wsl-containers-now-generally-available/)
- [WSL 3.0.1 release](https://github.com/microsoft/WSL/releases/tag/3.0.1)
- [Microsoft WSL containers guide](https://learn.microsoft.com/en-us/windows/wsl/tutorials/wsl-containers)
- Local `wsl --version`, `wslc version`, and command help inspected on the date above.

## Intended design

Replace only OCI acquisition and filesystem export. Continue provisioning in a normal WSL 2 distro, where systemd, OOBE, default-user behavior, and isolation validation match the delivered product.

```text
ubuntu:24.04
  -> wslc create (stopped container; fresh pull)
  -> wslc export --output rootfs.tar
  -> remove that container
  -> existing tar overlay injection
  -> existing WSL import/provision/restart/validate/export
  -> <image-name>.wsl + companion manifest
```

Use `wslc export`, not `wslc image save`: WSL import needs a flattened root filesystem, not an OCI/Docker image archive. Never start the acquisition container, provision inside it, or attach host directories, credentials, sockets, or ports.

## 1. Prove the replacement before changing the builder

Run a focused experiment in a unique temporary directory with a unique container name and a CID file. Use native argument arrays and check every exit status. The command shape, subject to verification, is:

```powershell
wslc.exe create --name <unique-name> --cidfile <cid-file> --pull always ubuntu:24.04
wslc.exe image inspect --format json ubuntu:24.04
wslc.exe export --output <rootfs.tar> <container-id>
wslc.exe rm <container-id>
```

Acceptance gates:

- A never-started container exports successfully to an uncompressed tar that Windows `tar.exe` can list and append to.
- Spot-check rootfs layout, numeric ownership, executable modes, and symbolic links in the archive. Rely on the existing build validation for imported Ubuntu identity and tooling; investigate metadata differences only if a problem appears.
- Determine the actual image-inspect JSON schema, including OS, architecture, image identity, and registry digest if exposed. Require Linux and the expected host architecture (`amd64` or `arm64`); fail closed for unknown hosts or mismatches. Do not invent a platform flag. If native selection cannot be verified reliably, resolve that before migration.
- Use `--pull always` and retain checked exit statuses so acquisition failures cannot silently fall back to stale images.
- Clean up only resources created by the experiment; no container/image prune, global WSL shutdown, or changes to existing user distros.

No separate crane comparison or exhaustive filesystem metadata audit is required. The acquisition smoke check can be part of the first build with the replacement backend.

## 2. Implement the acquisition change in build.ps1

1. Replace `$cranePath` and the crane prerequisite with `wslc.exe` discovery. Validate stable WSL minimum and required CLI capabilities before removing an existing reserved staging distro or allocating build resources. Missing/old/disabled WSLC should produce an actionable error directing the user to stable `wsl --update`; never update or install automatically.
2. Extract a small acquisition function that produces the disposable `rootfs.tar`. Keep package selection, version policy, overlay generation, and Linux provisioning outside it. Do not add a backend selector or retain two production backends.
3. Create a GUID-named stopped container with `--pull always` and `--cidfile`. Read and validate the CID instead of parsing human-readable console output. Track the unique name before creation so partial failures with no CID can be reconciled safely using that exact name and ownership checks.
4. Inspect the selected image and verify its platform using the schema proven in step 1. Capture acquisition metadata before removing the container. Establish that the inspected image identity matches the container's image, avoiding a mutable-tag race.
5. Export directly with `--output`; never route tar bytes through PowerShell stdout or redirection. Require a nonempty, readable tar before overlay injection. Retain normal `tar.exe` operations and LF normalization before import.
6. Remove the acquisition container as soon as export and metadata collection succeed. A cleanup failure on the success path must prevent publication. In failure handling, report cleanup problems without masking the primary error.
7. Keep a final cleanup guard for partial acquisition failures. Only remove this invocation's exact container; do not remove shared cached images, sessions, volumes, or networks. Explain that WSLC may retain its shared image cache/service after the build.
8. Preserve `-KeepStagingOnFailure` for the provisioned WSL distro; the acquisition container is disposable and should still be removed. Preserve all existing artifact conflict, replay, and temporary-publication rules.

## 3. Update metadata and documentation

- `build.ps1`: keep the existing `Ubuntu base image:` manifest key for installer/skill compatibility; add acquisition backend, WSL/WSLC versions, selected platform, and image identity/digest where available. Do not label a local image ID as a registry digest.
- Keep the replay command fully resolved for existing build parameters. Record that `ubuntu:24.04` remains a mutable tag: recording a digest gives provenance but does not make tag-based replay byte-for-byte reproducible. Digest-pinned replay is a separate feature unless needed to solve acquisition correctness.
- `README.md`: replace crane setup and acquisition descriptions with stable WSL/WSLC prerequisites, workflow, shared-cache behavior, and troubleshooting for unavailable service, policy restrictions, or registry access.
- `AGENTS.md`: replace the crane-specific architecture/prerequisite rules and the WSLC deferral with the chosen acquisition contract. Retain Linux provisioning, isolation, staging-name, and no-Docker/Podman requirements.
- `.gitignore`: keep `crane.exe` ignored, with a legacy-local-tool comment, so an obsolete local executable cannot accidentally be committed. Do not delete the user's existing binary.
- Review the instance skill and example recipes for stale prerequisite references; change only relevant wording. Keep settings limited to their existing data keys. `install.ps1`, Linux modules, onboarding, and delivered image policy should need no functional changes.

## 4. Minimal validation

The change is confined to image acquisition. Keep all existing build-time validation enabled, and limit additional verification to:

1. Run PowerShell parser and diff checks; review native exit handling and acquisition-container cleanup.
2. Smoke-check create/export, the selected Linux architecture, tar readability/overlay append, and removal of the owned container. This can run within the build below rather than as a separate experiment.
3. Run one normal default build with a unique image name and no crane dependency. Let its existing provisioning, restart, tooling, and isolation checks verify the handoff. Confirm the artifact and companion manifest were produced and the owned container and staging distro were cleaned up.

Do not add an exhaustive failure-injection suite, a crane comparison, an ARM64 test run, or separate install/interop/scratch builds for this migration. Broaden checks only if the smoke check or normal build reveals a concrete issue. Report the architecture actually tested.

## Completion criteria and rollout

Ship one acquisition backend after the minimal checks and one normal build pass. A normal build must work without invoking or requiring `crane.exe`, require only stable WSL/WSLC plus the existing Windows tar tooling, and preserve the delivered distro behavior. Keep existing artifacts usable and do not rebuild them automatically.

Suggested implementation order: builder change; documentation/policy updates; parser checks and acquisition smoke check within one normal build. If the export contract fails, record the specific incompatibility and resolve it before completing the switch. Rollback is a source revert, without destroying user artifacts or adding a permanent fallback backend.
