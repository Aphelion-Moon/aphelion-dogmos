[CmdletBinding()]
param(
	[ValidateRange(1, 1800)][int]$TimeoutSeconds = 600,
	[string]$DmPath = 'dm.exe'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$gameRepository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scratchDme = Join-Path $gameRepository 'tgstation.dogmos-tests.dme'
$scratchDmb = [System.IO.Path]::ChangeExtension($scratchDme, '.dmb')
$scratchRsc = [System.IO.Path]::ChangeExtension($scratchDme, '.rsc')

try {
	Copy-Item -LiteralPath (Join-Path $gameRepository 'tgstation.dme') -Destination $scratchDme -Force
	$startedAt = Get-Date
	$result = Invoke-DogmosProcess -Executable $DmPath `
		-Arguments @('-DCBT', '-DCIBUILDING', (Split-Path -Leaf $scratchDme)) `
		-WorkingDirectory $gameRepository -TimeoutSeconds $TimeoutSeconds
	$result.Output -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Host $_ }
	$summary = @($result.Output -split "`r?`n" | Where-Object { $_ -match 'errors,' } | Select-Object -Last 1)
	if ($result.TimedOut) {
		throw "Dream Maker timed out after $TimeoutSeconds seconds."
	}
	if ($result.ExitCode -ne 0 -or $summary -notmatch '^\s*tgstation\.dogmos-tests\.dmb - 0 errors') {
		throw "Dream Maker test compile failed with exit code $($result.ExitCode)."
	}
	if (-not (Test-DogmosArtifactFresh -Path $scratchDmb -StartedAt $startedAt)) {
		throw 'Dream Maker did not produce a fresh test DMB.'
	}
	Write-Host 'Dogmos CIBUILDING compile passed with a fresh DMB.' -ForegroundColor Green
} finally {
	Remove-DogmosScratchPaths -Paths @($scratchDme, $scratchDmb, $scratchRsc)
}

