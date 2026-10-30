BeforeAll {
    $repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'scripts/source-e2e-fixture.ps1')
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/invoke-develop-e2e.ps1'),[ref]$tokens,[ref]$errors)
    foreach($name in @('ConvertTo-DevelopProcessArgument','Invoke-DevelopProcess','Invoke-InstalledAction','Read-CompactSummary','Invoke-DevelopWorkflowUpdate')){
        $fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function New-UpdateBoundaryFixture {
        param([string]$Name)
        $root=Join-Path $TestDrive ($Name+' проект с пробелами');$source=Join-Path $TestDrive ($Name+' кандидат Кириллица')
        $runner=Join-Path $root '.agents/skills/1c-workflow/scripts/run-itl-command.ps1'
        $helper=Join-Path $source '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $runner));[void][IO.Directory]::CreateDirectory((Split-Path -Parent $helper))
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'scripts'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root '.agent-1c'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'src/cf'))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{"baseConfigurationVersion":"PM5"}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'),"FOREIGN_SETTING=preserve`n",[Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/fixtures/gate-stand/cf/Configuration.xml') -Destination (Join-Path $root 'src/cf/Configuration.xml')
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/update-installed-workflow.ps1') -Destination (Join-Path $source 'scripts/update-installed-workflow.ps1')
        $old=@'
$Arguments=@($args)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../../')).TrimEnd('\','/')
if('-CatalogProjectId' -cnotin $Arguments -or $Arguments[[array]::IndexOf($Arguments,'-CatalogProjectId')+1] -cne 'itl-gate-qualification'){throw 'CATALOG_PROJECT_REQUIRED: original unbound technical stand needs an explicit published selection'}
$client=$Arguments[[array]::IndexOf($Arguments,'-AgentTarget')+1]
[IO.File]::WriteAllText((Join-Path $root 'initial-client.txt'),$client,[Text.UTF8Encoding]::new($false))
$run=Join-Path $root '.agent-1c/runs/compact-native-boundary';[void][IO.Directory]::CreateDirectory($run)
$statusPath=Join-Path $run 'status.json'
$guard=[ordered]@{action='update-workflow';status='failed';stage='workflow-update.post-copy';exitCode=1;blockerRequiresUserDecision=$false;projectRoot=$root;startedAt=[datetime]::UtcNow.ToString('o');errorMessage="CATALOG_PROJECT_REQUIRED: old caller lost explicit selection. Original candidate: '$env:ITL_WORKFLOW_SOURCE_PATH'."}
[IO.File]::WriteAllText(($statusPath+'.fresh-native.json'),($guard|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
@{action='update-workflow';status='failed';blockerRequiresUserDecision=$false;statusPath=$statusPath}|ConvertTo-Json -Compress
exit 1
'@
        $new=@'
param([string]$ProjectRoot,[string]$Action,[string]$AgentTarget,[string]$CatalogProjectId,[string]$CatalogDecision)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$ErrorActionPreference='Stop'
if($Action -cne 'update-workflow' -or $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE -cne 'true'){throw 'invalid source-owner handoff'}
if($CatalogProjectId -cne 'itl-gate-qualification' -or $CatalogDecision -cne 'keep-local'){throw 'catalog choice lost across source-owner handoff'}
if((Get-Content -LiteralPath (Join-Path $ProjectRoot 'initial-client.txt') -Raw -Encoding UTF8) -cne $AgentTarget){throw 'client changed across handoff'}
[IO.File]::WriteAllText((Join-Path $ProjectRoot 'source-owner.json'),(@{project=$ProjectRoot;source=$env:ITL_WORKFLOW_SOURCE_PATH;client=$AgentTarget}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
if($env:ITL_TEST_UPDATE_CONTINUATION_FAIL -eq 'true'){exit 7}
'@
        [IO.File]::WriteAllText($runner,$old,[Text.UTF8Encoding]::new($true));[IO.File]::WriteAllText($helper,$new,[Text.UTF8Encoding]::new($true))
        & git -C $source init --quiet
        & git -C $source -c user.name=fixture -c user.email=fixture@example.invalid add .
        & git -C $source -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
        if($LASTEXITCODE -ne 0){throw 'fixture Git initialization failed'}
        # As in the real builder, publish fixture settings before sealing the
        # baseline. The original seed stays unbound until the update owner.
        $null=Initialize-SourceE2ECatalog -Root $root
        return [pscustomobject]@{root=$root;source=$source}
    }
}

Describe 'Bounded source-owner workflow update continuation' {
    It 'restores the identical technical catalog payload for a bound copy without changing its binding' {
        $seed=New-UpdateBoundaryFixture 'catalog dependency seed'
        $copy=Join-Path $TestDrive 'Восстановленная копия с пробелом'
        [void][IO.Directory]::CreateDirectory((Join-Path $copy '.agent-1c'))
        [void][IO.Directory]::CreateDirectory((Join-Path $copy 'src/cf'))
        Copy-Item (Join-Path $seed.root 'src/cf/Configuration.xml') (Join-Path $copy 'src/cf/Configuration.xml')
        $settings=Get-Content (Join-Path $seed.root '.agent-1c/project.json') -Raw | ConvertFrom-Json
        $settings|Add-Member productProject @{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='itl-gate-qualification';productId='itl-gate-fixture'}
        $path=Join-Path $copy '.agent-1c/project.json'
        [IO.File]::WriteAllText($path,($settings|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $before=(Get-FileHash $path).Hash
        $publisher=Join-Path $copy '.agent-1c/mcp/qualification-catalog'
        [IO.File]::WriteAllText((Join-Path $copy '.dev.env'),"FOREIGN_SETTING=preserve`nVIBECODING1C_MCP_REGISTRY_REPO=$publisher`nVIBECODING1C_MCP_REGISTRY_PATH=$publisher`n",[Text.UTF8Encoding]::new($false))
        @(Initialize-SourceE2ECatalog -Root $copy).Count | Should -Be 0
        Test-Path $publisher | Should -BeFalse
        $null=Initialize-SourceE2ECatalog -Root $copy -RestoreQualificationPublisher
        (Get-FileHash $path).Hash | Should -BeExactly $before
        foreach($relative in @('registry.json','catalog/catalog.json','catalog/product-relations.json')){
            (Get-FileHash (Join-Path $publisher $relative)).Hash | Should -BeExactly (Get-FileHash (Join-Path $seed.root ('.agent-1c/mcp/qualification-catalog/'+$relative))).Hash
        }
        $preview=Invoke-ItlNativeProcessCapture -FilePath powershell.exe -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'),'-ProjectRoot',$copy,'-Action','vibecoding1c-mcp-status','-CatalogAction','preview','-CatalogProjectId','itl-gate-qualification','-AgentTarget','codex') -WorkingDirectory $repoRoot -TimeoutSeconds 60
        $preview.exitCode | Should -Be 0 -Because ($preview.stdout+$preview.stderr)
        $settings.productProject.projectId='foreign-business'
        [IO.File]::WriteAllText($path,($settings|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $envBefore=[IO.File]::ReadAllText((Join-Path $copy '.dev.env'))
        @(Initialize-SourceE2ECatalog -Root $copy -RestoreQualificationPublisher).Count | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $copy '.dev.env')) | Should -BeExactly $envBefore
    }

    It 'selects the technical project without changing the seed environment or creating a publisher' {
        $root=Join-Path $TestDrive 'catalog seed Кириллица'
        [void][IO.Directory]::CreateDirectory((Join-Path $root '.agent-1c'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'src/cf'))
        Set-Content -LiteralPath (Join-Path $root '.agent-1c/project.json') -Value '{"baseConfigurationVersion":"test"}'
        Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/fixtures/gate-stand/cf/Configuration.xml') -Destination (Join-Path $root 'src/cf/Configuration.xml')
        $envPath=Join-Path $root '.dev.env'
        [IO.File]::WriteAllText($envPath,"SOURCE_INFOBASE_PATH=C:\Исходная база`r`n",[Text.UTF8Encoding]::new($false))
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($envPath))
        @(Get-SourceE2ECatalogArguments -Root $root) | Should -Be @('-CatalogProjectId','itl-gate-qualification','-CatalogDecision','keep-local')
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($envPath)) | Should -BeExactly $before
        Test-Path -LiteralPath (Join-Path $root '.agent-1c/mcp/qualification-catalog') | Should -BeFalse
    }

    It 'passes prepared catalog selection through the publication updater before any environment mutation' {
        $f=New-UpdateBoundaryFixture 'publication catalog'
        [void][IO.Directory]::CreateDirectory((Join-Path $f.root '.agent-1c'))
        [void][IO.Directory]::CreateDirectory((Join-Path $f.root 'src/cf'))
        Set-Content -LiteralPath (Join-Path $f.root '.agent-1c/project.json') -Value '{"baseConfigurationVersion":"test"}'
        Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/fixtures/gate-stand/cf/Configuration.xml') -Destination (Join-Path $f.root 'src/cf/Configuration.xml')
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/source-e2e-workflow-update.ps1') -Destination (Join-Path $f.source 'scripts/source-e2e-workflow-update.ps1')
        [void][IO.Directory]::CreateDirectory((Join-Path $f.source 'tests/fixtures/gate-stand/cf'))
        Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/fixtures/gate-stand/cf/Configuration.xml') -Destination (Join-Path $f.source 'tests/fixtures/gate-stand/cf/Configuration.xml')
        $null=Initialize-SourceE2ECatalog -Root $f.root
        $envPath=Join-Path $f.root '.dev.env';$before=(Get-FileHash -LiteralPath $envPath).Hash
        $stub=@'
param($ProjectRoot,$Action,$CatalogProjectId,$CatalogDecision,$WorkflowUpdateBranchRootsFile)
if($Action -cne 'update-workflow' -or $CatalogProjectId -cne 'itl-gate-qualification' -or $CatalogDecision -cne 'keep-local'){throw 'selection not forwarded'}
[IO.File]::WriteAllText((Join-Path $ProjectRoot 'before-transaction.sha'),(Get-FileHash -LiteralPath (Join-Path $ProjectRoot '.dev.env')).Hash)
'@
        [IO.File]::WriteAllText((Join-Path $f.source '.agents/skills/1c-workflow/scripts/agent-1c.ps1'),$stub,[Text.UTF8Encoding]::new($true))
        & git -C $f.source add -A; & git -C $f.source -c user.name=fixture -c user.email=fixture@example.invalid commit -qm 'prepared catalog fixture'
        $script:outputRoot=Join-Path $f.root 'logs';[void][IO.Directory]::CreateDirectory($script:outputRoot)
        $script:steps=[Collections.Generic.List[object]]::new()
        $result=Invoke-DevelopProcess -Name 'stand-update' -ScriptPath (Join-Path $f.source 'scripts/update-installed-workflow.ps1') -Arguments @('-ProjectRoot',$f.root,'-SourceRoot',$f.source,'-WorkflowUpdateBranchRootsFile',(Join-Path $f.root 'scope.json')) -WorkingRoot $f.root -TimeoutSeconds 60 -AllowFailure
        $result.exitCode | Should -Be 0 -Because ((Get-Content -LiteralPath $result.stderr -Raw)-join '')
        Get-Content -LiteralPath (Join-Path $f.root 'before-transaction.sha') -Raw | Should -BeExactly $before
        (Get-FileHash -LiteralPath $envPath).Hash | Should -BeExactly $before
    }

    It 'retains the native failed call and completes the same Unicode root, candidate and client through <Caller>' -TestCases @(@{Caller='Develop'},@{Caller='Release'}) {
        param($Caller)
        $f=New-UpdateBoundaryFixture $Caller
        $prior=$env:ITL_WORKFLOW_SOURCE_PATH
        $script:outputRoot=Join-Path $f.root 'logs';[void][IO.Directory]::CreateDirectory($script:outputRoot)
        $script:steps=[Collections.Generic.List[object]]::new();$script:activeJourney='upgrade'
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH=$f.source
            if($Caller -eq 'Develop'){Invoke-DevelopWorkflowUpdate -Root $f.root -CandidateRoot $f.source -AgentTarget codex -TimeoutSeconds 60}
            else {Invoke-SourceFixtureWorkflowUpdate -Root $f.root -CandidateRoot $f.source -AgentTarget codex -LogRoot $script:outputRoot -TimeoutSeconds 60}
            $receipt=Get-Content -LiteralPath (Join-Path $f.root 'source-owner.json') -Raw -Encoding UTF8|ConvertFrom-Json
            $receipt.project|Should -BeExactly $f.root
            $receipt.source|Should -BeExactly $f.source
            $receipt.client|Should -BeExactly 'codex'
            # The original project stays unbound before the updater runs. Only
            # published test data and explicit CLI inputs satisfy the new rule.
            $settings=Get-Content -LiteralPath (Join-Path $f.root '.agent-1c/project.json') -Raw | ConvertFrom-Json
            $settings.PSObject.Properties['productProject']|Should -BeNullOrEmpty
            $publisher=Join-Path $f.root '.agent-1c/mcp/qualification-catalog'
            (& git -C $publisher rev-parse HEAD).Trim()|Should -Match '^[a-f0-9]{40}$'
            (Get-Content -LiteralPath (Join-Path $publisher 'catalog/catalog.json') -Raw|ConvertFrom-Json).projects[0].projectId|Should -BeExactly 'itl-gate-qualification'
            Get-Content -LiteralPath (Join-Path $f.root '.dev.env') -Raw | Should -Match 'FOREIGN_SETTING=preserve'
            $preview=Invoke-ItlNativeProcessCapture -FilePath powershell.exe -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'),'-ProjectRoot',$f.root,'-Action','vibecoding1c-mcp-status','-CatalogAction','preview','-CatalogProjectId','itl-gate-qualification','-AgentTarget','codex') -WorkingDirectory $repoRoot -TimeoutSeconds 60
            $preview.exitCode|Should -Be 0 -Because ($preview.stdout+$preview.stderr)
            $beforeEnv=[IO.File]::ReadAllText((Join-Path $f.root '.dev.env'))
            $settings|Add-Member -NotePropertyName productProject -NotePropertyValue @{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='retained';productId='retained'}
            [IO.File]::WriteAllText((Join-Path $f.root '.agent-1c/project.json'),($settings|ConvertTo-Json -Depth 5))
            @(Initialize-SourceE2ECatalog -Root $f.root).Count|Should -Be 0
            [IO.File]::ReadAllText((Join-Path $f.root '.dev.env'))|Should -BeExactly $beforeEnv
            $reexec=& {
                . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ProjectRoot $f.root -Action help -CatalogProjectId 'itl-gate-qualification' -CatalogProfileId 'profile with space' -CatalogDecision keep-local *> $null
                @(Get-Agent1cReexecArguments)
            }
            foreach($pair in @(@('-CatalogProjectId','itl-gate-qualification'),@('-CatalogProfileId','profile with space'),@('-CatalogDecision','keep-local'))){
                $reexec[[array]::IndexOf($reexec,$pair[0])+1]|Should -BeExactly $pair[1]
            }
            . (Join-Path $repoRoot 'scripts/quality-contracts.ps1')
            $catalog=Get-QualityContractCatalog $repoRoot
            foreach($journey in @('upgrade','fresh')){
                $projection=Get-DevelopE2EJourneyContractProjection $catalog $journey
                $patterns=@($projection.contracts|ForEach-Object {@($_.paths)+@(Get-QualityContractReuseInputPaths $_)})
                @(Select-QualityPaths -Paths @('tests/fixtures/gate-stand/cf/Configuration.xml') -Pattern $patterns).Count|Should -Be 1
            }
            $logs=@(Get-ChildItem -LiteralPath $script:outputRoot -Filter '*.stdout.log')
            $logs.Count|Should -Be 2
            ($logs|Get-Content -Encoding UTF8|Out-String)|Should -Match '"status":"failed"'
            if($Caller -eq 'Develop'){
                @($script:steps|Where-Object status -eq failed).Count|Should -Be 1
                @($script:steps|Where-Object {$_.name -eq 'upgrade-update-workflow' -and $_.status -eq 'passed'}).Count|Should -Be 1
                $script:steps[-1].attempts.Count|Should -Be 2
            }
        } finally {$env:ITL_WORKFLOW_SOURCE_PATH=$prior}
    }

    It 'preserves failure if the source owner fails and never starts a second continuation' {
        $f=New-UpdateBoundaryFixture 'failed continuation'
        $prior=$env:ITL_WORKFLOW_SOURCE_PATH;$priorFail=$env:ITL_TEST_UPDATE_CONTINUATION_FAIL
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH=$f.source;$env:ITL_TEST_UPDATE_CONTINUATION_FAIL='true'
            {Invoke-SourceFixtureWorkflowUpdate -Root $f.root -CandidateRoot $f.source -AgentTarget codex -LogRoot (Join-Path $f.root 'logs') -TimeoutSeconds 60}|Should -Throw '*SOURCE_E2E_UPDATE_CONTINUATION_FAILED*original logs=*continuation logs=*'
            @(Get-ChildItem -LiteralPath (Join-Path $f.root 'logs') -Filter '*.stdout.log').Count|Should -Be 2
        } finally {$env:ITL_WORKFLOW_SOURCE_PATH=$prior;$env:ITL_TEST_UPDATE_CONTINUATION_FAIL=$priorFail}
    }

    BeforeEach {
        $root=Join-Path $TestDrive 'admission проект';$candidate=Join-Path $TestDrive 'admission кандидат'
        $run=Join-Path $root '.agent-1c/runs/compact-admission';[void][IO.Directory]::CreateDirectory($run)
        $stdout=Join-Path $run 'stdout.log';$statusPath=Join-Path $run 'status.json';$fresh=$statusPath+'.fresh-one.json'
        $summary=@{action='update-workflow';status='failed';blockerRequiresUserDecision=$false;statusPath=$statusPath}
        $status=@{action='update-workflow';status='failed';stage='workflow-update.post-copy';exitCode=1;blockerRequiresUserDecision=$false;projectRoot=$root;startedAt=[datetime]::UtcNow.AddSeconds(1).ToString('o');errorMessage="VERIFICATION_MODEL_POLICY_LEGACY_SNAPSHOT: Original candidate: '$candidate'."}
        $process=[pscustomobject]@{exitCode=1;stdout=$stdout;stderr=($stdout+'.stderr')}
        $script:sourceCalls=0
    }

    It 'refuses <Case> evidence without invoking a source owner' -TestCases @(
        @{Case='unknown guard'},@{Case='foreign root'},@{Case='foreign candidate'},@{Case='stale'},@{Case='foreign status path'},@{Case='corrupt'},@{Case='ambiguous'},@{Case='requires user decision'}) {
        param($Case)
        switch($Case){
            'unknown guard' {$status.errorMessage='UNRELATED_FAILURE'}
            'foreign root' {$status.projectRoot=$candidate}
            'foreign candidate' {$status.errorMessage="VERIFICATION_MODEL_POLICY_LEGACY_SNAPSHOT: Original candidate: '$root'."}
            'stale' {$status.startedAt=[datetime]::UtcNow.AddHours(-1).ToString('o')}
            'foreign status path' {$summary.statusPath=Join-Path $candidate 'status.json'}
            'requires user decision' {$status.blockerRequiresUserDecision=$true}
        }
        [IO.File]::WriteAllText($stdout,($summary|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($fresh,($status|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        if($Case -eq 'corrupt'){[IO.File]::WriteAllText($fresh,'{invalid')}
        if($Case -eq 'ambiguous'){Copy-Item -LiteralPath $fresh -Destination ($statusPath+'.fresh-two.json')}
        try {
            {Invoke-SourceE2EWorkflowUpdate -Root $root -CandidateRoot $candidate -AgentTarget codex -TimeoutSeconds 60 -InstalledOperation {$process} -SourceOperation {$script:sourceCalls++;throw 'must not execute'}}|Should -Throw '*legacy continuation refused*'
            $script:sourceCalls|Should -Be 0
        } finally {if(Test-Path -LiteralPath ($statusPath+'.fresh-two.json')){Remove-Item -LiteralPath ($statusPath+'.fresh-two.json')}}
    }

    It 'passes only the remaining original budget to one continuation' {
        [IO.File]::WriteAllText($stdout,($summary|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($fresh,($status|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        $result=Invoke-SourceE2EWorkflowUpdate -Root $root -CandidateRoot $candidate -AgentTarget codex -TimeoutSeconds 5 -InstalledOperation {Start-Sleep -Milliseconds 1100;$process} -SourceOperation {
            param($Path,$Arguments,$Budget)
            $Budget|Should -BeIn @(1,2,3)
            $Path|Should -BeExactly (Join-Path $candidate 'scripts/update-installed-workflow.ps1')
            $Arguments|Should -Be @('-ProjectRoot',$root,'-SourceRoot',$candidate,'-Recovery','update','-AgentTarget','codex')
            $script:sourceCalls++;[pscustomobject]@{exitCode=0}
        }
        $script:sourceCalls|Should -Be 1
        $result.initial.exitCode|Should -Be 1
    }

    It 'accepts the other documented UI guard and preserves ordinary success without continuation' {
        $status.errorMessage="UI_TESTING_POLICY_LEGACY_SNAPSHOT: Original candidate: '$candidate'."
        [IO.File]::WriteAllText($stdout,($summary|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($fresh,($status|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        Test-SourceE2ELegacyUpdateEvidence -ProcessResult $process -Root $root -CandidateRoot $candidate -StartedAt ([datetime]::UtcNow)|Should -BeTrue
        $summary.status='succeeded';$process.exitCode=0
        [IO.File]::WriteAllText($stdout,($summary|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        $result=Invoke-SourceE2EWorkflowUpdate -Root $root -CandidateRoot $candidate -AgentTarget codex -TimeoutSeconds 60 -InstalledOperation {$process} -SourceOperation {$script:sourceCalls++;throw 'must not execute'}
        $result.continuation|Should -BeNullOrEmpty
        $script:sourceCalls|Should -Be 0
    }

    It 'does not reset an exhausted budget' {
        [IO.File]::WriteAllText($stdout,($summary|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($fresh,($status|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        {Invoke-SourceE2EWorkflowUpdate -Root $root -CandidateRoot $candidate -AgentTarget codex -TimeoutSeconds 1 -InstalledOperation {Start-Sleep -Milliseconds 1100;$process} -SourceOperation {$script:sourceCalls++}}|Should -Throw '*SOURCE_E2E_UPDATE_TIMEOUT*'
        $script:sourceCalls|Should -Be 0
    }
}
