# Windows Explorer Shell Verbs For pwsh

Reference detail for `open-pwsh-here`. Load this when diagnosing a failing menu
item, porting the verbs to another account, explaining why a repair uses HKCU,
or explaining why the normal and administrator windows look different.

## 1. Registry Layout And The Merged View

Explorer reads `HKEY_CLASSES_ROOT` (HKCR), which is a merged view of
`HKLM\SOFTWARE\Classes` and `HKCU\Software\Classes`. A per-user subkey with the
same name as a machine-wide subkey wins for that verb. Therefore:

- Keep the verb names `OpenPwshHere` and `OpenPwshHereAdmin` exactly as they
  were in HKLM. Creating a *differently named* verb would leave the broken
  machine-wide entries visible and produce duplicate menu items.
- Verify through `Registry::HKEY_CLASSES_ROOT\...`, not only HKCU. If the merged
  value still shows the old HKLM string, the shadow did not take effect.
- HKCU writes need no elevation. HKLM writes do. On a machine where the broken
  entries are in HKLM and the session is non-elevated, HKCU shadowing is the
  only non-disruptive repair.
- Explorer caches context-menu handlers. Close and reopen Explorer windows
  after installation. Restarting Explorer is a last resort and closes all
  Explorer windows.

Targets and placeholders:

| Registry key (relative to `Classes`) | Trigger | Placeholder | Value |
| --- | --- | --- | --- |
| `Directory\shell` | Right-click on a folder icon | `%1` | selected folder |
| `Directory\Background\shell` | Right-click on empty space inside a folder | `%V` | current folder |
| `Drive\shell` | Right-click on a drive | `%1` | drive root, for example `E:\` |

`%1` and `%V` are substituted by Explorer before `CreateProcess`, not by
`cmd.exe`. Characters such as `&`, `%` and `!` in a path are not re-interpreted
by a shell. Always wrap the placeholder in double quotes.

## 2. Why The Suffix `\.` Is Mandatory

Windows splits a raw command line into argv with these rules: backslashes are
literal unless they immediately precede a double quote; an odd number of
backslashes before a quote escapes that quote into a literal character.

For a drive root, `-WorkingDirectory "%V"` becomes:

```
-WorkingDirectory "E:\"
```

The final `\` escapes the closing quote, so pwsh receives a corrupted argument
(`E:"`) and the terminal opens in the wrong place or fails. Paths containing
spaces are fine with quotes, but drive roots, UNC roots and any path ending in
a backslash are not.

Appending `\.` moves a `.` in front of the closing quote:

```
"E:\."        -> E:\.
"E:\\."       -> E:\\.   (when the placeholder already ended in a backslash)
"C:\a b\."    -> C:\a b\.
```

`Get-Item`/`Directory.SetCurrentDirectory` normalize all of these. Verified on
PowerShell 7.6.9: `E:\.`, `E:\\.`, `E:\project\agent-skills\.` and
`E:\project\agent-skills\\.` all resolve to the intended directory. The same
suffix is used for `wt.exe -d "E:\."`; Windows Terminal accepts the normalized
path.

Do not "fix" this by trimming the trailing backslash: `E:\` trimmed to `E:`
is a drive-relative path meaning the current directory on drive E, which is
wrong.

## 3. Default Terminal Delegation And The Normal/Admin Mismatch

Windows 11 22H2+ can host any console application in Windows Terminal. The
choice lives in `HKCU\Console\%%Startup` (both values are `REG_SZ` GUIDs):

| Setting | `DelegationConsole` | `DelegationTerminal` |
| --- | --- | --- |
| Automatic (Windows Terminal if available) | `{00000000-0000-0000-0000-000000000000}` | `{00000000-0000-0000-0000-000000000000}` |
| Windows Console Host (legacy conhost) | `{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}` | `{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}` |
| Windows Terminal | `{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}` | `{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}` |

Delegation happens inside `ShellExecute` for an ordinary, unelevated console
launch. A process started through `Start-Process -Verb RunAs` is created by
the AppInfo service and **does not go through that delegation**, so it always
gets a legacy conhost window (or the packaged app fails to elevate). That is
why a normal verb can open the modern terminal while the administrator verb
opens an old black console window with a different font. Changing the default
terminal setting cannot fix it: it never reaches the elevated child.

The robust fix is to stop depending on delegation entirely. Both verbs call
`wt.exe` explicitly; the admin verb uses a Windows Terminal profile with
`"elevate": true`, so the elevated window is still the modern terminal. This
also makes the result independent of the per-user default-terminal setting.

## 4. Elevation

`HasLUAShield` only draws the shield icon; it does not elevate anything. Three
mechanisms exist:

- **Windows Terminal profile `"elevate": true`** (preferred, Windows Terminal
  1.18+). The profile's `commandline` is the Scoop `pwsh.exe`. Launching it
  from an unelevated window creates a *new elevated Windows Terminal window*;
  launching it from an already elevated window opens a tab there. Elevated and
  unelevated tabs cannot coexist in one window. The skill's profile is named
  `pwsh (Admin)` with GUID `{b8f1e7c2-3d4a-4f6b-9c5e-1a2b3c4d5e6f}` and is
  matched by GUID then name, so reinstalling is idempotent.
- Name the verb key `runas`. Explorer calls `ShellExecuteEx` with the canonical
  `runas` verb and AppInfo elevates. This cannot be used here because the verb
  name must stay `OpenPwshHereAdmin` to shadow HKLM.
- **Legacy fallback**: a helper calling
  `Start-Process -FilePath <pwsh> -Verb RunAs`. Used only when Windows Terminal
  is unavailable. `Launch-AdminPwsh.ps1` is copied to
  `%LOCALAPPDATA%\OpenPwshHere\`; it receives the directory as a plain
  positional argument, so no nested `powershell.exe -Command "... ""%V"" ..."`
  quoting is needed (that old HKLM chain broke on spaces, drive roots and
  single quotes, and flashed a Windows PowerShell 5.1 window). Its `-DryRun`
  prints `ChildCommandLine` as JSON for verification without UAC.

UAC behaviour is controlled by
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`:

- `ConsentPromptBehaviorAdmin = 0` — elevate without prompting.
- `= 2` or `= 5` — prompt on the secure desktop or for consent.
- `EnableLUA = 0` — UAC disabled; the process inherits the current token.

Do not substitute `Start-Process wt.exe -Verb RunAs` for the profile approach:
it tries to elevate the packaged application itself, is not the supported
path, and does not use the profile's `-d` directory reliably.

## 5. wt.exe Command Lines Used Here

```
normal : "<wt.exe>" -w -1 -d "%V\."
admin  : "<wt.exe>" -w -1 -p "pwsh (Admin)" -d "%V\."
```

- `wt.exe` is resolved to the stable app-execution-alias path
  `%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe` (a zero-byte reparse point).
  `HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\wt.exe` must point
  at a real binary inside `C:\Program Files\WindowsApps\...`. Do not hardcode
  that versioned path — it changes on every Windows Terminal update.
- `-w -1` (or `-w new`) always opens a new window; `-w 0` targets the most
  recently used window. Without a subcommand, `wt` defaults to `new-tab`.
- `-d` is the starting directory and belongs to `new-tab`; `-p` selects the
  profile by name. No `--elevate` CLI switch exists — elevation is a profile
  property.
- Do **not** run `wt.exe` with a real tab from the verifier: PowerShell waits
  for packaged Store applications to exit before returning, which hangs the
  script. `wt.exe --version` is a safe smoke test (`-ProbeWtExe`).
- `settings.json` lives at
  `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json`.
  It is JSONC-capable, but the installer parses plain JSON with
  `ConvertFrom-Json`; if a user has comments in it, `Auto` mode falls back to
  Legacy. Back up the file before writing and never replace it with a fixed
  template — only add/refresh the one admin profile.

## 6. Windows 11 Menu Behaviour

Windows 11 22H2 and later (including 25H2 builds in the 26100/26200 range)
show a compact first-level context menu. Registry `shell\command` verbs are
legacy extensions and appear under 显示更多选项 / "Show more options"
(Shift+F10 or Shift+right-click). First-level entries require an
`IExplorerCommand` implementation with packaged or sparse-package identity.

Consequently "the item is not in the first menu" is expected behaviour, not a
bug in these verbs. Do not install a CLSID override that disables the modern
menu just to make these verbs visible; that is a machine-wide cosmetic change
unrelated to the repair.

### 6.1 The Third Terminal Entry And The Two-Entry Invariant

Windows Terminal's AppxManifest declares
`desktop4:Extension Category="windows.fileExplorerContextMenus"` with
`desktop5:Verb Id="OpenTerminalHere"` and CLSID
`9f156763-7844-4dc4-b2b1-901f640f5155` (Windows Terminal Preview uses
`02db545a-3e20-46de-83a5-1329b1e88b6b`). This packaged `IExplorerCommand`
appears as 「在终端中打开(T)」in the compact menu. It is **not** a
`shell\command` verb, so it does not appear when enumerating
`Directory\shell`; deleting our six keys or changing
`HKCU\Console\%%Startup` cannot remove it.

Explorer honours
`HKCU\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`:
add each CLSID as a `REG_SZ` value (the data can be a label such as
`Windows Terminal`). The per-user list needs no elevation;
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`
is the all-users equivalent, overrides HKCU, and needs administrator rights.
The extension's ClassIndex entry lives under
`HKLM\SOFTWARE\Classes\PackagedCom\ClassIndex\{9f156763-...}` — do not delete
it, since packaged COM activation is shared.

The change takes effect only after restarting the Explorer shell or signing
out/in; reopening one Explorer window may still show the cached menu. The
installer logs exactly which values it added in `backup-*.json` and removes
only those on `-Uninstall`, leaving other applications' Blocked entries alone.
`Test-OpenPwshHere.ps1` proves the invariant by enumerating verbs whose label
contains 在终端中打开 (or whose name starts with `OpenPwshHere`) in HKCU and
HKCR: exactly two per context, named `OpenPwshHere` and `OpenPwshHereAdmin`.

## 7. Diagnosis Checklist

| Symptom | Likely cause |
| --- | --- |
| Item missing entirely | Wrong target key, or Explorer window not reopened |
| Duplicate items | A new verb name was used instead of shadowing the HKLM name |
| Opens in `C:\Windows\System32` | `-d` / `-WorkingDirectory` lost; check the `\.` suffix and argv split |
| Fails only at drive roots | Trailing backslash escaped the closing quote |
| Fails only on paths with spaces | Placeholder not quoted, or nested quoting stripped it |
| Normal opens Windows Terminal, admin opens old console | Admin verb uses `RunAs` and bypasses default terminal delegation; switch both verbs to explicit `wt.exe` |
| Admin window opens but is not elevated | `elevate` absent/false, Windows Terminal older than 1.18, UAC disabled, or filtered token |
| Admin item does nothing (Legacy) | Helper path missing, `-ExecutionPolicy` blocked, or `Start-Process -Verb RunAs` denied |
| A third 「在终端中打开(T)」entry appears | Windows Terminal's packaged IExplorerCommand; block its CLSID under HKCU `Shell Extensions\Blocked` and restart Explorer |
| More than two terminal verbs in 显示更多选项 | Another verb with a 在终端中打开 label in HKCU/HKLM `shell`; inspect the merged HKCR view |
| Old broken command still runs | HKCU shadow not checked in the merged HKCR view |
| Two admin profiles appear | Profile was matched by a different name/GUID; remove duplicates in `settings.json` |

## 8. Verification Boundary

`Test-OpenPwshHere.ps1` detects the installed mode from the registry. In
Windows Terminal mode it checks binary/alias/App Paths, Windows Terminal
version, the `elevate: true` profile (name, GUID uniqueness, commandline,
`startingDirectory`, cloned font), all six keys and labels, icons, shield flag,
exact command strings, HKCR shadowing and Windows argv splitting of `-w/-p/-d`
against three path shapes. In Legacy mode it additionally exercises the helper
`-DryRun` chain and launches real `pwsh.exe` processes. Both modes assert
exactly two terminal verbs per context in HKCU and HKCR and check that the
packaged Windows Terminal CLSIDs are in the per-user `Blocked` list.

It does **not** click an Explorer menu, trigger a UAC prompt, or observe an
elevated Windows Terminal window. Those are manual acceptance steps. Report a
verifier PASS as "static + component verified", never as "GUI verified".

## 9. Rollback

`Install-OpenPwshHere.ps1 -Uninstall` deletes the six HKCU verb keys, the
Legacy helper, and only the admin Windows Terminal profile it created (matched
by fixed GUID or name). It also removes only the `Blocked` values recorded in
the newest `backup-*.json`, which restores the packaged Windows Terminal entry.
Timestamped `backup-*.json` files in the install
directory record the previous per-user registry values;
`wt-settings-*.json` / `wt-settings-uninstall-*.json` are byte-for-byte copies
of `settings.json` before each edit, so the user's terminal configuration can
be restored manually. Removing the HKCU keys re-exposes the original HKLM
entries, so uninstalling restores the previous (broken) state rather than a
clean machine.
