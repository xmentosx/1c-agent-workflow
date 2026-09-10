BeforeAll {
    $script:PreservationRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:PreservationHelper = Join-Path $script:PreservationRepo '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    $script:PreservationModule = Join-Path $script:PreservationRepo '.agents/skills/1c-workflow/scripts/lib/agent-1c.merge-preservation.ps1'
    function Set-PreservationResult {
        param([string]$Text)
        [IO.File]::WriteAllText((Join-Path $script:ProjectRoot $script:MergeModulePath), $Text, [Text.UTF8Encoding]::new($false))
        Invoke-Git @('add', '--', $script:MergeModulePath)
    }
}

Describe 'Three-way merge preservation evidence' {
    BeforeEach {
        $root = Join-Path $TestDrive ('Слияние с пробелом ' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        . $script:PreservationHelper -ProjectRoot $root -Action help *> $null
        . $script:PreservationModule
        $script:MergeModulePath = 'src/cf/CommonModules/Модуль с пробелом/Ext/Module.bsl'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $root $script:MergeModulePath)))
        $baseText = "Функция Основа()`n Возврат 0;`nКонецФункции`n"
        $branchText = "Функция Основа()`n Возврат 1;`nКонецФункции`n`nПроцедура ПодготовитьБДДС()`n Сообщить(1);`nКонецПроцедуры`n"
        $targetText = "Функция Основа()`n Возврат 2;`nКонецФункции`n`nПроцедура ОбновитьОтчет()`n Сообщить(2);`nКонецПроцедуры`n"
        $mergedText = $branchText.Replace('Возврат 1;', 'Возврат 3;') + "`nПроцедура ОбновитьОтчет()`n Сообщить(2);`nКонецПроцедуры`n"
        Invoke-Git @('init', '--initial-branch=master') *> $null
        Invoke-Git @('config', 'user.name', 'Merge Fixture')
        Invoke-Git @('config', 'user.email', 'fixture@example.invalid')
        Invoke-Git @('config', 'commit.gpgsign', 'false')
        Invoke-Git @('config', 'core.autocrlf', 'false')
        Set-PreservationResult $baseText
        Invoke-Git @('commit', '-m', 'base') *> $null
        $baseCommit = Get-CurrentCommit
        Invoke-Git @('checkout', '-b', 'itldev/test') *> $null
        Set-PreservationResult $branchText
        Invoke-Git @('commit', '-m', 'branch feature') *> $null
        $branchCommit = Get-CurrentCommit
        Invoke-Git @('checkout', 'master') *> $null
        Set-PreservationResult $targetText
        Invoke-Git @('commit', '-m', 'target feature') *> $null
        $targetCommit = Get-CurrentCommit
        Invoke-Git @('checkout', 'itldev/test') *> $null
        try { Invoke-Git @('merge', '--no-ff', '--no-commit', $targetCommit) *> $null } catch {
            if (-not (Test-GitMergeInProgress)) { throw }
        }
        @(Get-DevBranchMergeUnmergedPaths) | Should -Contain $script:MergeModulePath
        Mock Set-RunFailureContext {}
    }

    It 'blocks whole-parent replacement and retains both-side patches without changing source or index' {
        Set-PreservationResult $targetText
        $indexPath = Join-Path $root '.git/index'
        $indexSha = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
        { Assert-DevBranchMergePreservation -BranchCommit $branchCommit -TargetCommit $targetCommit } | Should -Throw '*PRESERVATION_REVIEW_REQUIRED*'
        (Get-CurrentCommit) | Should -Be $branchCommit
        (Get-GitMergeHeadCommit) | Should -Be $targetCommit
        (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash | Should -Be $indexSha
        [IO.File]::ReadAllText((Join-Path $root $script:MergeModulePath)) | Should -BeExactly $targetText
        $reportPath = Join-Path (Get-MergePreservationReportRoot -BranchCommit $branchCommit -TargetCommit $targetCommit) 'review.json'
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.items.Count | Should -Be 1
        $report.items[0].risk.discardedSide | Should -Be 'branch'
        @($report.items[0].risk.lostDeclarations.name) | Should -Contain 'ПодготовитьБДДС'
        (Get-Content -LiteralPath $report.items[0].patches.branch -Raw -Encoding UTF8) | Should -Match 'ПодготовитьБДДС'
        (Get-Content -LiteralPath $report.items[0].patches.target -Raw -Encoding UTF8) | Should -Match 'ОбновитьОтчет'
    }

    It 'accepts compatible repairs retaining both added semantic units without a decision file' {
        Set-PreservationResult $mergedText
        $plan = Get-MergePreservationPlan -BranchCommit $branchCommit -TargetCommit $targetCommit
        @($plan.risks) | Should -HaveCount 0
        { Assert-DevBranchMergePreservation -BranchCommit $branchCommit -TargetCommit $targetCommit } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $root '.git/itl/merge-review') | Should -BeFalse
    }

    It 'still finds a lost addition when an extra edit disguises the whole-parent copy' {
        Set-PreservationResult ($targetText + "`n// дополнительная правка`n")
        $plan = Get-MergePreservationPlan -BranchCommit $branchCommit -TargetCommit $targetCommit
        @($plan.risks) | Should -HaveCount 1
        $plan.risks[0].discardedSide | Should -BeNullOrEmpty
        @($plan.risks[0].lostDeclarations.name) | Should -Contain 'ПодготовитьБДДС'
    }

    It 'does not require replacement review when one parent is already the clean three-way text result' {
        # Separate fixture history: one side contains the other's exact delta.
        Invoke-Git @('merge', '--abort')
        Invoke-Git @('checkout', '-b', 'compatible-left', $baseCommit) *> $null
        Set-PreservationResult ($baseText + "`n// общее дополнение`n")
        Invoke-Git @('commit', '-m', 'shared delta') *> $null
        $left = Get-CurrentCommit
        Invoke-Git @('checkout', '-b', 'compatible-right', $baseCommit) *> $null
        Set-PreservationResult (($baseText + "`n// общее дополнение`n").Replace('Возврат 0;', 'Возврат 4;'))
        Invoke-Git @('commit', '-m', 'shared delta and independent change') *> $null
        $right = Get-CurrentCommit
        $plan = Get-MergePreservationPlan -BranchCommit $left -TargetCommit $right -ResultCommit $right
        @($plan.risks) | Should -HaveCount 0
    }

    It 'recognizes duplicate additions without accepting different bodies or reordered existing content: <caseName>' -TestCases @(
        @{ caseName='identical new methods'; extension='bsl'; original="Procedure Start()`nEndProcedure`n`nProcedure Finish()`nEndProcedure`n"; addition="Procedure Shared()`n Message(1);`nEndProcedure`n`n"; different=$false; reorder=$false; expected=0 }
        @{ caseName='same method name with different bodies'; extension='bsl'; original="Procedure Start()`nEndProcedure`n`nProcedure Finish()`nEndProcedure`n"; addition="Procedure Shared()`n Message(1);`nEndProcedure`n`n"; different=$true; reorder=$false; expected=1 }
        @{ caseName='both shared method copies removed'; extension='bsl'; original="Procedure Start()`nEndProcedure`n`nProcedure Finish()`nEndProcedure`n"; addition="Procedure Shared()`n Message(1);`nEndProcedure`n`n"; different=$false; reorder=$false; expected=1; resultBase=$true }
        @{ caseName='identical parent additions removed'; extension='bsl'; original="Procedure Start()`nEndProcedure`n`nProcedure Finish()`nEndProcedure`n"; addition="Procedure Shared()`n Message(1);`nEndProcedure`n`n"; different=$false; reorder=$false; expected=1; resultBase=$true; sameParents=$true }
        @{ caseName='identical form definitions'; extension='xml'; original='<Form><Items><Item name="One"/><Item name="Two"/></Items></Form>'; addition='<Item name="Shared" title="One"/>'; different=$false; reorder=$false; expected=0 }
        @{ caseName='same form identity with different properties'; extension='xml'; original='<Form><Items><Item name="One"/><Item name="Two"/></Items></Form>'; addition='<Item name="Shared" title="One"/>'; different=$true; reorder=$false; expected=1 }
        @{ caseName='existing form order changed'; extension='xml'; original='<Form><Items><Item name="One"/><Item name="Two"/></Items></Form>'; addition='<Item name="Shared" title="One"/>'; different=$false; reorder=$true; expected=1 }
        @{ caseName='both XML additions reverted to base'; extension='xml'; original='<Form><Items><Item name="One"/><Item name="Two"/></Items></Form>'; addition='<Item name="Shared" title="One"/>'; different=$false; reorder=$false; expected=1; resultBase=$true }
    ) {
        param($caseName, $extension, $original, $addition, $different, $reorder, $expected, $resultBase = $false, $sameParents = $false)
        Invoke-Git @('merge', '--abort')
        Invoke-Git @('checkout', '-b', 'dedup-base', $baseCommit) *> $null
        if ($extension -eq 'xml') { $script:MergeModulePath = 'src/cf/CommonForms/Форма с пробелом/Ext/Form.xml' }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $root $script:MergeModulePath)))
        Set-PreservationResult $original
        Invoke-Git @('commit', '-m', 'dedup base') *> $null
        $dedupBase = Get-CurrentCommit
        if ($extension -eq 'xml') {
            $leftText = $original.Replace('<Items>', '<Items>' + $addition)
            $rightText = $original.Replace('</Items>', $addition + '</Items>')
            if ($different) { $rightText = $rightText.Replace('title="One"', 'title="Two"') }
            if ($reorder) { $rightText = $rightText.Replace('<Item name="One"/><Item name="Two"/>', '<Item name="Two"/><Item name="One"/>') }
        } else {
            $leftText = $addition + $original
            $rightText = $original + "`n" + $addition
            if ($different) { $rightText = $rightText.Replace('Message(1)', 'Message(2)') }
        }
        if ($sameParents) { $rightText = $leftText }
        Invoke-Git @('checkout', '-b', 'dedup-left') *> $null
        Set-PreservationResult $leftText
        Invoke-Git @('commit', '-m', 'left addition') *> $null
        $left = Get-CurrentCommit
        Invoke-Git @('checkout', '-b', 'dedup-right', $dedupBase) *> $null
        Set-PreservationResult $rightText
        Invoke-Git @('commit', '-m', 'right addition') *> $null
        $right = Get-CurrentCommit
        $resultCommit = if ($resultBase) { $dedupBase } else { $right }
        $plan = Get-MergePreservationPlan -BranchCommit $left -TargetCommit $right -ResultCommit $resultCommit
        @($plan.risks) | Should -HaveCount $expected
        if ($resultBase -and $extension -eq 'bsl') {
            @($plan.risks[0].lostDeclarations) | Should -HaveCount 2
            @($plan.risks[0].lostDeclarations.name | Sort-Object -Unique) | Should -Be @('Shared')
        }
    }

    It 'reports whole-parent replacement of binary bytes without attempting UTF-8 equivalence' {
        Invoke-Git @('merge', '--abort')
        Invoke-Git @('checkout', '-b', 'binary-base', $baseCommit) *> $null
        $path = 'Данные с пробелом.bin'
        [IO.File]::WriteAllBytes((Join-Path $root $path), [byte[]]@(0,255,1))
        Invoke-Git @('add', '--', $path)
        Invoke-Git @('commit', '-m', 'binary base') *> $null
        $binaryBase = Get-CurrentCommit
        Invoke-Git @('checkout', '-b', 'binary-left') *> $null
        [IO.File]::WriteAllBytes((Join-Path $root $path), [byte[]]@(0,255,2))
        Invoke-Git @('add', '--', $path)
        Invoke-Git @('commit', '-m', 'binary left') *> $null
        $left = Get-CurrentCommit
        Invoke-Git @('checkout', '-b', 'binary-right', $binaryBase) *> $null
        [IO.File]::WriteAllBytes((Join-Path $root $path), [byte[]]@(0,255,3))
        Invoke-Git @('add', '--', $path)
        Invoke-Git @('commit', '-m', 'binary right') *> $null
        $right = Get-CurrentCommit
        $plan = Get-MergePreservationPlan -BranchCommit $left -TargetCommit $right -ResultCommit $right
        @($plan.risks) | Should -HaveCount 1
        $plan.risks[0].path | Should -BeExactly $path
        $plan.risks[0].discardedSide | Should -Be 'branch'
    }

    It 'retains review evidence in common Git storage after its linked worktree is removed' {
        Invoke-Git @('merge', '--abort')
        $mainReportRoot = Get-MergePreservationReportRoot -BranchCommit $branchCommit -TargetCommit $targetCommit
        $linked = Join-Path $TestDrive ('Отдельная ветка ' + [guid]::NewGuid().ToString('N'))
        Invoke-Git @('worktree', 'add', '-b', 'review-copy', $linked, $branchCommit) *> $null
        try {
            $script:ProjectRoot = $linked
            try { Invoke-Git @('merge', '--no-ff', '--no-commit', $targetCommit) *> $null } catch {
                if (-not (Test-GitMergeInProgress)) { throw }
            }
            Set-PreservationResult $targetText
            { Assert-DevBranchMergePreservation -BranchCommit $branchCommit -TargetCommit $targetCommit } | Should -Throw '*PRESERVATION_REVIEW_REQUIRED*'
            $linkedReportRoot = Get-MergePreservationReportRoot -BranchCommit $branchCommit -TargetCommit $targetCommit
            $linkedReportRoot | Should -Not -Be $mainReportRoot
            $linkedReportRoot.StartsWith((Join-Path $root '.git/itl/merge-review/'), [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
            Invoke-Git @('merge', '--abort')
        } finally { $script:ProjectRoot = $root }
        # Git removes only this explicitly created fixture worktree.
        Invoke-Git @('worktree', 'remove', $linked)
        Test-Path -LiteralPath $linked | Should -BeFalse
        (Join-Path $linkedReportRoot 'review.json') | Should -Exist
    }

    It 'keeps malformed or stale decisions blocking and accepts only evidence for the exact result' {
        Set-PreservationResult $targetText
        { Assert-DevBranchMergePreservation -BranchCommit $branchCommit -TargetCommit $targetCommit } | Should -Throw '*PRESERVATION_REVIEW_REQUIRED*'
        $reportPath = Join-Path (Get-MergePreservationReportRoot -BranchCommit $branchCommit -TargetCommit $targetCommit) 'review.json'
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Utf8Text -Path $report.decisionPath -Value '{bad json'
        { Assert-DevBranchMergePreservation -BranchCommit $branchCommit -TargetCommit $targetCommit } | Should -Throw '*PRESERVATION_REVIEW_REQUIRED*'
        $decision = @{schemaVersion=1;planId=$report.planId;items=@(@{path=$script:MergeModulePath;baseCommit=$baseCommit;
            disposition='authorized-incompatible-change';reason='Fixture explicitly drops the obsolete branch feature';
            preservationEvidence='The target feature replaces the branch feature per fixture requirement';
            verificationEvidence='Fixture verifies exact target bytes and retained target declaration'})}
        Write-Utf8Text -Path $report.decisionPath -Value ($decision | ConvertTo-Json -Depth 8)
        { Assert-DevBranchMergePreservation -BranchCommit $branchCommit -TargetCommit $targetCommit } | Should -Throw '*PRESERVATION_REVIEW_REQUIRED*'
        $decision.items[0].userAuthorization = 'Explicit incompatible-outcome decision in this synthetic test fixture'
        Write-Utf8Text -Path $report.decisionPath -Value ($decision | ConvertTo-Json -Depth 8)
        { Assert-DevBranchMergePreservation -BranchCommit $branchCommit -TargetCommit $targetCommit } | Should -Not -Throw
        (Get-Content $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should -Be 'reviewed-intentional-replacement'
        Write-Utf8Text -Path (Join-Path $root 'caller.txt') -Value 'Changed caller after the replacement was reviewed'
        Invoke-Git @('add', '--', 'caller.txt')
        { Assert-DevBranchMergePreservation -BranchCommit $branchCommit -TargetCommit $targetCommit } | Should -Throw '*PRESERVATION_REVIEW_REQUIRED*'
        Set-PreservationResult ($targetText + "`n// другой результат`n")
        { Assert-DevBranchMergePreservation -BranchCommit $branchCommit -TargetCommit $targetCommit } | Should -Throw '*PRESERVATION_REVIEW_REQUIRED*'
    }

    It 'detects a deletion chosen against a modified parent' {
        Invoke-Git @('merge', '--abort')
        Invoke-Git @('checkout', 'master') *> $null
        Invoke-Git @('rm', '--', $script:MergeModulePath) *> $null
        Invoke-Git @('commit', '-m', 'remove module') *> $null
        $deletingTarget = Get-CurrentCommit
        $plan = Get-MergePreservationPlan -BranchCommit $branchCommit -TargetCommit $deletingTarget -ResultCommit $deletingTarget
        @($plan.risks) | Should -HaveCount 1
        $plan.risks[0].discardedSide | Should -Be 'branch'
        $plan.risks[0].resultBlob | Should -Match '^0+$'
        @($plan.risks[0].lostDeclarations.name) | Should -Contain 'ПодготовитьБДДС'
    }

    It 'prevents <operation> from committing a lost repair even after the conflict list is empty' -ForEach @(
        @{operation='refresh-dev-branch'}, @{operation='refresh-dev-branch-lite'}, @{operation='close-dev-branch'}
    ) {
        Set-PreservationResult $targetText
        $script:MergeState = [pscustomobject]@{devBranch='itldev/test';devBranchName='test';safeDevBranchName='test'}
        $DevBranchName = 'test'
        Mock Read-DevBranchState { $script:MergeState }
        Mock Update-DevBranchState {
            param($State, $Updates)
            foreach ($key in $Updates.Keys) { $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force }
        }
        Mock Assert-OneCConfigurationSourceIntegrity {}
        Mock Sync-AiRules1cManagedIgnoredFilesFromMain {}
        Mock Restart-Agent1cAfterDevBranchMerge { throw 'FIXTURE_HELPER_RESTART_AFTER_COMMIT' }
        Set-PendingDevBranchMergeTransaction -State $script:MergeState -Operation $operation -Branch itldev/test -BranchCommit $branchCommit -TargetCommit $targetCommit -Stage conflicts -AllowedPaths @($script:MergeModulePath) -ConflictPaths @()
        { Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation $operation -ConflictStage merge-conflicts } | Should -Throw '*PRESERVATION_REVIEW_REQUIRED*'
        (Get-CurrentCommit) | Should -Be $branchCommit
        (Get-GitMergeHeadCommit) | Should -Be $targetCommit
        Set-PreservationResult $mergedText
        { Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation $operation -ConflictStage merge-conflicts } | Should -Throw '*FIXTURE_HELPER_RESTART_AFTER_COMMIT*'
        $resultCommit = Get-CurrentCommit
        Test-GitCommitHasExactMergeParents -Commit $resultCommit -FirstParent $branchCommit -SecondParent $targetCommit | Should -BeTrue
        $script:MergeState.pendingMergeStage | Should -Be 'merged'
        $reportPath = Join-Path (Get-MergePreservationReportRoot -BranchCommit $branchCommit -TargetCommit $targetCommit) 'review.json'
        (Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should -Be 'resolved-by-repair'
    }
}
