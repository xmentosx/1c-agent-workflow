function Get-DevelopPositiveStandRoot {
    param([string]$ProjectRoot, [object]$Config)
    $property = $Config.PSObject.Properties['developConfigurationRejection']
    if (-not $property) { return '' }
    $positiveRoot = [IO.Path]::GetFullPath([string]$property.Value.positiveProjectRoot)
    if ([string]::Equals($positiveRoot, [IO.Path]::GetFullPath($ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'DEVELOP_NEGATIVE_POSITIVE_STAND_REQUIRED: the successful journey needs a separate valid fixture.'
    }
    $positiveConfig = Get-Content -LiteralPath (Join-Path $positiveRoot '.agent-1c/release-e2e.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($positiveConfig.PSObject.Properties['developConfigurationRejection']) {
        throw 'DEVELOP_NEGATIVE_RECURSION_FORBIDDEN: the positive stand must run the complete successful journey.'
    }
    return $positiveRoot
}

function Resolve-SourceE2EArtifactBinding {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath, [switch]$Offline)
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $lock = (Get-Content -LiteralPath (Join-Path $root 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies
    . (Join-Path $root '.agents/skills/1c-workflow/scripts/lib/agent-1c.immutable-download.ps1')
    $clientLock = $lock.vanessaMcp.clientMcp
    $clientPath = [Environment]::GetEnvironmentVariable('VANESSA_MCP_CLIENT_CFE_PATH', 'Process')
    if (-not $clientPath) {
        $clientPath = Join-Path $root ('build/third-party/client-mcp/' + [string]$clientLock.assetName)
        if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $clientPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$clientLock.sha256) {
            if ($Offline) { throw 'SOURCE_E2E_CLIENT_ARTIFACT_MISSING: provide the locked client CFE in the candidate cache or through VANESSA_MCP_CLIENT_CFE_PATH, then repeat the same qualification.' }
            [void](Invoke-ItlImmutableFileDownload -Uri ([string]$clientLock.url) -DestinationPath $clientPath -ExpectedSha256 ([string]$clientLock.sha256) -Label 'Source E2E client MCP CFE')
        }
    }
    $build = & (Join-Path $root 'scripts/Build-ItlOnDemandMcp.ps1') -SkipTests
    $binding = [pscustomobject]@{
        schemaVersion=1; kind='itl-source-e2e-artifact-binding'
        paths=[pscustomobject]@{
            ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE=[IO.Path]::GetFullPath($ArchivePath)
            VANESSA_MCP_CLIENT_CFE_PATH=[IO.Path]::GetFullPath($clientPath)
            ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE=[IO.Path]::GetFullPath([string]$build.path)
        }
    }
    [void](Get-SourceE2EArtifactBindingHashes -RepositoryRoot $root -Binding $binding)
    return $binding
}

function Get-SourceE2EArtifactBindingHashes {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$Binding)
    if ([int]$Binding.schemaVersion -ne 1 -or [string]$Binding.kind -cne 'itl-source-e2e-artifact-binding') { throw 'SOURCE_E2E_ARTIFACT_BINDING_INVALID' }
    $lock = (Get-Content -LiteralPath (Join-Path $RepositoryRoot 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies
    $expected = [ordered]@{
        ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE=[string]$lock.vanessaAutomation.sha256
        VANESSA_MCP_CLIENT_CFE_PATH=[string]$lock.vanessaMcp.clientMcp.sha256
        ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE=[string]$lock.itlOndemandMcp.sha256
    }
    $hashes = [ordered]@{}
    foreach ($name in $expected.Keys) {
        $path = [string]$Binding.paths.$name
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "SOURCE_E2E_ARTIFACT_MISSING: '$name'; repeat the same qualification to prepare its locked artifact." }
        $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sha -cne $expected[$name].ToLowerInvariant()) { throw "SOURCE_E2E_ARTIFACT_HASH_MISMATCH: '$name'; provide the exact locked bytes and repeat the same qualification." }
        $hashes[$name] = $sha
    }
    return $hashes
}

function Enter-SourceE2EClientMcpBuildScope {
    # Derive before a helper rereads its persisted project paths. This transient
    # source is confined to the actual E2E journey, never the Full Pester host.
    $name = 'ITL_VANESSA_MCP_CLIENT_SOURCE_BUILD_CFE'
    $scope = [pscustomobject]@{ previousValue = [Environment]::GetEnvironmentVariable($name, 'Process') }
    [Environment]::SetEnvironmentVariable($name, [Environment]::GetEnvironmentVariable('VANESSA_MCP_CLIENT_CFE_PATH', 'Process'), 'Process')
    return $scope
}

function Exit-SourceE2EClientMcpBuildScope {
    param([AllowNull()][object]$Scope)
    if ($null -ne $Scope) {
        [Environment]::SetEnvironmentVariable('ITL_VANESSA_MCP_CLIENT_SOURCE_BUILD_CFE', $Scope.previousValue, 'Process')
    }
}
Set-StrictMode -Version Latest

# Source qualification chooses a client for each actual installed target. The
# installed helper remains the sole owner of membership/attachment validation.
function Get-SourceE2EConfiguredClients {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $path = Join-Path $ProjectRoot '.agent-1c/project.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $project = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $rules = $project.PSObject.Properties['aiRules']
    if (-not $rules -or -not $rules.Value) { return @() }
    $tools = $rules.Value.PSObject.Properties['tools']
    if (-not $tools) { return @() }
    return @($tools.Value | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Resolve-SourceE2EAgentTarget {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [string]$AgentTarget = '')
    if (-not [string]::IsNullOrWhiteSpace($AgentTarget)) { return $AgentTarget }
    $clients = @(Get-SourceE2EConfiguredClients -ProjectRoot $ProjectRoot)
    if ($clients.Count -eq 1) { return $clients[0] }
    $choices = if ($clients.Count) { $clients -join ', ' } else { '<configured-client>' }
    throw "SOURCE_E2E_AGENT_TARGET_REQUIRED: unattended E2E target '$ProjectRoot' has $($clients.Count) configured clients ($choices). Repeat the same source-delivery.ps1, check.ps1 or invoke-*-e2e.ps1 command with -AgentTarget '<configured-client>' (choose from: $choices). The installed helper validates membership and attachment."
}

function Get-SourceE2ENativeLogsPath {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $logsPath = 'logs/1c'
    $projectPath = Join-Path $root '.agent-1c/project.json'
    if (Test-Path -LiteralPath $projectPath -PathType Leaf) {
        $project = Get-Content -LiteralPath $projectPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $property = $project.PSObject.Properties['logsPath']
        if ($property -and $null -ne $property.Value -and [string]$property.Value -ne '') { $logsPath = [string]$property.Value }
    }
    $path = if ([IO.Path]::IsPathRooted($logsPath)) { $logsPath } else { Join-Path $root $logsPath }
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($path))
}

function Get-SourceE2EReleaseStand {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $configPath = Join-Path ([IO.Path]::GetFullPath($ProjectRoot)) '.agent-1c\release-e2e.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Dedicated E2E stand config is missing: $configPath. Start from templates/release-e2e.example.json."
    }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $devBranchName = [string]$config.devBranchName
    $worktreePath = [IO.Path]::GetFullPath([string]$config.worktreePath)
    if (-not $devBranchName -or -not (Test-Path -LiteralPath $worktreePath -PathType Container)) {
        throw 'release-e2e.json must contain an existing worktreePath and devBranchName.'
    }
    return [pscustomobject]@{ config = $config; worktreePath = $worktreePath; devBranchName = $devBranchName }
}

function Get-SourceE2EClientIdentity {
    param([string]$ProjectRoot = '', [string]$AgentTarget = '')
    $roots = [ordered]@{}
    if ($ProjectRoot) {
        $roots['project'] = [IO.Path]::GetFullPath($ProjectRoot)
        $standPath = Join-Path $ProjectRoot '.agent-1c/release-e2e.json'
        if (Test-Path -LiteralPath $standPath -PathType Leaf) {
            $stand = Get-Content -LiteralPath $standPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($name in @('worktreePath', 'developWorktreePath', 'serverProjectRoot', 'serverWorktreePath')) {
                $property = $stand.PSObject.Properties[$name]
                if ($property -and [string]$property.Value) { $roots[$name] = [IO.Path]::GetFullPath([string]$property.Value) }
            }
            $negative = $stand.PSObject.Properties['developConfigurationRejection']
            if ($negative) {
                $positiveRoot = Get-DevelopPositiveStandRoot -ProjectRoot $ProjectRoot -Config $stand
                $positive = Get-Content -LiteralPath (Join-Path $positiveRoot '.agent-1c/release-e2e.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $roots['positiveProject'] = $positiveRoot
                $roots['positiveDevelop'] = [IO.Path]::GetFullPath([string]$positive.developWorktreePath)
            }
        }
    }
    $targets = @(foreach ($name in $roots.Keys) {
        [ordered]@{ role=$name; root=$roots[$name].ToLowerInvariant(); configuredClients=@(Get-SourceE2EConfiguredClients -ProjectRoot $roots[$name]) }
    })
    # ConvertTo-Json decorates strings in Windows PowerShell 5.1; the cache owner needs a scalar, not its Length property.
    return [string]([ordered]@{ requestedAgentTarget=$AgentTarget; freshAgentTarget='kilocode'; targets=$targets } | ConvertTo-Json -Depth 6 -Compress)
}

function Get-DeliveryPlanSemanticDotEnvNames {
    return @(
        'PLATFORM_PATH','PLATFORM_ARGS','IBCMD_ARGS','ONEC_MAX_CONCURRENT_SESSIONS',
        'INFOBASE_KIND','SOURCE_USES_REPOSITORY','SOURCE_REPOSITORY_UPDATE_MODE',
        'SOURCE_INFOBASE_PATH','SOURCE_SERVER_NAME','SOURCE_INFOBASE_NAME',
        'SOURCE_EVENT_LOG_BASELINE_ENABLED','SOURCE_SERVER_EVENT_LOG_LOOKBACK_DAYS',
        'SOURCE_EVENT_LOG_BOOTSTRAP_TAIL_BYTES','BASE_CONFIGURATION_VERSION',
        'IB_USER','IB_PASSWORD','REPOSITORY_PATH','REPOSITORY_USER','REPOSITORY_PASSWORD',
        'DEPENDENCY_MODE','SUPPORT_GUARD','ITL_YAXUNIT_TESTING','ITL_VANESSA_TESTING',
        'ITL_CHECK_EVENT_LOG','ITL_VERIFICATION_REPAIR_MAX_ATTEMPTS','VERIFICATION_POLICY',
        'ITL_PORT_REGISTRY_SCOPE','ITL_PORT_REGISTRY_HOME','DEV_BRANCH_INFOBASE_ROOT',
        'BRANCH_SEED_ROOT','DEV_BRANCH_WORKTREE_ROOT','DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP',
        'WEB_PUBLISH_BY_DEFAULT','WEB_PUBLISH_AUTO','WEBINST_PATH','APACHE_KIND',
        'APACHE_HTTPD_CONF_PATH','WEB_PUBLICATION_ROOT','WEB_PUBLICATION_URL_BASE',
        'VANESSA_AUTOMATION_ROOT','VANESSA_FEATURES_PATH','VANESSA_REPORTS_PATH',
        'VANESSA_TESTCLIENT_MANIFEST','YAXUNIT_INSTALL_ROOT','YAXUNIT_TESTS_PATH',
        'YAXUNIT_REPORTS_PATH','YAXUNIT_TESTS_EXTENSION_NAME','YAXUNIT_TEST_TIMEOUT_SECONDS',
        'VANESSA_TEST_PORT_RANGE','VANESSA_TEST_FOREIGN_WAIT_MODE',
        'VANESSA_TEST_FOREIGN_QUIET_SECONDS','VANESSA_TEST_FOREIGN_WAIT_TIMEOUT_SECONDS',
        'VANESSA_TEST_TIMEOUT_SECONDS','VANESSA_TEST_CLIENT_STARTUP_TIMEOUT_SECONDS',
        'VANESSA_TEST_WINDOW_SEARCH_TIMEOUT_SECONDS','VANESSA_EVENT_LOG_LEVELS',
        'VANESSA_EVENT_LOG_CLOCK_SKEW_SECONDS','VANESSA_EVENT_LOG_READER',
        'VANESSA_MCP_AUTO_START','VANESSA_MCP_INSTALL_ROOT','VANESSA_MCP_PORT_RANGE',
        'VANESSA_MCP_TESTCLIENT_PORT_RANGE','ROCTUP_MCP_ENABLED','ROCTUP_MCP_AUTO_START',
        'ROCTUP_MCP_REQUIRED','ROCTUP_MCP_INSTALL_ROOT','ROCTUP_MCP_PORT_RANGE',
        'VIBECODING1C_MCP_DISTRIBUTION_REPO','VIBECODING1C_MCP_REGISTRY_REPO','USE_GPU'
    )
}

function Get-DeliveryStableDotEnvSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    # This is a positive semantic contract. Helper-owned outputs and future
    # diagnostic keys do not become plan inputs merely because they were added
    # to .dev.env. Values are persisted only through this aggregate SHA.
    $semanticNames = @(Get-DeliveryPlanSemanticDotEnvNames)
    $semanticSet = @{}
    foreach ($name in $semanticNames) { $semanticSet[$name] = $true }
    $values = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $trimmed = ([string]$line).Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { continue }
        $name = $trimmed.Substring(0, $separator).Trim()
        if (-not $semanticSet.ContainsKey($name)) { continue }
        $value = $trimmed.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name] = $value
    }
    $canonical = foreach ($name in $semanticNames) {
        if ($values.Contains($name)) { "$name=$([string]$values[$name])" } else { "$name=<missing>" }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($canonical -join "`n") + "`n")))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

