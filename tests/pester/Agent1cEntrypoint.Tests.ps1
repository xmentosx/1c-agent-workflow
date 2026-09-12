BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
    $Catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
    $EntrypointPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    $EntrypointText = Get-Content -LiteralPath $EntrypointPath -Raw -Encoding UTF8
    $EntrypointModel = Get-Agent1cSemanticModel -Text $EntrypointText
}

Describe "Agent 1C entrypoint semantic contract" {
    It "keeps the entrypoint parseable with one literal Action dispatch" {
        $EntrypointModel.valid | Should -BeTrue
        @($EntrypointModel.actions.Keys).Count | Should -BeGreaterThan 50
    }

    It "keeps Action ValidateSet, dispatch labels, and semantic owners exactly equal" {
        $validateSet = @(Get-PublicLifecycleActions -RepositoryRoot $RepoRoot)
        $dispatch = @($EntrypointModel.actions.Keys | Sort-Object)
        $owners = @($Catalog.semanticTargeting.actionOwners.PSObject.Properties.Name | Sort-Object)
        $dispatch | Should -Be $validateSet
        $owners | Should -Be $validateSet
    }

    It "keeps every declared semantic owner tied to an existing focused test" {
        foreach ($owner in @($Catalog.semanticTargeting.owners.PSObject.Properties)) {
            foreach ($test in @($owner.Value.tests)) {
                Test-Path -LiteralPath (Join-Path $RepoRoot ([string]$test).Replace('/', '\')) -PathType Leaf | Should -BeTrue -Because "$($owner.Name) must remain executable"
            }
        }
    }
}
