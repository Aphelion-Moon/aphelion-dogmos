[CmdletBinding()]
param(
	[string[]]$Focus,
	[ValidateRange(1, 7200)][int]$TimeoutSeconds = 2400,
	[ValidateRange(0, 10000)][int]$MinimumTests = 400,
	[ValidateSet('RuntimeStation', 'MetaStation')][string]$Map = 'RuntimeStation',
	[string]$ShimPath,
	[string]$ServicePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$gameRepository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dmePath = Join-Path $gameRepository 'tgstation.dme'
$focusPath = Join-Path $gameRepository 'code\modules\unit_tests\_zzz_dogmos_focus.dm'
$resultsPath = Join-Path $gameRepository 'data\unit_tests.json'
$nextMapPath = Join-Path $gameRepository 'data\next_map.json'
$runtimeLog = Join-Path $gameRepository 'data\logs\ci\runtime.log'
$cleanMarker = Join-Path $gameRepository 'data\logs\ci\clean_run.lk'
$mapPreviewPath = Join-Path $gameRepository 'icons\obj\fluff\map_previews.dmi'
$originalDme = $null
$originalMapPreview = $null
$originalNextMap = $null
$originalNextMapExists = $false
$originalShim = $null
$originalService = $null

if ($Focus) {
	$Focus = @($Focus | Sort-Object -Unique)
	$invalid = @($Focus | Where-Object { $_ -notmatch '^/[A-Za-z0-9_/]+$' })
	if ($invalid.Count -ne 0) {
		throw "Invalid focused test path(s): $($invalid -join ', ')"
	}
	$MinimumTests = $Focus.Count
}

try {
	if (($ShimPath -and -not $ServicePath) -or ($ServicePath -and -not $ShimPath)) {
		throw '-ShimPath and -ServicePath must be supplied together.'
	}
	if ($ShimPath) {
		$resolvedShim = (Resolve-Path -LiteralPath $ShimPath).Path
		$resolvedService = (Resolve-Path -LiteralPath $ServicePath).Path
		$installedShim = Join-Path $gameRepository 'dogmos.dll'
		$installedService = Join-Path $gameRepository 'dogmosd.exe'
		$originalShim = [System.IO.File]::ReadAllBytes($installedShim)
		$originalService = [System.IO.File]::ReadAllBytes($installedService)
		Copy-Item -LiteralPath $resolvedShim -Destination $installedShim -Force
		Copy-Item -LiteralPath $resolvedService -Destination $installedService -Force
	}
	if ($Focus) {
		$originalDme = [System.IO.File]::ReadAllBytes($dmePath)
		$focusText = (@($Focus | ForEach-Object { "TEST_FOCUS($_)" }) -join "`n") + "`n"
		[System.IO.File]::WriteAllText($focusPath, $focusText, [System.Text.Encoding]::ASCII)
		[System.IO.File]::AppendAllText($dmePath, "`n#include `"code/modules/unit_tests/_zzz_dogmos_focus.dm`"`n", [System.Text.Encoding]::ASCII)
	}
	if (Test-Path -LiteralPath $mapPreviewPath -PathType Leaf) {
		$originalMapPreview = [System.IO.File]::ReadAllBytes($mapPreviewPath)
	}
	if (Test-Path -LiteralPath $nextMapPath -PathType Leaf) {
		$originalNextMapExists = $true
		$originalNextMap = [System.IO.File]::ReadAllBytes($nextMapPath)
	}
	$mapSelector = if ($Focus) {
		switch ($Map) {
			'RuntimeStation' { '_maps\runtimestation.json' }
			'MetaStation' { '_maps\metastation.json' }
		}
	} else {
		'_maps\runtimestation_minimal.json'
	}
	Copy-Item -LiteralPath (Join-Path $gameRepository $mapSelector) -Destination $nextMapPath -Force
	Remove-DogmosScratchPaths -Paths @($resultsPath, $runtimeLog, $cleanMarker, (Join-Path $gameRepository 'dogmos_panic.log'))

	$arguments = @('/d', '/c', 'tools\build\build.bat', 'dm-test', '--define=MINIMAL_CENTCOM', '--define=SKIP_LAVALAND', '--define=SKIP_SPACE_LEVELS')
	$result = Invoke-DogmosProcess -Executable 'cmd.exe' -Arguments $arguments `
		-WorkingDirectory $gameRepository -TimeoutSeconds $TimeoutSeconds
	$result.Output -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 80 | ForEach-Object { Write-Host $_ }
	if ($result.TimedOut) {
		throw "Unit-test run timed out after $TimeoutSeconds seconds."
	}
	if (-not (Test-Path -LiteralPath $resultsPath -PathType Leaf)) {
		throw "Unit-test run produced no fresh $resultsPath."
	}
	$logText = Read-DogmosFileShared -Path $runtimeLog
	if (-not $logText.Contains('Initializations complete within')) {
		throw 'Unit-test runtime log has no initialization-complete marker.'
	}
	$results = Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json
	$tests = @($results.PSObject.Properties)
	if ($tests.Count -lt $MinimumTests) {
		throw "Only $($tests.Count) tests were recorded; expected at least $MinimumTests."
	}
	if ($Focus) {
		$missing = @($Focus | Where-Object { $tests.Name -notcontains $_ })
		if ($missing.Count -ne 0) {
			throw "Focused test paths were not recorded: $($missing -join ', ')"
		}
	}
	$failed = @($tests | Where-Object { $_.Value.status -ne 0 })
	$runtimes = @(Get-DogmosRuntimeSignatures -LogText $logText)
	Write-Host "Recorded $($tests.Count) tests: $($tests.Count - $failed.Count) passed, $($failed.Count) failed, $($runtimes.Count) runtime signatures."
	foreach ($failure in $failed) {
		Write-Host "FAILED $($failure.Name): $($failure.Value.message)" -ForegroundColor Red
	}
	if ($failed.Count -ne 0 -or $runtimes.Count -ne 0) {
		throw "Dogmos unit-test gate failed with $($failed.Count) failed test(s) and $($runtimes.Count) runtime signature(s)."
	}
	Write-Host 'Dogmos DreamDaemon unit-test gate passed.' -ForegroundColor Green
} finally {
	if ($null -ne $originalDme) {
		Write-DogmosFileBytesWithRetry -Path $dmePath -Bytes $originalDme
	}
	Remove-DogmosScratchPaths -Paths @($focusPath)
	if ($null -ne $originalMapPreview) {
		Write-DogmosFileBytesWithRetry -Path $mapPreviewPath -Bytes $originalMapPreview
	}
	if ($null -ne $originalNextMap) {
		Write-DogmosFileBytesWithRetry -Path $nextMapPath -Bytes $originalNextMap
	} elseif (-not $originalNextMapExists) {
		Remove-DogmosScratchPaths -Paths @($nextMapPath)
	}
	if ($null -ne $originalShim) {
		Write-DogmosFileBytesWithRetry -Path (Join-Path $gameRepository 'dogmos.dll') -Bytes $originalShim
	}
	if ($null -ne $originalService) {
		Write-DogmosFileBytesWithRetry -Path (Join-Path $gameRepository 'dogmosd.exe') -Bytes $originalService
	}
}
