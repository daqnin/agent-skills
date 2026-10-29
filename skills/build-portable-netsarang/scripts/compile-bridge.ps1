param([Parameter(Mandatory)][string]$Compiler,[Parameter(Mandatory)][string]$OutputDirectory)
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
foreach($name in @('registry-bridge.dll','registry-runner.exe','registry-probe.exe')){
    $bytes=[IO.File]::ReadAllBytes((Join-Path $output $name))
    $pe=[BitConverter]::ToInt32($bytes,60)
    if([BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x14c){throw 'Compiler must target Windows x86.'}
}
Write-Output "Compiled x86 bridge, runner and probe: $output"
