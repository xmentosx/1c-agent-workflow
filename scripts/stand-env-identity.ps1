Set-StrictMode -Version Latest

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

