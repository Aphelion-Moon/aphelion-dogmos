[CmdletBinding()]
param(
	[ValidateRange(1, 1800)][int]$TimeoutSeconds = 300,
	[string]$DmPath = 'dm.exe',
	[string]$DreamDaemonPath = 'dreamdaemon.exe',
	[string]$DogmosRepository = (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'aphelion-dogmos'),
	[switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$gameRepository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runtimeLog = Join-Path $gameRepository 'data\logs\dogmos_boot_probe\runtime.log'
$panicLog = Join-Path $gameRepository 'dogmos_panic.log'
$handle = $null
$serviceProcessIds = @()
$exitCode = 1

try {
	& (Join-Path $PSScriptRoot 'sync_contract.ps1') -DogmosRepository $DogmosRepository -VerifyOnly
	if ($LASTEXITCODE -ne 0) {
		throw 'Dogmos contract verification failed.'
	}
	if (-not $SkipCompile) {
		# CBT must be defined, as the supported build (BUILD.cmd) does. Without it MAP_SWITCH()
		# selects its map-editor branch and every WHEN_COMPILE() block is dropped from the .dmb,
		# which still compiles cleanly and still boots - but leaves a game whose clients cannot
		# load assets. A probe that builds without it validates something the server never runs,
		# and leaves that broken .dmb on disk for the next launch to pick up.
		$compile = Invoke-DogmosProcess -Executable $DmPath -Arguments @('-DCBT', 'tgstation.dme') `
			-WorkingDirectory $gameRepository -TimeoutSeconds $TimeoutSeconds
		$compile.Output -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Host $_ }
		if ($compile.TimedOut -or $compile.ExitCode -ne 0 -or $compile.Output -notmatch 'tgstation\.dmb - 0 errors') {
			throw 'Dream Maker compile failed before the boot probe.'
		}
		if ($compile.Output -match 'Building with Dream Maker is no longer supported') {
			throw 'Compile did not define CBT; the resulting .dmb would omit WHEN_COMPILE blocks.'
		}
	}

	Remove-DogmosScratchPaths -Paths @((Split-Path -Parent $runtimeLog), $panicLog)
	$arguments = Get-DogmosDreamDaemonArguments -DmbPath 'tgstation.dmb' -Port 1337 `
		-AdditionalArguments @('-close', '-verbose', '-params', 'log-directory=dogmos_boot_probe')
	$handle = Start-DogmosProcess -Executable $DreamDaemonPath -Arguments $arguments -WorkingDirectory $gameRepository
	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
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
		Start-Sleep -Milliseconds 250
	}

	if (-not $initialized) {
		$state = if ($handle.Process.HasExited) { "DreamDaemon exited with $($handle.Process.ExitCode)" } else { 'initialization timed out' }
		throw "Dogmos two-process boot failed: $state; dogmosd descendants=$($serviceProcessIds.Count)."
	}
	$logText = Read-DogmosFileShared -Path $runtimeLog
	$runtimeSignatures = @(Get-DogmosRuntimeSignatures -LogText $logText)
	if ($runtimeSignatures.Count -ne 0) {
		throw "Dogmos boot produced $($runtimeSignatures.Count) runtime error signature(s): $($runtimeSignatures -join '; ')"
	}
	if (Test-Path -LiteralPath $panicLog -PathType Leaf) {
		if ((Get-Item -LiteralPath $panicLog).Length -gt 0) {
			throw 'Dogmos wrote a panic log during the boot probe.'
		}
	}
	Write-Host "Dogmos initialized with DreamDaemon PID $($handle.ProcessId) and dogmosd PID $($serviceProcessIds[0])." -ForegroundColor Green
	$exitCode = 0
} finally {
	if ($null -ne $handle) {
		Stop-DogmosProcess -Handle $handle -Force | Out-Null
	}
	$orphanIds = @($serviceProcessIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
	if ($orphanIds.Count -ne 0) {
		foreach ($orphanId in $orphanIds) {
			Stop-DogmosOwnedProcessTree -ProcessId $orphanId
		}
		$exitCode = 1
		Write-Error "dogmosd did not exit with DreamDaemon: $($orphanIds -join ', ')" -ErrorAction Continue
	}
}

exit $exitCode

