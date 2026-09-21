#Requires -Version 5.1
<#
.SYNOPSIS
Read-only 250 ms process sampling for one existing RIFT run.
.DESCRIPTION
Start during compilation. Discovers only DreamDaemon and dogmosd identities reported
by this run's event stream; never launches, changes, or stops those processes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunDirectory,
    [ValidateRange(1, 7200)][int]$TimeoutSeconds = 2400
)
$ErrorActionPreference = 'Stop'
$runRoot = (Resolve-Path -LiteralPath $RunDirectory).Path
$eventPath = Join-Path $runRoot 'events.ndjson'
$outputPath = Join-Path $runRoot 'processes-250ms.csv'
$metadataPath = Join-Path $runRoot 'processes-250ms.json'
if (Test-Path -LiteralPath $metadataPath) { throw 'Sampling metadata already exists.' }
$metadata = [ordered]@{
    requested_interval_ms = 250
    started_utc = [DateTime]::UtcNow.ToString('o')
    finished_utc = $null
    status = 'running'
    targets = @()
    errors = @()
    limits = @('Attachment follows RIFT process discovery; initial allocation may precede the first sample.',
        'Intervals include scheduler delay; use recorded timestamps to assess coverage.',
        'This sampler does not inspect address-space regions or native allocations.')
}
$reader = $null
$writer = $null
$targets = @{}
$pendingLine = ''
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    $stream = [IO.File]::Open($outputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $writer = [IO.StreamWriter]::new($stream)
    $writer.WriteLine('utc,role,pid,start_utc,private_bytes,working_set_bytes,virtual_bytes,cpu_seconds')
    $eventStream = [IO.File]::Open($eventPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    $reader = [IO.StreamReader]::new($eventStream)
    while ($true) {
        $iteration = [Diagnostics.Stopwatch]::StartNew()
        $pendingLine += $reader.ReadToEnd()
        $lines = $pendingLine.Split([char]10)
        $pendingLine = $lines[-1]
        for ($index = 0; $index -lt $lines.Length - 1; $index++) {
            if ([string]::IsNullOrWhiteSpace($lines[$index])) { continue }
            $eventRecord = $lines[$index] | ConvertFrom-Json
            foreach ($sample in $eventRecord.data.resource_samples) {
                if ($sample.role -notin @('dreamdaemon', 'dogmosd')) { continue }
                if (-not $sample.creationTime) { continue }
                # PowerShell 7 may deserialize JSON dates; avoid a culture-sensitive string round trip.
                $expected = ([DateTimeOffset]$sample.creationTime).UtcDateTime
                $identity = '{0}:{1}' -f $sample.pid, $expected.Ticks
                if ($targets.ContainsKey($identity)) { continue }
                try {
                    $process = Get-Process -Id $sample.pid -ErrorAction Stop
                    $start = $process.StartTime.ToUniversalTime()
                    if ($process.ProcessName -ine $sample.role -or [Math]::Abs(($start - $expected).TotalMilliseconds) -gt 1) {
                        $process.Dispose()
                        continue
                    }
                    $entry = [ordered]@{ role = $sample.role; pid = $sample.pid; start_utc = $start.ToString('o');
                        first_sample_utc = $null; last_sample_utc = $null; sample_count = 0; maximum_gap_ms = 0 }
                    $metadata.targets += $entry
                    $targets[$identity] = @{ process = $process; start_ticks = $start.Ticks; entry = $entry; previous = $null }
                } catch [Microsoft.PowerShell.Commands.ProcessCommandException] { }
            }
        }
        foreach ($target in $targets.Values) {
            $process = $target.process
            try {
                $process.Refresh()
                if ($process.HasExited -or $process.StartTime.ToUniversalTime().Ticks -ne $target.start_ticks) { continue }
                $now = [DateTime]::UtcNow
                $entry = $target.entry
                $writer.WriteLine(('{0},{1},{2},{3},{4},{5},{6},{7}' -f $now.ToString('o'), $entry.role,
                    $entry.pid, $entry.start_utc, $process.PrivateMemorySize64, $process.WorkingSet64,
                    $process.VirtualMemorySize64, $process.TotalProcessorTime.TotalSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)))
                if ($null -eq $entry.first_sample_utc) { $entry.first_sample_utc = $now.ToString('o') }
                if ($null -ne $target.previous) { $entry.maximum_gap_ms = [Math]::Max($entry.maximum_gap_ms, ($now - $target.previous).TotalMilliseconds) }
                $target.previous = $now
                $entry.last_sample_utc = $now.ToString('o')
                $entry.sample_count++
            } catch [InvalidOperationException] { }
        }
        $writer.Flush()
        if (Test-Path -LiteralPath (Join-Path $runRoot 'summary.json')) { $metadata.status = 'run_finished'; break }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { $metadata.status = 'timed_out'; break }
        Start-Sleep -Milliseconds ([Math]::Max(1, 250 - [int]$iteration.ElapsedMilliseconds))
    }
} catch {
    $metadata.status = 'failed'
    $metadata.errors += $_.Exception.Message
    throw
} finally {
    if ($null -ne $reader) { $reader.Dispose() }
    if ($null -ne $writer) { $writer.Dispose() }
    foreach ($target in $targets.Values) { $target.process.Dispose() }
    $metadata.finished_utc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json -Depth 8))
}
if ($metadata.status -ne 'run_finished') { throw "Sampling ended: $($metadata.status)" }
Write-Output ($metadata | ConvertTo-Json -Depth 8)
