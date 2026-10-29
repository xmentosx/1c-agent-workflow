[CmdletBinding()]
param(
    [string]$StandRoot = '',
    [string]$PositiveRoot = '',
    [string]$SourceRoot = '',
    [string]$AiRulesSource = '',
    [string]$AgentTarget = 'kilocode',
    [string]$PlatformPath = ''
)
# Builds the Develop/Release qualification stand from the repository fixture
# (openspec/changes/minimal-gate-stand). It only composes existing owners:
# native infobase creation, configured init, new-dev-branch and Git. The stand
# has no lifecycle of its own; a failed build is repeated on new directories.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot = Join-Path $repositoryRoot 'tests/fixtures/gate-stand'
. (Join-Path $PSScriptRoot 'source-delivery-process.ps1')
. (Join-Path $PSScriptRoot 'source-delivery-component.ps1')

function Read-GateStandFixture {
    param([string]$Root)
    $manifest = [IO.File]::ReadAllText((Join-Path $Root 'manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.kind -cne 'itl-gate-stand-fixture') { throw 'GATE_STAND_FIXTURE_INVALID: unsupported manifest.' }
    foreach ($relative in @([string]$manifest.configurationPath, [string]$manifest.negative.replacementPath, [string]$manifest.release.markerPath, [string]$manifest.release.featureSourcePath)) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relative))) { throw "GATE_STAND_FIXTURE_INVALID: missing '$relative'." }
    }
    foreach ($relative in @([string]$manifest.negative.sourcePath, [string]$manifest.release.modulePath)) {
        if ($relative -cnotlike 'src/cf/*' -or -not (Test-Path -LiteralPath (Join-Path (Join-Path $Root $manifest.configurationPath) $relative.Substring(7)) -PathType Leaf)) {
            throw "GATE_STAND_FIXTURE_INVALID: '$relative' is not a fixture configuration file."
        }
    }
    return $manifest
}

function Assert-GateStandTarget {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { throw "GATE_STAND_TARGET_NOT_EMPTY: '$Path' is a file; choose a new stand directory." }
    if ((Test-Path -LiteralPath $Path -PathType Container) -and @(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
        throw "GATE_STAND_TARGET_NOT_EMPTY: '$Path' already has content; choose a new stand directory."
    }
}

function New-GateStandProjectSettings {
    param([string]$ProjectRoot, [string]$SnapshotPath, [string]$Platform, [string]$User, [string]$Agent)
    $project = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'templates/project.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $project.sourceUsesRepository = $false
    $project.sourceInfoBaseUnsafeActionProtectionMode = 'confirmed'
    $project.aiRules.tools = @($Agent)
    $overrides = [ordered]@{
        PLATFORM_PATH = $Platform; SOURCE_USES_REPOSITORY = 'false'; SOURCE_INFOBASE_PATH = $SnapshotPath
        IB_USER = $User; IB_PASSWORD = ''; REPOSITORY_PATH = ''; REPOSITORY_USER = ''
        SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE = 'confirmed'; DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP = 'skip'
        VIBECODING1C_MCP_SETUP_DURING_INIT = 'false'
    }
    $lines = New-Object Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $repositoryRoot 'templates/dev.env.example'), [Text.Encoding]::UTF8)) {
        $name = if ($line -match '^([A-Z0-9_]+)=') { $Matches[1] } else { '' }
        if ($name -and $overrides.Contains($name)) { continue }
        $lines.Add($line)
    }
    foreach ($key in $overrides.Keys) { $lines.Add("$key=$($overrides[$key])") }
    return [pscustomobject]@{ project = $project; env = @($lines) }
}

function Write-GateStandProject {
    param([string]$ProjectRoot, [object]$Settings)
    $agentRoot = Join-Path $ProjectRoot '.agent-1c'
    [void][IO.Directory]::CreateDirectory($agentRoot)
    [IO.File]::WriteAllText((Join-Path $agentRoot 'project.json'), (($Settings.project | ConvertTo-Json -Depth 10) + [Environment]::NewLine), $utf8)
    [IO.File]::WriteAllText((Join-Path $ProjectRoot '.dev.env'), (($Settings.env -join [Environment]::NewLine) + [Environment]::NewLine), $utf8)
}

function New-GateStandReleaseConfig {
    param([string]$DevelopBranch, [string]$DevelopWorktree, [string]$ReleaseBranch, [string]$ReleaseWorktree, [object]$Rejection)
    $config = [ordered]@{
        schemaVersion = 1; developDevBranchName = $DevelopBranch; developWorktreePath = $DevelopWorktree
        devBranchName = $ReleaseBranch; worktreePath = $ReleaseWorktree; preserveWorktreePaths = @($DevelopWorktree)
    }
    if ($null -ne $Rejection) { $config.developConfigurationRejection = $Rejection }
    return $config
}

function Invoke-GateStandChild {
    param([string]$Name, [string]$WorkingRoot, [string]$ScriptPath, [string[]]$Arguments, [int]$TimeoutSeconds, [Collections.IDictionary]$Environment = $null)
    $stdout = Join-Path $script:LogRoot ($Name + '.stdout.log'); $stderr = Join-Path $script:LogRoot ($Name + '.stderr.log')
    $parts = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($Arguments)
    $line = @($parts | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value ([string]$_) }) -join ' '
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $job = Start-DeliveryProcess -ArgumentList $line -WorkingDirectory $WorkingRoot -StandardOutputPath $stdout -StandardErrorPath $stderr -EnvironmentOverrides $Environment
    $errorText = ''
    try {
        if (-not $job.process.WaitForExit($TimeoutSeconds * 1000)) { throw "GATE_STAND_STEP_TIMEOUT: '$Name' exceeded $TimeoutSeconds s; see $stdout" }
        $job.process.WaitForExit()
        if ($job.process.ExitCode -ne 0) { throw "GATE_STAND_STEP_FAILED: '$Name' exit=$($job.process.ExitCode); see $stdout and $stderr" }
    } catch { $errorText = $_.Exception.Message; throw }
    finally { Close-DeliveryProcessJob -JobHandle $job.jobHandle -Process $job.process -PriorErrorMessage $errorText; $job.process.Dispose() }
    $script:Steps.Add([ordered]@{ name = $Name; durationMs = [int64]$watch.ElapsedMilliseconds; stdout = $stdout }) | Out-Null
}

function New-GateStandSnapshot {
    param([string]$ProjectRoot, [object]$Fixture, [switch]$Negative)
    # Native work happens in an owned context root; only the finished base
    # moves into the not-yet-initialized project as its in-stand source.
    $work = Join-Path ([IO.Path]::GetTempPath()) ('itl-gate-stand-' + [guid]::NewGuid().ToString('N'))
    $source = Join-Path $work 'source'
    Copy-Item -LiteralPath (Join-Path $fixtureRoot $Fixture.configurationPath) -Destination $source -Recurse
    if ($Negative) {
        Copy-Item -LiteralPath (Join-Path $fixtureRoot $Fixture.negative.replacementPath) -Destination (Join-Path $source ([string]$Fixture.negative.sourcePath).Substring(7)) -Force
    }
    $base = Join-Path $work 'base'
    $sessionScript = {
        param($WorkRoot, $SourcePath, $BasePath, $Platform, $Repository)
        $ErrorActionPreference = 'Stop'
        [Environment]::SetEnvironmentVariable('PLATFORM_PATH', $Platform, 'Process')
        . (Join-Path $Repository '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ProjectRoot $WorkRoot -Action help *> $null
        . (Join-Path $Repository 'scripts/vanessa-build-runtime.ps1')
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
        $template = Get-VanessaServiceInfoBaseTemplate
        [void](Invoke-VanessaBuildOwnedNative -FilePath (Get-PlatformPath) -Arguments @('CREATEINFOBASE', (New-FileInfoBaseConnectionString -Path $BasePath), '/DisableStartupDialogs', '/Out', (Join-Path $WorkRoot 'create-base.log')) -Bases @([pscustomobject]@{ kind = 'file'; path = $BasePath }) -Purpose 'gate-stand-create' -CreateInfoBase -TimeoutSeconds 300)
        Invoke-Designer -InfoBaseKind file -InfoBasePath $BasePath -User '' -Password '' -DesignerArgs @('/RestoreIB', $template.path) | Out-Null
        Invoke-Designer -InfoBaseKind file -InfoBasePath $BasePath -User $template.user -Password '' -DesignerArgs @('/LoadConfigFromFiles', $SourcePath, '/UpdateDBCfg') | Out-Null
        return $template.user
    }
    $user = & $sessionScript $work $source $base $script:Platform $repositoryRoot
    $snapshot = Join-Path $ProjectRoot '.agent-1c\infobases\source-snapshot'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $snapshot))
    Move-Item -LiteralPath $base -Destination $snapshot
    Remove-Item -LiteralPath $work -Recurse -Force
    return [pscustomobject]@{ path = $snapshot; user = [string]$user }
}

function Initialize-GateStandProject {
    param([string]$ProjectRoot, [object]$Fixture, [switch]$Negative, [string]$Label)
    [void][IO.Directory]::CreateDirectory($ProjectRoot)
    $snapshot = New-GateStandSnapshot -ProjectRoot $ProjectRoot -Fixture $Fixture -Negative:$Negative
    Write-GateStandProject -ProjectRoot $ProjectRoot -Settings (New-GateStandProjectSettings -ProjectRoot $ProjectRoot -SnapshotPath $snapshot.path -Platform $script:Platform -User $snapshot.user -Agent $AgentTarget)
    $environment = if ($AiRulesSource) { @{ ITL_AI_RULES_SOURCE_PATH = [IO.Path]::GetFullPath($AiRulesSource) } } else { $null }
    # Monitored bootstrap budget: default init limit plus 300 seconds.
    Invoke-GateStandChild -Name "$Label-init" -WorkingRoot $ProjectRoot -ScriptPath (Join-Path $SourceRoot 'install-agent-1c-workflow.ps1') `
        -Arguments @('-ProjectRoot', $ProjectRoot, '-SourceRoot', $SourceRoot, '-InitMode', 'configured', '-AgentTarget', $AgentTarget, '-SkipWorkflowSourceFreshnessCheck') `
        -TimeoutSeconds 14700 -Environment $environment
}

function New-GateStandBranch {
    param([string]$ProjectRoot, [string]$Name, [string]$Label)
    $runner = Join-Path $ProjectRoot '.agents\skills\1c-workflow\scripts\run-itl-command.ps1'
    Invoke-GateStandChild -Name "$Label-branch-$Name" -WorkingRoot $ProjectRoot -ScriptPath $runner `
        -Arguments @('-Windowed', '--', '-Action', 'new-dev-branch', '-AgentTarget', $AgentTarget, '-DevBranchName', $Name) -TimeoutSeconds 3600
    $current = ''
    foreach ($line in @(& git -C $ProjectRoot worktree list --porcelain)) {
        if ($line -like 'worktree *') { $current = $line.Substring(9) }
        if ($line -ceq "branch refs/heads/itldev/$Name") { return [IO.Path]::GetFullPath($current) }
    }
    throw "GATE_STAND_BRANCH_MISSING: itldev/$Name was not registered in '$ProjectRoot'."
}

function Add-GateStandReleaseFixture {
    param([string]$Worktree, [object]$Fixture)
    $module = Join-Path $Worktree ([string]$Fixture.release.modulePath)
    $bytes = [IO.File]::ReadAllBytes($module)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $encoding = [Text.UTF8Encoding]::new($bom)
    $text = $encoding.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $marker = ([IO.File]::ReadAllText((Join-Path $fixtureRoot $Fixture.release.markerPath), [Text.Encoding]::UTF8)) -replace "`r?`n", $newLine
    [IO.File]::WriteAllText($module, $text.TrimEnd("`r", "`n") + $newLine + $marker, $encoding)
    $feature = Join-Path $Worktree ([string]$Fixture.release.featurePath)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $feature))
    Copy-Item -LiteralPath (Join-Path $fixtureRoot $Fixture.release.featureSourcePath) -Destination $feature -Force
    $oid = (& git -C $Worktree hash-object -- $module).Trim()
    $suites = [ordered]@{ schemaVersion = 1; suites = @([ordered]@{ id = 'itl-release-e2e'; purpose = 'acceptance'; featurePaths = @('tests/features/*.feature'); ownerPaths = @('src/cf/Configuration.xml') }) }
    $yaxunit = [ordered]@{ schemaVersion = 1; notApplicable = @([ordered]@{ path = [string]$Fixture.release.modulePath; sourceOid = $oid
        reason = 'This technical constant marks code loaded into the Release E2E target infobase. tests/features/workflow-release-e2e.feature checks it in a real server session; a unit test of the literal cannot establish that deployment contract.' }) }
    [IO.File]::WriteAllText((Join-Path $Worktree 'tests/verification-suites.branch.json'), (($suites | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8)
    [IO.File]::WriteAllText((Join-Path $Worktree 'tests/yaxunit-suites.branch.json'), (($yaxunit | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8)
    $paths = @([string]$Fixture.release.modulePath, [string]$Fixture.release.featurePath, 'tests/verification-suites.branch.json', 'tests/yaxunit-suites.branch.json')
    & git -C $Worktree add -- $paths
    if ($LASTEXITCODE -ne 0) { throw 'GATE_STAND_RELEASE_FIXTURE_FAILED: unable to stage the Release fixture.' }
    & git -C $Worktree commit -m 'test: add release E2E fixture' -- $paths | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'GATE_STAND_RELEASE_FIXTURE_FAILED: unable to commit the Release fixture.' }
}

function Resolve-GateStandSource {
    param([string]$Requested)
    # Capture admits only a published workflow baseline, so the stand installs
    # origin/develop unless the caller names an equally published checkout.
    if ($Requested) {
        $root = [IO.Path]::GetFullPath($Requested)
        $head = (& git -C $root rev-parse HEAD).Trim()
        & git -C $root merge-base --is-ancestor $head refs/remotes/origin/develop
        $published = $LASTEXITCODE -eq 0
        if (-not $published -or @(& git -C $root status --porcelain --untracked-files=no).Count -gt 0) {
            throw "GATE_STAND_SOURCE_UNPUBLISHED: '$root' at $head is not a clean origin/develop commit; omit -SourceRoot to install origin/develop."
        }
        return [pscustomobject]@{ root = $root; temporary = $false }
    }
    $root = Join-Path ([IO.Path]::GetTempPath()) ('itl-gate-stand-source-' + [guid]::NewGuid().ToString('N'))
    & git -C $repositoryRoot worktree add --quiet --detach $root refs/remotes/origin/develop
    if ($LASTEXITCODE -ne 0) { throw 'GATE_STAND_SOURCE_UNAVAILABLE: unable to check out origin/develop; fetch origin and repeat.' }
    return [pscustomobject]@{ root = $root; temporary = $true }
}

function Write-GateStandReleaseConfig {
    param([string]$ProjectRoot, [Collections.IDictionary]$Config)
    [IO.File]::WriteAllText((Join-Path $ProjectRoot '.agent-1c/release-e2e.json'), (($Config | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8)
}

function Get-GateStandFixtureId {
    param([string]$Repository = $repositoryRoot)
    # The committed fixture tree identifies a stand; one fixture builds one stand.
    $id = (& git -C $Repository rev-parse 'HEAD:tests/fixtures/gate-stand').Trim()
    if ($LASTEXITCODE -ne 0 -or $id -cnotmatch '^[a-f0-9]{40}$') { throw 'GATE_STAND_FIXTURE_UNCOMMITTED: commit tests/fixtures/gate-stand before building a stand.' }
    return $id
}

function Get-GateStandMarkerPath { param([string]$StandRoot) return (Join-Path $StandRoot '.agent-1c/gate-stand.json') }

function Read-GateStandMarker {
    param([string]$StandRoot)
    $path = Get-GateStandMarkerPath -StandRoot $StandRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { $marker = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $null }
    if ([int]$marker.schemaVersion -ne 1 -or [string]$marker.kind -cne 'itl-gate-stand' -or [string]$marker.fixtureId -cnotmatch '^[a-f0-9]{40}$') { return $null }
    return $marker
}

function Write-GateStandMarker {
    param([string]$StandRoot, [string]$PositiveRoot, [string]$FixtureId)
    # Written last: its presence means build and baseline capture completed.
    $marker = [ordered]@{ schemaVersion = 1; kind = 'itl-gate-stand'; fixtureId = $FixtureId; positiveRoot = $PositiveRoot; builtAt = [DateTime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText((Get-GateStandMarkerPath -StandRoot $StandRoot), (($marker | ConvertTo-Json) + [Environment]::NewLine), $utf8)
}

function Resolve-GateStandPlatform {
    param([string]$Requested, [object]$Fixture)
    if ($Requested) { return [IO.Path]::GetFullPath($Requested) }
    if ($env:PLATFORM_PATH) { return $env:PLATFORM_PATH }
    $default = Join-Path $env:ProgramFiles ('1cv8\' + [string]$Fixture.platformVersion + '\bin\1cv8.exe')
    if (Test-Path -LiteralPath $default -PathType Leaf) { return $default }
    throw "GATE_STAND_PLATFORM_REQUIRED: install 1C $($Fixture.platformVersion) or pass -PlatformPath to an 8.3.27+ 1cv8.exe."
}

if (-not $StandRoot) { return }
$StandRoot = [IO.Path]::GetFullPath($StandRoot)
$PositiveRoot = if ($PositiveRoot) { [IO.Path]::GetFullPath($PositiveRoot) } else { $StandRoot + '-positive' }
$fixture = Read-GateStandFixture -Root $fixtureRoot
$fixtureId = Get-GateStandFixtureId
$script:Platform = Resolve-GateStandPlatform -Requested $PlatformPath -Fixture $fixture
foreach ($root in @($StandRoot, $PositiveRoot)) { Assert-GateStandTarget -Path $root }
$script:LogRoot = Join-Path ([IO.Path]::GetTempPath()) ('itl-gate-stand-logs-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:LogRoot)
$script:Steps = New-Object Collections.Generic.List[object]
$source = Resolve-GateStandSource -Requested $SourceRoot
$SourceRoot = $source.root
try {
Initialize-GateStandProject -ProjectRoot $PositiveRoot -Fixture $fixture -Label 'positive'
$positiveDevelop = New-GateStandBranch -ProjectRoot $PositiveRoot -Name 'golden' -Label 'positive'
$positiveRelease = New-GateStandBranch -ProjectRoot $PositiveRoot -Name 'seed' -Label 'positive'
Write-GateStandReleaseConfig -ProjectRoot $PositiveRoot -Config (New-GateStandReleaseConfig -DevelopBranch 'golden' -DevelopWorktree $positiveDevelop -ReleaseBranch 'seed' -ReleaseWorktree $positiveRelease -Rejection $null)

Initialize-GateStandProject -ProjectRoot $StandRoot -Fixture $fixture -Negative -Label 'stand'
$sourcePath = Join-Path $StandRoot ([string]$fixture.negative.sourcePath)
$rejection = [ordered]@{
    sourcePath = [string]$fixture.negative.sourcePath
    sourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    diagnostic = [string]$fixture.negative.diagnostic
    positiveProjectRoot = $PositiveRoot
}
$develop = New-GateStandBranch -ProjectRoot $StandRoot -Name 'workflow-develop-e2e' -Label 'stand'
$release = New-GateStandBranch -ProjectRoot $StandRoot -Name 'workflow-release-e2e' -Label 'stand'
Add-GateStandReleaseFixture -Worktree $release -Fixture $fixture
Write-GateStandReleaseConfig -ProjectRoot $StandRoot -Config (New-GateStandReleaseConfig -DevelopBranch 'workflow-develop-e2e' -DevelopWorktree $develop -ReleaseBranch 'workflow-release-e2e' -ReleaseWorktree $release -Rejection $rejection)
# Publication preparation never creates baselines; the published install is it.
$capture = Join-Path $repositoryRoot 'scripts/source-e2e-fixture.ps1'
foreach ($baseline in @(@('Release', $StandRoot), @('Develop', $StandRoot), @('Develop', $PositiveRoot))) {
    $output = Join-Path $script:LogRoot ("capture-$($baseline[0])-$($script:Steps.Count).json")
    Invoke-GateStandChild -Name "capture-$($baseline[0])-$(Split-Path -Leaf $baseline[1])" -WorkingRoot $baseline[1] -ScriptPath $capture `
        -Arguments @('-Action', 'Capture', '-Phase', $baseline[0], '-ProjectRoot', $baseline[1], '-AgentTarget', $AgentTarget, '-OutputPath', $output) -TimeoutSeconds 900
}
Write-GateStandMarker -StandRoot $StandRoot -PositiveRoot $PositiveRoot -FixtureId $fixtureId
} finally {
    if ($source.temporary) { & git -C $repositoryRoot worktree remove --force $source.root }
}

[ordered]@{ status = 'built'; standRoot = $StandRoot; positiveRoot = $PositiveRoot; logRoot = $script:LogRoot; steps = $script:Steps.ToArray() } | ConvertTo-Json -Depth 5
