BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

Describe 'Exact source cutover for a pinned legacy workflow recovery' {
    BeforeEach {
        $root = Join-Path $TestDrive ('Проект с пробелом ' + [guid]::NewGuid().ToString('N'))
        $candidate = Join-Path $TestDrive ('Старый пакет ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root, $candidate | Out-Null
        . $helperPath -ProjectRoot $root -Action help *> $null
        $script:legacyPending = [pscustomobject]@{ receipt=[pscustomobject]@{phase='master-committed';sourceRoot=$candidate;sourceCommit=('b'*40)} }
        Mock Get-WorkflowUpdatePendingSnapshot { $script:legacyPending }
        Mock Assert-WorkflowUpdateSnapshotCurrentState {}
        Mock Assert-WorkflowUpdateRecordedSource {}
    }

    It 'finishes the same guard owner for <Phase> without installing candidate files' -ForEach @(
        @{Phase='master-committed'}, @{Phase='branch-commit-ready'}
    ) {
        $script:legacyPending.receipt.phase = $Phase
        Enable-WorkflowExecutionGuardForCurrentRoot
        $marker = Get-Content -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') -Raw | ConvertFrom-Json
        $marker.generation | Should -Be 'execution-guards-v2'
        Test-Path -LiteralPath (Join-Path $root '.agents') | Should -BeFalse
        Should -Invoke Assert-WorkflowUpdateRecordedSource -Times 2 -Exactly
        Should -Invoke Assert-WorkflowUpdateSnapshotCurrentState -Times 1 -Exactly
    }

    It 'does not reinterpret a missing modern installed entrypoint as a legacy package' {
        $entrypoint = Join-Path $candidate '.agents/skills/1c-workflow/scripts/execution-guard-cutover.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $entrypoint) | Out-Null
        [IO.File]::WriteAllText($entrypoint, '# modern candidate')
        { Enable-WorkflowExecutionGuardForCurrentRoot } | Should -Throw '*EXECUTION_GUARD_CUTOVER_ENTRYPOINT_MISSING*'
        Test-Path -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') | Should -BeFalse
    }

    It 'refuses an uncommitted phase' {
        $script:legacyPending.receipt.phase = 'post-copy-failed'
        { Enable-WorkflowExecutionGuardForCurrentRoot } | Should -Throw '*EXECUTION_GUARD_CUTOVER_ENTRYPOINT_MISSING*'
    }

    It 'preserves exact-source refusal before enabling the marker' {
        Mock Assert-WorkflowUpdateRecordedSource { throw 'WORKFLOW_UPDATE_SOURCE_CHANGED: fixture' }
        { Enable-WorkflowExecutionGuardForCurrentRoot } | Should -Throw '*WORKFLOW_UPDATE_SOURCE_CHANGED*'
        Test-Path -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') | Should -BeFalse
    }

    It 'keeps Vanessa launch input outside process inspection without hiding its live state' {
        $runtimeRoot = Join-Path $root '.agent-1c/mcp/ondemand/vanessa-ui'
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        $paramsPath = Join-Path $runtimeRoot 'instance.VAParams.json'
        [IO.File]::WriteAllText($paramsPath, '{"Version":2,"КлиентТестирования":{}}', [Text.UTF8Encoding]::new($false))
        Get-WorkflowUpdateRootRuntimeBusyReason -Root $root | Should -Be ''
        Enable-WorkflowExecutionGuardForCurrentRoot
        [IO.File]::ReadAllText($paramsPath) | Should -Be '{"Version":2,"КлиентТестирования":{}}'
        $runtime = @{testClientPid=0;testClientProcessStartTime='';testClientExecutablePath='';testClientOwnershipMarkers=@();pid=$PID;processStartTime='invalid';executablePath='unknown';ownershipMarkers=@('fixture')}
        [IO.File]::WriteAllText((Join-Path $runtimeRoot 'instance.json'), ($runtime | ConvertTo-Json -Compress))
        Get-WorkflowUpdateRootRuntimeBusyReason -Root $root | Should -Be 'runtime-process-active-or-unconfirmed'
        { Enable-WorkflowExecutionGuardForCurrentRoot } | Should -Throw '*EXECUTION_GUARD_CUTOVER_RUNTIME_OWNERSHIP_UNCONFIRMED*'
    }

    It 'uses its exact source guard with a modern installed payload too' {
        $installed = Join-Path $root '.agents/skills/1c-workflow/scripts/execution-guard-cutover.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installed) | Out-Null
        [IO.File]::WriteAllText($installed, "throw 'Installed guard from another payload must not execute'")
        Enable-WorkflowExecutionGuardForCurrentRoot
        Test-Path -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') | Should -BeTrue
        Should -Invoke Assert-WorkflowUpdateRecordedSource -Times 1 -Exactly
    }

    It 'preserves the guard runtime ownership check and existing marker bytes' {
        $runtimeRoot = Join-Path $root '.agent-1c/mcp/ondemand'
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        $runtime = @{testClientPid=0;testClientProcessStartTime='';testClientExecutablePath='';testClientOwnershipMarkers=@();pid=$PID;processStartTime='invalid';executablePath='unknown';ownershipMarkers=@('fixture')}
        [IO.File]::WriteAllText((Join-Path $runtimeRoot 'unproven.json'), ($runtime | ConvertTo-Json -Compress))
        $marker = Join-Path $root '.agent-1c/execution-guard-generation.json'
        [IO.File]::WriteAllText($marker, '{"preserve":"before"}')
        { Enable-WorkflowExecutionGuardForCurrentRoot } | Should -Throw '*EXECUTION_GUARD_CUTOVER_RUNTIME_OWNERSHIP_UNCONFIRMED*'
        [IO.File]::ReadAllText($marker) | Should -Be '{"preserve":"before"}'
    }
}
