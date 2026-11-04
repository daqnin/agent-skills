param([switch]$CheckOnly, [switch]$Ensure)
$ErrorActionPreference='Stop'
try {
    $entries=@(Import-Clixml -LiteralPath (Join-Path $PSScriptRoot 'Data\registration.clixml'))
    $missing=$false
    $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
    try {
        foreach ($app in @('Xshell','Xftp')) {
            $values=@($entries | Where-Object App -eq $app)
            if (($values | Where-Object Name -eq 'Type').Value -ne 'Personal') { throw 'Only original Personal registrations are supported.' }
            $path=Join-Path $PSScriptRoot "App\$app 8"
            $key=$machine.OpenSubKey("SOFTWARE\NetSarang\$app\8")
            try {
                if ($key) {
                    $registeredPath=[string]$key.GetValue('Path')
                    $samePath=$registeredPath.TrimEnd('\') -eq $path.TrimEnd('\')
                    $version=($values | Where-Object Name -eq 'Version').Value
                    if ($key.GetValue('Type') -ne 'Personal' -or $key.GetValue('Version') -ne $version -or !$samePath) {
                        if (($CheckOnly -or $Ensure) -and $key.GetValue('Type') -eq 'Personal' -and $key.GetValue('Version') -eq $version -and $registeredPath -and (Test-Path -LiteralPath (Join-Path $registeredPath "$app.exe"))) {
                            Write-Output "$app uses existing local Personal registration; clean-PC portability not verified."
                            continue
                        }
                        throw "$app has a different existing registration. It was not changed. Use the vendor's registration or an isolated PC."
                    }
                    Write-Output "$app registration already matches."
                    continue
                }
            } finally { if ($key) { $key.Dispose() } }
            $missing=$true
            if ($CheckOnly) { throw 'Missing machine registration. Start a Portable launcher to register automatically, or run Register-Personal.cmd.' }
            if (!(Test-Path -LiteralPath (Join-Path $path "$app.exe"))) { throw 'Missing portable application.' }
            # Only restore original, explicitly named vendor values; never generate licensing data.
        }
        if (!$CheckOnly) {
            if ($Ensure -and !$missing) { return }
            $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                $arguments='-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Ensure'
                $winPs51=Join-Path ([Environment]::GetFolderPath('Windows')) 'system32\WindowsPowerShell\v1.0\powershell.exe'
                $elevated=Start-Process -FilePath $winPs51 -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
                if ($elevated.ExitCode -ne 0) { throw 'Product registration failed. Run Register-Personal.cmd to see details.' }
                return
            }
            foreach ($app in @('Xshell','Xftp')) {
                $existing=$machine.OpenSubKey("SOFTWARE\NetSarang\$app\8")
                if ($existing) { $existing.Dispose(); continue }
                $key=$machine.CreateSubKey("SOFTWARE\NetSarang\$app\8")
                try {
                    foreach ($entry in @($entries | Where-Object App -eq $app)) {
                        if ($entry.Name -notin @('Version','RESELLER','Type','Package','InstallDate','PackageInstallDate','MagicCode','MagicTime','UserName','Company')) { throw 'Unexpected registration field.' }
                        $kind=[Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],$entry.Kind)
                        $key.SetValue($entry.Name,$entry.Value,$kind)
                    }
                    $key.SetValue('Path',(Join-Path $PSScriptRoot "App\$app 8"))
                } finally { $key.Dispose() }
            }
            Write-Output 'Original Personal registration restored. No application binaries or license checks modified.'
        }
    } finally { $machine.Dispose() }
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
