<#
Test-OpenPwshHere.ps1

Verifies the installed verbs without clicking through Explorer. It detects the
installed mode from the registry and checks accordingly:

  WindowsTerminal mode - wt.exe alias + App Paths registration, Windows Terminal
    version, the "elevate": true admin profile in settings.json, all six verbs,
    HKCR shadowing and Windows argv splitting of -w / -p / -d against a plain
    path, a path with spaces and a drive root.

  Legacy mode - the original checks, including helper -DryRun and real pwsh.exe
    launches that report their working directory and elevation state.

Both modes also assert menu hygiene: exactly two terminal verbs per context in
HKCU and in the merged HKCR view, and the packaged Windows Terminal verb hidden
in the per-user Shell Extensions\Blocked list (use -AllowWindowsTerminalVerb
only when the installer was run with -KeepWindowsTerminalVerb).

Neither mode clicks an Explorer menu, triggers UAC, or observes an elevated
Windows Terminal window. Those are manual acceptance steps in SKILL.md.
#>
[CmdletBinding()]
param(
    [string] $PwshPath,
    [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'OpenPwshHere'),
    [string] $WtSettingsPath,
    [switch] $ProbeWtExe,
    [switch] $AllowWindowsTerminalVerb
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'OpenPwshHere.Common.ps1')

if (-not $WtSettingsPath) { $WtSettingsPath = Get-OpenPwshHereWtSettingsPath }

$script:passed = 0
$script:failed = 0
function Assert-OpenPwshHere {
    param([bool] $Condition, [Parameter(Mandatory)] [string] $Name, [string] $Detail = '')
    if ($Condition) {
        $script:passed++
        Write-Output ("  PASS  {0}" -f $Name)
    }
    else {
        $script:failed++
        Write-Output ("  FAIL  {0} :: {1}" -f $Name, $Detail)
    }
}

# Parser self-check so a broken parser cannot silently pass the real checks.
$p1 = Split-WindowsCommandLine '"C:\a b\pwsh.exe" -NoExit -WorkingDirectory "E:\dir with spaces\."'
Assert-OpenPwshHere ($p1.Count -eq 4 -and $p1[0] -eq 'C:\a b\pwsh.exe' -and $p1[3] -eq 'E:\dir with spaces\.') `
    'argv parser self-test (quotes and spaces)' ($p1 -join ' | ')
$p2 = Split-WindowsCommandLine 'tool.exe -c "say ""hi"""'
Assert-OpenPwshHere ($p2.Count -eq 3 -and $p2[2] -eq 'say "hi"') 'argv parser self-test (doubled quotes)' ($p2 -join ' | ')

$mode = Get-OpenPwshHereInstalledMode
if (-not $mode) {
    Write-Output 'RESULT: 0 passed, 1 failed'
    Write-Output '  FAIL  no installed normal verb found'
    exit 1
}

$pwsh = Resolve-OpenPwshHerePwsh -Explicit $PwshPath
$helper = Join-Path $InstallDir 'Launch-AdminPwsh.ps1'
$targets = Get-OpenPwshHereTargets
$verbs = Get-OpenPwshHereVerbs

$backgroundKey = Get-OpenPwshHereKeyPath -Key 'Directory\Background\shell' -Name 'OpenPwshHere'
$adminKey = Get-OpenPwshHereKeyPath -Key 'Directory\Background\shell' -Name 'OpenPwshHereAdmin'
$normalRaw = (Get-Item -LiteralPath (Join-Path $backgroundKey 'command')).GetValue('')
$adminRaw = (Get-Item -LiteralPath (Join-Path $adminKey 'command')).GetValue('')
$normalArgv = Split-WindowsCommandLine $normalRaw
$adminArgv = Split-WindowsCommandLine $adminRaw
$wt = if ($mode -eq 'WindowsTerminal') { $normalArgv[0] } else { $null }
$pIndex = [Array]::IndexOf($adminArgv, '-p')
$profileName = if ($pIndex -ge 0 -and ($pIndex + 1) -lt $adminArgv.Count) {
    $adminArgv[$pIndex + 1]
}
else { Get-OpenPwshHereAdminProfileName }

Write-Output ''
Write-Output ("=== 0. installed mode: {0} ===" -f $mode)
Write-Output ("  INFO  wt.exe       : {0}" -f $(if ($wt) { $wt } else { '<not used>' }))
Write-Output ("  INFO  admin profile: {0}" -f $(if ($mode -eq 'WindowsTerminal') { $profileName } else { '<helper RunAs>' }))

Write-Output ''
Write-Output '=== 1. binaries ==='
Assert-OpenPwshHere (Test-Path -LiteralPath $pwsh -PathType Leaf) 'pwsh.exe exists' $pwsh
$edition = (& $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSEdition' 2>$null | Select-Object -First 1)
Assert-OpenPwshHere ($edition -eq 'Core') 'pwsh.exe is PowerShell Core' ("edition=$edition")

if ($mode -eq 'WindowsTerminal') {
    Assert-OpenPwshHere (Test-Path -LiteralPath $wt -PathType Leaf) 'wt.exe exists' $wt
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    Assert-OpenPwshHere (Test-Path -LiteralPath $alias -PathType Leaf) 'app execution alias present' $alias
    $appPathKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\wt.exe'
    $realWt = if (Test-Path -LiteralPath $appPathKey) { (Get-Item -LiteralPath $appPathKey).GetValue('') } else { $null }
    Assert-OpenPwshHere ($realWt -and (Test-Path -LiteralPath $realWt -PathType Leaf)) `
        'App Paths points to a real Windows Terminal binary' ("target=$realWt")
    $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue | Select-Object -First 1
    $ver = if ($pkg) { [version] $pkg.Version } else { $null }
    Assert-OpenPwshHere ($ver -and $ver -ge [version] '1.18.0.0') `
        'Windows Terminal supports the elevate profile property' ("version=$ver")
    if ($ProbeWtExe) {
        & $wt --version 2>$null | Out-Null
        Assert-OpenPwshHere ($LASTEXITCODE -eq 0) 'wt.exe alias smoke test exits 0' ("exit=$LASTEXITCODE")
    }
}
else {
    Assert-OpenPwshHere (Test-Path -LiteralPath $helper -PathType Leaf) 'admin helper installed' $helper
}

Write-Output ''
Write-Output '=== 2. registry keys and HKLM shadowing ==='
foreach ($t in $targets) {
    foreach ($v in $verbs) {
        $key = Get-OpenPwshHereKeyPath -Key $t.Key -Name $v.Name
        $expected = Get-OpenPwshHereCommand -PwshPath $pwsh -HelperPath $helper `
                        -Placeholder $t.Placeholder -Mode $mode -WtPath $wt `
                        -AdminProfileName $profileName -Admin:$v.Admin
        $tag = ('{0}/{1}' -f $t.Key, $v.Name)

        Assert-OpenPwshHere (Test-Path -LiteralPath $key) ("HKCU key exists $tag") $key
        $regKey = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
        Assert-OpenPwshHere ($regKey -and $regKey.GetValue('') -eq $v.Label) ("label $tag") ("actual=$($regKey.GetValue(''))")
        Assert-OpenPwshHere ($regKey -and $regKey.GetValue('Icon') -eq $pwsh) ("icon $tag")
        if ($v.Admin) {
            Assert-OpenPwshHere ($regKey -and $regKey.GetValueNames() -contains 'HasLUAShield') ("HasLUAShield $tag")
        }
        $commandKey = Join-Path $key 'command'
        $actual = (Get-Item -LiteralPath $commandKey -ErrorAction SilentlyContinue).GetValue('')
        Assert-OpenPwshHere ($actual -eq $expected) ("command $tag") ("expected=$expected actual=$actual")

        $mergedPath = 'Registry::HKEY_CLASSES_ROOT\' + $t.Key + '\' + $v.Name + '\command'
        $merged = (Get-Item -LiteralPath $mergedPath -ErrorAction SilentlyContinue).GetValue('')
        Assert-OpenPwshHere ($merged -eq $expected) ("HKCR merged view wins $tag") ("merged=$merged")
    }
}

# Probe directories deliberately include a space-bearing path and a drive root.
$probeRoot = Join-Path $env:TEMP 'open-pwsh-here-test'
New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
$plainDir = Join-Path $probeRoot 'plain'
$spaceDir = Join-Path $probeRoot 'dir with spaces'
New-Item -ItemType Directory -Force -Path $plainDir, $spaceDir | Out-Null
$rootDir = [System.IO.Path]::GetPathRoot($pwsh)
$probeDirs = @($plainDir, $spaceDir, $rootDir)

Write-Output ''
Write-Output '=== 3. command-line parsing (all targets x all probe directories) ==='
foreach ($t in $targets) {
    $normal = Get-OpenPwshHereCommand -PwshPath $pwsh -HelperPath $helper -Placeholder $t.Placeholder `
                  -Mode $mode -WtPath $wt -AdminProfileName $profileName
    $admin = Get-OpenPwshHereCommand -PwshPath $pwsh -HelperPath $helper -Placeholder $t.Placeholder `
                 -Mode $mode -WtPath $wt -AdminProfileName $profileName -Admin

    foreach ($dir in $probeDirs) {
        $suffix = $dir + '\.'
        $tag = ('{0} / {1}' -f $t.Placeholder, $dir)
        $wanted = (Get-Item -LiteralPath $dir).FullName

        $normalArgv = Split-WindowsCommandLine ($normal.Replace($t.Placeholder, $dir))
        $adminArgv2 = Split-WindowsCommandLine ($admin.Replace($t.Placeholder, $dir))

        if ($mode -eq 'WindowsTerminal') {
            $ok = $normalArgv.Count -eq 5 -and $normalArgv[0] -eq $wt -and
                  $normalArgv[1] -eq '-w' -and $normalArgv[2] -eq '-1' -and
                  $normalArgv[3] -eq '-d' -and $normalArgv[4] -eq $suffix -and
                  (Test-Path -LiteralPath $normalArgv[4]) -and
                  (Get-Item -LiteralPath $normalArgv[4]).FullName -eq $wanted
            Assert-OpenPwshHere $ok ("normal wt argv $tag") ($normalArgv -join ' | ')

            $ok = $adminArgv2.Count -eq 7 -and $adminArgv2[0] -eq $wt -and
                  $adminArgv2[1] -eq '-w' -and $adminArgv2[2] -eq '-1' -and
                  $adminArgv2[3] -eq '-p' -and $adminArgv2[4] -eq $profileName -and
                  $adminArgv2[5] -eq '-d' -and $adminArgv2[6] -eq $suffix -and
                  (Test-Path -LiteralPath $adminArgv2[6]) -and
                  (Get-Item -LiteralPath $adminArgv2[6]).FullName -eq $wanted
            Assert-OpenPwshHere $ok ("admin wt argv $tag") ($adminArgv2 -join ' | ')
        }
        else {
            $ok = $normalArgv.Count -eq 4 -and $normalArgv[0] -eq $pwsh -and
                  $normalArgv[1] -eq '-NoExit' -and $normalArgv[2] -eq '-WorkingDirectory' -and
                  (Test-Path -LiteralPath $normalArgv[3]) -and
                  (Get-Item -LiteralPath $normalArgv[3]).FullName -eq $wanted
            Assert-OpenPwshHere $ok ("normal argv $tag") ($normalArgv -join ' | ')

            $ok = $adminArgv2.Count -eq 11 -and $adminArgv2[0] -eq $pwsh -and
                  $adminArgv2[7] -eq '-File' -and $adminArgv2[8] -eq $helper -and
                  $adminArgv2[9] -eq $pwsh -and $adminArgv2[10] -eq $suffix
            Assert-OpenPwshHere $ok ("admin launcher argv $tag") ($adminArgv2 -join ' | ')

            if (Test-Path -LiteralPath $helper) {
                $dry = (& $pwsh -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass `
                            -File $helper $pwsh $suffix -DryRun 2>$null | Select-Object -First 1) | ConvertFrom-Json
                $childArgv = if ($dry -and $dry.ChildCommandLine) { Split-WindowsCommandLine $dry.ChildCommandLine } else { @() }
                $ok = $dry -and $dry.Verb -eq 'RunAs' -and $dry.PwshPath -eq $pwsh -and
                      $childArgv.Count -eq 3 -and $childArgv[0] -eq '-NoExit' -and
                      $childArgv[1] -eq '-WorkingDirectory' -and
                      (Test-Path -LiteralPath $childArgv[2]) -and
                      (Get-Item -LiteralPath $childArgv[2]).FullName -eq $wanted
                Assert-OpenPwshHere $ok ("admin RunAs child argv $tag") ($childArgv -join ' | ')
            }
        }
    }
}

if ($mode -eq 'WindowsTerminal') {
    Write-Output ''
    Write-Output '=== 4. Windows Terminal elevated profile ==='
    Assert-OpenPwshHere (Test-Path -LiteralPath $WtSettingsPath -PathType Leaf) 'settings.json exists' $WtSettingsPath
    $json = $null
    if (Test-Path -LiteralPath $WtSettingsPath -PathType Leaf) {
        try { $json = (Get-Content -LiteralPath $WtSettingsPath -Raw -Encoding utf8) | ConvertFrom-Json }
        catch { $json = $null }
    }
    Assert-OpenPwshHere ($null -ne $json) 'settings.json parses as JSON' $WtSettingsPath
    if ($json) {
        $profiles = @($json.profiles.list)
        $matches = @($profiles | Where-Object { $_.name -eq $profileName })
        Assert-OpenPwshHere ($matches.Count -eq 1) 'exactly one admin profile with the requested name' ("count=$($matches.Count)")
        $adminProfile = $matches | Select-Object -First 1
        if ($adminProfile) {
            Assert-OpenPwshHere ($adminProfile.elevate -eq $true) 'admin profile has elevate=true' ("elevate=$($adminProfile.elevate)")
            Assert-OpenPwshHere ($adminProfile.commandline -eq $pwsh) 'admin profile launches the Scoop pwsh.exe' ("commandline=$($adminProfile.commandline)")
            Assert-OpenPwshHere ($null -eq $adminProfile.startingDirectory) 'admin profile lets -d choose the directory' ("startingDirectory=$($adminProfile.startingDirectory)")
            Assert-OpenPwshHere ($adminProfile.hidden -ne $true) 'admin profile is visible in the profile list'
            $sameGuid = @($profiles | Where-Object { $_.guid -eq $adminProfile.guid })
            Assert-OpenPwshHere ($sameGuid.Count -eq 1) 'admin profile GUID is unique' ("count=$($sameGuid.Count)")
            $defaultProfile = $profiles | Where-Object { $_.guid -eq $json.defaultProfile } | Select-Object -First 1
            if ($defaultProfile -and $defaultProfile.font -and $defaultProfile.font.face) {
                Assert-OpenPwshHere ($adminProfile.font -and $adminProfile.font.face -eq $defaultProfile.font.face) `
                    'admin window matches the default profile font' ("admin=$($adminProfile.font.face) default=$($defaultProfile.font.face)")
            }
        }
    }
}
else {
    Write-Output ''
    Write-Output '=== 4. live pwsh launch with the installed argument shape ==='
    $probeScript = Join-Path $probeRoot 'probe.ps1'
    $resultFile = Join-Path $probeRoot 'result.json'
    @'
$out = Join-Path $env:TEMP 'open-pwsh-here-test\result.json'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
[pscustomobject]@{
    Pwd      = (Get-Location).Path
    User     = $id.Name
    Elevated = ([Security.Principal.WindowsPrincipal] $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $out -Encoding utf8
'@ | Set-Content -LiteralPath $probeScript -Encoding utf8

    foreach ($dir in $probeDirs) {
        if (Test-Path -LiteralPath $resultFile) { Remove-Item -LiteralPath $resultFile -Force }
        & $pwsh -NoLogo -NoProfile -WindowStyle Hidden -WorkingDirectory ($dir + '\.') -File $probeScript 2>$null | Out-Null
        $observed = if (Test-Path -LiteralPath $resultFile) { Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json } else { $null }
        $wanted = (Get-Item -LiteralPath $dir).FullName
        Assert-OpenPwshHere ($observed -and $observed.Pwd -eq $wanted) ("pwsh working directory $dir") ("observed=$($observed.Pwd)")
        Assert-OpenPwshHere ($observed -and $observed.Elevated -eq $false) ("normal verb stays non-elevated $dir")
    }
}

Write-Output ''
Write-Output '=== 5. exactly two terminal menu entries ==='
foreach ($view in @('HKCU', 'HKCR')) {
    $found = @(Get-OpenPwshHereTerminalVerbNames -View $view)
    foreach ($t in $targets) {
        $group = @($found | Where-Object { $_.Context -eq $t.Key })
        $names = @($group | ForEach-Object { $_.Name } | Sort-Object)
        $ok = $group.Count -eq 2 -and ($names -join ',') -eq 'OpenPwshHere,OpenPwshHereAdmin'
        Assert-OpenPwshHere $ok ("$view has exactly two terminal verbs: $($t.Key)") `
            (($group | ForEach-Object { "$($_.Name)=$($_.Label)" }) -join ' / ')
    }
}
$extensionPresent = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Classes\PackagedCom\ClassIndex\{9f156763-7844-4dc4-b2b1-901f640f5155}'
Write-Output ("  INFO  packaged Windows Terminal Explorer extension registered: {0}" -f $extensionPresent)
$blockedKey = Get-OpenPwshHereBlockedKey
$blockedReg = Get-Item -LiteralPath $blockedKey -ErrorAction SilentlyContinue
$blockedNames = if ($blockedReg) { @($blockedReg.GetValueNames()) } else { @() }
foreach ($c in Get-OpenPwshHereTerminalClsids) {
    if ($AllowWindowsTerminalVerb) {
        Write-Output ("  INFO  packaged verb hiding not required: {0}" -f $c.Label)
        continue
    }
    Assert-OpenPwshHere ($blockedNames -contains $c.Guid) `
        ("packaged verb hidden: {0}" -f $c.Label) ("blocked key=$blockedKey names=$($blockedNames -join ',')")
}

Write-Output ''
Write-Output '=== 6. environment notes ==='
$startup = Get-Item -LiteralPath 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
$delegation = if ($startup) { $startup.GetValue('DelegationTerminal') } else { '<key absent>' }
Write-Output ("  INFO  HKCU\Console\%%Startup DelegationTerminal = {0}" -f $delegation)
Write-Output '  INFO  {00000000-...} = automatic (Windows Terminal when available); explicit wt.exe does not depend on this.'
$uac = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
Write-Output ("  INFO  UAC EnableLUA={0} ConsentPromptBehaviorAdmin={1} PromptOnSecureDesktop={2}" -f `
    $uac.EnableLUA, $uac.ConsentPromptBehaviorAdmin, $uac.PromptOnSecureDesktop)
Write-Output '  INFO  No Explorer click, no UAC prompt and no elevated window observed here; those are manual acceptance steps.'

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
