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
    $checkerTokens = $null; $checkerErrors = $null
    $checkerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts\check.ps1'), [ref]$checkerTokens, [ref]$checkerErrors)
    if (@($checkerErrors).Count -gt 0) { throw 'The candidate checker did not parse.' }
    $routeDefinition = $checkerAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Ensure-DevelopE2ERoute'
    }, $true)
    if (-not $routeDefinition) { throw 'The candidate checker journey owner is missing.' }
    Invoke-Expression $routeDefinition.Extent.Text
    $identityDefinition = $checkerAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DevelopE2EIdentitySha256'
    }, $true)
    if (-not $identityDefinition) { throw 'The candidate checker identity collaborator is missing.' }
    Invoke-Expression $identityDefinition.Extent.Text
    function Invoke-GateStage { param([string]$Name, [string]$Reason, [string]$Detail, [scriptblock]$Body); & $Body }
    function Invoke-PowerShellChild { param([string]$ScriptPath, [string[]]$Arguments, [int]$TimeoutSeconds, [int]$NoProgressSeconds, [string]$LogName); throw 'Unexpected native child launch in budget fixture.' }

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
            budgets=[pscustomobject]@{ fullHardSeconds=2400 }
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
        $script:DeliverySupervisorChannel = 'master'
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

    It 'budgets Develop journeys again when matching owner evidence belongs to an older tree' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        $script:GateScript = Join-Path $repo.root 'check.ps1'
        Mock Get-QualityContractCatalog { $catalog }
        Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@($catalog.contracts[0]); tests=@('tests/pester/Runtime.Tests.ps1'); unknownPaths=@() } }
        Mock Resolve-DevelopE2EJourneyPlan { [pscustomobject]@{ journeys=@('upgrade','fresh'); unknownPaths=@() } }

        $oldPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        $proof = Join-Path $TestDrive 'older-tree-proof.json'
        [IO.File]::WriteAllText($proof, '{"status":"passed"}', [Text.UTF8Encoding]::new($false))
        foreach ($stage in $oldPlan.stages) {
            Save-DeliveryStageEvidence -Stage $stage -CandidateCommit $repo.commit -CandidateTree $repo.tree -ProofPath $proof | Out-Null
        }
        $reusedOldPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        @($reusedOldPlan.stages.execution | Select-Object -Unique) | Should -Be @('reuse')

        [IO.File]::WriteAllText((Join-Path $repo.root 'harness.ps1'), "'h2'", [Text.UTF8Encoding]::new($false))
        & git -C $repo.root add harness.ps1
        & git -C $repo.root commit --quiet -m 'change delivery harness'
        $newCommit = (& git -C $repo.root rev-parse HEAD).Trim()
        $newTree = (& git -C $repo.root rev-parse 'HEAD^{tree}').Trim()
        $newPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $newCommit -CandidateTree $newTree

        @($newPlan.stages.execution | Select-Object -Unique) | Should -Be @('execute')
        $newPlan.stages[0].budgetSeconds | Should -Be 2400
        $newPlan.executedBudgetSeconds | Should -Be 5700
        (Get-DeliveryPlanGateBudgetSeconds -Plan $newPlan -Mode Develop) | Should -Be 5700
        $newPlan.stages[1].inputFingerprint | Should -Not -Be $oldPlan.stages[1].inputFingerprint
        $reusedOldPlan.candidate.tree = $newTree
        (Restore-DeliveryPlanQualification -Plan $reusedOldPlan -CandidateRoot $repo.root) | Should -BeFalse
    }

    It 'passes the same catalog budget from the actual checker and immutable planner to each journey' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        $catalog.budgets.fullHardSeconds = 2700
        $catalog.developJourneys.routes.upgrade | Add-Member -NotePropertyName hardSeconds -NotePropertyValue 1200
        $catalog.developJourneys.routes.fresh | Add-Member -NotePropertyName hardSeconds -NotePropertyValue 3600
        $script:GateScript = Join-Path $repo.root 'check.ps1'
        Mock Get-QualityContractCatalog { $catalog }
        Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@($catalog.contracts[0]); tests=@('tests/pester/Runtime.Tests.ps1'); unknownPaths=@() } }
        Mock Resolve-DevelopE2EJourneyPlan { [pscustomobject]@{ journeys=@('upgrade','fresh'); unknownPaths=@() } }
        $plan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        $plan.executedBudgetSeconds | Should -Be 7500
        (Get-DeliveryPlanGateBudgetSeconds -Plan $plan -Mode Develop) | Should -Be 7500

        $script:qualityCatalog = $catalog
        $script:developQualificationRoot = Join-Path $TestDrive 'checker budgets'
        New-Item -ItemType Directory -Force -Path $script:developQualificationRoot | Out-Null
        $script:releaseContext = [pscustomobject]@{}; $script:aiRulesRelease = [pscustomobject]@{}
        $script:developRulesSource = $repo.root; $script:developScript = Join-Path $repo.root 'journey.ps1'
        $repoRoot = $repo.root; $outputRoot = $script:developQualificationRoot; $tree = $repo.tree
        $E2EProjectRoot = $repo.root; $AgentTarget = 'kilocode'
        Mock Get-DevelopE2EIdentitySha256 { 'a' * 64 }
        Mock Get-DevelopE2EStandStateSha256 { 'b' * 64 }
        Mock Restore-DevelopE2EQualification { $false }
        Mock Invoke-PowerShellChild {
            $script:observedJourneyBudget = $TimeoutSeconds
            throw 'fixture child boundary'
        }
        foreach ($journey in @('upgrade','fresh')) {
            { Ensure-DevelopE2ERoute -Journey $journey -Plan $plan } | Should -Throw '*fixture child boundary*'
            $stage = @($plan.stages | Where-Object id -eq "develop.$journey")[0]
            $script:observedJourneyBudget | Should -Be $stage.budgetSeconds
        }
        Should -Invoke Invoke-PowerShellChild -Exactly -Times 2 -ParameterFilter {
            $NoProgressSeconds -eq 900 -and $Arguments -contains '-AgentTarget' -and $Arguments -contains 'kilocode'
        }
    }

    It 'changes the immutable plan identity and refuses old-tree reuse when the committed fresh budget changes' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        $catalog.budgets.fullHardSeconds = 2700
        $catalogPath = Join-Path $repo.root 'tests\quality-contracts.json'
        [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        & git -C $repo.root add -- tests/quality-contracts.json
        & git -C $repo.root commit --quiet -m 'record legacy route catalog'
        $oldCommit = (& git -C $repo.root rev-parse HEAD).Trim(); $oldTree = (& git -C $repo.root rev-parse 'HEAD^{tree}').Trim()
        $script:GateScript = Join-Path $repo.root 'check.ps1'
        Mock Get-QualityContractCatalog { Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@($catalog.contracts[0]); tests=@('tests/pester/Runtime.Tests.ps1'); unknownPaths=@() } }
        Mock Resolve-DevelopE2EJourneyPlan { [pscustomobject]@{ journeys=@('upgrade','fresh'); unknownPaths=@() } }
        $oldPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $oldCommit -CandidateTree $oldTree
        $oldPlan.executedBudgetSeconds | Should -Be 6000
        $proof = Join-Path $TestDrive 'prior-budget-proof.json'
        [IO.File]::WriteAllText($proof, '{"status":"passed"}', [Text.UTF8Encoding]::new($false))
        foreach ($stage in $oldPlan.stages) { Save-DeliveryStageEvidence -Stage $stage -CandidateCommit $oldCommit -CandidateTree $oldTree -ProofPath $proof | Out-Null }
        $reused = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $oldCommit -CandidateTree $oldTree
        @($reused.stages.execution | Select-Object -Unique) | Should -Be @('reuse')

        $catalog.developJourneys.routes.fresh | Add-Member -NotePropertyName hardSeconds -NotePropertyValue 3600
        [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        & git -C $repo.root add -- tests/quality-contracts.json
        & git -C $repo.root commit --quiet -m 'extend the unchanged fresh proof deadline'
        $newCommit = (& git -C $repo.root rev-parse HEAD).Trim(); $newTree = (& git -C $repo.root rev-parse 'HEAD^{tree}').Trim()
        $newPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $newCommit -CandidateTree $newTree
        $newPlan.executedBudgetSeconds | Should -Be 7500
        $newPlan.planId | Should -Not -Be $oldPlan.planId
        @($newPlan.stages.execution | Select-Object -Unique) | Should -Be @('execute')
        $newPlan.stages[2].budgetSeconds | Should -Be 3600
        $newPlan.stages[2].inputFingerprint | Should -Not -Be $oldPlan.stages[2].inputFingerprint
    }

    It 'blocks an unknown path without inventing a full fallback' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        Mock Get-QualityContractCatalog { $catalog }; Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@(); tests=@(); unknownPaths=@('runtime.ps1') } }
        $plan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        $plan.status | Should -Be 'blocked'; @($plan.stages.execution) | Should -Be @('blocked'); @($plan.stages.reason) | Should -Match 'QUALITY_OWNER_MISSING'
        { Assert-DeliveryQualityPlanMayRun -Plan $plan } | Should -Throw '*QUALITY_OWNER_MISSING*'
    }

    It 'pins the authority channel into the immutable plan identity' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        $script:GateScript = Join-Path $repo.root 'check.ps1'
        Mock Get-QualityContractCatalog { $catalog }
        Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@($catalog.contracts[0]); tests=@('tests/pester/Runtime.Tests.ps1'); unknownPaths=@() } }
        Mock Resolve-DevelopE2EJourneyPlan { [pscustomobject]@{ journeys=@(); unknownPaths=@() } }

        $masterPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        $script:DeliverySupervisorChannel = 'develop'
        $developPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        $masterPlan.supervisor.channel | Should -Be 'master'
        $developPlan.supervisor.channel | Should -Be 'develop'
        $developPlan.planId | Should -Not -Be $masterPlan.planId
    }

    It 'selects only requested Release capabilities and their dependencies' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        $script:GateScript = Join-Path $repo.root 'check.ps1'
        Mock Get-QualityContractCatalog { $catalog }
        Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@($catalog.contracts[0]); tests=@('tests/pester/Runtime.Tests.ps1'); unknownPaths=@() } }
        Mock Resolve-DevelopE2EJourneyPlan { [pscustomobject]@{ journeys=@(); unknownPaths=@() } }
        Mock Get-DeliveryPlanEnvironmentIdentity { param([string]$Mode) [ordered]@{ mode=$Mode } }
        Mock Get-DeliveryReleaseStageCatalog {
            [pscustomobject]@{ stages=@(
                [pscustomobject]@{ id='config-cadence'; version=1; budgetSeconds=10; dependsOn=@(); paths=@('runtime.ps1') },
                [pscustomobject]@{ id='extension-smoke'; version=1; budgetSeconds=10; dependsOn=@('config-cadence'); paths=@('runtime.ps1') },
                [pscustomobject]@{ id='ondemand-mcp'; version=1; budgetSeconds=10; dependsOn=@(); paths=@('runtime.ps1') }
            ) }
        }

        $componentPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -ReleaseCapability 'ondemand-mcp'
        @($componentPlan.releaseCapabilities) | Should -Be @('ondemand-mcp')
        @($componentPlan.stages.id | Where-Object { $_ -like 'release.*' }) | Should -Be @('release.ondemand-mcp')

        $vanessaPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -ReleaseCapability 'extension-smoke'
        @($vanessaPlan.releaseCapabilities) | Should -Be @('config-cadence','extension-smoke')
        @($vanessaPlan.stages.id | Where-Object { $_ -like 'release.*' }) | Should -Be @('release.config-cadence','release.extension-smoke')

        $combinedPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -ReleaseCapability @('extension-smoke','ondemand-mcp')
        @($combinedPlan.releaseCapabilities) | Should -Be @('config-cadence','extension-smoke','ondemand-mcp')

        $fullPlan = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -RequireRelease
        @($fullPlan.releaseCapabilities) | Should -Be @('config-cadence','extension-smoke','ondemand-mcp')
    }

    It 'pins the enclosing Release reserve once and preserves continuation scope and reusable evidence' {
        $repo = New-PlanRepository; $script:Root = $repo.root; $catalog = New-PlanCatalog
        $catalog.budgets | Add-Member -NotePropertyName releaseHardSeconds -NotePropertyValue 9240
        $releaseCatalog = [pscustomobject]@{ enclosingOverheadSeconds=1140; stages=@(
            [pscustomobject]@{ id='config-cadence'; version=3; budgetSeconds=4800; dependsOn=@(); paths=@('runtime.ps1') },
            [pscustomobject]@{ id='extension-smoke'; version=2; budgetSeconds=900; dependsOn=@('config-cadence'); paths=@('runtime.ps1') }
        ) }
        $script:GateScript = Join-Path $repo.root 'check.ps1'
        Mock Get-QualityContractCatalog { $catalog }
        Mock Test-QualityContractCatalog { $true }
        Mock Resolve-QualityContractsForPaths { [pscustomobject]@{ contracts=@($catalog.contracts[0]); tests=@('tests/pester/Runtime.Tests.ps1'); unknownPaths=@() } }
        Mock Resolve-DevelopE2EJourneyPlan { [pscustomobject]@{ journeys=@(); unknownPaths=@() } }
        Mock Get-DeliveryPlanEnvironmentIdentity { param([string]$Mode) [ordered]@{ mode=$Mode } }
        Mock Get-DeliveryReleaseStageCatalog { $releaseCatalog }
        Mock Test-DeliveryStageEvidence { $null }
        $none = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree
        $none.PSObject.Properties.Name | Should -Not -Contain 'releaseEnclosingOverheadSeconds'
        $none.executedBudgetSeconds | Should -Be 2400
        $first = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -ReleaseCapability 'extension-smoke'
        $first.releaseCapabilities | Should -Be @('config-cadence','extension-smoke')
        $first.stages.id | Should -Be @('develop.static','release.config-cadence','release.extension-smoke')
        $first.executedBudgetSeconds | Should -Be 9240
        Get-DeliveryPlanGateBudgetSeconds -Plan $first -Mode Release | Should -Be 6840
        # Original 2026-10-07 Release ran out of the 900s extension budget after
        # UI passed and CFE apply, during canonical dump and before final restore.
        # Budget correction must preserve the same capability work and evidence.
        $productionStages = Get-QualityReleaseStageCatalog -RepositoryRoot $RepoRoot
        ($releaseCatalog.stages | Where-Object id -eq 'extension-smoke').budgetSeconds =
            [int]($productionStages.stages | Where-Object id -eq 'extension-smoke').budgetSeconds
        $catalog.budgets.releaseHardSeconds = 9540
        $budgetCorrected = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -ReleaseCapability 'extension-smoke'
        ($budgetCorrected.stages | Where-Object id -eq 'release.extension-smoke').budgetSeconds | Should -Be 1200
        ($budgetCorrected.stages | Where-Object id -eq 'release.config-cadence').budgetSeconds | Should -Be 4800
        $budgetCorrected.executedBudgetSeconds | Should -Be 9540
        Get-DeliveryPlanGateBudgetSeconds -Plan $budgetCorrected -Mode Release | Should -Be 7140
        $budgetCorrected.planId | Should -Not -Be $first.planId
        $budgetCorrected.stages.inputFingerprint | Should -Be $first.stages.inputFingerprint
        $budgetCorrected.releaseCapabilities | Should -Be $first.releaseCapabilities
        $budgetCorrected.releaseEnclosingOverheadSeconds | Should -Be 1140
        $releaseCatalog.enclosingOverheadSeconds = 1200
        $catalog.budgets.releaseHardSeconds = 9600
        $corrected = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -ReleaseCapability 'extension-smoke'
        $corrected.planId | Should -Not -Be $first.planId
        $corrected.planId | Should -Not -Be $budgetCorrected.planId
        $corrected.stages.inputFingerprint | Should -Be $first.stages.inputFingerprint
        $first.releaseEnclosingOverheadSeconds | Should -Be 1140
        # Both original backend probes passed in 1177.836s on 2026-10-08,
        # then the stage correctly rejected the obsolete 900s ceiling.
        # Correct its owner budget without changing capability fingerprints.
        $releaseCatalog.stages += [pscustomobject]@{ id='ondemand-mcp'; version=5; budgetSeconds=900; dependsOn=@(); paths=@('runtime.ps1') }
        $catalog.budgets.releaseHardSeconds = 10500
        $mcpBefore = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -ReleaseCapability @('extension-smoke','ondemand-mcp')
        ($releaseCatalog.stages | Where-Object id -eq 'ondemand-mcp').budgetSeconds =
            [int]($productionStages.stages | Where-Object id -eq 'ondemand-mcp').budgetSeconds
        $catalog.budgets.releaseHardSeconds = 11100
        $mcpAfter = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -ReleaseCapability @('extension-smoke','ondemand-mcp')
        ($mcpAfter.stages | Where-Object id -eq 'release.ondemand-mcp').budgetSeconds | Should -Be 1500
        $mcpAfter.planId | Should -Not -Be $mcpBefore.planId
        $mcpAfter.stages.inputFingerprint | Should -Be $mcpBefore.stages.inputFingerprint
        $mcpAfter.releaseCapabilities | Should -Be $mcpBefore.releaseCapabilities
        ($mcpAfter.executedBudgetSeconds - $mcpBefore.executedBudgetSeconds) | Should -Be 600
        ((Get-DeliveryPlanGateBudgetSeconds -Plan $mcpAfter -Mode Release) - (Get-DeliveryPlanGateBudgetSeconds -Plan $mcpBefore -Mode Release)) | Should -Be 600
        Mock Test-DeliveryStageEvidence { [pscustomobject]@{ candidate=[pscustomobject]@{ tree=$repo.tree } } }
        $reused = New-DeliveryQualityPlanForCandidate -CandidateRoot $repo.root -BaseCommit $repo.base -CandidateCommit $repo.commit -CandidateTree $repo.tree -ReleaseCapability 'extension-smoke'
        @($reused.stages | Where-Object execution -eq 'execute').Count | Should -Be 0
        $reused.executedBudgetSeconds | Should -Be 1200
        Get-DeliveryPlanGateBudgetSeconds -Plan $reused -Mode Release | Should -Be 1200
        $reused.releaseCapabilities | Should -Be @('config-cadence','extension-smoke')
        $reused.planId | Should -Be $corrected.planId
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
        $before.environmentIdentitySchemaVersion | Should -Be 3

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

    It 'invalidates clientMcp qualification when the configured CFE bytes change' {
        $file = Join-Path $TestDrive 'client build.cfe'
        $copy = Join-Path $TestDrive 'same client elsewhere.cfe'
        [IO.File]::WriteAllBytes($file, [byte[]]@(1,2,3))
        [IO.File]::Copy($file, $copy)
        $saved = [Environment]::GetEnvironmentVariable('VANESSA_MCP_CLIENT_CFE_PATH', 'Process')
        try {
            $env:VANESSA_MCP_CLIENT_CFE_PATH = $file
            $before = Get-DeliveryPlanEnvironmentIdentity -Mode Release
            $env:VANESSA_MCP_CLIENT_CFE_PATH = $copy
            (Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanEnvironmentIdentity -Mode Release)) | Should -Be (Get-DeliveryCanonicalJsonSha256 $before)
            [IO.File]::WriteAllBytes($copy, [byte[]]@(1,2,4))
            (Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanEnvironmentIdentity -Mode Release)) | Should -Not -Be (Get-DeliveryCanonicalJsonSha256 $before)
        } finally { [Environment]::SetEnvironmentVariable('VANESSA_MCP_CLIENT_CFE_PATH', $saved, 'Process') }
    }

    It 'resolves the locked controlled fork before accumulated plan runtime fingerprints' {
        $planSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-plan.ps1') -Raw -Encoding UTF8
        $candidateSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-candidate.ps1') -Raw -Encoding UTF8
        $resolverText = [regex]::Match($planSource, '(?ms)^function Resolve-DeliveryPlanAiRulesSource \{.*?^\}').Value
        $accumulatedText = [regex]::Match($planSource, '(?ms)^function New-AccumulatedDeliveryPlan \{.*?^\}').Value
        $publishText = [regex]::Match($candidateSource, '(?ms)^function Publish-AccumulatedDevelop \{.*?^\}').Value
        $resolverText | Should -Match 'Resolve-DeliveryAiRulesSource -Lock \$aiRulesLock'
        $accumulatedText | Should -Match 'Resolve-DeliveryPlanAiRulesSource[\s\S]*New-DeliveryQualityPlanForCandidate'
        $publishText | Should -Match 'Resolve-DeliveryPlanAiRulesSource[\s\S]*New-DeliveryQualityPlanForCandidate'

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

    It 'adds owned component Release capabilities to the accumulated Plan' {
        $planSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-plan.ps1') -Raw -Encoding UTF8
        $accumulatedText = [regex]::Match($planSource, '(?ms)^function New-AccumulatedDeliveryPlan \{.*?^\}').Value
        & {
            Invoke-Expression $accumulatedText
            $script:Remote = 'origin'; $script:preflightCalled = $false; $script:resolverCalled = $false
            function Assert-CleanDeliveryWorktree {}
            function Invoke-DeliveryGit { param([string[]]$Arguments); return [pscustomobject]@{ exitCode=0; stdout='' } }
            function Get-GitValue { return ('b' * 40) }
            function Get-QueueEntries { return @([pscustomobject]@{ id='develop'; base=('a' * 40); head=('c' * 40) }) }
            function New-DeliveryWorktree { return [pscustomobject]@{ path='C:\candidate'; branch='itl/plan' } }
            function Add-QueuedRangesToCandidate {}
            function Invoke-WorktreeGit {
                param([string]$Root,[string[]]$Arguments)
                return [pscustomobject]@{ exitCode=0; stdout=$(if ($Arguments -contains 'HEAD^{tree}') { ('d' * 40) } else { ('c' * 40) }) }
            }
            function Get-OwnedComponentPublicationPlan { return [pscustomobject]@{ status='planned'; requiredReleaseCapabilities=@('ondemand-mcp'); components=@() } }
            function Assert-ComponentPublicationFinalizerPreflight { $script:preflightCalled = $true }
            function Resolve-DeliveryPlanAiRulesSource { $script:resolverCalled = $true; return 'C:\exact-rules' }
            function New-DeliveryQualityPlanForCandidate {
                param([string]$CandidateRoot,[string]$BaseCommit,[string]$CandidateCommit,[string]$CandidateTree,[switch]$RequireRelease,[string[]]$ReleaseCapability)
                return [pscustomobject]@{ planId='plan'; status='ready'; requireRelease=(@($ReleaseCapability).Count -gt 0); releaseCapabilities=@($ReleaseCapability) }
            }
            function Save-DeliveryQualityPlan { return 'C:\plan.json' }
            function Remove-DeliveryWorktree {}

            $plan = New-AccumulatedDeliveryPlan
            $plan.requireRelease | Should -BeTrue
            @($plan.releaseCapabilities) | Should -Be @('ondemand-mcp')
            $script:preflightCalled | Should -BeTrue
            $script:resolverCalled | Should -BeTrue
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
        $seedParallel = @($catalog.stages | Where-Object { [string]$_.id -eq 'seed-parallel' })[0]
        [int]$seedParallel.version | Should -Be 6
        [int]$seedParallel.budgetSeconds | Should -Be 1800
    }
}

Describe 'E2E client delivery inputs' {
    It 'binds the plan and publication identity to explicit client selection' {
        & {
            $stand=Join-Path $TestDrive 'client plan путь'
            New-Item -ItemType Directory -Force -Path (Join-Path $stand '.agent-1c')|Out-Null
            [IO.File]::WriteAllText((Join-Path $stand '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode","codex"]}}',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $stand '.agent-1c/release-e2e.json'),'{}',[Text.UTF8Encoding]::new($false))
            $script:E2EProjectRoot=$stand
            $AgentTarget='kilocode';$before=Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanEnvironmentIdentity -Mode Develop)
            $AgentTarget='codex';(Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanEnvironmentIdentity -Mode Develop))|Should -Not -Be $before
            $AgentTarget='kilocode';(Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanEnvironmentIdentity -Mode Develop))|Should -Be $before
            $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/source-delivery-candidate.ps1'),[ref]$tokens,[ref]$errors)
            . ([scriptblock]::Create(($ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-DevelopPublicationEnvironmentIdentity'},$false)).Extent.Text))
            function Invoke-RepositoryGit {param($RepositoryRoot,$Arguments,[switch]$AllowFailure)[pscustomobject]@{exitCode=0;stdout=$(if($Arguments[0] -eq 'rev-parse'){'a'*40}else{''})}}
            $publication=Get-DevelopPublicationEnvironmentIdentity
            $AgentTarget='codex';(Get-DevelopPublicationEnvironmentIdentity)|Should -Not -Be $publication
        }
    }

    It 'forwards the optional selection across source gate and check runner boundaries' {
        & {
            $tokens=$null;$errors=$null
            foreach($file in @('source-delivery.ps1','source-delivery-supervisor.ps1','check.ps1','invoke-develop-e2e.ps1','invoke-release-e2e.ps1')){
                $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot ('scripts/'+$file)),[ref]$tokens,[ref]$errors)
                @($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath -ceq 'AgentTarget'}).Count|Should -Be 1
            }
            $source=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/source-delivery-process.ps1'),[ref]$tokens,[ref]$errors)
            . ([scriptblock]::Create(($source.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-SourceGate'},$false)).Extent.Text))
            $script:Root=$RepoRoot;$script:GateScript=Join-Path $TestDrive 'fixture gate.ps1'
            [IO.File]::WriteAllText($script:GateScript,'# process boundary is mocked',[Text.UTF8Encoding]::new($false))
            $CoverageContract=@();$AiRulesSource='';$E2EProjectRoot='';$ReleaseResumeMode='Auto';$AgentTarget='kilocode'
            function Start-DeliveryProcess {param($ArgumentList,$WorkingDirectory,$StandardOutputPath,$StandardErrorPath)$script:capturedClientArguments=$ArgumentList;throw 'fixture launch boundary'}
            function Close-DeliveryProcessJob {param($JobHandle,$Process,$PriorErrorMessage)}
            function Stop-DeliveryProcessTree {param($Process)}
            function Write-DeliveryRunRecord {param($Mode,$Status,$ErrorMessage,$WorkingRoot,$StartedAt,$FinishedAt,$ExitCode,$ReleaseCapability)'fixture-record'}
            function Update-DeliveryOperation {param($Values)}
            foreach($mode in @('Develop','Release')){
                {Invoke-SourceGate -Mode $mode -WorkingRoot $TestDrive}|Should -Throw '*fixture launch boundary*'
                ([regex]::Matches($script:capturedClientArguments,'-AgentTarget kilocode')).Count|Should -Be 1
            }
            $AgentTarget=''
            {Invoke-SourceGate -Mode Develop -WorkingRoot $TestDrive}|Should -Throw '*fixture launch boundary*'
            $script:capturedClientArguments|Should -Not -Match 'AgentTarget'
            $check=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'),[ref]$tokens,[ref]$errors)
            $E2EProjectRoot=$TestDrive;$repoRoot=$RepoRoot;$script:developRulesSource=$RepoRoot;$rawPath='raw.json';$Journey='upgrade'
            $releaseRulesSource=$RepoRoot;$releaseHelperPath='helper.ps1';$e2eReportPath='release.json';$AgentTarget='kilocode'
            foreach($variable in @('developArguments','releaseE2EArguments')){
                $assignment=$check.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ceq $variable -and $n.Operator -eq 'Equals'},$true)
                $append=$check.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -like ('if (-not [[]string[]]::IsNullOrWhiteSpace($AgentTarget))*$'+$variable+' +=*')},$true)
                $assignment|Should -Not -BeNullOrEmpty;$append|Should -Not -BeNullOrEmpty
                . ([scriptblock]::Create($assignment.Extent.Text+"`n"+$append.Extent.Text))
                $forwarded=Get-Variable -Name $variable -ValueOnly
                @($forwarded|Where-Object{$_ -ceq '-AgentTarget'}).Count|Should -Be 1
                $forwarded[[Array]::IndexOf($forwarded,'-AgentTarget')+1]|Should -BeExactly 'kilocode'
            }
        }
    }
}
Describe 'Pinned supervisor client option compatibility' {
    It 'preserves explicit intent on old authority and delegates it once after support is present' {
        & {
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/source-delivery.ps1'),[ref]$tokens,[ref]$errors)
            . ([scriptblock]::Create(($ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-DeliveryBootstrapAgentTargetSupport'},$false)).Extent.Text))
            $legacy=[Management.Automation.Language.Parser]::ParseInput('param([string]$Action) $Action',[ref]$tokens,[ref]$errors)
            $bound=@{Action='Plan';AgentTarget='kilocode'}
            {Assert-DeliveryBootstrapAgentTargetSupport $legacy ('a'*40) $bound}|Should -Throw '*DELIVERY_E2E_CLIENT_OPTION_UNSUPPORTED*Publish*same explicit command*'
            $bound.AgentTarget|Should -BeExactly 'kilocode'
            {Assert-DeliveryBootstrapAgentTargetSupport $legacy ('a'*40) @{Action='Plan'}}|Should -Not -Throw
            $current=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/source-delivery-supervisor.ps1'),[ref]$tokens,[ref]$errors)
            {Assert-DeliveryBootstrapAgentTargetSupport $current ('b'*40) $bound}|Should -Not -Throw
            $bound.Count|Should -Be 2;$bound.AgentTarget|Should -BeExactly 'kilocode'
            # Execute the entrypoint's actual bound-parameter projection; no publication.
            $projection=$ast.Find({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Extent.Text -ceq 'foreach ($entry in $PSBoundParameters.GetEnumerator()) { $arguments[$entry.Key] = $entry.Value }'},$true)
            $projection|Should -Not -BeNullOrEmpty
            $projectBoundParameters=[scriptblock]::Create('param($Action,$AgentTarget) $arguments=@{};'+$projection.Extent.Text+';return $arguments')
            $delegated=& $projectBoundParameters @bound
            $delegated.Count|Should -Be 2;$delegated.AgentTarget|Should -BeExactly 'kilocode'
        }
    }
}
