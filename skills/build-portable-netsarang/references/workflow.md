# Reproducible Build And Acceptance

## Compiler

The checked implementation compiled with TinyCC 0.9.27 win32. Prefer an existing trusted x86 C compiler. Otherwise obtain the official archive from https://download.savannah.gnu.org/releases/tinycc/tcc-0.9.27-win32-bin.zip and extract it into the task cache. Do not install system software or add compiler files to the skill. Record the downloaded file SHA256; do not present a locally computed digest as an official checksum. No compiler is needed on the destination.

The build machine also needs installed Microsoft x86 runtime DLLs in Windows/SysWOW64. The builder validates Microsoft signatures and copies mfc140u, msvcp140, vcruntime140, concrt140, msvcp140_1 and msvcp140_2 app-locally. Check applicable redistribution terms before sharing beyond the user's private use. A missing runtime fails the build; do not quietly omit it.

The same TinyCC compiles `portable-launcher.c` with `-Wl,-subsystem=windows -luser32` and `xftp-path-probe.c` with `-ladvapi32`. Another x86 compiler needs its equivalent GUI flag passed as `-GuiSubsystemFlag` (MSVC link: `/SUBSYSTEM:WINDOWS`; MinGW: `-Wl,--subsystem,windows`). `compile-bridge.ps1` verifies x86 (Machine 0x14c) and GUI subsystem (2) in the PE header; a console-subsystem launcher would flash a window on double-click.

`verify-package.ps1 -RunProbe` resolves Windows PowerShell 5.1 from the Windows directory, not `$PSHOME`: on a PowerShell 7 host `$PSHOME\powershell.exe` does not exist and the probe fails. The delivered launcher and bootstrap use the same absolute Windows PowerShell 5.1 path.

## Commands

Run from the skill directory. Replace example paths with discovered ones; relative script paths resolve here, not in the software source directory. Use PowerShell 5.1 or later on Windows.

```powershell
$bridge = 'E:\Work\.cache\netsarang-bridge'
$output = 'E:\Work\outputs\NetSarang-noadmin'
& .\scripts\compile-bridge.ps1 -Compiler 'E:\Work\.cache\tcc\tcc.exe' -OutputDirectory $bridge
& .\scripts\build.ps1 -XshellPath 'D:\NetSarang\Xshell 8' -XftpPath 'D:\NetSarang\Xftp 8' -ProfilePath 'E:\Profiles\NetSarang\8' -OutputDirectory $output -BridgeDirectory $bridge -PreservePersonalRegistration
& .\scripts\verify-package.ps1 -OutputDirectory $output -XshellPath 'D:\NetSarang\Xshell 8' -XftpPath 'D:\NetSarang\Xftp 8' -RunProbe
```

Omit preservation only when not requested. The no-admin path always requires BridgeDirectory. Output is a fresh directory, sibling ZIP, and ZIP.sha256. ZIP entries start with App/, Data/, Tools/, portable.ps1, manifest.json and the two root-level native launchers Xshell-Portable.exe / Xftp-Portable.exe, without an enclosing folder. No .cmd or .vbs launcher is delivered. GUI tests use a different extraction under task cache; the archive and pristine staging remain unchanged.

## Data Boundary

Safe settings include global mouse/copy/paste options, terminal fonts/display, validated colors and built-in keyboard actions. Do not copy the full Documents profile or opaque registry workspace blobs. Default .xshf/.xfpf templates can contain connection credentials; only the reconstructed display-only Xshell default belongs in the initial archive. Omit custom scripts, commands, external paths, autologin, proxies, bookmarks, logs, SECSH, credentials and master passwords.

Requested free preservation copies original machine registration fields from the 32-bit registry view, plus user name/email and License SubmitTime, SubmitToken, CheckInChecked, FreeLicenseKey, MIDList. Values remain unchanged. Distinguish connection usernames (excluded) from the license owner (explicitly retained). The retained token is not proof it will be accepted by another hardware identity. Official terms: https://www.netsarang.com/en/free-for-home-school/ ; free use is personal/educational and non-commercial.

## Runtime

portable-user.ps1 is delivered as portable.ps1. It seeds HKCU/Software/CodexPortable/NetSarang8/<package-path-hash>, starts the native x86 runner and saves the used user registry to Data/registry.clixml after applications exit. New sessions remain in Data/8. Registry state can persist in the dedicated namespace; moving to a new path imports the saved snapshot. Close all package applications before moving it. Do not treat this as zero-trace registry virtualization.

Xshell-Portable.exe and Xftp-Portable.exe are the same compiled `portable-launcher.c` binary delivered under two names. Each is an x86 GUI-subsystem executable: no console flash, no cmd.exe, no Windows Script Host, no VBS. It resolves Windows PowerShell 5.1, runs portable.ps1 hidden with -App chosen from its own file name, sets the working directory to the package root, waits for the bootstrap and returns its exit code. portable.ps1 remains the verified bootstrap and verifier -SelfTest target. A fully PowerShell-free package (Win32-only registry seeding and settings export) is possible in principle but unverified here; do not describe the delivered package as script-free.

The runner starts the original executable suspended and loads registry-bridge.dll. Vendor imports, dynamically loaded modules, and child launches are routed. Besides CreateProcessW/A, the bridge hooks ShellExecuteW/A, ShellExecuteExW/A and WinExec, because Xshell starts its XshellCore viewer through ShellExecuteExW (`-setviewer <hwnd>`); those hooks reproduce the launch as suspended-start + injection + resume, preserving lpParameters/lpDirectory/nShow and using the executable folder as the working directory when lpDirectory is NULL. OS modules are not patched. Window lookup and named events isolate instances from installed Xshell. Keep the source INI SingleProcessMode value and the registry MultiCoreProcess value: build.ps1 no longer forces 1/0, and portable.ps1 re-applies the original MultiCoreProcess from Data/settings.clixml on each start. Forcing single-core selected "Single Core Process Mode" and broke the viewer handshake on 8.0.0.27. The bridge does not provide an OS-wide security boundary or cover every possible Win32 API. A diagnostic DLL built with `-DBRIDGE_TRACE` writes %TEMP%\ns-bridge-trace.log; never ship it.

Tools/xftp-path-probe.exe is a self-checking x86 probe run through the same runner during `-SelfTest`. It derives the package root from its own path and asserts that HKLM Xftp/Xshell `...\8\Path` and HKCU `Common\8\UserData\UserDataPath` all resolve inside the package. That is the exact registry lookup Xshell performs to find the executable behind its built-in Xftp button, so it verifies the target is the portable Xftp without opening a GUI. Combined with the parent/child injection probe, it covers the mechanism; a UI click still needs a working product window.

The original source contains legacy administrator scripts used by the non-bridge builder branch. A no-admin build excludes those files; never instruct its user to register HKLM as a workaround.

## GUI Acceptance

First run the package verifier and parent/child probe. Confirm the test process token is non-elevated. Read real HKLM only to confirm probe keys were not created; never remove the installed product registration to simulate a clean PC.

Launch Xftp from a separate extraction. Confirm the executable path belongs to it and the main window shows Free for Home/School; a free activation dialog is not success. Launch Xshell separately and confirm its own main window plus any XshellCore path. Startup logs should progress through the Personal check and frame creation. Avoid unfiltered logs: vendor check-in lines can contain tokens. Use the available Windows computer-use skill for UI observations; if it cannot bind the portable copy, combine returned window titles, package process paths and filtered application logs and state the limitation.

Verify settings persistence after normal exit where practical, including after moving the directory. Do not terminate user-installed sessions. Forced termination of only path-verified disposable test processes is cleanup, not evidence that normal-exit persistence works. New hardware, clean OS, offline licensing, antivirus compatibility, ARM64 and other product builds need separate testing.

## Failure Diagnosis

| Symptom | Established explanation or next check |
| --- | --- |
| Error 40002 / "产品运行所需…请重新安装 Xshell或Xftp" | Missing product installation information is one cause; both machine registration and user product identity matter. Observed on same-host builds without `-PreservePersonalRegistration`: Xshell showed a #32770 error dialog with the frame hidden, and an identity-free Xftp build showed the same 276x182 dialog titled Xftp. Request the user's consent, then rebuild with `-PreservePersonalRegistration` (only when the original Type is Personal). For another person, never copy someone else's identity fields; they must obtain their own free license. Exact failing call was not traced. |
| Missing machine registration from launcher | Old administrator launcher was selected; use BridgeDirectory and the no-admin entrypoint. |
| Free activation dialog | Installation registration alone was insufficient; check whether explicitly requested original License fields were included. |
| "Single Core Process Mode" in the startup log | A stale override forced INI SingleProcessMode=1 or MultiCoreProcess=0. Rebuild from current sources; the installed product uses 0/1. |
| Only last registry property remains | PowerShell New-Item -Force can recreate keys; create missing keys only, then set properties. |
| Child injection fails | Report runner exit code and architecture; do not disable security controls. |
| Installed profile used / portable settings ignored | A vendor exe was double-clicked. Only the root-level Xshell-Portable.exe / Xftp-Portable.exe set NS_PORTABLE_REGISTRY and invoke Tools/registry-runner.exe. Relaunch from them. |
| Console window flashes or .cmd is blocked by policy | An old build produced .cmd launchers. Rebuild with -BridgeDirectory from a fresh compile so the two native exe launchers are emitted. |
| MainFrame Create Failed / Xshell exits after ~5s on 8.0.0.27 | The viewer child now IS injected (verify with a traced bridge: second ATTACH), but XshellCore.exe exits with 0xC0000005 before creating a child frame, and spawns a second short-lived core. A control build without launch hooks crashes identically, so injection is not the cause; skipping core IAT patches or disabling instance-isolation hooks also does not help. This is a hard boundary for the built-in Xftp button. Use Xftp-Portable.exe, or add a custom Xshell quick command pointing at it. Never treat Tools/xftp-path-probe.exe as UI acceptance. See validation-boundary.md. |
| Copying to another PC | Extract to a writable folder; the namespace is derived from that path, so a fresh one is built from Data/settings.clixml. Verified with a different-drive extraction: Xftp reached Free for Home/School, loaded the bridge, used a new namespace id and persisted Data/registry.clixml on normal exit; real HKLM/HKCU stayed unchanged. A preserved-registration build is for the same licensed individual's second device only. An identity-free build shows the 40002-class "产品运行所需…请重新安装" dialog. Another hardware identity and offline license validation remain unverified. |

## Final Cross-PC Re-verification (2026-11-04)

Both final archives were re-extracted into brand-new paths and checked with portable.ps1 -SelfTest: each built its own path-derived namespace id, HKLM Xftp/Xshell Path and HKCU UserDataPath resolved inside the new folder, and real HKLM Xftp Path stayed `D:\NetSarang\Xftp 8`. The Self ZIP was then launched by double-clicking Xftp-Portable.exe from the fresh extraction: Xftp 8 (Free for Home/School) opened, registry-bridge.dll was loaded in the process, and a normal window close exported Data/registry.clixml (30,774 bytes) without touching real HKLM. No absolute source path or identity string occurs in the Clean ZIP's text files; both ZIPs pass unzip -t and their SHA-256 sidecars. This confirms technical path portability, not licensing on foreign hardware. The two .sha256 sidecars were rewritten with LF endings so `sha256sum -c` works in Git Bash as well as PowerShell.
