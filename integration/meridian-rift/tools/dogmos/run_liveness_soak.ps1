[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$ShimPath,
	[Parameter(Mandatory = $true)][string]$ServicePath,
	[ValidateSet('RuntimeStation', 'MetaStation')][string]$Map = 'RuntimeStation',
	[ValidateRange(30, 1800)][int]$SoakSeconds = 300,
	[ValidateRange(60, 1800)][int]$InitializationTimeoutSeconds = 600,
	[string]$DmPath = 'dm.exe',
	[string]$DreamDaemonPath = 'dreamdaemon.exe'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$gameRepository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installedShim = Join-Path $gameRepository 'dogmos.dll'
$installedService = Join-Path $gameRepository 'dogmosd.exe'
$nextMapPath = Join-Path $gameRepository 'data\next_map.json'
$mapSelector = switch ($Map) {
	'RuntimeStation' { '_maps\runtimestation.json' }
	'MetaStation' { '_maps\metastation.json' }
}
$logName = 'dogmos_liveness_soak_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
$logDirectory = Join-Path $gameRepository "data\logs\$logName"
$runtimeLog = Join-Path $logDirectory 'runtime.log'
$originalShim = [System.IO.File]::ReadAllBytes($installedShim)
$originalService = [System.IO.File]::ReadAllBytes($installedService)
$originalNextMapExists = Test-Path -LiteralPath $nextMapPath -PathType Leaf
$originalNextMap = if ($originalNextMapExists) {
	[System.IO.File]::ReadAllBytes($nextMapPath)
} else {
	$null
}
$handle = $null
$serviceProcessIds = @()
$failureMessage = $null

try {
	Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ShimPath).Path -Destination $installedShim -Force
	Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ServicePath).Path -Destination $installedService -Force
	Copy-Item -LiteralPath (Join-Path $gameRepository $mapSelector) -Destination $nextMapPath -Force

	Write-Host "Compiling $Map for the Dogmos liveness soak."
	# -DCBT as the supported build and test_compile_check.ps1 both do. Without it MAP_SWITCH()
	# takes its map-editor branch and WHEN_COMPILE() blocks vanish from the .dmb, producing a
	# game that boots but whose clients cannot load assets.
	$compile = Invoke-DogmosProcess -Executable $DmPath -Arguments @('-DCBT', 'tgstation.dme') `
		-WorkingDirectory $gameRepository -TimeoutSeconds 300
	$compile.Output -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 12 | ForEach-Object { Write-Host $_ }
	if ($compile.TimedOut -or $compile.ExitCode -ne 0 -or $compile.Output -notmatch 'tgstation\.dmb - 0 errors') {
		throw 'Dream Maker compile failed before the liveness soak.'
	}

	$arguments = Get-DogmosDreamDaemonArguments -DmbPath 'tgstation.dmb' -Port 1338 `
		-AdditionalArguments @('-close', '-verbose', '-params', "log-directory=$logName")
	$handle = Start-DogmosProcess -Executable $DreamDaemonPath -Arguments $arguments -WorkingDirectory $gameRepository
	$started = Get-Date
	Write-Host "DreamDaemon PID $($handle.ProcessId) is initializing $Map."
	$deadline = $started.AddSeconds($InitializationTimeoutSeconds)
	$initialized = $false
	while ((Get-Date) -lt $deadline) {
		$handle.Process.Refresh()
		if ($handle.Process.HasExited) {
			break
		}
		$serviceProcessIds = @(Get-DogmosProcessTreeIds -ProcessId $handle.ProcessId | Where-Object {
			$process = Get-Process -Id $_ -ErrorAction SilentlyContinue
			$process -and $process.ProcessName -eq 'dogmosd'
		})
		if ((Test-DogmosLogMarker -Path $runtimeLog -Marker 'Initializations complete within') -and $serviceProcessIds.Count -eq 1) {
			$initialized = $true
			break
		}
		Start-Sleep -Seconds 2
	}
	if (-not $initialized) {
		throw "Dogmos liveness soak failed to initialize; dogmosd descendants=$($serviceProcessIds.Count)."
	}

	$initializationSeconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
	Write-Host "Initialization completed in $initializationSeconds seconds; dogmosd PID $($serviceProcessIds[0])."
	$dreamDaemonPrivateMax = 0L
	$servicePrivateMax = 0L
	$sampleCount = [Math]::Ceiling($SoakSeconds / 5)
	for ($sample = 1; $sample -le $sampleCount; $sample++) {
		Start-Sleep -Seconds 5
		$handle.Process.Refresh()
		if ($handle.Process.HasExited) {
			throw "DreamDaemon exited during the liveness soak with code $($handle.Process.ExitCode)."
		}
		$dreamDaemon = Get-Process -Id $handle.ProcessId -ErrorAction Stop
		$service = Get-Process -Id $serviceProcessIds[0] -ErrorAction Stop
		$dreamDaemonPrivateMax = [Math]::Max($dreamDaemonPrivateMax, $dreamDaemon.PrivateMemorySize64)
		$servicePrivateMax = [Math]::Max($servicePrivateMax, $service.PrivateMemorySize64)
		if ($sample % 6 -eq 0) {
			$partialLog = Read-DogmosFileShared -Path $runtimeLog
			$stageConflicts = ([regex]::Matches($partialLog, 'StageConflict')).Count
			$malformedResponses = ([regex]::Matches($partialLog, 'malformed stage response')).Count
			Write-Host "Soak $($sample * 5)s: StageConflict=$stageConflicts malformed=$malformedResponses DreamDaemonPrivate=$($dreamDaemon.PrivateMemorySize64) dogmosdPrivate=$($service.PrivateMemorySize64)"
		}
	}

	$logText = Read-DogmosFileShared -Path $runtimeLog
	$runtimeSignatures = @(Get-DogmosRuntimeSignatures -LogText $logText)
	$stageConflicts = ([regex]::Matches($logText, 'StageConflict')).Count
	$malformedResponses = ([regex]::Matches($logText, 'malformed stage response')).Count
	$pendingMismatches = ([regex]::Matches($logText, 'remains pending')).Count
	$lifecycleRejections = ([regex]::Matches($logText, 'lifecycle.*rejected', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
	Write-Host "DOGMOS LIVENESS SOAK: map=$Map initialization_seconds=$initializationSeconds runtimes=$($runtimeSignatures.Count) stage_conflicts=$stageConflicts malformed=$malformedResponses pending_mismatches=$pendingMismatches lifecycle_rejections=$lifecycleRejections dreamdaemon_private_max=$dreamDaemonPrivateMax dogmosd_private_max=$servicePrivateMax log=$logDirectory"
	if ($runtimeSignatures.Count -ne 0 -or $stageConflicts -ne 0 -or $malformedResponses -ne 0 -or $pendingMismatches -ne 0 -or $lifecycleRejections -ne 0) {
		$failureMessage = 'Dogmos liveness soak detected a runtime or rejected-stage signature.'
	}
} catch {
	$failureMessage = $_.Exception.Message
} finally {
	if ($null -ne $handle) {
		Stop-DogmosProcess -Handle $handle -Force | Out-Null
	}
	foreach ($serviceProcessId in $serviceProcessIds) {
		if (Get-Process -Id $serviceProcessId -ErrorAction SilentlyContinue) {
			Stop-DogmosOwnedProcessTree -ProcessId $serviceProcessId
		}
	}
	Write-DogmosFileBytesWithRetry -Path $installedShim -Bytes $originalShim
	Write-DogmosFileBytesWithRetry -Path $installedService -Bytes $originalService
	if ($originalNextMapExists) {
		Write-DogmosFileBytesWithRetry -Path $nextMapPath -Bytes $originalNextMap
	} elseif (Test-Path -LiteralPath $nextMapPath) {
		Remove-Item -LiteralPath $nextMapPath -Force
	}
}

if ($failureMessage) {
	throw $failureMessage
}
