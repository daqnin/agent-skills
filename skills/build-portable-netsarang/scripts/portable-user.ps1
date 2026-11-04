param([ValidateSet('Xshell','Xftp')][string]$App='Xshell',[switch]$SelfTest)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$digest=[Security.Cryptography.SHA256]::Create()
$id=([BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))).Replace('-','').Substring(0,16)
$digest.Dispose()
$shadow="Software\CodexPortable\NetSarang8\$id"
$mutex=New-Object Threading.Mutex($false,"Local\CodexPortable-NetSarang8-$id")
$locked=$false
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(!$locked){throw 'This portable package is already running. Close its applications before switching.'}
    $userRoot="HKCU:\$shadow\User\Software\NetSarang"
    $machineRoot="HKCU:\$shadow\Machine\Software\NetSarang"
    if(!(Test-Path -LiteralPath $userRoot)){
        $saved=Join-Path $root 'Data\registry.clixml'
        $entries=if(Test-Path -LiteralPath $saved){@(Import-Clixml -LiteralPath $saved)}else{@(Import-Clixml -LiteralPath (Join-Path $root 'Data\settings.clixml'))}
        foreach($entry in $entries){
            if($entry.Path -notmatch '^(Xshell|Xftp|Common)(\\|$)'){throw 'Invalid user registry path'}
            $p=Join-Path $userRoot $entry.Path
            if(!(Test-Path -LiteralPath $p)){New-Item -Path $p -Force | Out-Null}
            New-ItemProperty -Path $p -Name $entry.Name -Value $entry.Value -PropertyType $entry.Kind -Force | Out-Null
        }
    }
    foreach($entry in @(Import-Clixml -LiteralPath (Join-Path $root 'Data\registration.clixml'))){
        if($entry.App -notin @('Xshell','Xftp') -or $entry.Name -notin @('Version','RESELLER','Type','Package','InstallDate','PackageInstallDate','MagicCode','MagicTime','UserName','Company')){throw 'Invalid product registration'}
        $p=Join-Path $machineRoot ($entry.App+'\8')
        if(!(Test-Path -LiteralPath $p)){New-Item -Path $p -Force | Out-Null}
        New-ItemProperty -Path $p -Name $entry.Name -Value $entry.Value -PropertyType $entry.Kind -Force | Out-Null
    }
    foreach($name in @('Xshell','Xftp')){
        New-ItemProperty -Path (Join-Path $machineRoot "$name\8") -Name Path -Value (Join-Path $root "App\$name 8") -Force | Out-Null
    }
    # Keep the vendor's original core-process preference. Forcing single-core
    # made Xshell 8 build 8.0.0.27 fail the viewer handshake
    # ("Create Child Frame Result : 0" / "Failed to initialize viewer instance").
    $coreMode=@(Import-Clixml -LiteralPath (Join-Path $root 'Data\settings.clixml')) | Where-Object { $_.Name -eq 'MultiCoreProcess' } | Select-Object -First 1
    if($coreMode){
        New-ItemProperty -Path (Join-Path $userRoot 'Xshell\8') -Name MultiCoreProcess -Value $coreMode.Value -PropertyType $coreMode.Kind -Force | Out-Null
    }
    $p=Join-Path $userRoot 'Common\8\UserData'
    New-Item -Path $p -Force | Out-Null
    New-ItemProperty -Path $p -Name UserDataPath -Value (Join-Path $root 'Data\8') -Force | Out-Null
    $env:NS_PORTABLE_REGISTRY=$shadow
    if($SelfTest){
        $probe=Join-Path $root 'Tools\registry-probe.exe'
        if(!(Test-Path -LiteralPath $probe)){throw 'Diagnostic probe not included.'}
        $p=Join-Path $machineRoot 'Probe'
        New-Item -Path $p -Force | Out-Null
        New-ItemProperty -Path $p -Name Sentinel -Value 'user-only' -Force | Out-Null
        & (Join-Path $root 'Tools\registry-runner.exe') $probe
        if($LASTEXITCODE){throw 'Registry isolation probe failed'}
        Remove-Item -LiteralPath $p
        # Xshell locates its built-in Xftp target through these vendor paths.
        $pathProbe=Join-Path $root 'Tools\xftp-path-probe.exe'
        if(!(Test-Path -LiteralPath $pathProbe)){throw 'Xftp path probe not included.'}
        & (Join-Path $root 'Tools\registry-runner.exe') $pathProbe
        if($LASTEXITCODE){throw 'Portable Xftp/Xshell path routing probe failed'}
        return
    }
    $exe=Join-Path $root "App\$App 8\$App.exe"
    if($App -eq 'Xshell'){& (Join-Path $root 'Tools\registry-runner.exe') $exe '-newwin'}
    else{& (Join-Path $root 'Tools\registry-runner.exe') $exe}
    if($LASTEXITCODE){throw "Application exited with code $LASTEXITCODE"}
    # Keep the namespace until all package children are gone; never touch installed processes.
    do {
        $children=@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $root 'App')+'\',[StringComparison]::OrdinalIgnoreCase)})
        if($children.Count){Start-Sleep -Milliseconds 500}
    }while($children.Count)
    $savedEntries=@(foreach($key in @(Get-Item -LiteralPath $userRoot)+@(Get-ChildItem -LiteralPath $userRoot -Recurse)){
        $relative=$key.Name.Substring(('HKEY_CURRENT_USER\'+$shadow+'\User\Software\NetSarang').Length).TrimStart('\')
        if(!$relative){continue}
        foreach($name in $key.GetValueNames()){[pscustomobject]@{Path=$relative;Name=$name;Kind=$key.GetValueKind($name).ToString();Value=$key.GetValue($name)}}
    })
    $savedEntries | Export-Clixml -LiteralPath (Join-Path $root 'Data\registry.clixml') -Encoding UTF8
}catch{
    if($SelfTest){throw}
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'NetSarang Portable') | Out-Null
    exit 1
}finally{
    if($locked){$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
