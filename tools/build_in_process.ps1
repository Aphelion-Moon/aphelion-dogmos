[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidateSet('i686-pc-windows-msvc', 'i686-unknown-linux-gnu')][string]$TargetTriple = 'i686-pc-windows-msvc',
    [string]$Python = 'python',
    [string]$LibClangPath = $env:LIBCLANG_PATH
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $root ('target/in-process-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
}
$previousClang = $env:LIBCLANG_PATH
try {
    $env:LIBCLANG_PATH = $LibClangPath
    & $Python -B (Join-Path $PSScriptRoot 'build_in_process.py') --target $TargetTriple --output $OutputDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Native bundle build failed.' }
} finally { $env:LIBCLANG_PATH = $previousClang }
