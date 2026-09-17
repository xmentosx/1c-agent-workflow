BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $RepoRoot 'scripts\git-path-list.ps1')
    . (Join-Path $RepoRoot 'scripts\quality-contracts.ps1')
    . (Join-Path $RepoRoot 'scripts\develop-e2e-qualification.ps1')

    function Get-DeliveryTextSha256 {
        param([string]$Text)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    function Get-DeliveryFileIdentity {
        param([string]$Path)
        [ordered]@{ path=[IO.Path]::GetFullPath($Path); sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    function Get-DeliveryFileSha256 { param([string]$Path); (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    function Get-DeliveryCommonGitDirectory {
        (& git -C $script:Root rev-parse --path-format=absolute --git-common-dir).Trim()
    }
    . (Join-Path $RepoRoot 'scripts\source-delivery-plan.ps1')

    function New-PlanRepository {
        $nonAscii = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0L/Rg9GC0Yw='))
        $root = Join-Path $TestDrive ("plan repo $nonAscii " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'tests\pester') | Out-Null
        & git -C $root init --quiet -b develop; & git -C $root config user.name 'ITL Test'; & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root 'runtime.ps1'), "'v1'", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'harness.ps1'), "'h1'", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'tests\pester\Runtime.Tests.ps1'), "Describe 'runtime' { It 'works' { `$true | Should -BeTrue } }", [Text.UTF8Encoding]::new($false))
        & git -C $root add --all; & git -C $root commit --quiet -m base
        $base = (& git -C $root rev-parse HEAD).Trim()
        [IO.File]::WriteAllText((Join-Path $root 'runtime.ps1'), "'v2'", [Text.UTF8Encoding]::new($false))
        & git -C $root add runtime.ps1; & git -C $root commit --quiet -m candidate
        [pscustomobject]@{ root=$root; base=$base; commit=(& git -C $root rev-parse HEAD).Trim(); tree=(& git -C $root rev-parse 'HEAD^{tree}').Trim() }
    }

    function New-PlanCatalog {
        $contract = [pscustomobject]@{ id='runtime'; paths=@('runtime.ps1'); tests=@('tests/pester/Runtime.Tests.ps1') }
        [pscustomobject]@{
            contracts=@($contract)
            developJourneys=[pscustomobject]@{
                names=@('upgrade','fresh'); fullPaths=@('orchestrator.ps1')
                routes=[pscustomobject]@{ upgrade=[pscustomobject]@{contracts=@('runtime')}; fresh=[pscustomobject]@{contracts=@('runtime')} }
            }
        }
    }
}

Describe 'Delivery v3 immutable selective plan' {
    BeforeEach {
        $script:DeliverySupervisorCommit = '1111111111111111111111111111111111111111'
        $script:DeliverySupervisorBootstrap = $false
        $script:ResumePlan = ''
        $script:ApproveLongPlan = ''
        $script:E2EProjectRoot = ''
        $script:AiRulesSource = ''
        $script:DeliveryRequestedAiRulesSource = ''
    }

    It 'builds a stage DAG from changed owner inputs and reuses matching immutable evidence' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        $script:GateScript = Join-Path $repo.root 'check.ps1'
        Mock Get-QualityContractCatalog { $catalog }
        Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@($catalog.contracts[0]); tests=@('tests/pester/Runtime.Tests.ps1'); unknownPaths=@() } }
        Mock Resolve-DevelopE2EJourneyPlan { [pscustomobject]@{ journeys=@('upgrade'); unknownPaths=@() } }

        $first = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        $first.schemaVersion | Should -Be 1
        $first.status | Should -Be 'ready'; @($first.stages.id) | Should -Be @('develop.static','develop.upgrade'); @($first.stages.execution | Select-Object -Unique) | Should -Be @('execute')
        $proof = Join-Path $TestDrive 'proof.json'; [IO.File]::WriteAllText($proof, '{"status":"passed"}', [Text.UTF8Encoding]::new($false))
        foreach ($stage in $first.stages) { Save-DeliveryStageEvidence -Stage $stage -CandidateCommit $repo.commit -CandidateTree $repo.tree -ProofPath $proof | Out-Null }
        $second = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        @($second.stages.execution | Select-Object -Unique) | Should -Be @('reuse'); $second.planId | Should -Be $first.planId
        $saved = Save-DeliveryQualityPlan -Plan $first; $first.createdAt = [DateTime]::UtcNow.AddMinutes(1).ToString('o'); (Save-DeliveryQualityPlan -Plan $first) | Should -Be $saved
    }

    It 'blocks an unknown path without inventing a full fallback' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        Mock Get-QualityContractCatalog { $catalog }; Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@(); tests=@(); unknownPaths=@('runtime.ps1') } }
        $plan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        $plan.status | Should -Be 'blocked'; @($plan.stages.execution) | Should -Be @('blocked'); @($plan.stages.reason) | Should -Match 'QUALITY_OWNER_MISSING'
        { Assert-DeliveryQualityPlanMayRun -Plan $plan } | Should -Throw '*QUALITY_OWNER_MISSING*'
    }

    It 'does not invalidate an independent runtime fingerprint when only harness content changes' {
        $repo = New-PlanRepository; $script:Root = $repo.root
        $before = Get-DeliveryInputFingerprint -StageId 'release.runtime' -Version 1 -CandidateRoot $repo.root -ExactPath @('runtime.ps1')
        [IO.File]::WriteAllText((Join-Path $repo.root 'harness.ps1'), "'h2'", [Text.UTF8Encoding]::new($false))
        $after = Get-DeliveryInputFingerprint -StageId 'release.runtime' -Version 1 -CandidateRoot $repo.root -ExactPath @('runtime.ps1')
        $after | Should -Be $before
    }

    It 'fingerprints the current complete production input set rather than only the latest diff' {
        $repo = New-PlanRepository; $script:Root = $repo.root
        $before = Get-DeliveryInputFingerprint -StageId 'release.runtime' -Version 1 -CandidateRoot $repo.root -Pattern @('runtime.ps1')
        [IO.File]::WriteAllText((Join-Path $repo.root 'runtime.ps1'), "'v3'", [Text.UTF8Encoding]::new($false))
        $after = Get-DeliveryInputFingerprint -StageId 'release.runtime' -Version 1 -CandidateRoot $repo.root -Pattern @('runtime.ps1')
        $after | Should -Not -Be $before
    }

    It 'keeps Develop evidence reusable when helpers only rewrite volatile stand context' {
        $stand = Join-Path $TestDrive 'stand identity'
        New-Item -ItemType Directory -Force -Path (Join-Path $stand '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $stand '.agent-1c\project.json'), '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $stand '.agent-1c\release-e2e.json'), '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
        $envPath = Join-Path $stand '.dev.env'
        [IO.File]::WriteAllText($envPath, "PLATFORM_PATH=C:\\1cv8`nEXPORT_PATH=src/cf`nEXTENSION_NAME=FirstExtension`nITL_ACTIVE_CONTEXT_UPDATED_AT=first`nROCTUP_MCP_PORT=6001`n", [Text.UTF8Encoding]::new($false))
        $script:E2EProjectRoot = $stand
        $before = Get-DeliveryPlanEnvironmentIdentity -Mode Develop
        $before.environmentIdentitySchemaVersion | Should -Be 2

        [IO.File]::WriteAllText($envPath, "PLATFORM_PATH=C:\\1cv8`nEXPORT_PATH=`nEXTENSION_NAME=`nITL_ACTIVE_CONTEXT_UPDATED_AT=second`nROCTUP_MCP_PORT=6002`nFUTURE_HELPER_OUTPUT=changed`n", [Text.UTF8Encoding]::new($false))
        $volatileRewrite = Get-DeliveryPlanEnvironmentIdentity -Mode Develop
        (Get-DeliveryCanonicalJsonSha256 -Value $volatileRewrite) | Should -Be (Get-DeliveryCanonicalJsonSha256 -Value $before)

        [IO.File]::WriteAllText($envPath, "PLATFORM_PATH=C:\\new-1cv8`nEXPORT_PATH=src/cfe`nEXTENSION_NAME=SecondExtension`nITL_ACTIVE_CONTEXT_UPDATED_AT=third`nROCTUP_MCP_PORT=6003`n", [Text.UTF8Encoding]::new($false))
        $materialRewrite = Get-DeliveryPlanEnvironmentIdentity -Mode Develop
        (Get-DeliveryCanonicalJsonSha256 -Value $materialRewrite) | Should -Not -Be (Get-DeliveryCanonicalJsonSha256 -Value $before)
    }

    It 'keeps durable publication identity stable across helper-owned dev-env rewrites' {
        $candidateSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-candidate.ps1') -Raw -Encoding UTF8
        $functionText = [regex]::Match($candidateSource, '(?ms)^function Get-DevelopPublicationEnvironmentIdentity \{.*?^\}').Value
        & {
            Invoke-Expression $functionText
            $stand = Join-Path $TestDrive 'durable stand identity'; $develop = Join-Path $stand 'develop'
            New-Item -ItemType Directory -Force -Path (Join-Path $stand '.agent-1c'), $develop | Out-Null
            [IO.File]::WriteAllText((Join-Path $stand '.agent-1c\project.json'), '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $stand '.agent-1c\release-e2e.json'), ('{"developWorktreePath":"' + ($develop -replace '\\','\\\\') + '"}'), [Text.UTF8Encoding]::new($false))
            $envPath = Join-Path $stand '.dev.env'; $script:E2EProjectRoot = $stand
            function Invoke-RepositoryGit { param([string]$RepositoryRoot,[string[]]$Arguments,[switch]$AllowFailure); if ($Arguments[0] -eq 'rev-parse') { return [pscustomobject]@{exitCode=0;stdout=('a' * 40)} }; return [pscustomobject]@{exitCode=0;stdout=''} }
            [IO.File]::WriteAllText($envPath, "PLATFORM_PATH=C:\\1cv8`nITL_ACTIVE_CONTEXT_UPDATED_AT=first`nROCTUP_MCP_PORT=6001`n", [Text.UTF8Encoding]::new($false))
            $before = Get-DevelopPublicationEnvironmentIdentity
            [IO.File]::WriteAllText($envPath, "PLATFORM_PATH=C:\\1cv8`nITL_ACTIVE_CONTEXT_UPDATED_AT=second`nROCTUP_MCP_PORT=6002`nFUTURE_HELPER_OUTPUT=changed`n", [Text.UTF8Encoding]::new($false))
            (Get-DevelopPublicationEnvironmentIdentity) | Should -Be $before
            [IO.File]::WriteAllText($envPath, "PLATFORM_PATH=C:\\new-1cv8`nITL_ACTIVE_CONTEXT_UPDATED_AT=third`n", [Text.UTF8Encoding]::new($false))
            (Get-DevelopPublicationEnvironmentIdentity) | Should -Not -Be $before
        }
    }

    It 'canonicalizes allowlisted env inputs without persisting secret values' {
        $first = Join-Path $TestDrive 'first.env'
        $second = Join-Path $TestDrive 'second.env'
        $missing = Join-Path $TestDrive 'missing.env'
        $empty = Join-Path $TestDrive 'empty.env'
        [IO.File]::WriteAllText($first, "# comment`nIB_PASSWORD=old`n PLATFORM_PATH = 'C:\\1cv8' `nIB_PASSWORD=secret-value`nFUTURE_HELPER_OUTPUT=one`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($second, "IB_PASSWORD = `"secret-value`"`r`n# another comment`r`nFUTURE_HELPER_OUTPUT=two`r`nPLATFORM_PATH=C:\\1cv8`r`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($missing, "# PLATFORM_ARGS is absent`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($empty, "PLATFORM_ARGS=`n", [Text.UTF8Encoding]::new($false))

        $firstHash = Get-DeliveryStableDotEnvSha256 -Path $first
        $firstHash | Should -Be (Get-DeliveryStableDotEnvSha256 -Path $second)
        $firstHash | Should -Not -Match 'secret-value'
        (Get-DeliveryStableDotEnvSha256 -Path $missing) | Should -Not -Be (Get-DeliveryStableDotEnvSha256 -Path $empty)

        $missingHash = Get-DeliveryStableDotEnvSha256 -Path $missing
        foreach ($name in @(Get-DeliveryPlanSemanticDotEnvNames)) {
            [IO.File]::WriteAllText($empty, "$name=semantic-value`n", [Text.UTF8Encoding]::new($false))
            (Get-DeliveryStableDotEnvSha256 -Path $empty) | Should -Not -Be $missingHash -Because "$name is a declared semantic plan input"
        }
    }

    It 'identifies the maintainer Vanessa source build by bytes rather than its path' {
        $stand = Join-Path $TestDrive 'source build stand'
        New-Item -ItemType Directory -Force -Path (Join-Path $stand '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $stand '.agent-1c\project.json'), '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $stand '.agent-1c\release-e2e.json'), '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $stand '.dev.env'), "PLATFORM_PATH=C:\\1cv8`n", [Text.UTF8Encoding]::new($false))
        $archive = Join-Path $TestDrive 'candidate archive.zip'
        $copy = Join-Path $TestDrive 'same archive elsewhere.zip'
        [IO.File]::WriteAllText($archive, 'first bytes', [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath $archive -Destination $copy
        $savedArchive = [Environment]::GetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', 'Process')
        try {
            $script:E2EProjectRoot = $stand
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archive
            $before = Get-DeliveryPlanEnvironmentIdentity -Mode Release
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $copy
            $sameBytes = Get-DeliveryPlanEnvironmentIdentity -Mode Release
            (Get-DeliveryCanonicalJsonSha256 -Value $sameBytes) | Should -Be (Get-DeliveryCanonicalJsonSha256 -Value $before)
            (($before | ConvertTo-Json -Depth 8) -join '') | Should -Not -Match ([regex]::Escape($archive))

            [IO.File]::WriteAllText($copy, 'second bytes', [Text.UTF8Encoding]::new($false))
            $changed = Get-DeliveryPlanEnvironmentIdentity -Mode Release
            (Get-DeliveryCanonicalJsonSha256 -Value $changed) | Should -Not -Be (Get-DeliveryCanonicalJsonSha256 -Value $before)
        } finally {
            [Environment]::SetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', $savedArchive, 'Process')
        }
    }

    It 'keys ai rules identity by commit and tree rather than temporary checkout path' {
        $repo = New-PlanRepository
        $clone = Join-Path $TestDrive 'equivalent rules checkout'
        & git clone --quiet -- $repo.root $clone
        $LASTEXITCODE | Should -Be 0

        $script:AiRulesSource = $repo.root
        $before = Get-DeliveryPlanEnvironmentIdentity -Mode Release
        $script:AiRulesSource = $clone
        $after = Get-DeliveryPlanEnvironmentIdentity -Mode Release

        (Get-DeliveryCanonicalJsonSha256 -Value $after) | Should -Be (Get-DeliveryCanonicalJsonSha256 -Value $before)
    }

    It 'resolves the locked controlled fork before accumulated plan runtime fingerprints' {
        $planSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-plan.ps1') -Raw -Encoding UTF8
        $resolverText = [regex]::Match($planSource, '(?ms)^function Resolve-DeliveryPlanAiRulesSource \{.*?^\}').Value
        $accumulatedText = [regex]::Match($planSource, '(?ms)^function New-AccumulatedDeliveryPlan \{.*?^\}').Value
        $resolverText | Should -Match 'Resolve-DeliveryAiRulesSource -Lock \$aiRulesLock'
        $accumulatedText | Should -Match 'Resolve-DeliveryPlanAiRulesSource[\s\S]*New-DeliveryQualityPlanForCandidate'

        & {
            Invoke-Expression $resolverText
            $candidateRoot = Join-Path $TestDrive 'plan locked rules candidate'
            New-Item -ItemType Directory -Force -Path (Join-Path $candidateRoot 'templates') | Out-Null
            $lock = [ordered]@{ dependencies = [ordered]@{ aiRules1c = [ordered]@{ repo='https://example.invalid/ai_rules_1c.git'; commit=('a' * 40) } } }
            [IO.File]::WriteAllText((Join-Path $candidateRoot 'templates\dependency-lock.json'), ($lock | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            $script:DeliveryCustomGateBoundary = $false
            $script:seenRulesLock = $null
            function Resolve-DeliveryAiRulesSource {
                param([object]$Lock)
                $script:seenRulesLock = $Lock
                $script:AiRulesSource = 'C:\exact-rules'
                return $script:AiRulesSource
            }

            (Resolve-DeliveryPlanAiRulesSource -CandidateRoot $candidateRoot) | Should -Be 'C:\exact-rules'
            [string]$script:seenRulesLock.commit | Should -Be ('a' * 40)
            $script:AiRulesSource | Should -Be 'C:\exact-rules'
        }
    }

    It 'requires exact explicit approval for a plan whose selected stages exceed sixty minutes' {
        $plan = [pscustomobject]@{ status='ready'; planId='long-plan'; executedBudgetSeconds=3601 }
        { Assert-DeliveryQualityPlanMayRun -Plan $plan } | Should -Throw '*LONG_PLAN_APPROVAL_REQUIRED*'
        $script:ApproveLongPlan = 'long-plan'; { Assert-DeliveryQualityPlanMayRun -Plan $plan } | Should -Not -Throw
    }

    It 'keeps the supervisor stage catalog identical to candidate Release capability definitions' {
        . (Join-Path $RepoRoot 'scripts\release-e2e\common.ps1')
        foreach ($module in @('seed-parallel.ps1','server-reset.ps1','config-cadence.ps1','config-roundtrip.ps1','extension-smoke.ps1','ondemand-mcp.ps1','result-cleanup.ps1')) {
            . (Join-Path $RepoRoot "scripts\release-e2e\$module")
        }
        $catalog = Get-DeliveryReleaseStageCatalog -CandidateRoot $RepoRoot
        @($catalog.stages.id) | Should -Be @($script:ReleaseE2EStageDefinitions.Keys)
        foreach ($stage in $catalog.stages) {
            $definition = $script:ReleaseE2EStageDefinitions[[string]$stage.id]
            [int]$stage.version | Should -Be ([int]$definition.version)
            @($stage.dependsOn) | Should -Be @($definition.dependsOn)
            $expectedPaths = @($definition.paths) + @("scripts/release-e2e/$([string]$definition.moduleFile)")
            @($stage.paths | Sort-Object) | Should -Be @($expectedPaths | Sort-Object)
        }
    }
}
