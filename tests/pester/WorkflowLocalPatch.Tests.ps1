Describe 'Temporary workflow patches and original-task continuation' {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.local-patch.ps1')
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
        $script:ProjectRoot = Join-Path $TestDrive ('Проект с пробелом ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ProjectRoot | Out-Null
        $script:patchPath = '.agents/skills/1c-workflow/scripts/lib/исправление тест.ps1'
        $script:target = Join-Path $script:ProjectRoot $script:patchPath
        $script:report = Join-Path $script:ProjectRoot 'handoffs/incident.md'
        Set-FixtureText $script:target "original: Кириллица`r`n"
        Set-FixtureText $script:report 'Original task, reproduced error, scoped user permission and proposed workaround.'
        Set-FixtureText (Join-Path $script:ProjectRoot '.agent-1c/project.json') '{}'
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
        Get-WorkflowPatchRetirementPlan -Operation 'refresh-dev-branch' | Should -BeNullOrEmpty
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
        It 'merges incoming workflow bytes after retiring the patch instead of checkpointing it' {
            # Change master through a separate worktree, as real refresh does.
            $main = Join-Path $TestDrive ('Основная ветка ' + [guid]::NewGuid().ToString('N'))
            Invoke-Git @('worktree', 'add', '--quiet', $main, 'master')
            Set-FixtureText (Join-Path $main $script:patchPath) 'official incoming fix'
            Invoke-GitAt -Root $main -Arguments @('add', '--', $script:patchPath)
            Invoke-GitAt -Root $main -Arguments @('commit', '-qm', 'official workflow update')
            Mock Invoke-NewDevBranchLifecycleMerge {
                param($State,$Operation,$TargetCommit,$ConflictStage)
                Invoke-Git @('merge', '--no-edit', $TargetCommit)
                throw 'MERGE_BOUNDARY'
            }
            { Invoke-RefreshDevBranchCore -OperationName 'refresh-dev-branch-lite' } | Should -Throw '*MERGE_BOUNDARY*'
            Read-Utf8Text $script:target | Should -BeExactly 'official incoming fix'
            (Read-WorkflowPatchReceipt).phase | Should -Be 'retired'
            (Get-GitOutput @('log', '--format=%s')) -join "`n" | Should -Not -Match 'checkpoint before branch refresh'
        }
    }

    Context 'Package copy boundary' {
        BeforeEach {
            Invoke-Git @('checkout', '-qb', 'master')
            New-SealedFixturePatch | Out-Null
            $script:incoming = Join-Path $TestDrive ('incoming ' + [guid]::NewGuid().ToString('N'))
            Set-FixtureText (Join-Path $script:incoming $script:patchPath) 'official replacement'
            Mock Set-RunStage {}
            Mock Resolve-WorkflowPackageSource { [pscustomobject]@{root=$script:incoming;ref='develop';commit=('a'*40)} }
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
        It 'keeps official bytes and the incident when copy succeeded but a later phase fails' {
            Mock Copy-WorkflowManagedDirectory { Set-FixtureText $script:target 'official replacement' }
            { Update-WorkflowPackage } | Should -Throw '*REEXEC_BOUNDARY*'
            Read-Utf8Text $script:target | Should -BeExactly 'official replacement'
            (Read-WorkflowPatchReceipt).phase | Should -Be 'retired'
        }
    }
}
