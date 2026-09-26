Describe 'Temporary workflow patches and original-task continuation' {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.local-patch.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1')
        $LifecyclePhase = ''
        $script:DevBranchName = 'test'
        $utf8 = New-Object Text.UTF8Encoding $false
        [Console]::OutputEncoding = $utf8
        $OutputEncoding = $utf8
        function Set-FixtureText($Path, $Text) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
            [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
        }
        function New-SealedFixturePatch {
            $r = New-WorkflowPatchReceipt -Paths @($script:patchPath) -ReportPath $script:report
            Set-FixtureText $script:target "patched: Кириллица`r`n"
            Set-WorkflowPatchSealed | Out-Null
            return $r
        }
    }
    BeforeEach {
        $script:archiveRoot = Join-Path $TestDrive ('Общий архив ' + [guid]::NewGuid().ToString('N'))
        Mock Get-WorkflowFixArchiveRoot { $script:archiveRoot }
        $script:ProjectRoot = Join-Path $TestDrive ('Проект с пробелом ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ProjectRoot | Out-Null
        $script:patchPath = '.agents/skills/1c-workflow/scripts/lib/исправление тест.ps1'
        $script:target = Join-Path $script:ProjectRoot $script:patchPath
        $script:report = Join-Path $script:ProjectRoot 'handoffs/incident.md'
        Set-FixtureText $script:target "original: Кириллица`r`n"
        Set-FixtureText $script:report 'Original task, reproduced error, scoped user permission and proposed workaround.'
        Set-FixtureText (Join-Path $script:ProjectRoot '.agent-1c/project.json') '{}'
        Set-FixtureText (Join-Path $script:ProjectRoot '.agent-1c/dependency-lock.json') ('{"dependencies":{"workflowPackage":{"repo":"fixture-workflow","commit":"' + ('b'*40) + '"}}}')
        Set-FixtureText (Join-Path $script:ProjectRoot '.gitignore') ".agent-1c/snapshots/`n"
        Set-FixtureText (Join-Path $script:ProjectRoot 'product.txt') 'user product'
        Invoke-Git @('init', '-q', '-b', 'itldev/test')
        Invoke-Git @('config', 'user.email', 'fixture@example.invalid')
        Invoke-Git @('config', 'user.name', 'Patch fixture')
        Invoke-Git @('config', 'core.autocrlf', 'false')
        Invoke-Git @('add', '--', '.')
        Invoke-Git @('commit', '-qm', 'fixture baseline')
    }

    It 'captures exact Unicode bytes and retires an unstaged patch without changing product edits' {
        $r = New-SealedFixturePatch
        Set-FixtureText (Join-Path $script:ProjectRoot 'product.txt') 'user additional work'
        $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch'
        Start-WorkflowPatchRetirement $plan
        Complete-WorkflowPatchRetirement $plan
        (Read-Utf8Text $script:target) | Should -BeExactly "original: Кириллица`r`n"
        (Read-Utf8Text (Join-Path $script:ProjectRoot 'product.txt')) | Should -BeExactly 'user additional work'
        Test-Path -LiteralPath $r.reportPath | Should -BeTrue
        $archive = Join-Path (Split-Path -Parent $r.reportPath) 'patch.json'
        $saved = Read-Utf8Text $archive | ConvertFrom-Json
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($saved.files[0].after)) | Should -BeExactly "patched: Кириллица`r`n"
        Get-WorkflowPatchRetirementPlan -Operation 'update-workflow' | Should -BeNullOrEmpty
    }

    It 'does not checkpoint an uncommitted patch and leaves foreign staging unchanged' {
        New-SealedFixturePatch | Out-Null
        Invoke-Git @('add', '--', $script:patchPath)
        Set-FixtureText (Join-Path $script:ProjectRoot 'product.txt') 'staged user work'
        Invoke-Git @('add', '--', 'product.txt')
        $head = Get-CurrentCommit
        $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch-lite'
        Start-WorkflowPatchRetirement $plan
        (Get-CurrentCommit) | Should -BeExactly $head
        @(Get-GitPathList -Arguments @('diff', '--cached', '--name-only', '-z')) | Should -Be @('product.txt')
        (Get-GitOutput @('show', ':product.txt')) | Should -BeExactly 'staged user work'
    }

    It 'retires a committed patch with a corrective commit and preserves staged product work' {
        New-SealedFixturePatch | Out-Null
        Invoke-Git @('add', '--', $script:patchPath)
        Invoke-Git @('commit', '-qm', 'authorized temporary patch')
        $patchedHead = Get-CurrentCommit
        Set-FixtureText (Join-Path $script:ProjectRoot 'product.txt') 'staged user work'
        Invoke-Git @('add', '--', 'product.txt')
        $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch'
        Start-WorkflowPatchRetirement $plan
        (Get-GitOutput @('rev-parse', 'HEAD^')) | Should -BeExactly $patchedHead
        (Get-GitOutput @('log', '-1', '--format=%s')) | Should -Be 'chore: retire temporary ITL workflow patch'
        @(Get-GitPathList -Arguments @('diff', '--cached', '--name-only', '-z')) | Should -Be @('product.txt')
    }

    It 'preserves additional edits and reports the exact file instead of overwriting it' {
        New-SealedFixturePatch | Out-Null
        Set-FixtureText $script:target 'patch plus unrecorded user edit'
        { Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch' } | Should -Throw '*WORKFLOW_PATCH_ADDITIONAL_EDITS*'
        Read-Utf8Text $script:target | Should -BeExactly 'patch plus unrecorded user edit'
    }

    It 'rejects unexpected staging even when the working file matches the patch' {
        New-SealedFixturePatch | Out-Null
        Set-FixtureText $script:target 'staged foreign edit'
        Invoke-Git @('add', '--', $script:patchPath)
        Set-FixtureText $script:target "patched: Кириллица`r`n"
        { Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch' } | Should -Throw '*WORKFLOW_PATCH_GIT_DIVERGED*'
        Get-GitOutput @('show', ":$script:patchPath") | Should -BeExactly 'staged foreign edit'
    }

    It 'keeps strict update dirty guards without removing the patch first' {
        New-SealedFixturePatch | Out-Null
        Set-FixtureText (Join-Path $script:ProjectRoot 'product.txt') 'other work'
        { Get-WorkflowPatchRetirementPlan -Operation 'update-workflow' } | Should -Throw '*WORKFLOW_PATCH_UNRELATED_EDITS*'
        Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
    }

    It 'resumes retirement after an interruption between file restoration and completion' {
        New-SealedFixturePatch | Out-Null
        $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch-lite'
        Start-WorkflowPatchRetirement $plan
        $resumed = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch-lite'
        Start-WorkflowPatchRetirement $resumed
        Complete-WorkflowPatchRetirement $resumed
        Read-Utf8Text $script:target | Should -BeExactly "original: Кириллица`r`n"
    }

    It 'restores the working workaround after preparation fails without rewriting history' {
        New-SealedFixturePatch | Out-Null
        $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch'
        $head = Get-CurrentCommit
        Start-WorkflowPatchRetirement $plan
        Undo-WorkflowPatchRetirement $plan
        (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
        (Get-CurrentCommit) | Should -Be $head
        Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
    }

    It 'never reapplies old bytes over a different installed version' {
        New-SealedFixturePatch | Out-Null
        $plan = Get-WorkflowPatchRetirementPlan -Operation 'update-workflow'
        Start-WorkflowPatchRetirement $plan
        Set-FixtureText $script:target 'new installed workflow'
        { Undo-WorkflowPatchRetirement $plan } | Should -Throw '*WORKFLOW_PATCH_ROLLBACK_DIVERGED*'
        Read-Utf8Text $script:target | Should -BeExactly 'new installed workflow'
    }

    It 'does not transfer an active exception to another branch' {
        New-SealedFixturePatch | Out-Null
        Invoke-Git @('checkout', '-qb', 'itldev/other')
        { Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch' } | Should -Throw '*WORKFLOW_PATCH_SCOPE_MISMATCH*'
    }

    It 'does not modify paths outside ITL ownership or follow traversal in a receipt' {
        { New-WorkflowPatchReceipt -Paths @('product.txt') -ReportPath $script:report } | Should -Throw '*WORKFLOW_PATCH_NOT_ITL_OWNED*'
        { Resolve-WorkflowPatchPath '.agents/skills/1c-workflow/../../outside.ps1' } | Should -Throw '*WORKFLOW_PATCH_PATH_INVALID*'
        New-SealedFixturePatch | Out-Null
        $receipt = Read-WorkflowPatchReceipt
        $receipt.files[0].path = 'product.txt'
        Write-WorkflowPatchReceipt $receipt
        { Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch' } | Should -Throw '*WORKFLOW_PATCH_NOT_ITL_OWNED*'
    }

    It 'rejects damaged saved bytes before retiring any file' {
        New-SealedFixturePatch | Out-Null
        $receipt = Read-WorkflowPatchReceipt
        $receipt.files[0].before = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('tampered'))
        Write-WorkflowPatchReceipt $receipt
        { Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch' } | Should -Throw '*WORKFLOW_PATCH_SNAPSHOT_HASH_MISMATCH*'
        Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
    }

    It 'does no Git discovery when there is no incident receipt' {
        Mock Get-CurrentBranch { throw 'unexpected Git probe' }
        Mock Get-GitPathList { throw 'unexpected Git probe' }
        Mock Get-WorkflowFixArchiveRoot { throw 'unexpected archive scan' }
        Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch' | Should -BeNullOrEmpty
        Invoke-WorkflowLocalPatchStep -Step Plan -Operation 'refresh-dev-branch' -TargetCommit ('a'*40) | Should -BeNullOrEmpty
    }

    It 'extends a committed patch with another edit and file while retaining their original baselines' {
        New-SealedFixturePatch | Out-Null
        Invoke-Git @('add', '--', $script:patchPath)
        Invoke-Git @('commit', '-qm', 'first authorized patch')
        $secondPath = '.agents/skills/1c-workflow/scripts/second.ps1'
        $secondFile = Join-Path $script:ProjectRoot $secondPath
        Set-FixtureText $secondFile 'second original'
        Invoke-Git @('add', '--', $secondPath)
        Invoke-Git @('commit', '-qm', 'existing second file')
        New-WorkflowPatchReceipt -Paths @($script:patchPath, $secondPath) -ReportPath $script:report | Out-Null
        Set-FixtureText $script:target 'second authorized correction'
        Set-FixtureText $secondFile 'second patched'
        Set-WorkflowPatchSealed | Out-Null
        $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch'
        Start-WorkflowPatchRetirement $plan
        Read-Utf8Text $script:target | Should -BeExactly "original: Кириллица`r`n"
        Read-Utf8Text $secondFile | Should -BeExactly 'second original'
    }

    It 'preserves a pre-existing staged edit when the working file has been restored to HEAD' {
        Set-FixtureText $script:target 'pre-existing staged work'
        Invoke-Git @('add', '--', $script:patchPath)
        Set-FixtureText $script:target "original: Кириллица`r`n"
        { New-WorkflowPatchReceipt -Paths @($script:patchPath) -ReportPath $script:report } | Should -Throw '*WORKFLOW_PATCH_CAPTURE_NEEDS_BASELINE*'
        Get-GitOutput @('show', ":$script:patchPath") | Should -BeExactly 'pre-existing staged work'
        Read-WorkflowPatchReceipt | Should -BeNullOrEmpty
    }

    It 'captures and seals through the Windows PowerShell entrypoint with Unicode paths' {
        $entry = Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/workflow-local-patch.ps1'
        $captured = Invoke-TestPowerShellFile -FilePath $entry -Arguments @('-Action','Capture','-ProjectRoot',$script:ProjectRoot,'-Paths',$script:patchPath,'-ReportPath',$script:report)
        $captured.exitCode | Should -Be 0 -Because $captured.combinedText
        (($captured.stdout -join "`n") | ConvertFrom-Json).files[0] | Should -BeExactly $script:patchPath
        Set-FixtureText $script:target "patched: Кириллица`r`n"
        $sealed = Invoke-TestPowerShellFile -FilePath $entry -Arguments @('-Action','Seal','-ProjectRoot',$script:ProjectRoot)
        $sealed.exitCode | Should -Be 0 -Because $sealed.combinedText
        (($sealed.stdout -join "`n") | ConvertFrom-Json).phase | Should -Be 'active'
    }

    It 'preserves changes made after planning, including a foreign index on rollback' {
        New-SealedFixturePatch | Out-Null
        $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch'
        Set-FixtureText $script:target 'new staged change'
        Invoke-Git @('add', '--', $script:patchPath)
        Set-FixtureText $script:target "patched: Кириллица`r`n"
        { Start-WorkflowPatchRetirement $plan } | Should -Throw '*WORKFLOW_PATCH_CHANGED_AFTER_PLAN*'
        { Undo-WorkflowPatchRetirement $plan } | Should -Throw '*WORKFLOW_PATCH_ROLLBACK_DIVERGED*'
        Get-GitOutput @('show', ":$script:patchPath") | Should -BeExactly 'new staged change'
    }

    It 'allows ordinary work in another branch after the patch was archived' {
        New-SealedFixturePatch | Out-Null
        $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch'
        Start-WorkflowPatchRetirement $plan
        Complete-WorkflowPatchRetirement $plan
        Invoke-Git @('checkout', '-qb', 'itldev/other')
        Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch' | Should -BeNullOrEmpty
    }

    Context 'Refresh preparation and merge boundary' {
        BeforeEach {
            Invoke-Git @('branch', 'master')
            New-SealedFixturePatch | Out-Null
            Mock Read-DevBranchState { [pscustomobject]@{devBranch='itldev/test'} }
            Mock Assert-DevelopmentBranchWorktreeContext {}
            Mock Assert-DevBranchExtensionInitialized {}
            Mock Get-PendingDevBranchMergeTransaction { $null }
            Mock Sync-DevBranchContextToDotEnv {}
            Mock Complete-PendingDevBranchRefreshAfterVerifiedRecovery {}
            Mock Resume-DevBranchLifecycleMergeIfPresent { $false }
            Mock Set-RunStage {}
            Mock Ensure-GitIgnore {}
            Mock Repair-OneCSourceLineEndings {}
            Mock Get-MasterBranch { 'master' }
            Mock Assert-RefreshExpectedMasterCommit {}
            Mock Sync-Master {}
        }
        It 'restores the workaround if source synchronization fails before the merge' {
            Mock Sync-Master { throw 'SYNC_FAILED' }
            { Invoke-RefreshDevBranchCore -SynchronizeMaster -OperationName 'refresh-dev-branch' } | Should -Throw '*SYNC_FAILED*'
            Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
            (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
        }
        It 'merges incoming workflow after selecting the target and retiring the checkpointed patch' {
            # Change master through a separate worktree, as real refresh does.
            $main = Join-Path $TestDrive ('Основная ветка ' + [guid]::NewGuid().ToString('N'))
            Invoke-Git @('worktree', 'add', '--quiet', $main, 'master')
            Set-FixtureText (Join-Path $main $script:patchPath) 'official incoming fix'
            Set-FixtureText (Join-Path $main '.agent-1c/dependency-lock.json') ('{"dependencies":{"workflowPackage":{"repo":"fixture-workflow","commit":"' + ('a'*40) + '"}}}')
            Invoke-GitAt -Root $main -Arguments @('add', '--', $script:patchPath,'.agent-1c/dependency-lock.json')
            Invoke-GitAt -Root $main -Arguments @('commit', '-qm', 'official workflow update')
            Mock Invoke-NewDevBranchLifecycleMerge {
                param($State,$Operation,$TargetCommit,$ConflictStage)
                Invoke-Git @('merge', '--no-edit', $TargetCommit)
                throw 'MERGE_BOUNDARY'
            }
            { Invoke-RefreshDevBranchCore -OperationName 'refresh-dev-branch-lite' } | Should -Throw '*MERGE_BOUNDARY*'
            Read-Utf8Text $script:target | Should -BeExactly 'official incoming fix'
            (Read-WorkflowPatchReceipt).phase | Should -Be 'retired'
            (Get-GitOutput @('log', '--format=%s')) -join "`n" | Should -Match 'retire temporary ITL workflow patch'
            New-SealedFixturePatch | Out-Null
            { Invoke-RefreshDevBranchCore -OperationName 'refresh-dev-branch-lite' } | Should -Throw '*MERGE_BOUNDARY*'
            Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
            (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
        }

        It 'preserves the patch through configuration-only <Operation>' -TestCases @(
            @{Operation='refresh-dev-branch';Full=$true}, @{Operation='refresh-dev-branch-lite';Full=$false}
        ) {
            param($Operation,$Full)
            $main = Join-Path $TestDrive ('Основная конфигурация ' + [guid]::NewGuid().ToString('N'))
            Invoke-Git @('worktree','add','--quiet',$main,'master')
            Set-FixtureText (Join-Path $main 'product.txt') 'incoming configuration'
            Invoke-GitAt -Root $main -Arguments @('add','--','product.txt')
            Invoke-GitAt -Root $main -Arguments @('commit','-qm','configuration only')
            Mock Invoke-NewDevBranchLifecycleMerge {
                param($State,$Operation,$TargetCommit,$ConflictStage)
                Invoke-Git @('merge','--no-edit',$TargetCommit)
                throw 'MERGE_BOUNDARY'
            }
            { Invoke-RefreshDevBranchCore -SynchronizeMaster:$Full -OperationName $Operation } | Should -Throw '*MERGE_BOUNDARY*'
            Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
            Read-Utf8Text (Join-Path $script:ProjectRoot 'product.txt') | Should -Be 'incoming configuration'
            (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
            @(Get-WorkflowFixArchiveRecords).Count | Should -Be 0
        }
    }


    Context 'Shared fix archive' {
        BeforeEach { New-SealedFixturePatch | Out-Null }

        It 'deduplicates exact fixes and does not count searches as usage' {
            $receipt = Read-WorkflowPatchReceipt
            Save-WorkflowFixArchive $receipt
            Save-WorkflowFixArchive $receipt
            $entries = @(Get-WorkflowFixArchiveRecords)
            $entries.Count | Should -Be 1
            $past = [datetime]::UtcNow.AddDays(-10)
            [IO.File]::SetLastWriteTimeUtc($entries[0].path,$past)
            $found = @(Find-WorkflowFixArchive -Query 'Original task')
            $found.Count | Should -Be 1
            $found[0].lastUsedAt | Should -Be $past
            $entries[0].entry.files[0].diff | Should -Match 'patched: Кириллица'
            $entries[0].entry.workflowPackage.commit | Should -Be ('b'*40)
        }

        It 'reuses a reviewed diff in another project with new local authorization and provenance' {
            $receipt = Read-WorkflowPatchReceipt
            Save-WorkflowFixArchive $receipt
            $entry = @(Get-WorkflowFixArchiveRecords)[0]
            [IO.File]::SetLastWriteTimeUtc($entry.path,[datetime]::UtcNow.AddDays(-10))
            $first = $script:ProjectRoot
            $consumer = Join-Path $TestDrive 'Другой проект с пробелом'
            Invoke-GitCommand -Root $TestDrive -Arguments @('clone','--quiet','--no-local',$first,$consumer)
            $script:ProjectRoot = $consumer
            Invoke-Git @('config','user.email','fixture@example.invalid')
            Invoke-Git @('config','user.name','Patch fixture')
            Invoke-Git @('config','core.autocrlf','false')
            $report = Join-Path $consumer 'handoffs/new-permission.md'
            Set-FixtureText $report 'Authorization for this second project only; candidate from the shared archive.'
            $new = New-WorkflowPatchReceipt -Paths @($script:patchPath) -ReportPath $report -ArchiveId $entry.id
            $new.projectRoot | Should -Be $consumer
            Read-Utf8Text $new.reportPath | Should -Match 'second project only'
            $patchFile = Join-Path $TestDrive 'проверенный diff.patch'
            Set-FixtureText $patchFile $entry.entry.files[0].diff
            Invoke-Git @('apply','--check','--',$patchFile)
            Invoke-Git @('apply','--',$patchFile)
            Set-WorkflowPatchSealed | Out-Null
            (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
            Read-Utf8Text (Join-Path $consumer $script:patchPath) | Should -Match 'patched: Кириллица'
            @(Get-WorkflowFixArchiveRecords)[0].lastUsedAt | Should -BeGreaterThan ([datetime]::UtcNow.AddDays(-1))
            $script:ProjectRoot = $first
            (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
        }

        It 'does not automatically apply an incompatible archive candidate' {
            Save-WorkflowFixArchive (Read-WorkflowPatchReceipt)
            Set-FixtureText $script:target 'different current implementation'
            $entries = @(Find-WorkflowFixArchive -Query 'Original')
            $patchFile = Join-Path $TestDrive 'incompatible.patch'
            Set-FixtureText $patchFile ((Read-Utf8Text $entries[0].path | ConvertFrom-Json).files[0].diff)
            { Invoke-Git @('apply','--check','--',$patchFile) } | Should -Throw
            Read-Utf8Text $script:target | Should -Be 'different current implementation'
        }

        It 'expires unused records and enforces count and byte caps without touching active data' {
            $receipt = Read-WorkflowPatchReceipt
            $prototype = $receipt.files[0].diff
            foreach ($i in 1..5) {
                $receipt.files[0].diff = $prototype + "# variant $i" + [char]10
                Save-WorkflowFixArchive $receipt
            }
            $entries = @(Get-WorkflowFixArchiveRecords)
            $entries.Count | Should -Be 5
            for ($i=0; $i -lt 5; $i++) { [IO.File]::SetLastWriteTimeUtc($entries[$i].path,[datetime]::UtcNow.AddDays(-$i)) }
            Invoke-WorkflowFixArchiveCleanup -MaxCount 3
            @(Get-WorkflowFixArchiveRecords).Count | Should -Be 3
            $latest = @(Get-WorkflowFixArchiveRecords | Sort-Object lastUsedAt -Descending)[0]
            Invoke-WorkflowFixArchiveCleanup -MaxBytes $latest.size
            @(Get-WorkflowFixArchiveRecords).Count | Should -Be 1
            [IO.File]::SetLastWriteTimeUtc($latest.path,[datetime]::UtcNow.AddDays(-91))
            @(Find-WorkflowFixArchive).Count | Should -Be 0
            (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
            Read-Utf8Text $script:target | Should -Match 'patched'
            Test-Path -LiteralPath $receipt.reportPath | Should -BeTrue
            Test-Path -LiteralPath $script:report | Should -BeTrue
        }

        It 'warns on unavailable storage while completing local retirement' {
            Mock Get-WorkflowFixArchiveRoot { throw 'archive unavailable' }
            $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch'
            Start-WorkflowPatchRetirement $plan
            $warnings = @(& { Complete-WorkflowPatchRetirement $plan } 3>&1)
            ($warnings -join ' ') | Should -Match 'archive unavailable'
            (Read-WorkflowPatchReceipt).phase | Should -Be 'retired'
            Test-Path -LiteralPath $plan.receipt.reportPath | Should -BeTrue
            Read-Utf8Text $script:target | Should -Match '^original'
            @(Find-WorkflowFixArchive).Count | Should -Be 0
        }

        It 'preserves corrupted records instead of returning them as ready solutions' {
            Save-WorkflowFixArchive (Read-WorkflowPatchReceipt)
            $entry = @(Get-WorkflowFixArchiveRecords)[0]
            $changed = $entry.entry
            $changed.files[0].diff = 'tampered'
            Write-Utf8TextAtomic -Path $entry.path -Value ($changed | ConvertTo-Json -Depth 8)
            @(Find-WorkflowFixArchive).Count | Should -Be 0
            Test-Path -LiteralPath $entry.path | Should -BeTrue
            { Resolve-WorkflowFixArchivePath '../outside' } | Should -Throw '*ID_INVALID*'
        }

        It 'writes complete deduplicated records from concurrent processes' {
            $receiptPath = Join-Path $TestDrive 'shared-receipt.json'
            Write-Utf8TextAtomic -Path $receiptPath -Value ((Read-WorkflowPatchReceipt) | ConvertTo-Json -Depth 12)
            $jobs = @()
            try {
                foreach ($i in 1..3) {
                    $jobs += Start-Job -ArgumentList $RepoRoot,$script:archiveRoot,$receiptPath -ScriptBlock {
                        param($repository,$archive,$receiptFile)
                        . (Join-Path $repository '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
                        . (Join-Path $repository '.agents/skills/1c-workflow/scripts/lib/agent-1c.local-patch.ps1')
                        $script:fixtureArchive = $archive
                        function Get-WorkflowFixArchiveRoot { $script:fixtureArchive }
                        Save-WorkflowFixArchive (Read-Utf8Text $receiptFile | ConvertFrom-Json)
                    }
                }
                $jobs | Wait-Job -Timeout 30 | Out-Null
                @($jobs | Where-Object State -ne 'Completed').Count | Should -Be 0
                $output = @($jobs | Receive-Job -ErrorAction Stop 3>&1)
                ($output -join ' ') | Should -Not -Match 'unavailable|invalid archive'
                @(Get-WorkflowFixArchiveRecords).Count | Should -Be 1
            } finally { $jobs | Stop-Job; $jobs | Remove-Job -Force }
        }

        It 'archives a legacy receipt without new metadata or diff fields' {
            $receipt = Read-WorkflowPatchReceipt
            $receipt.PSObject.Properties.Remove('workflowPackage')
            $receipt.files[0].PSObject.Properties.Remove('diff')
            Write-WorkflowPatchReceipt $receipt
            (Get-WorkflowPatchBaselineIdentity $receipt).commit | Should -Be ('b'*40)
            Save-WorkflowFixArchive $receipt
            $entry = @(Get-WorkflowFixArchiveRecords)[0]
            $entry.entry.files[0].diff | Should -Match '@@ -1,1 \+1,1 @@'
            Set-FixtureText $script:target ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($receipt.files[0].before)))
            $patchFile = Join-Path $TestDrive 'legacy.patch'
            Set-FixtureText $patchFile $entry.entry.files[0].diff
            Invoke-Git @('apply','--check','--',$patchFile)
        }

        It 'uses incoming managed changes for legacy provenance: <ChangedPath>' -TestCases @(
            @{ChangedPath='product.txt';Expected='same'},
            @{ChangedPath='AGENT-INSTALL.md';Expected='changed'},
            @{ChangedPath='.agents/skills/1c-workflow/new-rule.md';Expected='changed'}
        ) {
            param($ChangedPath,$Expected)
            $receipt = Read-WorkflowPatchReceipt
            $receipt.PSObject.Properties.Remove('workflowPackage')
            Mock Get-WorkflowPatchPackageIdentity { $null }
            Invoke-Git @('branch','master')
            Invoke-Git @('add','--',$script:patchPath)
            Invoke-Git @('commit','-qm','branch-local workaround')
            $main = Join-Path $TestDrive ('Старый мастер ' + [guid]::NewGuid().ToString('N'))
            Invoke-Git @('worktree','add','--quiet',$main,'master')
            Set-FixtureText (Join-Path $main $ChangedPath) 'incoming change without package identity'
            Invoke-GitAt -Root $main -Arguments @('add','--',$ChangedPath)
            Invoke-GitAt -Root $main -Arguments @('commit','-qm','legacy master update')
            $incoming = (Get-GitOutput @('rev-parse','master')).Trim()
            Get-WorkflowPatchPackageChange -Receipt $receipt -TargetCommit $incoming | Should -Be $Expected
            Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
        }

        It 'exposes only completed old local incidents to existing retention' {
            $receipt = Read-WorkflowPatchReceipt
            $plan = Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch'
            Start-WorkflowPatchRetirement $plan
            Complete-WorkflowPatchRetirement $plan
            @(Get-ItlWorkflowIncidentArchiveCandidates -ProjectRoot $script:ProjectRoot).Count | Should -Be 0
            New-SealedFixturePatch | Out-Null
            $candidates = @(Get-ItlWorkflowIncidentArchiveCandidates -ProjectRoot $script:ProjectRoot)
            $candidates.Count | Should -Be 1
            $candidates[0].path | Should -Be (Split-Path -Parent $receipt.reportPath)
            $candidates[0].path | Should -Not -Be (Split-Path -Parent $script:report)
            Set-FixtureText (Join-Path $script:ProjectRoot '.agent-1c/snapshots/workflow-incidents/active.json') '{}'
            @(Get-ItlWorkflowIncidentArchiveCandidates -ProjectRoot $script:ProjectRoot).Count | Should -Be 0
        }
    }


    Context 'Package copy boundary' {
        BeforeEach {
            Invoke-Git @('checkout', '-qb', 'master')
            New-SealedFixturePatch | Out-Null
            $script:incoming = Join-Path $TestDrive ('incoming ' + [guid]::NewGuid().ToString('N'))
            Set-FixtureText (Join-Path $script:incoming $script:patchPath) 'official replacement'
            Mock Set-RunStage {}
            Mock Resolve-WorkflowPackageSource { [pscustomobject]@{root=$script:incoming;repo='fixture-workflow';ref='develop';commit=('a'*40)} }
            Mock Assert-WorkflowSourceOutsideProject {}
            Mock Assert-WorkflowSourceAiRulesInstallable {}
            Mock Get-WorkflowPackageCopyDirectoryPaths { '.agents/skills/1c-workflow' }
            Mock Get-WorkflowPackageCopyFilePaths { @() }
            Mock Remove-LegacyWorkflowManagedFiles {}
            Mock Update-WorkflowPackageLockEntry {}
            Mock Invoke-Agent1cFreshProcess { throw 'REEXEC_BOUNDARY' }
        }
        It 'restores the workaround when managed copying fails after a partial write' {
            Mock Copy-WorkflowManagedDirectory {
                Set-FixtureText $script:target 'partial replacement'
                throw 'COPY_FAILURE'
            }
            { Update-WorkflowPackage } | Should -Throw '*COPY_FAILURE*'
            Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
            (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
        }
        It 'keeps official bytes and the incident when archive and later processing fail' {
            Mock Get-WorkflowFixArchiveRoot { throw 'archive unavailable' }
            Mock Copy-WorkflowManagedDirectory { Set-FixtureText $script:target 'official replacement' }
            { Update-WorkflowPackage } | Should -Throw '*REEXEC_BOUNDARY*'
            Read-Utf8Text $script:target | Should -BeExactly 'official replacement'
            (Read-WorkflowPatchReceipt).phase | Should -Be 'retired'
        }
        It 'preserves a same-version patch without copying or claiming a new installation' {
            Mock Resolve-WorkflowPackageSource { [pscustomobject]@{root=$script:incoming;repo='fixture-workflow';commit=('b'*40)} }
            Mock Copy-WorkflowManagedDirectory { throw 'unexpected copy' }
            $warnings = @(& { Update-WorkflowPackage } 3>&1)
            Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
            (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
            ($warnings -join ' ') | Should -Match 'copying skipped'
            Should -Invoke Copy-WorkflowManagedDirectory -Times 0
        }
        It 'preserves the patch when source identity is unavailable' {
            Mock Resolve-WorkflowPackageSource { [pscustomobject]@{root=$script:incoming;repo='';commit=''} }
            Mock Copy-WorkflowManagedDirectory { throw 'unexpected copy' }
            Update-WorkflowPackage
            Read-Utf8Text $script:target | Should -BeExactly "patched: Кириллица`r`n"
            (Read-WorkflowPatchReceipt).phase | Should -Be 'active'
            Should -Invoke Copy-WorkflowManagedDirectory -Times 0
        }
    }
}
