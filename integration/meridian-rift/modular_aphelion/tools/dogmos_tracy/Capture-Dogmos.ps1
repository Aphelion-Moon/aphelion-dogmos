#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check', 'ArmNextRound', 'Capture')][string]$Mode = 'Check',
    [Parameter(Mandatory)][string]$GameDirectory,
    [string]$DreamDaemonPath,
    [string]$BundleDirectory,
    [string]$OutputDirectory,
    [string]$ExpectedDreamDaemonPath,
    [string]$NotBeforeUtc,
    [ValidateRange(1, 65535)][int]$ProfilerPort = 8086,
    [ValidateRange(1, 300)][int]$WindowSeconds = 120,
    [ValidateRange(1, 8)][int]$Windows = 5,
    [ValidateRange(16, 4096)][int]$MemoryLimitMB = 1024,
    [ValidateRange(1, 900)][int]$WaitSeconds = 600
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BundleDirectory)) { $BundleDirectory = $PSScriptRoot }
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell for the x64 collector and cross-bitness module verification.' }
$gameRoot = (Resolve-Path -LiteralPath $GameDirectory).Path
$bundleRoot = (Resolve-Path -LiteralPath $BundleDirectory).Path
$manifest = Get-Content -LiteralPath (Join-Path $bundleRoot 'bundle.json') -Raw | ConvertFrom-Json
if ($manifest.schema -ne 1) { throw 'Unsupported capture bundle schema.' }
foreach ($entry in $manifest.files) {
    $file = [IO.Path]::GetFullPath((Join-Path $bundleRoot $entry.path))
    if (-not $file.StartsWith($bundleRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Bundle manifest path escapes its directory.'
    }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.sha256) {
        throw "Capture bundle hash mismatch: $($entry.path)"
    }
}
$hookPath = Join-Path $bundleRoot 'bin/prof.dll'
$installedHook = Join-Path $gameRoot 'prof.dll'
$hookHash = (Get-FileHash -LiteralPath $hookPath -Algorithm SHA256).Hash
$marker = Join-Path $gameRoot 'data/enable_tracy'
if (-not (Test-Path -LiteralPath (Join-Path $gameRoot 'tgstation.dmb'))) {
    throw 'GameDirectory must be the TGS game directory containing tgstation.dmb and its data directory.'
}
# An empty collector session checks its runtime DLLs without connecting to DreamDaemon.
# Do this before arming the hook, which can block game startup waiting for the collector.
$probeInfo = [Diagnostics.ProcessStartInfo]::new()
$probeInfo.FileName = Join-Path $bundleRoot 'bin/meridian-tracy-helper.exe'
$probeInfo.Arguments = '--session'
$probeInfo.UseShellExecute = $false
$probeInfo.CreateNoWindow = $true
$probeInfo.RedirectStandardInput = $true
$probeInfo.RedirectStandardOutput = $true
$probeInfo.RedirectStandardError = $true
$probe = [Diagnostics.Process]::Start($probeInfo)
try {
    $probe.StandardInput.Close()
    if (-not $probe.WaitForExit(5000)) {
        $probe.Kill()
        $probe.WaitForExit()
        throw 'Collector startup check timed out; no profiling marker was created by this invocation.'
    }
    if ($probe.ExitCode -ne 0) {
        throw "Collector startup failed (exit $($probe.ExitCode)). Check the x64 Visual C++ v14 runtime described in README.md before arming profiling."
    }
} finally { $probe.Dispose() }
if ($Mode -eq 'Check') {
    [pscustomobject]@{ BundleVerified = $true; CollectorStarts = $true; HookSHA256 = $hookHash; SupportedBYOND = '516.1685-516.1687';
        InstalledHookMatches = ((Test-Path -LiteralPath $installedHook) -and
            (Get-FileHash -LiteralPath $installedHook -Algorithm SHA256).Hash -eq $hookHash);
        NextRoundArmed = (Test-Path -LiteralPath $marker) }
    return
}
if ($Mode -eq 'ArmNextRound') {
    if ([string]::IsNullOrWhiteSpace($DreamDaemonPath)) { throw 'ArmNextRound requires DreamDaemonPath pointing to the BYOND executable selected in TGS.' }
    $engine = Get-Item -LiteralPath $DreamDaemonPath
    if ($engine.Name -ine 'DreamDaemon.exe' -or $engine.VersionInfo.FileBuildPart -ne 516 -or
        $engine.VersionInfo.FilePrivatePart -notin @(1685, 1686, 1687)) {
        throw 'This hook supports only DreamDaemon 516.1685 through 516.1687. No profiling marker was created.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $gameRoot 'data') -PathType Container)) { throw 'The game data directory is missing.' }
    if (Test-Path -LiteralPath $marker) { throw 'Next-round profiling is already armed.' }
    if (Test-Path -LiteralPath $installedHook) {
        if ((Get-FileHash -LiteralPath $installedHook -Algorithm SHA256).Hash -ne $hookHash) {
            throw 'A different prof.dll is installed. Review and remove it manually while the game is stopped.'
        }
    } else {
        [IO.File]::Copy($hookPath, $installedHook, $false)
    }
    if (Test-Path -LiteralPath $marker) { throw 'Next-round profiling is already armed.' }
    $stream = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    $stream.Dispose()
    Write-Output 'Next round armed. Start Capture in another administrator PowerShell before the normal TGS reboot. This command does not reboot TGS.'
    return
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw 'Capture requires a new OutputDirectory.' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory already exists; each capture must use a new directory.' }
if ($WindowSeconds * $Windows -gt 1500) { throw 'Total requested capture time must not exceed 25 minutes.' }
if (-not (Test-Path -LiteralPath $installedHook) -or
    (Get-FileHash -LiteralPath $installedHook -Algorithm SHA256).Hash -ne $hookHash) {
    throw 'The game does not have this bundle''s verified hook installed.'
}
$null = New-Item -ItemType Directory -Path $outputRoot
$script:sampleWriter = [IO.StreamWriter]::new((Join-Path $outputRoot 'processes.csv'), $false)
$script:sampleWriter.WriteLine('utc,role,pid,start_utc,private_bytes,working_set_bytes,virtual_bytes,cpu_seconds')
$script:targets = @()
$script:requestId = 0
$script:collector = $null
$script:errorRead = $null
$script:nextDiscovery = [DateTime]::MinValue
$script:daemonId = 0
$primaryCaptureError = $null
$run = [ordered]@{ schema = 1; started_utc = [DateTime]::UtcNow.ToString('o'); finished_utc = $null;
    completed = $false; reason = $null; byond = $null; hook_sha256 = $hookHash; windows = @();
    dreamdaemon = $null; cleanup_errors = @(); retained_collector_pid = $null;
    limitations = @('Instrumented run; compare with matched instrumented controls.',
        'Capture windows have attachment gaps; early startup before the first window is not captured.',
        'Process sampling excludes address-space region maps and native per-operation timing.') }

function Sample-Processes {
    if ($script:daemonId -gt 0 -and [DateTime]::UtcNow -ge $script:nextDiscovery) {
        $script:nextDiscovery = [DateTime]::UtcNow.AddSeconds(1)
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $script:daemonId" | Where-Object { $_.Name -ieq 'dogmosd.exe' })
        foreach ($child in $children) {
            if ($script:targets.Id -notcontains [int]$child.ProcessId) {
                $service = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
                if ($null -ne $service) { $script:targets += @{ Id=$service.Id; Role='dogmosd'; StartTicks=$service.StartTime.ToUniversalTime().Ticks } }
            }
        }
    }
    foreach ($target in $script:targets) {
        try {
            $process = Get-Process -Id $target.Id -ErrorAction Stop
            if ($process.StartTime.ToUniversalTime().Ticks -ne $target.StartTicks) { continue }
            $script:sampleWriter.WriteLine(('{0},{1},{2},{3},{4},{5},{6},{7}' -f
                [DateTime]::UtcNow.ToString('o'), $target.Role, $process.Id, $process.StartTime.ToUniversalTime().ToString('o'),
                $process.PrivateMemorySize64, $process.WorkingSet64, $process.VirtualMemorySize64,
                $process.TotalProcessorTime.TotalSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)))
        } catch [Microsoft.PowerShell.Commands.ProcessCommandException] { }
    }
    $script:sampleWriter.Flush()
}

function Invoke-Collector([string]$Command, [hashtable]$Parameters, [int]$TimeoutSeconds) {
    $script:requestId++
    $request = @{ schema_version = 2; id = $script:requestId; command = $Command; params = $Parameters }
    $script:collector.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 8 -Compress))
    $script:collector.StandardInput.Flush()
    $pending = [DogmosCaptureWindows]::ReadLine($script:collector.StandardOutput)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $pending.IsCompleted) {
        Sample-Processes
        if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Collector timed out during $Command." }
        Start-Sleep -Milliseconds 250
    }
    $line = $pending.GetAwaiter().GetResult()
    if ([string]::IsNullOrEmpty($line)) { throw 'Collector closed its response stream.' }
    $response = $line | ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $outputRoot ('response-{0:D3}.json' -f $script:requestId)), $line)
    if ($response.schema_version -ne 2 -or $response.id -ne $script:requestId) { throw 'Collector response identity mismatch.' }
    if (-not $response.ok) { throw "Collector rejected $Command`: $($response.error.code): $($response.error.message)" }
    return $response.result
}

function Get-ProfilerModulePath([int]$ProcessId) {
    # .NET Framework Process.Modules in 64-bit PowerShell 5.1 omits the x86 modules.
    if (-not ('DogmosCaptureWindows' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class DogmosCaptureWindows {
    // Framework redirected pipes can begin an Async read synchronously. Keep reads on workers.
    public static System.Threading.Tasks.Task<string> ReadLine(System.IO.StreamReader reader) {
        return System.Threading.Tasks.Task.Factory.StartNew(() => reader.ReadLine(), System.Threading.CancellationToken.None,
            System.Threading.Tasks.TaskCreationOptions.LongRunning, System.Threading.Tasks.TaskScheduler.Default);
    }
    public static System.Threading.Tasks.Task<string> ReadAll(System.IO.StreamReader reader) {
        return System.Threading.Tasks.Task.Factory.StartNew(() => reader.ReadToEnd(), System.Threading.CancellationToken.None,
            System.Threading.Tasks.TaskCreationOptions.LongRunning, System.Threading.Tasks.TaskScheduler.Default);
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("psapi.dll", SetLastError=true)] static extern bool EnumProcessModulesEx(IntPtr process, [Out] IntPtr[] modules, uint bytes, out uint needed, uint filter);
    [DllImport("psapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetModuleFileNameEx(IntPtr process, IntPtr module, StringBuilder path, uint size);
    public static string Hook(int pid) {
        IntPtr process = OpenProcess(0x410, false, pid);
        if (process == IntPtr.Zero) throw new Win32Exception();
        try {
            IntPtr[] modules = new IntPtr[1024]; uint needed;
            if (!EnumProcessModulesEx(process, modules, (uint)(modules.Length * IntPtr.Size), out needed, 3)) throw new Win32Exception();
            if (needed > modules.Length * IntPtr.Size) throw new InvalidOperationException("Module inventory exceeds capture limit.");
            for (int i=0; i<needed/IntPtr.Size; i++) {
                var path = new StringBuilder(32768);
                if (GetModuleFileNameEx(process, modules[i], path, 32768) == 0) throw new Win32Exception();
                if (System.IO.Path.GetFileName(path.ToString()).Equals("prof.dll", StringComparison.OrdinalIgnoreCase)) return path.ToString();
            }
            return null;
        } finally { CloseHandle(process); }
    }
}
'@
    }
    return [DogmosCaptureWindows]::Hook($ProcessId)
}

try {
    Write-Output "Waiting for this game's DreamDaemon Tracy listener on 127.0.0.1:$ProfilerPort..."
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        $listeners = @(Get-NetTCPConnection -LocalPort $ProfilerPort -State Listen -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 1) { throw 'Multiple profiler listeners found.' }
        if ($listeners.Count -eq 1) {
            if ($listeners[0].LocalAddress -ne '127.0.0.1') { throw 'Profiler must bind only to 127.0.0.1; check TGS inherited UTRACY_BIND_ADDRESS.' }
            $daemon = Get-Process -Id $listeners[0].OwningProcess
            if ($daemon.ProcessName -ne 'DreamDaemon') { throw 'Profiler listener is not owned by DreamDaemon.' }
            $daemonBirth = $daemon.StartTime.ToUniversalTime()
            if ($NotBeforeUtc -and $daemonBirth -lt ([DateTimeOffset]::Parse($NotBeforeUtc)).UtcDateTime) {
                throw 'Profiler listener belongs to a round started before this capture was armed.'
            }
            $daemonIdentity = Get-CimInstance Win32_Process -Filter "ProcessId = $($daemon.Id)"
            if (-not $daemonIdentity.ExecutablePath -or [Math]::Abs(($daemonIdentity.CreationDate.ToUniversalTime() - $daemonBirth).TotalMilliseconds) -gt 1) {
                throw 'DreamDaemon executable and process lifetime could not be verified.'
            }
            if ($ExpectedDreamDaemonPath -and -not [IO.Path]::GetFullPath($daemonIdentity.ExecutablePath).Equals([IO.Path]::GetFullPath($ExpectedDreamDaemonPath), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'DreamDaemon executable differs from the configured TGS engine.'
            }
            $loadedHook = Get-ProfilerModulePath $daemon.Id
            if ([string]::IsNullOrEmpty($loadedHook) -or -not [IO.Path]::GetFullPath($loadedHook).Equals([IO.Path]::GetFullPath($installedHook), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Listener belongs to a different game directory or its hook cannot be verified.'
            }
            $run.dreamdaemon = @{pid=$daemon.Id;start_utc=$daemonBirth.ToString('o');executable=$daemonIdentity.ExecutablePath;sha256=(Get-FileHash -LiteralPath $daemonIdentity.ExecutablePath -Algorithm SHA256).Hash;hook_path=$loadedHook}
            break
        }
        if ($wait.Elapsed.TotalSeconds -gt $WaitSeconds) { throw 'Timed out waiting for the next profiled round.' }
        Start-Sleep -Milliseconds 250
    } while ($true)
    $script:targets += @{ Id = $daemon.Id; Role = 'DreamDaemon'; StartTicks = $daemon.StartTime.ToUniversalTime().Ticks }
    $script:daemonId = $daemon.Id
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $bundleRoot 'bin/meridian-tracy-helper.exe'
    $startInfo.Arguments = '--session'
    $startInfo.WorkingDirectory = $bundleRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $script:collector = [Diagnostics.Process]::Start($startInfo)
    $script:errorRead = [DogmosCaptureWindows]::ReadAll($script:collector.StandardError)
    $script:targets += @{ Id = $script:collector.Id; Role = 'TracyCollector'; StartTicks = $script:collector.StartTime.ToUniversalTime().Ticks }
    $status = Invoke-Collector 'session_start' @{host='127.0.0.1'; port=$ProfilerPort; connect_timeout_ms=120000; progress_timeout_ms=120000} 250
    if (-not $status.queue_health.prologue_validated -or -not $status.queue_health.hook_installed -or
        $status.queue_health.byond_build -notin @('1685', '1686', '1687')) { throw 'Hook health or BYOND build validation failed.' }
    $run.byond = '516.' + $status.queue_health.byond_build
    foreach ($index in 1..$Windows) {
        $tracePath = Join-Path $outputRoot ('window-{0:D2}.tracy' -f $index)
        Write-Output "Capturing window $index/$Windows for $WindowSeconds seconds..."
        $result = Invoke-Collector 'capture_window' @{duration_ms=$WindowSeconds*1000; memory_limit_mb=$MemoryLimitMB;
            output_path=$tracePath; phase='server'; phase_iteration=$index} ($WindowSeconds + 180)
        if (-not $result.validation.valid) { throw 'Trace validation failed.' }
        $run.windows += @{ file=[IO.Path]::GetFileName($tracePath); sha256=(Get-FileHash -LiteralPath $tracePath -Algorithm SHA256).Hash;
            validation=$result.validation }
    }
    $null = Invoke-Collector 'session_stop' @{} 20
    $run.completed = $true
} catch {
    $run.reason = $_.Exception.Message
    $primaryCaptureError = $_
} finally {
    if ($null -ne $script:collector) {
        try { $script:collector.StandardInput.Close() } catch { $run.cleanup_errors += "collector input: $($_.Exception.Message)" }
        try {
            if (-not $script:collector.WaitForExit(5000)) {
                $script:collector.Kill()
                if (-not $script:collector.WaitForExit(5000)) { throw 'Owned collector did not exit after termination.' }
            }
        } catch {
            $run.retained_collector_pid = $script:collector.Id
            $run.cleanup_errors += "collector exit: $($_.Exception.Message)"
        }
        try {
            if ($null -ne $script:errorRead) {
                if (-not $script:errorRead.Wait(5000)) { throw 'Collector diagnostic stream did not finish.' }
                [IO.File]::WriteAllText((Join-Path $outputRoot 'collector.log'), $script:errorRead.GetAwaiter().GetResult())
            }
        } catch { $run.cleanup_errors += "collector log: $($_.Exception.Message)" }
        try { $script:collector.Dispose() } catch { $run.cleanup_errors += "collector handle: $($_.Exception.Message)" }
    }
    try { $script:sampleWriter.Dispose() } catch { $run.cleanup_errors += "process samples: $($_.Exception.Message)" }
    foreach ($name in @('dogmos.lock.json')) {
        $source = Join-Path $gameRoot $name
        try {
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $outputRoot $name) }
        } catch { $run.cleanup_errors += "deployment evidence: $($_.Exception.Message)" }
    }
    if ($run.cleanup_errors.Count) { $run.completed = $false }
    $run.finished_utc = [DateTime]::UtcNow.ToString('o')
    try {
        [IO.File]::WriteAllText((Join-Path $outputRoot 'capture.json'), ($run | ConvertTo-Json -Depth 15))
    } catch {
        $run.completed = $false
        $run.cleanup_errors += "capture evidence: $($_.Exception.Message)"
        Write-Warning "Could not save capture.json: $($_.Exception.Message)"
    }
}
if ($null -ne $primaryCaptureError) { throw $primaryCaptureError }
if ($run.cleanup_errors.Count) { throw "Capture cleanup failed: $($run.cleanup_errors -join '; ')" }
