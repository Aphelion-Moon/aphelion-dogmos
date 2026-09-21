#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$GameDirectory,
    [string]$DreamDaemonPath,
    [string]$OutputDirectory,
    [ValidateRange(1,300)][int]$WindowSeconds = 120,
    [ValidateRange(1,8)][int]$Windows = 5,
    [ValidateRange(1,900)][int]$WaitSeconds = 600,
    [ValidateRange(1,65535)][int]$ProfilerPort = 8086,
    [switch]$CheckOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-CapturePath([string]$Value, [string]$Prompt) {
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = Read-Host $Prompt }
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'A deployment path is required.' }
    return $Value.Trim().Trim('"')
}

function Test-CaptureAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CaptureDeployment([string]$Root) {
    $records = @()
    $files = @('tgstation.dmb','dogmos.lock.json','dogmos.dll','dogmosd.exe')
    if (Test-Path -LiteralPath (Join-Path $Root 'tgstation.rsc') -PathType Leaf) { $files += 'tgstation.rsc' }
    foreach ($name in $files) {
        $file = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "The Dogmos deployment is missing $name." }
        $item = Get-Item -LiteralPath $file
        $records += [ordered]@{path=$name;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $lock = Get-Content -LiteralPath (Join-Path $Root 'dogmos.lock.json') -Raw | ConvertFrom-Json
    if ($lock.schema_version -ne 1) { throw 'Unsupported Dogmos lock schema.' }
    foreach ($role in @('shim','service')) {
        $expected = @($lock.artifacts | Where-Object { $_.platform -eq 'windows' -and $_.role -eq $role })
        $name = if ($role -eq 'shim') {'dogmos.dll'} else {'dogmosd.exe'}
        $architecture = if ($role -eq 'shim') {'i686'} else {'x86_64'}
        $actual = @($records | Where-Object { $_.path -eq $name })[0]
        if ($expected.Count -ne 1 -or $expected[0].file -ne ('windows/'+$name) -or $expected[0].architecture -ne $architecture -or $expected[0].size -ne $actual.bytes -or $expected[0].sha256 -ne $actual.sha256) {
            throw "The deployed $name does not match dogmos.lock.json."
        }
    }
    return $records
}

function Invoke-DogmosCapture {
param(
    [string]$GameDirectory,
    [string]$DreamDaemonPath,
    [string]$OutputDirectory,
    [ValidateRange(1,300)][int]$WindowSeconds = 120,
    [ValidateRange(1,8)][int]$Windows = 5,
    [ValidateRange(1,900)][int]$WaitSeconds = 600,
    [ValidateRange(1,65535)][int]$ProfilerPort = 8086,
    [switch]$CheckOnly
)
if (-not [Environment]::Is64BitProcess) { throw 'Run START_CAPTURE.cmd from 64-bit Windows.' }
if (-not $CheckOnly) {
    if (-not (Test-CaptureAdministrator)) {
        throw 'Right-click START_CAPTURE.cmd and choose Run as administrator on the game server.'
    }
}
if ($WindowSeconds * $Windows -gt 1500) { throw 'Total capture duration must not exceed 25 minutes.' }

$settingsPath = Join-Path $PSScriptRoot 'capture-settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if (-not $GameDirectory) { $GameDirectory = [string]$settings.GameDirectory }
    if (-not $DreamDaemonPath) { $DreamDaemonPath = [string]$settings.DreamDaemonPath }
}
$GameDirectory = Read-CapturePath $GameDirectory 'TGS deployment folder containing tgstation.dmb and data'
$gameRoot = (Resolve-Path -LiteralPath $GameDirectory).Path
$captureScript = Join-Path $PSScriptRoot 'Capture-Dogmos.ps1'
$check = & $captureScript -Mode Check -GameDirectory $gameRoot -BundleDirectory $PSScriptRoot
$check | Format-List | Out-Host
$deploymentFiles = @(Get-CaptureDeployment $gameRoot)
if ($CheckOnly) {
    Write-Output 'Bundle, collector and deployed native-pair checks passed. No hook or next-round marker was installed. Engine and capture attachment are checked when arming.'
    return
}
$DreamDaemonPath = Read-CapturePath $DreamDaemonPath 'DreamDaemon.exe selected for this deployment in TGS'
$enginePath = (Resolve-Path -LiteralPath $DreamDaemonPath).Path
if ($check.NextRoundArmed) { throw 'A profiling marker is already present. Finish or cancel that armed capture before starting another.' }
if (@(Get-NetTCPConnection -LocalPort $ProfilerPort -State Listen -ErrorAction SilentlyContinue).Count) {
    throw 'The profiler port already has a listener. Finish the current profiled round before arming a startup capture.'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $PSScriptRoot ('captures/startup-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory already exists; choose a new capture directory.' }
# Test output write access before creating a marker. The collector creates its own directory.
$outputParent = [IO.Path]::GetDirectoryName($outputRoot)
$null = New-Item -ItemType Directory -Force -Path $outputParent
$writeProbe = Join-Path $outputParent ('.capture-write-' + [Guid]::NewGuid().ToString('N'))
$probeStream = [IO.File]::Open($writeProbe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
$probeStream.Dispose()
Remove-Item -LiteralPath $writeProbe

$launch = [ordered]@{
    schema=1;started_utc=[DateTime]::UtcNow.ToString('o');finished_utc=$null;completed=$false;error=$null
    game_directory=$gameRoot;dreamdaemon_path=$enginePath;output_directory=$outputRoot
    window_seconds=$WindowSeconds;windows=$Windows;wait_seconds=$WaitSeconds;profiler_port=$ProfilerPort
    bundle_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'bundle.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    launcher_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Start-DogmosCapture.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    deployment_files=$deploymentFiles;deployment_files_after=$null;armed_utc=$null;marker_created=$false;unconsumed_marker_removed=$false;marker_cleanup_error=$null
    environment=[ordered]@{os=[Environment]::OSVersion.VersionString;logical_processors=[Environment]::ProcessorCount;powershell=$PSVersionTable.PSVersion.ToString()}
    limits=@('Server acceptance requires actual successful traces and reviewed coverage.','Deployment hashes identify the build; record map, seed, player count and scenario separately.','Broader host activity is not excluded by game-process observations.')
}
$marker = Join-Path $gameRoot 'data/enable_tracy'
$markerCreationTicks = $null
$evidenceWriteError = $null
try {
    $launch.armed_utc = [DateTime]::UtcNow.ToString('o')
    & $captureScript -Mode ArmNextRound -GameDirectory $gameRoot -DreamDaemonPath $enginePath -BundleDirectory $PSScriptRoot
    $launch.marker_created = $true
    $armedMarker = Get-Item -LiteralPath $marker -ErrorAction SilentlyContinue
    if ($null -ne $armedMarker) { $markerCreationTicks = $armedMarker.CreationTimeUtc.Ticks }
    [IO.File]::WriteAllText($settingsPath, ([ordered]@{GameDirectory=$gameRoot;DreamDaemonPath=$enginePath} | ConvertTo-Json))
    Write-Output "Ready. Perform the normal TGS hard restart now; this window will wait up to $WaitSeconds seconds."
    Write-Output "Capture destination: $outputRoot"
    & $captureScript -Mode Capture -GameDirectory $gameRoot -BundleDirectory $PSScriptRoot -OutputDirectory $outputRoot -WindowSeconds $WindowSeconds -Windows $Windows -WaitSeconds $WaitSeconds -ProfilerPort $ProfilerPort -ExpectedDreamDaemonPath $enginePath -NotBeforeUtc $launch.armed_utc
    $result = Get-Content -LiteralPath (Join-Path $outputRoot 'capture.json') -Raw | ConvertFrom-Json
    if (-not $result.completed -or @($result.windows).Count -ne $Windows) { throw 'Capture did not complete every requested window.' }
    $launch.deployment_files_after = @(Get-CaptureDeployment $gameRoot)
    if (($launch.deployment_files | ConvertTo-Json -Compress) -cne ($launch.deployment_files_after | ConvertTo-Json -Compress)) { throw 'The deployed build or native pair changed during capture.' }
    $launch.completed = $true
} catch {
    $launch.error = $_.Exception.Message
    throw
} finally {
    # Remove only the empty, unconsumed one-shot marker this invocation created.
    # The loaded hook remains owned by the game until its normal hard restart.
    try {
        if ($launch.marker_created -and (Test-Path -LiteralPath $marker)) {
            $remaining = Get-Item -LiteralPath $marker
            if ($remaining.CreationTimeUtc.Ticks -eq $markerCreationTicks -and $remaining.Length -eq 0) {
                Remove-Item -LiteralPath $marker
                $launch.unconsumed_marker_removed = $true
            }
        }
    } catch {
        $launch.marker_cleanup_error = $_.Exception.Message
        $launch.completed = $false
    }
    $launch.finished_utc = [DateTime]::UtcNow.ToString('o')
    try {
        $null = New-Item -ItemType Directory -Force -Path $outputRoot
        [IO.File]::WriteAllText((Join-Path $outputRoot 'launch.json'), ($launch | ConvertTo-Json -Depth 8))
    } catch {
        $evidenceWriteError = $_.Exception.Message
        Write-Warning "Could not save launch evidence: $evidenceWriteError"
    }
}
if ($launch.marker_cleanup_error) { throw "Capture marker cleanup failed: $($launch.marker_cleanup_error)" }
if ($evidenceWriteError) { throw "Capture evidence write failed: $evidenceWriteError" }
Write-Output 'Capture complete. Keep the entire capture folder with the matching round logs and scenario notes.'
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-DogmosCapture @PSBoundParameters }
    catch {
        $failure = [ordered]@{failed_utc=[DateTime]::UtcNow.ToString('o');error=$_.Exception.Message;scope='Launcher failure; see launch.json and capture.json if capture began.'}
        $failurePath = Join-Path $PSScriptRoot ('capture-failure-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N') + '.json')
        try { [IO.File]::WriteAllText($failurePath, ($failure | ConvertTo-Json)); Write-Host "Failure details: $failurePath" } catch { Write-Warning 'Could not save the failure record in the bundle directory.' }
        throw
    }
}
