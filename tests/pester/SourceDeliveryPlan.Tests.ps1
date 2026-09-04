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
    }

    It 'builds a stage DAG from changed owner inputs and reuses matching immutable evidence' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        Mock Get-QualityContractCatalog { $catalog }
        Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@($catalog.contracts[0]); tests=@('tests/pester/Runtime.Tests.ps1'); unknownPaths=@() } }
        Mock Resolve-DevelopE2EJourneyPlan { [pscustomobject]@{ journeys=@('upgrade'); unknownPaths=@() } }

        $first = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
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
