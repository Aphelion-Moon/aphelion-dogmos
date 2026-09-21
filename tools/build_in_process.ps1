[CmdletBinding()]
param(
	[string] $OutputDirectory,
	[string] $Cargo = 'cargo',
	[string] $Python = 'python',
	[string] $LibClangPath = $env:LIBCLANG_PATH
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$target = Join-Path $root 'target'
if (-not $OutputDirectory) {
	$OutputDirectory = Join-Path $target ('in-process-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($target + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
	throw 'Build output must be a new directory under this repository target directory.'
}
if (Test-Path -LiteralPath $output) { throw 'Preserve the previous build; select a new output directory.' }
if ((Get-Content (Join-Path $root 'rust-toolchain.toml') -Raw) -notmatch 'channel\s*=\s*"1\.98\.0"') {
	throw 'Update the in-process builder for the changed toolchain pin.'
}
$null = New-Item -ItemType Directory -Path $output
$features = @('aphelion_reactions', 'katmos', 'katmos_slow_decompression', 'superconductivity', 'turf_processing')
$snapshot = Join-Path $output 'dogmos-source-snapshot.json'
$previousIdentity = $env:DOGMOS_SOURCE_SHA256
$previousClang = $env:LIBCLANG_PATH
$previousTarget = $env:CARGO_TARGET_DIR
Push-Location -LiteralPath $root
try {
	$identityJson = & $Python -B tools/dogmos_source_snapshot.py capture --repository-root $root --snapshot $snapshot
	if ($LASTEXITCODE -ne 0) { throw "Source capture failed: $identityJson" }
	$identity = ($identityJson | Out-String) | ConvertFrom-Json
	if ($identity.source_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid source snapshot identity.' }
	$env:DOGMOS_SOURCE_SHA256 = $identity.source_sha256
	$env:LIBCLANG_PATH = $LibClangPath
	$env:CARGO_TARGET_DIR = $target
	$arguments = @('+1.98.0', 'build', '-p', 'dogmos', '--lib', '--example', 'generate_bindings', '--release', '--locked', '--target', 'i686-pc-windows-msvc', '--no-default-features', '--features', ($features -join ','))
	& $Cargo @arguments *> (Join-Path $output 'build.log')
	if ($LASTEXITCODE -ne 0) {
		Get-Content (Join-Path $output 'build.log') -Tail 35
		throw 'In-process compilation failed.'
	}
	$release = Join-Path $target 'i686-pc-windows-msvc/release'
	Push-Location -LiteralPath $output
	try {
		& (Join-Path $release 'examples/generate_bindings.exe')
		if ($LASTEXITCODE -ne 0) { throw 'In-process binding generation failed.' }
	} finally { Pop-Location }
	Copy-Item -LiteralPath (Join-Path $release 'dogmos.dll') -Destination $output
	Copy-Item -LiteralPath (Join-Path $release 'dogmos.pdb') -Destination $output
	Move-Item -LiteralPath (Join-Path $output 'bindings.dm') -Destination (Join-Path $output 'dogmos_bindings.dm')
	& $Python -B tools/dogmos_source_snapshot.py verify --repository-root $root --snapshot $snapshot
	if ($LASTEXITCODE -ne 0) { throw 'Source changed during compilation; rebuild from a stable snapshot.' }
	$artifacts = @{}
	foreach ($name in @('dogmos.dll', 'dogmos.pdb', 'dogmos_bindings.dm', 'dogmos-source-snapshot.json')) {
		$artifacts[$name] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $output $name)).Hash.ToLowerInvariant()
	}
	$manifest = [ordered]@{
		schema_version = 1
		kind = 'unqualified-in-process-playtest'
		backend = 'in-process'
		target = 'i686-pc-windows-msvc'
		toolchain = '1.98.0'
		source_revision = $identity.source_revision
		source_sha256 = $identity.source_sha256
		features = $features
		cargo_arguments = $arguments
		artifacts = $artifacts
		tests_run = $false
		runtime_qualified = $false
	}
	[IO.File]::WriteAllText((Join-Path $output 'dogmos-playtest.json'), (($manifest | ConvertTo-Json -Depth 5) + "`n"))
	Write-Output "Built unqualified in-process candidate: $output"
} finally {
	$env:DOGMOS_SOURCE_SHA256 = $previousIdentity
	$env:LIBCLANG_PATH = $previousClang
	$env:CARGO_TARGET_DIR = $previousTarget
	Pop-Location
}
