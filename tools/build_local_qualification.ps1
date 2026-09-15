[CmdletBinding()]
param(
	[string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
	[string] $OutputDirectory,
	[string] $LinuxDistribution = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'
$resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$targetRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot 'target'))
if (-not $OutputDirectory) {
	$OutputDirectory = Join-Path $targetRoot ('local-qualification-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
}
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($targetRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw 'Local qualification output must be inside this repository target directory.'
}
if (Test-Path -LiteralPath $output) {
	throw 'Local qualification output already exists; preserve it and select a new directory.'
}
if ((Get-Content -LiteralPath (Join-Path $resolvedRoot 'rust-toolchain.toml') -Raw) -notmatch 'channel\s*=\s*"1\.98\.0"') {
	throw 'Revalidate this builder against the changed Rust toolchain before building.'
}
[System.IO.Directory]::CreateDirectory($output) | Out-Null
$logs = Join-Path $output 'logs'
[System.IO.Directory]::CreateDirectory($logs) | Out-Null
$bundle = Join-Path $output 'bundle'
[System.IO.Directory]::CreateDirectory((Join-Path $bundle 'windows')) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $bundle 'linux')) | Out-Null

function Invoke-QualificationStep {
	param([string] $Name, [string] $Program, [string[]] $Arguments)
	Write-Output "Dogmos local qualification: $Name"
	$stepLog = Join-Path $logs ($Name + '.log')
	& $Program @Arguments *> $stepLog
	if ($LASTEXITCODE -ne 0) {
		Get-Content -LiteralPath $stepLog -Tail 30 | Write-Output
		throw "$Name failed with exit code $LASTEXITCODE; see $stepLog"
	}
}

$previousRevision = $env:DOGMOS_SOURCE_REVISION
$previousFingerprint = $env:DOGMOS_FEATURE_FINGERPRINT
Push-Location -LiteralPath $resolvedRoot
try {
	Invoke-QualificationStep 'rust-version' 'rustc' @('+1.98.0', '--version', '--verbose')
	# Generate before capture: generated DM exports are themselves hashed inputs.
	Push-Location -LiteralPath (Join-Path $resolvedRoot 'crates/dogmos-byond')
	try {
		Invoke-QualificationStep 'bindings' 'cargo' @('+1.98.0', 'run', '--quiet', '--locked', '--target', 'i686-pc-windows-msvc', '-p', 'dogmos-byond', '--example', 'generate_bindings')
	} finally {
		Pop-Location
	}
	$snapshot = Join-Path $bundle 'dogmos-source-snapshot.json'
	$identityJson = & python -B tools/dogmos_source_snapshot.py capture --repository-root $resolvedRoot --snapshot $snapshot
	if ($LASTEXITCODE -ne 0) { throw 'Local source snapshot capture failed.' }
	$identity = ($identityJson | Out-String) | ConvertFrom-Json
	if ($identity.source_revision -notmatch '^[0-9a-f]{40}$' -or $identity.feature_fingerprint -notmatch '^[0-9a-f]{64}$') {
		throw 'Local source snapshot returned an invalid compiled identity.'
	}
	$env:DOGMOS_SOURCE_REVISION = $identity.source_revision
	$env:DOGMOS_FEATURE_FINGERPRINT = $identity.feature_fingerprint
	Invoke-QualificationStep 'windows-shim' 'cargo' @('+1.98.0', 'build', '--release', '--locked', '--target', 'i686-pc-windows-msvc', '-p', 'dogmos-byond')
	Invoke-QualificationStep 'windows-service' 'cargo' @('+1.98.0', 'build', '--release', '--locked', '--target', 'x86_64-pc-windows-msvc', '-p', 'dogmos-server', '--bin', 'dogmosd')
	# Only validated hexadecimal identities enter shell source; all filesystem paths
	# stay positional arguments. WSL builds use the same checkout and locked cache.
	$linuxBuild = 'set -euo pipefail' + "`n" +
		'export DOGMOS_SOURCE_REVISION=' + $identity.source_revision + "`n" +
		'export DOGMOS_FEATURE_FINGERPRINT=' + $identity.feature_fingerprint + "`n" +
		'rustc +1.98.0 --version --verbose' + "`n" +
		'cargo +1.98.0 build --release --locked --offline --target i686-unknown-linux-gnu -p dogmos-byond' + "`n" +
		'cargo +1.98.0 build --release --locked --offline --target x86_64-unknown-linux-gnu -p dogmos-server --bin dogmosd'
	Invoke-QualificationStep 'linux-pair' 'wsl.exe' @('-d', $LinuxDistribution, '--cd', $resolvedRoot, '--exec', 'bash', '-lc', $linuxBuild)
	$linuxBundle = & wsl.exe -d $LinuxDistribution --exec wslpath -a $bundle.Replace('\', '/')
	if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the local bundle inside WSL.' }
	$linuxSymbols = @'
set -euo pipefail
objcopy --only-keep-debug target/i686-unknown-linux-gnu/release/libdogmos_byond.so "$1/linux/libdogmos.so.debug"
objcopy --strip-debug target/i686-unknown-linux-gnu/release/libdogmos_byond.so "$1/linux/libdogmos.so"
objcopy --only-keep-debug target/x86_64-unknown-linux-gnu/release/dogmosd "$1/linux/dogmosd.debug"
objcopy --strip-debug target/x86_64-unknown-linux-gnu/release/dogmosd "$1/linux/dogmosd"
chmod +x "$1/linux/dogmosd"
'@
	Invoke-QualificationStep 'linux-symbols' 'wsl.exe' @('-d', $LinuxDistribution, '--cd', $resolvedRoot, '--exec', 'bash', '-lc', $linuxSymbols, 'dogmos-symbols', $linuxBundle.Trim())
	Copy-Item -LiteralPath target/i686-pc-windows-msvc/release/dogmos_byond.dll -Destination (Join-Path $bundle 'windows/dogmos.dll')
	Copy-Item -LiteralPath target/i686-pc-windows-msvc/release/dogmos_byond.pdb -Destination (Join-Path $bundle 'windows/dogmos.pdb')
	Copy-Item -LiteralPath target/x86_64-pc-windows-msvc/release/dogmosd.exe -Destination (Join-Path $bundle 'windows/dogmosd.exe')
	Copy-Item -LiteralPath target/x86_64-pc-windows-msvc/release/dogmosd.pdb -Destination (Join-Path $bundle 'windows/dogmosd.pdb')
	Copy-Item -LiteralPath crates/dogmos-byond/bindings.dm -Destination (Join-Path $bundle 'dogmos_bindings.dm')
	Invoke-QualificationStep 'source-after-build' 'python' @('-B', 'tools/dogmos_source_snapshot.py', 'verify', '--repository-root', $resolvedRoot, '--snapshot', $snapshot)
	$manifest = Join-Path $bundle 'dogmos-release-manifest.json'
	$generate = @('-B', 'tools/dogmos_contract.py', 'generate', '--repository-root', $resolvedRoot,
		'--local-snapshot', $snapshot, '--bindings', (Join-Path $bundle 'dogmos_bindings.dm'), '--output', $manifest)
	foreach ($inputPair in @(
		@('windows-shim', 'windows/dogmos.dll'), @('windows-shim-symbols', 'windows/dogmos.pdb'),
		@('windows-service', 'windows/dogmosd.exe'), @('windows-service-symbols', 'windows/dogmosd.pdb'),
		@('linux-shim', 'linux/libdogmos.so'), @('linux-shim-symbols', 'linux/libdogmos.so.debug'),
		@('linux-service', 'linux/dogmosd'), @('linux-service-symbols', 'linux/dogmosd.debug')
	)) {
		$generate += ('--' + $inputPair[0])
		$generate += (Join-Path $bundle $inputPair[1])
	}
	Invoke-QualificationStep 'manifest' 'python' $generate
	Invoke-QualificationStep 'bundle-verification' 'python' @('-B', 'tools/dogmos_contract.py', 'verify', '--manifest', $manifest, '--bundle-root', $bundle, '--allow-local-qualification')
	Write-Output "Verified local qualification bundle: $bundle"
	Write-Output 'This command does not install or publish artifacts. Use the maintained synchronizer with -AllowLocalQualification for a local development/test checkout.'
} finally {
	$env:DOGMOS_SOURCE_REVISION = $previousRevision
	$env:DOGMOS_FEATURE_FINGERPRINT = $previousFingerprint
	Pop-Location
}
