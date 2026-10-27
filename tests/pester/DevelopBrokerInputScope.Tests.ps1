BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryPlan.TestSupport.ps1') }

Describe 'Develop broker cleanup input scope' {
    AfterEach { Exit-DeliveryPlanFixtureEnvironment -Snapshot $script:deliveryPlanFixtureEnvironment }
    BeforeEach { $script:deliveryPlanFixtureEnvironment=Enter-DeliveryPlanFixtureEnvironment }

    It 'reuses authenticated native proofs for retained-only cleanup changes and rejects shared-path changes' {
        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
        $f=New-IncrementalPlanFixture
        $script:Root=$f.root
        [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}')
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        $catalog=Get-QualityContractCatalog $RepoRoot
        $f.catalog.developJourneys | Add-Member -NotePropertyName scenarios -NotePropertyValue $catalog.developJourneys.scenarios
        $f.catalog.developJourneys | Add-Member -NotePropertyName scenarioInputs -NotePropertyValue @()
        $relative='.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1'
        $path=Join-Path $f.root $relative
        $current=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepoRoot $relative)))
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($current,[ref]$tokens,[ref]$errors)
        $peer=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ItlOnDemandPeerSessionOwnership'},$true)
        $loop=$ast.Find({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.Extent.Text -eq '$session' -and $n.Extent.Text.Contains('Test-ItlOnDemandPeerSessionOwnership')},$true)
        $peer | Should -Not -BeNullOrEmpty
        $loop | Should -Not -BeNullOrEmpty
        # Preserve the observed pre-fix retained-launch rejection, including the
        # original path and runtime preconditions. All other source stays actual.
        $oldLoop="if (`$foreign.Count -gt 0) { throw 'ITL_ONDEMAND_RECOVERY_NOT_QUIESCENT: unidentified exact-base 1C sessions remain; wait for their owner to finish, then retry the original operation. No foreign process was stopped.' }"
        $before=$current.Remove($loop.Extent.StartOffset,$loop.Extent.EndOffset-$loop.Extent.StartOffset).Insert($loop.Extent.StartOffset,$oldLoop)
        $before=$before.Remove($peer.Extent.StartOffset,$peer.Extent.EndOffset-$peer.Extent.StartOffset)
        [IO.File]::WriteAllText($path,$before,[Text.UTF8Encoding]::new($false))
        $f.catalog.contracts[0].paths+=@($relative)
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'original retained cleanup boundary'
        $f.base=(& git -C $f.root rev-parse HEAD).Trim()
        $diagnostics=[Collections.Generic.List[object]]::new()
        $identity=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding -Diagnostics $diagnostics
        $identity | Should -Not -BeNullOrEmpty -Because ($diagnostics|ConvertTo-Json -Depth 6 -Compress)
        Save-IncrementalJourneyProofs $f
        $old=@{}
        foreach($journey in @('fresh','upgrade')) {
            $old[$journey]=Get-DevelopE2EInputIdentity $f.root $journey $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        }
        [IO.File]::WriteAllText($path,$current,[Text.UTF8Encoding]::new($false))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'prove exact registered peer during retained cleanup'
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $route=Resolve-DevelopE2EJourneyPlanCore $f.root $f.base @($relative) $catalog
        @($route.journeys) | Should -BeNullOrEmpty
        @((Resolve-QualityContractsForPaths $catalog @($relative)).tests) | Should -Contain 'tests/pester/OnDemandMcp.Tests.ps1'
        foreach($journey in @('fresh','upgrade')) {
            $now=Get-DevelopE2EInputIdentity $f.root $journey $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
            $records=@(Get-DevelopScenarioReusePlan $f.root $tree $journey $now $f.catalog -AllowPendingStatic)
            @($records | Where-Object execution -ne reuse) | Should -BeNullOrEmpty -Because ($records|ConvertTo-Json -Depth 8 -Compress)
            @($records).Count | Should -Be @($catalog.developJourneys.scenarios.$journey).Count
        }
        foreach($case in @('registered-path','shared-helper','shared-retained','default','unknown-function','top-level')) {
            $changed=switch($case) {
                'registered-path' {$current.Replace('Assert-ItlOnDemandRuntimeMutation -Family $Family -InstanceId $InstanceId',"Write-Output 'changed registered drain'; Assert-ItlOnDemandRuntimeMutation -Family `$Family -InstanceId `$InstanceId")}
                'shared-helper' {$current+"`nfunction New-SharedCaller { Test-ItlOnDemandPeerSessionOwnership }`n"}
                'shared-retained' {$current+"`nfunction New-SharedCaller { Stop-ItlOnDemandBackendInstance -RetainedRuntimeState @{} }`n"}
                'default' {$current.Replace('[AllowNull()][object]$RetainedRuntimeState = $null','[AllowNull()][object]$RetainedRuntimeState = @{}')}
                'unknown-function' {$current+"`nfunction New-UnmappedBrokerPath { throw 'new path' }`n"}
                'top-level' {$current+"`nWrite-Output 'new ambient execution'`n"}
            }
            $changed | Should -Not -BeExactly $current
            [IO.File]::WriteAllText($path,$changed,[Text.UTF8Encoding]::new($false))
            $now=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
            Test-DevelopScenarioEquivalentInput $f.root $old.fresh $now $f.base @('verification') $f.catalog | Should -BeFalse -Because $case
            # This library's existing catalog owner routes fresh. The unchanged
            # upgrade route is selected separately by lock/installation inputs.
            @(Resolve-DevelopE2EJourneyPlanCore $f.root $f.base @($relative) $catalog).journeys | Should -Be @('fresh') -Because $case
            foreach($journey in @('fresh','upgrade')) {Test-DevelopJourneyUnaffectedPath $f.root $relative $f.base $journey | Should -BeFalse -Because $case}
        }
    }

    It 'keeps retained launch admission exclusive to the internal RPC path' {
        $calls=@();$recoverCalls=@();$coreOwners=@()
        foreach($file in @(Get-ChildItem (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts') -Recurse -File -Filter '*.ps1')) {
            $text=[IO.File]::ReadAllText($file.FullName)
            if(-not $text.Contains('RetainedRuntimeState') -and -not $text.Contains('Recover-ItlOnDemandBackendInstance')) {continue}
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            foreach($command in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))) {
                $owner=$command.Parent
                while($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) {$owner=$owner.Parent}
                if($command.GetCommandName() -eq 'Recover-ItlOnDemandBackendInstance') {
                    $file.Name | Should -Be 'agent-1c.ondemand-mcp.ps1'
                    $recoverCalls+=@($owner.Name)
                }
                $command.GetCommandName() | Should -Not -Be 'Recover-ItlOnDemandBackendInstanceCore'
                $command.GetCommandName() | Should -Not -Be 'Stop-ItlOnDemandBackendInstanceCore'
                if($command.Extent.Text -match "-OwnerFunction 'Recover-ItlOnDemandBackendInstanceCore'") {$coreOwners+=@($owner.Name)}
                if(-not @($command.CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'RetainedRuntimeState'}).Count) {continue}
                $file.Name | Should -Be 'agent-1c.ondemand-mcp.ps1'
                $command.GetCommandName() | Should -Be 'Stop-ItlOnDemandBackendInstance'
                $parent=$command.Parent
                while($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) {$parent=$parent.Parent}
                $calls+=@($parent.Name)
            }
        }
        @($calls|Sort-Object) | Should -Be @('Invoke-ItlOnDemandBackendBroker','Recover-ItlOnDemandBackendInstanceCore')
        @($recoverCalls) | Should -Be @('Invoke-ItlOnDemandBackendBroker')
        @($coreOwners) | Should -Be @('Recover-ItlOnDemandBackendInstance')
        foreach($relative in @('scripts/invoke-develop-e2e.ps1','scripts/develop-configuration-rejection.ps1','scripts/source-e2e-fixture.ps1','scripts/update-installed-workflow.ps1')) {
            [IO.File]::ReadAllText((Join-Path $RepoRoot $relative)) | Should -Not -Match '(?i)-InternalOnDemandOperation\b'
        }
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'),[ref]$tokens,[ref]$errors)
        $dispatch=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-ItlOnDemandBackendBroker'},$true))
        $dispatch.Count | Should -Be 1
        $parent=$dispatch[0].Parent
        while($parent -and $parent -isnot [Management.Automation.Language.IfStatementAst]) {$parent=$parent.Parent}
        $parent.Clauses[0].Item1.Extent.Text | Should -Be '$InternalOnDemandOperation'
        $dispatch[0].Extent.EndOffset | Should -BeLessOrEqual $parent.Clauses[0].Item2.Extent.EndOffset
    }
}
