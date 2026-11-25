[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SpecPath)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$utf8=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=$utf8
$OutputEncoding=$utf8
$lib=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\1c-workflow\scripts\lib'))
foreach($name in @('core','runtime-values','ports','sessions')) { . (Join-Path $lib ('agent-1c.'+$name+'.ps1')) }
. (Join-Path $PSScriptRoot 'SourceCapture.ps1')
$context=Read-Utf8Text -Path $env:ITL_RUN_CONTEXT | ConvertFrom-Json
$script:ProjectRoot=[string]$context.target.workspace
Import-DotEnv -Path (Join-Path $script:ProjectRoot '.dev.env')
$cancelPath=[string](Get-StateValue -State $context -Name 'cancelPath' -Default '')
$spec=Read-Utf8Text -Path $SpecPath | ConvertFrom-Json
if ([string]$spec.stepId -notmatch '^[a-f0-9]{32}$') { throw 'SOURCE_CAPTURE_STEP_ID_INVALID' }
if ([double]$spec.timeoutSeconds -le 0 -or [double]$spec.timeoutSeconds -gt 86400 -or [double]::IsNaN([double]$spec.timeoutSeconds)) { throw 'SOURCE_CAPTURE_TIMEOUT_INVALID' }
$step=Get-ItlSourceCaptureStep -Context $context -RunRoot (Split-Path -Parent $env:ITL_RUN_CONTEXT) -Spec $spec
$log=Join-Path $step.root ($spec.stepId + '.log')
$resultPath=Join-Path $step.root ($spec.stepId + '.json')
$arguments=@($step.arguments) + @('/Out', $log)
if ($step.output) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $step.output) | Out-Null }
if ($step.create) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $step.scratch) | Out-Null }
$result=[ordered]@{operation=$step.operation; status='running'; startedAt=[DateTime]::UtcNow.ToString('o'); cleanupErrors=@(); log=$log}
$process=$null
$watch=[Diagnostics.Stopwatch]::StartNew()
try {
    $sessionWait=Get-OneCSessionWaitParameters -ContextPath $env:ITL_RUN_CONTEXT -DefaultTimeoutSeconds ([double]$spec.timeoutSeconds)
    Invoke-WithOneCSessionAdmissionContext -InfoBaseKind $step.base.kind -InfoBasePath $step.base.path -Purpose 'profile-source-capture' @sessionWait -ScriptBlock {
        try {
            $argumentLine=if ($step.create) { Join-OneCCreateInfoBaseCommandLineArguments -Arguments $arguments } else { Join-NativeCommandLineArguments -Arguments $arguments }
            $process=Invoke-OneCSessionProcessStart -StartProcess {
                Start-Process -FilePath $step.executable -ArgumentList $argumentLine -WorkingDirectory $script:ProjectRoot -WindowStyle Hidden -PassThru
            }
            $result.pid=$process.Id
            $result.processStartedAt=$process.StartTime.ToUniversalTime().ToString('o')
            $result.admissionWaitSeconds=$watch.Elapsed.TotalSeconds
            while (-not $process.WaitForExit(100)) {
                if ($cancelPath -and (Test-Path -LiteralPath $cancelPath)) { throw 'CANCELLED' }
                if (Test-OneCSessionWaitExpired -Context ([pscustomobject]$sessionWait) -Watch $watch) { throw 'SOURCE_CAPTURE_STEP_TIMEOUT' }
            }
            $result.exitCode=$process.ExitCode
            if ($process.ExitCode -ne 0) { throw ('SOURCE_CAPTURE_DESIGNER_FAILED: ' + $process.ExitCode) }
        } finally {
            if ($null -ne $process) {
                if (-not $process.HasExited) {
                    $stopped=Stop-NativeProcessForSafety -Process $process
                    if (-not $stopped.confirmed) { $result.cleanupErrors += 'SOURCE_CAPTURE_PROCESS_EXIT_UNPROVEN' }
                }
                $process.Dispose()
            }
        }
    }
    if ($step.create) {
        Write-Utf8TextAtomic -Path $step.marker -Value (([ordered]@{snapshotId=$spec.snapshotId; jobId=$context.jobId; path=$step.scratch}) | ConvertTo-Json)
    }
    $result.status='completed'
} catch {
    $result.status='failed'
    $result.error=$_.Exception.Message
} finally {
    $result.finishedAt=[DateTime]::UtcNow.ToString('o')
    Write-Utf8TextAtomic -Path $resultPath -Value ($result | ConvertTo-Json -Depth 8)
}
$result | ConvertTo-Json -Depth 8 -Compress
if ($result.status -ne 'completed' -or @($result.cleanupErrors).Count) { exit 1 }
