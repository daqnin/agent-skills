<#
Install-OpenPwshHere.ps1

Creates per-user (HKCU\Software\Classes) Explorer verbs that open the
Scoop-installed PowerShell 7 in the right-clicked location:
  - 在终端中打开          -> current user
  - 在终端中打开（管理员） -> elevated

Default mode (Auto) uses Windows Terminal for BOTH verbs when wt.exe and its
settings.json are available: the admin verb runs through a Windows Terminal
profile with "elevate": true, so the elevated window is still the modern
terminal. Without Windows Terminal it falls back to Legacy mode, where the
admin verb uses Launch-AdminPwsh.ps1 / Start-Process -Verb RunAs (conhost).

It also hides Windows Terminal's own packaged "在终端中打开(T)" verb through
the per-user Shell Extensions\Blocked list (no elevation needed), so exactly
two terminal entries remain. Pass -KeepWindowsTerminalVerb to leave it visible.

HKCU verbs with the same names as existing machine-wide HKLM verbs win in the
merged HKEY_CLASSES_ROOT view, so this repairs broken HKLM entries without
elevation. No administrator rights are required.
#>
[CmdletBinding()]
param(
    [string] $PwshPath,
    [string] $WtPath,
    [string] $WtSettingsPath,
    [ValidateSet('Auto', 'WindowsTerminal', 'Legacy')] [string] $Mode = 'Auto',
    [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'OpenPwshHere'),
    [string] $NormalLabel = '在终端中打开',
    [string] $AdminLabel  = '在终端中打开（管理员）',
    [string] $AdminProfileName,
    [switch] $KeepWindowsTerminalVerb,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OpenPwshHere.Common.ps1')

if (-not $AdminProfileName) { $AdminProfileName = Get-OpenPwshHereAdminProfileName }
if (-not $WtSettingsPath)  { $WtSettingsPath  = Get-OpenPwshHereWtSettingsPath }

$targets = Get-OpenPwshHereTargets
$verbs = Get-OpenPwshHereVerbs -NormalLabel $NormalLabel -AdminLabel $AdminLabel
$helperPath = Join-Path $InstallDir 'Launch-AdminPwsh.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($Uninstall) {
    foreach ($t in $targets) {
        foreach ($v in $verbs) {
            $key = Get-OpenPwshHereKeyPath -Key $t.Key -Name $v.Name
            if (Test-Path -LiteralPath $key) {
                Remove-Item -LiteralPath $key -Recurse -Force
                Write-Output "removed  $key"
            }
        }
    }
    if (Test-Path -LiteralPath $helperPath) {
        Remove-Item -LiteralPath $helperPath -Force
        Write-Output "removed  $helperPath"
    }
    $uninstallBackup = Join-Path $InstallDir ("wt-settings-uninstall-{0}.json" -f $stamp)
    try {
        $removed = Remove-OpenPwshHereAdminProfile -SettingsPath $WtSettingsPath `
                        -ProfileName $AdminProfileName -BackupPath $uninstallBackup
        if ($removed) { Write-Output "removed  Windows Terminal profile '$AdminProfileName'" }
    }
    catch { Write-Output ("WARN    could not clean Windows Terminal settings: {0}" -f $_.Exception.Message) }
    # Restore only the Blocked values the last install added. Never delete the
    # whole Blocked key: other applications may have their own entries there.
    $lastBackup = Get-ChildItem -LiteralPath $InstallDir -Filter 'backup-*.json' -File -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending | Select-Object -First 1
    if ($lastBackup) {
        try {
            $snap = (Get-Content -LiteralPath $lastBackup.FullName -Raw -Encoding utf8) | ConvertFrom-Json
            $changes = @($snap.TerminalVerbChanges)
            if ($changes.Count -gt 0) {
                Restore-OpenPwshHereTerminalVerbs -Changes $changes
                Write-Output 'restored  packaged Windows Terminal context-menu entry'
            }
        }
        catch { Write-Output ("WARN    could not restore Blocked values: {0}" -f $_.Exception.Message) }
    }
    Write-Output 'Uninstall complete. Reopen any Explorer windows to refresh the menu.'
    return
}

$pwsh = Resolve-OpenPwshHerePwsh -Explicit $PwshPath
$wt = Resolve-OpenPwshHereWt -Explicit $WtPath

$mode = $Mode
if ($mode -eq 'Auto') {
    if ($wt -and (Test-Path -LiteralPath $WtSettingsPath -PathType Leaf)) {
        $mode = 'WindowsTerminal'
    }
    else {
        $mode = 'Legacy'
        Write-Output 'WARN    wt.exe or Windows Terminal settings.json not found; falling back to Legacy (conhost) mode.'
    }
}
if ($mode -eq 'WindowsTerminal' -and -not $wt) {
    throw 'WindowsTerminal mode requested but wt.exe cannot be resolved. Pass -WtPath or use -Mode Legacy.'
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# Windows Terminal's own packaged verb ("在终端中打开(T)") is a third entry.
# Hide it per-user so the menu contains only our two verbs.
$terminalChanges = @()
if (-not $KeepWindowsTerminalVerb) {
    $terminalChanges = @(Set-OpenPwshHereTerminalVerbsHidden)
    Write-Output ("hidden    : packaged Windows Terminal verb blocked in HKCU Shell Extensions\Blocked")
}

$wtBackup = $null
if ($mode -eq 'WindowsTerminal') {
    try {
        $wtBackup = Join-Path $InstallDir ("wt-settings-{0}.json" -f $stamp)
        $profileGuid = Set-OpenPwshHereAdminProfile -SettingsPath $WtSettingsPath `
                           -PwshPath $pwsh -ProfileName $AdminProfileName -BackupPath $wtBackup
        Write-Output ("WT profile : '{0}' [{1}], elevate=true" -f $AdminProfileName, $profileGuid)
        Write-Output ("WT backup  : {0}" -f $wtBackup)
    }
    catch {
        if ($Mode -eq 'Auto') {
            $mode = 'Legacy'
            $wt = $null
            $wtBackup = $null
            Write-Output ("WARN    Windows Terminal profile setup failed ({0}); falling back to Legacy." -f $_.Exception.Message)
        }
        else { throw }
    }
}

if ($mode -eq 'Legacy') {
    $helperSource = Join-Path $PSScriptRoot 'Launch-AdminPwsh.ps1'
    if (-not (Test-Path -LiteralPath $helperSource -PathType Leaf)) {
        throw "Missing helper template: $helperSource"
    }
    Copy-Item -LiteralPath $helperSource -Destination $helperPath -Force
}

# Snapshot any pre-existing per-user values before touching them.
$snapshot = @()
foreach ($t in $targets) {
    foreach ($v in $verbs) {
        $key = Get-OpenPwshHereKeyPath -Key $t.Key -Name $v.Name
        foreach ($path in @($key, (Join-Path $key 'command'))) {
            if (Test-Path -LiteralPath $path) {
                $regKey = Get-Item -LiteralPath $path
                $values = @{}
                foreach ($name in $regKey.GetValueNames()) {
                    $display = if ($name -eq '') { '(default)' } else { $name }
                    $values[$display] = [string] $regKey.GetValue($name)
                }
                $snapshot += [pscustomobject]@{ Path = $path; Values = $values }
            }
        }
    }
}
$backupPath = Join-Path $InstallDir ("backup-{0}.json" -f $stamp)
# Always write the file, including when no per-user verb existed before.
[pscustomobject]@{
    CreatedAt        = (Get-Date).ToString('o')
    Mode             = $mode
    PwshPath         = $pwsh
    HelperPath       = $helperPath
    WtPath           = $wt
    WtSettingsPath   = $WtSettingsPath
    WtSettingsBackup = $wtBackup
    AdminProfileName = $AdminProfileName
    KeepWindowsTerminalVerb = [bool] $KeepWindowsTerminalVerb
    TerminalVerbChanges = @($terminalChanges)
    PreviousValues   = @($snapshot)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $backupPath -Encoding utf8

foreach ($t in $targets) {
    $common = @{
        PwshPath         = $pwsh
        HelperPath       = $helperPath
        Placeholder      = $t.Placeholder
        Mode             = $mode
        WtPath           = $wt
        AdminProfileName = $AdminProfileName
    }
    $normalCommand = Get-OpenPwshHereCommand @common
    $adminCommand  = Get-OpenPwshHereCommand @common -Admin

    foreach ($v in $verbs) {
        $key = Get-OpenPwshHereKeyPath -Key $t.Key -Name $v.Name
        $command = if ($v.Admin) { $adminCommand } else { $normalCommand }

        New-Item -Path $key -Force | Out-Null
        Set-Item -LiteralPath $key -Value $v.Label
        New-ItemProperty -LiteralPath $key -Name 'Icon' -Value $pwsh -PropertyType String -Force | Out-Null
        if ($v.Admin) {
            New-ItemProperty -LiteralPath $key -Name 'HasLUAShield' -Value '' -PropertyType String -Force | Out-Null
        }
        else {
            # Remove a stale shield flag if this key used to be the admin verb.
            Remove-ItemProperty -LiteralPath $key -Name 'HasLUAShield' -ErrorAction SilentlyContinue
        }

        $commandKey = Join-Path $key 'command'
        New-Item -Path $commandKey -Force | Out-Null
        Set-Item -LiteralPath $commandKey -Value $command

        Write-Output ("{0} [{1}] -> {2}" -f $v.Label, $t.Context, $command)
    }
}

Write-Output ''
Write-Output ("mode      : {0}" -f $mode)
Write-Output ("pwsh      : {0}" -f $pwsh)
Write-Output ("wt.exe    : {0}" -f $(if ($wt) { $wt } else { '<legacy: not used>' }))
Write-Output ("backup    : {0}" -f $backupPath)
Write-Output ("extra menu: {0}" -f $(if ($KeepWindowsTerminalVerb) { 'packaged Windows Terminal verb kept' } else { 'packaged Windows Terminal verb hidden (2 terminal entries)' }))
Write-Output ("keys      : {0} per-user verbs under HKCU\Software\Classes" -f ($targets.Count * $verbs.Count))
Write-Output 'Next      : run scripts/Test-OpenPwshHere.ps1, then reopen Explorer windows.'
Write-Output 'Note      : on Windows 11 legacy verbs appear under 显示更多选项 (Shift+F10).'
