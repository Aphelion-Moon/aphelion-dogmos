[CmdletBinding()]
param(
    [string] $CargoPath = "cargo",
    [ValidateSet('i686-pc-windows-msvc', 'i686-unknown-linux-gnu')]
    [string] $Target = "i686-pc-windows-msvc",
    [string] $Python = "python"
)

$ErrorActionPreference = "Stop"
& $Python -B (Join-Path $PSScriptRoot 'check_feature_matrix.py') --cargo $CargoPath --target $Target
exit $LASTEXITCODE
