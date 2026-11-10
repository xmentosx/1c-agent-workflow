BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryPlan.TestSupport.ps1') }

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
