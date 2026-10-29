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
if($BridgeDirectory){$safe.XshellOptions['SingleProcessMode']='1'}
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
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'register-personal.ps1') -Destination (Join-Path $output 'register-personal.ps1')
if($BridgeDirectory){
    $tools=Join-Path $output 'Tools'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    foreach($name in @('registry-bridge.dll','registry-runner.exe','registry-probe.exe')){Copy-Item -LiteralPath (Join-Path $BridgeDirectory $name) -Destination $tools}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'portable-user.ps1') -Destination (Join-Path $output 'portable.ps1') -Force
}
Write-Text (Join-Path $output 'Register-Personal.cmd') "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0register-personal.ps1`"`r`npause`r`n"
foreach ($app in @('Xshell','Xftp')) {
    $vbs=@'
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
root = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(root, "portable.ps1")
command = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """ -App APPNAME"
sh.Run command, 0, False
'@
    Write-Text (Join-Path $output "$app-Portable.vbs") ($vbs.Replace('APPNAME',$app))
}
$readme=@"
Xshell / Xftp 8 Portable

Xshell product version: $($versions.Xshell)
Xftp product version: $($versions.Xftp)

Extract the entire ZIP into a writable local directory. Double-click
Xshell-Portable.vbs or Xftp-Portable.vbs. Windows PowerShell 5.1 and Windows
Script Host are required. If VBS is disabled, run:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\portable.ps1 -App Xshell

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
On a new PC, launch either Portable.vbs and approve Windows elevation once.
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
if($BridgeDirectory){
    Remove-Item -LiteralPath (Join-Path $output 'Register-Personal.cmd'),(Join-Path $output 'register-personal.ps1')
    Write-Text (Join-Path $output 'USAGE.txt') @"
Xshell / Xftp 8 - current-user portable edition

Extract the ZIP into a writable local folder; it has no enclosing directory.
Double-click Xshell-Portable.vbs or Xftp-Portable.vbs. No administrator
registration, UAC prompt, service, driver or machine registry write is used.
Windows PowerShell 5.1 and Windows Script Host are required.

Tools/registry-runner.exe loads a process-local registry bridge into the
original 32-bit vendor programs and their children. NetSarang registry
access is routed to HKCU/Software/CodexPortable/NetSarang8, isolated by package
path. System registry keys and installed NetSarang profiles are not replaced.
Do not run both package launchers simultaneously. Close all package apps
before moving the directory; saved settings are in Data/registry.clixml.
New sessions are in Data/8. The initial archive excludes connection data.

Original Personal registration and owner name/email are included as requested.
Keep this private. Vendor license checks are unchanged. Free licensing is
for personal/educational non-commercial use. Cross-PC acceptance depends on
vendor validation. No promise of universal licensing or antivirus compatibility.

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
