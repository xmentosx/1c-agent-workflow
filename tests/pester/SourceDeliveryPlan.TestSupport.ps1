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
function Add-ReusedStage { param([string]$Name, [string]$Reason, [string]$Detail) }
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

function New-IncrementalPlanFixture {
    $repo=New-PlanRepository
    $root=$repo.root
    $catalog=New-PlanCatalog
    $catalog | Add-Member schemaVersion 1
    $catalog | Add-Member pesterWorkers ([pscustomobject]@{targetedImplicitDefault=4})
    $catalog | Add-Member retiredTests ([pscustomobject]@{})
    $catalog | Add-Member continuationScopes ([pscustomobject]@{static=@('tests/pester/*');gate=@('scripts/*','tests/quality-contracts.json');develop=@('runtime.ps1');release=@('release/*');deliveryPostGate=@('post/*')})
    $catalog.contracts[0] | Add-Member owner 'runtime'
    $catalog.contracts[0] | Add-Member primaryTest 'tests/pester/Runtime.Tests.ps1'
    $catalog.contracts[0] | Add-Member budgetSeconds 30
    $catalog.contracts[0].paths += @('tests/pester/Runtime.Tests.ps1','scripts/invoke-develop-e2e.ps1','scripts/develop-configuration-rejection.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1','templates/dependency-lock.json','tests/quality-contracts.json')
    $catalog.contracts[0].paths += 'scripts/stand-env-identity.ps1'
    $catalog.developJourneys.fullPaths=@('scripts/invoke-develop-e2e.ps1','scripts/develop-configuration-rejection.ps1','scripts/stand-env-identity.ps1')
    foreach($relative in @('scripts/invoke-develop-e2e.ps1','scripts/develop-configuration-rejection.ps1','scripts/stand-env-identity.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')) {
        $path=Join-Path $root $relative
        [void][IO.Directory]::CreateDirectory((Split-Path $path))
        Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $path
    }
    [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'),($catalog|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
    $artifact=Join-Path $root '.git/artifact.bin'
    [IO.File]::WriteAllBytes($artifact,[byte[]](0,1,2,3))
    $sha=(Get-FileHash $artifact).Hash.ToLowerInvariant()
    $binding=[pscustomobject]@{schemaVersion=1;kind='itl-source-e2e-artifact-binding';paths=[pscustomobject]@{
        ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE=$artifact;VANESSA_MCP_CLIENT_CFE_PATH=$artifact;ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE=$artifact}}
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'templates'))
    $lock=@{dependencies=@{vanessaAutomation=@{sha256=$sha;compatibilityVersion='1';downstreamRevision='r1';assetName='archive.zip'};
        vanessaMcp=@{clientMcp=@{sha256=$sha;assetName='client.cfe'}};itlOndemandMcp=@{sha256=$sha;assetName='mcp.exe'}}}
    [IO.File]::WriteAllText((Join-Path $root 'templates/dependency-lock.json'),($lock|ConvertTo-Json -Depth 6))
    # Keep rules and stand outside the candidate: advancing source commits
    # must not silently advance a controlled-fork/environment identity.
    $rules=Join-Path $root '.git/rules'
    & git clone --quiet -- $root $rules
    $stand=Join-Path $root '.git/stand'
    [void][IO.Directory]::CreateDirectory((Join-Path $stand '.agent-1c'))
    [IO.File]::WriteAllText((Join-Path $stand '.agent-1c/project.json'),'{}')
    [IO.File]::WriteAllText((Join-Path $stand '.agent-1c/release-e2e.json'),'{}')
    [IO.File]::WriteAllText((Join-Path $stand '.dev.env'),"PLATFORM_PATH=$artifact`n")
    & git -C $root add --all; & git -C $root commit --quiet -m 'incremental baseline'
    $base=(& git -C $root rev-parse HEAD).Trim()
    return [pscustomobject]@{root=$root;base=$base;catalog=$catalog;binding=$binding;stand=$stand;rules=$rules;artifact=$artifact}
}

function Save-IncrementalJourneyProofs {
    param([object]$Fixture)
    foreach($journey in @('upgrade','fresh')) {
        $inputs=Get-DevelopE2EInputIdentity -RepositoryRoot $Fixture.root -Journey $journey -Catalog $Fixture.catalog -ProjectRoot $Fixture.stand -AiRulesSource $Fixture.rules -AgentTarget kilocode -ArtifactBinding $Fixture.binding
        $inputs | Should -Not -BeNullOrEmpty
        $tree=(& git -C $Fixture.root rev-parse 'HEAD^{tree}').Trim()
        $report=New-DevelopE2ERouteReport -RepositoryRoot $Fixture.root -Plan ([pscustomobject]@{kind='itl-develop-e2e-journey-plan';journeys=@('upgrade','fresh')}) -Journey $journey -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) -JourneyResult ([pscustomobject]@{name=$journey;status='passed'})
        $path=Join-Path $Fixture.root ".git/$journey.json"
        [IO.File]::WriteAllText($path,($report|ConvertTo-Json -Depth 16))
        [void](Save-DevelopE2EQualification -RepositoryRoot $Fixture.root -ReportPath $path -Tree $tree -Journey $journey -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) -InputIdentity $inputs)
    }
}

function Save-IncrementalStaticProof {
    param([object]$Fixture)
    . (Join-Path $context.RepoRoot 'scripts/develop-static-qualification.ps1')
    $commit=(& git -C $Fixture.root rev-parse HEAD).Trim();$tree=(& git -C $Fixture.root rev-parse 'HEAD^{tree}').Trim()
    $junit=Join-Path $Fixture.root '.git/pester.xml'
    [IO.File]::WriteAllText($junit,'<testsuites tests="1" failures="0" errors="0" />')
    $tests=@('tests/pester/Runtime.Tests.ps1')
    $q=@{schemaVersion=4;kind='itl-workflow-full-qualification';status='passed';reusable=$false
        repository=@{commit=$commit;tree=$tree;worktreeClean=$true};result=@{passed=1;failed=0;skipped=0}
        pesterInputs=@{schemaVersion=1;kind='itl-pester-input-identity';reusable=$false;runtimeIdentityStatus='known';runtimeIdentitySha256=('a'*64);files=@($tests|ForEach-Object{@{path=$_;digest=''}})}
        inventory=@{tests=@($tests|ForEach-Object{@{path=$_}})};junit=@{sha256=(Get-FileHash $junit).Hash.ToLowerInvariant()}
        stages=@('pester','git-diff-check','static-tracked-state','ai-rules-compatibility'|ForEach-Object{@{name=$_;status='passed'}})}
    $path=Join-Path $Fixture.root '.git/full.json'
    [IO.File]::WriteAllText($path,($q|ConvertTo-Json -Depth 16))
    Save-DevelopE2ECurrentStaticProof -QualificationPath $path -Commit $commit -Tree $tree
}
