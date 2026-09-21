[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GameRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$ResumePrepared,
    [string]$DmPath = 'C:\Program Files (x86)\BYOND\bin\dm.exe',
    [string]$DreamDaemonPath = 'C:\Program Files (x86)\BYOND\bin\dreamdaemon.exe'
)
$ErrorActionPreference = 'Stop'
$game = (Resolve-Path -LiteralPath $GameRoot).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $ResumePrepared) {
    if (Test-Path -LiteralPath $output) { throw 'Select a fresh output directory.' }
    New-Item -ItemType Directory -Path $output | Out-Null
}
. (Join-Path $game 'tools/dogmos/_common.ps1')
$fixture = (Resolve-Path (Join-Path $PSScriptRoot '../../docs/performance/workloads/fusion_canister_storm.dm')).Path.Replace('\', '/')
$scratch = Join-Path $game ('.fusion-profile-' + [Guid]::NewGuid().ToString('N'))
$handle = $null
$samples = [Collections.Generic.List[object]]::new()
$outcome = [ordered]@{ status = 'preparing'; diagnostic_only = $true; natural_exit = $false; isolation = 'fresh data; empty config; no copied saves; no SQL or outbound configuration'; canisters = 120 }
try {
    if (-not $ResumePrepared) {
        & python -B (Join-Path $game 'tools/dogmos/verify_contract.py') verify-installed --root $game
        if ($LASTEXITCODE -ne 0) { throw 'Installed native contract failed.' }
        Copy-Item -LiteralPath $fixture -Destination (Join-Path $output 'fusion_canister_storm.dm')
        $fixtureHash = (Get-FileHash -LiteralPath $fixture).Hash.ToLowerInvariant()
        $damageFixture = Join-Path (Split-Path $fixture) 'fusion_damage_regressions.dm'
        Copy-Item -LiteralPath $damageFixture -Destination $output
        $outcome.damage_fixture_sha256 = (Get-FileHash -LiteralPath $damageFixture).Hash.ToLowerInvariant()
        $dme = [IO.File]::ReadAllText((Join-Path $game 'tgstation.dme'))
        [IO.File]::WriteAllText(($scratch + '.dme'), ($dme + "`n#include `"$fixture`"`n"))
        Write-Output 'Compiling the focused full-MetaStation diagnostic.'
        $compile = Invoke-DogmosProcess -Executable $DmPath -Arguments @('-DCBT', '-DDEBUG', '-DAUTOSTART_GAME', ($scratch + '.dme')) -WorkingDirectory $game -TimeoutSeconds 600
        [IO.File]::WriteAllText((Join-Path $output 'compile.log'), $compile.Output)
        if ($compile.TimedOut -or $compile.ExitCode -ne 0 -or $compile.Output -notmatch '0 errors, 0 warnings') { throw 'Diagnostic compile failed; inspect compile.log.' }
        if ((Get-FileHash -LiteralPath $fixture).Hash.ToLowerInvariant() -ne $fixtureHash) { throw 'Fixture changed during compilation.' }
        if ((Get-FileHash -LiteralPath $damageFixture).Hash.ToLowerInvariant() -ne $outcome.damage_fixture_sha256) { throw 'Damage fixture changed during compilation.' }
        & bun (Join-Path $PSScriptRoot 'stage_fusion_profile.ts') $game $output ($scratch + '.dmb') ($scratch + '.rsc')
        if ($LASTEXITCODE -ne 0) { throw 'Isolated deployment failed.' }
    } else {
        $previous = Get-Content -LiteralPath (Join-Path $output 'manifest.json') -Raw | ConvertFrom-Json
        if ($previous.PSObject.Properties['pid']) { throw 'Cannot resume a deployment that already launched.' }
        foreach ($entry in $previous.hashes.PSObject.Properties) {
            $actual = (Get-FileHash -LiteralPath (Join-Path $output ('workspace/' + $entry.Name))).Hash.ToLowerInvariant()
            if ($actual -ne $entry.Value) { throw 'Prepared artifact changed.' }
        }
        if ((Get-FileHash -LiteralPath $fixture).Hash.ToLowerInvariant() -ne $previous.fixture_sha256) { throw 'Prepared fixture changed.' }
        $damageFixture = Join-Path (Split-Path $fixture) 'fusion_damage_regressions.dm'
        if ((Get-FileHash -LiteralPath $damageFixture).Hash.ToLowerInvariant() -ne $previous.damage_fixture_sha256) { throw 'Prepared damage fixture changed.' }
        $outcome.damage_fixture_sha256 = $previous.damage_fixture_sha256
        Copy-Item -LiteralPath (Join-Path $output 'manifest.json') -Destination (Join-Path $output 'prelaunch-failure.json')
    }
    $workspace = Join-Path $output 'workspace'
    $outcome.hashes = @{}
    foreach ($name in @('tgstation.dmb', 'tgstation.rsc', 'dogmos.dll')) { $outcome.hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $workspace $name)).Hash.ToLowerInvariant() }
    $outcome.fixture_sha256 = (Get-FileHash -LiteralPath $fixture).Hash.ToLowerInvariant()
    $outcome.game_revision = (& git -C $game rev-parse HEAD).Trim()
    $outcome.native_contract = Get-Content -LiteralPath (Join-Path $game 'dogmos.lock.json') -Raw | ConvertFrom-Json
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $arguments = Get-DogmosDreamDaemonArguments -DmbPath 'tgstation.dmb' -Port $port -AdditionalArguments @('-close', '-verbose', '-params', 'log-directory=rift')
    $handle = Start-DogmosProcess -Executable $DreamDaemonPath -Arguments $arguments -WorkingDirectory $workspace
    $outcome.pid = $handle.ProcessId
    $outcome.creation_time_utc = $handle.Process.StartTime.ToUniversalTime().ToString('o')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $outcome.status = 'running'
    $outcome | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'manifest.json')
    Write-Output "Profiling owned DreamDaemon PID $($handle.ProcessId); 120 ruptures, 300 seconds of phase observation, 900-second total wall limit."
    $shutdownObservedAt = $null
    while (-not $handle.Process.HasExited) {
        $handle.Process.Refresh()
        if ($handle.Process.HasExited) { break }
        $samples.Add([pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); elapsed_seconds = $clock.Elapsed.TotalSeconds; private_bytes = $handle.Process.PrivateMemorySize64; virtual_bytes = $handle.Process.VirtualMemorySize64; working_set_bytes = $handle.Process.WorkingSet64; cpu_seconds = $handle.Process.TotalProcessorTime.TotalSeconds })
        if ($handle.Process.PrivateMemorySize64 -gt 3400MB) { throw 'Diagnostic private-memory guard exceeded (3400 MiB).' }
        if ($clock.Elapsed.TotalSeconds -gt 900) { throw 'Diagnostic exceeded 900-second wall limit.' }
        if (Test-Path -LiteralPath (Join-Path $workspace 'data/logs/rift/fusion-shutdown-complete.json')) {
            if ($null -eq $shutdownObservedAt) { $shutdownObservedAt = $clock.Elapsed.TotalSeconds }
            if ($clock.Elapsed.TotalSeconds - $shutdownObservedAt -gt 30) { throw 'Native shutdown completed, but DreamDaemon did not exit within 30 seconds.' }
        }
        Start-Sleep -Milliseconds 500
    }
    $complete = Join-Path $workspace 'data/logs/rift/fusion-complete.json'
    if (-not (Test-Path -LiteralPath $complete)) { throw 'Missing workload completion.' }
    # Windows DreamDaemon can return a nonzero code after a successful del(world).
    # Require executed workload/shutdown markers and logs; retain the raw code below.
    $outcome.native_shutdown = Get-Content -LiteralPath (Join-Path $workspace 'data/logs/rift/fusion-shutdown-complete.json') -Raw | ConvertFrom-Json
    if (-not $outcome.native_shutdown.native_shutdown_complete) { throw 'Native shutdown did not complete.' }
    $outcome.natural_exit = $true
    $outcome.damage_regressions = Get-Content -LiteralPath (Join-Path $workspace 'data/logs/rift/fusion-damage-regressions.json') -Raw | ConvertFrom-Json
    if (-not $outcome.damage_regressions.passed) { throw 'Damage regressions did not pass.' }
    foreach ($phase in @('baseline', 'wave1', 'wave2', 'recovery')) {
        foreach ($kind in @('profile', 'native')) {
            $artifact = Join-Path $workspace "data/logs/rift/fusion-$kind-$phase.json"
            if (-not (Test-Path -LiteralPath $artifact)) { throw "Missing $kind for $phase." }
            $null = Get-Content -LiteralPath $artifact -Raw | ConvertFrom-Json
        }
    }
    if (Test-Path -LiteralPath (Join-Path $workspace 'dogmos_panic.log')) { throw 'Native panic log found.' }
    $outcome.workload = Get-Content -LiteralPath $complete -Raw | ConvertFrom-Json
    $runtime = Read-DogmosFileShared -Path (Join-Path $workspace 'data/logs/rift/runtime.log')
    $outcome.runtime_signatures = @(Get-DogmosRuntimeSignatures -LogText $runtime)
    if ($outcome.runtime_signatures.Count) { throw 'Workload completed with runtime errors; inspect evidence.' }
    $outcome.status = 'completed'
} catch {
    $outcome.status = 'failed'
    $outcome.failure = $_.Exception.Message
    throw
} finally {
    if ($null -ne $handle) {
        $stopped = Stop-DogmosProcess -Handle $handle -Force
        [IO.File]::WriteAllText((Join-Path $output 'daemon.log'), $stopped.Output)
        $outcome.exit_code = $stopped.ExitCode
    }
    $samples | Export-Csv -LiteralPath (Join-Path $output 'process-samples.csv') -NoTypeInformation
    $outcome | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'manifest.json')
    foreach ($extension in @('.dme', '.dmb', '.rsc')) {
        if (Test-Path -LiteralPath ($scratch + $extension)) { Remove-Item -LiteralPath ($scratch + $extension) }
    }
}
