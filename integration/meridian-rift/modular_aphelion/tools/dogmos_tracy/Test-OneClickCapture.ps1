param([Parameter(Mandatory=$true)][string]$EvidenceRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$EvidenceRoot=[IO.Path]::GetFullPath($EvidenceRoot)
if(Test-Path -LiteralPath $EvidenceRoot){throw 'Choose new fixture evidence.'}
New-Item -ItemType Directory -Path $EvidenceRoot | Out-Null
$source=Join-Path $PSScriptRoot 'Start-DogmosCapture.ps1'
$results=@()
$stub=@'
param($Mode,$GameDirectory,$BundleDirectory,$DreamDaemonPath,$OutputDirectory,$WindowSeconds,$Windows,$WaitSeconds,$ProfilerPort,$ExpectedDreamDaemonPath,$NotBeforeUtc)
$scenario=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'scenario.txt')
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'calls.txt') -Value $Mode
$marker=Join-Path $GameDirectory 'data/enable_tracy'
if($Mode -eq 'Check'){
    if($scenario -eq 'check-failure'){throw 'fixture collector startup failure'}
    return [pscustomobject]@{BundleVerified=$true;CollectorStarts=$true;NextRoundArmed=(Test-Path -LiteralPath $marker)}
}
if($Mode -eq 'ArmNextRound'){
    [IO.File]::WriteAllText($marker,'')
    if($scenario -eq 'settings-write-failure'){New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'capture-settings.json')|Out-Null}
    return
}
if($Mode -eq 'Capture'){
    if($scenario -in @('timeout','cleanup-failure')){throw 'fixture capture timeout'}
    if($scenario -eq 'replacement-marker'){
        [IO.File]::WriteAllText($marker,'another owner')
        throw 'fixture replacement marker'
    }
    Remove-Item -LiteralPath $marker
    New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
    $windows=@(1..$Windows | ForEach-Object {@{file="window-$_.tracy"}})
    if($scenario -eq 'incomplete'){$windows=@()}
    if($scenario -eq 'deployment-changed'){[IO.File]::WriteAllText((Join-Path $GameDirectory 'dogmos.dll'),'changed')}
    @{completed=($scenario -ne 'incomplete');windows=$windows}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutputDirectory 'capture.json')
}
'@
foreach($scenario in @('check-only','not-admin','check-failure','missing-pair','mismatched-pair','already-armed','occupied-port','output-exists','timeout','cleanup-failure','replacement-marker','settings-write-failure','incomplete','deployment-changed','success')){
    $caseRoot=Join-Path $EvidenceRoot $scenario
    $game=Join-Path $caseRoot 'game with spaces'
    New-Item -ItemType Directory -Path $caseRoot,(Join-Path $game 'data')|Out-Null
    $scriptPath=Join-Path $caseRoot 'Start-DogmosCapture.ps1'
    Copy-Item -LiteralPath $source -Destination $scriptPath
    Set-Content -LiteralPath (Join-Path $caseRoot 'Capture-Dogmos.ps1') -Value $stub
    Set-Content -LiteralPath (Join-Path $caseRoot 'scenario.txt') -Value $scenario
    Set-Content -LiteralPath (Join-Path $caseRoot 'bundle.json') -Value '{}'
    [IO.File]::WriteAllText((Join-Path $game 'tgstation.dmb'),'fixture build')
    $artifacts=@()
    foreach($role in @('shim','service')){
        $nativeName=if($role -eq 'shim'){'dogmos.dll'}else{'dogmosd.exe'}
        $architecture=if($role -eq 'shim'){'i686'}else{'x86_64'}
        $nativePath=Join-Path $game $nativeName
        [IO.File]::WriteAllText($nativePath,'fixture native bytes; never executed')
        $artifacts+=@{platform='windows';role=$role;file=('windows/'+$nativeName);architecture=$architecture;size=(Get-Item -LiteralPath $nativePath).Length;sha256=(Get-FileHash -LiteralPath $nativePath).Hash}
    }
    @{schema_version=1;artifacts=$artifacts}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $game 'dogmos.lock.json')
    if($scenario -eq 'missing-pair'){Remove-Item -LiteralPath (Join-Path $game 'dogmosd.exe')}
    if($scenario -eq 'mismatched-pair'){[IO.File]::WriteAllText((Join-Path $game 'dogmos.dll'),'wrong bytes')}
    $engine=Join-Path $caseRoot 'DreamDaemon.exe'
    [IO.File]::WriteAllText($engine,'fixture path only; never executed')
    $marker=Join-Path $game 'data/enable_tracy'
    $output=Join-Path $caseRoot 'capture-output'
    if($scenario -eq 'already-armed'){[IO.File]::WriteAllText($marker,'existing marker')}
    if($scenario -eq 'output-exists'){New-Item -ItemType Directory -Path $output|Out-Null}
    . $scriptPath
    # Replace only OS admission and network discovery for fixture execution.
    # The actual launcher function and marker/settings/result logic are unchanged.
    $global:CaptureFixtureScenario=$scenario
    function Test-CaptureAdministrator {return $global:CaptureFixtureScenario -ne 'not-admin'}
    function Get-NetTCPConnection {param($LocalPort,$State,$ErrorAction);if($global:CaptureFixtureScenario -eq 'occupied-port'){[pscustomobject]@{LocalPort=$LocalPort}}}
    function Remove-Item {
        param([string]$LiteralPath)
        if($global:CaptureFixtureScenario -eq 'cleanup-failure' -and $LiteralPath.EndsWith('enable_tracy')){throw 'fixture marker removal denied'}
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath
    }
    $errorText=$null
    try {
        Invoke-DogmosCapture -GameDirectory $game -DreamDaemonPath $engine -OutputDirectory $output -WindowSeconds 1 -Windows 2 -CheckOnly:($scenario -eq 'check-only') | Out-Null
    }catch{$errorText=$_.Exception.Message}
    $expectedFailure=$scenario -notin @('check-only','success')
    if($expectedFailure -ne ($null -ne $errorText)){throw "Unexpected outcome in $scenario : $errorText"}
    $callsPath=Join-Path $caseRoot 'calls.txt'
    $calls=@();if(Test-Path -LiteralPath $callsPath){$calls=@(Get-Content -LiteralPath $callsPath)}
    $expectCalls=switch($scenario){
        'not-admin' {@()}
        {$_ -in @('check-only','check-failure','missing-pair','mismatched-pair','already-armed','occupied-port','output-exists')} {@('Check')}
        'settings-write-failure' {@('Check','ArmNextRound')}
        default {@('Check','ArmNextRound','Capture')}
    }
    if(($calls -join ',') -cne ($expectCalls -join ',')){throw "Unexpected operation order in $scenario : $($calls -join ',')"}
    $markerShouldRemain=$scenario -in @('already-armed','replacement-marker','cleanup-failure')
    if((Test-Path -LiteralPath $marker) -ne $markerShouldRemain){throw "Marker ownership violated in $scenario"}
    if($scenario -eq 'check-only' -and ((Test-Path -LiteralPath $output) -or (Test-Path -LiteralPath (Join-Path $caseRoot 'capture-settings.json')))){throw 'CheckOnly wrote capture state.'}
    if('ArmNextRound' -in $calls){
        $launch=Get-Content -LiteralPath (Join-Path $output 'launch.json') -Raw|ConvertFrom-Json
        if($launch.completed -ne ($scenario -eq 'success')){throw "Wrong completion evidence for $scenario"}
        if($scenario -in @('timeout','settings-write-failure') -and -not $launch.unconsumed_marker_removed){throw "Missing owned marker cleanup evidence for $scenario"}
        if($scenario -eq 'cleanup-failure' -and ($errorText -ne 'fixture capture timeout' -or $launch.marker_cleanup_error -ne 'fixture marker removal denied')){throw 'Cleanup masked primary failure or lost cleanup evidence.'}
    }
    $results+=@{scenario=$scenario;passed=$true;operations=$calls;expected_failure=$errorText}
}
Remove-Variable -Name CaptureFixtureScenario -Scope Global
@{scope='Actual launcher logic with OS admission/network/collector fixture doubles; no game or TGS process launched.';powershell=$PSVersionTable.PSVersion.ToString();source_sha256=(Get-FileHash -LiteralPath $source).Hash;cases=$results}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $EvidenceRoot 'result.json')
Write-Output "Passed $($results.Count) launcher scenarios."
