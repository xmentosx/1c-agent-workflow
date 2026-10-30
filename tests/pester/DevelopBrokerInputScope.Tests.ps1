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
        $stop=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-ItlOnDemandBackendInstanceCore'},$true)
        $loop=$stop.Find({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.Extent.Text -eq '$session' -and $n.Extent.Text.Contains('Test-ItlOnDemandPeerSessionOwnership')},$true)
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
        foreach($case in @('registered-path','shared-helper','shared-completion','unguarded-completion','shared-retained','default','unknown-function','top-level')) {
            $changed=switch($case) {
                'registered-path' {$current.Replace('Assert-ItlOnDemandRuntimeMutation -Family $Family -InstanceId $InstanceId',"Write-Output 'changed registered drain'; Assert-ItlOnDemandRuntimeMutation -Family `$Family -InstanceId `$InstanceId")}
                'shared-helper' {$current+"`nfunction New-SharedCaller { Test-ItlOnDemandPeerSessionOwnership }`n"}
                'shared-completion' {$current+"`nfunction New-SharedCaller { Test-ItlOnDemandRetainedCleanupComplete }`n"}
                'unguarded-completion' {$current.Replace('$retained -and (Test-ItlOnDemandRetainedCleanupComplete -RuntimeState $runtimeState)','(Test-ItlOnDemandRetainedCleanupComplete -RuntimeState $runtimeState)')}
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

    It 'keeps cold admission bound while projecting only the completed-retained classifier' {
        $relative='.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1'
        $current=[IO.File]::ReadAllText((Join-Path $RepoRoot $relative))
        $projection=Get-DevelopBrokerCleanupSourceProjection $current
        $changed=$current.Replace('if ($owners.Count -ne 1) { return $false }','if ($owners.Count -ne 2) { return $false }')
        $changed|Should -Not -BeExactly $current
        Get-DevelopBrokerCleanupSourceProjection $changed|Should -BeExactly $projection
        $changed=$current.Replace('Test-ItlOnDemandRetainedCleanupComplete -RuntimeState $proof','Test-ItlOnDemandRetainedCleanupComplete -RuntimeState $null')
        $changed|Should -Not -BeExactly $current
        Get-DevelopBrokerCleanupSourceProjection $changed|Should -Not -BeExactly $projection
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

Describe 'Cold fresh cutover proof' {
    AfterEach { Exit-DeliveryPlanFixtureEnvironment -Snapshot $script:deliveryPlanFixtureEnvironment }
    BeforeEach { $script:deliveryPlanFixtureEnvironment=Enter-DeliveryPlanFixtureEnvironment }

    It 'reuses all fresh scenarios for the original retained-record fix while binding upgrade and cold admission' {
        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
        $f=New-IncrementalPlanFixture;$script:Root=$f.root
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        $actual=Get-QualityContractCatalog $RepoRoot
        $f.catalog.developJourneys|Add-Member scenarios $actual.developJourneys.scenarios
        $f.catalog.developJourneys|Add-Member scenarioInputs @()
        [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}')
        $paths=@('install-agent-1c-workflow.ps1','.agents/skills/1c-workflow/scripts/execution-guard-cutover.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.runtime-values.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')
        $original=@{}
        foreach($relative in $paths) {
            $target=Join-Path $f.root $relative;[void][IO.Directory]::CreateDirectory((Split-Path $target))
            Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target
            $original[$relative]=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($target))
        }
        $cutover=$paths[1];$values=$paths[2]
        # Exact original enumerator and retained-runtime topology; do not turn
        # the old failure into a different branch by inventing empty receipts.
        $old=$original[$cutover].Replace(". (Join-Path `$PSScriptRoot 'lib/agent-1c.runtime-values.ps1')",'').Replace('Get-ItlOnDemandRuntimeRecordFiles -RuntimeRoot $runtimeRoot','Get-ChildItem -LiteralPath $runtimeRoot -Filter ''*.json'' -File -Recurse -ErrorAction Stop | Where-Object { $_.Name -notlike ''*.VAParams.json'' }')
        [IO.File]::WriteAllText((Join-Path $f.root $cutover),$old,[Text.UTF8Encoding]::new($false))
        $oldLifecycle=$original[$paths[3]].Replace('Get-ItlOnDemandRuntimeRecordFiles -RuntimeRoot $runtimeRoot','Get-ChildItem -LiteralPath $runtimeRoot -Filter ''*.json'' -File -Recurse -ErrorAction Stop | Where-Object { $_.Name -notlike ''*.VAParams.json'' }')
        [IO.File]::WriteAllText((Join-Path $f.root $paths[3]),$oldLifecycle,[Text.UTF8Encoding]::new($false))
        $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($original[$values].TrimStart([char]0xfeff),[ref]$t,[ref]$e)
        $leaf=$ast.EndBlock.Statements|Where-Object Name -eq 'Get-ItlOnDemandRuntimeRecordFiles'
        $before=$original[$values].TrimStart([char]0xfeff).Remove($leaf.Extent.StartOffset,$leaf.Extent.EndOffset-$leaf.Extent.StartOffset)
        [IO.File]::WriteAllText((Join-Path $f.root $values),$before,[Text.UTF8Encoding]::new($true))
        $f.catalog.contracts[0].paths+=@($paths)
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'original retained record admission'
        $f.base=(& git -C $f.root rev-parse HEAD).Trim();
        $diagnostics=[Collections.Generic.List[object]]::new();$identity=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding -Diagnostics $diagnostics
        $identity|Should -Not -BeNullOrEmpty -Because ($diagnostics|ConvertTo-Json -Depth 5 -Compress)
        Save-IncrementalJourneyProofs $f
        $prior=@{};foreach($journey in @('fresh','upgrade')) {$prior[$journey]=Get-DevelopE2EInputIdentity $f.root $journey $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding}
        foreach($relative in $paths){[IO.File]::WriteAllText((Join-Path $f.root $relative),$original[$relative],[Text.UTF8Encoding]::new($false))}
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'retained record enumeration fix'
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $now=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        $records=@(Get-DevelopScenarioReusePlan $f.root $tree fresh $now $f.catalog -AllowPendingStatic)
        @($records|Where-Object execution -ne reuse)|Should -BeNullOrEmpty -Because ($records|Select-Object id,execution,reuseDiagnostics|ConvertTo-Json -Depth 5 -Compress)
        $upgrade=Get-DevelopE2EInputIdentity $f.root upgrade $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        Test-DevelopScenarioEquivalentInput $f.root $prior.upgrade $upgrade $f.base @('update') $f.catalog|Should -BeFalse
        # Combine the retained-record fix with a real changed, locked broker.
        # Its non-consumers may reuse; installation and refresh still execute.
        $lockPath=Join-Path $f.root 'templates/dependency-lock.json';$lockBytes=[IO.File]::ReadAllBytes($lockPath)
        $broker=Join-Path $f.root '.git/current-broker.exe';[IO.File]::WriteAllBytes($broker,[byte[]](4,5,6,7))
        $oldBroker=$f.binding.paths.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE;$f.binding.paths.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE=$broker
        $lock=Get-Content $lockPath -Raw -Encoding UTF8|ConvertFrom-Json;$lock.dependencies.itlOndemandMcp.sha256=(Get-FileHash $broker).Hash.ToLowerInvariant();$lock.dependencies.itlOndemandMcp.version='2'
        [IO.File]::WriteAllText($lockPath,($lock|ConvertTo-Json -Depth 8))
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'new exact broker plus retained record fix'
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $combined=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        $selected=@(Get-DevelopScenarioReusePlan $f.root $tree fresh $combined $f.catalog -AllowPendingStatic)
        @($selected|Where-Object execution -eq reuse|ForEach-Object id)|Should -Be @('stale-export','close')
        @($selected|Where-Object execution -eq setup|ForEach-Object id)|Should -Be @('verification')
        @($selected|Where-Object execution -eq execute|ForEach-Object id)|Should -Be @('install','branch','refresh')
        [IO.File]::WriteAllBytes($lockPath,$lockBytes);$f.binding.paths.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE=$oldBroker
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'restore exact original broker'
        foreach($case in @('cold-guard','generation','unknown-function','top-level','library-side-effect','library-other-function','lifecycle-live-prefix','runner','bootstrap','catalog-helper','historical-sha','unknown-scenario')) {
            foreach($relative in $paths){[IO.File]::WriteAllText((Join-Path $f.root $relative),$original[$relative],[Text.UTF8Encoding]::new($false))}
            $runner=Join-Path $f.root 'scripts/invoke-develop-e2e.ps1';$runnerBytes=[IO.File]::ReadAllBytes($runner)
            $catalogHelper=Join-Path $f.root 'scripts/source-e2e-workflow-update.ps1';$catalogBytes=[IO.File]::ReadAllBytes($catalogHelper)
            switch($case) {
                'cold-guard' {[IO.File]::WriteAllText((Join-Path $f.root $cutover),$original[$cutover].Replace('if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) { return }','if ($true) { return }'))}
                'generation' {[IO.File]::WriteAllText((Join-Path $f.root $cutover),$original[$cutover].Replace("generation='execution-guards-v2'","generation='changed'"))}
                'unknown-function' {[IO.File]::AppendAllText((Join-Path $f.root $cutover),"`nfunction Unknown-Cutover { 'changed' }`n")}
                'top-level' {[IO.File]::AppendAllText((Join-Path $f.root $cutover),"`nWrite-Output 'changed'`n")}
                'library-side-effect' {[IO.File]::AppendAllText((Join-Path $f.root $values),"`nWrite-Output 'eager import'`n")}
                'library-other-function' {[IO.File]::AppendAllText((Join-Path $f.root $values),"`nfunction Unknown-Value { 'changed' }`n")}
                'lifecycle-live-prefix' {[IO.File]::WriteAllText((Join-Path $f.root $paths[3]),$original[$paths[3]].Replace('Join-Path $Root ''.agent-1c/mcp/ondemand''','Join-Path $Root ''.agent-1c/mcp/other'''))}
                'runner' {[IO.File]::AppendAllText($runner,"`nWrite-Verbose 'changed cold recipe'`n")}
                'bootstrap' {[IO.File]::AppendAllText((Join-Path $f.root $paths[0]),"`nWrite-Verbose 'changed bootstrap'`n")}
                'catalog-helper' {[IO.File]::AppendAllText($catalogHelper,"`nGet-ChildItem '.agent-1c/mcp/ondemand' -Recurse`n")}
            }
            $changed=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
            $oldProof=$prior.fresh|ConvertTo-Json -Depth 32|ConvertFrom-Json
            if($case -eq 'historical-sha'){($oldProof.inventory.inputs|Where-Object path -eq $cutover).sha256='e'*64;$oldProof.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $oldProof.inventory}
            $scenario=if($case -eq 'unknown-scenario'){@('future-scenario')}else{@('verification')}
            Test-DevelopScenarioEquivalentInput $f.root $oldProof $changed $f.base $scenario $f.catalog|Should -BeFalse -Because $case
            [IO.File]::WriteAllBytes($runner,$runnerBytes)
            [IO.File]::WriteAllBytes($catalogHelper,$catalogBytes)
        }
    }

    It 'executes original and current cutover on a cold Unicode root and retains malformed-state refusal' {
        $relative='.agents/skills/1c-workflow/scripts/execution-guard-cutover.ps1'
        $current=[IO.File]::ReadAllText((Join-Path $RepoRoot $relative))
        $old=$current.Replace(". (Join-Path `$PSScriptRoot 'lib/agent-1c.runtime-values.ps1')",'').Replace('Get-ItlOnDemandRuntimeRecordFiles -RuntimeRoot $runtimeRoot','Get-ChildItem -LiteralPath $runtimeRoot -Filter ''*.json'' -File -Recurse -ErrorAction Stop | Where-Object { $_.Name -notlike ''*.VAParams.json'' }')
        $package=Join-Path $TestDrive 'Пакет с пробелом';[void][IO.Directory]::CreateDirectory((Join-Path $package 'lib'))
        foreach($name in @('agent-1c.package-content.ps1','agent-1c.runtime-values.ps1')){Copy-Item (Join-Path $RepoRoot ('.agents/skills/1c-workflow/scripts/lib/'+$name)) (Join-Path $package ('lib/'+$name))}
        foreach($variant in @('old','current')) {
            $scriptPath=Join-Path $package 'cutover.ps1';$text=if($variant -eq 'old'){$old}else{$current};[IO.File]::WriteAllText($scriptPath,$text,[Text.UTF8Encoding]::new($true))
            $root=Join-Path $TestDrive ('Проект с пробелом '+$variant);[void][IO.Directory]::CreateDirectory($root)
            (& $scriptPath -ProjectRoot $root).status|Should -Be 'completed'
            (Get-Content (Join-Path $root '.agent-1c/execution-guard-generation.json') -Raw -Encoding UTF8|ConvertFrom-Json).generation|Should -Be 'execution-guards-v2'
            $runtime=Join-Path $root '.agent-1c/mcp/ondemand';[void][IO.Directory]::CreateDirectory($runtime)
            [IO.File]::WriteAllText((Join-Path $runtime 'unknown.json'),'{not-json')
            {& $scriptPath -ProjectRoot $root}|Should -Throw '*EXECUTION_GUARD_CUTOVER_RUNTIME_STATE_INVALID*'
        }
    }

    It 'keeps the retained-runtime reader inventory closed under current complete static proof' {
        $leaf=@();$callers=@()
        foreach($path in @(Get-RepositoryGitPathList $RepoRoot @('ls-files','-z','--','.agents/skills/1c-workflow/scripts'))|Where-Object {$_ -like '*.ps1'}) {
            $text=[IO.File]::ReadAllText((Join-Path $RepoRoot $path))
            if($text -notmatch 'Get-ItlOnDemandRuntimeRecordFiles|Get-WorkflowUpdateRootRuntimeBusyReason'){continue}
            $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text.TrimStart([char]0xfeff),[ref]$t,[ref]$e)
            foreach($command in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -cin @('Get-ItlOnDemandRuntimeRecordFiles','Get-WorkflowUpdateRootRuntimeBusyReason')},$true))) {
                $owner=$command.Parent;while($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
                $name=if($owner){$owner.Name}else{'<top-level>'}
                if($command.GetCommandName() -ceq 'Get-ItlOnDemandRuntimeRecordFiles'){$leaf+=($path+':'+$name)}else{$callers+=$name}
            }
        }
        @($leaf|Sort-Object -Unique)|Should -Be @('.agents/skills/1c-workflow/scripts/execution-guard-cutover.ps1:Assert-NoActiveCutoverRuntime','.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1:Get-WorkflowUpdateRootRuntimeBusyReason')
        @($callers|Sort-Object -Unique)|Should -Be @('Assert-WorkflowUpdateReconciliationScope','Assert-WorkflowUpdateRollbackTarget','Get-WorkflowLegacyCopyEvidence','Get-WorkflowUpdateRootBusyReason','Invoke-WorkflowDevelopmentBranchRollout','Update-WorkflowPackage')
    }
}
