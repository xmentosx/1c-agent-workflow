BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}
Describe "Local quality gate contract" {
    It "keeps the short modes cheap and reserves broad proof for Develop and Release" {
        $path = Join-Path $RepoRoot "scripts\check.ps1"
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $text | Should -Match '\[ValidateSet\("Targeted", "Smoke", "Fast", "Full", "Develop", "Release"\)\]'; $text | Should -Match '\[string\]\$Mode = "Smoke"'
        $text | Should -Match 'Fast is deprecated and now aliases Smoke'; $text | Should -Match 'resolve-targeted-tests\.ps1'; $text | Should -Match 'smokeTests'
        $text | Should -Match 'TimeoutSeconds 5400'; $text | Should -Match 'TimeoutSeconds 7200'; $text | Should -Not -Match 'TimeoutSeconds 14400'
        $text | Should -Match 'targetBudgetSeconds'; $text | Should -Match 'slowestStages'
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1"); $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog | Should -BeTrue
        @(Get-PublicLifecycleActions -RepositoryRoot $RepoRoot).Count | Should -BeGreaterThan 50
        $known = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("docs/путь с пробелами/пример.md", "scripts/source-delivery.ps1"); @($known.unknownPaths) | Should -BeNullOrEmpty
        @($known.tests) | Should -Contain "tests/pester/SourceDelivery.Tests.ps1"
        $unknown = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("unowned/новый файл.ps1")
        @($unknown.unknownPaths) | Should -Be @("unowned/новый файл.ps1")
        $retired = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("tests/pester/TriageContract.Tests.ps1")
        @($retired.tests) | Should -Be @("tests/pester/ParserDocsBudgets.Tests.ps1")
        @($catalog.contracts.paths | ForEach-Object { @($_) } | Where-Object { [string]$_ -in @("*", "**", "*/*") }) | Should -BeNullOrEmpty
        $testFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot "tests\pester") -File -Filter "*.Tests.ps1")
        $caseCount = 0
        $lineCount = 0
        foreach ($testFile in $testFiles) {
            $testText = Get-Content -LiteralPath $testFile.FullName -Raw -Encoding UTF8
            $caseCount += ([regex]::Matches($testText, '(?m)^\s*It\s+["'']')).Count
            $lineCount += (Get-Content -LiteralPath $testFile.FullName -Encoding UTF8).Count
        }
        $testFiles.Count | Should -BeLessThan ([int]$catalog.baseline.testFiles)
        $caseCount | Should -BeLessThan ([int]$catalog.baseline.testCases)
        $lineCount | Should -BeLessThan ([int]$catalog.baseline.testLines)
    }
    It "qualifies static and live candidate evidence without repeating Develop during Release" {
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8; $qualification = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-qualification.ps1") -Raw -Encoding UTF8
        $promoter = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\promote-ai-rules-compatibility.ps1") -Raw -Encoding UTF8; $delivery = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\source-delivery.ps1") -Raw -Encoding UTF8; $developJourney = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-develop-e2e.ps1") -Raw -Encoding UTF8
        $check | Should -Match 'itl-workflow-full-qualification'
        $check | Should -Match 'itl-workflow-develop-qualification'
        $check | Should -Match 'Test-DevelopQualification'
        $check | Should -Match 'Write-DevelopQualification'
        $check | Should -Match 'Add-ReusedStage -Name "develop-e2e"'
        $check | Should -Match 'Test-HasExactInventory'
        $check | Should -Match 'static-tracked-state'; $check | Should -Match ([regex]::Escape("-split ','"))
        $qualification | Should -Match 'merge-base --is-ancestor'
        $promoter | Should -Match 'qualificationSha256'
        $promoter | Should -Match 'compatibilityStatus'
        $delivery | Should -Match 'Restore-DeliveryQualification'
        $delivery | Should -Match 'itl\\qualifications'; $check | Should -Match ([regex]::Escape('Stop-GateChildProcessTree -Process $process'))
        foreach ($marker in @('update-workflow', 'SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE=confirmed', 'fresh-bootstrap-init-project', 'Assert-InitializedProject', 'lifecycle-operation.json', 'fresh-status', 'Git worktree: clean', '-Windowed', '$process.Handle', 'ITL develop E2E step', 'Stop-DevelopProcessTree', 'taskkill.exe /PID $processId /T /F', 'fresh-missing-suite', 'fresh-stale-export', 'Assert-FreshVerificationResult', '.agent-1c\dev-branches\{0}.json', 'Assert-ExportResult', 'Read-CompactSummary -ProcessResult $result', 'develop-e2e-cleanup.ps1', 'Remove-DevelopE2EFreshProject -FreshProjectsRoot $FreshProjectsRoot')) {
            $developJourney | Should -Match ([regex]::Escape($marker))
        }
        $developJourney | Should -Match 'tests\\features\\ITLDevelopJourney\.feature.*stale verification boundary'
    }
    It "removes an exact disposable E2E repository and its registered worktree" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-e2e-cleanup-" + [guid]::NewGuid().ToString("N")); $main = Join-Path $root "d-fixture"; $branch = Join-Path $root "d-fixture-develop-golden"
        try { New-Item -ItemType Directory -Force -Path $main | Out-Null; & git -C $main init *> $null; & git -C $main config user.name "ITL Test"; & git -C $main config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $main "value.txt") -Value "one" -Encoding ASCII; & git -C $main add value.txt; & git -C $main commit -m init *> $null; & git -C $main worktree add -b itldev/develop-golden $branch *> $null; . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            Remove-DevelopE2EFreshProject -FreshProjectsRoot $root -Path $main -BranchPath $branch; Test-Path -LiteralPath $main | Should -BeFalse; Test-Path -LiteralPath $branch | Should -BeFalse
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It "runs complete Pester in isolated balanced workers" {
        $runner = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1") -Raw -Encoding UTF8; $worker = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\run-pester-shard.ps1") -Raw -Encoding UTF8
        $runner | Should -Match '\*\.Tests\.ps1'; $runner | Should -Match 'Sort-Object.*weight'; $runner | Should -Match 'assignment omitted or duplicated'
        $runner | Should -Match 'Keep them away from the parallel lifecycle workers'; $runner | Should -Match 'CreateElement\("testsuites"\)'
        $runner | Should -Match 'Get-ShardInputDigest'; $runner | Should -Match 'itl\\pester-shards\\v1'
        $runner | Should -Match 'reusedWorkerCount'; $runner | Should -Match 'Save-ShardCache'; $runner | Should -Match 'SelectionPath'
        $worker | Should -Match 'Invoke-Pester -Configuration'
    }
    It "reuses only a passed shard with the same owner inputs" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-shard-cache-" + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"
        try { New-Item -ItemType Directory -Force -Path $testRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            $testPath = Join-Path $testRoot "Cache.Tests.ps1"; Set-Content -LiteralPath $testPath -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            $catalog = [ordered]@{ schemaVersion=1; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='full';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m fixture *> $null
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $first = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -RepositoryRoot $root -OutputRoot $out1 -JunitPath (Join-Path $out1 "pester.xml") -WorkerCount 1 -SelectionPath $selectionPath | Out-String) | ConvertFrom-Json
            $out2 = Join-Path $root "out2"; $second = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -RepositoryRoot $root -OutputRoot $out2 -JunitPath (Join-Path $out2 "pester.xml") -WorkerCount 1 -SelectionPath $selectionPath | Out-String) | ConvertFrom-Json; $first.executedWorkerCount | Should -Be 1; $second.reusedWorkerCount | Should -Be 1
            Add-Content -LiteralPath $testPath -Encoding UTF8 -Value "# changed owner input"; $out3 = Join-Path $root "out3"; $third = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -RepositoryRoot $root -OutputRoot $out3 -JunitPath (Join-Path $out3 "pester.xml") -WorkerCount 1 -SelectionPath $selectionPath | Out-String) | ConvertFrom-Json; $third.executedWorkerCount | Should -Be 1
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
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
    It "keeps repository-only guidance out of installed packages and preserves the five skills" {
        Test-Path -LiteralPath (Join-Path $RepoRoot ".githooks") | Should -BeFalse
        $expected = @("1c-workflow", "1c-workflow-fast", "itl-roctup-1c-data", "itl-vanessa-ui-mcp", "product-docs") | Sort-Object
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills") -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $actual | Should -Be $expected
        $docs = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\local-quality-gate.md") -Raw -Encoding UTF8
        $docs | Should -Match "Git hooks"
        $docs | Should -Match "GitHub Actions"
    }
}
