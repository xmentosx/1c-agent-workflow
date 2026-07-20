BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Local quality gate contract" {
    It "parses scripts/check.ps1" {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $RepoRoot "scripts\check.ps1"),
            [ref]$tokens,
            [ref]$errors
        )
        @($errors) | Should -BeNullOrEmpty
    }

    It "makes Full the default and exposes Fast Full Release modes" {
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $text | Should -Match '\[ValidateSet\("Fast", "Full", "Release"\)\]'
        $text | Should -Match '\[string\]\$Mode = "Full"'
        $text | Should -Match 'ITL_AI_RULES_SOURCE_PATH'
        $text | Should -Match 'Get-LocalForkRelease'
        $text | Should -Match 'invoke-release-e2e\.ps1'
        $text | Should -Match 'LifecycleOperationLock\.Tests\.ps1'
    }

    It "reuses exact or ancestor same-tree Full qualifications and checkpoints static proof before runtime" {
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $text | Should -Match 'itl-workflow-full-qualification'
        $text | Should -Match 'Test-WorkflowQualification'
        $text | Should -Match 'repository\.worktreeClean'
        $text | Should -Match 'Test-HasExactInventory'
        $text | Should -Match 'qualificationJunitPath'
        $text | Should -Match 'ancestor-same-tree'
        (Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-qualification.ps1") -Raw -Encoding UTF8) | Should -Match 'merge-base --is-ancestor'
        $text | Should -Match 'static-tracked-state'
        $text | Should -Match 'invoke-release-e2e\.ps1'
        $text | Should -Match 'test-ai-rules-compatibility\.ps1'
        $text | Should -Match 'invoke-pester-shards\.ps1'
        $text | Should -Match 'Start-PowerShellChildProcess'
        $text | Should -Match 'Complete-ParallelGateStage'
        $text | Should -Match 'forkReadyForParallel'
        $text | Should -Match '\[int\]\$PesterWorkers = 3'
        $text | Should -Match ([regex]::Escape('execution = $Execution'))
        $text | Should -Match 'Add-ReusedStage -Name "pester"'
        $text | Should -Match 'Invoke-GateStage -Name "helper-help" -Reason "always-run helper parse preflight"'
        $text | Should -Match 'Invoke-GateStage -Name "release-e2e" -Reason "always-run release runtime proof"'
        $text | Should -Match ([regex]::Escape('"-ResumeMode", $ReleaseResumeMode'))
    }

    It "balances every Pester file across isolated workers and merges JUnit" {
        $runner = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1") -Raw -Encoding UTF8
        $worker = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\run-pester-shard.ps1") -Raw -Encoding UTF8
        $runner | Should -Match '\*\.Tests\.ps1'
        $runner | Should -Match 'Sort-Object.*weight'
        $runner | Should -Match 'Start-Process'
        $runner | Should -Match 'assignment omitted or duplicated'
        $runner | Should -Match 'CreateElement\("testsuites"\)'
        $worker | Should -Match 'Invoke-Pester -Configuration'
    }

    It "accepts only exact or ancestor same-tree qualification commits" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-qualification-reuse-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $tempRoot "value.txt") -Encoding ASCII -Value "one"
            & git -C $tempRoot add value.txt; & git -C $tempRoot commit -m base *> $null
            $base = (& git -C $tempRoot rev-parse HEAD).Trim(); $baseTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            & git -C $tempRoot commit --allow-empty -m merge-like *> $null
            $descendant = (& git -C $tempRoot rev-parse HEAD).Trim(); $descendantTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            & git -C $tempRoot switch --quiet -c sibling $base *> $null; & git -C $tempRoot commit --allow-empty -m sibling *> $null
            $sibling = (& git -C $tempRoot rev-parse HEAD).Trim(); $siblingTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            Set-Content -LiteralPath (Join-Path $tempRoot "value.txt") -Encoding ASCII -Value "two"; & git -C $tempRoot add value.txt; & git -C $tempRoot commit -m changed *> $null
            $changed = (& git -C $tempRoot rev-parse HEAD).Trim(); $changedTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            . (Join-Path $RepoRoot "scripts\release-qualification.ps1")
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 2 -QualifiedCommit $base -EvidenceCommit $base -QualifiedTree $baseTree -CurrentCommit $base -CurrentTree $baseTree | Should -Be "exact-commit"
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 2 -QualifiedCommit $base -EvidenceCommit $base -QualifiedTree $baseTree -CurrentCommit $descendant -CurrentTree $descendantTree | Should -Be "ancestor-same-tree"
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 1 -QualifiedCommit $base -EvidenceCommit $base -QualifiedTree $baseTree -CurrentCommit $descendant -CurrentTree $descendantTree | Should -Be ""
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 2 -QualifiedCommit $sibling -EvidenceCommit $sibling -QualifiedTree $siblingTree -CurrentCommit $descendant -CurrentTree $descendantTree | Should -Be ""
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 2 -QualifiedCommit $base -EvidenceCommit $base -QualifiedTree $baseTree -CurrentCommit $changed -CurrentTree $changedTree | Should -Be ""
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "does not install repository-managed git hooks" {
        Test-Path -LiteralPath (Join-Path $RepoRoot ".githooks") | Should -BeFalse
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\local-quality-gate.md") -Raw -Encoding UTF8
        $text | Should -Match "Git hooks"
        $text | Should -Match "GitHub Actions"
    }

    It "keeps the five local skill directories present" {
        $expected = @(
            "1c-workflow",
            "1c-workflow-fast",
            "itl-roctup-1c-data",
            "itl-vanessa-ui-mcp",
            "product-docs"
        ) | Sort-Object
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills") -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $actual | Should -Be $expected
    }
}
