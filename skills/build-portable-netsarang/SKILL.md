---
name: build-portable-netsarang
description: Build no-admin Windows portable Xshell and Xftp packages from local installations, with sanitized preferences, optional existing Personal free registration, process-local registry routing and ZIP verification. Use for portable packaging or error 40002 diagnosis.
---

# Portable Xshell And Xftp

Make a private, installation-free package from existing signed version 8 programs. Keep settings, exclude connection information, and support a destination without administrator rights. The verified implementation uses x86 vendor programs on x64 Windows. Other majors or architectures require separate adaptation.

## Workflow

1. Discover installed paths from uninstall entries and running process paths. Read the profile path from `HKCU\Software\NetSarang\Common\8\UserData\UserDataPath`, falling back to Documents. Inspect versions and executable signatures. Do not print session contents, license values or complete logs; report names, types and verification results only.
2. Read [workflow.md](references/workflow.md) before building. It contains compiler acquisition, exact commands, settings boundaries, runtime behavior and GUI acceptance. Use explicit source paths and a fresh output directory.
3. Run `scripts/compile-bridge.ps1` with an x86 TinyCC executable and a fresh cache output directory. Run `scripts/build.ps1` with `-BridgeDirectory` pointing at those compiled helpers. This option selects the no-admin launcher and bundles signed Microsoft x86 runtime DLLs beside each application.
4. Add `-PreservePersonalRegistration` when the user requests their existing free registration. Require original `Type=Personal`. Copy original identity and license fields without altering them. Never create license tokens, change expiration, spoof machine identifiers or bypass vendor validation. Do not package commercial activation. A preserved package contains private name/email and authorization data.
5. Run `scripts/verify-package.ps1` against the fresh output and ZIP. Run its `-RunProbe` option to test parent/child registry routing without launching either product. Test GUI startup only from a separate extracted test copy, without connections. Never repack the tested copy: it accumulates logs, registry state and new sessions.
6. Deliver the rootless software ZIP, SHA256 and actual verification limits. If updating this skill, run skill-creator's validator and export source helpers only. Neither vendor binaries nor private registration belongs in the skill archive.

## Essential Constraints

- The delivered no-admin package must not include `Register-Personal.cmd`, `register-personal.ps1`, an elevation path, or a containing top-level ZIP directory. Legacy scripts remain implementation dependencies of the older builder branch; do not select that branch for this workflow.
- NetSarang HKLM/HKCU paths are routed in the application processes into a dedicated current-user namespace. Installed profiles and real HKLM are not replaced. This is compatibility tooling, not a security sandbox. Do not disable Windows protections if bridge loading is blocked.
- Xshell needs INI `SingleProcessMode=1`, `-newwin`, isolated instance events and scoped window lookup. Registry `MultiCoreProcess` alone did not prevent forwarding to the installed viewer.
- Retain the builder's preference allowlists. Exclude sessions, credentials, SSH keys, host keys, master passwords, history, bookmarks, scripts, executable quick commands and restored windows. Default session templates must be reconstructed from display sections.
- On failed startup, inspect the filtered logs and actual child executable paths. Stop test processes only after verifying they belong to the test directory. Do not close installed connected sessions to make a test pass.
- Use [validation-boundary.md](references/validation-boundary.md) when explaining proven behavior. Same-host non-admin startup is not clean-machine or cross-machine authorization acceptance. If the vendor rejects the copied free registration, use its official free-registration flow.
