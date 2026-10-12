Describe "1C workflow development branch lifecycle checks" {
    BeforeAll { . (Join-Path $PSScriptRoot 'DevBranchLifecycleSupport.ps1') }

    Describe 'Copied MCP provenance in an unfinished fork' -Tag 'ForkMcpProvenance' {
        BeforeAll {
            function New-ForkMcpProvenanceFixture {
                param([string]$Root, [string]$LegacyDocument = '')
                $main=Join-Path $Root 'Главная рабочая папка'; $target=Join-Path $Root 'Незавершённая ветка'
                $utf8=[Text.UTF8Encoding]::new($false)
                New-Item -ItemType Directory -Force -Path (Join-Path $main '.agent-1c/mcp'),(Join-Path $main '.kilo') | Out-Null
                [IO.File]::WriteAllText((Join-Path $main '.gitignore'),".kilo/kilo.json`n.kilo/kilo.jsonc`n.agent-1c/mcp/`n.agent-1c/snapshots/`n.agent-1c/fork-staging/`n.agent-1c/dev-branches/`n.agent-1c/tmp/`n",$utf8)
                [IO.File]::WriteAllText((Join-Path $main '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}',$utf8)
                [IO.File]::WriteAllText((Join-Path $main 'AGENT-INSTALL.md'),'old package',$utf8)
                [IO.File]::WriteAllText((Join-Path $main 'business.txt'),'original business',$utf8)
                if($LegacyDocument){[IO.File]::WriteAllText((Join-Path $main 'README.md'),$(if($LegacyDocument -eq 'known'){"known legacy`r`n"}else{'custom README'}),$utf8)}
                & git -C $main init -q -b master; $LASTEXITCODE | Should -Be 0
                & git -C $main config user.name 'MCP provenance fixture'; $LASTEXITCODE | Should -Be 0
                & git -C $main config user.email 'mcp@example.invalid'; $LASTEXITCODE | Should -Be 0
                & git -C $main add --all; $LASTEXITCODE | Should -Be 0
                & git -C $main commit -qm baseline; $LASTEXITCODE | Should -Be 0
                $anchor=(& git -C $main rev-parse HEAD).Trim()
                & git -C $main branch itldev/source; $LASTEXITCODE | Should -Be 0
                & git -C $main worktree add -q -b itldev/fork $target; $LASTEXITCODE | Should -Be 0
                New-Item -ItemType Directory -Force -Path (Join-Path $target '.kilo'),(Join-Path $target '.agent-1c/mcp'),(Join-Path $target '.agent-1c/dev-branches') | Out-Null
                $config='{"mcp":{"itl-roctup-data":{"type":"local","command":["fixture.exe","D:\\База с пробелом"],"enabled":false},"itl-vanessa-ui":{"type":"local","command":["fixture-ui.exe"]}},"permission":{"bash":"ask"}}'
                foreach($path in @($main,$target)){[IO.File]::WriteAllText((Join-Path $path '.kilo/kilo.json'),$config,$utf8)}
                [IO.File]::WriteAllText((Join-Path $main '.agent-1c/mcp/client-managed.json'),'{"schemaVersion":1,"owners":{"kilocode/ondemand-facade":["itl-roctup-data","itl-vanessa-ui"]}}',$utf8)
                [IO.File]::WriteAllText((Join-Path $target '.agent-1c/mcp/client-managed.json'),'{"schemaVersion":1,"owners":{"kilocode/branch-runtime":[],"codex/user":["foreign-client"]}}',$utf8)
                $staging=Join-Path $main '.agent-1c/fork-staging/fork'
                New-Item -ItemType Directory -Force -Path $staging | Out-Null
                $artifact=Join-Path $staging 'snapshot.bin';[IO.File]::WriteAllText($artifact,'small immutable base fixture',$utf8)
                $artifactSha=(Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
                $forkId=[guid]::NewGuid().ToString('N')
                $fork=[ordered]@{schemaVersion=1;status='ready';forkId=$forkId;targetSafeName='fork';targetWorktreePath=$target;targetGitBranch='itldev/fork';sourceCommit=$anchor;sourceGitBranch='itldev/source';artifactPath=$artifact;artifactSha256=$artifactSha;artifactKind='file-1cd';infoBaseKind='file'}
                [IO.File]::WriteAllText((Join-Path $staging 'manifest.json'),($fork|ConvertTo-Json -Depth 5),$utf8)
                $state=[ordered]@{devBranch='itldev/fork';worktreePath=$target;mainWorktreePath=$main;forkId=$forkId;forkedFromCommit=$anchor;forkedFromBranch='itldev/source';forkSnapshotArtifactSha256=$artifactSha;forkSnapshotArtifactKind='file-1cd';devBranchInfoBasePath=(Join-Path $target '.agent-1c/infobases/dev-branches/fork');infoBaseKind='file';initializationStatus='fork-failed'}
                [IO.File]::WriteAllText((Join-Path $target '.agent-1c/dev-branches/fork.json'),($state|ConvertTo-Json -Depth 5),$utf8)
                $completed=& {
                    $global:LASTEXITCODE=0
                    . $HelperPath -ProjectRoot $main -Action help *> $null
                    $LASTEXITCODE | Should -Be 0
                    $source=[pscustomobject]@{root=$RepoRoot;commit=('a'*40)}
                    $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths (@('AGENT-INSTALL.md','.kilo/kilo.json','.agent-1c/mcp/client-managed.json')+$(if($LegacyDocument){@('README.md')}else{@()})) -SnapshotParent (Join-Path $main '.agent-1c/snapshots/workflow-update')
                    Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
                    [IO.File]::WriteAllText((Join-Path $main 'AGENT-INSTALL.md'),'new package',$utf8)
                    $commitPaths=@('AGENT-INSTALL.md')
                    if($LegacyDocument){Remove-Item -LiteralPath (Join-Path $main 'README.md');$commitPaths+=@('README.md')}
                    & git -C $main add -- $commitPaths; $LASTEXITCODE | Should -Be 0
                    & git -C $main commit -qm 'workflow update'; $LASTEXITCODE | Should -Be 0
                    Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
                    Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
                }
                $pending=& {
                    $global:LASTEXITCODE=0
                    . $HelperPath -ProjectRoot $target -Action help *> $null
                    $LASTEXITCODE | Should -Be 0
                    $source=[pscustomobject]@{root=$RepoRoot;commit=('a'*40)}
                    $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md','.kilo/kilo.json','.agent-1c/mcp/client-managed.json') -SnapshotParent (Join-Path $target '.agent-1c/snapshots/workflow-update')
                    Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
                    [IO.File]::WriteAllText((Join-Path $target 'AGENT-INSTALL.md'),'new package',$utf8)
                    Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-failed
                    $snapshot.root
                }
                [pscustomobject]@{main=$main;target=$target;anchor=$anchor;completed=[string]$completed;pending=[string]$pending;fork=$fork;staging=$staging}
            }
            function Add-ForkMcpMainReceipt {
                param([object]$Fixture,[switch]$DifferentOwnership)
                & {
                    $global:LASTEXITCODE=0
                    . $HelperPath -ProjectRoot $Fixture.main -Action help *> $null
                    $LASTEXITCODE | Should -Be 0
                    if($DifferentOwnership){[IO.File]::WriteAllText((Join-Path $Fixture.main '.agent-1c/mcp/client-managed.json'),'{"schemaVersion":1,"owners":{"kilocode/another-owner":["itl-roctup-data","itl-vanessa-ui"]}}',[Text.UTF8Encoding]::new($false))}
                    $source=[pscustomobject]@{root=$RepoRoot;commit=('a'*40)}
                    $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md','.kilo/kilo.json','.agent-1c/mcp/client-managed.json') -SnapshotParent (Join-Path $Fixture.main '.agent-1c/snapshots/workflow-update')
                    Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
                    [IO.File]::WriteAllText((Join-Path $Fixture.main 'AGENT-INSTALL.md'),'another package update',[Text.UTF8Encoding]::new($false))
                    & git -C $Fixture.main add -- AGENT-INSTALL.md;$LASTEXITCODE|Should -Be 0
                    & git -C $Fixture.main commit -qm 'second workflow update';$LASTEXITCODE|Should -Be 0
                    Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
                    $retained=Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
                    $id=(Split-Path -Leaf $retained).Substring('itl-workflow-update-completed-'.Length)
                    (Get-WorkflowUpdateCompletedSnapshot -SnapshotId $id).receipt.completedHead | Should -BeExactly (Get-CurrentCommit)
                }
            }
        }

        It 'carries ownership with a new JSON copy without importing other client owners' {
            $fixture=New-ForkMcpProvenanceFixture -Root (Join-Path $TestDrive 'Новое копирование с владельцем')
            $newTarget=Join-Path $TestDrive 'Новая целевая папка'
            New-Item -ItemType Directory -Force -Path (Join-Path $newTarget '.agent-1c') | Out-Null
            Copy-Item -LiteralPath (Join-Path $fixture.main '.agent-1c/project.json') -Destination (Join-Path $newTarget '.agent-1c/project.json')
            & {
                $global:LASTEXITCODE=0
                . $HelperPath -ProjectRoot $fixture.main -Action help *> $null
                $LASTEXITCODE | Should -Be 0
                Copy-KiloProjectConfigToWorktree -MainProjectRoot $fixture.main -WorktreePath $newTarget
                $script:ProjectRoot | Should -Be $fixture.main
                (Get-FileHash -LiteralPath (Join-Path $newTarget '.kilo/kilo.json')).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $fixture.main '.kilo/kilo.json')).Hash
                $state=Read-Utf8Text -Path (Join-Path $newTarget '.agent-1c/mcp/client-managed.json') | ConvertFrom-Json
                @($state.owners.'kilocode/ondemand-facade') | Should -Be @('itl-roctup-data','itl-vanessa-ui')
                [IO.File]::WriteAllText((Join-Path $newTarget '.kilo/kilo.json'),'user replacement',[Text.UTF8Encoding]::new($false))
                Copy-KiloProjectConfigToWorktree -MainProjectRoot $fixture.main -WorktreePath $newTarget
                (Read-Utf8Text -Path (Join-Path $newTarget '.kilo/kilo.json')) | Should -BeExactly 'user replacement'
            }
        }

        It 'repairs proven legacy fork ownership with <EquivalentReceipts> equivalent receipts and reaches the ordinary endpoint writer' -ForEach @(@{EquivalentReceipts=1},@{EquivalentReceipts=2}) {
            $fixture=New-ForkMcpProvenanceFixture -Root (Join-Path $TestDrive ('Прерванный fork с доказательством '+$EquivalentReceipts))
            if($EquivalentReceipts -eq 2){Add-ForkMcpMainReceipt -Fixture $fixture}
            & {
                $global:LASTEXITCODE=0
                . $HelperPath -ProjectRoot $fixture.target -Action help *> $null
                $LASTEXITCODE | Should -Be 0
                $configBefore=Get-ItlMcpFileState (Join-Path $fixture.target '.kilo/kilo.json')
                $manifestBefore=Get-ItlMcpFileState (Join-Path $fixture.staging 'manifest.json')
                Restore-UnfinishedForkCopiedMcpOwnership | Should -BeTrue
                (Get-ItlMcpFileState (Join-Path $fixture.target '.kilo/kilo.json')) | Should -BeExactly $configBefore
                (Get-ItlMcpFileState (Join-Path $fixture.staging 'manifest.json')) | Should -BeExactly $manifestBefore
                (Get-CurrentCommit) | Should -BeExactly $fixture.anchor
                @((Read-ItlManagedMcpState).owners.'codex/user') | Should -Contain 'foreign-client'
                Restore-UnfinishedForkCopiedMcpOwnership | Should -BeFalse
                Write-ItlClientMcpEndpoints -Client kilocode -Owner ondemand-facade -Endpoints @([pscustomobject]@{name='itl-roctup-data';url='https://target.invalid'}) | Out-Null
                (Read-ItlClientMcpEntries -Client kilocode)['itl-roctup-data'].enabled | Should -BeFalse
            }
        }

        It 'recognizes only a known legacy retirement in the main ownership capsule: <LegacyDocument>' -ForEach @(@{LegacyDocument='known'},@{LegacyDocument='custom'}) {
            $fixture=New-ForkMcpProvenanceFixture -Root (Join-Path $TestDrive ('Старый документ main '+$LegacyDocument)) -LegacyDocument $LegacyDocument
            & {
                $global:LASTEXITCODE=0
                . $HelperPath -ProjectRoot $fixture.target -Action help *> $null
                $LASTEXITCODE|Should -Be 0
                $sha=[Security.Cryptography.SHA256]::Create()
                try{$knownHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("known legacy`r`n")))).Replace('-','')}finally{$sha.Dispose()}
                function Get-LegacyWorkflowManagedFileHashes {@{'README.md'=@($knownHash)}}
                $configBefore=Get-ItlMcpFileState (Join-Path $fixture.target '.kilo/kilo.json')
                $ownerBefore=Get-ItlMcpFileState (Join-Path $fixture.target '.agent-1c/mcp/client-managed.json')
                if($LegacyDocument -eq 'known'){
                    Restore-UnfinishedForkCopiedMcpOwnership|Should -BeTrue
                    Write-ItlClientMcpEndpoints -Client kilocode -Owner ondemand-facade -Endpoints @([pscustomobject]@{name='itl-roctup-data';url='https://target.invalid'})|Out-Null
                }else{
                    Restore-UnfinishedForkCopiedMcpOwnership|Should -BeFalse
                    {Write-ItlClientMcpEndpoints -Client kilocode -Owner ondemand-facade -Endpoints @([pscustomobject]@{name='itl-roctup-data';url='https://target.invalid'})}|Should -Throw '*CLIENT_MCP_USER_COLLISION*'
                    (Get-ItlMcpFileState (Join-Path $fixture.target '.kilo/kilo.json'))|Should -BeExactly $configBefore
                    (Get-ItlMcpFileState (Join-Path $fixture.target '.agent-1c/mcp/client-managed.json'))|Should -BeExactly $ownerBefore
                }
            }
        }

        It 'keeps the ordinary user collision for <Fault> provenance' -ForEach @(
            @{Fault='tampered-main-backup'},@{Fault='main-receipt-hash'},@{Fault='main-receipt-context'},@{Fault='ready-branch'},@{Fault='target-config-drift'},@{Fault='target-before-marker'},@{Fault='wrong-fork'},@{Fault='foreign-main'},@{Fault='business-main-commit'},@{Fault='forged-business-capsule'},@{Fault='different-ownership-receipts'}
        ) {
            $fixture=New-ForkMcpProvenanceFixture -Root (Join-Path $TestDrive ('Недоказанный перенос '+$Fault))
            $utf8=[Text.UTF8Encoding]::new($false)
            $receiptPath=Join-Path $fixture.completed 'transaction.json'
            $receipt=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $configRecord=@($receipt.records | Where-Object relativePath -CEQ '.kilo/kilo.json')[0]
            $statePath=Join-Path $fixture.target '.agent-1c/dev-branches/fork.json'
            $state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            switch($Fault) {
                'different-ownership-receipts' {Add-ForkMcpMainReceipt -Fixture $fixture -DifferentOwnership}
                'tampered-main-backup' {[IO.File]::AppendAllText((Join-Path $fixture.completed $configRecord.backupName),'changed',$utf8)}
                'main-receipt-hash' {$receipt.beforePathState.'.kilo/kilo.json'='file:'+('0'*64);[IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 15),$utf8)}
                'main-receipt-context' {$receipt.projectRoot=$fixture.target;[IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 15),$utf8)}
                'ready-branch' {$state.initializationStatus='ready';[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 10),$utf8)}
                'target-config-drift' {[IO.File]::AppendAllText((Join-Path $fixture.target '.kilo/kilo.json'),"`n",$utf8)}
                'target-before-marker' {
                    $p=Get-Content -LiteralPath (Join-Path $fixture.pending 'transaction.json') -Raw -Encoding UTF8|ConvertFrom-Json
                    $r=@($p.records|Where-Object relativePath -CEQ '.agent-1c/mcp/client-managed.json')[0]
                    [IO.File]::AppendAllText((Join-Path $fixture.pending $r.backupName),'changed',$utf8)
                }
                'wrong-fork' {$state.forkId=[guid]::NewGuid().ToString('N');[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 10),$utf8)}
                'foreign-main' {
                    $foreign=Join-Path $TestDrive 'Чужой Git main'
                    New-Item -ItemType Directory -Force -Path $foreign|Out-Null
                    & git -C $foreign init -q -b master;$LASTEXITCODE|Should -Be 0
                    $state.mainWorktreePath=$foreign;[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 10),$utf8)
                }
                'business-main-commit' {
                    [IO.File]::WriteAllText((Join-Path $fixture.main 'business.txt'),'foreign business change',$utf8)
                    & git -C $fixture.main add -- business.txt;$LASTEXITCODE|Should -Be 0
                    & git -C $fixture.main commit --amend --no-edit -q;$LASTEXITCODE|Should -Be 0
                    $receipt.completedHead=(& git -C $fixture.main rev-parse HEAD).Trim()
                    [IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 15),$utf8)
                }
                'forged-business-capsule' {
                    $businessBackup=Join-Path $fixture.completed 'item-999'
                    [IO.File]::WriteAllText($businessBackup,'original business',$utf8)
                    $businessPath=Join-Path $fixture.main 'business.txt'
                    [IO.File]::WriteAllText($businessPath,'foreign business change',$utf8)
                    $manifestPath=Join-Path $fixture.main '.ai-rules.json'
                    [IO.File]::WriteAllText($manifestPath,'{"files":{"business.txt":{"source":"forged-rule"}}}',$utf8)
                    $receipt.records+=@([pscustomobject]@{relativePath='business.txt';existed=$true;wasDirectory=$false;backupName='item-999'},[pscustomobject]@{relativePath='.ai-rules.json';existed=$false;wasDirectory=$false;backupName=''})
                    $receipt.beforePathState|Add-Member -NotePropertyName 'business.txt' -NotePropertyValue ('file:'+(Get-FileHash -LiteralPath $businessBackup).Hash.ToLowerInvariant())
                    $receipt.pathState|Add-Member -NotePropertyName 'business.txt' -NotePropertyValue ('file:'+(Get-FileHash -LiteralPath $businessPath).Hash.ToLowerInvariant())
                    $receipt.beforePathState|Add-Member -NotePropertyName '.ai-rules.json' -NotePropertyValue 'absent'
                    $receipt.pathState|Add-Member -NotePropertyName '.ai-rules.json' -NotePropertyValue ('file:'+(Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant())
                    & git -C $fixture.main add -- business.txt .ai-rules.json;$LASTEXITCODE|Should -Be 0
                    & git -C $fixture.main commit --amend --no-edit -q;$LASTEXITCODE|Should -Be 0
                    $receipt.completedHead=(& git -C $fixture.main rev-parse HEAD).Trim()
                    [IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 15),$utf8)
                    & {
                        $global:LASTEXITCODE=0
                        . $HelperPath -ProjectRoot $fixture.main -Action help *> $null
                        $LASTEXITCODE | Should -Be 0
                        $id=(Split-Path -Leaf $fixture.completed).Substring('itl-workflow-update-completed-'.Length)
                        $qualified=Get-WorkflowUpdateCompletedSnapshot -SnapshotId $id
                        $qualified.receipt.completedHead|Should -BeExactly $receipt.completedHead
                    }
                }
            }
            & {
                $global:LASTEXITCODE=0
                . $HelperPath -ProjectRoot $fixture.target -Action help *> $null
                $LASTEXITCODE | Should -Be 0
                $configBefore=Get-ItlMcpFileState (Join-Path $fixture.target '.kilo/kilo.json')
                $ownerBefore=Get-ItlMcpFileState (Join-Path $fixture.target '.agent-1c/mcp/client-managed.json')
                Restore-UnfinishedForkCopiedMcpOwnership | Should -BeFalse
                {Write-ItlClientMcpEndpoints -Client kilocode -Owner ondemand-facade -Endpoints @([pscustomobject]@{name='itl-roctup-data';url='https://target.invalid'})} | Should -Throw '*CLIENT_MCP_USER_COLLISION*'
                (Get-ItlMcpFileState (Join-Path $fixture.target '.kilo/kilo.json')) | Should -BeExactly $configBefore
                (Get-ItlMcpFileState (Join-Path $fixture.target '.agent-1c/mcp/client-managed.json')) | Should -BeExactly $ownerBefore
            }
        }
    }

    It "limits a new worktree path to 50 characters and reports the available branch name length" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            function Get-MainWorktreePath {
                return "C:\Users\e.ermakov\W\test3"
            }

            function Get-DevBranchWorktreeRoot {
                return "C:\Users\e.ermakov\W"
            }

            $acceptedName = "12345678901234567890123"
            $rejectedName = (("x" * 79) -join "")
            $acceptedPath = Resolve-DevBranchWorktreePath -SafeDevBranchName $acceptedName
            Assert-DevBranchWorktreePathBudget -WorktreePath $acceptedPath -SafeDevBranchName $acceptedName | Out-Null

            $message = ""
            $rejectedPath = ""
            try {
                $rejectedPath = Resolve-DevBranchWorktreePath -SafeDevBranchName $rejectedName
                Assert-DevBranchWorktreePathBudget -WorktreePath $rejectedPath -SafeDevBranchName $rejectedName | Out-Null
            } catch {
                $message = $_.Exception.Message
            }

            [pscustomobject]@{
                acceptedLength = $acceptedPath.Length
                rejectedLength = $rejectedPath.Length
                message = $message
                firstLine = @($message -split "\r?\n")[0]
            }
        }

        $result.acceptedLength | Should -Be 50
        $result.rejectedLength | Should -Be 106
        $result.firstLine | Should -Match "сейчас 79"
        $result.firstLine | Should -Match "допустимо не более 23"
        $result.firstLine | Should -Match "нужно убрать минимум 56"
        $result.message | Should -Match "MAX_PATH=260"
    }

    It "stops direct non-interactive manual unsafe action confirmation before creating a worktree" {
        $tempRoot = New-ShortWorkflowProjectRoot
        $legacyWorktreeRoot = "$tempRoot-worktrees"
        $worktreePath = "$tempRoot-needs-confirmation"
        $sourceBase = Join-Path $tempRoot "source-base"
        $oldAppData = $env:APPDATA
        $oldUnsafeSetup = [Environment]::GetEnvironmentVariable("DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", "Process")
        $oldPrefixedUnsafeSetup = [Environment]::GetEnvironmentVariable("AGENT_1C_DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", "Process")

        try {
            [Environment]::SetEnvironmentVariable("DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", $null, "Process")
            [Environment]::SetEnvironmentVariable("AGENT_1C_DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", $null, "Process")

            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`nappdata/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            $devEnv = @(
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=false",
                "VANESSA_MCP_AUTO_START=false"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            $env:APPDATA = Join-Path $tempRoot "appdata"
            $result = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Needs Confirmation")
            $result.exitCode | Should -Not -Be 0
            $outputText = $result.combinedText
            $outputText | Should -Match "run-agent-1c-window\.ps1"
            $outputText | Should -Match "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip"

            ((& git -C $tempRoot branch --list "itldev/needs-confirmation") -join "") | Should -Be ""
            (Test-Path -LiteralPath $worktreePath -ErrorAction SilentlyContinue) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\needs-confirmation.json") -PathType Leaf -ErrorAction SilentlyContinue) | Should -Be $false
        } finally {
            $env:APPDATA = $oldAppData
            [Environment]::SetEnvironmentVariable("DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", $oldUnsafeSetup, "Process")
            [Environment]::SetEnvironmentVariable("AGENT_1C_DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", $oldPrefixedUnsafeSetup, "Process")
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $tempRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $legacyWorktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $legacyWorktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "creates a sibling worktree branch without starting branch MCP even when legacy auto-start is true" {
        $tempRoot = New-ShortWorkflowProjectRoot
        $legacyWorktreeRoot = "$tempRoot-worktrees"
        $worktreePath = "$tempRoot-fixture-branch"
        $sourceBase = Join-Path $tempRoot "source-base"
        $facadeFixtureRoot = "$tempRoot-facade-fixture"
        $projectName = Split-Path -Leaf $tempRoot
        $oldAppData = $env:APPDATA
        $oldOnDemandInstallRoot = $env:ITL_ONDEMAND_MCP_INSTALL_ROOT

        try {
            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`nappdata/`n.agent-1c/`n.kilo/commands/itl*.md`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Value '{"tools":["kilocode"],"files":{}}' -Encoding UTF8
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse
            $fakePlatform = Copy-AutoUpdateToolFixture -TargetRoot $tempRoot
            $env:ITL_ONDEMAND_MCP_INSTALL_ROOT = New-ItlOnDemandMcpInstallFixture -TargetRoot $facadeFixtureRoot
            $devEnv = @(
                "PLATFORM_PATH=$fakePlatform",
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=true",
                "VANESSA_MCP_AUTO_START=true",
                "AGENT_TOOLS=kilocode"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .ai-rules.json .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value '{"instructions":["USER-RULES.md","docs/custom.md"],"permission":{"bash":"ask"}}' -Encoding ASCII

            New-TestBranchSeedFixture -ProjectRoot $tempRoot -SourceInfoBasePath $sourceBase
            $env:APPDATA = Join-Path $tempRoot "appdata"
            $createResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Fixture Branch", "-AgentTarget", "kilocode")
            if ($createResult.exitCode -ne 0) {
                throw "Fixture branch creation failed: $($createResult.combinedText)"
            }

            ((& git -C $tempRoot branch --show-current).Trim()) | Should -Be "master"
            (Test-Path -LiteralPath $worktreePath -PathType Container) | Should -Be $true
            (Test-Path -LiteralPath $legacyWorktreeRoot -ErrorAction SilentlyContinue) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $worktreePath ".dev.env") -PathType Leaf) | Should -Be $true
            (Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".dev.env")) | Should -Match ([regex]::Escape("SOURCE_INFOBASE_PATH=$sourceBase"))
            $statePath = Join-Path $worktreePath ".agent-1c\dev-branches\fixture-branch.json"
            (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -Be $true
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            ([bool]$state.createdWithWorktree) | Should -Be $true
            $state.worktreePath | Should -Be ([System.IO.Path]::GetFullPath($worktreePath))
            $state.mainWorktreePath | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
            $expectedLauncherFolder = "/ITL/" + (Split-Path -Leaf $tempRoot)
            $expectedLauncherName = "$projectName-fixture-branch"
            $state.launcherInfoBaseName | Should -Be $expectedLauncherName
            $state.launcherFolder | Should -Be $expectedLauncherFolder
            $state.unsafeActionProtectionSetupMode | Should -Be "skip"
            ([bool]$state.unsafeActionProtectionConfirmed) | Should -Be $false
            $state.initializationStatus | Should -Be "ready"
            $state.initializationError | Should -Be ""
            $state.initializationUpdatedAt | Should -Not -BeNullOrEmpty
            $state.publicationStatus | Should -Be "disabled"
            $state.publicationMode | Should -Be "none"
            $state.publicationUrl | Should -Be ""
            $state.roctupMcpStatus | Should -Be "stopped"
            [int]$state.roctupMcpPort | Should -Be 0
            $state.roctupMcpPid | Should -Be ""
            $state.roctupMcpUrl | Should -Be ""
            $state.roctupMcpHealthUrl | Should -Be ""
            $state.vanessaMcpStatus | Should -Be "stopped"
            [int]$state.vanessaMcpPort | Should -Be 0
            $state.vanessaMcpPid | Should -Be ""
            $state.vanessaMcpUrl | Should -Be ""
            (Test-Path -LiteralPath (Join-Path $worktreePath ".codex\config.toml") -PathType Leaf -ErrorAction SilentlyContinue) | Should -BeFalse
            $kiloText = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".kilo\kilo.json")
            $kiloText | Should -Not -Match "itl-.*-roctup"
            $kiloText | Should -Not -Match "VanessaAutomation-"
            $kiloConfig = $kiloText | ConvertFrom-Json
            @($kiloConfig.instructions) | Should -Be @("USER-RULES.md", "docs/custom.md")
            $kiloConfig.permission.bash | Should -Be "ask"
            $kiloConfig.PSObject.Properties.Name | Should -Not -Contain "plugin"
            $branchKiloCommands = @(Get-ChildItem -LiteralPath (Join-Path $worktreePath ".kilo\commands") -File -Filter "itl*.md" | Select-Object -ExpandProperty Name | Sort-Object)
            $branchKiloCommands | Should -Be @(@("itl.md", "itl-check.md", "itl-clean.md", "itl-fork-branch.md", "itl-litemode.md", "itl-lock-objects.md", "itl-refresh.md", "itl-refresh-lite.md", "itl-reset-branch.md", "itl-result.md", "itl-status.md", "itl-sync-branches.md", "itl-sync-master.md", "itl-update-workflow.md", "itl-verify-fix.md") | Sort-Object)
            $branchKiloCommands | Should -Not -Contain "itl-new-config-branch.md"
            $branchKiloCommands | Should -Not -Contain "itl-new-extension-branch.md"
            $launcherText = Get-Content -Encoding UTF8 -Raw (Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i")
            $launcherText | Should -Match ("(?m)^\[{0}\]\r?$" -f [regex]::Escape($expectedLauncherName))
            $launcherText | Should -Match ("(?m)^Folder={0}\r?$" -f [regex]::Escape($expectedLauncherFolder))
            $launcherText | Should -Not -Match "(?m)^Folder=/ITL/fixture-branch\r?$"

            $statusOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action status 2>&1
            $LASTEXITCODE | Should -Be 0
            $statusText = $statusOutput -join [Environment]::NewLine
            $statusText | Should -Match "Active development worktrees: 1"
            $statusText | Should -Match "ITL on-demand MCP facade: ready"
            $statusText | Should -Match "ITL on-demand MCP backend instances: 0"

            $listOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action list-dev-branches 2>&1
            $LASTEXITCODE | Should -Be 0
            $listText = $listOutput -join [Environment]::NewLine
            $listText | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($worktreePath)))
            $listText | Should -Match "ROCTUP MCP: stopped"
            $listText | Should -Match "Vanessa UI MCP: stopped"

            $switchOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action switch-dev-branch -DevBranchName "Fixture Branch" 2>&1
            $LASTEXITCODE | Should -Be 0
            ($switchOutput -join [Environment]::NewLine) | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($worktreePath)))
            ((& git -C $tempRoot branch --show-current).Trim()) | Should -Be "master"

            $duplicateResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Fixture Branch", "-AgentTarget", "kilocode")
            $duplicateResult.exitCode | Should -Not -Be 0
            $duplicateResult.combinedText | Should -Match "Development branch already exists: itldev/fixture-branch"
        } finally {
            $env:APPDATA = $oldAppData
            $env:ITL_ONDEMAND_MCP_INSTALL_ROOT = $oldOnDemandInstallRoot
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $tempRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $legacyWorktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $legacyWorktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $facadeFixtureRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $facadeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "resumes worktree branch initialization after the early protection resolution fails" {
        $tempRoot = New-ShortWorkflowProjectRoot
        $worktreeRoot = "$tempRoot-worktrees"
        $worktreePath = Join-Path $worktreeRoot "partial-branch"
        $sourceBase = Join-Path $tempRoot "source-base"
        $projectName = Split-Path -Leaf $tempRoot
        $oldAppData = $env:APPDATA

        try {
            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`nappdata/`n.agent-1c/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Value '{"tools":["kilocode"],"files":{}}' -Encoding UTF8
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse
            $fakePlatform = Copy-AutoUpdateToolFixture -TargetRoot $tempRoot
            $devEnv = @(
                "PLATFORM_PATH=$fakePlatform",
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=invalid",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=false",
                "VANESSA_MCP_AUTO_START=false",
                "AGENT_TOOLS=kilocode"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .ai-rules.json .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value "{}" -Encoding ASCII

            New-TestBranchSeedFixture -ProjectRoot $tempRoot -SourceInfoBasePath $sourceBase
            $env:APPDATA = Join-Path $tempRoot "appdata"
            $firstResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Partial Branch", "-DevBranchWorktreePath", $worktreePath, "-AgentTarget", "kilocode")
            $firstResult.exitCode | Should -Not -Be 0
            $firstResult.combinedText | Should -Match "Unsupported DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP value"

            $statePath = Join-Path $worktreePath ".agent-1c\dev-branches\partial-branch.json"
            (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -Be $true
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            $state.initializationStatus | Should -Be "repository-unbound"
            $state.initializationError | Should -Match "Unsupported DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP value"
            $launcherPath = Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i"
            (Test-Path -LiteralPath $launcherPath -PathType Leaf -ErrorAction SilentlyContinue) | Should -BeFalse

            $statusOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action status 2>&1
            $LASTEXITCODE | Should -Be 0
            $statusText = $statusOutput -join [Environment]::NewLine
            $statusText | Should -Match "Initialization status: repository-unbound"
            $statusText | Should -Match "Recovery: rerun new-dev-branch"

            $listOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action list-dev-branches 2>&1
            $LASTEXITCODE | Should -Be 0
            $listText = $listOutput -join [Environment]::NewLine
            $listText | Should -Match "Initialization status: repository-unbound"
            $listText | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($worktreePath)))

            foreach ($envPath in @((Join-Path $tempRoot ".dev.env"), (Join-Path $worktreePath ".dev.env"))) {
                $fixedEnv = (Get-Content -Encoding UTF8 -Raw $envPath).Replace("DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=invalid", "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip")
                Set-Content -LiteralPath $envPath -Value $fixedEnv -Encoding UTF8
            }

            $resumeResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Partial Branch", "-AgentTarget", "kilocode")
            $resumeResult.exitCode | Should -Be 0 -Because $resumeResult.combinedText
            $resumeResult.combinedText | Should -Match "Resuming development branch initialization: itldev/partial-branch"
            (Test-Path -LiteralPath "$tempRoot-partial-branch" -ErrorAction SilentlyContinue) | Should -Be $false

            $resumedState = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            $resumedState.initializationStatus | Should -Be "ready"
            $resumedState.initializationError | Should -Be ""
            $resumedState.unsafeActionProtectionSetupMode | Should -Be "skip"
            $resumedState.unsafeActionProtectionResolution | Should -Be "skip"
            $expectedLauncherName = "$projectName-partial-branch"
            $launcherTextAfter = Get-Content -Encoding UTF8 -Raw $launcherPath
            ([regex]::Matches($launcherTextAfter, ("(?m)^\[{0}\]\r?$" -f [regex]::Escape($expectedLauncherName)))).Count | Should -Be 1
        } finally {
            $env:APPDATA = $oldAppData
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $tempRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $worktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $worktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "inherits complete vibecoding1c MCP selection into a sibling worktree" {
        $tempRoot = New-ShortWorkflowProjectRoot
        $legacyWorktreeRoot = "$tempRoot-worktrees"
        $worktreePath = "$tempRoot-mcp-branch"
        $sourceBase = Join-Path $tempRoot "source-base"
        $registryRoot = Join-Path $tempRoot "registry"
        $oldAppData = $env:APPDATA
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldLocalHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $sourceBase, $registryRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`nregistry/`n.agent-1c/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Value '{"tools":["kilocode"],"files":{}}' -Encoding UTF8
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse
            $fakePlatform = Copy-AutoUpdateToolFixture -TargetRoot $tempRoot
            $devEnv = @(
                "PLATFORM_PATH=$fakePlatform",
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=false",
                "VANESSA_MCP_AUTO_START=false",
                "AGENT_TOOLS=kilocode"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            $registry = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-05T00:10:00Z"
                hosts = @(
                    [ordered]@{
                        hostId = "host-a"
                        baseUrl = "http://host-a"
                        publishedAt = "2026-07-05T00:00:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade"; configurationVersion = "1.0" })
                        servers = @(
                            [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-a:18100/mcp"; health = "running"; configurationName = "Trade"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" },
                            [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-graph"; url = "http://host-a:18101/mcp"; health = "running"; configurationName = "Trade"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" }
                        )
                    }
                )
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Encoding UTF8 -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\mcp") | Out-Null
            $selection = [ordered]@{
                schemaVersion = 1
                family = "vibecoding1c"
                defaultProvider = "remote"
                remoteConfigId = "trade"
                remoteHostId = "host-a"
                localScopeDefault = "project"
                servers = @(
                    [ordered]@{ id = "code"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; hostId = "host-a"; localScope = "project" },
                    [ordered]@{ id = "graph"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; hostId = "host-a"; localScope = "project" }
                )
            }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\mcp\vibecoding1c-selection.json") -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .ai-rules.json .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-TestBranchSeedFixture -ProjectRoot $tempRoot -SourceInfoBasePath $sourceBase
            $env:APPDATA = Join-Path $tempRoot "appdata"
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action new-dev-branch -DevBranchName "MCP Branch" -McpScope project -AgentTarget kilocode *> $null
            $LASTEXITCODE | Should -Be 0

            $worktreeSelectionPath = Join-Path $worktreePath ".agent-1c\mcp\vibecoding1c-selection.json"
            (Test-Path -LiteralPath $worktreeSelectionPath -PathType Leaf) | Should -Be $true
            (Get-Content -Encoding UTF8 -Raw $worktreeSelectionPath) | Should -Match '"configId"\s*:\s*"trade"'

            $projectStatePath = Join-Path $worktreePath ".agent-1c\mcp\state.json"
            (Test-Path -LiteralPath $projectStatePath -PathType Leaf) | Should -Be $true
            $projectState = Get-Content -Encoding UTF8 -Raw $projectStatePath | ConvertFrom-Json
            $projectState.projectSlug | Should -Be (Split-Path -Leaf $worktreePath).ToLowerInvariant()
            $projectState.branchSlug | Should -Be "mcp-branch"
            (@($projectState.servers | Where-Object { $_.id -eq "code" }).Count) | Should -Be 1
            ($projectState.servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).url | Should -Be "http://host-a:18100/mcp"

            (Test-Path -LiteralPath (Join-Path $worktreePath ".codex\config.toml") -PathType Leaf -ErrorAction SilentlyContinue) | Should -BeFalse

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'1c-code-metadata-mcp'.url | Should -Be "http://host-a:18100/mcp"
            $kilo.mcp.'1c-graph-metadata-mcp'.url | Should -Be "http://host-a:18101/mcp"
            $managed = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".agent-1c\mcp\client-managed.json") | ConvertFrom-Json
            @($managed.owners.'kilocode/vibecoding1c') | Should -Contain "1c-code-metadata-mcp"
        } finally {
            $env:APPDATA = $oldAppData
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldLocalHome, "Process")
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $tempRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $legacyWorktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $legacyWorktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "warns and repairs missing BookStack MCP client config in a PM5 development worktree" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-worktree-bookstack-mcp-test-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"
        $worktreePath = Join-Path $tempRoot "branch1"
        $registryRoot = Join-Path $tempRoot "registry"
        $codexHomeConfig = Join-Path $tempRoot "codex-home\config.toml"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldLocalHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")
        $oldBookStackEnabled = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_BOOKSTACK_ENABLED", "Process")
        $oldBaseVersion = [Environment]::GetEnvironmentVariable("BASE_CONFIGURATION_VERSION", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $mainRoot, $registryRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Value ".agent-1c/mcp/`n.codex/config.toml`n.kilo/kilo.json`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Value "fixture" -Encoding ASCII
            & git -C $mainRoot init | Out-Null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            & git -C $mainRoot add .gitignore README.md
            & git -C $mainRoot commit -m init | Out-Null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b itldev/branch1 $worktreePath | Out-Null

            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot ".agent-1c\mcp"), (Join-Path $worktreePath ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $worktreePath ".agent-1c\project.json") -Encoding UTF8 -Value (@{ schemaVersion = 1; baseConfigurationVersion = "PM5"; aiRules = @{ tools = @("kilocode") } } | ConvertTo-Json -Depth 5)
            Set-Content -LiteralPath (Join-Path $worktreePath ".ai-rules.json") -Encoding UTF8 -Value '{"schemaVersion":1,"tools":["kilocode"],"files":{}}'

            $registryServers = @(
                [ordered]@{ id = "docs"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-docs"; url = "http://host-a:18000/mcp"; health = "running" },
                [ordered]@{ id = "templates"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-templates"; url = "http://host-a:18001/mcp"; health = "running" },
                [ordered]@{ id = "syntax"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-syntax"; url = "http://host-a:18002/mcp"; health = "running" },
                [ordered]@{ id = "codechecker"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-codechecker"; url = "http://host-a:18003/mcp"; health = "running" },
                [ordered]@{ id = "ssl"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-ssl"; url = "http://host-a:18004/mcp"; health = "running" },
                [ordered]@{ id = "bookstack"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "bookstack-product-docs"; url = "http://host-a:18005/mcp"; health = "running"; embeddingModel = "intfloat/multilingual-e5-base" },
                [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-a:18100/mcp"; health = "running"; configurationName = "Trade"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" },
                [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-graph"; url = "http://host-a:18101/mcp"; health = "running"; configurationName = "Trade"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" }
            )
            $registry = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-05T00:10:00Z"
                hosts = @(
                    [ordered]@{
                        hostId = "host-a"
                        baseUrl = "http://host-a"
                        publishedAt = "2026-07-05T00:00:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade"; configurationVersion = "1.0" })
                        servers = $registryServers
                    }
                )
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Encoding UTF8 -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            $selection = [ordered]@{
                schemaVersion = 1
                family = "vibecoding1c"
                defaultProvider = "remote"
                remoteConfigId = ""
                remoteHostId = ""
                localScopeDefault = "project"
                servers = @(
                    "docs",
                    "templates",
                    "syntax",
                    "codechecker",
                    "ssl",
                    "bookstack"
                ) | ForEach-Object {
                    [ordered]@{ id = $_; family = "vibecoding1c"; provider = "remote"; configId = ""; hostId = "host-a"; localScope = "project" }
                }
            }
            $selection.servers += [ordered]@{ id = "code"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; hostId = "host-a"; localScope = "project" }
            $selection.servers += [ordered]@{ id = "graph"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; hostId = "host-a"; localScope = "project" }
            Set-Content -LiteralPath (Join-Path $mainRoot ".agent-1c\mcp\vibecoding1c-selection.json") -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_BOOKSTACK_ENABLED", "true", "Process")
            [Environment]::SetEnvironmentVariable("BASE_CONFIGURATION_VERSION", $null, "Process")

            $statusOutput = & {
                . $HelperPath -ProjectRoot $worktreePath -Action help *> $null
                $script:TestCodexHomeConfigPath = $codexHomeConfig
                function Get-Vibecoding1cMcpCodexHomeConfigPath {
                    return $script:TestCodexHomeConfigPath
                }
                Show-Vibecoding1cMcpStatus
            } *>&1
            $statusText = $statusOutput -join [Environment]::NewLine
            $statusText | Should -Match "WARNING: PM5 product documentation MCP is selected in the main worktree"
            $statusText | Should -Match "BookStack-product-docs-mcp"
            $statusText | Should -Match "vibecoding1c-mcp-setup"

            & {
                . $HelperPath -ProjectRoot $worktreePath -Action help -AgentTarget kilocode *> $null
                $script:TestCodexHomeConfigPath = $codexHomeConfig
                function Get-Vibecoding1cMcpCodexHomeConfigPath {
                    return $script:TestCodexHomeConfigPath
                }
                Setup-Vibecoding1cMcp *> $null
            }

            (Test-Path -LiteralPath (Join-Path $worktreePath ".agent-1c\mcp\vibecoding1c-selection.json") -PathType Leaf) | Should -BeTrue
            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'BookStack-product-docs-mcp'.url | Should -Be "http://host-a:18005/mcp"
            $managed = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".agent-1c\mcp\client-managed.json") | ConvertFrom-Json
            @($managed.owners.'kilocode/vibecoding1c') | Should -Contain "BookStack-product-docs-mcp"
            (Test-Path -LiteralPath $codexHomeConfig -PathType Leaf -ErrorAction SilentlyContinue) | Should -BeFalse
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldLocalHome, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_BOOKSTACK_ENABLED", $oldBookStackEnabled, "Process")
            [Environment]::SetEnvironmentVariable("BASE_CONFIGURATION_VERSION", $oldBaseVersion, "Process")
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $mainRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps the legacy checkout mode when UseCurrentWorktree is explicit" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-legacy-branch-test-" + [guid]::NewGuid().ToString("N"))
        $sourceBase = Join-Path $tempRoot "source-base"
        $oldAppData = $env:APPDATA

        try {
            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`n.agent-1c/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Value '{"tools":["kilocode"],"files":{}}' -Encoding UTF8
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse
            $fakePlatform = Copy-AutoUpdateToolFixture -TargetRoot $tempRoot
            $devEnv = @(
                "PLATFORM_PATH=$fakePlatform",
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=false",
                "VANESSA_MCP_AUTO_START=false",
                "AGENT_TOOLS=kilocode"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .ai-rules.json .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-TestBranchSeedFixture -ProjectRoot $tempRoot -SourceInfoBasePath $sourceBase
            $env:APPDATA = Join-Path $tempRoot "appdata"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action new-dev-branch -DevBranchName "Legacy Branch" -UseCurrentWorktree -AgentTarget kilocode *> $null
            $LASTEXITCODE | Should -Be 0

            ((& git -C $tempRoot branch --show-current).Trim()) | Should -Be "itldev/legacy-branch"
            $legacyWorktreeRoot = Join-Path (Split-Path -Parent $tempRoot) ((Split-Path -Leaf $tempRoot) + "-worktrees")
            (Test-Path -LiteralPath $legacyWorktreeRoot -PathType Container -ErrorAction SilentlyContinue) | Should -Be $false
            $statePath = Join-Path $tempRoot ".agent-1c\dev-branches\legacy-branch.json"
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            $state.publicationStatus | Should -Be "disabled"
            $state.publicationMode | Should -Be "none"
            (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -Be $true
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            ([bool]$state.createdWithWorktree) | Should -Be $false
            $state.worktreePath | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
            $state.mainWorktreePath | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
        } finally {
            $env:APPDATA = $oldAppData
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "separates local dev commands from Kilo primary-checkout inheritance" {
        $mainRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-kilo-primary-" + [guid]::NewGuid().ToString("N"))
        $worktreeRoot = $mainRoot + "-worktree"
        try {
            New-Item -ItemType Directory -Force -Path $mainRoot, (Join-Path $mainRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding ASCII -Value ".kilo/"
            Set-Content -LiteralPath (Join-Path $mainRoot ".agent-1c\project.json") -Encoding ASCII -Value '{"aiRules":{"tools":["kilocode"]}}'
            & git -C $mainRoot init | Out-Null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            & git -C $mainRoot add .gitignore .agent-1c/project.json
            & git -C $mainRoot commit -m init | Out-Null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b itldev/branch1 $worktreeRoot | Out-Null

            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot ".kilo\commands"), (Join-Path $worktreeRoot ".kilo\commands") | Out-Null
            Set-Content -LiteralPath (Join-Path $mainRoot ".kilo\commands\itl.md") -Encoding ASCII -Value "common"
            Set-Content -LiteralPath (Join-Path $mainRoot ".kilo\commands\itl-update-workflow.md") -Encoding ASCII -Value "master"
            Set-Content -LiteralPath (Join-Path $worktreeRoot ".kilo\commands\itl.md") -Encoding ASCII -Value "common"
            Set-Content -LiteralPath (Join-Path $worktreeRoot ".kilo\commands\itl-check.md") -Encoding ASCII -Value "dev"

            $result = & {
                . $HelperPath -ProjectRoot $worktreeRoot -Action help *> $null
                @(Get-KiloInheritedPrimaryItlCommands)
            }
            $result | Should -BeNullOrEmpty

            $helpResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                "-ProjectRoot", $worktreeRoot,
                "-Action", "help"
            )
            $helpResult.exitCode | Should -Be 0
            $helpResult.combinedText | Should -Match "Команды ITL в этом контексте"
            $helpResult.combinedText | Should -Match "/itl-update-workflow"
        } finally {
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & git -C $mainRoot worktree remove --force --force $worktreeRoot *> $null
                & git -C $mainRoot worktree prune *> $null
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            Remove-Item -LiteralPath $mainRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $worktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves fresh project templates through merge and current-helper ignored hydration' -Tag 'FreshMutableTemplateHydration' {
        $fixtureRoot = Join-Path $TestDrive 'Fresh hydration Проект'
        $mainRoot = Join-Path $fixtureRoot 'Главная папка'
        $branchRoot = Join-Path $fixtureRoot 'Ветка develop golden'
        $utf8 = [Text.UTF8Encoding]::new($false)
        $utf8Bom = [Text.UTF8Encoding]::new($true)
        $envNames = @('UI_TESTING','ITL_VANESSA_TESTING','USER_SENTINEL','ONEC_MAX_CONCURRENT_SESSIONS',
            'INFOBASE_KIND','INFOBASE_PATH','INFOBASE_PUBLISH_URL','EXPORT_PATH','EXTENSION_NAME',
            'ITL_ACTIVE_DEV_BRANCH','ITL_ACTIVE_DEV_BRANCH_KIND','ITL_ACTIVE_CONTEXT_UPDATED_AT',
            'VANESSA_TEST_PORT','VANESSA_MCP_PORT','VANESSA_MCP_URL','ROCTUP_MCP_PORT','ROCTUP_MCP_URL','ROCTUP_MCP_HEALTH_URL')
        $savedEnv = @{}
        foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot '.agent-1c'),(Join-Path $mainRoot '.kilo/skills/runtime') | Out-Null
            [IO.File]::WriteAllText((Join-Path $mainRoot '.gitignore'), ".dev.env`n.agent-1c/migrations/`n.kilo/skills/runtime/package.json`n", $utf8)
            [IO.File]::WriteAllText((Join-Path $mainRoot '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode"]},"exportPath":"src/cf"}', $utf8)
            Copy-Item -LiteralPath (Join-Path $RepoRoot 'templates/dependency-lock.json') -Destination (Join-Path $mainRoot '.agent-1c/dependency-lock.json')
            $envPath = Join-Path $mainRoot '.dev.env'
            [IO.File]::WriteAllText($envPath, "ITL_VANESSA_TESTING=auto`r`nUSER_SENTINEL=Кириллица с пробелом`r`nINFOBASE_KIND=file`r`nONEC_MAX_CONCURRENT_SESSIONS=3`r`n", $utf8Bom)
            $envBaseline = (Get-FileHash -LiteralPath $envPath).Hash.ToLowerInvariant()
            $userPath = Join-Path $mainRoot 'USER-RULES.md'
            [IO.File]::WriteAllText($userPath, "# User Rules`r`n", $utf8)
            $userBaseline = (Get-FileHash -LiteralPath $userPath).Hash.ToLowerInvariant()
            $runtimePath = Join-Path $mainRoot '.kilo/skills/runtime/package.json'
            [IO.File]::WriteAllText($runtimePath, "{}`n", $utf8)
            $manifest = [ordered]@{version='itl-main-c1fb8e6-r41';tools=@('kilocode');files=[ordered]@{
                '.dev.env' = @{source='.dev.env.example';template=$true;installedHash=$envBaseline}
                'USER-RULES.md' = @{source='USER-RULES.md';template=$true;installedHash=$userBaseline}
                '.kilo/skills/runtime/package.json' = @{source='content/runtime/package.json';installedHash=(Get-FileHash -LiteralPath $runtimePath).Hash.ToLowerInvariant()}
            }}
            [IO.File]::WriteAllText((Join-Path $mainRoot '.ai-rules.json'), ($manifest | ConvertTo-Json -Depth 8), $utf8)
            & git -C $mainRoot init -q -b master; $LASTEXITCODE | Should -Be 0
            & git -C $mainRoot config user.name 'Fresh template fixture'
            & git -C $mainRoot config user.email 'fixture@example.invalid'
            & git -C $mainRoot add --all; $LASTEXITCODE | Should -Be 0
            & git -C $mainRoot commit -qm baseline; $LASTEXITCODE | Should -Be 0
            $policy = & {
                . $HelperPath -ProjectRoot $mainRoot -Action help *> $null
                Invoke-UiTestingPolicyTransition -NewScope
            }
            $policy.beforeSha256 | Should -Be $envBaseline
            $policy.afterValue | Should -Be 'essential'
            $policy.converted | Should -BeTrue
            & git -C $mainRoot worktree add -q -b itldev/develop-golden $branchRoot master; $LASTEXITCODE | Should -Be 0
            & {
                . $HelperPath -ProjectRoot $mainRoot -Action help *> $null
                Copy-DotEnvToWorktree -WorktreePath $branchRoot
            }
            $inherited = Get-Content -LiteralPath (Join-Path $branchRoot '.agent-1c/migrations/ui-testing-essential-v1.json') -Raw | ConvertFrom-Json
            $inherited.eligibility | Should -Be 'inherited-completed-policy'
            $inherited.afterSha256 | Should -Be $policy.afterSha256
            $branchUserPath = Join-Path $branchRoot 'USER-RULES.md'
            $userOverlay = "# User Rules`r`nЛокальное пользовательское правило.`r`n<!-- ITL-WORKFLOW-USER-RULES:BEGIN -->`r`nKeep strict verification.`r`n<!-- ITL-WORKFLOW-USER-RULES:END -->`r`n"
            [IO.File]::WriteAllText($branchUserPath, $userOverlay, $utf8)
            & git -C $branchRoot add -- USER-RULES.md; $LASTEXITCODE | Should -Be 0
            & git -C $branchRoot commit -qm 'branch user overlay'; $LASTEXITCODE | Should -Be 0
            $state = [pscustomobject]@{mainWorktreePath=$mainRoot;devBranch='itldev/develop-golden';infoBaseKind='file';devBranchInfoBasePath=(Join-Path $branchRoot '.agent-1c/infobases/dev-branches/develop-golden')}
            & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                Sync-DevBranchContextToDotEnv -State $state
            }
            [IO.File]::WriteAllText((Join-Path $mainRoot 'develop-journey.txt'), "refresh boundary`n", $utf8)
            & git -C $mainRoot add -- develop-journey.txt; $LASTEXITCODE | Should -Be 0
            & git -C $mainRoot commit -qm 'advance fresh master'; $LASTEXITCODE | Should -Be 0
            $target = (& git -C $mainRoot rev-parse HEAD).Trim()
            & git -C $branchRoot merge --no-ff --no-edit $target; $LASTEXITCODE | Should -Be 0
            $mergeHead = (& git -C $branchRoot rev-parse HEAD).Trim()
            $parents = ((& git -C $branchRoot rev-list --parents -n 1 HEAD) -join '').Split(' ')
            $parents.Count | Should -Be 3
            $parents[2] | Should -Be $target
            $branchEnvPath = Join-Path $branchRoot '.dev.env'
            $branchManifestPath = Join-Path $branchRoot '.ai-rules.json'
            $manifestBefore = [IO.File]::ReadAllBytes($branchManifestPath)
            $userBefore = [IO.File]::ReadAllBytes($branchUserPath)
            Test-Path -LiteralPath (Join-Path $branchRoot '.kilo/skills/runtime/package.json') | Should -BeFalse
            # The actual refresh resumes after merge through the current helper,
            # which activates branch context before restoring ignored rules.
            $continuation = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                Sync-DevBranchContextToDotEnv -State $state
                $before = [IO.File]::ReadAllBytes($branchEnvPath)
                $failure = ''
                try { $copied = Sync-AiRules1cManagedIgnoredFilesFromMain -State $state } catch { $failure = $_.Exception.Message; $copied = -1 }
                [pscustomobject]@{error=$failure;copied=$copied;before=$before;after=[IO.File]::ReadAllBytes($branchEnvPath)}
            }
            $continuation.after | Should -Be $continuation.before
            [IO.File]::ReadAllBytes($branchUserPath) | Should -Be $userBefore
            [IO.File]::ReadAllBytes($branchManifestPath) | Should -Be $manifestBefore
            $envText = [IO.File]::ReadAllText($branchEnvPath)
            $envText | Should -Match '(?m)^USER_SENTINEL=Кириллица с пробелом\r?$'
            $envText | Should -Match '(?m)^UI_TESTING=essential\r?$'
            $envText | Should -Match '(?m)^ITL_ACTIVE_DEV_BRANCH=itldev/develop-golden\r?$'
            $continuation.after[0..2] | Should -Be ([byte[]]@(239,187,191))
            $continuation.error | Should -BeNullOrEmpty
            $continuation.copied | Should -Be 1
            [IO.File]::ReadAllBytes((Join-Path $branchRoot '.kilo/skills/runtime/package.json')) | Should -Be ([IO.File]::ReadAllBytes($runtimePath))
            ((& git -C $branchRoot rev-parse HEAD) -join '').Trim() | Should -Be $mergeHead
        } finally {
            foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process') }
        }
    }

    It 'does not exempt an edited ignored validator with an arbitrary template flag' -Tag 'FreshMutableTemplateHydration' {
        $mainRoot = Join-Path $TestDrive 'Template guard Главная папка'
        $branchRoot = Join-Path $TestDrive 'Template guard Ветка с пробелом'
        $utf8 = [Text.UTF8Encoding]::new($false)
        $relative = '.kilo/skills/runtime/validator.ps1'
        foreach ($root in @($mainRoot,$branchRoot)) { New-Item -ItemType Directory -Force -Path (Join-Path $root '.kilo/skills/runtime') | Out-Null }
        $source = Join-Path $mainRoot $relative
        $target = Join-Path $branchRoot $relative
        [IO.File]::WriteAllText($source, 'Write-Output original', $utf8)
        [IO.File]::WriteAllText($target, 'Write-Output modified', $utf8)
        $manifest = @{version='same';files=@{$relative=@{source='content/runtime/validator.ps1';template=$true;installedHash=(Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()}}}
        foreach ($root in @($mainRoot,$branchRoot)) { [IO.File]::WriteAllText((Join-Path $root '.ai-rules.json'), ($manifest | ConvertTo-Json -Depth 8), $utf8) }
        $before = [IO.File]::ReadAllBytes($target)
        {
            & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{mainWorktreePath=$mainRoot})
            }
        } | Should -Throw '*AI_RULES_MANAGED_IGNORED_USER_MODIFIED*'
        [IO.File]::ReadAllBytes($target) | Should -Be $before
    }

    It "restores missing ignored rules only from matching bytes and preserves modified branch files" {
        $mainRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-ignored-main-" + [guid]::NewGuid().ToString("N"))
        $branchRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-ignored-branch-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot ".kilo\skills\runtime") | Out-Null
            & git -C $mainRoot init | Out-Null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding UTF8 -Value ".kilo/skills/runtime/package.json"
            $runtimePath = Join-Path $mainRoot ".kilo\skills\runtime\package.json"
            [IO.File]::WriteAllText($runtimePath, "{}`n", (New-Object Text.UTF8Encoding $false))
            $runtimeHash = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [ordered]@{ version = "itl-main-410951e7-r24"; tools = @("kilocode"); files = [ordered]@{
                ".kilo/skills/runtime/package.json" = [ordered]@{ source = "runtime"; installedHash = $runtimeHash }
            } }
            Set-Content -LiteralPath (Join-Path $mainRoot ".ai-rules.json") -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 8)
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Encoding UTF8 -Value "fixture"
            & git -C $mainRoot add .gitignore .ai-rules.json README.md
            & git -C $mainRoot commit -m init | Out-Null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b itldev/test $branchRoot master | Out-Null

            # A refresh has already selected target A and stopped at a
            # business conflict. Moving master to package B must not change
            # the branch's selected merge target or its rule bytes.
            Set-Content -LiteralPath (Join-Path $branchRoot 'README.md') -Encoding UTF8 -Value 'branch work'
            & git -C $branchRoot add -- README.md
            & git -C $branchRoot commit -m 'branch business work' | Out-Null
            Set-Content -LiteralPath (Join-Path $mainRoot 'README.md') -Encoding UTF8 -Value 'master target A'
            & git -C $mainRoot add -- README.md
            & git -C $mainRoot commit -m 'refresh target A' | Out-Null
            $refreshTargetA = ((& git -C $mainRoot rev-parse HEAD) -join '').Trim()
            & git -C $branchRoot merge --no-edit master *> $null
            $LASTEXITCODE | Should -Not -Be 0
            ((& git -C $branchRoot rev-parse MERGE_HEAD) -join '').Trim() | Should -Be $refreshTargetA

            $result = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{ mainWorktreePath = $mainRoot })
            }
            $result | Should -Be 1
            $branchRuntimePath = Join-Path $branchRoot ".kilo\skills\runtime\package.json"
            [IO.File]::ReadAllBytes($branchRuntimePath) | Should -Be ([IO.File]::ReadAllBytes($runtimePath))

            [IO.File]::WriteAllText($branchRuntimePath, "{`"stale`":true}`n", (New-Object Text.UTF8Encoding $false))
            {
                & {
                    . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                    Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{ mainWorktreePath = $mainRoot })
                }
            } | Should -Throw "*AI_RULES_MANAGED_IGNORED_USER_MODIFIED*"
            [IO.File]::ReadAllText($branchRuntimePath) | Should -Be "{`"stale`":true}`n"

            Remove-Item -LiteralPath $branchRuntimePath -Force
            [IO.File]::WriteAllText($runtimePath, "{`"changed`":true}`n", (New-Object Text.UTF8Encoding $false))
            {
                & {
                    . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                    Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{ mainWorktreePath = $mainRoot })
                }
            } | Should -Throw "*AI_RULES_MANAGED_IGNORED_IMMUTABLE_SOURCE_UNAVAILABLE*"
            Test-Path -LiteralPath $branchRuntimePath | Should -BeFalse

            $forkRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-ignored-pinned-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path (Join-Path $forkRoot "content\runtime") | Out-Null
            $forkSource = Join-Path $forkRoot "content\runtime\package.json"
            [IO.File]::WriteAllText($forkSource, "{}`n", (New-Object Text.UTF8Encoding $false))
            $branchManifestPath = Join-Path $branchRoot ".ai-rules.json"
            $branchManifest = Get-Content -LiteralPath $branchManifestPath -Raw | ConvertFrom-Json
            $branchManifest.files.'.kilo/skills/runtime/package.json'.source = "content/runtime/package.json"
            Set-Content -LiteralPath $branchManifestPath -Encoding UTF8 -Value ($branchManifest | ConvertTo-Json -Depth 8)
            $mainManifest = Get-Content -LiteralPath (Join-Path $mainRoot ".ai-rules.json") -Raw | ConvertFrom-Json
            $mainManifest.version = "itl-main-410951e7-r25"
            Set-Content -LiteralPath (Join-Path $mainRoot ".ai-rules.json") -Encoding UTF8 -Value ($mainManifest | ConvertTo-Json -Depth 8)
            & git -C $mainRoot add -- .ai-rules.json
            & git -C $mainRoot commit -m 'workflow package B' | Out-Null
            ((& git -C $mainRoot rev-parse HEAD) -join '').Trim() | Should -Not -Be $refreshTargetA
            $branchPinCommit = '1111111111111111111111111111111111111111'
            {
                & {
                    . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                    function Get-DependencyLockEntry { param([string]$Name); $null }
                    Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{ mainWorktreePath = $mainRoot })
                }
            } | Should -Throw '*AI_RULES_MANAGED_IGNORED_PIN_MISMATCH*'
            Test-Path -LiteralPath $branchRuntimePath | Should -BeFalse
            {
                & {
                    . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                    function Get-DependencyLockEntry { param([string]$Name); [pscustomobject]@{ repo='https://github.com/xmentosx/itl_ai_rules_1c.git'; ref='itl-main-410951e7-r24'; commit=$branchPinCommit } }
                    function Sync-AiRules1cCheckout { param([string]$RepoOverride,[string]$RefOverride,[string]$CommitOverride); [pscustomobject]@{ root = $forkRoot; ref = "itl-main-410951e7-r25"; commit=$branchPinCommit } }
                    Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{ mainWorktreePath = $mainRoot })
                }
            } | Should -Throw "*AI_RULES_MANAGED_IGNORED_SOURCE_VERSION_MISMATCH*"
            Test-Path -LiteralPath $branchRuntimePath | Should -BeFalse

            $resultFromPinned = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                function Get-DependencyLockEntry { param([string]$Name); [pscustomobject]@{ repo='https://github.com/xmentosx/itl_ai_rules_1c.git'; ref='itl-main-410951e7-r24'; commit=$branchPinCommit } }
                function Sync-AiRules1cCheckout {
                    param([string]$RepoOverride,[string]$RefOverride,[string]$CommitOverride)
                    $script:requestedBranchPin = [pscustomobject]@{repo=$RepoOverride;ref=$RefOverride;commit=$CommitOverride}
                    [pscustomobject]@{ root = $forkRoot; ref = "itl-main-410951e7-r24"; commit=$branchPinCommit }
                }
                $copied = Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{ mainWorktreePath = $mainRoot })
                [pscustomobject]@{copied=$copied; requestedPin=$script:requestedBranchPin}
            }
            $resultFromPinned.copied | Should -Be 1
            $resultFromPinned.requestedPin.ref | Should -Be 'itl-main-410951e7-r24'
            $resultFromPinned.requestedPin.commit | Should -Be $branchPinCommit
            [IO.File]::ReadAllBytes($branchRuntimePath) | Should -Be ([IO.File]::ReadAllBytes($forkSource))
            ((& git -C $branchRoot rev-parse MERGE_HEAD) -join '').Trim() | Should -Be $refreshTargetA
            @(& git -C $branchRoot diff --name-only --diff-filter=U) | Should -Contain 'README.md'

            $forkBRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-ignored-pinned-b-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path (Join-Path $forkBRoot 'content/runtime') | Out-Null
            $forkBSource = Join-Path $forkBRoot 'content/runtime/package.json'
            [IO.File]::WriteAllText($forkBSource, "{`"package`":`"B`"}`n", [Text.UTF8Encoding]::new($false))
            $newHash = (Get-FileHash -LiteralPath $forkBSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $branchManifest.version = 'itl-main-410951e7-r25'
            $branchManifest.files.'.kilo/skills/runtime/package.json'.installedHash = $newHash
            Set-Content -LiteralPath $branchManifestPath -Encoding UTF8 -Value ($branchManifest | ConvertTo-Json -Depth 8)
            $branchLockPath = Join-Path $branchRoot '.agent-1c/dependency-lock.json'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $branchLockPath) | Out-Null
            $branchPinB = '2222222222222222222222222222222222222222'
            [IO.File]::WriteAllText($branchLockPath, ('{"dependencies":{"aiRules1c":{"repo":"https://github.com/xmentosx/itl_ai_rules_1c.git","ref":"itl-main-410951e7-r25","commit":"' + $branchPinB + '"}}}'), [Text.UTF8Encoding]::new($false))
            $pendingState = [pscustomobject]@{
                safeDevBranchName = 'test'; devBranchName = 'test'; devBranch = 'itldev/test'
                stateProjectRoot = $branchRoot; devBranchInfoBasePath = ''
                pendingMergeOperation = 'refresh-dev-branch'; pendingMergeBranch = 'itldev/test'
                pendingMergeBranchCommit = ((& git -C $branchRoot rev-parse HEAD) -join '').Trim()
                pendingMergeTargetCommit = $refreshTargetA; pendingMergeStage = 'conflicts'
                pendingMergePaths = @('README.md'); pendingMergeConflictPaths = @('README.md')
            }
            $workflowCommit = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                $plan = New-WorkflowBranchCommitPlan -ManagedPathSpecs @('.ai-rules.json', '.agent-1c/dependency-lock.json')
                (Apply-WorkflowBranchCommitPlan -Plan $plan -PendingMergeState $pendingState).commit
            }
            ((& git -C $branchRoot rev-parse HEAD) -join '').Trim() | Should -Be $workflowCommit
            ((& git -C $branchRoot rev-parse MERGE_HEAD) -join '').Trim() | Should -Be $refreshTargetA
            Remove-Item -LiteralPath $branchRuntimePath -Force
            $restoredB = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                function Sync-AiRules1cCheckout {
                    param([string]$RepoOverride,[string]$RefOverride,[string]$CommitOverride)
                    [pscustomobject]@{ root=$forkBRoot; ref='itl-main-410951e7-r25'; commit=$branchPinB }
                }
                Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{ mainWorktreePath=$mainRoot })
            }
            $restoredB | Should -Be 1
            [IO.File]::ReadAllBytes($branchRuntimePath) | Should -Be ([IO.File]::ReadAllBytes($forkBSource))
            Set-Content -LiteralPath (Join-Path $branchRoot 'README.md') -Encoding UTF8 -Value 'resolved business A'
            & git -C $branchRoot add -- README.md
            & git -C $branchRoot commit --quiet --no-edit
            $LASTEXITCODE | Should -Be 0
            $mergeParents = @((& git -C $branchRoot rev-list --parents -n 1 HEAD) -split ' ')
            $mergeParents[1] | Should -Be $workflowCommit
            $mergeParents[2] | Should -Be $refreshTargetA
        } finally {
            $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            foreach ($cleanupRoot in @($mainRoot, $branchRoot, $forkRoot, $forkBRoot) | Where-Object { $_ }) {
                $resolvedCleanupRoot = [IO.Path]::GetFullPath($cleanupRoot)
                if (-not $resolvedCleanupRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                    (Split-Path -Leaf $resolvedCleanupRoot) -notmatch '^itl-ai-ignored-(main|branch|pinned|pinned-b)-[0-9a-f]{32}$') {
                    throw "Unexpected ignored-rules canary cleanup target: $resolvedCleanupRoot"
                }
            }
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try { & git -C $mainRoot worktree remove --force $branchRoot *> $null } finally { $ErrorActionPreference = $previousPreference }
            Remove-Item -LiteralPath $branchRoot, $mainRoot -Recurse -Force -ErrorAction SilentlyContinue
            if ($forkRoot) { Remove-Item -LiteralPath $forkRoot -Recurse -Force -ErrorAction SilentlyContinue }
            if ($forkBRoot) { Remove-Item -LiteralPath $forkBRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "rejects every master-only action from itldev before changing tracked state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-master-action-guard-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "sentinel.txt") -Encoding ASCII -Value "unchanged"
            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add sentinel.txt
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot checkout -b itldev/current | Out-Null
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()

            foreach ($case in @(
                @{ action = "update-workflow"; extra = @() },
                @{ action = "new-dev-branch"; extra = @("-DevBranchName", "other") },
                @{ action = "new-extension-dev-branch"; extra = @("-DevBranchName", "other-extension") }
            )) {
                $result = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments (@("-ProjectRoot", $tempRoot, "-Action", $case.action) + $case.extra)
                $result.exitCode | Should -Not -Be 0
                $result.combinedText | Should -Match "master"
                ((& git -C $tempRoot rev-parse HEAD) -join "").Trim() | Should -Be $beforeCommit
                @(& git -C $tempRoot status --porcelain) | Should -BeNullOrEmpty
                (Get-Content -LiteralPath (Join-Path $tempRoot "sentinel.txt") -Raw -Encoding ASCII).Trim() | Should -Be "unchanged"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "finishes classification with the original full refresh facts without rerunning 1C" {
        $root = Join-Path $TestDrive 'Отчёт ветки с пробелами'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $result = & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            function Get-Vibecoding1cMcpStatusSummary { [pscustomobject]@{ active=@('remote/remote'); skipped=@(); staleServers=@(); missingConfigId=@() } }
            function Get-ItlActiveClient { 'codex' }
            function Get-KiloBrowserAutomationDisplay { $null }
            $fixtureState = [pscustomobject]@{ devBranch='itldev/report'; worktreePath=$root; mainWorktreePath='C:\Главный проект'
                devBranchInfoBasePath=(Join-Path $root 'База'); devBranchKind='configuration'; lastRefreshAt='2026-09-26T12:00:00'
                lastRefreshMode='lite'; lastRefreshMasterCommit='master-sha'; lastConfigBaseUpdatedCommit='branch-sha'
                verificationClassificationStatus='required'; roctupMcpStatus='stopped'; vanessaMcpStatus='stopped'; secret='must-not-persist' }
            $load = [pscustomobject]@{ loaded=$true; enterpriseInvoked=$true; loadModeUsed='partial'; currentCommit='branch-sha'; password='must-not-persist' }
            $script:RunRequiredAction = 'classify-tests-after-refresh: fixture; then also follow: MCP reload fixture'
            $script:ResolvedRunStatusPath = Join-Path $root 'original-status.json'
            Write-DevBranchRunUserReport -State $fixtureState -AdvisoryRoot $root -Operation refreshed -LoadResult $load
            $originalReport = $script:RunUserReport
            Write-Vibecoding1cMcpJsonFile -Path $script:ResolvedRunStatusPath -Value @{ status='succeeded'; action='refresh-dev-branch-lite'; projectRoot=$root; userReport=$originalReport }
            Save-RefreshClassificationReportContext -State $fixtureState -LoadResult $load
            $contextPath = Join-Path (Get-VerificationSelectionStateRoot) 'refresh-report-context.json'
            $savedContext = Read-Utf8Text -Path $contextPath
            $sourceHash = (Get-FileHash $script:ResolvedRunStatusPath).Hash
            $inventoryFixture = [pscustomobject]@{ featureCount=3; yaxunit=@{ moduleCount=2 } }
            function Set-RunStage { param($Stage,$Detail) }
            function Assert-VerificationClassificationReady { param($Reason,[switch]$RequireVanessa,[switch]$RequireYAxUnit) $inventoryFixture }
            function Assert-VerificationScenarioMigrationPreserved { param($Inventory) }
            function Read-DevBranchState { param($Name) $fixtureState }
            function Update-DevBranchState { param($State,$Updates) }
            function Invoke-Enterprise { throw 'Report must not launch 1C' }
            function Invoke-Designer { throw 'Report must not launch 1C' }
            Test-VerificationClassification | Out-Null
            $completed = $script:RunUserReport
            $completedAction = $script:RunRequiredAction
            $unchanged = $sourceHash -eq (Get-FileHash $script:ResolvedRunStatusPath).Hash
            $fixtureState.lastRefreshAt = 'later-refresh'
            Test-VerificationClassification 3>$null | Out-Null
            $stale = $script:RunUserReport
            Write-Utf8Text -Path $contextPath -Value '{broken'
            Test-VerificationClassification 3>$null | Out-Null
            [pscustomobject]@{ original=$originalReport; completed=$completed; action=$completedAction; unchanged=$unchanged; context=$savedContext; stale=$stale; broken=$script:RunUserReport }
        }
        $result.original | Should -Match 'требуется до завершения задачи refresh'
        $result.completed | Should -Match '## Обновление ветки разработки'
        $result.completed | Should -Match 'Обновление конфигурации базы: выполнено'
        $result.completed | Should -Match 'Режим загрузки: частичная загрузка'
        $result.completed | Should -Match 'Enterprise-автообновление: выполнено'
        $result.completed | Should -Match 'Классификация тестов: готова'
        $result.completed | Should -Match '## MCP'
        $result.completed | Should -Match '## Инструкции и рекомендации'
        $result.completed | Should -Match 'MCP reload fixture'
        $result.completed | Should -Match '/itl-check'
        $result.completed | Should -Match 'не является проверкой BSL'
        $result.completed | Should -Not -Match 'classify-tests-after-refresh|требуется до завершения'
        $result.action | Should -Be 'MCP reload fixture'
        $result.unchanged | Should -BeTrue
        $result.context | Should -Not -Match 'must-not-persist|password|secret'
        foreach ($fallback in @($result.stale,$result.broken)) {
            $fallback | Should -Match 'Классификация завершена'
            $fallback | Should -Match 'Исходный отчёт refresh недоступен'
            $fallback | Should -Not -Match 'Обновление конфигурации базы:|Результат: успешно'
        }
    }

    It "announces remote owner changes without losing an existing continuation" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { 'codex' }
            $script:RunRequiredAction = 'existing continuation'
            $script:ItlClientMcpSemanticChanges = [ordered]@{}
            Register-ItlClientMcpSemanticChange -Client codex -Owner vibecoding1c -Path 'fixture.toml'
            Set-ItlOnDemandMcpSemanticReloadRequiredAction -Operation 'refresh-dev-branch' | Out-Null
            $script:RunRequiredAction
        }
        $result | Should -Match '^existing continuation; '
        $result | Should -Match 'vibecoding1c'
        $result | Should -Match 'штатным механизмом клиента в текущей задаче'
        $result | Should -Not -Match 'перезапустите приложение'
    }
}
