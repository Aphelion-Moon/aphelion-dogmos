[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string] $DogmosRepository,
	[string] $DestinationRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
	[string] $ManifestPath,
	[string] $BundleRoot,
	[switch] $AllowLocalQualification,
	[switch] $VerifyOnly
)

$ErrorActionPreference = 'Stop'

function Assert-NativeExitCode {
	param([string] $Description)
	if ($LASTEXITCODE -ne 0) {
		throw "$Description failed with exit code $LASTEXITCODE"
	}
}

function Set-AtomicFile {
	param(
		[string] $Source,
		[string] $Destination,
		[string] $Token
	)
	$parent = Split-Path -Parent $Destination
	[System.IO.Directory]::CreateDirectory($parent) | Out-Null
	$temporary = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Destination) + ".$Token.tmp")
	[System.IO.File]::Copy($Source, $temporary, $true)
	if ([System.IO.File]::Exists($Destination)) {
		$replaceBackup = "$temporary.replace-backup"
		[System.IO.File]::Replace($temporary, $Destination, $replaceBackup, $true)
		[System.IO.File]::Delete($replaceBackup)
	} else {
		[System.IO.File]::Move($temporary, $Destination)
	}
}

$resolvedDogmos = (Resolve-Path -LiteralPath $DogmosRepository).Path
$resolvedDestination = (Resolve-Path -LiteralPath $DestinationRoot).Path
$verifier = Join-Path $PSScriptRoot 'verify_contract.py'
if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) {
	throw "Dogmos contract verifier is missing: $verifier"
}
if (-not $ManifestPath) {
	$ManifestPath = Join-Path $resolvedDogmos 'dogmos-release-manifest.json'
}
if (-not $BundleRoot) {
	$BundleRoot = Join-Path $resolvedDogmos 'release-bundle'
}
$resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
$resolvedBundle = (Resolve-Path -LiteralPath $BundleRoot).Path

$qualificationArguments = @()
if ($AllowLocalQualification) {
	$qualificationArguments += '--allow-local-qualification'
}
& python $verifier validate-release --manifest $resolvedManifest --bundle-root $resolvedBundle @qualificationArguments
Assert-NativeExitCode 'Dogmos release contract validation'
$manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
if ($manifest.source_revision -notmatch '^[0-9a-f]{40}$') {
	throw 'Dogmos release contract does not contain an exact lowercase source revision'
}
$head = (& git -C $resolvedDogmos rev-parse --verify HEAD 2>&1 | Out-String).Trim()
Assert-NativeExitCode 'Dogmos source revision lookup'
if ($head -cne $manifest.source_revision) {
	throw "Dogmos source revision mismatch: contract=$($manifest.source_revision) repository=$head"
}
if ($manifest.PSObject.Properties.Name -contains 'qualification') {
	& python $verifier verify-local-source --manifest $resolvedManifest --bundle-root $resolvedBundle --repository-root $resolvedDogmos
	Assert-NativeExitCode 'Dogmos local qualification source verification'
} else {
	$status = @(& git -C $resolvedDogmos status --porcelain=v1 --untracked-files=all)
	Assert-NativeExitCode 'Dogmos source cleanliness check'
	if ($status.Count -gt 0) {
		throw 'Dogmos source repository is dirty; contract sync requires an exact clean revision'
	}
}

if ($VerifyOnly) {
	$installedLock = Join-Path $resolvedDestination 'dogmos.lock.json'
	if (-not (Test-Path -LiteralPath $installedLock -PathType Leaf)) {
		throw "Installed Dogmos lock is missing: $installedLock"
	}
	if (-not [System.Linq.Enumerable]::SequenceEqual(
		[byte[]][System.IO.File]::ReadAllBytes($resolvedManifest),
		[byte[]][System.IO.File]::ReadAllBytes($installedLock)
	)) {
		throw 'Installed dogmos.lock.json does not match the selected release contract'
	}
	& python $verifier verify-installed --root $resolvedDestination
	Assert-NativeExitCode 'Installed Dogmos contract verification'
	Write-Output 'Dogmos contract is current.'
	return
}

$token = [guid]::NewGuid().ToString('N')
$stage = Join-Path $resolvedDestination ".dogmos-sync-$token"
$stageRoot = [System.IO.Path]::GetFullPath($stage)
if (-not $stageRoot.StartsWith($resolvedDestination + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw "Unsafe Dogmos staging path: $stageRoot"
}
[System.IO.Directory]::CreateDirectory($stageRoot) | Out-Null

try {
	$artifactByPair = @{}
	foreach ($artifact in $manifest.artifacts) {
		$artifactByPair["$($artifact.platform)/$($artifact.role)"] = $artifact
	}
	$stagedFiles = [ordered]@{
		'dogmos.dll' = Join-Path $resolvedBundle $artifactByPair['windows/shim'].file
		'dogmosd.exe' = Join-Path $resolvedBundle $artifactByPair['windows/service'].file
		'libdogmos.so' = Join-Path $resolvedBundle $artifactByPair['linux/shim'].file
		'dogmosd' = Join-Path $resolvedBundle $artifactByPair['linux/service'].file
		'code\__DEFINES\dogmos_bindings.dm' = Join-Path $resolvedBundle $manifest.bindings.file
		'dogmos.lock.json' = $resolvedManifest
	}
	foreach ($relativePath in $stagedFiles.Keys) {
		$destination = Join-Path $stageRoot $relativePath
		[System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
		[System.IO.File]::Copy($stagedFiles[$relativePath], $destination, $true)
	}
	$contractDefines = Join-Path $stageRoot 'code\__DEFINES\dogmos_contract.dm'
	& python $verifier render-defines --manifest $resolvedManifest --bundle-root $resolvedBundle --output $contractDefines @qualificationArguments
	Assert-NativeExitCode 'Dogmos contract define generation'
	& python $verifier verify-installed --root $stageRoot
	Assert-NativeExitCode 'Staged Dogmos contract verification'

	$installOrder = @(
		'dogmos.dll',
		'dogmosd.exe',
		'libdogmos.so',
		'dogmosd',
		'code\__DEFINES\dogmos_bindings.dm',
		'code\__DEFINES\dogmos_contract.dm',
		'dogmos.lock.json'
	)
	$backupRoot = Join-Path $stageRoot 'backup'
	if ($manifest.PSObject.Properties.Name -contains 'qualification') {
		& python $verifier verify-local-source --manifest $resolvedManifest --bundle-root $resolvedBundle --repository-root $resolvedDogmos
		Assert-NativeExitCode 'Dogmos local source recheck before install'
	}
	$existing = @{}
	foreach ($relativePath in $installOrder) {
		$destination = Join-Path $resolvedDestination $relativePath
		$existing[$relativePath] = Test-Path -LiteralPath $destination -PathType Leaf
		if ($existing[$relativePath]) {
			$backup = Join-Path $backupRoot $relativePath
			[System.IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
			[System.IO.File]::Copy($destination, $backup, $true)
		}
	}
	try {
		foreach ($relativePath in $installOrder) {
			Set-AtomicFile -Source (Join-Path $stageRoot $relativePath) -Destination (Join-Path $resolvedDestination $relativePath) -Token $token
		}
		& python $verifier verify-installed --root $resolvedDestination
		Assert-NativeExitCode 'Installed Dogmos contract verification'
	} catch {
		foreach ($relativePath in $installOrder) {
			$destination = Join-Path $resolvedDestination $relativePath
			if ($existing[$relativePath]) {
				Set-AtomicFile -Source (Join-Path $backupRoot $relativePath) -Destination $destination -Token $token
			} elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
				Remove-Item -LiteralPath $destination -Force
			}
		}
		throw
	}
	Write-Output 'Dogmos contract synchronized and verified.'
} finally {
	if (Test-Path -LiteralPath $stageRoot -PathType Container) {
		Remove-Item -LiteralPath $stageRoot -Recurse -Force
	}
}
