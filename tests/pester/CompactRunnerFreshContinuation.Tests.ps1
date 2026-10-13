Describe 'fresh helper compact native wait' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1')
        $freshSourceHelper = if ($env:ITL_TEST_FRESH_BASELINE_ROOT) { Join-Path $env:ITL_TEST_FRESH_BASELINE_ROOT '.agents/skills/1c-workflow/scripts/agent-1c.ps1' } else { $context.HelperPath }
        function Invoke-FreshCompactFixture {
            param([string]$Mode = 'success', [int]$SilentSeconds = 4, [switch]$DefaultStale, [int]$OperationSeconds = 45, [switch]$LegacyNested)
            $root = Join-Path ([IO.Path]::GetTempPath()) ('itl fresh ожидание с пробелом ' + [guid]::NewGuid().ToString('N'))
            $oldEnvironment = @{}
            foreach ($name in @('ITL_RUNNER_STATUS_STALE_WARNING_SECONDS','ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS','ITL_RUNNER_OPERATION_TIMEOUT_SECONDS')) { $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
            try {
                $scripts = Join-Path $root '.agents/skills/1c-workflow/scripts'
                New-Item -ItemType Directory -Path (Join-Path $scripts 'lib') -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/run-itl-command.ps1') -Destination (Join-Path $scripts 'run-itl-command.ps1')
                Copy-Item -LiteralPath (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/lib/itl-runner-timeout.ps1') -Destination (Join-Path $scripts 'lib/itl-runner-timeout.ps1')
                [IO.File]::WriteAllText((Join-Path $root '.gitignore'),'.agent-1c/' + "`n",[Text.Encoding]::ASCII)
                & git -C $root init *> $null
                & git -C $root config user.email 'fixture@example.com'
                & git -C $root config user.name 'Fixture'
                & git -C $root add .gitignore
                & git -C $root commit -m fixture *> $null
                & git -C $root branch -M master
                $parent = @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action,[string]$FixtureSource,[string]$Mode,[int]$SilentSeconds,[string]$RoundTrip,[switch]$ShortHeartbeat,[string]$LegacyFunctionPath)
$fixture = @{root=$ProjectRoot;status=$RunStatusPath;log=$RunLogPath;action=$Action;source=$FixtureSource;mode=$Mode;seconds=$SilentSeconds;roundTrip=$RoundTrip;short=$ShortHeartbeat;legacy=$LegacyFunctionPath}
. $FixtureSource -ProjectRoot $ProjectRoot -Action help -AgentTarget kilocode *> $null
$Action=$fixture.action; $RunStatusPath=$fixture.status; $RunLogPath=$fixture.log
$script:RunStartedAt=Get-Date
if ($fixture.short) {
    $script:FixtureMonitorFactory=${function:New-NativeWaitRunStatusMonitor}
    function New-NativeWaitRunStatusMonitor { param([string[]]$LogPaths=@()) & $script:FixtureMonitorFactory -LogPaths $LogPaths -HeartbeatSeconds 1 }
}
$script:Agent1cReexecArguments=@('-Action',$Action,'-ProjectRoot',$fixture.root,'-RunStatusPath',$RunStatusPath,'-RunLogPath',$RunLogPath,'-FixtureSource',$fixture.source,'-Mode',$fixture.mode,'-SilentSeconds',[string]$fixture.seconds,'-RoundTrip',$fixture.roundTrip,'-OriginalStatusPath',$RunStatusPath)
if($fixture.legacy){$script:Agent1cReexecArguments+=@('-LegacyFunctionPath',$fixture.legacy)}
Enter-Agent1cLifecycleOperation -RequestedAction $Action
$originalErrorWriter=[Console]::Error
$fixtureErrorStream=[IO.FileStream]::new((Join-Path $fixture.root 'native-stderr.txt'),[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
$fixtureErrorWriter=[IO.StreamWriter]::new($fixtureErrorStream,[Text.UTF8Encoding]::new($false)); $fixtureErrorWriter.AutoFlush=$true
[Console]::SetError($fixtureErrorWriter)
try {
    $result=Invoke-Agent1cFreshProcess -ScriptPath (Join-Path $fixture.root 'child.ps1') -ReturnExitStatus
    exit $result.exitCode
} catch {
    $message=$_.Exception.Message
    Complete-Agent1cLifecycleOperation -Status failed -ExitCode 1 -ErrorMessage $message
    Set-RunFailureContext -Category runner
    Write-RunStatus -Status failed -ExitCode 1 -ErrorMessage $message
    [Console]::Error.WriteLine($message)
    exit 1
} finally { [Console]::SetError($originalErrorWriter); $fixtureErrorWriter.Dispose(); Exit-Agent1cLifecycleOperation }
'@
                $child = @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action,[string]$FixtureSource,[string]$Mode,[int]$SilentSeconds,[string]$RoundTrip,[string]$OriginalStatusPath,[string]$OperationId,[int]$OperationOwnerPid,[switch]$OperationContinuation,[string]$LegacyFunctionPath)
$fixture=@{root=$ProjectRoot;status=$RunStatusPath;log=$RunLogPath;action=$Action;source=$FixtureSource;mode=$Mode;seconds=$SilentSeconds;roundTrip=$RoundTrip;external=$OriginalStatusPath;operation=$OperationId;owner=$OperationOwnerPid;continuation=$OperationContinuation;legacy=$LegacyFunctionPath}
. $FixtureSource -ProjectRoot $ProjectRoot -Action help -AgentTarget kilocode *> $null
$Action=$fixture.action; $RunStatusPath=$fixture.status; $RunLogPath=$fixture.log
Enter-Agent1cLifecycleOperation -RequestedAction $Action -RequestedOperationId $fixture.operation -RequestedOwnerPid $fixture.owner -Continuation:$fixture.continuation
[IO.File]::WriteAllText((Join-Path $fixture.root 'child-pid.txt'),[string]$PID,[Text.Encoding]::ASCII)
Set-RunStage -Stage 'workflow-update.branches' -Detail 'Обновление ветки без stdout'
if($fixture.mode -eq 'nested') {
    [IO.File]::WriteAllText((Join-Path $fixture.root 'immediate-child-pid.txt'),[string]$PID,[Text.Encoding]::ASCII)
    . $fixture.legacy
    $script:Agent1cReexecArguments=@('-Action',$Action,'-ProjectRoot',$fixture.root,'-RunStatusPath',$RunStatusPath,'-RunLogPath',$RunLogPath,'-FixtureSource',$fixture.source,'-Mode','success','-SilentSeconds',[string]$fixture.seconds,'-RoundTrip',$fixture.roundTrip,'-OriginalStatusPath',$fixture.external)
    $nestedResult=Invoke-Agent1cFreshProcess -ScriptPath (Join-Path $fixture.root 'child.ps1') -ReturnExitStatus
    exit $nestedResult.exitCode
}
Write-Output ('UTF8 stdout: ' + $fixture.roundTrip)
[Console]::Error.WriteLine('UTF8 stderr: Кириллица с пробелом')
if ($fixture.mode -in @('foreign','stale')) {
    $status=Read-Utf8Text -Path $RunStatusPath | ConvertFrom-Json
    $status.status='succeeded'; $status.stage='FORGED_TERMINAL'
    if ($fixture.mode -eq 'foreign') { $status.pid=$PID+999999 }
    else { $status.startedAt='2000-01-01T00:00:00Z'; $status.updatedAt='2000-01-01T00:00:00Z' }
    Write-Utf8TextAtomic -Path $RunStatusPath -Value ($status|ConvertTo-Json -Depth 10)
}
if ($fixture.mode -eq 'orphan') {
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 90'))
    $owned=Start-Process powershell.exe -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -PassThru -WindowStyle Hidden
    [IO.File]::WriteAllText((Join-Path $fixture.root 'descendant-pid.txt'),[string]$owned.Id,[Text.Encoding]::ASCII)
}
Start-Sleep -Seconds $fixture.seconds
Copy-Item -LiteralPath $fixture.external -Destination (Join-Path $fixture.root 'observed-external.json')
if ($fixture.mode -eq 'streaming') {
    $log=Read-Utf8Text -Path $RunLogPath
    $errorReadStream=[IO.FileStream]::new((Join-Path $fixture.root 'native-stderr.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $errorReader=[IO.StreamReader]::new($errorReadStream,[Text.UTF8Encoding]::new($false))
    try{$errorLog=$errorReader.ReadToEnd()}finally{$errorReader.Dispose()}
    if ($log -notmatch [regex]::Escape('UTF8 stdout: '+$fixture.roundTrip) -or $errorLog -notmatch 'UTF8 stderr: Кириллица с пробелом') { throw 'FRESH_OUTPUT_NOT_STREAMED_BEFORE_EXIT' }
}
$script:RunStage='fixture.actual-terminal'; $script:RunStageDetail='Точный финал дочернего процесса'
if ($fixture.mode -eq 'failure') {
    Complete-Agent1cLifecycleOperation -Status failed -ExitCode 7 -ErrorMessage 'Проверяемый отказ ветки'
    Write-RunStatus -Status failed -ExitCode 7 -ErrorMessage 'Проверяемый отказ ветки'
    exit 7
}
Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
if ($fixture.mode -eq 'invalid-final') {
    $invalid=Read-Utf8Text -Path $RunStatusPath | ConvertFrom-Json
    $invalid.status='succeeded'; $invalid.pid=$PID+999999; $invalid.exitCode=0
    Write-Utf8TextAtomic -Path $RunStatusPath -Value ($invalid|ConvertTo-Json -Depth 10)
    exit 0
}
Write-RunStatus -Status succeeded -ExitCode 0
if ($fixture.mode -eq 'cleanup-failure') {
    Start-Sleep -Seconds 3
    Complete-Agent1cLifecycleOperation -Status failed -ExitCode 7 -ErrorMessage 'Отказ очистки после первоначального успеха'
    Write-RunStatus -Status failed -ExitCode 7 -ErrorMessage 'Отказ очистки после первоначального успеха'
    exit 7
}
if ($fixture.mode -eq 'cleanup') { Start-Sleep -Seconds 4 }
exit 0
'@
                [IO.File]::WriteAllText((Join-Path $scripts 'agent-1c.ps1'),$parent,[Text.UTF8Encoding]::new($true))
                [IO.File]::WriteAllText((Join-Path $root 'child.ps1'),$child,[Text.UTF8Encoding]::new($true))
                [Environment]::SetEnvironmentVariable('ITL_RUNNER_STATUS_STALE_WARNING_SECONDS',$(if($DefaultStale){$null}else{'1'}),'Process')
                [Environment]::SetEnvironmentVariable('ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS',$(if($DefaultStale){$null}else{'2'}),'Process')
                [Environment]::SetEnvironmentVariable('ITL_RUNNER_OPERATION_TIMEOUT_SECONDS',[string]$OperationSeconds,'Process')
                $roundTrip=(Join-Path $root 'параметр с пробелом')+'\'
                $invokeArgs=@('--','-Action','update-workflow','-FixtureSource',$freshSourceHelper,'-Mode',$Mode,'-SilentSeconds',[string]$SilentSeconds,'-RoundTrip',$roundTrip)
                if($LegacyNested) {
                    $legacyText=@(& git -C $context.RepoRoot show 'c6c829b61c8d31a9f52d7a64ed762c5b5b93b2d7:.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1') -join "`n"
                    if($LASTEXITCODE -ne 0){throw 'Canonical c6 legacy function source unavailable'}
                    $legacyTokens=$null;$legacyErrors=$null
                    $legacyAst=[Management.Automation.Language.Parser]::ParseInput($legacyText,[ref]$legacyTokens,[ref]$legacyErrors)
                    $legacyFunction=$legacyAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Agent1cFreshProcess'},$true)
                    if(@($legacyErrors).Count -or $null -eq $legacyFunction){throw 'Canonical c6 legacy function parse failed'}
                    $legacyPath=Join-Path $root 'legacy c6 fresh function.ps1'
                    [IO.File]::WriteAllText($legacyPath,$legacyFunction.Extent.Text,[Text.UTF8Encoding]::new($true))
                    # The real stopped stand argv has no trailing separator.
                    # Keep the independent original trailing-separator cases.
                    $roundTrip=$roundTrip.TrimEnd('\')
                    $invokeArgs=@('--','-Action','update-workflow','-FixtureSource',$freshSourceHelper,'-Mode','nested','-SilentSeconds',[string]$SilentSeconds,'-RoundTrip',$roundTrip,'-LegacyFunctionPath',$legacyPath)
                }
                if(-not $DefaultStale){$invokeArgs+='-ShortHeartbeat'}
                Push-Location $root
                try {
                    $timer=[Diagnostics.Stopwatch]::StartNew()
                    $native=Invoke-ItlNativeProcessCapture -FilePath 'powershell.exe' -Arguments (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $scripts 'run-itl-command.ps1'))+$invokeArgs) -WorkingDirectory $root -TimeoutSeconds ($OperationSeconds+15)
                    $result=@{exitCode=$native.exitCode;stdout=$native.stdout;stderr=$native.stderr;combinedText=($native.stdout+"`n"+$native.stderr)}
                    $timer.Stop()
                } finally { Pop-Location }
                $summary=($result.stdout -join "`n") | ConvertFrom-Json
                $status=Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $lifecycle=Get-Content -LiteralPath (Join-Path $root '.agent-1c/locks/lifecycle-operation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($env:ITL_TEST_FRESH_RECEIPTS_ROOT) {
                    $receiptRoot=Join-Path $env:ITL_TEST_FRESH_RECEIPTS_ROOT (Split-Path -Leaf $root)
                    New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
                    Copy-Item -LiteralPath $summary.logPath -Destination (Join-Path $receiptRoot 'console.log')
                    Copy-Item -LiteralPath $summary.statusPath -Destination (Join-Path $receiptRoot 'status.json')
                    Copy-Item -LiteralPath (Join-Path $root '.agent-1c/locks/lifecycle-operation.json') -Destination (Join-Path $receiptRoot 'lifecycle.json')
                    if(Test-Path -LiteralPath (Join-Path $root 'native-stderr.txt')){Copy-Item -LiteralPath (Join-Path $root 'native-stderr.txt') -Destination (Join-Path $receiptRoot 'native-stderr.txt')}
                }
                return @{root=$root;result=$result;summary=$summary;status=$status;lifecycle=$lifecycle;elapsed=$timer.Elapsed.TotalSeconds;roundTrip=$roundTrip}
            } catch { if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}; throw }
            finally { foreach($name in $oldEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$oldEnvironment[$name],'Process')} }
        }
        function Remove-FreshCompactFixture { param($Fixture) Remove-Item -LiteralPath $Fixture.root -Recurse -Force }
    }

    It 'keeps the original compact parent fresh while its silent continuation exceeds the configured stale threshold' {
        $fixture=Invoke-FreshCompactFixture
        try {
            $fixture.result.exitCode | Should -Be 0 -Because $fixture.result.combinedText
            $fixture.status.status | Should -Be 'succeeded'
            $fixture.status.stage | Should -Be 'fixture.actual-terminal'
            $fixture.status.pid | Should -Be $fixture.lifecycle.pid
            $fixture.status.pid | Should -Not -Be ([int](Get-Content -LiteralPath (Join-Path $fixture.root 'child-pid.txt')))
            $fixture.lifecycle.status | Should -Be 'succeeded'
            (Get-Content -LiteralPath $fixture.summary.logPath -Raw -Encoding UTF8) | Should -Match ([regex]::Escape('UTF8 stdout: '+$fixture.roundTrip))
            (Get-Content -LiteralPath (Join-Path $fixture.root 'native-stderr.txt') -Raw -Encoding UTF8) | Should -Match 'UTF8 stderr: Кириллица с пробелом'
            $fixture.result.combinedText | Should -Not -Match 'RUNNER_STATUS_STALE'
        } finally { Remove-FreshCompactFixture $fixture }
    }

    It 'preserves a native nonzero continuation result and exact terminal failure fields' {
        $fixture=Invoke-FreshCompactFixture -Mode failure
        try {
            $fixture.result.exitCode | Should -Be 7
            $fixture.status.status | Should -Be 'failed'
            $fixture.status.exitCode | Should -Be 7
            $fixture.status.errorMessage | Should -Be 'Проверяемый отказ ветки'
            $fixture.status.stage | Should -Be 'fixture.actual-terminal'
            $fixture.lifecycle.exitCode | Should -Be 7
        } finally { Remove-FreshCompactFixture $fixture }
    }

    It 'forwards terminal before child cleanup without replacing it with running' {
        $fixture=Invoke-FreshCompactFixture -Mode cleanup
        try {
            $fixture.result.exitCode | Should -Be 0
            $fixture.status.status | Should -Be 'succeeded'
            $fixture.status.stage | Should -Be 'fixture.actual-terminal'
            $fixture.result.combinedText | Should -Not -Match 'RUNNER_STATUS_STALE'
        } finally { Remove-FreshCompactFixture $fixture }
    }

    It 'preserves a later cleanup failure after the child first publishes success' {
        $fixture=Invoke-FreshCompactFixture -Mode cleanup-failure -DefaultStale
        try {
            $fixture.result.exitCode | Should -Be 7
            $fixture.status.status | Should -Be 'failed'
            $fixture.status.exitCode | Should -Be 7
            $fixture.status.errorMessage | Should -Be 'Отказ очистки после первоначального успеха'
            $fixture.lifecycle.status | Should -Be 'failed'
        } finally { Remove-FreshCompactFixture $fixture }
    }

    It 'does not report success when the signed continuation has no valid terminal observation' {
        $fixture=Invoke-FreshCompactFixture -Mode invalid-final
        try {
            $fixture.result.exitCode | Should -Be 1
            $fixture.status.status | Should -Be 'failed'
            $fixture.status.errorMessage | Should -Match 'did not write valid terminal run status'
        } finally { Remove-FreshCompactFixture $fixture }
    }

    It 'preserves a nested c6 legacy continuation terminal from its actual grandchild writer' {
        $fixture=Invoke-FreshCompactFixture -LegacyNested
        try {
            $fixture.result.exitCode | Should -Be 0 -Because $fixture.result.combinedText
            $fixture.status.status | Should -Be 'succeeded'
            $fixture.status.stage | Should -Be 'fixture.actual-terminal'
            $grandchildPid=[int](Get-Content -LiteralPath (Join-Path $fixture.root 'child-pid.txt'))
            $immediatePid=[int](Get-Content -LiteralPath (Join-Path $fixture.root 'immediate-child-pid.txt'))
            $fixture.lifecycle.continuationPid | Should -Be $grandchildPid
            $grandchildPid | Should -Not -Be $immediatePid
            $fixture.status.pid | Should -Be $fixture.lifecycle.pid
            $fixture.status.pid | Should -Not -Be $grandchildPid
            (Get-Content -LiteralPath $fixture.summary.logPath -Raw -Encoding UTF8) | Should -Match ([regex]::Escape('UTF8 stdout: '+$fixture.roundTrip))
        } finally { Remove-FreshCompactFixture $fixture }
    }

    It 'streams UTF8 stdout and stderr before the fresh child exits' {
        $fixture=Invoke-FreshCompactFixture -Mode streaming
        try { $fixture.result.exitCode | Should -Be 0 -Because $fixture.result.combinedText }
        finally { Remove-FreshCompactFixture $fixture }
    }

    It 'rejects a <Mode> observation from the private child channel' -ForEach @(@{Mode='foreign'},@{Mode='stale'}) {
        $fixture=Invoke-FreshCompactFixture -Mode $Mode
        try {
            $fixture.result.exitCode | Should -Be 0
            $observed=Get-Content -LiteralPath (Join-Path $fixture.root 'observed-external.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $observed.status | Should -Be 'running'
            $observed.pid | Should -Be $fixture.lifecycle.pid
            $observed.stage | Should -Not -Be 'FORGED_TERMINAL'
            $fixture.status.stage | Should -Be 'fixture.actual-terminal'
        } finally { Remove-FreshCompactFixture $fixture }
    }

    It 'bounds a silent continuation and stops its owned descendant at the original operation deadline' {
        $fixture=Invoke-FreshCompactFixture -Mode orphan -SilentSeconds 90 -OperationSeconds 20
        try {
            $fixture.result.exitCode | Should -Not -Be 0
            $fixture.elapsed | Should -BeLessThan 40
            $fixture.status.status | Should -Be 'failed'
            $childPid=[int](Get-Content -LiteralPath (Join-Path $fixture.root 'child-pid.txt'))
            $descendantPid=[int](Get-Content -LiteralPath (Join-Path $fixture.root 'descendant-pid.txt'))
            @(Get-Process -Id $childPid -ErrorAction SilentlyContinue).Count | Should -Be 0
            @(Get-Process -Id $descendantPid -ErrorAction SilentlyContinue).Count | Should -Be 0
            $fixture.status.errorMessage | Should -Match 'TIMEOUT'
        } finally { Remove-FreshCompactFixture $fixture }
    }
}


Describe 'Native Windows PowerShell child environment' -Tag WorkflowDependencyTransport {
    It 'loads the matching hash cmdlet through the shared capture boundary and round-trips a Unicode whitespace path' {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context=Initialize-WorkflowPesterContext
        $core=Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if(-not $core){Set-ItResult -Skipped -Because 'PowerShell Core is not installed; the cross-edition boundary is inapplicable';return}
        $root=Join-Path $TestDrive 'Модули и путь с пробелом'
        New-Item -ItemType Directory -Path $root | Out-Null
        $payload=Join-Path $root 'Файл для hash.txt'
        [IO.File]::WriteAllText($payload,'Unicode round trip',[Text.UTF8Encoding]::new($false))
        $expected=(Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
        $child=Join-Path $root 'Child script.ps1'
        $childText=@'
param([string]$Payload)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$hash=Get-FileHash -LiteralPath $Payload -Algorithm SHA256
[pscustomobject]@{path=$Payload;sha256=$hash.Hash.ToLowerInvariant();edition=$PSVersionTable.PSEdition}|ConvertTo-Json -Compress
'@
        [IO.File]::WriteAllText($child,$childText,[Text.UTF8Encoding]::new($true))
        $parent=Join-Path $root 'Parent script.ps1'
        $parentText=@'
param([string]$Helper,[string]$Root,[string]$Child,[string]$Payload)
$ErrorActionPreference='Stop'
. $Helper -ProjectRoot $Root -Action help *> $null
$before=$env:PSModulePath
$result=Invoke-ItlNativeProcessCapture -FilePath (Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Child,'-Payload',$Payload) -WorkingDirectory $Root -TimeoutSeconds 60
if($env:PSModulePath -cne $before){throw 'Parent module environment changed'}
if($result.exitCode -ne 0){throw $result.stderr}
[pscustomobject]@{parentEdition=$PSVersionTable.PSEdition;child=($result.stdout|ConvertFrom-Json)}|ConvertTo-Json -Compress
'@
        [IO.File]::WriteAllText($parent,$parentText,[Text.UTF8Encoding]::new($true))
        & {
            . $context.HelperPath -ProjectRoot $root -Action help *> $null
            $result=Invoke-ItlNativeProcessCapture -FilePath $core.Source -Arguments @('-NoProfile','-File',$parent,'-Helper',$context.HelperPath,'-Root',$root,'-Child',$child,'-Payload',$payload) -WorkingDirectory $root -TimeoutSeconds 90
            $result.exitCode | Should -Be 0 -Because $result.stderr
            $data=$result.stdout|ConvertFrom-Json
            $data.parentEdition | Should -Be Core
            $data.child.edition | Should -Be Desktop
            $data.child.path | Should -BeExactly $payload
            $data.child.sha256 | Should -BeExactly $expected
        }
    }
}
