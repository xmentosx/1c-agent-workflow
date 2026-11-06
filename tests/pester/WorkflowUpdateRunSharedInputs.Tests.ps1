Describe 'update-workflow shared run inputs' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $HelperPath = $context.HelperPath

        # Master plus two development worktrees, applied in sequence by one
        # update-workflow process. Expensive machine-scoped owners are counted;
        # branch-local writers (.dev.env settings) stay real.
        function Invoke-RunFixture {
            param([Parameter(Mandatory = $true)][string]$Parent, [switch]$Shared, [hashtable]$RoctupVersionByRoot = @{})
            $roots = @(foreach ($leaf in @('Мастер проект с пробелом', 'Ветка один с пробелом', 'Ветка два с пробелом')) {
                $root = Join-Path $Parent $leaf
                New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
                @{aiRules=@{tools=@('codex')}} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root '.agent-1c/project.json') -Encoding UTF8
                $root
            })
            $fork = Join-Path $Parent 'Форк правил с пробелом'
            New-Item -ItemType Directory -Force -Path $fork | Out-Null
            $preflightCounter = Join-Path $Parent 'preflight count.txt'
            Set-Content -LiteralPath (Join-Path $fork 'install.ps1') -Encoding UTF8 -Value @'
param([string]$Command, [string]$ProjectRoot, [string]$Source, [string]$Tools, [string]$McpMode, [switch]$NonInteractive, [switch]$AssumeYes)
[IO.File]::AppendAllText($env:ITL_TEST_PREFLIGHT_COUNTER, "$Command`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $ProjectRoot '.ai-rules.json'), '{"files":{"AGENTS.md":{},".codex/rules/core.md":{}}}', [Text.UTF8Encoding]::new($false))
'@
            $registryRoot = Join-Path $Parent 'Реестр MCP с пробелом'
            New-Item -ItemType Directory -Force -Path $registryRoot | Out-Null
            @{publishedAt='fixture';servers=@()} | ConvertTo-Json | Set-Content (Join-Path $registryRoot 'registry.json') -Encoding UTF8
            $artifactRoot = Join-Path $Parent 'Общий кэш артефактов'
            $facadeBytes = [Text.Encoding]::UTF8.GetBytes('fixture facade')
            $facadeSha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($facadeBytes)) -replace '-', '').ToLowerInvariant()
            $counts = [ordered]@{ preflight=0; roctup=0; vanessaEpf=0; vanessaUiMcp=0; vanessaUiMcpLock=0; ondemand=0
                registry=0; agentBrowser=0; windowsMcp=0; windowsMcpWarnings=0; installer=0; commandSurface=0 }
            $previousAutoInstall = $env:ITL_UI_TOOLS_AUTO_INSTALL
            $previousCounter = $env:ITL_TEST_PREFLIGHT_COUNTER
            try {
                $env:ITL_UI_TOOLS_AUTO_INSTALL = ''
                $env:ITL_TEST_PREFLIGHT_COUNTER = $preflightCounter
                & {
                    . $HelperPath -ProjectRoot $roots[0] -Action help -AgentTarget codex *> $null
                    $SkipAiRules = $false
                    foreach ($name in @(
                        'Assert-WorkflowUpdateMcpConfigSnapshot','Assert-UiTestingPolicyUpdateSnapshot',
                        'Restore-UnfinishedForkCopiedMcpOwnership','Ensure-OneCSessionLimitDotEnv',
                        'Ensure-Agent1cLifecycleLocksIgnored','Ensure-GitIgnore','Ensure-ItlPinnedOpenSpecGitAttributes',
                        'Sync-ItlVanessaLibraries','Update-UserRules','Sync-WorkflowManagedDependencyLockEntries',
                        'Install-YAxUnit','Sync-VanessaAutomationDependencyLock','Sync-ItlOnDemandMcpDependencyLock',
                        'Update-AgentGuidanceBridge','Sync-ItlClientUserEnvironment','Invoke-CavemanPolicyTransition',
                        'Assert-AiRulesMigrationCandidateScope'
                    )) { Set-Item -Path ('Function:' + $name) -Value {} }
                    function Get-WorkflowUpdatePendingSnapshot { @{receipt=@{sourceRoot=$script:ProjectRoot};snapshot=@{}} }
                    function Test-WorkflowSourceLayeredOpenCodeConfig { $true }
                    function Test-WorkflowSourceUiTestingPolicy { $false }
                    function Get-AiRules1cManifestFileEntries { @() }
                    function Get-WorkflowUpdateClientSurfacePaths { @() }
                    function Get-CavemanPolicyPreviousWorkflowCommit { '' }
                    function Get-AiRulesMigrationPlan { [pscustomobject]@{eligible=$false;status='current';suppressRegularUpdate=$false;reason=''} }
                    function Sync-AiRules1cCheckout { [pscustomobject]@{root=$fork;repo='https://example.invalid/ai_rules_1c.git';ref='itl-fixture';commit=('a' * 40)} }
                    function Invoke-AiRules1cInstaller { param([string]$Command) $counts.installer++ }
                    function Sync-ItlClientSurfaces { param([string]$SourceRoot) $counts.commandSurface++ }
                    function Write-Warning { param([Parameter(Position = 0)][string]$Message, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest) if ($Message -match 'WINDOWS_MCP_UVX_REQUIRED') { $counts.windowsMcpWarnings++ } }
                    # ROCTUP: shared artifact acquisition; settings stay real.
                    function Get-RoctupMcpEnabled { $true }
                    function Get-RoctupMcpReleaseAssetInfo {
                        $leaf = Split-Path -Leaf $script:ProjectRoot
                        $version = if ($RoctupVersionByRoot.ContainsKey($leaf)) { $RoctupVersionByRoot[$leaf] } else { 'v1.7.1' }
                        [pscustomobject]@{url='https://example.invalid/MCP_Toolkit.epf';name='MCP_Toolkit.epf';version=$version;expectedSha256=('b' * 64);source='workflow-selection'}
                    }
                    function Get-RoctupMcpInstallRoot { Join-Path $artifactRoot 'roctup' }
                    function Find-RoctupMcpEpf { '' }
                    function Install-RoctupMcpSkillsBestEffort { param([string]$Version, [string]$InstallRoot) }
                    function Save-RoctupMcpArtifact {
                        param([object]$AssetInfo)
                        $counts.roctup++
                        $epf = Join-Path (Get-RoctupMcpInstallRoot) "$($AssetInfo.version)\MCP_Toolkit.epf"
                        [pscustomobject]@{path=$epf;version=$AssetInfo.version;sha256=$AssetInfo.expectedSha256;source='workflow-selection'}
                    }
                    # Vanessa Automation: shared EPF hash proof.
                    function Get-VanessaAutomationDownloadInfo { [pscustomobject]@{compatibilityVersion='1.2.043.42';downstreamRevision='itl-r8'} }
                    function Get-WorkflowDependencyEntry { param([string]$Name, [object]$Plan) if ($Name -eq 'vanessaAutomation') { [pscustomobject]@{version='1.2.043.42';epfSha256=('c' * 64)} } }
                    function Get-VanessaAutomationEpfPath { Join-Path $artifactRoot 'vanessa\vanessa.epf' }
                    function Get-VanessaAutomationState {
                        $counts.vanessaEpf++
                        [pscustomobject]@{ready=$true;epfPath=(Get-VanessaAutomationEpfPath);version='1.2.043.42';downstreamRevision='itl-r8'}
                    }
                    # Vanessa UI MCP: shared CFE acquisition; lock entry is unchanged.
                    function Get-VanessaMcpReleaseAssetInfo { param([object]$Definition) [pscustomobject]@{url="https://example.invalid/$($Definition.lockKey).cfe";name="$($Definition.lockKey).cfe";version='0.6.5';expectedSha256=('d' * 64);source='workflow-selection'} }
                    function Get-VanessaMcpManagedArtifactPath { param([object]$Definition) Join-Path $artifactRoot "vanessa-mcp\$($Definition.lockKey).cfe" }
                    function Get-VanessaMcpArtifactLockEntry { param([object]$Definition) [pscustomobject]@{version='0.6.5';sha256=('d' * 64)} }
                    function Update-VanessaMcpArtifactLockEntry { param([object]$Artifact) $counts.vanessaUiMcpLock++ }
                    function Install-VanessaMcpArtifact {
                        param([object]$Definition, [switch]$ForceDownload)
                        $counts.vanessaUiMcp++
                        [pscustomobject]@{key=[string]$Definition.lockKey;path=(Get-VanessaMcpManagedArtifactPath -Definition $Definition);version='0.6.5';sha256=('d' * 64);source='workflow-selection'}
                    }
                    # On-demand MCP facade: the real owner proves a cached executable.
                    $facadeDirectory = Join-Path $artifactRoot ('ondemand\0.4.27\' + $facadeSha)
                    New-Item -ItemType Directory -Force -Path $facadeDirectory | Out-Null
                    [IO.File]::WriteAllBytes((Join-Path $facadeDirectory 'itl-ondemand-mcp-windows-amd64.exe'), $facadeBytes)
                    function Get-ItlOnDemandMcpFacadeContract {
                        [pscustomobject]@{version='0.4.27';sha256=$facadeSha;assetName='itl-ondemand-mcp-windows-amd64.exe'
                            entry=[pscustomobject]@{version='0.4.27';sha256=$facadeSha;url='https://example.invalid/itl.exe'}}
                    }
                    function Get-ItlOnDemandMcpInstallRoot { Join-Path $artifactRoot 'ondemand' }
                    function Get-FileHash {
                        param([string]$LiteralPath, [string]$Algorithm)
                        if ($LiteralPath -like '*itl-ondemand-mcp-windows-amd64.exe') { $counts.ondemand++ }
                        Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
                    }
                    # User-scope UI tools; windows-mcp stays degraded without uvx.
                    function Get-ItlUiToolsLock { param([string]$Name) [pscustomobject]@{ $Name = [pscustomobject]@{version='1.0'} } }
                    function Install-ItlAgentBrowser { $counts.agentBrowser++ }
                    function Install-ItlWindowsMcp { $counts.windowsMcp++; throw 'WINDOWS_MCP_UVX_REQUIRED: uv/uvx is required.' }
                    # vibecoding1c registry checkout and snapshot.
                    function Test-Vibecoding1cMcpLegacySelectionPresent { $true }
                    function Get-Vibecoding1cMcpRegistryRoot { $registryRoot }
                    function Update-Vibecoding1cMcpRegistryCheckout { $counts.registry++; $registryRoot }
                    function Read-Vibecoding1cMcpSelection { @{} }
                    function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{isComplete=$false;reasons=@('fixture')} }

                    $applyCopy = {
                        foreach ($root in $roots) {
                            Invoke-InProjectContext -Root $root -ScriptBlock {
                                $checkout = Sync-AiRules1cCheckout
                                # Pre-copy snapshot inventory, then the migration owner's preflight.
                                Get-AiRulesCandidateInstallInventory -Checkout $checkout -Tools @(Get-AgentTargets) | Out-Null
                                Invoke-AiRulesMigrationCandidatePreflight -Plan ([pscustomobject]@{tools=@(Get-AgentTargets);target=[pscustomobject]@{
                                    repo=$checkout.repo;ref=$checkout.ref;commit=$checkout.commit;upstreamCommit=('f' * 40);explicitWorkflowAdoption=$true}}) | Out-Null
                                Invoke-WorkflowPackageFilePostCopy *> $null
                            }
                        }
                    }
                    if ($Shared) { Invoke-WorkflowUpdateRunSharedInputs $applyCopy } else { & $applyCopy }
                    Test-WorkflowUpdateRunSharedInputsActive | Should -BeFalse
                    Get-Variable ItlWorkflowPostCopyDefersClientSurfaces -Scope Script -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
                }
            } finally {
                $env:ITL_UI_TOOLS_AUTO_INSTALL = $previousAutoInstall
                $env:ITL_TEST_PREFLIGHT_COUNTER = $previousCounter
            }
            $counts.preflight = @([IO.File]::ReadAllLines($preflightCounter) | Where-Object { $_ }).Count
            return [pscustomobject]@{ roots = $roots; counts = $counts }
        }
    }

    It 'prepares machine-scoped inputs once for master and two branches while each copy installs rules and surfaces once' {
        $current = Invoke-RunFixture -Parent (Join-Path $TestDrive 'Текущий порядок с пробелом')
        $shared = Invoke-RunFixture -Parent (Join-Path $TestDrive 'Общие входы прогона с пробелом') -Shared

        # Each copy keeps exactly one rules installer pass and one command surface.
        $shared.counts.installer | Should -Be 3
        $shared.counts.commandSurface | Should -Be 3
        $current.counts.installer | Should -Be 3
        $current.counts.commandSurface | Should -Be 3
        # Artifact proofs, registry refresh, rules preflight and windows-mcp run once per run.
        foreach ($name in @('preflight','roctup','vanessaEpf','registry','agentBrowser','windowsMcp','windowsMcpWarnings')) {
            $shared.counts[$name] | Should -Be 1 -Because $name
        }
        # One facade proof (its hash reads) per run instead of one per copy.
        $shared.counts.ondemand | Should -BeGreaterThan 0
        ($shared.counts.ondemand * 3) | Should -Be $current.counts.ondemand
        $shared.counts.vanessaUiMcp | Should -Be 2 -Because 'one acquisition per Vanessa UI MCP CFE'
        $shared.counts.vanessaUiMcpLock | Should -Be 0 -Because 'an unchanged lock entry is not rewritten'
        # The same fixture without the run scope repeats every proof per copy.
        $current.counts.preflight | Should -Be 6
        $current.counts.roctup | Should -Be 3
        $current.counts.registry | Should -Be 3
        $current.counts.windowsMcpWarnings | Should -Be 3

        for ($index = 0; $index -lt 3; $index++) {
            $expected = [IO.File]::ReadAllText((Join-Path $current.roots[$index] '.dev.env'))
            $actual = [IO.File]::ReadAllText((Join-Path $shared.roots[$index] '.dev.env'))
            $expected = $expected.Replace((Split-Path -Parent $current.roots[$index]), '<parent>')
            $actual = $actual.Replace((Split-Path -Parent $shared.roots[$index]), '<parent>')
            $actual | Should -BeExactly $expected
            $actual | Should -Match 'ROCTUP_MCP_TOOLKIT_EPF='
            $actual | Should -Match 'VANESSA_AUTOMATION_EPF='
            $actual | Should -Match 'VANESSA_MCP_CLIENT_CFE_PATH='
        }
    }

    It 'reverifies a shared artifact for a branch whose pin differs from master' {
        $run = Invoke-RunFixture -Parent (Join-Path $TestDrive 'Другой пин ветки с пробелом') -Shared -RoctupVersionByRoot @{ 'Ветка два с пробелом' = 'v1.8.0' }
        $run.counts.roctup | Should -Be 2
        [IO.File]::ReadAllText((Join-Path $run.roots[2] '.dev.env')) | Should -Match 'ROCTUP_MCP_VERSION=v1\.8\.0'
        [IO.File]::ReadAllText((Join-Path $run.roots[1] '.dev.env')) | Should -Match 'ROCTUP_MCP_VERSION=v1\.7\.1'
    }
}
