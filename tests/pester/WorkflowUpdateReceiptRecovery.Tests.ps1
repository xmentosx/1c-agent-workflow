BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

Describe 'Workflow update receipt detail recovery' {
    BeforeAll {
        function New-ReceiptCommitFixture {
            param([string]$Root,[string]$Change='')
            $utf8=[Text.UTF8Encoding]::new($false)
            New-Item -ItemType Directory -Force -Path (Join-Path $Root '.agent-1c'),(Join-Path $Root '.codex/rules'),(Join-Path $Root '.kilo/commands'),(Join-Path $Root 'src/cf')|Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.gitignore'),".agent-1c/snapshots/`n.agent-1c/tmp/`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),'{"aiRules":{"tools":["codex"]}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/dependency-lock.json'),'{"schemaVersion":1,"dependencies":{"workflowPackage":{"source":"path","repo":"fixture","ref":"master","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'),'old package',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.codex/rules/старое правило.md'),'old rule',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.kilo/commands/itl.md'),'old command',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль с пробелом.bsl'),'business baseline',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.ai-rules.json'),'{"files":{".codex/rules/старое правило.md":{"source":"content/rules/old.md","installedHash":"fixture","userModified":false}}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/client-surface.json'),'{"schemaVersion":1,"clients":{"kilocode":{"files":{".kilo/commands/itl.md":{"hash":"fixture"}}}}}',$utf8)
            if($Change-eq'OpenCode') {[IO.File]::WriteAllText((Join-Path $Root 'opencode.json'),'{"user":"old"}',$utf8)}
            & git -C $Root init -q -b master; $LASTEXITCODE|Should -Be 0
            & git -C $Root config user.name 'Receipt recovery fixture'
            & git -C $Root config user.email 'receipt@example.invalid'
            & git -C $Root add --all; & git -C $Root commit -qm baseline; $LASTEXITCODE|Should -Be 0
            & {
                . $helperPath -ProjectRoot $Root -Action help *> $null
                $source=[pscustomobject]@{root=$repoRoot;commit=('b'*40);ref='master';repo='fixture';source='path'}
                $before=Get-CurrentCommit
                $paths=@('AGENT-INSTALL.md','.agent-1c/dependency-lock.json','.ai-rules.json','.agent-1c/client-surface.json','.codex/rules/старое правило.md','.codex/rules/новое правило.md','.kilo/commands/itl.md')
                if($Change-eq'business'){$paths+='src/cf/Модуль с пробелом.bsl'}
                if($Change-eq'OpenCode'){$paths+='opencode.json'}
                $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths $paths -SnapshotParent (Join-Path $Root '.agent-1c/snapshots/workflow-update')
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
                [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'),'new package',$utf8)
                [IO.File]::WriteAllText((Join-Path $Root '.codex/rules/новое правило.md'),'new owned rule',$utf8)
                [IO.File]::WriteAllText((Join-Path $Root '.ai-rules.json'),'{"files":{".codex/rules/новое правило.md":{"source":"content/rules/new.md","installedHash":"new"}}}',$utf8)
                [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/client-surface.json'),'{"schemaVersion":1,"clients":{"codex":{"files":{".codex/current.md":{"hash":"new"}}}}}',$utf8)
                if($Change-eq'business'){[IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль с пробелом.bsl'),'foreign business',$utf8)}
                if($Change-eq'OpenCode'){[IO.File]::WriteAllText((Join-Path $Root 'opencode.json'),'{"user":"new"}',$utf8)}
                $details=@{preCommitHead=$before;aiRulesPathsBefore=@('.codex/rules/старое правило.md');clientSurfacePathsBefore=@('.kilo/commands/itl.md');plannedChangePaths=$paths}
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase master-commit-ready -Details $details
                Invoke-Git @('add','--all')
                $subject=if($Change-eq'subject'){'unrelated commit'}else{Get-WorkflowUpdateCommitMessage -Source $source}
                Invoke-Git @('commit','-qm',$subject)
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase master-committed -Details $details
                $pending=Get-WorkflowUpdatePendingSnapshot
                $damaged=ConvertTo-Agent1cHashtable -Object $pending.receipt
                foreach($key in @('preCommitHead','aiRulesPathsBefore','clientSurfacePathsBefore','plannedChangePaths')){[void]$damaged.Remove($key)}
                if($Change-ne'executor'){$damaged.recoveryExecutorRoot=$repoRoot;$damaged.recoveryExecutorCommit=('c'*40)}
                if($Change-eq'partial'){$damaged.preCommitHead=$before}
                Write-Utf8TextAtomic -Path $pending.receiptPath -Value (($damaged|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
                if($Change-eq'parent'){Invoke-Git @('commit','--allow-empty','-qm',(Get-WorkflowUpdateCommitMessage -Source $source))}
                if($Change-eq'backup'){$record=@($snapshot.records|Where-Object relativePath -eq '.ai-rules.json')[0];[IO.File]::WriteAllText($record.backupPath,'{"files":{}}',$utf8)}
                if($Change-eq'dirty'){[IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль с пробелом.bsl'),'late user business',$utf8)}
                [pscustomobject]@{root=$Root;source=$source;snapshot=$snapshot;head=Get-CurrentCommit;before=$before;receiptPath=$pending.receiptPath}
            }
        }
    }

    It 'retains nonreserved details and permits an explicit detail override during executor rebinding' {
        $fixture=New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Сохранение полей с пробелом') -PendingInterruption
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            $pending=Get-WorkflowUpdatePendingSnapshot
            $source=[pscustomobject]@{root=$repoRoot;commit=('b'*40);ref='master';repo='fixture';source='path'}
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $pending.snapshot -Source $source -Phase post-copy-running -Details @{ownerNote='first';context=@{unicode='Кириллица с пробелом';paths=@('one','two')}}
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $pending.snapshot -Source $source -Phase post-copy-running -Details @{ownerNote='second';recoveryExecutorRoot=$repoRoot;recoveryExecutorCommit=('c'*40)}
            $saved=(Get-WorkflowUpdatePendingSnapshot).receipt
            $saved.ownerNote|Should -BeExactly 'second'
            $saved.context.unicode|Should -BeExactly 'Кириллица с пробелом'
            @($saved.context.paths)|Should -Be @('one','two')
            $saved.recoveryExecutorCommit|Should -BeExactly ('c'*40)
            $before=(Get-FileHash -LiteralPath $pending.receiptPath).Hash
            {Save-WorkflowUpdateSnapshotReceipt -Snapshot $pending.snapshot -Source $source -Phase post-copy-running -Details @{phase='forged'}}|Should -Throw '*WORKFLOW_UPDATE_RECEIPT_DETAIL_CONFLICT*'
            (Get-FileHash -LiteralPath $pending.receiptPath).Hash|Should -BeExactly $before
        }
    }

    It 'reconstructs the fully lost committed details from hash-bound before manifests and the single owned Git commit' {
        $fixture=New-ReceiptCommitFixture -Root (Join-Path $TestDrive 'Повреждённый master с пробелом')
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            Mock Assert-WorkflowUpdateRecordedSource {}
            $beforeFiles=@($fixture.snapshot.records|ForEach-Object {Get-WorkflowUpdatePathState -RelativePath $_.relativePath})
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $fixture.snapshot -Source $fixture.source -Phase master-committed -Details @{recoveryExecutorRoot=$repoRoot;recoveryExecutorCommit=('c'*40)}
            $saved=(Get-WorkflowUpdatePendingSnapshot).receipt
            $saved.preCommitHead|Should -BeExactly $fixture.before
            @($saved.aiRulesPathsBefore)|Should -Be @('.codex/rules/старое правило.md')
            @($saved.clientSurfacePathsBefore)|Should -Be @('.kilo/commands/itl.md')
            @($saved.plannedChangePaths)|Should -Contain '.codex/rules/новое правило.md'
            @($saved.aiRulesPathsBefore)|Should -Not -Contain '.codex/rules/новое правило.md'
            (Assert-WorkflowUpdateMasterCommitCheckpoint -Receipt $saved -Source $fixture.source).committed|Should -BeTrue
            Get-CurrentCommit|Should -BeExactly $fixture.head
            @($fixture.snapshot.records|ForEach-Object {Get-WorkflowUpdatePathState -RelativePath $_.relativePath})|Should -Be $beforeFiles
            Should -Invoke Assert-WorkflowUpdateRecordedSource -Times 1 -Exactly
        }
    }

    It 'refuses ambiguous committed-detail repair for <Change> without changing the receipt or Git HEAD' -ForEach @(
        @{Change='backup';Category='WORKFLOW_UPDATE_RECONCILIATION_BACKUP_INVALID'},
        @{Change='parent';Category='WORKFLOW_UPDATE_MASTER_HEAD_CHANGED'},
        @{Change='subject';Category='WORKFLOW_UPDATE_MASTER_HEAD_CHANGED'},
        @{Change='business';Category='WORKFLOW_UPDATE_MASTER_COMMIT_PATHS_CHANGED'},
        @{Change='OpenCode';Category='WORKFLOW_UPDATE_MASTER_COMMIT_PATHS_CHANGED'},
        @{Change='dirty';Category='WORKFLOW_UPDATE_MASTER_COMMIT_DIRTY'},
        @{Change='partial';Category='WORKFLOW_UPDATE_MASTER_COMMIT_RECEIPT_INVALID'},
        @{Change='executor';Category='WORKFLOW_UPDATE_MASTER_COMMIT_RECEIPT_INVALID'}
    ) {
        $fixture=New-ReceiptCommitFixture -Root (Join-Path $TestDrive ('Чужие данные '+$Change)) -Change $Change
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            Mock Assert-WorkflowUpdateRecordedSource {}
            $sha=(Get-FileHash -LiteralPath $fixture.receiptPath).Hash
            $expected="*$Category*"
            if($Change-eq'business'){$expected+='src/cf/Модуль с пробелом.bsl*'}
            if($Change-eq'OpenCode'){$expected+='opencode.json*'}
            {Save-WorkflowUpdateSnapshotReceipt -Snapshot $fixture.snapshot -Source $fixture.source -Phase master-committed -Details @{recoveryExecutorRoot=$repoRoot;recoveryExecutorCommit=('c'*40)}}|Should -Throw $expected
            (Get-FileHash -LiteralPath $fixture.receiptPath).Hash|Should -BeExactly $sha
            Get-CurrentCommit|Should -BeExactly $fixture.head
        }
    }
}
