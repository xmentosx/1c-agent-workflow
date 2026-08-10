Describe "1C workflow standalone host tooling checks" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $HelperModulePaths = $context.HelperModulePaths
        $LauncherPath = $context.LauncherPath
        $InstallerPath = $context.InstallerPath
        $McpHostPath = $context.McpHostPath
        $McpHostDumpPath = $context.McpHostDumpPath
        $HelperText = $context.HelperText
        $LauncherText = $context.LauncherText
        $McpHostText = $context.McpHostText
    }
    It "parses the standalone MCP host installer" {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($McpHostPath, [ref]$tokens, [ref]$errors) | Out-Null

        @($errors).Count | Should -Be 0
    }

    It "parses the standalone MCP host config dump helper" {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($McpHostDumpPath, [ref]$tokens, [ref]$errors) | Out-Null

        @($errors).Count | Should -Be 0
    }

    It "selects a real Python 3 executable when PATH also exposes the Windows Store alias" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-python-resolution-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $realPythonPath = Join-Path $tempRoot "python.exe"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            New-Item -ItemType File -Force -Path $realPythonPath | Out-Null
            $config = [ordered]@{ schemaVersion = 1; stateRoot = (Join-Path $tempRoot "state"); pythonPath = "python" }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:ProbedPythonPaths = @()
                function Get-Command {
                    param($Name, $CommandType, [switch]$All, $ErrorAction)
                    return @(
                        [pscustomobject]@{ Source = "C:\Users\fixture\AppData\Local\Microsoft\WindowsApps\python.exe" },
                        [pscustomobject]@{ Source = $realPythonPath }
                    )
                }
                function Invoke-ProcessCapture {
                    param([string]$FilePath, [string[]]$Arguments)
                    $script:ProbedPythonPaths += $FilePath
                    return [pscustomobject]@{ exitCode = 0; lines = @("Python 3.12.4") }
                }

                $resolved = Resolve-PythonExecutable -Config ([pscustomobject]@{ pythonPath = "python" })

                $resolved | Should -Be $realPythonPath
                @($script:ProbedPythonPaths) | Should -Be @($realPythonPath)
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "preserves MCP tool contracts while compacting only descriptions" {
        $testPath = Join-Path $RepoRoot "tests\node\tools-list-proxy.test.js"
        $output = & node $testPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "unit contract passed"
        $contract = Get-Content -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\tools-list-proxy\tools-contract.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $maximumLength = [int]$contract.descriptionPolicy.maximumApprovedDescriptionCharacters
        $remember = [string]$contract.servers.templates.toolDescriptions.remember.compact
        $recall = [string]$contract.servers.templates.toolDescriptions.recall.compact

        $remember | Should -Match 'shared cross-project memory'
        $remember | Should -Match 'Never use it for project-specific facts'
        $recall | Should -Match 'shared cross-project memory'
        $recall | Should -Match 'verify results against the current project'
        $remember.Length | Should -BeLessOrEqual $maximumLength
        $recall.Length | Should -BeLessOrEqual $maximumLength
    }

    It "bounds BookStack MCP responses and keeps explicit continuation" {
        $testPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\bookstack-product-docs-mcp\test_server.py"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & python $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "Ran 15 tests"
    }

    It "keeps the Mantis MCP transport stateless" {
        $testPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\mantis-ticket-mcp\test_server.py"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & python $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "Ran 8 tests"
    }

    It "falls back to the direct endpoint when the qualified proxy is unavailable" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-tools-proxy-state-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{ schemaVersion = 1; stateRoot = (Join-Path $tempRoot "state"); toolsListProxy = [ordered]@{ enabled = $true; serverIds = @("code"); portOffset = 4000 } }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                (Test-ToolsListProxyTarget -Config $hostConfig -ServerId "code") | Should -BeTrue
                (Test-ToolsListProxyTarget -Config $hostConfig -ServerId "graph") | Should -BeFalse
                function Get-HostContainerPublishState { param([string]$ContainerName); return "running" }
                function Test-HostTcpPortOpen { param([int]$Port, [int]$TimeoutMilliseconds = 500); return ($script:ProxyReady -and $Port -eq 22100) }
                function Test-ToolsListProxyReady { param([int]$Port, [int]$TimeoutSec = 35); return ($script:ProxyReady -and $Port -eq 22100) }
                $server = [ordered]@{
                    id = "code"; url = "http://host:22100/mcp"; directUrl = "http://host:18100/mcp"; proxyUrl = "http://host:22100/mcp"
                    proxyPort = 22100; proxyContainerName = "itl-code-tools-list-proxy"; toolsContractStatus = "qualified"
                }
                $script:ProxyReady = $true
                $qualified = Update-ToolsListProxyPublishEndpoint -Server $server
                $qualified.url | Should -Be "http://host:22100/mcp"
                $qualified.toolsContractStatus | Should -Be "qualified"
                $script:ProxyReady = $false
                $fallback = Update-ToolsListProxyPublishEndpoint -Server $server
                $fallback.url | Should -Be "http://host:18100/mcp"
                $fallback.toolsContractStatus | Should -Be "fallback-direct"
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "qualifies proxy readiness from the MCP-aware endpoint" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-tools-proxy-readiness-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{ schemaVersion = 1; stateRoot = (Join-Path $tempRoot "state") }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                function Invoke-RestMethod {
                    param($Uri, $Method, $TimeoutSec, $ErrorAction)
                    if ($script:ReadinessResult -eq "throw") { throw "fixture upstream failure" }
                    return [pscustomobject]@{ status = $script:ReadinessResult }
                }

                $script:ReadinessResult = "ready"
                (Test-ToolsListProxyReady -Port 22005) | Should -BeTrue
                $script:ReadinessResult = "unready"
                (Test-ToolsListProxyReady -Port 22005) | Should -BeFalse
                $script:ReadinessResult = "throw"
                (Test-ToolsListProxyReady -Port 22005) | Should -BeFalse
                (Test-ToolsListProxyReady -Port 0) | Should -BeFalse

                $script:ReadinessAttempts = 0
                function Test-HostTcpPortOpen { param([int]$Port, [int]$TimeoutMilliseconds = 500); return $true }
                function Test-ToolsListProxyReady {
                    param([int]$Port, [int]$TimeoutSec = 35)
                    $script:ReadinessAttempts++
                    return ($script:ReadinessAttempts -ge 3)
                }
                function Start-Sleep { param([int]$Seconds) }
                (Wait-ToolsListProxyReady -Port 22005 -Attempts 4 -DelaySeconds 0 -ProbeTimeoutSec 1) | Should -BeTrue
                $script:ReadinessAttempts | Should -Be 3
                Remove-Variable -Scope Script -Name ReadinessResult -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name ReadinessAttempts -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "plans tracked proxy activation without setup, refresh, or indexing" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-tools-proxy-action-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $stateRoot = Join-Path $tempRoot "state"
        $statePath = Join-Path $stateRoot "host-state.json"
        try {
            New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "fixture-host"
                baseUrl = "http://fixture-host"
                stateRoot = $stateRoot
                toolsListProxy = [ordered]@{ enabled = $true; serverIds = @("code"); portOffset = 4000 }
            }
            $state = [ordered]@{
                schemaVersion = 1
                updatedAt = "2026-07-20T00:00:00Z"
                configurations = @()
                servers = @([ordered]@{
                    id = "code"; scope = "project"; configId = "trade"; name = "itl-code-trade"
                    containerName = "itl-code-trade"; hostPort = 18100; url = "http://fixture-host:18100/mcp"
                    status = "running"; health = "running"
                })
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            Set-Content -LiteralPath $statePath -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            $beforeHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $McpHostPath -Action proxy -ConfigPath $configPath -DryRun 2>&1

            $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
            ($output -join [Environment]::NewLine) | Should -Match "no server setup or indexing would run"
            ($output -join [Environment]::NewLine) | Should -Not -Match "Refreshing configurations|Reindexing database-backed|Starting global MCP servers"
            (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash | Should -Be $beforeHash
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "plans tracked reconcile without mutating state or restarting in dry-run" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-tools-reconcile-action-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $stateRoot = Join-Path $tempRoot "state"
        $statePath = Join-Path $stateRoot "host-state.json"
        try {
            New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "fixture-host"
                baseUrl = "http://fixture-host"
                stateRoot = $stateRoot
                toolsListProxy = [ordered]@{ enabled = $true; serverIds = @("code"); portOffset = 4000 }
            }
            $state = [ordered]@{
                schemaVersion = 1
                updatedAt = "2026-07-20T00:00:00Z"
                configurations = @()
                servers = @([ordered]@{
                    id = "code"; scope = "project"; configId = "trade"; name = "itl-code-trade"
                    containerName = "itl-code-trade"; hostPort = 18100; url = "http://fixture-host:18100/mcp"
                    status = "running"; health = "running"
                })
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            Set-Content -LiteralPath $statePath -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            $beforeHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $McpHostPath -Action reconcile -ConfigPath $configPath -DryRun 2>&1

            $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
            ($output -join [Environment]::NewLine) | Should -Match "Would reconcile tracked MCP runtime 'code'"
            ($output -join [Environment]::NewLine) | Should -Not -Match "docker start|docker restart|Refreshing configurations|Reindexing"
            (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash | Should -Be $beforeHash
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "plans the managed watchdog task without requiring an administrator-written script" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-watchdog-action-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                stateRoot = (Join-Path $tempRoot "state")
                watchdog = [ordered]@{
                    enabled = $true
                    intervalMinutes = 7
                    startupDelaySeconds = 45
                    taskName = "ITL fixture watchdog"
                    dockerDesktopRecovery = [ordered]@{
                        enabled = $true
                        timeoutSeconds = 90
                        commandTimeoutSeconds = 60
                        pollSeconds = 3
                    }
                }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $McpHostPath -Action watchdog-install -ConfigPath $configPath -DryRun 2>&1

            $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
            ($output -join [Environment]::NewLine) | Should -Match "Would install scheduled task 'ITL fixture watchdog'"
            ($output -join [Environment]::NewLine) | Should -Match "every 7 minute"
            ($output -join [Environment]::NewLine) | Should -Match "45-second initial delay"
            ($output -join [Environment]::NewLine) | Should -Match ([regex]::Escape("-Action watchdog-run"))
            ($output -join [Environment]::NewLine) | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($configPath)))
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "rejects invalid watchdog settings and refuses an unmanaged task collision" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-watchdog-guard-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                stateRoot = (Join-Path $tempRoot "state")
                watchdog = [ordered]@{ enabled = $true; intervalMinutes = 5; startupDelaySeconds = 30; taskName = "ITL fixture watchdog" }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                { Get-McpHostWatchdogSettings -Config ([pscustomobject]@{ watchdog = [pscustomobject]@{ enabled = $true; intervalMinutes = 0 } }) } | Should -Throw "*between 1 and 1440*"
                { Get-McpHostWatchdogSettings -Config ([pscustomobject]@{ watchdog = [pscustomobject]@{ enabled = $true; dockerDesktopRecovery = [pscustomobject]@{ timeoutSeconds = 10 } } }) } | Should -Throw "*between 30 and 900*"
                { Assert-McpHostWatchdogTaskOwned -Task ([pscustomobject]@{ Description = "another owner" }) -TaskName "ITL fixture watchdog" } | Should -Throw "*is not managed by this installer*"
                { Assert-McpHostWatchdogTaskOwned -Task ([pscustomobject]@{ Description = $script:WatchdogDescription }) -TaskName "ITL fixture watchdog" } | Should -Not -Throw
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "plans a managed nightly incremental index task and validates its settings" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-nightly-index-action-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                stateRoot = (Join-Path $tempRoot "state")
                nightlyIndex = [ordered]@{
                    enabled = $true
                    at = "02:15"
                    taskName = "ITL fixture nightly index"
                    timeoutMinutes = 360
                    pollSeconds = 20
                    configIds = @("pm5corp", "pm4corp")
                }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $McpHostPath -Action nightly-index-install -ConfigPath $configPath -DryRun 2>&1

            $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
            ($output -join [Environment]::NewLine) | Should -Match "Would install scheduled task 'ITL fixture nightly index'"
            ($output -join [Environment]::NewLine) | Should -Match "daily at 02:15"
            ($output -join [Environment]::NewLine) | Should -Match ([regex]::Escape("-Action nightly-index-run"))
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $settings = Get-McpHostNightlyIndexSettings -Config (Read-JsonFile -Path $configPath)
                $settings.hour | Should -Be 2
                $settings.minute | Should -Be 15
                @($settings.configIds) | Should -Be @("pm5corp", "pm4corp")
                { Get-McpHostNightlyIndexSettings -Config ([pscustomobject]@{ nightlyIndex = [pscustomobject]@{ at = "25:00" } }) } | Should -Throw "*HH:mm*"
                { Get-McpHostNightlyIndexSettings -Config ([pscustomobject]@{ nightlyIndex = [pscustomobject]@{ pollSeconds = 1 } }) } | Should -Throw "*between 5 and 300*"
                { Assert-McpHostNightlyIndexTaskOwned -Task ([pscustomobject]@{ Description = "another owner" }) -TaskName "ITL fixture nightly index" } | Should -Throw "*is not managed by this installer*"
                { Assert-McpHostNightlyIndexTaskOwned -Task ([pscustomobject]@{ Description = $script:NightlyIndexDescription }) -TaskName "ITL fixture nightly index" } | Should -Not -Throw
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "classifies code and graph index status without treating an idle server as busy" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-nightly-index-status-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1}'
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                (Get-HostMcpIndexState -Text '{"server_status":"running","is_indexing":false,"last_indexed_at":"2026-08-06T00:00:00Z"}') | Should -Be "succeeded"
                (Get-HostMcpIndexState -Text '{"pending":2,"running":1,"completed":8,"failed":0}') | Should -Be "running"
                (Get-HostMcpIndexState -Text '{"pending":0,"running":0,"completed":11,"failed":0}') | Should -Be "succeeded"
                (Get-HostMcpIndexState -Text '{"status":"failed","message":"fixture"}') | Should -Be "failed"
                (Get-HostMcpIndexState -Text 'unrecognized payload') | Should -Be "unknown"
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "keeps the watchdog out of active and waiting nightly maintenance windows" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-nightly-index-lock-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                stateRoot = (Join-Path $tempRoot "state")
                watchdog = [ordered]@{ enabled = $true; taskName = "ITL fixture watchdog" }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $lease = Enter-McpHostMaintenanceLock -Config $hostConfig -Operation "nightly-index"
                try {
                    $script:WatchdogCoreInvoked = $false
                    function Invoke-McpHostWatchdogRunCore { param([object]$Config); $script:WatchdogCoreInvoked = $true }

                    Invoke-McpHostWatchdogRun -Config $hostConfig *> $null

                    $script:WatchdogCoreInvoked | Should -BeFalse
                    $runState = Read-JsonFile -Path (Get-McpHostWatchdogStatePath -Config $hostConfig)
                    $runState.status | Should -Be "skipped"
                    $runState.message | Should -Match "maintenance is already active"
                    Remove-Variable -Scope Script -Name WatchdogCoreInvoked -ErrorAction SilentlyContinue
                } finally {
                    Exit-McpHostMaintenanceLock -Lease $lease
                }

                $priorityLease = Enter-McpHostNightlyPriorityLock -Config $hostConfig
                try {
                    $priorityLease.acquired | Should -BeTrue
                    $script:WatchdogCoreInvoked = $false
                    function Invoke-McpHostWatchdogRunCore { param([object]$Config); $script:WatchdogCoreInvoked = $true }

                    Invoke-McpHostWatchdogRun -Config $hostConfig *> $null

                    $script:WatchdogCoreInvoked | Should -BeFalse
                    $runState = Read-JsonFile -Path (Get-McpHostWatchdogStatePath -Config $hostConfig)
                    $runState.status | Should -Be "skipped"
                    $runState.message | Should -Match "Nightly indexing is pending or active"
                } finally {
                    Exit-McpHostNightlyPriorityLock -Lease $priorityLease
                }

                Test-McpHostNightlyPriorityLockActive -Config $hostConfig | Should -BeFalse
                Invoke-McpHostWatchdogRun -Config $hostConfig *> $null
                $script:WatchdogCoreInvoked | Should -BeTrue
                Remove-Variable -Scope Script -Name WatchdogCoreInvoked -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "excludes the 1C dump cursor from the nightly content fingerprint" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-nightly-index-fingerprint-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1}'
            Set-Content -LiteralPath (Join-Path $tempRoot "Configuration.xml") -Encoding UTF8 -Value "configuration"
            Set-Content -LiteralPath (Join-Path $tempRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor-1"
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $contentBefore = Get-DirectoryFingerprint -Path $tempRoot -ExcludeRelativePaths @("ConfigDumpInfo.xml", "host.config.json")
                $rawBefore = Get-DirectoryFingerprint -Path $tempRoot -ExcludeRelativePaths @("host.config.json")
                Set-Content -LiteralPath (Join-Path $tempRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor-2"

                (Get-DirectoryFingerprint -Path $tempRoot -ExcludeRelativePaths @("ConfigDumpInfo.xml", "host.config.json")) | Should -Be $contentBefore
                (Get-DirectoryFingerprint -Path $tempRoot -ExcludeRelativePaths @("host.config.json")) | Should -Not -Be $rawBefore
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "recovers an unavailable Docker Desktop daemon with one bounded restart" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-watchdog-docker-recovery-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1,"stateRoot":"fixture"}'
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:DesktopRecoveryCalls = New-Object System.Collections.Generic.List[string]
                function Get-DockerDaemonProbe { param([int]$TimeoutSec = 20); return [pscustomobject]@{ available = $false; failureKind = "daemon-unavailable"; message = "fixture unavailable" } }
                function Get-DockerDesktopRuntimeStatus { return "running" }
                function Wait-DockerDaemonAvailable { param([int]$TimeoutSec, [int]$PollSeconds); return $true }
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec, [string]$Description)
                    $script:DesktopRecoveryCalls.Add(($Arguments -join " "))
                }
                $settings = [pscustomobject]@{
                    dockerDesktopRecoveryEnabled = $true
                    dockerDesktopRecoveryTimeoutSeconds = 90
                    dockerDesktopCommandTimeoutSeconds = 60
                    dockerDesktopPollSeconds = 3
                }

                (Repair-DockerDesktopAvailability -Settings $settings) | Should -Be "restart"
                @($script:DesktopRecoveryCalls) | Should -Be @("desktop restart --timeout 60")
                Remove-Variable -Scope Script -Name DesktopRecoveryCalls -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "does not restart a reported-running Docker Desktop after a probe timeout" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-watchdog-docker-probe-timeout-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1,"stateRoot":"fixture"}'
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:ProbeTimeoutCalls = 0
                $script:ProbeTimeoutDockerCalls = 0
                function Get-DockerDaemonProbe {
                    param([int]$TimeoutSec = 20)
                    $script:ProbeTimeoutCalls++
                    return [pscustomobject]@{ available = $false; failureKind = "probe-timeout"; message = "fixture plugin timeout" }
                }
                function Get-DockerDesktopRuntimeStatus { return "running" }
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec, [string]$Description)
                    $script:ProbeTimeoutDockerCalls++
                }
                $settings = [pscustomobject]@{
                    dockerDesktopRecoveryEnabled = $true
                    dockerDesktopRecoveryTimeoutSeconds = 90
                    dockerDesktopCommandTimeoutSeconds = 60
                    dockerDesktopPollSeconds = 3
                }

                { Repair-DockerDesktopAvailability -Settings $settings } | Should -Throw "*refusing to restart*"
                $script:ProbeTimeoutCalls | Should -Be 2
                $script:ProbeTimeoutDockerCalls | Should -Be 0
                Remove-Variable -Scope Script -Name ProbeTimeoutCalls,ProbeTimeoutDockerCalls -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "terminates the complete child process tree after a native command timeout" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-host-process-tree-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $fixturePath = Join-Path $tempRoot "spawn-child.ps1"
        $childPidPath = Join-Path $tempRoot "child.pid"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1,"stateRoot":"fixture"}'
            Set-Content -LiteralPath $fixturePath -Encoding UTF8 -Value @'
param([string]$ChildPidPath)
$child = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 120") -PassThru
[IO.File]::WriteAllText($ChildPidPath, [string]$child.Id)
Start-Sleep -Seconds 120
'@
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                { Invoke-ProcessWithTimeout -FilePath "powershell.exe" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $fixturePath, $childPidPath) -TimeoutSec 3 -Description "fixture process tree" } | Should -Throw "*timed out*"
            }
            (Test-Path -LiteralPath $childPidPath -PathType Leaf) | Should -BeTrue
            $childPid = [int](Get-Content -LiteralPath $childPidPath -Raw)
            for ($attempt = 0; $attempt -lt 30 -and (Get-Process -Id $childPid -ErrorAction SilentlyContinue); $attempt++) {
                Start-Sleep -Milliseconds 100
            }
            (Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "normalizes malformed Graph compose memory keys and validates before down" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-graph-compose-preflight-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $distributionRoot = Join-Path $tempRoot "distribution"
        $workRoot = Join-Path $tempRoot "work"
        try {
            New-Item -ItemType Directory -Force -Path $distributionRoot, $workRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1,"stateRoot":"fixture"}'
            Set-Content -LiteralPath (Join-Path $distributionRoot "graph.yml") -Encoding UTF8 -Value @'
services:
  mcp-app:
    deploy:
      resources:
        limits:
          memory:4G
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8006/search"]
'@
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $script:GraphComposeCalls = New-Object System.Collections.Generic.List[string]
                function Get-DistributionRoot { param([object]$Config); return $distributionRoot }
                function Get-ConfigWorkRoot { param([object]$Config, [string]$ConfigId); return $workRoot }
                function Resolve-ServerEnv {
                    param([object]$Config, [object]$Server, [object]$ConfigState, [switch]$ForceResetDatabase)
                    return [ordered]@{ RESET_DATABASE = "true" }
                }
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec, [string]$Description)
                    $script:GraphComposeCalls.Add(($Arguments -join " "))
                    if ($Arguments -contains "config") { throw "fixture compose validation failed" }
                }
                $server = [pscustomobject]@{ id = "graph"; composePath = "graph.yml" }
                $runtime = [pscustomobject]@{
                    name = "itl-fixture-graph"; composeProject = "itl-fixture-graph"; containerName = "itl-fixture-graph"
                    url = "http://localhost:18101/mcp"; hostPort = 18101; internalPort = 8006
                }
                $configState = [pscustomobject]@{ configId = "fixture" }

                { Start-ComposeServer -Config $hostConfig -Server $server -Runtime $runtime -ConfigState $configState -Recreate -ForceResetDatabase } | Should -Throw "*fixture compose validation failed*"
                @($script:GraphComposeCalls).Count | Should -Be 1
                $script:GraphComposeCalls[0] | Should -Match "compose .* config --quiet$"
                $script:GraphComposeCalls[0] | Should -Not -Match "\sdown\s|\sup\s"
                $runtimeCompose = Join-Path (Join-Path $workRoot "runtime") "itl-fixture-graph\docker-compose.yml"
                $composeText = Get-Content -Raw -LiteralPath $runtimeCompose
                $composeText | Should -Match '(?m)^\s+memory: 4G$'
                $composeText | Should -Not -Match '(?m)^\s+memory:4G$'
                Remove-Variable -Scope Script -Name GraphComposeCalls -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "repairs tracked graph healthchecks without restart or indexing" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-watchdog-graph-health-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $stateRoot = Join-Path $tempRoot "state"
        $runtimePath = Join-Path $tempRoot "runtime"
        try {
            New-Item -ItemType Directory -Force -Path $stateRoot, $runtimePath | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($([ordered]@{
                schemaVersion = 1; stateRoot = $stateRoot
            }) | ConvertTo-Json) + [Environment]::NewLine)
            Set-Content -LiteralPath (Join-Path $runtimePath "docker-compose.yml") -Encoding UTF8 -Value @'
services:
  mcp-app:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8006/search"]
'@
            Set-Content -LiteralPath (Join-Path $stateRoot "host-state.json") -Encoding UTF8 -Value (($([ordered]@{
                schemaVersion = 1
                configurations = @()
                servers = @([ordered]@{
                    id = "graph"
                    containerName = "itl-graph"
                    runtimePath = $runtimePath
                })
            }) | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $script:GraphHealthDockerCalls = New-Object System.Collections.Generic.List[string]
                $script:GraphHealthShimInstalled = $false
                function Get-HostContainerPublishState { param([string]$ContainerName); return "running" }
                function Invoke-DockerCommandCapture {
                    param([string[]]$Arguments, [int]$TimeoutSec, [string]$Description)
                    $script:GraphHealthDockerCalls.Add(($Arguments -join " "))
                    if ($script:GraphHealthShimInstalled) {
                        return @("ITL_GRAPH_HEALTH_OK")
                    }
                    return @('OCI runtime exec failed: exec: "curl": executable file not found in $PATH')
                }
                function Invoke-DockerCommand {
                    param([string[]]$Arguments, [switch]$Quiet, [int]$TimeoutSec)
                    $script:GraphHealthDockerCalls.Add(($Arguments -join " "))
                    return 1
                }
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec, [string]$Description)
                    $script:GraphHealthDockerCalls.Add(($Arguments -join " "))
                    if ($Arguments[0] -eq "cp") {
                        $script:GraphHealthShimInstalled = $true
                    }
                }

                (Repair-TrackedGraphHealthchecks -Config $hostConfig) | Should -Be 2
                $composeText = Get-Content -LiteralPath (Join-Path $runtimePath "docker-compose.yml") -Raw
                $composeText | Should -Match "python -c"
                $composeText | Should -Not -Match '\["CMD", "curl"'
                $callText = @($script:GraphHealthDockerCalls) -join "|"
                $callText | Should -Match "cp .*itl-graph:/usr/local/bin/curl"
                $callText | Should -Match "exec itl-graph chmod 0755 /usr/local/bin/curl"
                $callText | Should -Match "exec itl-graph curl -f http://localhost:8006/search"
                $callText | Should -Not -Match "restart|reindex|setup"
                Remove-Variable -Scope Script -Name GraphHealthDockerCalls -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name GraphHealthShimInstalled -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "records watchdog success, failure, and disabled runs" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-watchdog-state-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                stateRoot = (Join-Path $tempRoot "state")
                watchdog = [ordered]@{ enabled = $true; intervalMinutes = 5; startupDelaySeconds = 30; taskName = "ITL fixture watchdog" }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                function Repair-DockerDesktopAvailability { param([object]$Settings); return "already-available" }
                function Repair-TrackedGraphHealthchecks { param([object]$Config); return 0 }
                function Repair-TrackedMcpHostAndPublish { param([object]$Config); if ($script:WatchdogFailure) { throw "fixture failure" } }

                $script:WatchdogFailure = $false
                Invoke-McpHostWatchdogRun -Config $hostConfig *> $null
                $state = Read-JsonFile -Path (Get-McpHostWatchdogStatePath -Config $hostConfig)
                $state.status | Should -Be "succeeded"

                $script:WatchdogFailure = $true
                { Invoke-McpHostWatchdogRun -Config $hostConfig *> $null } | Should -Throw "*fixture failure*"
                $state = Read-JsonFile -Path (Get-McpHostWatchdogStatePath -Config $hostConfig)
                $state.status | Should -Be "failed"
                $state.message | Should -Be "fixture failure"

                $hostConfig.watchdog.enabled = $false
                Invoke-McpHostWatchdogRun -Config $hostConfig *> $null
                $state = Read-JsonFile -Path (Get-McpHostWatchdogStatePath -Config $hostConfig)
                $state.status | Should -Be "disabled"
                Remove-Variable -Scope Script -Name WatchdogFailure -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "recovers one mid-run daemon loss without retrying an ordinary container failure" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-watchdog-mid-run-recovery-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{ schemaVersion = 1; stateRoot = (Join-Path $tempRoot "state"); watchdog = [ordered]@{ enabled = $true } }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                function Repair-DockerDesktopAvailability {
                    param([object]$Settings)
                    $script:WatchdogRecoveryCalls++
                    if ($script:WatchdogScenario -eq "recovery-fails" -and $script:WatchdogRecoveryCalls -gt 1) { throw "Docker Desktop restart did not restore docker info within 120 seconds." }
                    return $(if ($script:WatchdogRecoveryCalls -eq 1) { "already-available" } else { "restart" })
                }
                function Test-DockerDaemonAvailable { param([int]$TimeoutSec); return ($script:WatchdogScenario -eq "container-fails") }
                function Repair-TrackedGraphHealthchecks { param([object]$Config); return 0 }
                function Repair-TrackedMcpHostAndPublish {
                    param([object]$Config)
                    $script:WatchdogReconcileCalls++
                    if ($script:WatchdogScenario -eq "container-fails") { throw "Direct MCP runtime 'docs' did not open tracked port 18000 after restart." }
                    if ($script:WatchdogReconcileCalls -eq 1) { throw "docker start itl-1c-docs failed: failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine" }
                }
                function Set-TrackedHostRuntimeStatus { param([object]$Config, [string]$Status) }
                function Publish-Registry { param([object]$Config, [switch]$SkipUnchangedHost, [switch]$SkipRuntimeRefresh); $script:WatchdogUnavailablePublished = [bool]$SkipRuntimeRefresh }

                $script:WatchdogScenario = "recovers"; $script:WatchdogRecoveryCalls = 0; $script:WatchdogReconcileCalls = 0
                Invoke-McpHostWatchdogRun -Config $hostConfig *> $null
                $script:WatchdogRecoveryCalls | Should -Be 2; $script:WatchdogReconcileCalls | Should -Be 2
                $state = Read-JsonFile -Path (Get-McpHostWatchdogStatePath -Config $hostConfig)
                $state.status | Should -Be "succeeded"; $state.message | Should -Match "already-available -> restart"

                $script:WatchdogScenario = "recovery-fails"; $script:WatchdogRecoveryCalls = 0; $script:WatchdogReconcileCalls = 0; $script:WatchdogUnavailablePublished = $false
                { Invoke-McpHostWatchdogRun -Config $hostConfig *> $null } | Should -Throw "*did not restore docker info*"
                $script:WatchdogRecoveryCalls | Should -Be 2; $script:WatchdogUnavailablePublished | Should -BeTrue
                $state = Read-JsonFile -Path (Get-McpHostWatchdogStatePath -Config $hostConfig)
                $state.status | Should -Be "failed"; $state.message | Should -Match "did not restore docker info"

                $script:WatchdogScenario = "container-fails"; $script:WatchdogRecoveryCalls = 0; $script:WatchdogReconcileCalls = 0
                { Invoke-McpHostWatchdogRun -Config $hostConfig *> $null } | Should -Throw "*did not open tracked port*"
                $script:WatchdogRecoveryCalls | Should -Be 1; $script:WatchdogReconcileCalls | Should -Be 1
                (Read-JsonFile -Path (Get-McpHostWatchdogStatePath -Config $hostConfig)).status | Should -Be "failed"
                Remove-Variable -Scope Script -Name WatchdogScenario,WatchdogRecoveryCalls,WatchdogReconcileCalls,WatchdogUnavailablePublished -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "publishes unavailable host state without runtime refresh when Docker recovery fails" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-watchdog-docker-failure-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                stateRoot = (Join-Path $tempRoot "state")
                watchdog = [ordered]@{ enabled = $true }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $script:UnavailableStatus = ""
                $script:UnavailablePublished = $false
                function Repair-DockerDesktopAvailability { param([object]$Settings); throw "fixture docker failure" }
                function Set-TrackedHostRuntimeStatus { param([object]$Config, [string]$Status); $script:UnavailableStatus = $Status }
                function Publish-Registry {
                    param([object]$Config, [switch]$SkipUnchangedHost, [switch]$SkipRuntimeRefresh)
                    $script:UnavailablePublished = [bool]$SkipRuntimeRefresh
                }

                { Invoke-McpHostWatchdogRun -Config $hostConfig *> $null } | Should -Throw "*fixture docker failure*"
                $script:UnavailableStatus | Should -Be "unavailable"
                $script:UnavailablePublished | Should -BeTrue
                $state = Read-JsonFile -Path (Get-McpHostWatchdogStatePath -Config $hostConfig)
                $state.status | Should -Be "failed"
                $state.message | Should -Be "fixture docker failure"
                Remove-Variable -Scope Script -Name UnavailableStatus -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name UnavailablePublished -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "rolls back tracked proxy activation before publish when qualification fails" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-tools-proxy-rollback-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $stateRoot = Join-Path $tempRoot "state"
        $statePath = Join-Path $stateRoot "host-state.json"
        try {
            New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1; hostId = "fixture-host"; baseUrl = "http://fixture-host"; stateRoot = $stateRoot
                toolsListProxy = [ordered]@{ enabled = $true; serverIds = @("code"); portOffset = 4000; image = "fixture-proxy:latest" }
            }
            $state = [ordered]@{
                schemaVersion = 1; updatedAt = "2026-07-20T00:00:00Z"; configurations = @()
                servers = @([ordered]@{
                    id = "code"; scope = "project"; configId = "trade"; name = "itl-code-trade"
                    containerName = "itl-code-trade"; hostPort = 18100; url = "http://fixture-host:18100/mcp"
                    status = "running"; health = "running"
                })
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            Set-Content -LiteralPath $statePath -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            $before = Get-Content -Raw -LiteralPath $statePath

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:DryRun = $false
                $script:ProxyRollbackDockerCalls = New-Object System.Collections.Generic.List[string]
                $script:ProxyRollbackPublished = $false
                function Get-Command { param($Name, $ErrorAction); return [pscustomobject]@{ Source = $Name } }
                function Test-DockerDaemonAvailable { param([int]$TimeoutSec = 15); return $true }
                function Assert-HostSourceCheckoutCurrent { }
                function Assert-RegistryPushPreflight { param([object]$Config) }
                function Ensure-ToolsListProxyImage { param([object]$Config) }
                function Get-HostContainerPublishState {
                    param([string]$ContainerName)
                    return $(if ($ContainerName -eq "itl-code-trade") { "running" } else { "missing" })
                }
                function Test-HostTcpPortOpen {
                    param([int]$Port, [int]$TimeoutMilliseconds = 500)
                    return ($Port -in @(18100, 22100))
                }
                function Wait-ToolsListProxyReady { param([int]$Port); return $false }
                function Invoke-DockerCommand {
                    param([string[]]$Arguments, [switch]$Quiet, [int]$TimeoutSec = 300)
                    $script:ProxyRollbackDockerCalls.Add(($Arguments -join " "))
                    return 0
                }
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker")
                    $script:ProxyRollbackDockerCalls.Add(($Arguments -join " "))
                }
                function Invoke-DockerCommandCapture {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker")
                    return @("qualification failed")
                }
                function Start-Sleep { param([int]$Seconds) }
                function Publish-Registry { param([object]$Config); $script:ProxyRollbackPublished = $true }

                { Enable-TrackedToolsListProxiesAndPublish -Config (Read-JsonFile -Path $configPath) } | Should -Throw "*did not qualify*"
                $script:ProxyRollbackPublished | Should -BeFalse
                (@($script:ProxyRollbackDockerCalls) -join "|") | Should -Match "run -d --restart unless-stopped --name itl-code-trade-tools-list-proxy"
                (@($script:ProxyRollbackDockerCalls) -join "|") | Should -Match "rm -f itl-code-trade-tools-list-proxy"
                Remove-Variable -Scope Script -Name ProxyRollbackDockerCalls -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name ProxyRollbackPublished -ErrorAction SilentlyContinue
            }

            (Get-Content -Raw -LiteralPath $statePath) | Should -BeExactly $before
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "wires standalone MCP host tooling and registry schema" {
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\install-vibecoding1c-mcp-host.ps1") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\export-1c-config-dump.ps1") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\host.config.example.json") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\README.md") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\bookstack-product-docs-mcp\Dockerfile") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\bookstack-product-docs-mcp\server.py") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\bookstack-product-docs-mcp\requirements.txt") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\bookstack-product-docs-mcp\test_server.py") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\mantis-ticket-mcp\Dockerfile") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\mantis-ticket-mcp\server.py") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\mantis-ticket-mcp\requirements.txt") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\mantis-ticket-mcp\test_server.py") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\tools-list-proxy\Dockerfile") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\tools-list-proxy\mcp-tools-list-proxy.js") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\tools-list-proxy\mcp-tools-list-catalog.js") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\tools-list-proxy\tools-contract.json") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts\export-tools-list-proxy-catalog.ps1") -PathType Leaf) | Should -Be $true
        $bookStackRequirementsText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\bookstack-product-docs-mcp\requirements.txt")
        $bookStackRequirementsText | Should -Match "fastmcp>=2\.10,<3\.0"
        $bookStackRequirementsText | Should -Match "sentence-transformers"
        $bookStackServerText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\bookstack-product-docs-mcp\server.py")
        $bookStackServerText | Should -Match 'FastMCP\("bookstack-product-docs", stateless_http=True\)'
        foreach ($toolName in @("search_docs", "read_page", "list_structure", "index_status", "reindex_docs")) {
            $bookStackServerText | Should -Match "def $toolName"
        }
        $bookStackServerText | Should -Match "/api/search"
        $bookStackServerText | Should -Match "/api/pages"
        $bookStackServerText | Should -Match "CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts"
        $bookStackServerText | Should -Match "/embeddings"
        $bookStackServerText | Should -Match "embedded_pages"
        $bookStackServerText | Should -Match "newest_indexed_at"
        $bookStackServerText | Should -Match "last_embedding_error"
        $bookStackServerText | Should -Match "EMBEDDING_MODEL"
        $bookStackServerText | Should -Match "/app/model_cache"
        $bookStackServerText | Should -Match "SentenceTransformer"
        $bookStackServerText | Should -Match "cache_folder=self.cache_dir"
        $bookStackServerText | Should -Match "normalize_embeddings=True"
        $bookStackServerText | Should -Match "DEFAULT_PAGE_MAX_CHARS = 12000"
        $bookStackServerText | Should -Match "DEFAULT_STRUCTURE_LIMIT = 30"
        $bookStackServerText | Should -Match "total_matches"
        $bookStackServerText | Should -Match "has_more"
        $bookStackServerText | Should -Match "next_cursor"
        $bookStackServerText | Should -Match "semantic_min_score"
        $mantisRequirementsText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\mantis-ticket-mcp\requirements.txt")
        $mantisRequirementsText | Should -Match "fastmcp>=2\.10,<3\.0"
        $mantisRequirementsText | Should -Match "pytesseract"
        $mantisRequirementsText | Should -Match "Pillow"
        $mantisServerText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\mantis-ticket-mcp\server.py")
        $mantisServerText | Should -Match 'FastMCP\("mantis-ticket", stateless_http=True\)'
        foreach ($toolName in @("read_ticket", "get_attachment", "health")) {
            $mantisServerText | Should -Match "def $toolName"
        }
        $mantisServerText | Should -Match "OCR_NOTICE"
        $mantisServerText | Should -Match "style_spans"
        $mantisServerText | Should -Match "rendered_html_sanitized"
        $mantisServerText | Should -Match "agent_context_markdown"
        $mantisServerText | Should -Match "original_is_source_of_truth"
        $mantisServerText | Should -Match "/api/rest/issues"
        $indexStatusStart = $bookStackServerText.IndexOf("    def index_status(self) -> Dict[str, Any]:")
        $indexStatusEnd = $bookStackServerText.IndexOf("    def index_page", $indexStatusStart)
        $indexStatusStart | Should -BeGreaterThan -1
        $indexStatusEnd | Should -BeGreaterThan $indexStatusStart
        $bookStackServerText.Substring($indexStatusStart, $indexStatusEnd - $indexStatusStart) | Should -Not -Match "self\.client"

        $hostConfig = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\host.config.example.json") | ConvertFrom-Json
        $hostConfig.registryRepo | Should -Be "http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git"
        $hostConfig.pythonPath | Should -Be "python"
        $hostConfig.embedding.PSObject.Properties["apiBase"] | Should -BeNullOrEmpty
        $hostConfig.embedding.PSObject.Properties["apiKey"] | Should -BeNullOrEmpty
        $hostConfig.embedding.model | Should -Be "intfloat/multilingual-e5-base"
        $hostConfig.codeMetadataSearchServer.resetDatabase | Should -Be $false
        $hostConfig.codeMetadataSearchServer.PSObject.Properties["reindexIntervalHours"] | Should -Not -BeNullOrEmpty
        $hostConfig.graphMetadataSearchServer.resetDatabase | Should -Be $false
        $hostConfig.graphMetadataSearchServer.PSObject.Properties["reindexIntervalHours"] | Should -Not -BeNullOrEmpty
        $hostConfig.toolsListProxy.enabled | Should -BeTrue
        @($hostConfig.toolsListProxy.serverIds) | Should -Be @("docs", "templates", "syntax", "codechecker", "ssl", "bookstack", "mantis", "code", "graph")
        $hostConfig.toolsListProxy.portOffset | Should -Be 4000
        $hostConfig.watchdog.enabled | Should -BeTrue
        $hostConfig.watchdog.intervalMinutes | Should -Be 5
        $hostConfig.watchdog.startupDelaySeconds | Should -Be 30
        $hostConfig.watchdog.taskName | Should -Be "ITL MCP Host Watchdog"
        $hostConfig.watchdog.dockerDesktopRecovery.enabled | Should -BeTrue
        $hostConfig.watchdog.dockerDesktopRecovery.timeoutSeconds | Should -Be 120
        $hostConfig.watchdog.dockerDesktopRecovery.commandTimeoutSeconds | Should -Be 90
        $hostConfig.watchdog.dockerDesktopRecovery.pollSeconds | Should -Be 5
        $hostConfig.nightlyIndex.enabled | Should -BeFalse
        $hostConfig.nightlyIndex.at | Should -Be "02:00"
        $hostConfig.nightlyIndex.timeoutMinutes | Should -Be 480
        $hostConfig.nightlyIndex.pollSeconds | Should -Be 15
        $hostConfig.graphMetadataSearchServer.autoUpdateOnStartup | Should -Be $true
        $hostConfig.configurations[0].configId | Should -Be "trade"
        $hostConfig.configurations[0].sourceRepo | Should -Match "trade-config-dump"
        $hostConfig.configurations[1].sourcePath | Should -Match "trade-local"
        $hostConfig.configurations[1].dump.repositoryPath | Should -Match "tcp://"
        $hostConfig.secrets.ONEC_AI_TOKEN | Should -Match "^<"
        $hostConfig.secrets.BOOKSTACK_TOKEN_ID | Should -Match "^<"
        $hostConfig.secrets.BOOKSTACK_TOKEN_SECRET | Should -Match "^<"
        $hostConfig.secrets.MANTIS_API_TOKEN | Should -Match "^<"
        $hostConfig.bookStackProductDocsServer.baseUrl | Should -Match "^http"
        $hostConfig.bookStackProductDocsServer.reindexIntervalHours | Should -Be 24
        $hostConfig.bookStackProductDocsServer.semanticMinScore | Should -Be 0.82
        $hostConfig.mantisTicketServer.baseUrl | Should -Match "^http"
        $hostConfig.mantisTicketServer.attachmentCachePath | Should -Match "mantis-ticket"
        $hostConfig.mantisTicketServer.maxAttachmentBytes | Should -Be 26214400
        $hostConfig.mantisTicketServer.maxInlineTextChars | Should -Be 16000
        $hostConfig.mantisTicketServer.ocr.enabled | Should -Be $true
        $hostConfig.mantisTicketServer.ocr.languages | Should -Contain "rus"
        $hostConfig.mantisTicketServer.ocr.languages | Should -Contain "eng"
        $hostConfig.enabledServers.global | Should -Contain "bookstack"
        $hostConfig.enabledServers.global | Should -Contain "mantis"
        $hostConfig.helpSearchServer.platformVersion | Should -Match "8\.3\."
        $hostConfig.helpSearchServer.platformBinPath | Should -Match "1cv8"
        $hostConfig.sslSearchServer.bspVersion | Should -Match "3\."
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape("vibecoding1c-mcp-host/host.config.json"))
        $McpHostText | Should -Match "norkins/metadata"
        $McpHostText | Should -Match "Invoke-PythonMetadataGenerator"
        $McpHostText | Should -Match "Ensure-PythonRuntime"
        $McpHostText | Should -Match "Resolve-PythonExecutable"
        $McpHostText | Should -Match "pythonPath"
        $McpHostText | Should -Match "Python 3 runtime check failed"
        $McpHostText | Should -Match "function Invoke-Git"
        $McpHostText | Should -Match '& git -C \$Root @Arguments 2>&1'
        $McpHostText | Should -Match 'Invoke-Git -Root \$parent -Arguments @\("clone", \$Repo, \$Path\)'
        $McpHostText | Should -Match "Write-MetadataDiagnosticsSummary"
        $McpHostText | Should -Match "Write-HostPhase"
        $McpHostText | Should -Match "Refreshing metadata for configId"
        $McpHostText | Should -Match "Running norkins/metadata report generation"
        $McpHostText | Should -Match "Report.txt ready for configId"
        $McpHostText | Should -Match "Container ready:"
        $McpHostText | Should -Match "Enabled global servers:"
        $McpHostText | Should -Match "Enabled project servers:"
        $McpHostText | Should -Match 'exitCode -eq 1'
        $McpHostText | Should -Match "with warnings"
        $McpHostText | Should -Match "did not create Report.txt"
        $McpHostText | Should -Match "norkins-metadata-"
        $McpHostText | Should -Match "mainConfigPath was not found"
        $McpHostText | Should -Match "Generator config:"
        $McpHostText | Should -Match "Python log:"
        $McpHostText | Should -Match "registry.json"
        $McpHostText | Should -Match "family"
        $McpHostText | Should -Match "sourceFingerprint"
        $McpHostText | Should -Match "dump-config"
        $McpHostText | Should -Match '"reindex"'
        $McpHostText | Should -Match '\[string\]\$ServerId'
        $McpHostText | Should -Match "Select-TargetServerIds"
        $McpHostText | Should -Match "Assert-TargetServerRequest"
        $McpHostText | Should -Match "Invoke-HostReindex"
        $McpHostText | Should -Match "Update-HostStateServers"
        $McpHostText | Should -Match "ForceResetDatabase"
        $McpHostText | Should -Match "Test-HostServerSupportsDatabaseReset"
        $McpHostText | Should -Match "Reindexing database-backed MCP servers"
        $McpHostText | Should -Match "Skipping configuration refresh because targeted server"
        $McpHostText | Should -Match "standalone-cpu-embedding-placeholder"
        $McpHostText | Should -Match "Invoke-HostConfigDumpHelper"
        $McpHostText | Should -Match 'Refresh-HostConfigurations -Config \$config -TargetConfigId \$ConfigId'
        $McpHostText | Should -Match "Get-BookStackProductDocsServerDefinition"
        $McpHostText | Should -Match '(?s)Get-BookStackProductDocsServerDefinition.*embedding = \$true'
        $McpHostText | Should -Match "Ensure-ServerDockerImageAvailable"
        $McpHostText | Should -Match "BOOKSTACK_BASE_URL"
        $McpHostText | Should -Match "BookStack-product-docs-mcp"
        $McpHostText | Should -Match "Get-MantisTicketServerDefinition"
        $McpHostText | Should -Match "MANTIS_BASE_URL"
        $McpHostText | Should -Match "MANTIS_API_TOKEN"
        $McpHostText | Should -Match "MANTIS_OCR_LANGUAGES"
        $McpHostText | Should -Match "itl-mantis-ticket-mcp"
        $McpHostText | Should -Match "sourcePath"
        $McpHostText | Should -Match "Ensure-HostEmbeddingModel"
        $McpHostText | Should -Match "Test-HostEmbeddingModelPresent"
        $McpHostText | Should -Match "Get-HostEmbeddingModelsUri"
        $McpHostText | Should -Match "lms server start --port"
        $McpHostText | Should -Match "ONEC_AI_TOKEN"
        $McpHostText | Should -Match "PATH_1C_BIN"
        $McpHostText | Should -Match "PLATFORM_VERSION"
        $McpHostText | Should -Match "SSL_VERSION"
        $McpHostText | Should -Match "BSP_VERSION"
        $McpHostText | Should -Match "ConfigurationRepositoryUpdateCfg"
        $McpHostText | Should -Match "DumpConfigToFiles"
        $McpHostText | Should -Match "ConfigDumpInfo.xml"
        $McpHostText | Should -Match "nightly-index-install"
        $McpHostText | Should -Match 'reindex" -Arguments \(\[ordered\]@\{ force = \$false \}\)'
        $McpHostText | Should -Match "get_indexing_status"
        $McpHostText | Should -Match "host-maintenance.lock"
        $McpHostText | Should -Match "AUTO_UPDATE_ON_STARTUP=true"
        $readmeText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\README.md")
        $readmeText | Should -Match ([regex]::Escape("-Action setup -ConfigPath .\host.config.json -ServerId bookstack"))
        $readmeText | Should -Match ([regex]::Escape("-Action start -ConfigPath .\host.config.json -ServerId bookstack"))
        $readmeText | Should -Match ([regex]::Escape("-Action status -ConfigPath .\host.config.json -ServerId bookstack"))
        $readmeText | Should -Match ([regex]::Escape("-Action stop -ConfigPath .\host.config.json -ServerId bookstack"))
        $readmeText | Should -Match ([regex]::Escape("-Action reindex -ConfigPath .\host.config.json -ServerId bookstack"))
        $readmeText | Should -Match ([regex]::Escape("-Action setup -ConfigPath .\host.config.json -ServerId mantis"))
        $readmeText | Should -Match ([regex]::Escape("-Action start -ConfigPath .\host.config.json -ServerId mantis"))
        $readmeText | Should -Match ([regex]::Escape("-Action status -ConfigPath .\host.config.json -ServerId mantis"))
        $readmeText | Should -Match ([regex]::Escape("-Action stop -ConfigPath .\host.config.json -ServerId mantis"))
        $readmeText | Should -Match "index_status"
        $readmeText | Should -Match "intfloat/multilingual-e5-base"
        $readmeText | Should -Match ([regex]::Escape("/app/model_cache"))
        $readmeText | Should -Match "sentence-transformers"
        $readmeText | Should -Match "embedded_pages > 0"
        $readmeText | Should -Match ([regex]::Escape("-Action reconcile -ConfigPath .\host.config.json"))
        $readmeText | Should -Match ([regex]::Escape("-Action watchdog-install -ConfigPath .\host.config.json"))
        $readmeText | Should -Match ([regex]::Escape("-Action watchdog-status -ConfigPath .\host.config.json"))
        $readmeText | Should -Match ([regex]::Escape("-Action watchdog-run -ConfigPath .\host.config.json"))
        $readmeText | Should -Match ([regex]::Escape("-Action watchdog-uninstall -ConfigPath .\host.config.json"))
        $readmeText | Should -Match "Docker Desktop CLI"
        $readmeText | Should -Match "without a container restart or indexing"
        $readmeText | Should -Match "restart=unless-stopped"
        $readmeText | Should -Match ([regex]::Escape("https://docs.onerpa.ru/mcp-servery-1c"))
        $readmeText | Should -Match ([regex]::Escape("-Action nightly-index-run -ConfigPath .\host.config.json"))
        $readmeText | Should -Match ([regex]::Escape("reindex(force=false)"))
        $runbookText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\RUNBOOK.ru.md")
        $runbookText | Should -Match ([regex]::Escape("-Action setup -ConfigPath .\host.config.json -ServerId bookstack"))
        $runbookText | Should -Match ([regex]::Escape("-Action start -ConfigPath .\host.config.json -ServerId bookstack"))
        $runbookText | Should -Match ([regex]::Escape("-Action status -ConfigPath .\host.config.json -ServerId bookstack"))
        $runbookText | Should -Match ([regex]::Escape("-Action stop -ConfigPath .\host.config.json -ServerId bookstack"))
        $runbookText | Should -Match ([regex]::Escape("-Action reindex -ConfigPath .\host.config.json -ServerId bookstack"))
        $runbookText | Should -Match ([regex]::Escape("-Action setup -ConfigPath .\host.config.json -ServerId mantis"))
        $runbookText | Should -Match ([regex]::Escape("-Action start -ConfigPath .\host.config.json -ServerId mantis"))
        $runbookText | Should -Match ([regex]::Escape("-Action status -ConfigPath .\host.config.json -ServerId mantis"))
        $runbookText | Should -Match ([regex]::Escape("-Action stop -ConfigPath .\host.config.json -ServerId mantis"))
        $runbookText | Should -Match "index_status"
        $runbookText | Should -Match "intfloat/multilingual-e5-base"
        $runbookText | Should -Match ([regex]::Escape("/app/model_cache"))
        $runbookText | Should -Match "sentence-transformers"
        $runbookText | Should -Match "embedded_pages > 0"
        $runbookText | Should -Match ([regex]::Escape("-Action reconcile -ConfigPath .\host.config.json"))
        $runbookText | Should -Match ([regex]::Escape("-Action watchdog-install -ConfigPath .\host.config.json"))
        $runbookText | Should -Match ([regex]::Escape("-Action watchdog-status -ConfigPath .\host.config.json"))
        $runbookText | Should -Match ([regex]::Escape("-Action watchdog-run -ConfigPath .\host.config.json"))
        $runbookText | Should -Match ([regex]::Escape("-Action watchdog-uninstall -ConfigPath .\host.config.json"))
        $runbookText | Should -Match "dockerDesktopRecovery"
        $runbookText | Should -Match "без перезапуска контейнера и без индексации"
        $runbookText | Should -Match ([regex]::Escape("https://docs.onerpa.ru/mcp-servery-1c"))
        $runbookText | Should -Match ([regex]::Escape("-Action nightly-index-run -ConfigPath .\host.config.json"))
        $runbookText | Should -Match ([regex]::Escape("reindex(force=false)"))
        $McpHostDumpText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\export-1c-config-dump.ps1")
        $nativeEmptyStringFunction = [regex]::Match($McpHostDumpText, '(?s)function ConvertTo-NativeEmptyStringArgument \{.*?\n\}')
        $nativeEmptyStringFunction.Success | Should -Be $true
        $nativeEmptyStringFunction.Value | Should -Match 'return ""'
        $nativeEmptyStringFunction.Value | Should -Not -Match 'return ''""'''
        $McpHostText | Should -Match "Invoke-DockerCommand"
        $McpHostText | Should -Match '"image", "inspect"'
        $McpHostText | Should -Match '"pull", \$Image'
        $McpHostText | Should -Match 'Write-Host \(\[string\]\$line\)'
        $McpHostText | Should -Match "Invoke-ProcessWithTimeout"
        $McpHostText | Should -Match "Invoke-DockerCommandChecked"
        $McpHostText | Should -Match "Invoke-DockerCommandCapture"
        $McpHostText | Should -Match "Command timed out after"
        $McpHostText | Should -Match "read-only file system"
        $McpHostText | Should -Not -Match '(?m)^\s*LICENSE_KEY_[A-Z0-9_]+\s*=\s*[^#\s]+'
    }

    It "publishes proxied endpoints only after MCP protocol readiness" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-tools-proxy-publish-status-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{ schemaVersion = 1; stateRoot = (Join-Path $tempRoot "state") }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                function Get-HostContainerPublishState {
                    param([string]$ContainerName)
                    return $script:ProxyPublishContainerState
                }
                function Test-ToolsListProxyReady {
                    param([int]$Port, [int]$TimeoutSec = 35)
                    return $script:ProxyPublishReady
                }
                $server = [ordered]@{
                    id = "code"; containerName = "itl-code-trade"; hostPort = 18100
                    proxyUrl = "http://fixture-host:22100/mcp"; proxyPort = 22100
                    proxyContainerName = "itl-code-trade-tools-list-proxy"; toolsContractStatus = "qualified"
                }

                $script:ProxyPublishContainerState = "running"
                $script:ProxyPublishReady = $true
                (Get-HostServerPublishStatus -Server $server) | Should -Be "running"
                $script:ProxyPublishReady = $false
                (Get-HostServerPublishStatus -Server $server) | Should -Be "unreachable"
                $script:ProxyPublishContainerState = "stopped"
                (Get-HostServerPublishStatus -Server $server) | Should -Be "stopped"
                Remove-Variable -Scope Script -Name ProxyPublishContainerState -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name ProxyPublishReady -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "fails registry credential preflight before proxy container activation" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-tools-proxy-preflight-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $registryRoot = Join-Path $tempRoot "registry"
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $registryRoot ".git") | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (([ordered]@{ schemaVersion = 1; stateRoot = $tempRoot } | ConvertTo-Json) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                function Invoke-HostGitPreflight {
                    param([string]$Root, [string[]]$Arguments, [int]$TimeoutSec = 45, [string]$Description = "Git preflight")
                    return [pscustomobject]@{ exitCode = 1; lines = @("authentication failed") }
                }

                { Assert-RegistryPushPreflight -Config (Read-JsonFile -Path $configPath) } | Should -Throw "*before proxy activation*"
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "rejects a stale host source checkout before proxy activation" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-host-source-preflight-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1,"stateRoot":"fixture"}'
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                function Get-GitOutput {
                    param([string]$Root, [string[]]$Arguments)
                    $command = $Arguments -join " "
                    if ($command -eq "rev-parse --show-toplevel") { return @($tempRoot) }
                    if ($command -match "--symbolic-full-name") { return @("origin/develop") }
                    if ($command -eq "rev-parse HEAD") { return @("1111111111111111111111111111111111111111") }
                    if ($command -eq "rev-parse origin/develop") { return @("2222222222222222222222222222222222222222") }
                    throw "Unexpected git query: $command"
                }
                function global:git { $global:LASTEXITCODE = 0; return @() }
                function Invoke-HostGitPreflight {
                    param([string]$Root, [string[]]$Arguments, [int]$TimeoutSec = 45, [string]$Description = "Git preflight")
                    if ($Arguments[0] -eq "fetch") { return [pscustomobject]@{ exitCode = 0; lines = @() } }
                    return [pscustomobject]@{ exitCode = 1; lines = @() }
                }

                { Assert-HostSourceCheckoutCurrent } | Should -Throw "*stale or diverged*"
                Remove-Item Function:\global:git -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item Function:\global:git -ErrorAction SilentlyContinue }
    }

    It "marks Graph functionally degraded when vector tasks are blocked by an embedding mismatch" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-graph-functional-health-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1,"stateRoot":"fixture"}'
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                function Open-HostMcpConnection { param([string]$Url, [int]$TimeoutSec = 60); return [pscustomobject]@{ url = $Url; headers = @{}; nextId = 2 } }
                function Invoke-HostMcpTool {
                    param([object]$Connection, [string]$Name, [object]$Arguments = $null, [int]$TimeoutSec = 120)
                    $status = [ordered]@{
                        background_tasks = [ordered]@{
                            structural_indexes = [ordered]@{ status = "completed"; error = $null }
                            vector_indexing = [ordered]@{ status = "running"; error = $null }
                            routine_embedding_indexing = [ordered]@{ status = "running"; error = $null }
                        }
                        any_running = $true
                    } | ConvertTo-Json -Depth 8 -Compress
                    return [pscustomobject]@{ content = @([pscustomobject]@{ type = "text"; text = $status }) }
                }
                function Invoke-DockerCommandCapture {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker command")
                    return @("EMBEDDING MODEL MISMATCH DETECTED!", "Exiting process due to embedding model mismatch.")
                }
                $server = [ordered]@{ id = "graph"; name = "itl-trade-graph"; containerName = "itl-trade-graph"; url = "http://host-a:18101/mcp" }

                $health = Get-HostServerFunctionalHealth -Server $server
                $health.status | Should -Be "degraded"
                $health.message | Should -Match "embedding model mismatch"
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "keeps config-specific MCP host servers project-scoped for legacy manifests and configs" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-scope-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                enabledServers = [ordered]@{
                    global = @("docs", "graph")
                    project = @("code")
                }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $legacyGraph = [pscustomobject]@{ id = "graph" }
                $globalGraph = [pscustomobject]@{ id = "graph"; scope = "global" }

                Get-ServerScope -Server $legacyGraph | Should -Be "project"
                Get-ServerScope -Server $globalGraph | Should -Be "project"
                Get-EnabledServerIds -Config $hostConfig -Scope "global" | Should -Not -Contain "graph"
                Get-EnabledServerIds -Config $hostConfig -Scope "project" | Should -Contain "graph"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "selects one standalone MCP host server without dropping other host state records" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-server-target-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                enabledServers = [ordered]@{
                    global = @("docs", "bookstack")
                    project = @("code")
                }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $manifest = [pscustomobject]@{
                    servers = @(
                        [pscustomobject]@{ id = "docs"; scope = "global" },
                        [pscustomobject]@{ id = "bookstack"; scope = "global" },
                        [pscustomobject]@{ id = "code"; scope = "project" }
                    )
                }
                $globalIds = Get-EnabledServerIds -Config $hostConfig -Scope "global"
                $projectIds = Get-EnabledServerIds -Config $hostConfig -Scope "project"

                Select-TargetServerIds -Ids $globalIds -TargetServerId "bookstack" | Should -Be @("bookstack")
                @(Select-TargetServerIds -Ids $projectIds -TargetServerId "bookstack").Count | Should -Be 0
                { Assert-TargetServerRequest -Manifest $manifest -TargetServerId "bookstack" -TargetConfigId "trade" -GlobalServerIds $globalIds -ProjectServerIds $projectIds } | Should -Throw "*global MCP server*"
                { Assert-TargetServerRequest -Manifest $manifest -TargetServerId "missing" -GlobalServerIds $globalIds -ProjectServerIds $projectIds } | Should -Throw "*was not found*"

                Write-HostState -Config $hostConfig -State ([ordered]@{
                    schemaVersion = 1
                    configurations = @()
                    servers = @(
                        [pscustomobject]@{ id = "docs"; scope = "global"; name = "docs"; configId = "" },
                        [pscustomobject]@{ id = "code"; scope = "project"; name = "code-trade"; configId = "trade" }
                    )
                })
                Update-HostStateServers -Config $hostConfig -ServerStates @(
                    [pscustomobject]@{ id = "bookstack"; scope = "global"; name = "bookstack-product-docs"; configId = "" }
                )
                $state = Read-HostState -Config $hostConfig
                $ids = @(As-Array (Get-ObjectValue -Object $state -Name "servers" -Default @()) | ForEach-Object { [string](Get-ObjectValue -Object $_ -Name "id" -Default "") })
                $ids.Count | Should -Be 3
                $ids | Should -Contain "docs"
                $ids | Should -Contain "code"
                $ids | Should -Contain "bookstack"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not let blank distribution PATH settings shadow host-generated config paths" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-path-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            $stateRoot = Join-Path $tempRoot "state"
            New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot "distribution") | Out-Null
            Set-Content -LiteralPath (Join-Path $stateRoot "distribution\config.env") -Encoding UTF8 -Value "PATH_METADATA=`nPATH_CODE=`n"

            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = $stateRoot
                enabledServers = [ordered]@{ global = @(); project = @("graph") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $configState = [pscustomobject]@{
                    configId = "pm5corp"
                    metadataRoot = (Join-Path $tempRoot "metadata")
                    sourceRoot = (Join-Path $tempRoot "source")
                    mainConfigPath = "src/cf"
                }
                $server = [pscustomobject]@{
                    id = "graph"
                    env = @([ordered]@{ name = "METADATA_HOST_PATH"; from = "PATH_METADATA"; required = $true })
                }

                $envValues = Resolve-ServerEnv -Config $hostConfig -Server $server -ConfigState $configState

                $envValues["METADATA_HOST_PATH"] | Should -Be $configState.metadataRoot
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "falls back graph chat OpenAI settings to host embedding settings" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-graph-openai-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            $stateRoot = Join-Path $tempRoot "state"
            New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot "distribution") | Out-Null
            Set-Content -LiteralPath (Join-Path $stateRoot "distribution\config.env") -Encoding UTF8 -Value "CHAT_API_KEY=`nCHAT_API_BASE=`nCHAT_MODEL=`n"

            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = $stateRoot
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "fixture-embedding-model"
                }
                secrets = [ordered]@{
                    ("BOOKSTACK_TOKEN_" + "ID") = "fixture-id"
                    ("BOOKSTACK_TOKEN_" + "SECRET") = "fixture-secret"
                    MANTIS_API_TOKEN = "fixture-mantis-token"
                }
                bookStackProductDocsServer = [ordered]@{
                    baseUrl = "http://bookstack.test"
                }
                mantisTicketServer = [ordered]@{
                    baseUrl = "http://mantis.test"
                    attachmentCachePath = (Join-Path $tempRoot "mantis-attachments")
                    timeoutSeconds = 25
                    maxAttachmentBytes = 12345
                    maxInlineTextChars = 2345
                    ocr = [ordered]@{
                        enabled = $true
                        languages = @("rus", "eng")
                    }
                }
                enabledServers = [ordered]@{ global = @(); project = @("graph") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{
                    id = "graph"
                    embedding = $true
                    env = @(
                        [ordered]@{ name = "OPENAI_API_KEY"; from = "CHAT_API_KEY"; required = $false },
                        [ordered]@{ name = "OPENAI_API_BASE"; from = "CHAT_API_BASE"; required = $false },
                        [ordered]@{ name = "OPENAI_MODEL"; from = "CHAT_MODEL"; required = $false }
                    )
                }

                $envValues = Resolve-ServerEnv -Config $hostConfig -Server $server

                $envValues["OPENAI_API_KEY"] | Should -Be "lm-studio"
                $envValues["OPENAI_API_BASE"] | Should -Be "http://host.docker.internal:19000/v1"
                $envValues["OPENAI_MODEL"] | Should -Be "fixture-embedding-model"

                $bookStackEnv = Resolve-ServerEnv -Config $hostConfig -Server (Get-BookStackProductDocsServerDefinition)
                $bookStackEnv["BOOKSTACK_EMBEDDING_API_KEY"] | Should -Be "lm-studio"
                $bookStackEnv["BOOKSTACK_EMBEDDING_API_BASE"] | Should -Be "http://host.docker.internal:19000/v1"
                $bookStackEnv["BOOKSTACK_EMBEDDING_MODEL"] | Should -Be "fixture-embedding-model"
                $bookStackEnv.Contains("EMBEDDING_MODEL") | Should -Be $false

                $mantisServer = Get-MantisTicketServerDefinition
                $mantisEnv = Resolve-ServerEnv -Config $hostConfig -Server $mantisServer
                $mantisEnv["MANTIS_BASE_URL"] | Should -Be "http://mantis.test"
                $mantisEnv["MANTIS_API_TOKEN"] | Should -Be "fixture-mantis-token"
                $mantisEnv["MANTIS_TIMEOUT_SECONDS"] | Should -Be "25"
                $mantisEnv["MANTIS_MAX_ATTACHMENT_BYTES"] | Should -Be "12345"
                $mantisEnv["MANTIS_MAX_INLINE_TEXT_CHARS"] | Should -Be "2345"
                $mantisEnv["MANTIS_OCR_ENABLED"] | Should -Be $true
                $mantisEnv["MANTIS_OCR_LANGUAGES"] | Should -Be "rus,eng"
                $mantisVolumes = @(Resolve-ServerVolumes -Config $hostConfig -Server $mantisServer)
                @($mantisVolumes | Where-Object { $_.container -eq "/data/attachments" }).Count | Should -Be 1
                (Test-Path -LiteralPath (Join-Path $tempRoot "mantis-attachments") -PathType Container) | Should -Be $true
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "isolates standalone PATH_BASES volumes by config and server" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-bases-volume-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                enabledServers = [ordered]@{ global = @(); project = @("code") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{
                    id = "code"
                    scope = "project"
                    volumes = @([ordered]@{ from = "PATH_BASES"; to = "/app/chroma_db"; required = $false; subdir = "mcp_codemetadata" })
                }
                $tradeState = [pscustomobject]@{ configId = "trade"; sourceRoot = $tempRoot; mainConfigPath = "."; metadataRoot = $tempRoot }
                $pmState = [pscustomobject]@{ configId = "pm5corp"; sourceRoot = $tempRoot; mainConfigPath = "."; metadataRoot = $tempRoot }

                $tradeVolumes = @(Resolve-ServerVolumes -Config $hostConfig -Server $server -ConfigState $tradeState)
                $pmVolumes = @(Resolve-ServerVolumes -Config $hostConfig -Server $server -ConfigState $pmState)

                $tradeVolume = $tradeVolumes | Where-Object { $_.container -eq "/app/chroma_db" } | Select-Object -First 1
                $pmVolume = $pmVolumes | Where-Object { $_.container -eq "/app/chroma_db" } | Select-Object -First 1
                $tradeVolume.host | Should -Be (Join-Path (Join-Path (Join-Path $hostConfig.stateRoot "bases") "trade") "code\mcp_codemetadata")
                $pmVolume.host | Should -Be (Join-Path (Join-Path (Join-Path $hostConfig.stateRoot "bases") "pm5corp") "code\mcp_codemetadata")
                $tradeVolume.host | Should -Not -Be $pmVolume.host
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps standalone Graph CPU embeddings local when distribution defaults point to OpenRouter" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-graph-cpu-key-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            $stateRoot = Join-Path $tempRoot "state"
            New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot "distribution") | Out-Null
            Set-Content -LiteralPath (Join-Path $stateRoot "distribution\config.env") -Encoding UTF8 -Value "CHAT_API_KEY=`nCHAT_API_BASE=https://openrouter.ai/api`nCHAT_MODEL=qwen/qwen3-235b-a22b`nEMBEDDING_API_BASE=https://openrouter.ai/api`nEMBEDDING_MODEL=qwen/qwen3-embedding-8b`n"

            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = $stateRoot
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
                enabledServers = [ordered]@{ global = @(); project = @("graph") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $graphServer = [pscustomobject]@{
                    id = "graph"
                    embedding = $true
                    env = @(
                        [ordered]@{ name = "OPENAI_API_KEY"; from = "CHAT_API_KEY"; required = $false },
                        [ordered]@{ name = "OPENAI_API_BASE"; from = "CHAT_API_BASE"; required = $false },
                        [ordered]@{ name = "OPENAI_MODEL"; from = "CHAT_MODEL"; required = $false }
                    )
                }
                $codeServer = [pscustomobject]@{
                    id = "code"
                    embedding = $true
                    env = @(
                        [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base"; required = $true },
                        [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key"; required = $true },
                        [ordered]@{ name = "OPENAI_MODEL"; embedding = "model"; required = $true }
                    )
                }

                $graphEnv = Resolve-ServerEnv -Config $hostConfig -Server $graphServer
                $graphEnv["OPENAI_API_KEY"] | Should -Be "standalone-cpu-embedding-placeholder"
                $graphEnv["OPENAI_API_BASE"] | Should -Be "http://127.0.0.1:65535/v1"
                $graphEnv.Contains("OPENAI_MODEL") | Should -Be $false
                $graphEnv["OPENAI_EMBEDDING_API_KEY"] | Should -Be "standalone-cpu-embedding-placeholder"
                $graphEnv["OPENAI_EMBEDDING_API_BASE"] | Should -Be "http://127.0.0.1:65535/v1"
                $graphEnv["OPENAI_EMBEDDING_MODEL"] | Should -Be "intfloat/multilingual-e5-base"
                $graphEnv["EMBEDDING_ALLOW_OFFLINE_FALLBACK"] | Should -Be "true"
                $graphEnv["EMBEDDING_MODEL"] | Should -Be "intfloat/multilingual-e5-base"
                @($graphEnv.Values | Where-Object { [string]$_ -match "openrouter" }).Count | Should -Be 0

                $codeEnv = Resolve-ServerEnv -Config $hostConfig -Server $codeServer
                $codeEnv.Contains("OPENAI_API_KEY") | Should -Be $false
                $codeEnv.Contains("OPENAI_API_BASE") | Should -Be $false
                $codeEnv.Contains("OPENAI_MODEL") | Should -Be $false
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "uses standalone CPU embedding model without OpenAI env, lms, or LM Studio bootstrap" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-cpu-embedding-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    model = "intfloat/multilingual-e5-base"
                }
                secrets = [ordered]@{
                    ("BOOKSTACK_TOKEN_" + "ID") = "fixture-id"
                    ("BOOKSTACK_TOKEN_" + "SECRET") = "fixture-secret"
                }
                bookStackProductDocsServer = [ordered]@{
                    baseUrl = "http://bookstack.test"
                }
                enabledServers = [ordered]@{ global = @(); project = @("code") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostCpuLmsWasCalled = $false
                function Get-HostLmsCommand {
                    $script:HostCpuLmsWasCalled = $true
                    return $null
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{
                    id = "code"
                    scope = "project"
                    embedding = $true
                    env = @(
                        [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base"; required = $true },
                        [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key"; required = $true },
                        [ordered]@{ name = "OPENAI_MODEL"; embedding = "model"; required = $true }
                    )
                }
                $manifest = [pscustomobject]@{ servers = @($server) }

                Ensure-HostEmbeddingModel -Config $hostConfig -Manifest $manifest -GlobalServerIds @() -ProjectServerIds @("code")
                $script:HostCpuLmsWasCalled | Should -Be $false

                $envValues = Resolve-ServerEnv -Config $hostConfig -Server $server
                $envValues["EMBEDDING_MODEL"] | Should -Be "intfloat/multilingual-e5-base"
                $envValues.Contains("OPENAI_API_BASE") | Should -Be $false
                $envValues.Contains("OPENAI_API_KEY") | Should -Be $false
                $envValues.Contains("OPENAI_MODEL") | Should -Be $false
                $envValues["RESET_CACHE"] | Should -Be "false"

                $volumes = @(Resolve-ServerVolumes -Config $hostConfig -Server $server)
                @($volumes | Where-Object { $_.container -eq "/app/model_cache" }).Count | Should -Be 1
                (Test-Path -LiteralPath (Join-Path $hostConfig.stateRoot "model-cache") -PathType Container) | Should -Be $true

                $bookStackServer = Get-BookStackProductDocsServerDefinition
                $bookStackServer.embedding | Should -Be $true
                $bookStackEnv = Resolve-ServerEnv -Config $hostConfig -Server $bookStackServer
                $bookStackEnv["EMBEDDING_MODEL"] | Should -Be "intfloat/multilingual-e5-base"
                $bookStackEnv["RESET_CACHE"] | Should -Be "false"
                $bookStackEnv.Contains("BOOKSTACK_EMBEDDING_API_BASE") | Should -Be $false
                $bookStackEnv.Contains("BOOKSTACK_EMBEDDING_API_KEY") | Should -Be $false
                $bookStackEnv.Contains("BOOKSTACK_EMBEDDING_MODEL") | Should -Be $false
                $bookStackVolumes = @(Resolve-ServerVolumes -Config $hostConfig -Server $bookStackServer)
                @($bookStackVolumes | Where-Object { $_.container -eq "/app/model_cache" }).Count | Should -Be 1
                Remove-Variable -Scope Script -Name HostCpuLmsWasCalled -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "maps standalone CodeMetadata and Graph index settings to server env" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-index-env-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
                codeMetadataSearchServer = [ordered]@{
                    resetDatabase = $true
                    reindexIntervalHours = 6
                }
                graphMetadataSearchServer = [ordered]@{
                    resetDatabase = $false
                    reindexIntervalHours = 12
                    autoUpdateOnStartup = $false
                }
                enabledServers = [ordered]@{ global = @(); project = @("code", "graph") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath

                $codeEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{ id = "code"; scope = "project"; embedding = $false; env = @() })
                $codeEnv["RESET_DATABASE"] | Should -Be "true"
                $codeEnv["REINDEX_INTERVAL_HOURS"] | Should -Be "6"

                $graphEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{ id = "graph"; scope = "project"; embedding = $false; env = @() })
                $graphEnv["RESET_DATABASE"] | Should -Be "false"
                $graphEnv["REINDEX_INTERVAL_HOURS"] | Should -Be "12"
                $graphEnv["AUTO_UPDATE_ON_STARTUP"] | Should -Be "false"

                $codeReindexEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{ id = "code"; scope = "project"; embedding = $true; env = @() }) -ForceResetDatabase
                $codeReindexEnv["RESET_DATABASE"] | Should -Be "true"

                $docsSetupEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{
                    id = "docs"
                    scope = "global"
                    embedding = $true
                    env = @([ordered]@{ name = "RESET_CACHE"; value = "true" })
                })
                $docsSetupEnv["RESET_CACHE"] | Should -Be "false"
                $docsSetupEnv["EMBEDDING_MODEL"] | Should -Be "intfloat/multilingual-e5-base"

                $docsReindexEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{
                    id = "docs"
                    scope = "global"
                    embedding = $true
                    env = @([ordered]@{ name = "RESET_CACHE"; value = "true" })
                }) -ForceResetDatabase
                $docsReindexEnv["RESET_CACHE"] | Should -Be "false"
                $docsReindexEnv.Contains("RESET_DATABASE") | Should -Be $false
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "extracts configuration name and version from Configuration.xml and tolerates a missing file" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-config-xml-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $mainRoot = Join-Path $tempRoot "src\cf"

        try {
            New-Item -ItemType Directory -Force -Path $mainRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (@{ schemaVersion = 1; stateRoot = (Join-Path $tempRoot "state") } | ConvertTo-Json)
            Set-Content -LiteralPath (Join-Path $mainRoot "Configuration.xml") -Encoding UTF8 -Value @"
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses">
  <Configuration uuid="fixture">
    <Properties>
      <Name>TradeManagement</Name>
      <Version>11.5.10.99</Version>
    </Properties>
  </Configuration>
</MetaDataObject>
"@

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $info = Read-ConfigurationXmlInfo -MainConfigRoot $mainRoot -FallbackName "Fallback"
                $info.configurationName | Should -Be "TradeManagement"
                $info.configurationVersion | Should -Be "11.5.10.99"

                $missing = Read-ConfigurationXmlInfo -MainConfigRoot (Join-Path $tempRoot "missing") -FallbackName "Fallback"
                $missing.configurationName | Should -Be "Fallback"
                $missing.configurationVersion | Should -Be ""
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "merges standalone registry v2 hosts without overwriting another host" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-registry-v2-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $registryPath = Join-Path $tempRoot "state\registry\registry.json"

        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $registryPath) | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "host-a"
                baseUrl = "http://host-a"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            $existing = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-04T00:00:00Z"
                hosts = @([ordered]@{
                    hostId = "host-b"
                    baseUrl = "http://host-b"
                    publishedAt = "2026-07-04T00:00:00Z"
                    configurations = @([ordered]@{ configId = "trade"; title = "Trade B" })
                    servers = @([ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-b:18100/mcp"; image = "image-b"; health = "running" })
                })
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath $registryPath -Encoding UTF8 -Value (($existing | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $state = [ordered]@{
                    schemaVersion = 1
                    configurations = @([ordered]@{
                        configId = "trade"
                        title = "Trade A"
                        configurationName = "Trade A Name"
                        configurationVersion = "1.0"
                        reportHash = "abc"
                        indexedAt = "2026-07-05T00:00:00Z"
                    })
                    servers = @([ordered]@{
                        id = "code"
                        scope = "project"
                        family = "vibecoding1c"
                        provider = "remote"
                        configId = "trade"
                        name = "itl-trade-code"
                        url = "http://host-a:18100/mcp"
                        image = "image-a"
                        health = "running"
                        configurationName = "Trade A Name"
                        configurationVersion = "1.0"
                        embeddingMode = "cpu"
                        embeddingModel = "intfloat/multilingual-e5-base"
                        functionalStatus = "qualified"
                        functionalMessage = "MCP safe health tool 'stats' passed."
                        indexedAt = "2026-07-05T00:00:00Z"
                    })
                }
                Write-HostState -Config $hostConfig -State $state
                Write-MergedRegistryPayload -Config $hostConfig -RegistryPath $registryPath -PublishedAt "2026-07-05T00:00:00Z"
                $registry = Read-JsonFile -Path $registryPath

                @($registry.hosts).Count | Should -Be 2
                @($registry.hosts | Where-Object { $_.hostId -eq "host-b" }).Count | Should -Be 1
                @($registry.servers | Where-Object { $_.hostId -eq "host-a" -and $_.embeddingModel -eq "intfloat/multilingual-e5-base" }).Count | Should -Be 1
                ($registry.servers | Where-Object { $_.hostId -eq "host-a" -and $_.id -eq "code" } | Select-Object -First 1).clientNames.aiRules1c | Should -Be "1c-code-metadata-mcp"
                (Read-HostState -Config $hostConfig).servers[0].clientNames.aiRules1c | Should -Be "1c-code-metadata-mcp"
                @($registry.configurations | Where-Object { $_.hostId -eq "host-a" -and $_.configurationName -eq "Trade A Name" }).Count | Should -Be 1
                (Test-RegistryCurrentHostMatchesState -Config $hostConfig -RegistryPath $registryPath) | Should -BeTrue
                $changedState = Read-HostState -Config $hostConfig
                $changedState.configurations[0].title = "Trade A changed"
                Write-HostState -Config $hostConfig -State $changedState
                (Test-RegistryCurrentHostMatchesState -Config $hostConfig -RegistryPath $registryPath) | Should -BeFalse
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "refreshes standalone publish state statuses without starting containers or changing index metadata" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-publish-refresh-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $registryPath = Join-Path $tempRoot "state\registry\registry.json"

        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $registryPath) | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "host-a"
                baseUrl = "http://host-a"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            Set-Content -LiteralPath $registryPath -Encoding UTF8 -Value (([ordered]@{ schemaVersion = 2; hosts = @(); configurations = @(); servers = @() } | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:PublishDockerCalls = New-Object System.Collections.Generic.List[string]
                function Invoke-DockerCommandCapture {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker command")
                    $script:PublishDockerCalls.Add("capture:$($Arguments -join ' ')")
                    $name = $Arguments[-1]
                    switch ($name) {
                        "itl-trade-code" { return @("exited") }
                        "itl-trade-graph" { return @("running") }
                        "itl-1c-docs" { throw "No such object: $name" }
                        "itl-1c-ssl" { return @("running") }
                        "itl-1c-syntax" { throw "Cannot connect to the Docker daemon" }
                        default { throw "Unexpected docker inspect for $name" }
                    }
                }
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker command")
                    $script:PublishDockerCalls.Add("checked:$($Arguments -join ' ')")
                    throw "publish refresh must not run docker checked commands"
                }
                function Test-HostTcpPortOpen {
                    param([int]$Port, [int]$TimeoutMilliseconds = 500)
                    return ($Port -eq 18004)
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $state = [ordered]@{
                    schemaVersion = 1
                    configurations = @()
                    servers = @(
                        [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; containerName = "itl-trade-code"; hostPort = 18100; url = "http://host-a:18100/mcp"; image = "image-code"; sourceFingerprint = "fp-code"; reportHash = "hash-code"; indexedAt = "2026-07-05T00:00:00Z" },
                        [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-graph"; containerName = "itl-trade-graph"; hostPort = 18101; url = "http://host-a:18101/mcp"; image = "image-graph"; sourceFingerprint = "fp-graph"; reportHash = "hash-graph"; indexedAt = "2026-07-05T01:00:00Z" },
                        [ordered]@{ id = "docs"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-docs"; containerName = "itl-1c-docs"; hostPort = 18000; url = "http://host-a:18000/mcp"; image = "image-docs" },
                        [ordered]@{ id = "ssl"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-ssl"; containerName = "itl-1c-ssl"; hostPort = 18004; url = "http://host-a:18004/mcp"; image = "image-ssl" },
                        [ordered]@{ id = "syntax"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-syntax"; containerName = "itl-1c-syntax"; hostPort = 18003; url = "http://host-a:18003/mcp"; image = "image-syntax" }
                    )
                }
                Write-HostState -Config $hostConfig -State $state
                Write-MergedRegistryPayload -Config $hostConfig -RegistryPath $registryPath -PublishedAt "2026-07-05T00:00:00Z"

                $updatedState = Read-HostState -Config $hostConfig
                $registry = Read-JsonFile -Path $registryPath
                $stateServers = @($updatedState.servers)
                $registryServers = @($registry.servers | Where-Object { $_.hostId -eq "host-a" })

                ($stateServers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).status | Should -Be "stopped"
                ($stateServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).status | Should -Be "unreachable"
                ($stateServers | Where-Object { $_.id -eq "docs" } | Select-Object -First 1).status | Should -Be "missing"
                ($stateServers | Where-Object { $_.id -eq "ssl" } | Select-Object -First 1).status | Should -Be "running"
                ($stateServers | Where-Object { $_.id -eq "syntax" } | Select-Object -First 1).status | Should -Be "unknown"

                ($registryServers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).status | Should -Be "stopped"
                ($registryServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).status | Should -Be "unreachable"
                ($registryServers | Where-Object { $_.id -eq "docs" } | Select-Object -First 1).status | Should -Be "missing"
                ($registryServers | Where-Object { $_.id -eq "ssl" } | Select-Object -First 1).status | Should -Be "running"
                ($registryServers | Where-Object { $_.id -eq "syntax" } | Select-Object -First 1).status | Should -Be "unknown"
                ($registryServers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).clientNames.aiRules1c | Should -Be "1c-code-metadata-mcp"
                ($registryServers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).functionalStatus | Should -Be "not-probed"
                ($registryServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).sourceFingerprint | Should -Be "fp-graph"
                ($registryServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).reportHash | Should -Be "hash-graph"
                ($registryServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).indexedAt | Should -Be "2026-07-05T01:00:00Z"
                @($script:PublishDockerCalls | Where-Object { $_ -match "checked:| start | run | compose up" }).Count | Should -Be 0
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "starts existing standalone Docker containers through timeout wrappers" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-docker-timeout-wrapper-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostDockerWrapperCalls = New-Object System.Collections.Generic.List[string]
                function Invoke-DockerCommandCapture {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker command")
                    $script:HostDockerWrapperCalls.Add("capture:${TimeoutSec}:${Description}:$($Arguments -join ' ')")
                    return $(if ($script:HostDockerExisting) { @("itl-1c-ssl") } else { @() })
                }
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker command")
                    $script:HostDockerWrapperCalls.Add("checked:${TimeoutSec}:${Description}:$($Arguments -join ' ')")
                }
                function Ensure-ServerDockerImageAvailable { param([object]$Server, [string]$Image) }

                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{ id = "ssl"; embedding = $false }
                $runtime = [pscustomobject]@{
                    containerName = "itl-1c-ssl"
                    hostPort = 18004
                    internalPort = 8008
                    image = "fixture"
                    url = "http://localhost:18004/mcp"
                }
                $script:HostDockerExisting = $true
                Start-DockerServer -Config $hostConfig -Server $server -Runtime $runtime

                $calls = @($script:HostDockerWrapperCalls)
                $calls[0] | Should -Match "^capture:60:docker ps for itl-1c-ssl:"
                $calls[1] | Should -Be "checked:60:docker restart policy itl-1c-ssl:update --restart unless-stopped itl-1c-ssl"
                $calls[2] | Should -Be "checked:120:docker start itl-1c-ssl:start itl-1c-ssl"

                $script:HostDockerExisting = $false
                $runtime.containerName = "itl-1c-ssl-new"
                Start-DockerServer -Config $hostConfig -Server $server -Runtime $runtime
                (@($script:HostDockerWrapperCalls) -join "|") | Should -Match "run -d --restart unless-stopped --name itl-1c-ssl-new"
                Remove-Variable -Scope Script -Name HostDockerWrapperCalls -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name HostDockerExisting -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "checks standalone embedding readiness by configured model id" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-embedding-ready-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                enabledServers = [ordered]@{ global = @(); project = @() }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $smallResponse = [pscustomobject]@{
                    data = @([pscustomobject]@{ id = "intfloat/multilingual-e5-small" })
                }
                $baseResponse = [pscustomobject]@{
                    data = @([pscustomobject]@{ id = "intfloat/multilingual-e5-base" })
                }

                Test-HostEmbeddingModelPresent -Response $smallResponse -Model "intfloat/multilingual-e5-base" | Should -Be $false
                Test-HostEmbeddingModelPresent -Response $baseResponse -Model "intfloat/multilingual-e5-base" | Should -Be $true
                Get-HostEmbeddingModelsUri -ApiBase "http://host.docker.internal:19000/v1" | Should -Be "http://127.0.0.1:19000/v1/models"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "requires and propagates standalone host embedding.model" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-embedding-model-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "intfloat/multilingual-e5-base"
                }
                enabledServers = [ordered]@{ global = @(); project = @() }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $missingModelConfig = [pscustomobject]@{
                    embedding = [pscustomobject]@{
                        apiBase = "http://host.docker.internal:19000/v1"
                        apiKey = "lm-studio"
                    }
                }
                { Get-HostEmbeddingSettings -Config $missingModelConfig } | Should -Throw "*embedding.model is required*"

                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{
                    id = "code"
                    env = @([ordered]@{ name = "OPENAI_MODEL"; embedding = "model"; required = $true })
                }

                $envValues = Resolve-ServerEnv -Config $hostConfig -Server $server

                $envValues["OPENAI_MODEL"] | Should -Be "intfloat/multilingual-e5-base"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "fails clearly before container start when local standalone embedding needs lms and lms is missing" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-missing-lms-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "intfloat/multilingual-e5-base"
                }
                enabledServers = [ordered]@{ global = @(); project = @() }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                function Test-HostEmbeddingEndpointReady {
                    param([string]$ApiBase, [string]$Model)
                    return $false
                }
                function Get-HostLmsCommand {
                    return $null
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $manifest = [pscustomobject]@{
                    servers = @([pscustomobject]@{ id = "code"; scope = "project"; embedding = $true })
                }

                {
                    Ensure-HostEmbeddingModel -Config $hostConfig -Manifest $manifest -GlobalServerIds @() -ProjectServerIds @("code")
                } | Should -Throw "*needs LM Studio CLI 'lms'*"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "loads missing standalone embedding model through lms before declaring readiness" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-lms-bootstrap-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "intfloat/multilingual-e5-base"
                }
                enabledServers = [ordered]@{ global = @(); project = @() }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostLmsBootstrapCalls = New-Object System.Collections.Generic.List[string]
                $script:HostLmsBootstrapProbeCount = 0
                function Test-HostEmbeddingEndpointReady {
                    param([string]$ApiBase, [string]$Model)
                    $script:HostLmsBootstrapProbeCount++
                    return ($script:HostLmsBootstrapProbeCount -gt 1)
                }
                function Get-HostLmsCommand {
                    return [pscustomobject]@{ Source = "lms" }
                }
                function Invoke-HostLmsCommand {
                    param([string[]]$Arguments)
                    $script:HostLmsBootstrapCalls.Add(($Arguments -join " "))
                    return [pscustomobject]@{ exitCode = 0; output = "" }
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $manifest = [pscustomobject]@{
                    servers = @([pscustomobject]@{ id = "code"; scope = "project"; embedding = $true })
                }

                Ensure-HostEmbeddingModel -Config $hostConfig -Manifest $manifest -GlobalServerIds @() -ProjectServerIds @("code")

                $calls = @($script:HostLmsBootstrapCalls)
                $calls.Count | Should -Be 3
                $calls[0] | Should -Be "get intfloat/multilingual-e5-base"
                $calls[1] | Should -Be "load intfloat/multilingual-e5-base"
                $calls[2] | Should -Be "server start --port 19000"
                Remove-Variable -Scope Script -Name HostLmsBootstrapCalls -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name HostLmsBootstrapProbeCount -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "bootstraps standalone embedding before starting embedding-dependent servers" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-bootstrap-order-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "intfloat/multilingual-e5-base"
                }
                enabledServers = [ordered]@{ global = @(); project = @("code") }
                configurations = @([ordered]@{ configId = "trade" })
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostBootstrapTestEvents = New-Object System.Collections.Generic.List[string]
                function Add-HostBootstrapTestEvent {
                    param([string]$Name)
                    $script:HostBootstrapTestEvents.Add($Name)
                }
                function Ensure-HostPrerequisites {
                    param([object]$Config)
                    Add-HostBootstrapTestEvent -Name "prerequisites"
                }
                function Ensure-Distribution {
                    param([object]$Config)
                    Add-HostBootstrapTestEvent -Name "distribution"
                }
                function Read-DistributionManifest {
                    param([object]$Config)
                    Add-HostBootstrapTestEvent -Name "manifest"
                    return [pscustomobject]@{
                        servers = @([pscustomobject]@{
                            id = "code"
                            scope = "project"
                            embedding = $true
                            internalPort = 8000
                            image = "fixture-code-image:latest"
                        })
                    }
                }
                function Ensure-HostEmbeddingModel {
                    param(
                        [object]$Config,
                        [object]$Manifest,
                        [string[]]$GlobalServerIds,
                        [string[]]$ProjectServerIds
                    )
                    Add-HostBootstrapTestEvent -Name "embedding"
                }
                function Refresh-Configuration {
                    param([object]$Config, [object]$Configuration)
                    Add-HostBootstrapTestEvent -Name "refresh"
                    return [pscustomobject]@{
                        configId = "trade"
                        sourceRoot = (Join-Path $tempRoot "source")
                        mainConfigPath = "src/cf"
                        metadataRoot = (Join-Path $tempRoot "metadata")
                        configurationName = "Trade"
                        configurationVersion = "1.0"
                        sourceCommit = "fixture"
                        sourceFingerprint = "fixture"
                        reportHash = "fixture"
                        indexedAt = "2026-07-05T00:00:00Z"
                    }
                }
                function Start-DockerServer {
                    param([object]$Config, [object]$Server, [object]$Runtime, [object]$ConfigState = $null)
                    Add-HostBootstrapTestEvent -Name "start"
                }
                function Write-HostState {
                    param([object]$Config, [object]$State)
                    Add-HostBootstrapTestEvent -Name "state"
                }

                $hostConfig = Read-JsonFile -Path $configPath
                Start-HostServers -Config $hostConfig

                $events = @($script:HostBootstrapTestEvents)
                $events | Should -Contain "embedding"
                $events | Should -Contain "start"
                [array]::IndexOf($events, "embedding") | Should -BeLessThan ([array]::IndexOf($events, "start"))
                Remove-Variable -Scope Script -Name HostBootstrapTestEvents -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "indexes only changed fresh dump inputs and advances code and graph freshness together" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-nightly-index-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                stateRoot = (Join-Path $tempRoot "state")
                configurations = @([ordered]@{
                    configId = "trade"
                    sourcePath = (Join-Path $tempRoot "source")
                    mainConfigPath = "src/cf"
                    dump = [ordered]@{ sourceInfoBasePath = "fixture" }
                })
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $configuration = @($hostConfig.configurations)[0]
                $oldInput = Get-Sha256Text -Value "source=old-content|report=old-report"
                Write-HostState -Config $hostConfig -State ([ordered]@{
                    schemaVersion = 1
                    configurations = @([ordered]@{
                        configId = "trade"
                        sourceContentFingerprint = "old-content"
                        reportHash = "old-report"
                        indexInputFingerprint = $oldInput
                        indexedAt = "2026-07-05T00:00:00Z"
                    })
                    servers = @(
                        [ordered]@{ id = "code"; scope = "project"; configId = "trade"; hostPort = 18100; configurationName = "Trade Old"; configurationVersion = "1.0"; indexedAt = "2026-07-05T00:00:00Z" },
                        [ordered]@{ id = "graph"; scope = "project"; configId = "trade"; hostPort = 18101; configurationName = "Trade Old"; configurationVersion = "1.0"; indexedAt = "2026-07-05T00:00:00Z" }
                    )
                })
                $script:NightlyIndexEvents = New-Object System.Collections.Generic.List[string]
                $script:NightlySourceContent = "new-content"
                $script:NightlyReportHash = "new-report"
                $script:NightlyGraphFailure = $false
                function Invoke-HostConfigDumpHelper {
                    param([string]$ResolvedConfigPath, [string]$TargetConfigId)
                    $script:NightlyIndexEvents.Add("dump:$TargetConfigId")
                }
                function Refresh-Configuration {
                    param([object]$Config, [object]$Configuration)
                    $script:NightlyIndexEvents.Add("report:$([string]$Configuration.configId)")
                    return [pscustomobject]@{
                        configId = "trade"
                        title = "Trade"
                        configurationName = "Trade Current"
                        configurationVersion = "2.0"
                        sourceCommit = "fresh-source"
                        sourceFingerprint = "source-with-cursor"
                        sourceContentFingerprint = $script:NightlySourceContent
                        reportHash = $script:NightlyReportHash
                        indexedAt = "premature-report-time"
                    }
                }
                function Invoke-CodeIncrementalIndex {
                    param([object]$Server, [string]$ConfigId, [object]$Settings)
                    $script:NightlyIndexEvents.Add("code:$ConfigId")
                }
                function Invoke-GraphIncrementalIndex {
                    param([object]$Config, [object]$Server, [string]$ConfigId, [object]$Settings)
                    $script:NightlyIndexEvents.Add("graph:$ConfigId")
                    if ($script:NightlyGraphFailure) { throw "fixture graph indexing failure" }
                }
                $settings = [pscustomobject]@{ timeoutMinutes = 60; pollSeconds = 5 }

                $result = Invoke-NightlyConfigurationIndex -Config $hostConfig -Configuration $configuration -Settings $settings

                $result.status | Should -Be "succeeded"
                @($script:NightlyIndexEvents) | Should -Be @("dump:trade", "report:trade", "code:trade", "graph:trade")
                $state = Read-HostState -Config $hostConfig
                $configState = @($state.configurations | Where-Object configId -eq "trade")[0]
                $codeState = @($state.servers | Where-Object id -eq "code")[0]
                $graphState = @($state.servers | Where-Object id -eq "graph")[0]
                $configState.nightlyIndexStatus | Should -Be "succeeded"
                $configState.indexedAt | Should -Not -Be "premature-report-time"
                $configState.indexedAt | Should -Be $codeState.indexedAt
                $codeState.indexedAt | Should -Be $graphState.indexedAt
                $codeState.indexInputFingerprint | Should -Be $configState.indexInputFingerprint
                $graphState.sourceContentFingerprint | Should -Be "new-content"
                $codeState.configurationName | Should -Be "Trade Current"
                $codeState.configurationVersion | Should -Be "2.0"
                $graphState.configurationVersion | Should -Be "2.0"
                $graphState.sourceCommit | Should -Be "fresh-source"

                $script:NightlyIndexEvents.Clear()
                $unchanged = Invoke-NightlyConfigurationIndex -Config $hostConfig -Configuration $configuration -Settings $settings
                $unchanged.status | Should -Be "unchanged"
                @($script:NightlyIndexEvents) | Should -Be @("dump:trade", "report:trade")
                $unchangedState = Read-HostState -Config $hostConfig
                @($unchangedState.configurations | Where-Object configId -eq "trade")[0].indexedAt | Should -Be $configState.indexedAt

                $script:NightlySourceContent = "failed-content"
                $script:NightlyReportHash = "failed-report"
                $script:NightlyGraphFailure = $true
                $script:NightlyIndexEvents.Clear()
                { Invoke-NightlyConfigurationIndex -Config $hostConfig -Configuration $configuration -Settings $settings } | Should -Throw "*fixture graph indexing failure*"
                @($script:NightlyIndexEvents) | Should -Be @("dump:trade", "report:trade", "code:trade", "graph:trade")
                $failedState = Read-HostState -Config $hostConfig
                $failedConfig = @($failedState.configurations | Where-Object configId -eq "trade")[0]
                $failedConfig.nightlyIndexStatus | Should -Be "failed"
                $failedConfig.indexedAt | Should -Be $configState.indexedAt
                $failedConfig.indexInputFingerprint | Should -Be $configState.indexInputFingerprint
                @($failedState.servers | Where-Object id -eq "code")[0].indexInputFingerprint | Should -Be $configState.indexInputFingerprint
                @($failedState.servers | Where-Object id -eq "graph")[0].indexInputFingerprint | Should -Be $configState.indexInputFingerprint

                $script:NightlyGraphFailure = $false
                $script:NightlyIndexEvents.Clear()
                $retry = Invoke-NightlyConfigurationIndex -Config $hostConfig -Configuration $configuration -Settings $settings
                $retry.status | Should -Be "succeeded"
                @($script:NightlyIndexEvents) | Should -Be @("dump:trade", "report:trade", "code:trade", "graph:trade")
                Remove-Variable -Scope Script -Name NightlyIndexEvents -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name NightlySourceContent -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name NightlyReportHash -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name NightlyGraphFailure -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "refuses graph incremental restart unless reset is disabled and restarts only the MCP service" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-graph-incremental-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $runtimePath = Join-Path $tempRoot "runtime"
        try {
            New-Item -ItemType Directory -Force -Path $runtimePath | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1}'
            Set-Content -LiteralPath (Join-Path $runtimePath "docker-compose.yml") -Encoding UTF8 -Value "services:`n  mcp-app:`n    image: fixture"
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = [pscustomobject]@{ graphMetadataSearchServer = [pscustomobject]@{ composeService = "mcp-app" } }
                $server = [pscustomobject]@{ runtimePath = $runtimePath; composeProject = "fixture-graph"; hostPort = 18101 }
                Set-Content -LiteralPath (Join-Path $runtimePath ".env") -Encoding UTF8 -Value "RESET_DATABASE=true`nAUTO_UPDATE_ON_STARTUP=true`n"
                { Restart-GraphForIncrementalIndex -Config $hostConfig -Server $server -ConfigId "trade" } | Should -Throw "*RESET_DATABASE=false*"

                Set-Content -LiteralPath (Join-Path $runtimePath ".env") -Encoding UTF8 -Value "RESET_DATABASE=false`nAUTO_UPDATE_ON_STARTUP=true`n"
                $script:GraphIncrementalDockerCalls = New-Object System.Collections.Generic.List[string]
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec, [string]$Description)
                    $script:GraphIncrementalDockerCalls.Add(($Arguments -join " "))
                }
                function Test-HostTcpPortOpen { param([int]$Port, [int]$TimeoutMilliseconds); return $true }
                Restart-GraphForIncrementalIndex -Config $hostConfig -Server $server -ConfigId "trade"
                @($script:GraphIncrementalDockerCalls).Count | Should -Be 1
                $script:GraphIncrementalDockerCalls[0] | Should -Match "compose -p fixture-graph"
                $script:GraphIncrementalDockerCalls[0] | Should -Match "restart mcp-app$"
                $script:GraphIncrementalDockerCalls[0] | Should -Not -Match "down|neo4j|force-recreate"
                Remove-Variable -Scope Script -Name GraphIncrementalDockerCalls -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps config dump diagnostics out of nightly result objects" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-dump-output-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1}'
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                function powershell {
                    Write-Output "child dump diagnostic"
                    $global:LASTEXITCODE = 0
                }
                try {
                    $result = @(Invoke-HostConfigDumpHelper -ResolvedConfigPath $configPath -TargetConfigId "trade")
                    $result.Count | Should -Be 0
                } finally {
                    Remove-Item function:\powershell -ErrorAction SilentlyContinue
                }
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "waits for graph MCP readiness after the container port opens" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-graph-ready-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"schemaVersion":1}'
            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:GraphReadyAttempts = 0
                $script:GraphReadyWaitCalls = 0
                function Restart-GraphForIncrementalIndex {
                    param([object]$Config, [object]$Server, [string]$ConfigId)
                }
                function Open-HostMcpConnection {
                    param([string]$Url)
                    $script:GraphReadyAttempts++
                    if ($script:GraphReadyAttempts -lt 3) { throw "fixture startup connection closed" }
                    return [pscustomobject]@{ url = $Url; headers = @{}; nextId = 2 }
                }
                function Start-Sleep { param([int]$Seconds) }
                function Wait-HostMcpIndexCompletion {
                    param([object]$Connection, [string]$StatusTool, [string]$ServerId, [string]$ConfigId, [int]$TimeoutMinutes, [int]$PollSeconds)
                    $script:GraphReadyWaitCalls++
                    $Connection.url | Should -Be "http://127.0.0.1:18101/mcp"
                    $StatusTool | Should -Be "get_indexing_status"
                }

                $server = [pscustomobject]@{ hostPort = 18101 }
                $settings = [pscustomobject]@{ timeoutMinutes = 60; pollSeconds = 5 }
                Invoke-GraphIncrementalIndex -Config ([pscustomobject]@{}) -Server $server -ConfigId "trade" -Settings $settings

                $script:GraphReadyAttempts | Should -Be 3
                $script:GraphReadyWaitCalls | Should -Be 1
                Remove-Variable -Scope Script -Name GraphReadyAttempts -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name GraphReadyWaitCalls -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "reindexes only embedding-dependent standalone servers with stable port indexes" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-reindex-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
                enabledServers = [ordered]@{
                    global = @("ssl", "docs")
                    project = @("codechecker", "code", "graph")
                }
                configurations = @([ordered]@{ configId = "trade" })
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostReindexTestEvents = New-Object System.Collections.Generic.List[string]
                function Add-HostReindexTestEvent {
                    param([string]$Name)
                    $script:HostReindexTestEvents.Add($Name)
                }
                function Ensure-HostPrerequisites {
                    param([object]$Config)
                    Add-HostReindexTestEvent -Name "prerequisites"
                }
                function Ensure-Distribution {
                    param([object]$Config)
                    Add-HostReindexTestEvent -Name "distribution"
                }
                function Read-DistributionManifest {
                    param([object]$Config)
                    Add-HostReindexTestEvent -Name "manifest"
                    return [pscustomobject]@{
                        servers = @(
                            [pscustomobject]@{ id = "ssl"; scope = "global"; embedding = $false; internalPort = 8008; image = "fixture-ssl:latest" },
                            [pscustomobject]@{ id = "docs"; scope = "global"; embedding = $true; internalPort = 8001; image = "fixture-docs:latest"; env = @([ordered]@{ name = "RESET_CACHE"; value = "true" }) },
                            [pscustomobject]@{ id = "codechecker"; scope = "project"; embedding = $false; internalPort = 8002; image = "fixture-codechecker:latest" },
                            [pscustomobject]@{ id = "code"; scope = "project"; embedding = $true; internalPort = 8000; image = "fixture-code:latest" },
                            [pscustomobject]@{ id = "graph"; scope = "project"; embedding = $true; internalPort = 8006; image = "fixture-graph:latest"; compose = $true }
                        )
                    }
                }
                function Ensure-HostEmbeddingModel {
                    param(
                        [object]$Config,
                        [object]$Manifest,
                        [string[]]$GlobalServerIds,
                        [string[]]$ProjectServerIds
                    )
                    Add-HostReindexTestEvent -Name "embedding"
                }
                function Refresh-Configuration {
                    param([object]$Config, [object]$Configuration)
                    Add-HostReindexTestEvent -Name "refresh:$([string](Get-ObjectValue -Object $Configuration -Name 'configId' -Default ''))"
                    return [pscustomobject]@{
                        configId = "trade"
                        sourceRoot = (Join-Path $tempRoot "source")
                        mainConfigPath = "src/cf"
                        metadataRoot = (Join-Path $tempRoot "metadata")
                        configurationName = "Trade"
                        configurationVersion = "1.0"
                        sourceCommit = "fixture"
                        sourceFingerprint = "fixture-fingerprint"
                        reportHash = "fixture-report"
                        indexedAt = "2026-07-05T00:00:00Z"
                    }
                }
                function Start-DockerServer {
                    param(
                        [object]$Config,
                        [object]$Server,
                        [object]$Runtime,
                        [object]$ConfigState = $null,
                        [switch]$Recreate,
                        [switch]$ForceResetDatabase
                    )
                    Add-HostReindexTestEvent -Name "docker:$($Runtime.id):$($Runtime.hostPort):recreate=$($Recreate.IsPresent):reset=$($ForceResetDatabase.IsPresent)"
                }
                function Start-ComposeServer {
                    param(
                        [object]$Config,
                        [object]$Server,
                        [object]$Runtime,
                        [object]$ConfigState,
                        [switch]$Recreate,
                        [switch]$ForceResetDatabase
                    )
                    Add-HostReindexTestEvent -Name "compose:$($Runtime.id):$($Runtime.hostPort):recreate=$($Recreate.IsPresent):reset=$($ForceResetDatabase.IsPresent)"
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $initialState = [ordered]@{
                    schemaVersion = 1
                    updatedAt = "2026-07-05T00:00:00Z"
                    configurations = @()
                    servers = @([ordered]@{
                        id = "ssl"
                        scope = "global"
                        name = "itl-ssl"
                        containerName = "itl-ssl"
                        health = "running"
                    }, [ordered]@{
                        id = "docs"
                        scope = "global"
                        name = "itl-docs"
                        containerName = "itl-docs"
                        health = "running"
                    })
                }
                Write-HostState -Config $hostConfig -State $initialState

                Invoke-HostReindex -Config $hostConfig

                $events = @($script:HostReindexTestEvents)
                $events | Should -Contain "embedding"
                $events | Should -Contain "refresh:trade"
                $events | Should -Contain "docker:code:18101:recreate=True:reset=True"
                $events | Should -Contain "compose:graph:18102:recreate=True:reset=True"
                ($events -join "|") | Should -Not -Match "docker:ssl"
                ($events -join "|") | Should -Not -Match "docker:docs"
                ($events -join "|") | Should -Not -Match "docker:codechecker"

                $state = Read-HostState -Config $hostConfig
                @($state.configurations | Where-Object { $_.configId -eq "trade" }).Count | Should -Be 1
                @($state.servers | Where-Object { $_.id -eq "ssl" }).Count | Should -Be 1
                @($state.servers | Where-Object { $_.id -eq "docs" }).Count | Should -Be 1
                @($state.servers | Where-Object { $_.id -eq "code" }).Count | Should -Be 1
                @($state.servers | Where-Object { $_.id -eq "graph" }).Count | Should -Be 1
                Remove-Variable -Scope Script -Name HostReindexTestEvents -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "normalizes unscoped local code and graph manifest entries to project scope" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-local-scope-test-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $legacyGraph = [pscustomobject]@{ id = "graph" }
                $branchGraph = [pscustomobject]@{ id = "graph"; scope = "branch" }

                Get-Vibecoding1cMcpServerScope -Server $legacyGraph | Should -Be "project"
                Get-Vibecoding1cMcpServerScope -Server $branchGraph | Should -Be "branch"
                Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $legacyGraph | Should -Be $true
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "falls back local graph chat OpenAI settings to embedding settings" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-local-graph-openai-test-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $localHome = Join-Path $tempRoot "local-home"
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $localHome | Out-Null
            $state = [ordered]@{
                schemaVersion = 1
                model = [ordered]@{
                    apiBase = "http://127.0.0.1:19000/v1"
                    apiKey = "lm-studio"
                    model = "fixture-embedding-model"
                    ready = $true
                }
                servers = @()
                updatedAt = "2026-07-05T00:00:00Z"
            }
            Set-Content -LiteralPath (Join-Path $localHome "state.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $server = [pscustomobject]@{
                    id = "graph"
                    env = @(
                        [ordered]@{ name = "OPENAI_API_KEY"; from = "CHAT_API_KEY"; required = $false },
                        [ordered]@{ name = "OPENAI_API_BASE"; from = "CHAT_API_BASE"; required = $false },
                        [ordered]@{ name = "OPENAI_MODEL"; from = "CHAT_MODEL"; required = $false }
                    )
                }
                $runtime = [pscustomobject]@{ projectSlug = "fixture"; branchSlug = "master" }
                $configContext = [pscustomobject]@{ values = [ordered]@{} }

                $envResult = Resolve-Vibecoding1cMcpEnvironment -Server $server -Runtime $runtime -ConfigContext $configContext

                $envResult.values["OPENAI_API_KEY"] | Should -Be "lm-studio"
                $envResult.values["OPENAI_API_BASE"] | Should -Be "http://127.0.0.1:19000/v1"
                $envResult.values["OPENAI_MODEL"] | Should -Be "fixture-embedding-model"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
