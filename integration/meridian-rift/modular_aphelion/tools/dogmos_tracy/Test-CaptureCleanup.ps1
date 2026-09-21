param([Parameter(Mandatory=$true)][string]$EvidenceRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$EvidenceRoot=[IO.Path]::GetFullPath($EvidenceRoot)
if(Test-Path -LiteralPath $EvidenceRoot){throw 'Choose fresh evidence.'}
New-Item -ItemType Directory -Path $EvidenceRoot|Out-Null
$captureSourcePath=(Resolve-Path (Join-Path $PSScriptRoot 'Capture-Dogmos.ps1')).Path
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($captureSourcePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Collector source does not parse.'}
$outer=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
$text=$outer.Finally.Extent.Text
$cleanup=[scriptblock]::Create($text.Substring(1,$text.Length-2))
$postlude=[scriptblock]::Create(($ast.EndBlock.Statements | Select-Object -Last 2 | ForEach-Object {$_.Extent.Text}) -join "`n")
$results=@()
foreach($scenario in @('normal','sample-close-failure','collector-close-failure','collector-exit-failure','evidence-write-failure')){
    $outputRoot=Join-Path $EvidenceRoot $scenario
    $gameRoot=Join-Path $outputRoot 'game'
    New-Item -ItemType Directory -Path $outputRoot,$gameRoot|Out-Null
    Set-Content -LiteralPath (Join-Path $gameRoot 'dogmos.lock.json') -Value '{}'
    $run=[ordered]@{completed=($scenario -eq 'normal');reason=if($scenario -eq 'normal'){$null}else{'primary capture failure'};cleanup_errors=@();retained_collector_pid=$null;finished_utc=$null}
    $primaryCaptureError=$null
    if($scenario -ne 'normal'){$primaryCaptureError=[Management.Automation.ErrorRecord]::new([Exception]::new('primary capture failure'),'fixture',[Management.Automation.ErrorCategory]::NotSpecified,$null)}
    $script:collector=$null;$script:errorRead=$null
    $script:sampleWriter=[IO.StringWriter]::new()
    if($scenario -eq 'sample-close-failure'){$script:sampleWriter=[pscustomobject]@{};$script:sampleWriter|Add-Member ScriptMethod Dispose {throw 'fixture sample close failure'}}
    if($scenario -like 'collector-*'){
        $input=[pscustomobject]@{}
        if($scenario -eq 'collector-close-failure'){$input|Add-Member ScriptMethod Close {throw 'fixture input close failure'}}else{$input|Add-Member ScriptMethod Close {}}
        $script:collector=[pscustomobject]@{Id=12345;StandardInput=$input}
        if($scenario -eq 'collector-exit-failure'){
            $script:collector|Add-Member ScriptMethod WaitForExit {param($ms);throw 'fixture collector exit failure'}
        }else{$script:collector|Add-Member ScriptMethod WaitForExit {param($ms);return $true}}
        $script:collector|Add-Member ScriptMethod Dispose {}
        $script:collector|Add-Member ScriptMethod Kill {throw 'Unexpected fixture Kill'}
    }
    if($scenario -eq 'evidence-write-failure'){New-Item -ItemType Directory -Path (Join-Path $outputRoot 'capture.json')|Out-Null}
    . $cleanup
    $thrown=$null;try{. $postlude}catch{$thrown=$_.Exception.Message}
    if($scenario -eq 'normal'){
        if(-not $run.completed -or $thrown){throw 'Normal cleanup unexpectedly failed.'}
    }else{
        if($thrown -ne 'primary capture failure' -or $run.completed -or -not $run.cleanup_errors.Count){throw "Primary failure or cleanup evidence lost in $scenario : $thrown"}
    }
    if($scenario -ne 'evidence-write-failure'){
        $saved=Get-Content -LiteralPath (Join-Path $outputRoot 'capture.json') -Raw|ConvertFrom-Json
        if($saved.reason -ne $run.reason -or -not $saved.finished_utc){throw 'Saved capture evidence differs.'}
    }
    if($scenario -eq 'collector-exit-failure' -and $run.retained_collector_pid -ne 12345){throw 'Retained collector ownership missing.'}
    $results+=@{scenario=$scenario;passed=$true;primary_error=$thrown;cleanup_errors=$run.cleanup_errors}
}
@{source_sha256=(Get-FileHash -LiteralPath $captureSourcePath).Hash;powershell=$PSVersionTable.PSVersion.ToString();scope='Actual AST-extracted cleanup and error propagation with process/writer fixture doubles; no collector or game launch.';cases=$results}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $EvidenceRoot 'result.json')
Write-Output "Passed $($results.Count) collector cleanup scenarios."
