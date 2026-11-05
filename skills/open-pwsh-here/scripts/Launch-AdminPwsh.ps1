<#
Launch-AdminPwsh.ps1

Legacy-mode helper. Invoked by the "在终端中打开（管理员）" Explorer verb only
when Windows Terminal is unavailable. It receives the absolute pwsh.exe path
and the target directory (already suffixed with "\."), then starts an elevated
pwsh.exe session in that directory. In WindowsTerminal mode the verb instead
launches wt.exe with an "elevate": true profile and this helper is not used.

-DryRun prints the child command line as JSON instead of elevating. The verifier
uses this to check the whole launch chain without triggering UAC.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)] [string] $PwshPath,
    [Parameter(Mandatory = $true, Position = 1)] [string] $Directory,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PwshPath -PathType Leaf)) {
    throw "pwsh.exe not found: $PwshPath"
}

# Start-Process joins ArgumentList entries with spaces. Quote the directory
# exactly once; the "\." suffix guarantees no trailing backslash sits directly
# before the closing quote, so the Windows command-line parser keeps it intact.
$childArgs = @('-NoExit', '-WorkingDirectory', ('"{0}"' -f $Directory))
$childCommandLine = $childArgs -join ' '

if ($DryRun) {
    [pscustomobject]@{
        PwshPath         = $PwshPath
        Directory        = $Directory
        Verb             = 'RunAs'
        ChildCommandLine = $childCommandLine
    } | ConvertTo-Json -Compress
    return
}

Start-Process -FilePath $PwshPath -Verb RunAs -ArgumentList $childCommandLine
