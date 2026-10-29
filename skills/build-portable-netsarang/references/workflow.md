# Reproducible Build And Acceptance

## Compiler

The checked implementation compiled with TinyCC 0.9.27 win32. Prefer an existing trusted x86 C compiler. Otherwise obtain the official archive from https://download.savannah.gnu.org/releases/tinycc/tcc-0.9.27-win32-bin.zip and extract it into the task cache. Do not install system software or add compiler files to the skill. Record the downloaded file SHA256; do not present a locally computed digest as an official checksum. No compiler is needed on the destination.

The build machine also needs installed Microsoft x86 runtime DLLs in Windows/SysWOW64. The builder validates Microsoft signatures and copies mfc140u, msvcp140, vcruntime140, concrt140, msvcp140_1 and msvcp140_2 app-locally. Check applicable redistribution terms before sharing beyond the user's private use. A missing runtime fails the build; do not quietly omit it.

## Commands

Run from the skill directory. Replace example paths with discovered ones; relative script paths resolve here, not in the software source directory. Use PowerShell 5.1 or later on Windows.

```powershell
$bridge = 'E:\Work\.cache\netsarang-bridge'
$output = 'E:\Work\outputs\NetSarang-noadmin'
& .\scripts\compile-bridge.ps1 -Compiler 'E:\Work\.cache\tcc\tcc.exe' -OutputDirectory $bridge
& .\scripts\build.ps1 -XshellPath 'D:\NetSarang\Xshell 8' -XftpPath 'D:\NetSarang\Xftp 8' -ProfilePath 'E:\Profiles\NetSarang\8' -OutputDirectory $output -BridgeDirectory $bridge -PreservePersonalRegistration
& .\scripts\verify-package.ps1 -OutputDirectory $output -XshellPath 'D:\NetSarang\Xshell 8' -XftpPath 'D:\NetSarang\Xftp 8' -RunProbe
```

Omit preservation only when not requested. The no-admin path always requires BridgeDirectory. Output is a fresh directory, sibling ZIP, and ZIP.sha256. ZIP entries start with App/, Data/, Tools/ and launch files, without an enclosing folder. GUI tests use a different extraction under task cache; the archive and pristine staging remain unchanged.

## Data Boundary

Safe settings include global mouse/copy/paste options, terminal fonts/display, validated colors and built-in keyboard actions. Do not copy the full Documents profile or opaque registry workspace blobs. Default .xshf/.xfpf templates can contain connection credentials; only the reconstructed display-only Xshell default belongs in the initial archive. Omit custom scripts, commands, external paths, autologin, proxies, bookmarks, logs, SECSH, credentials and master passwords.

Requested free preservation copies original machine registration fields from the 32-bit registry view, plus user name/email and License SubmitTime, SubmitToken, CheckInChecked, FreeLicenseKey, MIDList. Values remain unchanged. Distinguish connection usernames (excluded) from the license owner (explicitly retained). The retained token is not proof it will be accepted by another hardware identity. Official terms: https://www.netsarang.com/en/free-for-home-school/ ; free use is personal/educational and non-commercial.

## Runtime

portable-user.ps1 is delivered as portable.ps1. It seeds HKCU/Software/CodexPortable/NetSarang8/<package-path-hash>, starts the native x86 runner and saves the used user registry to Data/registry.clixml after applications exit. New sessions remain in Data/8. Registry state can persist in the dedicated namespace; moving to a new path imports the saved snapshot. Close all package applications before moving it. Do not treat this as zero-trace registry virtualization.

The runner starts the original executable suspended and loads registry-bridge.dll. Vendor imports, dynamically loaded modules, and ordinary child CreateProcess calls are routed. OS modules are not patched. Window lookup and named events isolate instances from installed Xshell. Xshell uses INI SingleProcessMode=1 and -newwin; keep that arrangement unless a replacement is tested. The bridge does not provide an OS-wide security boundary or cover every possible Win32 API.

The original source contains legacy administrator scripts used by the non-bridge builder branch. A no-admin build excludes those files; never instruct its user to register HKLM as a workaround.

## GUI Acceptance

First run the package verifier and parent/child probe. Confirm the test process token is non-elevated. Read real HKLM only to confirm probe keys were not created; never remove the installed product registration to simulate a clean PC.

Launch Xftp from a separate extraction. Confirm the executable path belongs to it and the main window shows Free for Home/School; a free activation dialog is not success. Launch Xshell separately and confirm its own main window plus any XshellCore path. Startup logs should progress through the Personal check and frame creation. Avoid unfiltered logs: vendor check-in lines can contain tokens. Use the available Windows computer-use skill for UI observations; if it cannot bind the portable copy, combine returned window titles, package process paths and filtered application logs and state the limitation.

Verify settings persistence after normal exit where practical, including after moving the directory. Do not terminate user-installed sessions. Forced termination of only path-verified disposable test processes is cleanup, not evidence that normal-exit persistence works. New hardware, clean OS, offline licensing, antivirus compatibility, ARM64 and other product builds need separate testing.

## Failure Diagnosis

| Symptom | Established explanation or next check |
| --- | --- |
| Error 40002 | Missing product installation information is one cause; both machine registration and user product identity matter. Exact failing call was not traced. |
| Missing machine registration from launcher | Old administrator launcher was selected; use BridgeDirectory and the no-admin entrypoint. |
| Free activation dialog | Installation registration alone was insufficient; check whether explicitly requested original License fields were included. |
| Failed to initialize viewer / installed Core starts | Check INI SingleProcessMode, -newwin and scoped instance lookup; inspect actual executable paths. |
| Only last registry property remains | PowerShell New-Item -Force can recreate keys; create missing keys only, then set properties. |
| Child injection fails | Report runner exit code and architecture; do not disable security controls. |
