[CmdletBinding()]
param(
	[switch]$ValidateOnly,
	[string]$WorkloadDirectory,
	[string]$WorkloadPath,
	[string]$OutputDirectory,
	[string]$Revision,
	[string[]]$Features = @(),
	[string]$ByondVersion = '516.1687'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if(-not $WorkloadDirectory) {
	$WorkloadDirectory = Join-Path $PSScriptRoot '..\..\docs\performance\workloads'
}

function Get-Sha256Hex {
	param([Parameter(Mandatory)][string]$Path)

	$stream = [IO.File]::OpenRead($Path)
	try {
		$sha256 = [Security.Cryptography.SHA256]::Create()
		try {
			return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
		} finally {
			$sha256.Dispose()
		}
	} finally {
		$stream.Dispose()
	}
}

function Read-DogmosWorkload {
	param([Parameter(Mandatory)][string]$Path)

	$resolved = (Resolve-Path -LiteralPath $Path).Path
	$document = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
	$required = @('schema_version', 'id', 'seed', 'duration_seconds', 'map', 'driver', 'expected_markers', 'correctness_assertions')
	foreach($field in $required) {
		if($null -eq $document.PSObject.Properties[$field]) {
			throw "Workload '$resolved' is missing '$field'."
		}
	}
	if($document.schema_version -ne 1) { throw "Workload '$resolved' has unsupported schema_version '$($document.schema_version)'." }
	if($document.duration_seconds -le 0) { throw "Workload '$resolved' duration_seconds must be positive." }
	if(-not $document.expected_markers -or -not $document.correctness_assertions) {
		throw "Workload '$resolved' must define markers and correctness assertions."
	}
	$phases = @()
	if($document.id -eq 'runtime_isolation') {
		$names = @('idle', 'machinery', 'breach_fire', 'topology', 'recovery')
		if(-not $document.PSObject.Properties['phases'] -or @($document.phases).Count -ne 5 -or $document.duration_seconds -ne 300) {
			throw 'Runtime isolation requires five contiguous 60-second phases.'
		}
		$phases = @($document.phases)
		for($index = 0; $index -lt $names.Count; $index++) {
			$phase = $phases[$index]
			if($phase.id -cne $names[$index] -or $phase.start_seconds -ne $index * 60 -or $phase.duration_seconds -ne 60) {
				throw "Runtime isolation phase '$($names[$index])' has an invalid order or window."
			}
		}
	}
	[pscustomobject]@{
		id = [string]$document.id
		path = $resolved
		scenario_sha256 = Get-Sha256Hex -Path $resolved
		seed = [long]$document.seed
		duration_seconds = [double]$document.duration_seconds
		map = [string]$document.map
		driver = $document.driver
		phases = $phases
		expected_markers = @($document.expected_markers)
		correctness_assertions = @($document.correctness_assertions)
	}
}

if($ValidateOnly) {
	$directory = (Resolve-Path -LiteralPath $WorkloadDirectory).Path
	$workloads = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
		Read-DogmosWorkload -Path $_.FullName
	})
	if($workloads.Count -eq 0) { throw "No workload JSON files found in '$directory'." }
	ConvertTo-Json -InputObject $workloads -Depth 8 -Compress
	exit 0
}

if(-not $WorkloadPath) { throw '-WorkloadPath is required unless -ValidateOnly is used.' }
if(-not $OutputDirectory) { throw '-OutputDirectory is required for a workload run.' }
if(-not $Revision) { throw '-Revision is required for a workload run.' }

$workload = Read-DogmosWorkload -Path $WorkloadPath
if($workload.id -eq 'runtime_isolation') {
	throw 'Runtime isolation is not executable yet: bind and implement the representative-map fixture and ordered commands before preparing a run.'
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$identity = [ordered]@{
	map = $workload.map
	seed = $workload.seed
	revision = $Revision
	features = @($Features | Sort-Object)
	byond_version = $ByondVersion
	duration_seconds = $workload.duration_seconds
	scenario_sha256 = $workload.scenario_sha256
}
$manifest = [ordered]@{
	schema_version = 1
	workload_id = $workload.id
	identity = $identity
	expected_markers = $workload.expected_markers
	correctness_assertions = $workload.correctness_assertions
	status = 'prepared'
}
$manifestPath = Join-Path $output 'run-manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
ConvertTo-Json -InputObject ([pscustomobject]@{ manifest_path = $manifestPath; identity = $identity }) -Depth 8 -Compress
