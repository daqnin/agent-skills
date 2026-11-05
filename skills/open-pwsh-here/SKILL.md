---
name: open-pwsh-here
description: 修复或安装 Windows 资源管理器右键菜单中的「在终端中打开」与「在终端中打开（管理员）」，使两者都在右键所在位置启动 Scoop 安装的 PowerShell 7（pwsh.exe），分别以当前普通用户和管理员身份运行。适用于菜单项缺失、打开错误的终端、工作目录不对、盘符根目录或含空格路径下失效，以及需要审查、验证、卸载这些右键动词或将其复制到其他 Windows 账户的场景。
---

# Open Pwsh Here

Register six per-user Explorer shell verbs that open Scoop's `pwsh.exe` in the right-clicked folder, folder background or drive, and make both the normal and the administrator verb use the **same modern Windows Terminal** window. Use the same verb names as any pre-existing machine-wide entries so the per-user copies win in the merged `HKEY_CLASSES_ROOT` view; this repairs broken `HKLM` verbs without elevation and without deleting anything.

## Why The Two Windows Can Differ

Windows 11 22H2+ delegates console applications to a default terminal host according to `HKCU\Console\%%Startup`. A normal verb launched by Explorer (`ShellExecute`) is delegated to Windows Terminal, but a child started through `Start-Process -Verb RunAs` is launched by the AppInfo service and **bypasses that delegation** — it lands in the legacy conhost window. So "normal opens Windows Terminal, admin opens an old console" is expected when the admin verb uses a RunAs helper. Fix it by making both verbs launch `wt.exe` explicitly and letting a Windows Terminal profile with `"elevate": true` do the elevation. See [windows-shell-verbs.md](references/windows-shell-verbs.md) for the delegation GUIDs and the full diagnosis.

## Exactly Two Menu Entries

Windows Terminal registers a packaged `IExplorerCommand` verb — shown as
「在终端中打开(T)」in the compact Windows 11 menu — through the
`windows.fileExplorerContextMenus` extension in its AppxManifest. It is a
**third** terminal entry, independent of the six registry verbs this skill
writes. Its COM class is `{9F156763-7844-4DC4-B2B1-901F640F5155}`
(`{02DB545A-3E20-46DE-83A5-1329B1E88B6B}` for Windows Terminal Preview).

The installer hides it by adding those CLSIDs as `REG_SZ` values under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`.
That list is honoured per-user and needs no elevation; HKLM has an equivalent
all-users list that overrides it but requires administrator rights. The change
is logged in `backup-*.json` and restored by `-Uninstall`. Restart Explorer
(restart the shell process or sign out and back in) for the compact menu to
refresh — merely reopening an Explorer window may not be enough. Verify with
`Test-OpenPwshHere.ps1`, which asserts exactly two terminal verbs per context
in both HKCU and the merged HKCR view.

## Workflow

1. Inspect before changing anything. Read `HKLM\SOFTWARE\Classes` and `HKCU\Software\Classes` under `Directory\shell`, `Directory\Background\shell` and `Drive\shell`. Resolve the real `pwsh.exe` under `%SCOOP%\apps\pwsh\current\pwsh.exe` (not a shim). Check `wt.exe`, its App Paths registration, `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json` and the installed Windows Terminal version (`elevate` needs 1.18+).
2. Run `scripts/Install-OpenPwshHere.ps1` from PowerShell 7. `-Mode Auto` (default) uses Windows Terminal when available and falls back to the legacy RunAs helper otherwise. Force a mode with `-Mode WindowsTerminal` or `-Mode Legacy`; override paths with `-PwshPath`, `-WtPath`, `-WtSettingsPath`, `-InstallDir`, labels with `-NormalLabel` / `-AdminLabel`, and the elevated profile name with `-AdminProfileName`. In Windows Terminal mode the script backs up `settings.json`, adds or refreshes the admin profile (matched by a fixed GUID, idempotent), and clones appearance-only properties from the user's `defaultProfile`. It also hides the packaged Windows Terminal verb by default; pass `-KeepWindowsTerminalVerb` to leave that third entry visible.
3. Run `scripts/Test-OpenPwshHere.ps1`. It detects the installed mode from the registry and checks that mode, then asserts the two-entry invariant (exactly `OpenPwshHere` + `OpenPwshHereAdmin` per context in HKCU and HKCR, packaged CLSIDs blocked). Require the printed `RESULT: N passed, 0 failed` line before declaring success. Add `-ProbeWtExe` for a `wt.exe --version` smoke test; add `-AllowWindowsTerminalVerb` only if the installer used `-KeepWindowsTerminalVerb`. Never launch `wt.exe` with a real tab from the verifier: PowerShell waits for packaged apps to exit, which hangs the script.
4. Restart the Explorer shell (or sign out and back in) so the `Blocked` list refreshes the compact menu; reopening a single Explorer window is not enough for this change. On Windows 11 the two surviving legacy verbs appear under 显示更多选项 (Shift+F10), not in the compact first-level menu.
5. Perform the manual acceptance steps that an agent cannot do headlessly: right-click a folder, choose 在终端中打开 and confirm a normal-user Windows Terminal opens in that folder; then choose 在终端中打开（管理员）, accept the UAC prompt and confirm a **Windows Terminal** window (same font/theme) opens elevated in that folder. Check elevation inside it with `([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`.

## Registered Shape

| Context | Key under `HKCU\Software\Classes` | Placeholder |
| --- | --- | --- |
| Right-click on a folder | `Directory\shell` | `%1` |
| Right-click on empty space inside a folder | `Directory\Background\shell` | `%V` |
| Right-click on a drive | `Drive\shell` | `%1` |

Each context gets two verbs: `OpenPwshHere` (label 在终端中打开) and `OpenPwshHereAdmin` (label 在终端中打开（管理员）, plus `HasLUAShield`). Keep these names fixed; they shadow the broken machine-wide verbs.

Windows Terminal mode (default when available):

- Normal: `"<wt.exe>" -w -1 -d "<placeholder>\."` — uses the user's `defaultProfile`, `-w -1` forces a new window.
- Admin: `"<wt.exe>" -w -1 -p "<AdminProfileName>" -d "<placeholder>\."` — the named profile has `"elevate": true` and `"commandline": "<pwsh.exe>"`.
- The profile is `pwsh (Admin)` with GUID `{b8f1e7c2-3d4a-4f6b-9c5e-1a2b3c4d5e6f}` by default; appearance keys (font, colors, opacity) are cloned from `defaultProfile` so both windows look identical.

Legacy mode (no Windows Terminal):

- Normal: `"<pwsh>" -NoExit -WorkingDirectory "<placeholder>\."`
- Admin: hidden `pwsh.exe -File Launch-AdminPwsh.ps1` → `Start-Process -Verb RunAs`. The helper has a `-DryRun` mode for verification without UAC.

## Essential Constraints

- Append `\.` to every Explorer placeholder, in **both** modes. A raw `"%V"` becomes `"E:\"` at a drive root, where the backslash escapes the closing quote in the Windows command-line parser and corrupts the argument. `E:\.` and `E:\\.` both normalize to `E:\`. Never "simplify" this away; `-d "E:\."` works for Windows Terminal too.
- Use `%1` for selected items and `%V` for folder backgrounds. Do not substitute one for the other.
- Do not rely on the system default-terminal setting. It is per-user, can be "let Windows decide", and never applies to elevated children. Always call `wt.exe` explicitly.
- Do not write to `HKLM\SOFTWARE\Classes` for a repair. It needs elevation, and HKCU already wins in the merged view. Verify the shadow through `Registry::HKEY_CLASSES_ROOT\...`, not only through HKCU.
- `HasLUAShield` is only an icon. In Windows Terminal mode UAC is triggered by the profile's `elevate: true`, and Windows Terminal creates a separate elevated window because elevated and unelevated tabs cannot share a window. Do not try to `Start-Process wt.exe -Verb RunAs` as a substitute — it elevates the whole packaged app and is not the supported path.
- Profile edits must be backed up first and matched by the fixed GUID or name so reinstalling is idempotent. Never overwrite the whole `settings.json` with a fixed template, and never remove unrelated profiles. Use `-Uninstall` for rollback.
- Treat a verifier PASS as static + component evidence, not GUI acceptance. It does not click Explorer, does not trigger UAC, and does not prove the elevated Windows Terminal window starts. Report that boundary explicitly.
- Keep exactly two terminal entries. Hide the packaged Windows Terminal verb through the per-user `Blocked` list; never delete the whole `Blocked` key, never remove unrelated CLSIDs or third-party verbs, and assert the two-verb invariant in the verifier. If a machine ignores the HKCU list, an administrator must add the same CLSID value under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked` manually — that all-users list overrides HKCU. The skill writes HKCU only.
- Never delete the whole `shell` key or unrelated verbs.

## Resources

- `scripts/OpenPwshHere.Common.ps1` — shared target list, pwsh/wt resolution, both command builders, Windows Terminal profile read/write helpers, packaged-verb Blocked helpers, terminal-verb enumeration and the Windows command-line splitter.
- `scripts/Install-OpenPwshHere.ps1` — install, `settings.json` backup, profile creation, backup and uninstall.
- `scripts/Launch-AdminPwsh.ps1` — legacy elevated launcher copied into `%LOCALAPPDATA%\OpenPwshHere\`.
- `scripts/Test-OpenPwshHere.ps1` — mode-aware verification; exit code 0 only when every check passes.
- `references/windows-shell-verbs.md` — registry layout, placeholder and quoting rules, default terminal delegation, `elevate`, Windows 11 menu behavior, UAC and troubleshooting.
