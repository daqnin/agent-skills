param([Parameter(Mandatory)][string]$Compiler,[Parameter(Mandatory)][string]$OutputDirectory,[string]$GuiSubsystemFlag='-Wl,-subsystem=windows')
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Choose a fresh compiler output directory.'}
$compilerPath=(Resolve-Path -LiteralPath $Compiler).Path
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$output=(Resolve-Path -LiteralPath $OutputDirectory).Path
& $compilerPath -shared -DBRIDGE_DLL (Join-Path $PSScriptRoot 'registry-bridge.c') -o (Join-Path $output 'registry-bridge.dll') -ladvapi32 -luser32
if($LASTEXITCODE){throw 'Bridge compilation failed.'}
& $compilerPath (Join-Path $PSScriptRoot 'registry-bridge.c') -o (Join-Path $output 'registry-runner.exe') -ladvapi32 -luser32
if($LASTEXITCODE){throw 'Runner compilation failed.'}
& $compilerPath (Join-Path $PSScriptRoot 'registry-probe.c') -o (Join-Path $output 'registry-probe.exe') -ladvapi32
if($LASTEXITCODE){throw 'Probe compilation failed.'}
& $compilerPath $GuiSubsystemFlag (Join-Path $PSScriptRoot 'portable-launcher.c') -o (Join-Path $output 'portable-launcher.exe') -luser32
if($LASTEXITCODE){throw 'GUI launcher compilation failed.'}
& $compilerPath (Join-Path $PSScriptRoot 'xftp-path-probe.c') -o (Join-Path $output 'xftp-path-probe.exe') -ladvapi32
if($LASTEXITCODE){throw 'Xftp path probe compilation failed.'}
foreach($name in @('registry-bridge.dll','registry-runner.exe','registry-probe.exe','portable-launcher.exe','xftp-path-probe.exe')){
    $bytes=[IO.File]::ReadAllBytes((Join-Path $output $name))
    $pe=[BitConverter]::ToInt32($bytes,60)
    if([BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x14c){throw 'Compiler must target Windows x86.'}
    if($name -eq 'portable-launcher.exe' -and [BitConverter]::ToUInt16($bytes,$pe+24+68) -ne 2){throw 'Launcher must use the GUI subsystem; a console window would flash on double-click.'}
}
Write-Output "Compiled x86 bridge, runner, isolation probe, GUI launcher and Xftp path probe: $output"
