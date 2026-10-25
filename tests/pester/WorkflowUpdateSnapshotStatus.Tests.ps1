BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

Describe 'workflow update snapshot status ownership' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $heartbeatHelper = $context.HelperPath
        $heartbeatRepo = $context.RepoRoot
    }

    It 'keeps an owned heartbeat during real <Step> work and releases it afterwards' -Tag G3CopyStatus -ForEach @(@{Step='capture'},@{Step='receipt'}) {
        $root = Join-Path $TestDrive ('снимок с пробелом ' + $Step)
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'AGENT-INSTALL.md'
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes('unchanged snapshot bytes')
        [IO.File]::WriteAllBytes($path, $bytes)
        & {
            . $heartbeatHelper -ProjectRoot $root -Action help *> $null
            $RunStatusPath = $script:RunStatusPath = ''
            $snapshot = if ($Step -eq 'receipt') { New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md') -SnapshotParent (Join-Path $root 'private snapshots') }
            $script:RunStatusPath = Join-Path $root 'owned status.json'
            $RunStatusPath = $script:RunStatusPath
            $record = [ordered]@{ pid=$PID; status='running'; stage='workflow-update.copy'; updatedAt='2000-01-01T00:00:00Z'; exitCode=$null; proof='unchanged' }
            [IO.File]::WriteAllText($script:RunStatusPath, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            $global:g3CopyHeartbeatPath = $script:RunStatusPath + '.heartbeat'
            $global:g3CopyHeartbeatObservations = [Collections.Generic.List[object]]::new()
            $command = if ($Step -eq 'capture') { 'Copy-Item' } else { 'Get-WorkflowUpdateSnapshotPathState' }
            $breakpoint = Set-PSBreakpoint -Command $command -Action {
                if (@(Get-PSCallStack | Where-Object { $_.Command -in @('New-WorkflowUpdateRollbackSnapshot','Save-WorkflowUpdateSnapshotReceipt') }).Count) {
                    $exists = Test-Path -LiteralPath $global:g3CopyHeartbeatPath
                    $global:g3CopyHeartbeatObservations.Add(@{ exists=$exists; owner=$(if($exists){[IO.File]::ReadAllText($global:g3CopyHeartbeatPath)}else{''}) })
                }
            }
            try {
                if ($Step -eq 'capture') {
                    $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md') -SnapshotParent (Join-Path $root 'private snapshots')
                    $snapshot.targetRoot | Should -BeExactly $root
                    [Convert]::ToBase64String([IO.File]::ReadAllBytes($snapshot.records[0].backupPath)) | Should -BeExactly ([Convert]::ToBase64String($bytes))
                } else {
                    $source = [pscustomobject]@{ root=$heartbeatRepo; commit=('b'*40); ref='master'; repo='fixture'; source='path' }
                    Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
                    $receipt = Get-Content -LiteralPath (Join-Path $snapshot.root 'transaction.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                    $receipt.phase | Should -Be 'prepared'
                    $receipt.pathState.'AGENT-INSTALL.md' | Should -BeExactly ('file:' + (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant())
                    $receipt.beforePathState.'AGENT-INSTALL.md' | Should -BeExactly $receipt.pathState.'AGENT-INSTALL.md'
                }
                $global:g3CopyHeartbeatObservations.Count | Should -BeGreaterThan 0
                foreach ($observation in $global:g3CopyHeartbeatObservations) {
                    $observation.exists | Should -BeTrue
                    $observation.owner | Should -BeExactly ([string]$PID)
                }
                Test-Path -LiteralPath $global:g3CopyHeartbeatPath | Should -BeFalse
                $script:RunStatusHeartbeatDepth | Should -Be 0
                $status = Get-Content -LiteralPath $script:RunStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $status.status | Should -Be 'running'
                $status.stage | Should -Be 'workflow-update.copy'
                $status.proof | Should -BeExactly 'unchanged'
                [datetime]$status.updatedAt | Should -BeGreaterThan ([datetime]'2000-01-01')
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($bytes))
            } finally {
                Remove-PSBreakpoint -Breakpoint $breakpoint
                Remove-Variable -Name g3CopyHeartbeatPath,g3CopyHeartbeatObservations -Scope Global -ErrorAction SilentlyContinue
                $script:RunStatusPath = ''
            }
        }
    }
}
