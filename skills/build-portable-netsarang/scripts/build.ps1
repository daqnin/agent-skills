param(
    [Parameter(Mandatory)][string]$XshellPath,
    [Parameter(Mandatory)][string]$XftpPath,
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$PreservePersonalRegistration,
    [string]$BridgeDirectory
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Output directory already exists; choose a fresh directory.' }
if (Test-Path -LiteralPath ($OutputDirectory + '.zip')) { throw 'Output ZIP already exists.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-Text($path, $text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllText($path, $text, $utf8)
}
function Read-Ini($path) {
    $ini = [ordered]@{}
    if (!(Test-Path -LiteralPath $path)) { return $ini }
    $section = ''
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line -match '^\[(.+)\]\s*$') { $section=$matches[1]; $ini[$section]=[ordered]@{} }
        elseif ($section -and $line -match '^([^=]+)=(.*)$') { $ini[$section][$matches[1]]=$matches[2] }
    }
    return $ini
}
function Write-Ini($path, $ini) {
    $lines = foreach ($section in $ini.Keys) { "[$section]"; foreach ($key in $ini[$section].Keys) { "$key=$($ini[$section][$key])" }; '' }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllLines($path, [string[]]$lines, [Text.Encoding]::Unicode)
}
$versions = [ordered]@{}
foreach ($app in @('Xshell','Xftp')) {
    $source = if ($app -eq 'Xshell') { $XshellPath } else { $XftpPath }
    $exe = Join-Path $source "$app.exe"
    $signature = Get-AuthenticodeSignature -LiteralPath $exe
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'NetSarang') { throw "Invalid vendor signature: $app" }
    $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if ($version -notmatch '^8[.,]') { throw 'Only major version 8 is supported.' }
    $registered = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq "$app 8" } | Select-Object -ExpandProperty DisplayVersion -Unique)
    $versions[$app] = "registered=$($registered -join ','); binary=$version"
    $dest = Join-Path $output "App\$app 8"
    [IO.Directory]::CreateDirectory($dest) | Out-Null
    # Copy only known vendor assets. No arbitrary user scripts, activation or profile files.
    $dirs = @('Languages')
    if ($app -eq 'Xshell') { $dirs += @('ColorSchemes','Icons','HighlightSample','ScriptSample') }
    foreach ($file in Get-ChildItem -LiteralPath $source -File) {
        if ($file.Extension -in @('.exe','.dll','.tlb','.ico','.pdf') -or $file.Name -in @('python38.zip','crashrpt_lang.ini','filexfer.dat','LiveUpdate.dat','example.tkm')) {
            Copy-Item -LiteralPath $file.FullName -Destination $dest
        }
    }
    foreach ($dir in $dirs) {
        $p = Join-Path $source $dir
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dest -Recurse }
    }
    if($BridgeDirectory){
        foreach($runtime in @('mfc140u.dll','msvcp140.dll','vcruntime140.dll','concrt140.dll','msvcp140_1.dll','msvcp140_2.dll')){
            $runtimePath=Join-Path "$env:SystemRoot\SysWOW64" $runtime
            $sig=Get-AuthenticodeSignature -LiteralPath $runtimePath
            if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft'){throw "Invalid Microsoft runtime: $runtime"}
            Copy-Item -LiteralPath $runtimePath -Destination $dest
        }
    }
}
$data = Join-Path $output 'Data\8'
$shellKeys = @('MouseRightButton','UseAltI','OpenSftpAsTab','EnableAltMenuKey','ExitAllTabClose','CopyOnSelect','TransPercent','EnglishOnEsc','LeftClickMoveCursor','UseAltShiftT','PasteMultiLineCode','ClearScrollBufferOnClose','KeypadEnterToTab','ShowFileManagerTab','PasteBufSize','TabMaxWidth','SoftTab','IncludeNewLineChar','PasteMode','FullScreenScrollBar','HilightWithScrollBuff','MinLastTabClose','UseShiftTab','NewTabAsLocalShell','ImportFileOnDrop','UseCtrlTab','ExitToLocalShellOnClose','SingleProcessMode','ExitLastTabClose','CascadeCurrentSize','ConfirmCloseOnSessionExit','TabDblClickDuplicateSshChannel','DisableCtrlWheel','UseNotepad','StopScrollOnLButtonDown','TransOpaqueOnMouseOver','PrintToEditor','UseDefaultFrame','RemoveWhiteSpace','ComposeWindowLineMode','ShowProfileDlgAtStartUp','UseAlt190','TabDefaultColor','AskModifyFolderSession','ShowReconnectName','MinimizeToSystemTray','ShowCharacterSelect','ComposeWindowScrollbar','UseAltD','Transparent','CtrlHyperlink','ClearHistoryOnExit','WordDelimiters','MouseMiddleButton','UseCustomKeyMap','UseShiftXXX','TrueColorTerminal','PasteBaudRate','ShiftDblDelimiter','FullScreenTitleBar','MinToTrayOnStartup','ComposeWindowEnterKey','ComposeWindowInterpretEscapes','StartTabType','TransTopMost','SmartSelButton','UseHyperlink','ComposeBarTextToAll','FullScreenSessionTab','MultiSession','ConfirmCloseOnExit')
$sourceIni = Read-Ini (Join-Path $ProfilePath 'Xshell\Xshell.ini')
$safe = [ordered]@{XshellOptions=[ordered]@{}}
foreach ($key in $shellKeys) { if ($sourceIni.Contains('XshellOptions') -and $sourceIni['XshellOptions'].Contains($key)) { $safe.XshellOptions[$key]=$sourceIni['XshellOptions'][$key] } }
$safe.XshellOptions['RunOnWindowsStartup']='0'
$safe.XshellOptions['AutoSaveSession']='0'
# Keep the vendor INI value of SingleProcessMode. Forcing it to 1 on Xshell 8
# build 8.0.0.27 selects "Single Core Process Mode" and the viewer handshake
# fails with "Create Child Frame Result : 0". The bridge already isolates
# instances through scoped window lookup and suffixed named events.
$safe['AutoStart']=[ordered]@{Count='0'}
Write-Ini (Join-Path $data 'Xshell\Xshell.ini') $safe
$sourceIni = Read-Ini (Join-Path $ProfilePath 'Xftp\Xftp.ini')
$safe=[ordered]@{}
$ftpSections=@{Start=@('ShowSessionsOnStart','NoLocalTabOnSessionOpen');General=@('ShowBannerOnConnect','UseAltNum','ShowLocalFullPath','UseTildeAsDefaultDirectory','ConfirmDisconnect','AskModifyFolderSession','DeleteFinishedJobs','NaturalOrderSorting','ShowHiddenFiles','LocalDoubleClickAction','RemoteDoubleClickAction','LocalRightClickAction','DragConfirm');Transfer=@('SmartRename','UseFXP','DownThumbImages','RemoveAllCaches');Log=@('MaxLogLineNum','NoLimitLogLine','LogKeepingDays');Security=@('ClearHistoryOnExit')}
foreach ($section in $ftpSections.Keys) { $safe[$section]=[ordered]@{}; foreach ($key in $ftpSections[$section]) { if ($sourceIni.Contains($section) -and $sourceIni[$section].Contains($key)) { $safe[$section][$key]=$sourceIni[$section][$key] } } }
$safe.Log['SaveLogFile']='0'
$safe.Log['LogFolder']='Logs'
Write-Ini (Join-Path $data 'Xftp\Xftp.ini') $safe
# Preserve terminal display defaults, never the source template's connection/auth sections.
$template=Read-Ini (Join-Path $ProfilePath 'Xshell\Sessions\default.xshf')
$display=[ordered]@{}
foreach ($section in @('TERMINAL','TERMINAL:WINDOW')) {
    if (!$template.Contains($section)) { continue }
    $display[$section]=[ordered]@{}
    foreach ($key in $template[$section].Keys) {
        $value=$template[$section][$key]
        if ($key -match 'Path|File|Expect|TerminalName|MoveToWork' -or $value -match '[/\\]|://') { continue }
        $display[$section][$key]=$value
    }
}
Write-Ini (Join-Path $data 'Xshell\Sessions\default.xshf') $display
$keymap=Read-Ini (Join-Path $ProfilePath 'Xshell\CustomKeyMap.ckm')
$safeKeys=[ordered]@{Info=[ordered]@{Version='8.1'};KeyMap=[ordered]@{}}
if ($keymap.Contains('KeyMap')) { foreach ($key in $keymap.KeyMap.Keys) { $value=$keymap.KeyMap[$key]; if ($value -match '^\[0\]ID_[A-Z0-9_]+$') { $safeKeys.KeyMap[$key]=$value } } }
Write-Ini (Join-Path $data 'Xshell\CustomKeyMap.ckm') $safeKeys
$schemes=Join-Path $ProfilePath 'Xshell\ColorScheme Files'
if (Test-Path -LiteralPath $schemes) {
    foreach ($file in Get-ChildItem -LiteralPath $schemes -Filter '*.scs' -File) {
        $ini=Read-Ini $file.FullName
        if (!$ini.Contains('Color Scheme')) { continue }
        $colors=[ordered]@{'Color Scheme'=[ordered]@{}}
        foreach ($key in $ini['Color Scheme'].Keys) { $value=$ini['Color Scheme'][$key]; if ($key -match '^(text|cyan|magenta|green|background|red|yellow|white|blue|black)(\(bold\))?$' -and $value -match '^[0-9a-fA-F]{6}$') { $colors['Color Scheme'][$key]=$value } }
        Write-Ini (Join-Path $data ('Xshell\ColorScheme Files\' + $file.Name)) $colors
    }
}
$settings=@()
$registration=@()
foreach ($app in @('Xshell','Xftp')) {
    $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
    try {
        $key=$machine.OpenSubKey("SOFTWARE\NetSarang\$app\8")
        if (!$key) { throw "Missing installed product registration: $app" }
        try {
            if ($PreservePersonalRegistration -and $key.GetValue('Type') -ne 'Personal') { throw 'Personal registration export requires an existing Personal installation.' }
            $names=@('Version','RESELLER','Type','Package','InstallDate','PackageInstallDate')
            if ($PreservePersonalRegistration) { $names += @('MagicCode','MagicTime','UserName','Company') }
            foreach ($name in $names) {
                if ($name -in $key.GetValueNames()) { $registration += [pscustomobject]@{App=$app;Name=$name;Kind=$key.GetValueKind($name).ToString();Value=$key.GetValue($name)} }
            }
        } finally { $key.Dispose() }
    } finally { $machine.Dispose() }
    $user=Get-Item -LiteralPath "HKCU:\Software\NetSarang\$app\8"
    $names=@('Version','Reseller')
    if ($PreservePersonalRegistration) { $names += @('UserName','Email') }
    foreach ($name in $names) {
        if ($name -in $user.GetValueNames()) { $settings += [pscustomobject]@{Path="$app\8";Name=$name;Kind='String';Value=$user.GetValue($name)} }
    }
    if($PreservePersonalRegistration){
        $license=Get-Item -LiteralPath "HKCU:\Software\NetSarang\$app\8\License" -ErrorAction SilentlyContinue
        if($license){foreach($name in @('SubmitTime','SubmitToken','CheckInChecked','FreeLicenseKey','MIDList')){
            if($name -in $license.GetValueNames()){$settings += [pscustomobject]@{Path="$app\8\License";Name=$name;Kind=$license.GetValueKind($name).ToString();Value=$license.GetValue($name)}}
        }}
    }
}
$registryAllowed=@{
    ''=@('MultiCoreProcess','TrueColorTerminal','LastWinWidth','LastWinHeight','LastMaximized','SampleScript','SampleHighlight','SampleIcons','PaneHeight-SessionManager')
    Language=@('Temporary'); MainWindow=@('ShowCmd','Width','Height','MenuBar_DisplayOnFocus')
    PageSetup=@('MarginTop','MarginLeft','MarginRight','MarginBottom')
}
foreach ($app in @('Xshell','Xftp')) {
    foreach ($sub in $registryAllowed.Keys) {
        $relative="$app\8"; if ($sub) { $relative += "\$sub" }
        $key=Get-Item -LiteralPath "HKCU:\Software\NetSarang\$relative" -ErrorAction SilentlyContinue
        if (!$key) { continue }
        foreach ($name in $registryAllowed[$sub]) {
            if ($name -notin $key.GetValueNames()) { continue }
            $kind=$key.GetValueKind($name).ToString()
            if ($kind -in @('DWord','QWord')) { $settings += [pscustomobject]@{Path=$relative;Name=$name;Kind=$kind;Value=$key.GetValue($name)} }
        }
    }
}
$settings | Export-Clixml -LiteralPath (Join-Path $output 'Data\settings.clixml') -Encoding UTF8
$registration | Export-Clixml -LiteralPath (Join-Path $output 'Data\registration.clixml') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'portable.ps1') -Destination (Join-Path $output 'portable.ps1')
if(!$BridgeDirectory){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'register-personal.ps1') -Destination (Join-Path $output 'register-personal.ps1')
}
if($BridgeDirectory){
    $tools=Join-Path $output 'Tools'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    foreach($name in @('registry-bridge.dll','registry-runner.exe','registry-probe.exe','xftp-path-probe.exe')){Copy-Item -LiteralPath (Join-Path $BridgeDirectory $name) -Destination $tools}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'portable-user.ps1') -Destination (Join-Path $output 'portable.ps1') -Force
    # One native x86 GUI launcher, delivered under both names. The file name selects the app.
    foreach($app in @('Xshell','Xftp')){
        Copy-Item -LiteralPath (Join-Path $BridgeDirectory 'portable-launcher.exe') -Destination (Join-Path $output "$app-Portable.exe")
    }
}
if(!$BridgeDirectory){
    # Legacy administrator branch only. Never selected for the delivered no-admin package.
    Write-Text (Join-Path $output 'Register-Personal.cmd') "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0register-personal.ps1`"`r`npause`r`n"
    foreach ($app in @('Xshell','Xftp')) {
        $cmd=@"
@echo off
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0portable.ps1" -App $app
"@
        Write-Text (Join-Path $output "$app-Portable.cmd") $cmd
    }
}
$readme=@"
Xshell / Xftp 8 Portable

Xshell product version: $($versions.Xshell)
Xftp product version: $($versions.Xftp)

Extract the entire ZIP into a writable local directory. Double-click
Xshell-Portable.cmd or Xftp-Portable.cmd. Windows PowerShell 5.1 is required.
To start from a terminal instead, run:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\portable.ps1 -App Xshell
Xftp can be launched from inside Xshell with the built-in Xftp button where the
installed build supports it. A separate Xftp-Portable.cmd is the reliable fallback.

Close all installed Xshell/Xftp/helper processes first. One launcher can own
the shared profile at a time. If another application is opened, wait for both
applications and their helpers to exit. Do not launch installed copies while
the portable launcher is running. On a clean PC the launcher automatically
requests Windows administrator approval for the first product registration.

Preferences: global mouse/copy/paste/UI options, safe built-in key bindings,
color schemes and terminal display defaults. Executable quick commands,
scripts, custom external paths and opaque toolbar layouts are omitted.
The initial package has no saved sessions, hosts, usernames, passwords,
private keys, host keys, bookmarks, history or activation data.
New sessions created after extraction are stored under Data/8.

HKCU NetSarang settings are temporarily replaced during use and restored
after the applications exit. Interrupted-run recovery is kept on this PC in
LocalAppData/CodexPortable/NetSarang8; rerun a launcher after closing all
NetSarang processes to recover it. Do not move/delete that recovery journal
before recovery. This package is not a registry virtualization sandbox.
Approved existing registry settings are saved on exit; newly introduced
registry preferences outside the allowlist are not retained.

Original vendor binaries are unchanged. License/activation is not included;
the destination must meet the vendor's licensing and runtime requirements.
Clean-machine GUI startup and licensing must be checked on the destination.
"@
if ($PreservePersonalRegistration) {
    $readme=$readme.Replace('hosts, usernames, passwords,','hosts, connection usernames, passwords,').Replace('history or activation data.','history. Personal-license registration identity is retained.').Replace('Original vendor binaries are unchanged. License/activation is not included;', 'Original vendor binaries are unchanged. Existing Personal registration is included;')
    $readme += @"

PERSONAL REGISTRATION / ERROR 40002
This private package includes the source user's free-license name/email and
original Personal installation registration. Do not distribute it publicly.
It does not grant commercial rights or guarantee transfer to another machine.
On a new PC, launch either Portable.cmd and approve Windows elevation once.
Registration then completes automatically and application startup continues.
Register-Personal.cmd is a manual fallback and also requests elevation.
The script writes the original vendor product registration to 32-bit HKLM
and corrects paths to this extracted folder. It does not install a service,
modify binaries, generate license tokens or change license expiry.
Existing different product registration is never overwritten.
After moving the folder, rerun registration only if no conflicting install
exists. If the vendor rejects registration on another PC, obtain your own
free registration from https://www.netsarang.com/en/free-for-home-school/ .
Free use is limited to personal and educational non-commercial purposes.
"@
}
Write-Text (Join-Path $output 'USAGE.txt') $readme
$registrationNotice=if($PreservePersonalRegistration){@"
This build contains the original owner's Personal free registration and
name/email. Keep it private. The vendor's free license allows ONE person to
use one desktop plus one additional personal mobile device, for personal or
educational non-commercial use only. Copying it to your OWN second device is
within those terms; giving it to another person is not. If the vendor rejects
the license on the other PC, use its official free-license flow there instead.
"@}else{@"
This build contains NO personal identity or license fields. On a PC that does
not have the owner's legitimate Personal free registration, Xshell may report
missing product information. Obtain your own free license through the vendor's
official free-license flow; never reuse someone else's registration data.
"@}
if($BridgeDirectory){
    # Legacy helpers are never generated in this branch, so nothing needs deleting.
    Write-Text (Join-Path $output 'USAGE.txt') @"
Xshell / Xftp 8 - current-user portable edition

Extract the ZIP into a writable local folder; it has no enclosing directory.
Double-click Xshell-Portable.exe or Xftp-Portable.exe. These are native x86
GUI launchers: no cmd.exe, Windows Script Host, VBS, administrator
registration, UAC prompt, service, driver or machine registry write is used.
The launcher starts portable.ps1 hidden, which seeds the isolated registry
namespace and calls Tools/registry-runner.exe. Windows PowerShell 5.1 must be
present on the destination PC.

Do NOT double-click App/Xshell 8/Xshell.exe or App/Xftp 8/Xftp.exe directly:
without the runner the registry bridge is never injected, so no portable
profile is used and the installed product's registry may be read or written.
Use Xftp-Portable.exe as the reliable Xftp entry point. The built-in Xftp
button inside Xshell is NOT supported on Xshell 8 build 8.0.0.27: the
XshellCore viewer child terminates with 0xC0000005 before a child frame is
created, even when the registry bridge is injected into it, and Xshell then
exits. Tools/xftp-path-probe.exe only proves that Xftp's product-path lookup
resolves into this package. As a practical alternative, add a custom Xshell
button or quick command that runs Xftp-Portable.exe from this folder.
See the skill's validation-boundary.md.

Tools/registry-runner.exe loads a process-local registry bridge into the
original 32-bit vendor programs and their children. NetSarang registry
access is routed to HKCU/Software/CodexPortable/NetSarang8, isolated by package
path. System registry keys and installed NetSarang profiles are not replaced.
Do not run both package launchers simultaneously. Close all package apps
before moving the directory; saved settings are in Data/registry.clixml.
New sessions are in Data/8. The initial archive excludes connection data.

MOVING TO ANOTHER PC
The package is self-contained: vendor binaries, app-local x86 VC++ runtime
DLLs, settings and registration data all live inside this folder. No
installation, administrator rights or machine registry write is needed. The
isolated namespace is derived from the package path, so extracting to a
different drive or folder automatically builds a fresh namespace from
Data/settings.clixml; no absolute source-machine paths are stored. Close both
applications before copying a used package. Windows PowerShell 5.1 (built into
Windows 10/11) is required on the destination PC. Path-portability has been
tested on the source host; another hardware identity, offline license
validation, ARM64 and other Windows versions have not been verified.

$registrationNotice
Vendor license checks are unchanged. No promise of universal licensing or
antivirus compatibility.

Xshell: $($versions.Xshell)
Xftp: $($versions.Xftp)
"@
}
$files=@(Get-ChildItem -LiteralPath $output -Recurse -File | ForEach-Object { [pscustomobject]@{Path=$_.FullName.Substring($output.Length+1).Replace('\','/');Size=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} })
Write-Text (Join-Path $output 'manifest.json') (@{Products=$versions;Files=$files;ProfilePolicy='allowlisted-preferences-no-connections'} | ConvertTo-Json -Depth 6)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=$output+'.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($output,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Text ($zip+'.sha256') ($hash+'  '+[IO.Path]::GetFileName($zip)+[Environment]::NewLine)
Write-Output "Created: $zip"
Write-Output "SHA256: $hash"
