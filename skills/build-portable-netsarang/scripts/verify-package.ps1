param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$XshellPath,
    [Parameter(Mandatory)][string]$XftpPath,
    [switch]$RunProbe
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path -LiteralPath $OutputDirectory).Path.TrimEnd('\')
$manifest=Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($root+'.zip')
try{
    $entries=@{}
    foreach($entry in $zip.Entries){
        $name=$entry.FullName.Replace('\','/')
        if($name.EndsWith('/')){continue}
        if($name -match '(^|/)\.\.(/|$)|^/|^[A-Za-z]:|(^|/)(SECSH|Credential|applog|Logs|\.git)(/|$)|\.(xsh|xfp|pri|mpw|log|bak|reg)$|LocalBookmark|Data/registry.clixml|register-personal|Register-Personal|(^|/)(Xshell|Xftp)-Portable\.(cmd|vbs)$'){throw 'Forbidden archive path.'}
        if($entries.ContainsKey($name)){throw 'Duplicate archive entry.'}
        $entries[$name]=$entry
    }
    if(!$entries.ContainsKey('App/Xshell 8/Xshell.exe') -or !$entries.ContainsKey('App/Xftp 8/Xftp.exe') -or !$entries.ContainsKey('portable.ps1') -or !$entries.ContainsKey('Xshell-Portable.exe') -or !$entries.ContainsKey('Xftp-Portable.exe')){throw 'Missing root-level application files, native launchers or enclosing ZIP directory.'}
    if($entries.Count -ne $manifest.Files.Count+1){throw 'Archive count differs from manifest.'}
    $seen=@{}
    foreach($file in $manifest.Files){
        if($seen.ContainsKey($file.Path) -or !$entries.ContainsKey($file.Path)){throw 'Duplicate or missing manifest entry.'}
        $seen[$file.Path]=$true
        $entry=$entries[$file.Path];$stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$sha.Dispose()}
        if($hash -ne $file.SHA256 -or $entry.Length -ne $file.Size){throw 'Archive digest/size mismatch.'}
        $local=Join-Path $root $file.Path
        if((Get-FileHash -LiteralPath $local).Hash.ToLowerInvariant() -ne $hash){throw 'Staging differs from archive.'}
    }
    $stream=$entries['manifest.json'].Open();$reader=New-Object IO.StreamReader($stream)
    try{$archived=$reader.ReadToEnd() | ConvertFrom-Json}finally{$reader.Dispose()}
    if(($archived | ConvertTo-Json -Depth 8 -Compress) -ne ($manifest | ConvertTo-Json -Depth 8 -Compress)){throw 'Archived manifest differs.'}
}finally{$zip.Dispose()}
foreach($app in @('Xshell','Xftp')){
    $source=if($app -eq 'Xshell'){$XshellPath}else{$XftpPath}
    if((Get-FileHash -LiteralPath (Join-Path $source "$app.exe")).Hash -ne (Get-FileHash -LiteralPath (Join-Path $root "App\$app 8\$app.exe")).Hash){throw 'Vendor executable modified.'}
}
foreach($file in Get-ChildItem -LiteralPath (Join-Path $root 'Data') -Recurse -File){
    if($file.Extension -eq '.clixml'){continue}
    $content=[IO.File]::ReadAllText($file.FullName)
    if($content -match '(?im)^\[(CONNECTION[^\]]*|Host|InitialFolder|Bookmark)\]|^\s*(Host|UserName|Password|UserKey|Proxy|RemoteCommand|ScriptPath|StartCmd|RecentSession)\s*=|sftp://|ssh://|[A-Z]:\\|\b(?:\d{1,3}\.){3}\d{1,3}\b'){throw 'Connection field or personal path in preferences.'}
}
$settings=@(Import-Clixml -LiteralPath (Join-Path $root 'Data\settings.clixml'))
foreach($entry in $settings){
    if($entry.Path -notmatch '^(Xshell|Xftp)\\8(\\(License|Language|MainWindow|PageSetup))?$'){throw 'Unexpected settings key.'}
    if($entry.Kind -notin @('DWord','QWord') -and !($entry.Kind -eq 'String' -and $entry.Name -in @('Version','Reseller','UserName','Email','SubmitToken','FreeLicenseKey','MIDList'))){throw 'Unexpected settings value kind.'}
}
foreach($entry in @(Import-Clixml -LiteralPath (Join-Path $root 'Data\registration.clixml'))){
    if($entry.App -notin @('Xshell','Xftp') -or $entry.Name -notin @('Version','RESELLER','Type','Package','InstallDate','PackageInstallDate','MagicCode','MagicTime','UserName','Company')){throw 'Unexpected registration field.'}
    $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
    $key=$machine.OpenSubKey("SOFTWARE\NetSarang\$($entry.App)\8")
    try{
        if(!$key -or ($entry.Value | ConvertTo-Json -Compress) -ne ($key.GetValue($entry.Name) | ConvertTo-Json -Compress)){throw 'Original registration value differs.'}
    }finally{if($key){$key.Dispose()};$machine.Dispose()}
}
$launcher=Get-Content -LiteralPath (Join-Path $root 'portable.ps1') -Raw
if($launcher -match '(?i)-Verb\s+RunAs|register-personal|HKLM:|Restore-Journal'){throw 'Legacy/admin launcher selected.'}
if((Get-FileHash -LiteralPath ($root+'.zip')).Hash.ToLowerInvariant() -ne (Get-Content -LiteralPath ($root+'.zip.sha256') -Raw).Split(' ')[0]){throw 'ZIP checksum mismatch.'}
if($RunProbe){
    if(Test-Path 'HKLM:\SOFTWARE\WOW6432Node\NetSarang\Probe'){throw 'Machine probe key already exists; use an isolated environment.'}
    # $PSHOME\powershell.exe does not exist on a PowerShell 7 host; the probe targets Windows PowerShell 5.1.
    $ps51=Join-Path ([Environment]::GetFolderPath('Windows')) 'system32\WindowsPowerShell\v1.0\powershell.exe'
    if(!(Test-Path -LiteralPath $ps51)){throw 'Windows PowerShell 5.1 is required for the -SelfTest probe.'}
    $realKey='HKLM:\SOFTWARE\WOW6432Node\NetSarang\Xftp\8'
    $realBefore=(Get-ItemProperty $realKey -ErrorAction SilentlyContinue).Path
    & $ps51 -NoProfile -File (Join-Path $root 'portable.ps1') -SelfTest
    if($LASTEXITCODE){throw 'Parent/child, portable Xftp/Xshell path routing probe failed.'}
    if((Get-ItemProperty $realKey -ErrorAction SilentlyContinue).Path -ne $realBefore){throw 'Real HKLM Xftp Path was modified by the probe.'}
    if(Test-Path 'HKLM:\SOFTWARE\WOW6432Node\NetSarang\Probe'){throw 'Unexpected machine probe key.'}
}
Write-Output "PASS: $($manifest.Files.Count) manifest files; ZIP/staging hashes; rootless layout; native exe launchers only; original executables; sanitized profiles; original registration; parent/child isolation and portable Xftp path routing; no admin launcher."
