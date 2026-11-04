param([ValidateSet('Xshell','Xftp')][string]$App = 'Xshell', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$vendor = 'Software\NetSarang'
$journal = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexPortable\NetSarang8'
if ($SelfTest) {
    $vendor = 'Software\CodexPortableTest-' + [guid]::NewGuid().ToString('N')
    $journal = Join-Path $env:TEMP ('NetSarangTest-' + [guid]::NewGuid().ToString('N'))
}
$regPath = 'HKCU:\' + $vendor
$mutex = New-Object Threading.Mutex($false, 'Local\CodexPortable-NetSarang8')
$locked = $false
function Invoke-Reg([string]$arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\reg.exe'
    $info.Arguments = $arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $code = $process.ExitCode
    $process.Dispose()
    if ($code -ne 0) { throw 'Registry backup or recovery failed; preserve the local recovery journal.' }
}
function Restore-Journal {
    $stateFile = Join-Path $journal 'state.json'
    if (!(Test-Path -LiteralPath $stateFile)) { return }
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($state.Vendor -ne $vendor) { throw 'Recovery registry path mismatch.' }
    if ($state.Existed -and !(Test-Path -LiteralPath (Join-Path $journal 'original.reg'))) { throw 'Missing original registry backup.' }
    if (Test-Path -LiteralPath $regPath) { Remove-Item -LiteralPath $regPath -Recurse -Force }
    if ($state.Existed) {
        Invoke-Reg ('import "' + (Join-Path $journal 'original.reg') + '"')
    }
    Remove-Item -LiteralPath $stateFile -Force
    $backup = Join-Path $journal 'original.reg'
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
}
function Begin-Transaction {
    New-Item -ItemType Directory -Path $journal -Force | Out-Null
    $exists = Test-Path -LiteralPath $regPath
    if ($exists) {
        Invoke-Reg ('export "HKCU\' + $vendor + '" "' + (Join-Path $journal 'original.reg') + '" /y')
    }
    @{Vendor=$vendor; Existed=$exists} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $journal 'state.json') -Encoding UTF8
    if ($exists) { Remove-Item -LiteralPath $regPath -Recurse -Force }
}
function Get-RunningApps {
    @(Get-CimInstance Win32_Process | Where-Object Name -match '^(Xshell|XshellCore|Xftp|Xftpcl|Xagent|Xtransport|NsRDP|RealCmdModule|SessionConverter|SessionConverterXftp)\.exe$')
}
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Another portable NetSarang launcher is active. Close it before switching applications.' }
    if (!$SelfTest -and (Get-RunningApps).Count) { throw 'Close all Xshell, Xftp and NetSarang helper processes before starting the portable copy.' }
    Restore-Journal
    if ($SelfTest) {
        New-Item -Path $regPath -Force | Out-Null
        New-ItemProperty -Path $regPath -Name Sentinel -Value 'original' | Out-Null
        Begin-Transaction
        New-Item -Path $regPath -Force | Out-Null
        New-ItemProperty -Path $regPath -Name Sentinel -Value 'temporary' | Out-Null
        Restore-Journal
        if ((Get-ItemPropertyValue -LiteralPath $regPath -Name Sentinel) -ne 'original') { throw 'Existing-key recovery failed.' }
        Remove-Item -LiteralPath $regPath -Recurse
        Begin-Transaction
        New-Item -Path $regPath -Force | Out-Null
        Restore-Journal
        if (Test-Path -LiteralPath $regPath) { throw 'Absent-key recovery failed.' }
        Write-Output 'PASS: existing and absent registry recovery; isolated test keys only.'
        return
    }
    $settingsFile = Join-Path $root 'Data\settings.clixml'
    $registrationArgs='-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'register-personal.ps1') + '" -Ensure'
    $winPs51=Join-Path ([Environment]::GetFolderPath('Windows')) 'system32\WindowsPowerShell\v1.0\powershell.exe'
    $registration=Start-Process -FilePath $winPs51 -ArgumentList $registrationArgs -WindowStyle Hidden -Wait -PassThru
    if ($registration.ExitCode -ne 0) { throw 'Product registration failed or Windows elevation was cancelled. Run Register-Personal.cmd for details. Existing different registrations are not overwritten.' }
    $settings = @(Import-Clixml -LiteralPath $settingsFile)
    Begin-Transaction
    try {
        foreach ($entry in $settings) {
            if ($entry.Path -notmatch '^(Xshell|Xftp)\\8(\\(Language|MainWindow|TermColors|PageSetup))?$') { throw 'Unsupported settings registry path.' }
            $path = Join-Path $regPath $entry.Path
            New-Item -Path $path -Force | Out-Null
            New-ItemProperty -Path $path -Name $entry.Name -Value $entry.Value -PropertyType $entry.Kind -Force | Out-Null
        }
        $userData = Join-Path $regPath 'Common\8\UserData'
        New-Item -Path $userData -Force | Out-Null
        New-ItemProperty -Path $userData -Name UserDataPath -Value (Join-Path $root 'Data\8') -Force | Out-Null
        $import = Join-Path $regPath 'Common\8\Import'
        New-Item -Path $import -Force | Out-Null
        foreach ($name in @('Xshell','Xftp')) { New-ItemProperty -Path $import -Name $name -Value 1 -PropertyType DWord -Force | Out-Null }
        $exe = Join-Path $root ('App\' + $App + ' 8\' + $App + '.exe')
        $process = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru
        $process.WaitForExit()
        while ((Get-RunningApps).Count) { Start-Sleep -Milliseconds 500 }
        foreach ($entry in $settings) {
            $key = Get-Item -LiteralPath (Join-Path $regPath $entry.Path) -ErrorAction SilentlyContinue
            if ($key -and $entry.Name -in $key.GetValueNames()) { $entry.Value = $key.GetValue($entry.Name) }
        }
        $settings | Export-Clixml -LiteralPath $settingsFile -Encoding UTF8
    } finally { Restore-Journal }
} catch {
    if ($SelfTest) { throw }
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'NetSarang Portable') | Out-Null
    exit 1
} finally {
    if ($SelfTest) {
        Restore-Journal
        if (Test-Path -LiteralPath $regPath) { Remove-Item -LiteralPath $regPath -Recurse -Force }
        if (Test-Path -LiteralPath $journal) { Get-ChildItem -LiteralPath $journal -File | Remove-Item -Force; Remove-Item -LiteralPath $journal }
    }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
