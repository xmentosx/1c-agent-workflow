BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Unattended E2E client selection' {
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts/stand-env-identity.ps1')
        function Get-E2ETestDefinition {
            param([string]$Path,[string]$Name)
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $Path),[ref]$tokens,[ref]$errors)
            if($errors){throw 'Owner must parse'}
            $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$false)
            if(-not $node){throw "Missing owner $Name"};$node.Extent.Text
        }
        function New-E2EClientFixture {
            param([string]$Root,[string[]]$Clients=@('kilocode'))
            $helper=Join-Path $Root '.agents/skills/1c-workflow/scripts/run-itl-command.ps1'
            New-Item -ItemType Directory -Force -Path (Split-Path $helper),(Join-Path $Root '.agent-1c')|Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),(@{aiRules=@{tools=$Clients}}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root '.ai-rules.json'),(@{tools=$Clients}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            $providers=@"
`$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false)
`$forwarded=@(`$args|ForEach-Object{[string]`$_})
`$AgentTarget='';`$Action='';`$ProjectRoot=(Get-Location).Path
foreach(`$name in @('AgentTarget','Action','ProjectRoot')){`$i=[Array]::IndexOf(`$forwarded,'-'+`$name);if(`$i -ge 0){Set-Variable -Name `$name -Value `$forwarded[`$i+1]}}
function Get-AgentTargets {@((Get-Content -Raw -LiteralPath (Join-Path `$ProjectRoot '.agent-1c/project.json')|ConvertFrom-Json).aiRules.tools)}
function Get-AiRules1cProjectManifest {Get-Content -Raw -LiteralPath (Join-Path `$ProjectRoot '.ai-rules.json')|ConvertFrom-Json}
function Get-AiRules1cManifestToolNames {param(`$Manifest)@(`$Manifest.tools)}
function Get-InitAgentExecutionEnvironment {@{CODEX_THREAD_ID='ambient-codex'}}
function Resolve-InitAgentTargetFromExecutionContext {param(`$Environment,`$ProcessChain)'codex'}
function Get-InitAgentExecutionProcessChain {@()}
"@
            $owner=Get-E2ETestDefinition '.agents/skills/1c-workflow/scripts/lib/agent-1c.client-adapters.ps1' 'Get-ItlActiveClient'
            $result=@'
$selected=Get-ItlActiveClient
@{action=$Action;status='succeeded';agentTarget=$selected;root=$ProjectRoot;arguments=$forwarded}|ConvertTo-Json -Depth 4 -Compress
'@
            [IO.File]::WriteAllText($helper,($providers+"`r`n"+$owner+"`r`n"+$result),[Text.UTF8Encoding]::new($true))
            return $helper
        }
    }

    It 'selects the actual <Runner> root and resumes the same ambiguous operation explicitly' -ForEach @(@{Runner='Develop'},@{Runner='Release'}) {
        & {
            $root=Join-Path $TestDrive ("$Runner проект с пробелами")
            $HelperPath=New-E2EClientFixture $root
            $outputRoot=Join-Path $root 'logs';New-Item -ItemType Directory $outputRoot|Out-Null
            $steps=New-Object 'Collections.Generic.List[object]'
            $AgentTarget='';$activeJourney='upgrade';$script:activeStageDeadlineUtc=$null
            foreach($name in @('ConvertTo-DevelopProcessArgument','Invoke-DevelopProcess','Invoke-InstalledAction','Read-CompactSummary')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-develop-e2e.ps1' $name)))}
            foreach($name in @('ConvertTo-NativeArgument','Start-E2EHelperAtRoot','Complete-E2EHelperProcess')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))}
            function Invoke-SelectedFixture {
                if($Runner -eq 'Develop'){
                    $r=Invoke-InstalledAction -Name 'same-operation' -Root $root -Action status -TimeoutSeconds 30
                    return Read-CompactSummary $r
                }
                $invocation=Start-E2EHelperAtRoot -Root $root -Action status -LogPrefix 'same-operation'
                $r=Complete-E2EHelperProcess $invocation -TimeoutSeconds 30
                return Get-Content -Raw -LiteralPath $r.stdoutPath -Encoding UTF8|ConvertFrom-Json
            }
            $config=Join-Path $root '.agent-1c/project.json';$manifest=Join-Path $root '.ai-rules.json'
            $before=(Get-FileHash $config).Hash;$manifestBefore=(Get-FileHash $manifest).Hash
            $result=Invoke-SelectedFixture
            $result.agentTarget|Should -BeExactly 'kilocode';$result.root|Should -BeExactly $root
            @($result.arguments|Where-Object{$_ -ceq '-AgentTarget'}).Count|Should -Be 1
            (Get-FileHash $config).Hash|Should -BeExactly $before
            (Get-FileHash $manifest).Hash|Should -BeExactly $manifestBefore
            [IO.File]::WriteAllText($config,'{"aiRules":{"tools":["kilocode","codex"]}}',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($manifest,'{"tools":["kilocode","codex"]}',[Text.UTF8Encoding]::new($false))
            $ambiguousHash=(Get-FileHash $config).Hash;$ambiguousManifestHash=(Get-FileHash $manifest).Hash
            {Invoke-SelectedFixture}|Should -Throw '*SOURCE_E2E_AGENT_TARGET_REQUIRED*same*command*-AgentTarget*'
            $AgentTarget='kilocode';(Invoke-SelectedFixture).agentTarget|Should -BeExactly 'kilocode'
            (Get-FileHash $config).Hash|Should -BeExactly $ambiguousHash
            (Get-FileHash $manifest).Hash|Should -BeExactly $ambiguousManifestHash
            [IO.File]::WriteAllText($config,'{"aiRules":{"tools":["kilocode"]}}',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($manifest,'{"tools":["kilocode"]}',[Text.UTF8Encoding]::new($false))
            $unattachedConfigHash=(Get-FileHash $config).Hash;$unattachedManifestHash=(Get-FileHash $manifest).Hash
            $AgentTarget='codex'
            {Invoke-SelectedFixture}|Should -Throw '*failed with exit code*'
            (Get-Content (Join-Path $outputRoot 'same-operation.stderr.log') -Raw -Encoding UTF8)|Should -Match "ITL_CLIENT_NOT_ATTACHED: 'codex'"
            (Get-FileHash $config).Hash|Should -BeExactly $unattachedConfigHash
            (Get-FileHash $manifest).Hash|Should -BeExactly $unattachedManifestHash
            # Separate server targets resolve their own config, never the main Kilo root.
            $root=Join-Path $TestDrive ("$Runner server путь")
            $HelperPath=New-E2EClientFixture $root @('qwen');$AgentTarget=''
            (Invoke-SelectedFixture).agentTarget|Should -BeExactly 'qwen'
        }
    }

    It 'keeps the fresh journey on its bootstrap client despite an explicit upgrade client' {
        & {
            $root=Join-Path $TestDrive 'fresh путь с пробелами';$null=New-E2EClientFixture $root
            $outputRoot=Join-Path $root 'logs';New-Item -ItemType Directory $outputRoot|Out-Null
            $steps=New-Object 'Collections.Generic.List[object]';$activeJourney='fresh';$AgentTarget='codex'
            foreach($name in @('ConvertTo-DevelopProcessArgument','Invoke-DevelopProcess','Invoke-InstalledAction','Read-CompactSummary')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-develop-e2e.ps1' $name)))}
            (Read-CompactSummary (Invoke-InstalledAction -Name fresh -Root $root -Action status -TimeoutSeconds 30)).agentTarget|Should -BeExactly 'kilocode'
        }
    }

    It 'reloads an owned recovery write set through the actual checkpoint writer and canonical path validator' {
        & {
            foreach ($name in @('ConvertTo-E2EHashtable', 'Write-E2ECheckpoint')) {
                . ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))
            }
            . (Join-Path $RepoRoot 'scripts/release-e2e/extension-recovery.ps1')
            $root = Join-Path $TestDrive 'checkpoint восстановление с пробелами'
            $checkpointPath = Join-Path $root '.agent-1c/runs/release-e2e/checkpoint.json'
            $paths = @('src/cfe/ITLReleaseSmoke/Languages/Русский.xml', 'src/cfe/ITLReleaseSmoke/Configuration.xml')
            $checkpoint = [ordered]@{
                schemaVersion = 3; runId = 'write-set-roundtrip'; expectedHead = ('a' * 40)
                extensionRecovery = [ordered]@{
                    writeSet = $paths
                    files = @([ordered]@{ path = $paths[0]; bytes = 31; sha256 = ('b' * 64) })
                    stopEvidence = [ordered]@{ launcherExited = $true; nativeQuiescent = $true }
                }
            }
            Write-E2ECheckpoint
            $reloaded = ConvertTo-E2EHashtable (Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            foreach ($path in @($reloaded.extensionRecovery.writeSet)) { $path | Should -BeOfType ([string]) }
            @($reloaded.extensionRecovery.writeSet) | Should -Be $paths
            $reloaded.extensionRecovery.files.path | Should -BeExactly $paths[0]
            $reloaded.extensionRecovery.files.bytes | Should -Be 31
            $reloaded.extensionRecovery.stopEvidence.launcherExited | Should -BeTrue
            $context = [ordered]@{
                projectRoot = $root; worktreePath = $root; commonGitPath = (Join-Path $root '.git')
                branch = 'itldev/fixture'; expectedHead = $reloaded.expectedHead
                checkpointPath = $checkpointPath; runId = $reloaded.runId
                infoBaseKind = 'file'; infoBasePath = (Join-Path $root '.agent-1c/infobases/fixture')
            }
            $set = Get-ReleaseExtensionRecoveryWriteSet -Context $context -ExtensionName 'ITLReleaseSmoke' -WriteSet @($reloaded.extensionRecovery.writeSet)
            @($set.paths) | Should -Be @($paths | Sort-Object)
            $set.root | Should -BeExactly (Join-Path $root 'src/cfe/ITLReleaseSmoke')
        }
    }
    It 'preserves scalar client identity through the actual immutable capability cache writer' {
        & {
            foreach($name in @('ConvertTo-E2EHashtable','Get-E2EGeneratedCommitRecords','Save-E2ECapabilityCache')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))}
            $ProjectRoot=Join-Path $TestDrive 'cache scalar путь с пробелами';$null=New-E2EClientFixture $ProjectRoot
            $clientSelectionIdentity=Get-SourceE2EClientIdentity -ProjectRoot $ProjectRoot -AgentTarget 'kilocode'
            $capabilityCacheRoot=Join-Path $ProjectRoot 'capability-cache'
            $checkpoint=[ordered]@{runId='scalar-identity';identity=[ordered]@{clientSelection=$clientSelectionIdentity};snapshots=[ordered]@{};stateFiles=[ordered]@{};stages=[ordered]@{};generatedCommits=@()}
            $manifestPath=Save-E2ECapabilityCache
            $saved=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
            $saved.identity.clientSelection|Should -BeOfType ([string])
            $saved.identity.clientSelection|Should -BeExactly $clientSelectionIdentity
            $copied=ConvertTo-E2EHashtable $saved
            $copied.identity.clientSelection|Should -BeOfType ([string])
            $copied.identity.clientSelection|Should -BeExactly $clientSelectionIdentity
        }
    }
    It 'binds stage fingerprints and cache fallback to the client and actual server configuration' {
        & {
            $ProjectRoot=Join-Path $TestDrive 'fingerprint путь';$null=New-E2EClientFixture $ProjectRoot
            $server=Join-Path $TestDrive 'server fingerprint путь';$null=New-E2EClientFixture $server @('qwen')
            [IO.File]::WriteAllText((Join-Path $ProjectRoot '.agent-1c/release-e2e.json'),(@{serverWorktreePath=$server}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            . (Join-Path $RepoRoot 'scripts/release-e2e/admission.ps1')
            foreach($name in @('Get-E2EStageAdmissionContext','Get-E2EStageFingerprint')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))}
            $workflowRoot=Join-Path $TestDrive 'recipe исходники';$stageModuleRoot=Join-Path $workflowRoot 'scripts/release-e2e'
            New-Item -ItemType Directory -Force $stageModuleRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $workflowRoot 'scripts/stand-env-identity.ps1'),'identity fixture',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $stageModuleRoot 'probe.ps1'),'probe fixture',[Text.UTF8Encoding]::new($false))
            $script:ReleaseE2EStageDefinitions=@{probe=@{version=1;dependsOn=@();paths=@();moduleFile='probe.ps1'}}
            $script:E2ETrackedInputFiles=@()
            function Get-E2EReleaseConfigValue {param($Name)''}
            $runnerSha256='runner';$workflowCommit='fixture';$aiRulesCommit='fork';$aiRulesTree='tree';$projectConfigSha256='config'
            $clientSelectionIdentity=Get-SourceE2EClientIdentity $ProjectRoot 'kilocode';$first=Get-E2EStageFingerprint probe
            $clientSelectionIdentity=Get-SourceE2EClientIdentity $ProjectRoot 'codex';(Get-E2EStageFingerprint probe)|Should -Not -Be $first
            $clientSelectionIdentity=Get-SourceE2EClientIdentity $ProjectRoot 'kilocode';(Get-E2EStageFingerprint probe)|Should -Be $first
            [IO.File]::WriteAllText((Join-Path $server '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}',[Text.UTF8Encoding]::new($false))
            $clientSelectionIdentity=Get-SourceE2EClientIdentity $ProjectRoot 'kilocode';(Get-E2EStageFingerprint probe)|Should -Not -Be $first
        }
    }

    It 'rejects old or differently selected cache proof even when source inputs are unchanged' {
        & {
            foreach($name in @('ConvertTo-E2EHashtable','Find-E2ECompletedCapabilityCache','Restore-E2EInterruptedCapabilityStage')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))}
            $capabilityCacheRoot=Join-Path $TestDrive 'cache client путь';New-Item -ItemType Directory $capabilityCacheRoot|Out-Null
            $manifest=Join-Path $capabilityCacheRoot 'manifest.json'
            $ProjectRoot=$TestDrive;$worktreePath=$TestDrive;$branch='itldev/probe';$aiRulesCommit='fork';$aiRulesTree='fork-tree';$projectConfigSha256='project'
            $workflowRoot=$RepoRoot;$workflowCommit='current';$workflowTree='current-tree';$serverResetConfigured=$false;$serverResetTestFixture=$false
            $clientSelectionIdentity='selected-kilo'
            $cache=@{schemaVersion=1;identity=@{projectRoot=$ProjectRoot;worktreePath=$worktreePath;branch=$branch;initialHead='initial';aiRulesCommit=$aiRulesCommit;aiRulesTree=$aiRulesTree;projectConfigSha256=$projectConfigSha256;workflowCommit='previous';runnerSha256='previous-runner';clientSelection=$clientSelectionIdentity};stages=@{};snapshots=@{};stateFiles=@{}}
            foreach($stage in @('seed-parallel','config-cadence','config-roundtrip','extension-smoke','ondemand-mcp')){$cache.stages[$stage]=@{status='passed';fingerprint='old';evidencePath=''}}
            foreach($snapshot in @('baseline','postConfig')){$cache.snapshots[$snapshot]=@{path='snapshot';sha256='snapshot-sha'};$cache.stateFiles[$snapshot]=@{stateCopyPath='state';stateSha256='state-sha';envCopyPath=''}}
            [IO.File]::WriteAllText($manifest,($cache|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            $checkpoint=@{identity=@{initialHead='initial'};stages=@{'seed-parallel'=@{status='running'}}}
            function Get-WorkflowContinuationProof {param($RepositoryRoot,$QualifiedCommit,$CurrentCommit,$CurrentTree)$true}
            function Get-E2EStageFingerprint {param($Name,$RunnerSha256)'different-current-fingerprint'}
            function Test-E2EStageInputsUnchanged {param($Name,$QualifiedCommit)$true}
            function Assert-E2ECheckpointFile {param($Path,$Sha256,$Label)}
            function Write-E2ECheckpoint {}
            (Find-E2ECompletedCapabilityCache)|Should -BeExactly $manifest
            (Restore-E2EInterruptedCapabilityStage 'seed-parallel')|Should -BeTrue
            $checkpoint.stages['seed-parallel']=@{status='running'}
            $clientSelectionIdentity='selected-codex'
            (Find-E2ECompletedCapabilityCache)|Should -BeNullOrEmpty
            (Restore-E2EInterruptedCapabilityStage 'seed-parallel')|Should -BeFalse
            $clientSelectionIdentity='selected-kilo';$cache.identity.Remove('clientSelection')
            [IO.File]::WriteAllText($manifest,($cache|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            (Find-E2ECompletedCapabilityCache)|Should -BeNullOrEmpty
            (Restore-E2EInterruptedCapabilityStage 'seed-parallel')|Should -BeFalse
            $checkpoint.stages['seed-parallel'].status|Should -BeExactly 'running'
        }
    }
}
