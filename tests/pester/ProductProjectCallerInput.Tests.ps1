Describe 'Captured catalog offer uses its own foreground lifecycle caller' {
    BeforeAll {
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $helper=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        $fixture=Join-Path $RepoRoot 'tests/fixtures/product-project-caller-input.ps1'
        . $helper -ProjectRoot $TestDrive -Action help *> $null
    }
    It 'reads <Case> through original capture with cleanup and unchanged parent console mode' -ForEach @(
        @{Case='later';Questions=1},@{Case='empty';Questions=4},@{Case='new';Questions=1},@{Case='existing';Questions=3},@{Case='throw';Questions=2},@{Case='unattended';Questions=0}
    ) {
        $root=Join-Path $TestDrive ('input Проект '+$Case)
        [void][IO.Directory]::CreateDirectory((Join-Path $root '.agent-1c'))
        Write-Utf8TextAtomic (Join-Path $root '.agent-1c/project.json') '{}'
        $arguments=Join-NativeCommandLineArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixture,'-RepoRoot',$RepoRoot,'-Root',$root,'-Case',$Case)
        # ShellExecute creates a separate console; never inject into the worker
        # or user's console. Hidden is required for unattended source tests.
        $process=Start-Process powershell.exe -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden -PassThru
        try {
            $process.WaitForExit(70000)|Should -BeTrue
            if(Test-Path (Join-Path $root 'failure.txt')){throw (Read-Utf8Text (Join-Path $root 'failure.txt'))}
            $parent=Read-Utf8Text (Join-Path $root 'parent.json')|ConvertFrom-Json
            if($parent.capture.exitCode -ne 0){throw ($parent.capture.stderr+$parent.capture.stdout)}
            $process.ExitCode|Should -Be 0
            $child=Read-Utf8Text (Join-Path $root 'child.json')|ConvertFrom-Json
            $parent.answered|Should -Be $Questions
            $parent.modeRestored|Should -BeTrue
            $parent.capture.stdout|Should -Match 'CAPTURE_PIPE_SURVIVED'
            $parent.capture.stderr|Should -BeNullOrEmpty
            $child.readHostKind|Should -Be Cmdlet
            $child.preferences|Should -BeNullOrEmpty
            if($Case -ne 'unattended'){$child.detached|Should -BeTrue}
            if($Case -eq 'later'){$child.error|Should -Match 'CATALOG_PROJECT_UNKNOWN'}
            if($Case -eq 'new'){$child.error|Should -Match 'CATALOG_PROJECT_CREATE_SEPARATE'}
            if($Case -eq 'unattended'){$child.error|Should -Match 'CATALOG_PROJECT_REQUIRED'}
            if($Case -eq 'throw'){$child.error|Should -Match 'Fixture association failed after input'}
            if($Case -in @('existing','empty')){
                $child.error|Should -BeNullOrEmpty
                $nested=Read-Utf8Text (Join-Path $root 'nested.json')|ConvertFrom-Json
                $nested.name|Should -Be 'Тест Проект PM5';$nested.version|Should -Be PM5
            }
        } finally {if(-not $process.HasExited){$null=Stop-NativeProcessForSafety -Process $process};$process.Dispose()}
    }
    It 'refuses a stale record before attaching or reading any input' {
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-console.ps1')
        $script:LifecycleOperationIsContinuation=$true;$script:LifecycleOperationRecord=@{}
        $script:LifecycleOperationStatePath='fixture';$script:LifecycleOperationId='expected';$script:LifecycleOperationOwnerPid=$PID
        $Action='update-workflow';$LifecyclePhase='post-copy'
        Mock Assert-Agent1cLifecycleContinuationOwner {}
        Mock Read-Agent1cLifecycleOperationRecord {return @{operationId='stale'}}
        try {{Invoke-ItlProductProjectCallerInput {throw 'Must not read'}}|Should -Throw '*CATALOG_CALLER_INPUT_UNAVAILABLE*'}
        finally {$script:LifecycleOperationIsContinuation=$false;$script:LifecycleOperationRecord=$null}
    }
}
