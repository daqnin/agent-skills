# Shared definitions for the open-pwsh-here Explorer verbs.
# Dot-source this file from the installer and the verifier.
#
# Two launch modes are supported:
#   WindowsTerminal - both verbs explicitly launch wt.exe. The admin verb uses
#                     a Windows Terminal profile with "elevate": true, so the
#                     elevated window is still the modern terminal.
#   Legacy          - direct pwsh.exe + Launch-AdminPwsh.ps1 (RunAs). Used when
#                     Windows Terminal / its settings file are not available.

$script:OpenPwshHereTargets = @(
    [pscustomobject]@{ Key = 'Directory\shell';             Placeholder = '%1'; Context = 'a selected folder' }
    [pscustomobject]@{ Key = 'Directory\Background\shell'; Placeholder = '%V'; Context = 'folder background' }
    [pscustomobject]@{ Key = 'Drive\shell';                Placeholder = '%1'; Context = 'a selected drive' }
)

$script:OpenPwshHereAdminProfileName = 'pwsh (Admin)'
$script:OpenPwshHereAdminProfileGuid = '{b8f1e7c2-3d4a-4f6b-9c5e-1a2b3c4d5e6f}'
$script:OpenPwshHereWtPackageFamily  = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe'

# Windows Terminal ships a packaged IExplorerCommand ("在终端中打开(T)") in the
# Windows 11 compact menu. It is a third terminal entry that our verbs do not
# control. Explorer honours a per-user Shell Extensions\Blocked list, so hiding
# it needs no elevation. The second GUID covers Windows Terminal Preview.
$script:OpenPwshHereTerminalClsids = @(
    [pscustomobject]@{ Guid = '{9F156763-7844-4DC4-B2B1-901F640F5155}'; Label = 'Windows Terminal' }
    [pscustomobject]@{ Guid = '{02DB545A-3E20-46DE-83A5-1329B1E88B6B}'; Label = 'Windows Terminal Preview' }
)

function Get-OpenPwshHereTerminalClsids { return $script:OpenPwshHereTerminalClsids }
function Get-OpenPwshHereBlockedKey {
    return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
}

# Block the packaged verbs and return a change log so uninstall can restore
# only the values this skill added (never a user's own Blocked entries).
function Set-OpenPwshHereTerminalVerbsHidden {
    $key = Get-OpenPwshHereBlockedKey
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    $rk = Get-Item -LiteralPath $key
    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $script:OpenPwshHereTerminalClsids) {
        $existed = @($rk.GetValueNames()) -contains $c.Guid
        $previous = if ($existed) { [string] $rk.GetValue($c.Guid) } else { $null }
        if (-not $existed) {
            New-ItemProperty -LiteralPath $key -Name $c.Guid -Value $c.Label -PropertyType String -Force | Out-Null
        }
        $changes.Add([pscustomobject]@{
            Key           = $key
            Name          = $c.Guid
            ExistedBefore = $existed
            PreviousValue = $previous
            AddedByUs     = (-not $existed)
        })
    }
    return $changes.ToArray()
}

function Restore-OpenPwshHereTerminalVerbs {
    param([Parameter(Mandatory)] [object[]] $Changes)
    foreach ($c in $Changes) {
        if (-not $c.AddedByUs) { continue }
        if (Test-Path -LiteralPath $c.Key) {
            Remove-ItemProperty -LiteralPath $c.Key -Name $c.Name -Force -ErrorAction SilentlyContinue
        }
    }
}

# Enumerate verbs whose visible label is a terminal verb, in HKCU or in the
# merged HKCR view. Used to prove that exactly two terminal entries remain.
function Get-OpenPwshHereTerminalVerbNames {
    param([ValidateSet('HKCU', 'HKCR')] [string] $View = 'HKCU')
    $root = if ($View -eq 'HKCU') { 'HKCU:\Software\Classes' } else { 'Registry::HKEY_CLASSES_ROOT' }
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $script:OpenPwshHereTargets) {
        $base = Join-Path $root $t.Key
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue) {
            $r = Get-Item -LiteralPath $k.PSPath
            $names = @($r.GetValueNames())
            $label = [string] $r.GetValue('')
            $mui = if ($names -contains 'MUIVerb') { [string] $r.GetValue('MUIVerb') } else { '' }
            if ($label -match '在终端中打开' -or $mui -match '在终端中打开' -or $k.PSChildName -match '^OpenPwshHere') {
                $found.Add([pscustomobject]@{ Context = $t.Key; Name = $k.PSChildName; Label = $label })
            }
        }
    }
    return $found.ToArray()
}

function Get-OpenPwshHereTargets {
    return $script:OpenPwshHereTargets
}

function Get-OpenPwshHereVerbs {
    param(
        [string] $NormalLabel = '在终端中打开',
        [string] $AdminLabel  = '在终端中打开（管理员）'
    )
    return @(
        [pscustomobject]@{ Name = 'OpenPwshHere';      Admin = $false; Label = $NormalLabel }
        [pscustomobject]@{ Name = 'OpenPwshHereAdmin'; Admin = $true;  Label = $AdminLabel  }
    )
}

function Get-OpenPwshHereKeyPath {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Name
    )
    return (Join-Path (Join-Path 'HKCU:\Software\Classes' $Key) $Name)
}

function Get-OpenPwshHereAdminProfileName { return $script:OpenPwshHereAdminProfileName }
function Get-OpenPwshHereAdminProfileGuid { return $script:OpenPwshHereAdminProfileGuid }

function Get-OpenPwshHereWtSettingsPath {
    return (Join-Path $env:LOCALAPPDATA ('Packages\{0}\LocalState\settings.json' -f $script:OpenPwshHereWtPackageFamily))
}

function Resolve-OpenPwshHerePwsh {
    param([string] $Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "pwsh.exe not found: $Explicit"
        }
        return (Convert-Path -LiteralPath $Explicit)
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:SCOOP) { $candidates.Add((Join-Path $env:SCOOP 'apps\pwsh\current\pwsh.exe')) }
    $candidates.Add((Join-Path $env:USERPROFILE 'scoop\apps\pwsh\current\pwsh.exe'))

    $app = Get-Command pwsh -CommandType Application -All -ErrorAction SilentlyContinue |
           Where-Object { $_.Source -match 'apps\\pwsh\\current\\pwsh\.exe$' } |
           Select-Object -First 1
    if ($app) { $candidates.Insert(0, $app.Source) }

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return (Convert-Path -LiteralPath $c) }
    }
    throw 'Cannot locate a Scoop pwsh.exe. Pass -PwshPath with the full path.'
}

# Resolve wt.exe. Prefer the stable app-execution-alias path (it survives
# Windows Terminal upgrades) and require the matching App Paths registration.
function Resolve-OpenPwshHereWt {
    param([string] $Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "wt.exe not found: $Explicit"
        }
        return (Convert-Path -LiteralPath $Explicit)
    }

    $appPathKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\wt.exe'
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if ((Test-Path -LiteralPath $alias -PathType Leaf) -and (Test-Path -LiteralPath $appPathKey)) {
        return (Convert-Path -LiteralPath $alias)
    }
    if (Test-Path -LiteralPath $appPathKey) {
        $real = (Get-Item -LiteralPath $appPathKey).GetValue('')
        if ($real -and (Test-Path -LiteralPath $real -PathType Leaf)) { return $real }
    }
    return $null
}

# Build the exact command string stored in the registry.
# "%1\." / "%V\." is deliberate: the trailing "\." keeps the character before
# the closing quote from being a backslash, which would escape that quote in
# the Windows command-line parser (a real failure at drive roots such as E:\).
function Get-OpenPwshHereCommand {
    param(
        [Parameter(Mandatory)] [string] $PwshPath,
        [Parameter(Mandatory)] [string] $Placeholder,
        [string] $HelperPath = '',
        [switch] $Admin,
        [ValidateSet('Legacy', 'WindowsTerminal')] [string] $Mode = 'Legacy',
        [string] $WtPath = '',
        [string] $AdminProfileName = $script:OpenPwshHereAdminProfileName
    )

    $quotedDir = '"' + $Placeholder + '\.' + '"'

    if ($Mode -eq 'WindowsTerminal') {
        if (-not $WtPath) { throw 'WindowsTerminal mode requires -WtPath.' }
        $quotedWt = '"' + $WtPath + '"'
        if ($Admin) {
            # -w -1 forces a new window. The profile carries "elevate": true,
            # so Windows Terminal creates an elevated window for this tab.
            return ($quotedWt + ' -w -1 -p "' + $AdminProfileName + '" -d ' + $quotedDir)
        }
        # No -p: Windows Terminal uses the user's defaultProfile (scoop pwsh).
        return ($quotedWt + ' -w -1 -d ' + $quotedDir)
    }

    if (-not $HelperPath) { throw 'Legacy mode requires -HelperPath.' }
    $quotedPwsh = '"' + $PwshPath + '"'
    $quotedHelper = '"' + $HelperPath + '"'
    if ($Admin) {
        return ($quotedPwsh + ' -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ' +
                $quotedHelper + ' ' + $quotedPwsh + ' ' + $quotedDir)
    }
    return ($quotedPwsh + ' -NoExit -WorkingDirectory ' + $quotedDir)
}

# Detect which mode the installed normal verb currently uses.
function Get-OpenPwshHereInstalledMode {
    $key = Get-OpenPwshHereKeyPath -Key 'Directory\Background\shell' -Name 'OpenPwshHere'
    $cmdKey = Join-Path $key 'command'
    if (-not (Test-Path -LiteralPath $cmdKey)) { return $null }
    $raw = (Get-Item -LiteralPath $cmdKey).GetValue('')
    if (-not $raw) { return $null }
    $argv = Split-WindowsCommandLine $raw
    if ($argv.Count -gt 0 -and [System.IO.Path]::GetFileName($argv[0]) -eq 'wt.exe') {
        return 'WindowsTerminal'
    }
    return 'Legacy'
}

# Add or refresh the elevated Windows Terminal profile. Idempotent: matched by
# the fixed GUID first, then by name. Appearance-only properties are cloned from
# the user's default profile so both windows look identical.
function Set-OpenPwshHereAdminProfile {
    param(
        [Parameter(Mandatory)] [string] $SettingsPath,
        [Parameter(Mandatory)] [string] $PwshPath,
        [Parameter(Mandatory)] [string] $ProfileName,
        [Parameter(Mandatory)] [string] $BackupPath
    )

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "Windows Terminal settings.json not found: $SettingsPath"
    }
    $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8
    $json = $raw | ConvertFrom-Json
    if (-not $json.profiles -or -not $json.profiles.list) {
        throw 'Windows Terminal settings.json has no profiles.list array.'
    }

    Copy-Item -LiteralPath $SettingsPath -Destination $BackupPath -Force

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($json.profiles.list)) { [void] $items.Add($item) }
    $guid = $script:OpenPwshHereAdminProfileGuid
    $existing = $items | Where-Object { $_.guid -eq $guid -or $_.name -eq $ProfileName } |
                Select-Object -First 1
    $default = $items | Where-Object { $_.guid -eq $json.defaultProfile } | Select-Object -First 1

    $profile = [ordered]@{}
    $profile['commandline'] = $PwshPath
    $profile['elevate'] = $true
    $skip = @('guid', 'name', 'commandline', 'source', 'hidden', 'startingDirectory',
              'elevate', 'tabTitle', 'icon', 'closeOnExit')
    if ($default) {
        foreach ($prop in $default.PSObject.Properties) {
            if ($skip -notcontains $prop.Name) { $profile[$prop.Name] = $prop.Value }
        }
    }
    $profile['guid'] = if ($existing -and $existing.guid) { $existing.guid } else { $guid }
    $profile['hidden'] = $false
    $profile['name'] = $ProfileName
    $profile['startingDirectory'] = $null

    $rebuilt = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        if ($item -ne $existing) { [void] $rebuilt.Add($item) }
    }
    [void] $rebuilt.Add([pscustomobject] $profile)
    $json.profiles.list = $rebuilt.ToArray()
    $json | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $SettingsPath -Encoding utf8

    return $profile['guid']
}

# Remove only the profile this skill created; never discard unrelated settings.
function Remove-OpenPwshHereAdminProfile {
    param(
        [Parameter(Mandatory)] [string] $SettingsPath,
        [Parameter(Mandatory)] [string] $ProfileName,
        [Parameter(Mandatory)] [string] $BackupPath
    )

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return $false }
    $json = (Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8) | ConvertFrom-Json
    if (-not $json.profiles -or -not $json.profiles.list) { return $false }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($json.profiles.list)) { [void] $items.Add($item) }
    $guid = $script:OpenPwshHereAdminProfileGuid
    $matched = @($items | Where-Object { $_.guid -eq $guid -or $_.name -eq $ProfileName })
    if ($matched.Count -eq 0) { return $false }

    Copy-Item -LiteralPath $SettingsPath -Destination $BackupPath -Force
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        if ($item.guid -ne $guid -and $item.name -ne $ProfileName) { [void] $kept.Add($item) }
    }
    $json.profiles.list = $kept.ToArray()
    $json | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $SettingsPath -Encoding utf8
    return $true
}

# Faithful-enough reimplementation of the Windows command-line split used by
# CreateProcess / CommandLineToArgvW. Used for static verification only.
function Split-WindowsCommandLine {
    param([Parameter(Mandatory)] [string] $CommandLine)

    $result = [System.Collections.Generic.List[string]]::new()
    $sb = [System.Text.StringBuilder]::new()
    $started = $false
    $inQuotes = $false
    $i = 0
    $length = $CommandLine.Length

    while ($i -lt $length) {
        $ch = $CommandLine[$i]

        if (-not $inQuotes -and ($ch -eq ' ' -or $ch -eq "`t")) {
            if ($started) {
                $result.Add($sb.ToString())
                [void] $sb.Clear()
                $started = $false
            }
            $i++
            continue
        }
        $started = $true

        if ($ch -eq '\') {
            $j = $i
            while ($j -lt $length -and $CommandLine[$j] -eq '\') { $j++ }
            $slashes = $j - $i
            if ($j -lt $length -and $CommandLine[$j] -eq '"') {
                [void] $sb.Append(('\' * [int] [math]::Floor($slashes / 2)))
                if ($slashes % 2 -eq 1) {
                    [void] $sb.Append('"')
                    $i = $j + 1
                    continue
                }
                $i = $j
            }
            else {
                [void] $sb.Append(('\' * $slashes))
                $i = $j
                continue
            }
        }

        if ($i -lt $length -and $CommandLine[$i] -eq '"') {
            if ($inQuotes -and ($i + 1) -lt $length -and $CommandLine[$i + 1] -eq '"') {
                [void] $sb.Append('"')
                $i += 2
                continue
            }
            $inQuotes = -not $inQuotes
            $i++
            continue
        }

        [void] $sb.Append($ch)
        $i++
    }

    if ($started) { $result.Add($sb.ToString()) }
    return ,$result.ToArray()
}
