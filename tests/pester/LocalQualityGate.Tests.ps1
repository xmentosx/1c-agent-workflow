BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Local quality gate contract" {
        It "lets Windows PowerShell gate children rebuild their native module path when launched from PowerShell Core" {
        $path = Join-Path $RepoRoot "scripts\check.ps1"
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Start-PowerShellChildProcess"
        }, $true)
        $definition | Should -Not -BeNullOrEmpty
        $text = $definition.Extent.Text

        $filterOffset = $text.IndexOf('$coreModuleRoot = [IO.Path]::GetFullPath((Join-Path $PSHOME "Modules"))', [StringComparison]::Ordinal)
        $launchOffset = $text.IndexOf('Start-Process -FilePath "powershell.exe"', [StringComparison]::Ordinal)
        $restoreOffset = $text.LastIndexOf('$env:PSModulePath = $originalPowerShellModulePath', [StringComparison]::Ordinal)
        $text | Should -Match '\$resetModulePathForWindowsPowerShell = \[string\]\$PSVersionTable\.PSEdition -eq "Core"'
        $filterOffset | Should -BeGreaterThan -1
        $filterOffset | Should -BeLessThan $launchOffset
        $restoreOffset | Should -BeGreaterThan $launchOffset
        $text | Should -Match '\$env:PSModulePath = \$compatibleModuleRoots -join'
        $text | Should -Match 'try\s*\{[\s\S]+Start-Process[\s\S]+\}\s*finally\s*\{'
    }

    It "qualifies static and live candidate evidence without repeating Develop during Release" {
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8; $qualification = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-qualification.ps1") -Raw -Encoding UTF8
        $promoter = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\promote-ai-rules-compatibility.ps1") -Raw -Encoding UTF8
        $delivery = @("source-delivery.ps1", "source-delivery-supervisor.ps1", "source-delivery-process.ps1", "source-delivery-queue.ps1", "source-delivery-component.ps1", "source-delivery-candidate.ps1", "source-delivery-resources.ps1", "source-delivery-ref-cleanup.ps1", "source-delivery-cleanup.ps1" | ForEach-Object { Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\$_") -Raw -Encoding UTF8 }) -join [Environment]::NewLine
        $developJourney = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-develop-e2e.ps1") -Raw -Encoding UTF8
        $staticProducer = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts/develop-static-qualification.ps1') -Raw -Encoding UTF8
        $staticProducer | Should -Match 'itl-workflow-full-qualification'
        $staticProducer | Should -Match 'function Write-WorkflowQualification'
        $check | Should -Match '\. \(Join-Path \$PSScriptRoot "develop-static-qualification\.ps1"\)'
        $check | Should -Match 'source-delivery-ref-cleanup\.ps1' -Because 'ref cleanup code must invalidate reusable gate evidence'
        $check | Should -Match 'itl-workflow-develop-qualification'
        $check | Should -Match 'Test-DevelopQualification'
        $check | Should -Match 'Test-WorkflowQualification -Path \$qualificationFullPath.*-ForkIdentity \$aiRulesRelease'
        $check | Should -Match 'FullProof\.qualification\.repository\.commit'
        $check | Should -Match 'qualificationMatch -and \$qualificationMatch\.canReusePester'
        $check | Should -Match 'Update-DevelopQualificationFullBinding -Commit \$commit -Tree \$tree -PreviousFullProof \$releaseFullProof'
        $check | Should -Match 'Write-DevelopQualification'
        $developProofIndex = $check.IndexOf('$releaseDevelopProof = Test-DevelopQualification', [StringComparison]::Ordinal)
        $fullRewriteIndex = $check.IndexOf('$existingQualification = Write-WorkflowQualification', [StringComparison]::Ordinal)
        $developProofIndex | Should -BeGreaterThan -1; $fullRewriteIndex | Should -BeGreaterThan $developProofIndex
        $check | Should -Match 'Add-ReusedStage -Name "develop-e2e"'
        $check | Should -Match 'Test-HasExactInventory'
        $check | Should -Match 'sha256 = Get-CanonicalTextSha256 -Path \$Path'
        $check | Should -Match '\$canonicalHash = Get-CanonicalTextSha256 -Path \$path'
        $check | Should -Match '\$byteHash = \(Get-FileHash -LiteralPath \$path -Algorithm SHA256\)'
        $check | Should -Match '\$canonicalHash -ne \$expectedHash -and \$byteHash -ne \$expectedHash'
        $check | Should -Match 'static-tracked-state'; $check | Should -Match ([regex]::Escape("-split ','"))
        foreach ($gateLeaf in @('source-delivery-process.ps1','source-delivery-queue.ps1','source-delivery-component.ps1','source-delivery-candidate.ps1')) { $check | Should -Match ([regex]::Escape($gateLeaf)) }
        $delivery | Should -Match 'StatusDetail'; $delivery | Should -Match 'Invoke-SourceDeliveryPostSuccessCleanup'
        $check | Should -Match 'infrastructure-retried-once'; $check | Should -Match 'retrySafeLeaf'
        $check | Should -Match '\$plannedJourneys\.Count -gt 0 -and \$plannedJourneys\.Count -lt \$allJourneys\.Count'
        $qualification | Should -Match 'merge-base --is-ancestor'
        $promoter | Should -Match 'qualificationSha256'
        $promoter | Should -Match 'compatibilityStatus'
        $delivery | Should -Match 'Restore-DeliveryQualification'
        $delivery | Should -Match 'Enter-DeliveryOperation'; $delivery | Should -Match 'gateProcessStartedAt'; $delivery | Should -Match 'Archive-StaleDeliveryOperation'
        $delivery | Should -Match 'itl\\qualifications'; $check | Should -Match ([regex]::Escape('Stop-GateChildProcessTree -Process $process'))
        foreach ($marker in @('update-workflow', 'SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE=confirmed', 'fresh-bootstrap-init-project', 'Assert-InitializedProject', 'lifecycle-operation.json', 'fresh-status', 'Git worktree: clean', '-Windowed', '$process.Handle', 'ITL develop E2E step', 'Stop-DevelopProcessTree', 'taskkill.exe /PID $processId /T /F', 'Assert-DevelopAiRulesSourceAvailable', 'source must contain the annotated tag', 'tag/lock mismatch', 'DEVELOP_E2E_SPECIAL_PATH_REQUIRED', 'fresh-missing-suite', 'fresh-stale-export', 'warn-unverified', 'stale-export-warn', 'Assert-FreshVerificationResult', '.agent-1c\dev-branches\{0}.json', 'Assert-ExportResult', 'Read-CompactSummary -ProcessResult $result', 'develop-e2e-cleanup.ps1', 'Remove-DevelopE2EFreshProject -FreshProjectsRoot $FreshProjectsRoot')) {
            $developJourney | Should -Match ([regex]::Escape($marker))
        }
        $developJourney | Should -Match ([regex]::Escape("fresh passed.*warn"))
        $developJourney | Should -Not -Match ([regex]::Escape("fresh passed.*policy warn"))
        $developJourney | Should -Match '\[Console\]::OutputEncoding = \$utf8'
        $developJourney | Should -Match '\$OutputEncoding = \$utf8'
        $developJourney | Should -Match 'tests\\features\\ITLDevelopJourney\.feature.*stale verification boundary'
    }

    It "runs complete Pester as individually checkpointed files with bounded workers" {
        $runner = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1") -Raw -Encoding UTF8; $worker = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\run-pester-shard.ps1") -Raw -Encoding UTF8
        $localRunner = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\test.ps1") -Raw -Encoding UTF8
        $runner | Should -Match '\*\.Tests\.ps1'; $runner | Should -Match 'Get-ShardInputDigest -Paths @\(\[string\]\$item\.path\)'; $runner | Should -Match 'stopScheduling'
        $runner | Should -Match 'pendingParallel'; $runner | Should -Match 'pendingSerial'; $runner | Should -Match 'exact owner input fingerprint'; $runner | Should -Match 'CreateElement\("testsuites"\)'
        $runner | Should -Match 'Pester shard heartbeat:'; $runner | Should -Match 'Save-ShardCache -Digest \$digest -ResultPath \$resultPath -JunitPath \$workerJunit'
        $runner | Should -Match 'Expression = "weight"; Descending = \$true' -Because "long shards must start first so serial tail work fits the outer gate budget"
        $runner | Should -Match '\[string\]\$priorPlan\.inputDigest -eq \$digest'
        $runner | Should -Match 'Incomplete Pester shard cache is not empty'
        $runner | Should -Match 'Get-ShardInputDigest'; $runner | Should -Match 'itl\\pester-shards\\v1'
        $runner | Should -Match 'reusedWorkerCount'; $runner | Should -Match 'Save-ShardCache'; $runner | Should -Match 'SelectionPath'
        $runner | Should -Match 'Restore-ShardCache -Digest \$digest -ResultPath \$resultPath -JunitPath \$workerJunit -Worker \$index -TestPath'
        $runner | Should -Match 'Add-Member -NotePropertyName worker -NotePropertyValue \$Worker -Force'
        $runner | Should -Match 'Add-Member -NotePropertyName worker -NotePropertyValue \$index -Force'
        $runner | Should -Match '\$result\.paths = @\(\$TestPath\)'
        $runner | Should -Match '\$priorResult\.paths = @\(\[string\]\$item\.path\)'
        $runner | Should -Match 'Initialize-VanessaSourceBuildArchiveForPester'; $runner | Should -Match 'worktree list --porcelain'
        $runner | Should -Match 'itl\\dependencies\\vanessa-automation'; $runner | Should -Match 'Invoke-ItlImmutableFileDownload -Uri \$url -DestinationPath \$sharedArchive -ExpectedSha256 \$expected'
        $runner | Should -Match 'pesterExternalIdentityCache'; $runner | Should -Match 'pesterLegacyExternalIdentityCache'; $runner | Should -Match '\$configuredArchive'; $runner | Should -Match 'legacy scheduler or external identity normalized to exact owner inputs'
        $runner | Should -Match 'legacyInputDigests'; $runner | Should -Match 'legacyArchiveCandidates'
        $runner | Should -Match 'rev-list --max-count=8 HEAD'; $runner | Should -Match 'recentRootByHead'
        $runner | Should -Match 'hash-object --path \$RelativePath -- \$AbsolutePath'
        $runner | Should -Match 'ls-files", "-t", "-s", "-m", "-z"'
        $runner | Should -Match 'pesterTrackedIdentityCache'
        $runner | Should -Not -Match '& git -C \$RepositoryRoot diff --quiet'
        $runner | Should -Match 'fingerprintPlanMs'; $runner | Should -Match 'cacheLookupMs'; $runner | Should -Match 'workerSpanMs'
        $runner.IndexOf('$workerSpanStopwatch.Stop()') | Should -BeGreaterThan $runner.IndexOf('while (-not $stopScheduling -and $pendingSerial.Count -gt 0)')
        $runner | Should -Match '\$resetModulePathForWindowsPowerShell = \[string\]\$PSVersionTable\.PSEdition -eq "Core"'
        $runtimeOwner = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts/invoke-pester-runtime.ps1') -Raw -Encoding UTF8
        $runtimeOwner | Should -Match 'SpecialFolder\]::MyDocuments'
        $worker | Should -Match "\. \(Join-Path \`$PSScriptRoot 'invoke-pester-runtime\.ps1'\)"
        $worker.IndexOf('Initialize-PesterShardModulePath') | Should -BeGreaterThan -1
        $worker.IndexOf('Initialize-PesterShardModulePath') | Should -BeLessThan $worker.IndexOf('Import-Module Pester')
        $worker | Should -Match 'Invoke-Pester -Configuration'
        $worker | Should -Match '\$env:ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT\s*=\s*Join-Path \$fixtureRuntimeRoot "execution-guards-v2"'
        $localRunner | Should -Match '& powershell\.exe @runnerArguments'
        $localRunner | Should -Match 'itl-pester-local-'
        $localRunner | Should -Match 'SetEnvironmentVariable\("ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT", \$originalExecutionGuardFallbackRoot, "Process"\)'
    }

    It "runs owner-selected upgrade before complete Pester and records shard timing metrics" {
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $early = $check.IndexOf('owner-selected fail-fast $journey journey before complete Pester')
        $pester = $check.IndexOf('Invoke-GateStage -Name "pester"')
        $early | Should -BeGreaterOrEqual 0
        $early | Should -BeLessThan $pester
        $check | Should -Match 'Set-StageMetrics -Name "pester"'
        $check | Should -Match 'executedWorkerCount = \[int\]\$pesterShardSummary\.executedWorkerCount'
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        @($catalog.developJourneys.failFastOrder) | Should -Be @("upgrade")
        @($catalog.developJourneys.routes.upgrade.contracts) | Should -Contain "lifecycle"
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

            # PublishDevelop rebuilds a deterministic merge candidate from the
            # same remote base after every failed publication. Those sibling
            # merge commits are a continuation when their registered queue head
            # advances and owns an exact Targeted proof.
            $firstCandidate = (& git -C $tempRoot commit-tree $tree -p $base -p $current -m "Merge registered develop queue 'develop' at $current").Trim()
            Add-Content -LiteralPath (Join-Path $tempRoot "tests\pester\Fixture.Tests.ps1") -Encoding ASCII -Value "# second fix"
            & git -C $tempRoot add --all; & git -C $tempRoot commit -m "fix test again" *> $null
            $queueHead = (& git -C $tempRoot rev-parse HEAD).Trim(); $queueTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            $queueRun = [ordered]@{ schemaVersion=1; mode="Targeted"; status="passed"; exitCode=0; commit=$queueHead; tree=$queueTree; finishedAt=[DateTime]::UtcNow.ToString("o"); stages=@(
                [ordered]@{name="pester";status="passed"}, [ordered]@{name="tracked-state";status="passed"}, [ordered]@{name="git-diff-check";status="passed"}
            ) }
            [IO.File]::WriteAllText((Join-Path $runRoot "20260809-000001-000-targeted-proof.json"), (($queueRun | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $secondCandidate = (& git -C $tempRoot commit-tree $queueTree -p $base -p $queueHead -m "Merge registered develop queue 'develop' at $queueHead").Trim()
            $candidateProof = Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $firstCandidate -CurrentCommit $secondCandidate -CurrentTree $queueTree
            $candidateProof.proofKind | Should -Be "source-delivery-candidate"
            $candidateProof.targetedCommit | Should -Be $queueHead
            @($candidateProof.paths) | Should -Be @("tests/pester/Fixture.Tests.ps1")
            Test-RecordedWorkflowContinuation -Record $candidateProof -Commit $secondCandidate -Tree $queueTree | Should -BeTrue

            $badCandidate = (& git -C $tempRoot commit-tree $queueTree -p $base -p $queueHead -m "unmanaged merge candidate").Trim()
            Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $firstCandidate -CurrentCommit $badCandidate -CurrentTree $queueTree | Should -BeNullOrEmpty
            $forgedCandidate = (& git -C $tempRoot commit-tree $tree -p $base -p $queueHead -m "Merge registered develop queue 'develop' at $queueHead").Trim()
            Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $firstCandidate -CurrentCommit $forgedCandidate -CurrentTree $tree | Should -BeNullOrEmpty

            Add-Content -LiteralPath (Join-Path $tempRoot "workflow.txt") -Encoding ASCII -Value "changed"
            & git -C $tempRoot add --all; & git -C $tempRoot commit -m "change production" *> $null
            $productionCommit = (& git -C $tempRoot rev-parse HEAD).Trim(); $productionTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $base -CurrentCommit $productionCommit -CurrentTree $productionTree | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "keeps repository-only guidance alongside the managed skills without Git hooks" {
        Test-Path -LiteralPath (Join-Path $RepoRoot ".githooks") | Should -BeFalse
        $installedSkillIds = @("1c-workflow", "1c-workflow-fast", "itl-roctup-1c-data", "itl-vanessa-ui-mcp", "itl-performance", "itl-remote-runner", "itl-remote-agent", "product-docs")
        $sourcePlanningSkillIds = @(
            'grill-me', 'grill-with-docs', 'grilling', 'domain-modeling',
            'openspec-explore', 'openspec-propose', 'openspec-apply-change',
            'openspec-update-change', 'openspec-sync-specs', 'openspec-archive-change'
        )
        # BootstrapUpdate covers actual installed output and update copy boundaries.
        $expected = @($installedSkillIds + $sourcePlanningSkillIds | Sort-Object)
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills") -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $actual | Should -Be $expected
        $docs = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\local-quality-gate.md") -Raw -Encoding UTF8
        $docs | Should -Match "Git hooks"
        $docs | Should -Match "GitHub Actions"
        $docs | Should -Match "continuation\s+scope"
        $docs | Should -Match 'точный прошедший `Targeted`'
    }
}
