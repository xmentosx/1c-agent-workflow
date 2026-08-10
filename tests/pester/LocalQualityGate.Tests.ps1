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
        $text | Should -Match 'targetBudgetSeconds'; $text | Should -Match 'slowestStages'; $text | Should -Match 'ProgressPaths \(Join-Path \$outputRoot "pester-shards"\)'
        $text | Should -Match 'LastWriteTimeUtc\.Ticks'; $text | Should -Match '-ProgressPaths \$releaseProgressPaths -LogName "release-e2e"'
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1"); $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog | Should -BeTrue
        $ownedTests = @($catalog.contracts | ForEach-Object { @($_.tests) } | ForEach-Object { ([string]$_).Replace('\\','/') } | Sort-Object -Unique); @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot "tests\pester") -File -Filter "*.Tests.ps1" | ForEach-Object { "tests/pester/$($_.Name)" } | Where-Object { $_ -notin $ownedTests }) | Should -BeNullOrEmpty
        @(Get-PublicLifecycleActions -RepositoryRoot $RepoRoot).Count | Should -BeGreaterThan 50
        $known = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("docs/путь с пробелами/пример.md", "scripts/source-delivery.ps1"); @($known.unknownPaths) | Should -BeNullOrEmpty
        @($known.tests) | Should -Contain "tests/pester/SourceDelivery.Tests.ps1"
        $unknown = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("unowned/новый файл.ps1")
        @($unknown.unknownPaths) | Should -Be @("unowned/новый файл.ps1")
        $retired = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("tests/pester/TriageContract.Tests.ps1")
        @($retired.tests) | Should -Be @("tests/pester/ParserDocsBudgets.Tests.ps1")
        $roctupOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @(".agents/skills/1c-workflow/scripts/lib/agent-1c.roctup-mcp.ps1")
        @($roctupOnly.contracts.id) | Should -Be @("roctup-port-lifecycle")
        @($roctupOnly.tests) | Should -Be @("tests/pester/RoctupPortLifecycle.Tests.ps1")
        foreach ($sharedPath in @(".agents/skills/1c-workflow/scripts/lib/agent-1c.ports.ps1", ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1")) {
            $sharedSelection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($sharedPath)
            @($sharedSelection.tests) | Should -Contain "tests/pester/RoctupPortLifecycle.Tests.ps1"
            @($sharedSelection.tests) | Should -Contain "tests/pester/PortRegistryLifecycle.Tests.ps1"
        }
        $unrelatedLifecycle = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @(".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1")
        @($unrelatedLifecycle.tests) | Should -Not -Contain "tests/pester/RoctupPortLifecycle.Tests.ps1"
        $onDemandOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @(".agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1")
        @($onDemandOnly.contracts.id) | Should -Be @("mcp-hosts")
        @($onDemandOnly.tests) | Should -Contain "tests/pester/OnDemandMcp.Tests.ps1"
        @($catalog.contracts.paths | ForEach-Object { @($_) } | Where-Object { [string]$_ -in @("*", "**", "*/*") }) | Should -BeNullOrEmpty
        $catalog.PSObject.Properties["baseline"] | Should -BeNullOrEmpty
    }
    It "qualifies static and live candidate evidence without repeating Develop during Release" {
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8; $qualification = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-qualification.ps1") -Raw -Encoding UTF8
        $promoter = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\promote-ai-rules-compatibility.ps1") -Raw -Encoding UTF8; $delivery = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\source-delivery.ps1") -Raw -Encoding UTF8; $developJourney = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-develop-e2e.ps1") -Raw -Encoding UTF8
        $check | Should -Match 'itl-workflow-full-qualification'
        $check | Should -Match 'itl-workflow-develop-qualification'
        $check | Should -Match 'Test-DevelopQualification'
        $check | Should -Match 'Test-WorkflowQualification -Path \$qualificationFullPath.*-ForkIdentity \$aiRulesRelease'
        $check | Should -Match 'FullProof\.qualification\.repository\.commit'
        $check | Should -Match 'Write-DevelopQualification'
        $developProofIndex = $check.IndexOf('$releaseDevelopProof = Test-DevelopQualification', [StringComparison]::Ordinal)
        $fullRewriteIndex = $check.IndexOf('$existingQualification = Write-WorkflowQualification', [StringComparison]::Ordinal)
        $developProofIndex | Should -BeGreaterThan -1; $fullRewriteIndex | Should -BeGreaterThan $developProofIndex
        $check | Should -Match 'Add-ReusedStage -Name "develop-e2e"'
        $check | Should -Match 'Test-HasExactInventory'
        $check | Should -Match 'sha256 = Get-CanonicalTextSha256 -Path \$Path'
        $check | Should -Match '\(Get-CanonicalTextSha256 -Path \$path\) -ne'
        $check | Should -Match 'static-tracked-state'; $check | Should -Match ([regex]::Escape("-split ','"))
        $qualification | Should -Match 'merge-base --is-ancestor'
        $promoter | Should -Match 'qualificationSha256'
        $promoter | Should -Match 'compatibilityStatus'
        $delivery | Should -Match 'Restore-DeliveryQualification'
        $delivery | Should -Match 'Enter-DeliveryOperation'; $delivery | Should -Match 'gateProcessStartedAt'; $delivery | Should -Match 'Archive-StaleDeliveryOperation'
        $delivery | Should -Match 'itl\\qualifications'; $check | Should -Match ([regex]::Escape('Stop-GateChildProcessTree -Process $process'))
        foreach ($marker in @('update-workflow', 'SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE=confirmed', 'fresh-bootstrap-init-project', 'Assert-InitializedProject', 'lifecycle-operation.json', 'fresh-status', 'Git worktree: clean', '-Windowed', '$process.Handle', 'ITL develop E2E step', 'Stop-DevelopProcessTree', 'taskkill.exe /PID $processId /T /F', 'Assert-DevelopAiRulesRemoteReachable', 'MaxAttempts = 3', 'fresh-missing-suite', 'fresh-stale-export', 'Assert-FreshVerificationResult', '.agent-1c\dev-branches\{0}.json', 'Assert-ExportResult', 'Read-CompactSummary -ProcessResult $result', 'develop-e2e-cleanup.ps1', 'Remove-DevelopE2EFreshProject -FreshProjectsRoot $FreshProjectsRoot')) {
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
    It "runs complete Pester as individually checkpointed files with bounded workers" {
        $runner = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1") -Raw -Encoding UTF8; $worker = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\run-pester-shard.ps1") -Raw -Encoding UTF8
        $runner | Should -Match '\*\.Tests\.ps1'; $runner | Should -Match 'Get-ShardInputDigest -Paths @\(\[string\]\$item\.path\)'; $runner | Should -Match 'stopScheduling'
        $runner | Should -Match 'pendingParallel'; $runner | Should -Match 'pendingSerial'; $runner | Should -Match 'exact owner input fingerprint'; $runner | Should -Match 'CreateElement\("testsuites"\)'
        $runner | Should -Match 'Pester shard heartbeat:'; $runner | Should -Match 'Save-ShardCache -Digest \$digest -ResultPath \$resultPath -JunitPath \$workerJunit'
        $runner | Should -Match '\[string\]\$priorPlan\.inputDigest -eq \$digest'
        $runner | Should -Match 'Incomplete Pester shard cache is not empty'
        $runner | Should -Match 'Get-ShardInputDigest'; $runner | Should -Match 'itl\\pester-shards\\v1'
        $runner | Should -Match 'reusedWorkerCount'; $runner | Should -Match 'Save-ShardCache'; $runner | Should -Match 'SelectionPath'
        $runner | Should -Match 'Initialize-VanessaSourceBuildArchiveForPester'; $runner | Should -Match 'worktree list --porcelain'
        $runner | Should -Match 'itl\\dependencies\\vanessa-automation'; $runner | Should -Match 'Downloaded Vanessa source-build SHA256 differs from the dependency lock'
        $worker | Should -Match 'Invoke-Pester -Configuration'
    }
    It "reuses only a passed shard with the same owner inputs" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-shard-cache-" + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"
        try { New-Item -ItemType Directory -Force -Path $testRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            $testPath = Join-Path $testRoot "Cache.Tests.ps1"; Set-Content -LiteralPath $testPath -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            $catalog = [ordered]@{ schemaVersion=1; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='full';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m fixture *> $null
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $firstRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $firstRun.exitCode | Should -Be 0; $first = ($firstRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $digest = [string]$first.workers[0].inputDigest; $entryRoot = Join-Path $root ".git\itl\pester-shards\v1\$digest"; $nested = Join-Path $entryRoot ".$digest.fixture.tmp"; New-Item -ItemType Directory -Path $nested | Out-Null; Get-ChildItem -LiteralPath $entryRoot -File | Move-Item -Destination $nested
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $first.executedWorkerCount | Should -Be 1; $second.reusedWorkerCount | Should -Be 1
            Add-Content -LiteralPath $testPath -Encoding UTF8 -Value "# changed owner input"; $out3 = Join-Path $root "out3"; $thirdRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out3, "-JunitPath", (Join-Path $out3 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $thirdRun.exitCode | Should -Be 0; $third = ($thirdRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $third.executedWorkerCount | Should -Be 1
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "reuses an unchanged passed test file across runner and neighboring test repairs" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl runner путь " + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"; $scriptRoot = Join-Path $root "scripts"
        try {
            New-Item -ItemType Directory -Force -Path $testRoot, $scriptRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            $testPath = Join-Path $testRoot "Cache.Tests.ps1"; Set-Content -LiteralPath $testPath -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $scriptRoot "invoke-pester-shards.ps1") -Encoding ASCII -Value "runner-v1"
            Set-Content -LiteralPath (Join-Path $root ".gitignore") -Encoding ASCII -Value "out*/"
            $catalog = [ordered]@{ schemaVersion=1; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='full';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m v1 *> $null
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; (Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)).exitCode | Should -Be 0
            Set-Content -LiteralPath (Join-Path $scriptRoot "invoke-pester-shards.ps1") -Encoding ASCII -Value "runner-v2"; Set-Content -LiteralPath (Join-Path $testRoot "Other.Tests.ps1") -Encoding UTF8 -Value "Describe 'other' { It 'changed' { `$true | Should -BeTrue } }"; & git -C $root add --all; & git -C $root commit -m v2 *> $null
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $second.executedWorkerCount | Should -Be 0; $second.reusedWorkerCount | Should -Be 1; $second.workers[0].reuseReason | Should -Be "exact owner input fingerprint"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "restarts a failed Pester stage at the corrected test file and then runs only its downstream files" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-file-checkpoint-" + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"
        try {
            New-Item -ItemType Directory -Force -Path $testRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $testRoot "A.Tests.ps1") -Encoding UTF8 -Value "Describe 'A' { It 'passes' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $testRoot "B.Tests.ps1") -Encoding UTF8 -Value "Describe 'B' { It 'fails' { `$false | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $testRoot "C.Tests.ps1") -Encoding UTF8 -Value "Describe 'C' { It 'passes' { `$true | Should -BeTrue } }"
            $contracts = @('A','B','C') | ForEach-Object { [ordered]@{id=$_;owner='fixture';primaryTest="tests/pester/$_.Tests.ps1";gate='full';budgetSeconds=30;paths=@("fixture/$_/*");tests=@("tests/pester/$_.Tests.ps1")} }
            [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ([ordered]@{schemaVersion=1;contracts=$contracts} | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/A.Tests.ps1","tests/pester/B.Tests.ps1","tests/pester/C.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m fixture *> $null
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $first = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $first.exitCode | Should -Not -Be 0
            $failedSummary = Get-Content -LiteralPath (Join-Path $out1 "pester-shards\summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            @($failedSummary.workers.paths | ForEach-Object { Split-Path $_ -Leaf }) | Should -Be @("A.Tests.ps1", "B.Tests.ps1")

            Set-Content -LiteralPath (Join-Path $testRoot "B.Tests.ps1") -Encoding UTF8 -Value "Describe 'B' { It 'is fixed' { `$true | Should -BeTrue } }"
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $second.reusedWorkerCount | Should -Be 1; $second.executedWorkerCount | Should -Be 2
            @($second.workers | Where-Object execution -eq 'reused' | ForEach-Object { Split-Path $_.paths[0] -Leaf }) | Should -Be @("A.Tests.ps1")
            @($second.workers | Where-Object execution -eq 'executed' | ForEach-Object { Split-Path $_.paths[0] -Leaf }) | Should -Be @("B.Tests.ps1", "C.Tests.ps1")
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
    It "allows cross-tree continuation only for declared scopes with an exact passed Targeted run" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-continuation-proof-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "tests\pester") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $tempRoot "workflow.txt") -Encoding ASCII -Value "production"
            Set-Content -LiteralPath (Join-Path $tempRoot "tests\pester\Fixture.Tests.ps1") -Encoding ASCII -Value "Describe fixture {}"
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\quality-contracts.json"), '{"continuationScopes":{"static":["tests/pester/*"]}}', [Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add --all; & git -C $tempRoot commit -m base *> $null
            $base = (& git -C $tempRoot rev-parse HEAD).Trim()

            Add-Content -LiteralPath (Join-Path $tempRoot "tests\pester\Fixture.Tests.ps1") -Encoding ASCII -Value "# fixed test"
            & git -C $tempRoot add --all; & git -C $tempRoot commit -m "fix test" *> $null
            $current = (& git -C $tempRoot rev-parse HEAD).Trim(); $tree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            $runRoot = Join-Path $tempRoot ".git\itl\runs"; New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
            $run = [ordered]@{ schemaVersion=1; mode="Targeted"; status="passed"; exitCode=0; commit=$current; tree=$tree; finishedAt=[DateTime]::UtcNow.ToString("o"); stages=@(
                [ordered]@{name="pester";status="passed"}, [ordered]@{name="tracked-state";status="passed"}, [ordered]@{name="git-diff-check";status="passed"}
            ) }
            [IO.File]::WriteAllText((Join-Path $runRoot "20260809-000000-000-targeted-proof.json"), (($run | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

            . (Join-Path $RepoRoot "scripts\git-path-list.ps1")
            . (Join-Path $RepoRoot "scripts\release-qualification.ps1")
            $proof = Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $base -CurrentCommit $current -CurrentTree $tree
            @($proof.scopes) | Should -Be @("static")
            @($proof.paths) | Should -Be @("tests/pester/Fixture.Tests.ps1")
            Test-RecordedWorkflowContinuation -Record $proof -Commit $current -Tree $tree | Should -BeTrue

            Add-Content -LiteralPath (Join-Path $tempRoot "workflow.txt") -Encoding ASCII -Value "changed"
            & git -C $tempRoot add --all; & git -C $tempRoot commit -m "change production" *> $null
            $productionCommit = (& git -C $tempRoot rev-parse HEAD).Trim(); $productionTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $base -CurrentCommit $productionCommit -CurrentTree $productionTree | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "classifies Release readiness repairs as resumable Release harness changes" {
        $catalog = Get-Content -LiteralPath (Join-Path $RepoRoot "tests\quality-contracts.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        @($catalog.continuationScopes.release) | Should -Contain "scripts/test-release-readiness.ps1"
    }

    It "keeps repository-only guidance out of installed packages and preserves the five skills" {
        Test-Path -LiteralPath (Join-Path $RepoRoot ".githooks") | Should -BeFalse
        $expected = @("1c-workflow", "1c-workflow-fast", "itl-roctup-1c-data", "itl-vanessa-ui-mcp", "product-docs") | Sort-Object
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills") -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $actual | Should -Be $expected
        $docs = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\local-quality-gate.md") -Raw -Encoding UTF8
        $docs | Should -Match "Git hooks"
        $docs | Should -Match "GitHub Actions"
        $docs | Should -Match "continuation\s+scope"
        $docs | Should -Match 'точный прошедший `Targeted`'
    }
}
