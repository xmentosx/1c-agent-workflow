Describe "ITL auxiliary contour contract" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath

        function New-AuxiliaryFixture {
            param([object]$AuxiliaryContours)
            $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-auxiliary-Путь с пробелом-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path (Join-Path $root ".agent-1c"), (Join-Path $root "src\cf"), (Join-Path $root "src\configs\exchange\cf"), (Join-Path $root "tests\features"), (Join-Path $root "tests\auxiliary\exchange") | Out-Null
            Set-Content -LiteralPath (Join-Path $root "src\cf\Configuration.xml") -Encoding UTF8 -Value "primary"
            Set-Content -LiteralPath (Join-Path $root "src\configs\exchange\cf\Configuration.xml") -Encoding UTF8 -Value "auxiliary"
            Set-Content -LiteralPath (Join-Path $root "tests\features\smoke.feature") -Encoding UTF8 -Value "Функционал: smoke"
            Set-Content -LiteralPath (Join-Path $root "tests\auxiliary\exchange\smoke.feature") -Encoding UTF8 -Value "Функционал: auxiliary smoke"
            $config = [ordered]@{
                schemaVersion = 1
                auxiliaryContours = $AuxiliaryContours
                aiRules = [ordered]@{ tools = @("codex") }
            }
            Set-Content -LiteralPath (Join-Path $root ".agent-1c\project.json") -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 12) + "`n")
            & git -C $root init *> $null
            & git -C $root config user.email "test@example.com"
            & git -C $root config user.name "Test User"
            & git -C $root add .
            & git -C $root commit -m "fixture" *> $null
            & git -C $root branch -M itldev/auxiliary-fixture
            return $root
        }
    }

    It "keeps the feature optional and byte-preserves conventional extra configuration trees" {
        $project = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        @($project.auxiliaryContours.PSObject.Properties).Count | Should -Be 0
        $attributes = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            @(Get-OneCSourceGitAttributesManagedLines)
        }
        $attributes | Should -Contain "src/cf/** -text"
        $attributes | Should -Contain "src/cfe/** -text"
        $attributes | Should -Contain "src/configs/** -text"
    }

    It "resolves a managed read-write contour in a Cyrillic path with spaces" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{
                baseMode = "managed-file"
                sourceMode = "read-write"
                configurationPath = "src/configs/exchange/cf"
                tests = [ordered]@{ includePrimary = $true; path = "tests/auxiliary/exchange" }
                mcp = [ordered]@{ roctup = $true; vanessaUi = $true }
            }
        })
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $contour = Get-AuxiliaryContour -Name "exchange"
                $connection = Get-AuxiliaryContourConnection -Contour $contour
                [pscustomobject]@{ contour = $contour; connection = $connection; statePath = Get-AuxiliaryContourStatePath -Contour $contour }
            }
            $result.contour.sourceMode | Should -Be "read-write"
            $result.contour.mcpRoctup | Should -BeTrue
            $result.connection.kind | Should -Be "file"
            $result.connection.path | Should -Match ([regex]::Escape("Путь с пробелом"))
            $result.statePath | Should -Match 'auxiliary-contours'
            $result.statePath | Should -Match 'itldev-auxiliary-fixture'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "rejects a read-write owner for src/cf and duplicate read-write owners" {
        foreach ($contours in @(
            [ordered]@{ bad = [ordered]@{ baseMode = "managed-file"; sourceMode = "read-write"; configurationPath = "src/cf" } },
            [ordered]@{
                one = [ordered]@{ baseMode = "managed-file"; sourceMode = "read-write"; configurationPath = "src/configs/exchange/cf" }
                two = [ordered]@{ baseMode = "managed-file"; sourceMode = "read-write"; configurationPath = "src/configs/exchange/cf" }
            }
        )) {
            $root = New-AuxiliaryFixture -AuxiliaryContours $contours
            try {
                { & { . $HelperPath -ProjectRoot $root -Action help *> $null; Get-AuxiliaryContourDefinitions } } | Should -Throw 'ITL_AUXILIARY_*'
            } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "blocks configuration mutation for an attached read-only base before starting 1C" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            server = [ordered]@{ baseMode = "attached-readonly"; connectionRef = "SERVER_TEST"; configurationPath = "src/cf" }
        })
        try {
            $attachedBase = Join-Path $root "Присоединенная база"
            New-Item -ItemType Directory -Force -Path $attachedBase | Out-Null
            Set-Content -LiteralPath (Join-Path $attachedBase "1Cv8.1CD") -Encoding ASCII -Value "fixture"
            Set-Content -LiteralPath (Join-Path $root ".dev.env") -Encoding UTF8 -Value @(
                "ITL_AUX_SERVER_TEST_INFOBASE_KIND=file"
                "ITL_AUX_SERVER_TEST_INFOBASE_PATH=$attachedBase"
            )
            $probe = Invoke-Agent1cEntrypointProbe `
                -ProbeId 'auxiliary-update-readonly' `
                -HelperPath $HelperPath `
                -ProjectRoot $root `
                -Action 'update-auxiliary-contour' `
                -Arguments @{ AuxiliaryContourName = 'server' }
            $probe.exitCode | Should -Be 1
            $probe.combinedText | Should -Match 'ITL_AUXILIARY_READONLY'
            Test-Path -LiteralPath (Join-Path $root ".agent-1c\auxiliary-contours") | Should -BeFalse
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "adds compact per-contour MCP endpoints through wrappers without changing primary endpoint arguments" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{ baseMode = "managed-file"; configurationPath = "src/cf"; mcp = [ordered]@{ roctup = $true; vanessaUi = $true } }
        })
        $oldExe = [Environment]::GetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE", "Process")
        try {
            $exe = Join-Path $root "itl-ondemand-mcp.exe"
            Set-Content -LiteralPath $exe -Encoding ASCII -Value "fixture"
            [Environment]::SetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE", $exe, "Process")
            { & { . $HelperPath -ProjectRoot $root -Action help *> $null; Get-ItlOnDemandMcpEndpointDescriptors } } |
                Should -Throw '*ITL_ONDEMAND_FACADE_OVERRIDE_SHA_MISMATCH*'
            $fixtureLock = Get-Content -LiteralPath (Join-Path $RepoRoot 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $fixtureLock.dependencies.itlOndemandMcp.sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
            New-Item -ItemType Directory -Path (Join-Path $root 'templates') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'templates/dependency-lock.json') -Encoding UTF8 -Value ($fixtureLock | ConvertTo-Json -Depth 30)
            $endpoints = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-ItlOnDemandMcpEndpointDescriptors) }
            @($endpoints).Count | Should -Be 4
            @($endpoints.name) | Should -Contain "itl-roctup-data"
            @($endpoints.name) | Should -Contain "itl-vanessa-ui"
            @($endpoints.name) | Should -Contain "itl-roctup-aux-exchange"
            @($endpoints.name) | Should -Contain "itl-vanessa-ui-aux-exchange"
            foreach ($primary in @($endpoints | Where-Object { $_.name -in @("itl-roctup-data", "itl-vanessa-ui") })) {
                ($primary.args -join ' ') | Should -Not -Match '--contour'
                $helperIndex = [Array]::IndexOf([object[]]$primary.args, "--helper")
                [string]$primary.args[$helperIndex + 1] | Should -Match 'scripts[\\/]agent-1c\.ps1$'
            }
            foreach ($auxiliary in @($endpoints | Where-Object { $_.name -like '*-aux-*' })) {
                $helperIndex = [Array]::IndexOf([object[]]$auxiliary.args, "--helper")
                $wrapper = [string]$auxiliary.args[$helperIndex + 1]
                Test-Path -LiteralPath $wrapper -PathType Leaf | Should -BeTrue
                (Get-Content -LiteralPath $wrapper -Raw -Encoding UTF8) | Should -Match 'InternalOnDemandAuxiliaryContour.*exchange'
            }
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE", $oldExe, "Process")
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps schema 1 TestClient manifests unchanged and accepts contour routing only in schema 2" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{ baseMode = "managed-file"; configurationPath = "src/cf" }
        })
        try {
            $manifestPath = Join-Path $root "tests\clients.json"
            $configPath = Join-Path $root ".agent-1c\project.json"
            $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $config | Add-Member -NotePropertyName vanessaAutomation -NotePropertyValue ([pscustomobject]@{ testClientManifestPath = "tests/clients.json" }) -Force
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 12) + "`n")
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value '{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"main","contour":"exchange"}]}'
            { & { . $HelperPath -ProjectRoot $root -Action help *> $null; Read-VanessaTestClientManifest } } | Should -Throw '*unsupported profile property*contour*'
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value '{"schemaVersion":2,"maxConcurrency":1,"profiles":[{"name":"exchange","contour":"exchange"}]}'
            $manifest = & { . $HelperPath -ProjectRoot $root -Action help *> $null; Read-VanessaTestClientManifest }
            $manifest.profiles[0].contour | Should -Be "exchange"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "resolves schema 2 TestClient profiles to the exact ready contour infobase" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{ baseMode = "managed-file"; configurationPath = "src/cf" }
        })
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $contour = Get-AuxiliaryContour -Name exchange
                $connection = Get-AuxiliaryContourConnection -Contour $contour
                $source = Get-AuxiliaryContourFingerprint -Contour $contour
                Save-AuxiliaryContourState -Contour $contour -Updates @{ readinessStatus = "ready"; connectionIdentityHash = $connection.identityHash; sourceFingerprint = $source.combined; enterpriseNormalizationStatus = "passed"; enterpriseNormalizationProofVersion = 1 } | Out-Null
                $profile = [pscustomobject]@{ name = "Receiver"; contour = "exchange"; user = ""; password = "" }
                Get-VanessaTestClientProfileConnection -Profile $profile -DefaultState ([pscustomobject]@{ infoBaseKind = "file"; devBranchInfoBasePath = (Join-Path $root "primary") })
            }
            $result.contour | Should -Be "exchange"
            $result.kind | Should -Be "file"
            $result.path | Should -Match 'infobases[\\/]auxiliary'
            $result.path | Should -Match 'exchange$'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "projects auxiliary Vanessa runtime identity without inheriting primary credentials or process state" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{ baseMode = "managed-file"; configurationPath = "src/cf" }
        })
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $contour = Get-AuxiliaryContour -Name exchange
                $connection = Get-AuxiliaryContourConnection -Contour $contour
                $source = Get-AuxiliaryContourFingerprint -Contour $contour
                Save-AuxiliaryContourState -Contour $contour -Updates @{ readinessStatus = "ready"; connectionIdentityHash = $connection.identityHash; sourceFingerprint = $source.combined; enterpriseNormalizationStatus = "passed"; enterpriseNormalizationProofVersion = 1 } | Out-Null
                $primary = [pscustomobject]@{
                    devBranchName = "auxiliary-fixture"
                    safeDevBranchName = "auxiliary-fixture"
                    worktreePath = $root
                    stateProjectRoot = $root
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $root "primary")
                    vanessaServiceInfoBasePath = (Join-Path $root "manager")
                    vanessaTestPort = 48100
                    vanessaTestPorts = @(48100)
                    vanessaMcpPid = 12345
                }
                $script:ActiveAuxiliaryVanessaContext = $null
                $normal = Get-VanessaVerificationRuntimeState -State $primary
                $script:ActiveAuxiliaryVanessaContext = [pscustomobject]@{ contour = $contour }
                $runtime = Get-VanessaVerificationRuntimeState -State $primary
                $profile = [pscustomobject]@{ name = "Admin"; contour = "primary"; user = "PrimaryAdmin"; password = "primary-secret" }
                $redirected = Get-VanessaTestClientProfileConnection -Profile $profile -DefaultState $primary
                $profile.contour = "exchange"
                $explicit = Get-VanessaTestClientProfileConnection -Profile $profile -DefaultState $primary
                $script:ActiveAuxiliaryVanessaContext = $null
                $profile.contour = "primary"
                $original = Get-VanessaTestClientProfileConnection -Profile $profile -DefaultState $primary
                [pscustomobject]@{ normal = $normal; primary = $primary; runtime = $runtime; connection = $connection; redirected = $redirected; explicit = $explicit; original = $original }
            }

            [object]::ReferenceEquals($result.normal, $result.primary) | Should -BeTrue
            $result.runtime.devBranchInfoBasePath | Should -BeExactly $result.connection.path
            $result.runtime.vanessaServiceInfoBasePath | Should -BeExactly $result.primary.vanessaServiceInfoBasePath
            $result.runtime.worktreePath | Should -BeExactly $result.primary.worktreePath
            (Get-Member -InputObject $result.runtime -Name vanessaMcpPid) | Should -BeNullOrEmpty
            $result.redirected.user | Should -BeExactly $result.connection.user
            $result.redirected.password | Should -BeExactly $result.connection.password
            $result.explicit.user | Should -BeExactly "PrimaryAdmin"
            $result.explicit.password | Should -BeExactly "primary-secret"
            $result.original.user | Should -BeExactly "PrimaryAdmin"
            $result.original.password | Should -BeExactly "primary-secret"
            $result.primary.devBranchInfoBasePath | Should -Match 'primary$'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "requires exact auxiliary unsafe-action confirmation before a managed-base EPF and reuses only matching proof" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{ baseMode = "managed-file"; configurationPath = "src/cf" }
        })
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $contour = Get-AuxiliaryContour -Name exchange
                $connection = Get-AuxiliaryContourConnection -Contour $contour
                $connection.user = "AuxiliaryAdmin"
                $script:proofState = $null
                $script:interactive = $false
                $script:confirmations = 0
                function Read-AuxiliaryContourState { param($Contour) $script:proofState }
                function Save-AuxiliaryContourState { param($Contour, $Updates) $script:proofState = [pscustomobject]$Updates; $script:proofState }
                function Test-InteractiveInputAvailable { $script:interactive }
                function Confirm-DevBranchUnsafeActionProtection {
                    param($InfoBaseKind, $InfoBasePath, $DevBranchName, $SetupModeOverride, $InfoBaseUserOverride, $InfoBasePasswordOverride)
                    $script:confirmations++
                    if ($InfoBasePath -cne $connection.path -or $InfoBaseUserOverride -cne $connection.user -or $InfoBasePasswordOverride -cne $connection.password) { throw "wrong confirmation target" }
                    [pscustomobject]@{ mode = "manual-confirm"; confirmed = $true; confirmedAt = "2026-09-13T00:00:00Z"; user = $InfoBaseUserOverride }
                }
                $blocked = try { Ensure-AuxiliaryContourUnsafeActionProtection -Contour $contour -Connection $connection; "not-blocked" } catch { $_.Exception.Message }
                $script:interactive = $true
                Ensure-AuxiliaryContourUnsafeActionProtection -Contour $contour -Connection $connection
                Ensure-AuxiliaryContourUnsafeActionProtection -Contour $contour -Connection $connection
                [pscustomobject]@{ blocked = $blocked; confirmations = $script:confirmations; proof = $script:proofState.unsafeActionProtectionProof }
            }

            $result.blocked | Should -Match '^ITL_AUXILIARY_UNSAFE_ACTION_PROTECTION_CONFIRMATION_REQUIRED:'
            $result.blocked | Should -Match 'requiredAction=rerun-update-auxiliary-contour-interactively'
            $result.confirmations | Should -Be 1
            $result.proof.schemaVersion | Should -Be 1
            $result.proof.connectionIdentityHash | Should -Match '^[a-f0-9]{64}$'
            $result.proof.userIdentityHash | Should -Match '^[a-f0-9]{64}$'
            ($result.proof | ConvertTo-Json -Depth 8) | Should -Not -Match 'primary-secret|password'
            $auxiliary = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.auxiliary.ps1") -Raw -Encoding UTF8
            $update = [regex]::Match($auxiliary, '(?s)function Update-AuxiliaryContour \{(?<body>.*?)(?=\nfunction Invoke-AuxiliaryConfigurationDump)').Groups['body'].Value
            $update.IndexOf('Ensure-AuxiliaryContourUnsafeActionProtection') | Should -BeGreaterThan -1
            $update.IndexOf('Ensure-AuxiliaryContourUnsafeActionProtection') | Should -BeLessThan $update.IndexOf('Invoke-DevBranchEnterpriseAutoUpdate')
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "loads a newly created managed base without credentials, then requires a real user before EPF" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{
                baseMode = "managed-file"
                configurationPath = "src/cf"
                extensions = @([ordered]@{ name = "Support"; path = "src/configs/exchange/cfe/Support" })
            }
        })
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $script:auxState = $null
                $script:events = [Collections.Generic.List[string]]::new()
                $script:loadUsers = [Collections.Generic.List[string]]::new()
                $script:allowConfirmation = $false
                $script:connection = Get-AuxiliaryContourConnection -Contour (Get-AuxiliaryContour -Name exchange)
                $script:connection.user = "PreconfiguredUser"
                $Action = "update-auxiliary-contour"
                $AuxiliaryContourName = "exchange"
                function Get-AuxiliaryContourConnection { $script:connection }
                function Ensure-AuxiliaryManagedInfoBase {
                    $script:events.Add("create")
                    New-Item -ItemType Directory -Force -Path $script:connection.path | Out-Null
                    New-Item -ItemType File -Force -Path (Join-Path $script:connection.path "1Cv8.1CD") | Out-Null
                }
                function Get-AuxiliaryContourFingerprint {
                    [pscustomobject]@{ combined = "source-a"; configuration = [pscustomobject]@{ fingerprint = "config-a"; fileCount = 1 }; extensions = @() }
                }
                function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = 'extension-a'; fileCount = 1 } }
                function Read-AuxiliaryContourState { $script:auxState }
                function Save-AuxiliaryContourState {
                    param($Contour, $Updates)
                    $merged = [ordered]@{}
                    if ($script:auxState) { foreach ($property in $script:auxState.PSObject.Properties) { $merged[$property.Name] = $property.Value } }
                    foreach ($key in $Updates.Keys) { $merged[$key] = $Updates[$key] }
                    $script:auxState = [pscustomobject]$merged
                    $script:auxState
                }
                function Stop-AuxiliaryContourRuntimeBeforeMutation { $script:events.Add("drain") }
                function Invoke-ConfigLoadWithFallback {
                    param($InfoBasePath, $InfoBaseKind, $State, $AbsoluteExportPath, $ListFilePath, $FileCount, $ExtensionName, $Mode, $User, $Password)
                    $script:events.Add($(if ($ExtensionName) { "extension" } else { "configuration" }))
                    $script:loadUsers.Add([string]$User)
                    [pscustomobject]@{ configLoadStatus = "passed"; loadModeUsed = "full" }
                }
                function Ensure-AuxiliaryContourUnsafeActionProtection {
                    $script:events.Add("confirm")
                    if (-not $script:allowConfirmation) { throw "ITL_AUXILIARY_UNSAFE_ACTION_PROTECTION_CONFIRMATION_REQUIRED: fixture" }
                }
                function Invoke-DevBranchEnterpriseAutoUpdate {
                    param($State, $User, $Password, $RecoveryAction)
                    $script:events.Add("epf")
                    [pscustomobject]@{ updatedAt = "2026-09-24T00:00:00Z"; resultPath = "result.json"; logPath = "auto-update.log" }
                }
                function Sync-AuxiliaryContourMcpClientConfig {}

                $blocked = try { Update-AuxiliaryContour; "not-blocked" } catch { $_.Exception.Message }
                $blockedState = $script:auxState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
                $blockedEvents = @($script:events)
                $blockedLoadUsers = @($script:loadUsers)
                $script:connection.user = "AuxiliaryAdmin"
                $script:events.Clear()
                $preflightBlocked = try { Update-AuxiliaryContour; "not-blocked" } catch { $_.Exception.Message }
                $preflightEvents = @($script:events)
                $script:allowConfirmation = $true
                $script:events.Clear()
                $script:loadUsers.Clear()
                Update-AuxiliaryContour
                [pscustomobject]@{ blocked = $blocked; blockedState = $blockedState; blockedEvents = $blockedEvents; blockedLoadUsers = $blockedLoadUsers; preflightBlocked = $preflightBlocked; preflightEvents = $preflightEvents; readyState = $script:auxState; readyEvents = @($script:events); readyLoadUsers = @($script:loadUsers) }
            }

            $result.blocked | Should -Match '^ITL_AUXILIARY_UNSAFE_ACTION_PROTECTION_CONFIRMATION_REQUIRED:'
            $result.blocked | Should -Match 'requiredAction=create-user-in-auxiliary-configurator'
            $result.blockedEvents | Should -Be @("create", "drain", "configuration")
            $result.blockedLoadUsers | Should -Be @("")
            $result.blockedState.readinessStatus | Should -Be "confirmation-required"
            $result.blockedState.lastLoadStatus | Should -Be "passed"
            $result.blockedState.enterpriseNormalizationStatus | Should -Be "not-run"
            $result.blockedState.enterpriseNormalizationProofVersion | Should -Be 0
            $result.blockedState.sourceFingerprint | Should -Be ""
            $result.preflightBlocked | Should -Match '^ITL_AUXILIARY_UNSAFE_ACTION_PROTECTION_CONFIRMATION_REQUIRED:'
            $result.preflightEvents | Should -Be @("create", "confirm")
            $result.readyEvents | Should -Be @("create", "confirm", "drain", "configuration", "extension", "confirm", "epf")
            $result.readyLoadUsers | Should -Be @("AuxiliaryAdmin", "AuxiliaryAdmin")
            $result.readyState.readinessStatus | Should -Be "ready"
            $result.readyState.enterpriseNormalizationStatus | Should -Be "passed"
            $result.readyState.enterpriseNormalizationProofVersion | Should -Be 1
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "does not accept or silently replay a legacy ready auxiliary contour without update proof" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:Saved = 0
            $script:Contour = [pscustomobject]@{ name = "aux"; baseMode = "managed-file"; sourceMode = "load-only" }
            $script:Connection = [pscustomobject]@{ kind = "file"; path = "C:\bases\aux"; identityHash = "same"; user = ""; password = "" }
            $script:State = [pscustomobject]@{ readinessStatus = "ready"; connectionIdentityHash = "same"; sourceFingerprint = "same"; enterpriseNormalizationStatus = "passed" }
            function Get-AuxiliaryContour { $script:Contour }
            function Get-AuxiliaryContourConnection { $script:Connection }
            function Get-AuxiliaryContourFingerprint { [pscustomobject]@{ combined = "same" } }
            function Read-AuxiliaryContourState { $script:State }
            function Ensure-AuxiliaryManagedInfoBase {}
            function Ensure-AuxiliaryContourUnsafeActionProtection {}
            function Assert-AuxiliaryContourMutationAllowed {}
            function Save-AuxiliaryContourState { $script:Saved++ }
            $Action = "check-auxiliary-contour"
            $readiness = try { Assert-AuxiliaryContourReady -Contour $script:Contour -Operation "check" | Out-Null; "" } catch { $_.Exception.Message }
            $update = try { Update-AuxiliaryContour; "" } catch { $_.Exception.Message }
            $script:State.readinessStatus = "failed"
            $script:State.enterpriseNormalizationStatus = "failed"
            $failedRetry = try { Update-AuxiliaryContour; "" } catch { $_.Exception.Message }
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage -Message $failedRetry -RequestedAction "check-auxiliary-contour"
            [pscustomobject]@{ readiness = $readiness; update = $update; failedRetry = $failedRetry; saved = $script:Saved; category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }
        $result.readiness | Should -Match "ITL_AUXILIARY_INFOBASE_NOT_READY"
        $result.update | Should -Match "ITL_AUXILIARY_NORMALIZATION_PROOF_UNVERIFIED"
        $result.failedRetry | Should -Match "ITL_AUXILIARY_NORMALIZATION_RETRY_REQUIRED"
        $result.saved | Should -Be 0
        $result.category | Should -Be "infobase-readiness"
        $result.requiredAction | Should -Be "update-auxiliary-contour"
    }

    It "passes explicit auxiliary credentials through the shared unsafe-action prompt" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:answers = [Collections.Generic.Queue[string]]::new()
            $script:answers.Enqueue("no")
            $script:answers.Enqueue("ДА")
            $script:designer = $null
            function Read-Host { param($Prompt) $script:answers.Dequeue() }
            function Show-DevBranchUnsafeActionProtectionAttention {}
            function Write-Section { param($Title) }
            function Invoke-DesignerInteractive {
                param($InfoBasePath, $InfoBaseKind, $User, $Password)
                $script:designer = [pscustomobject]@{ path = $InfoBasePath; kind = $InfoBaseKind; user = $User; password = $Password }
            }
            $confirmation = Confirm-DevBranchUnsafeActionProtection `
                -InfoBaseKind file `
                -InfoBasePath "C:\auxiliary\Приёмник" `
                -DevBranchName "aux-exchange" `
                -SetupModeOverride manual-confirm `
                -InfoBaseUserOverride "AuxiliaryAdmin" `
                -InfoBasePasswordOverride "aux-secret"
            [pscustomobject]@{ confirmation = $confirmation; designer = $script:designer }
        }

        $result.confirmation.confirmed | Should -BeTrue
        $result.confirmation.user | Should -BeExactly "AuxiliaryAdmin"
        $result.designer.path | Should -BeExactly "C:\auxiliary\Приёмник"
        $result.designer.user | Should -BeExactly "AuxiliaryAdmin"
        $result.designer.password | Should -BeExactly "aux-secret"
    }

    It "installs and revalidates VAExtension only in the exact mutable auxiliary target" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{ baseMode = "managed-file"; configurationPath = "src/cf" }
        })
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $contour = Get-AuxiliaryContour -Name exchange
                $connection = Get-AuxiliaryContourConnection -Contour $contour
                $script:probePresent = $false
                $script:probeCount = 0
                $script:installCount = 0
                $script:proofState = $null
                $script:targets = [Collections.Generic.List[string]]::new()
                function Install-VanessaMcpArtifacts { [pscustomobject]@{ key = "vaExtension"; sha256 = "artifact-sha"; path = "artifact.cfe" } }
                function Read-AuxiliaryContourState { param($Contour) $script:proofState }
                function Get-ToolingRuntimeExtensions {
                    param($State, $Names, $User, $Password)
                    $script:probeCount++
                    $script:targets.Add([string]$State.devBranchInfoBasePath)
                    [pscustomobject]@{ name = "VAExtension"; present = $script:probePresent; active = $true; safeMode = $false; serverCodeObject = $true; contentHash = "runtime-sha" }
                }
                function Stop-AuxiliaryContourRuntimeBeforeMutation { param($Contour, $Connection, $Reason) $script:targets.Add([string]$Connection.path) }
                function Install-VanessaMcpExtensionCfe {
                    param($State, $CfePath, $ExtensionName, $InfoBaseKind, $InfoBasePath, $User, $Password)
                    $script:targets.Add([string]$InfoBasePath)
                    $script:installCount++
                    $script:probePresent = $true
                }
                function Set-VanessaMcpExtensionUnsafeMode {
                    param($State, $InfoBaseKind, $InfoBasePath, $ExtensionName, $Artifact, $User, $Password, $Scope)
                    $script:targets.Add([string]$InfoBasePath)
                    [pscustomobject]@{ verified = $true; safeMode = $false }
                }
                function Test-ToolingRuntimeExtensionReady { param($Runtime, $Name, $ExpectedHash, [switch]$RequireUnsafeMode) [bool]$Runtime.present -and [bool]$Runtime.active -and -not [bool]$Runtime.safeMode -and [bool]$Runtime.serverCodeObject -and (-not $ExpectedHash -or $Runtime.contentHash -ceq $ExpectedHash) }
                function Assert-ToolingRuntimeExtensionReady { param($Runtime, $Name, [switch]$RequireUnsafeMode) if (-not (Test-ToolingRuntimeExtensionReady -Runtime $Runtime -Name $Name -RequireUnsafeMode:$RequireUnsafeMode)) { throw "runtime not ready" } }
                function Save-AuxiliaryContourState { param($Contour, $Updates) $script:proofState = [pscustomobject]$Updates; $script:proofState }
                function Update-DevBranchState { throw "primary state must not be written" }
                $ready = [pscustomobject]@{ contour = $contour; connection = $connection }
                Ensure-AuxiliaryContourVanessaExtension -ReadyContext $ready
                Ensure-AuxiliaryContourVanessaExtension -ReadyContext $ready
                $script:probePresent = $false
                Ensure-AuxiliaryContourVanessaExtension -ReadyContext $ready
                $mutable = [pscustomobject]@{ installs = $script:installCount; probes = $script:probeCount; targets = @($script:targets); proof = $script:proofState.vanessaExtensionProof }
                $contour.baseMode = "attached-readonly"
                $beforeProbe = $script:probeCount
                $readonly = try { Ensure-AuxiliaryContourVanessaExtension -ReadyContext ([pscustomobject]@{ contour = $contour; connection = $connection }); "not-blocked" } catch { $_.Exception.Message }
                [pscustomobject]@{ mutable = $mutable; readonly = $readonly; readonlyProbeDelta = $script:probeCount - $beforeProbe }
            }

            $result.mutable.installs | Should -Be 2
            $result.mutable.probes | Should -Be 5
            @($result.mutable.targets | Where-Object { $_ -cne $result.mutable.targets[0] }).Count | Should -Be 0
            $result.mutable.proof.connectionIdentityHash | Should -Match '^[a-f0-9]{64}$'
            $result.mutable.proof.artifactSha256 | Should -BeExactly "artifact-sha"
            $result.mutable.proof.runtimeHash | Should -BeExactly "runtime-sha"
            $result.readonly | Should -Match 'ITL_AUXILIARY_READONLY_MUTATION_FORBIDDEN'
            $result.readonlyProbeDelta | Should -Be 0
            $auxiliary = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.auxiliary.ps1") -Raw -Encoding UTF8
            $invoke = [regex]::Match($auxiliary, '(?s)function Invoke-AuxiliaryContourVanessaTests \{(?<body>.*?)(?=\nfunction|\z)').Groups['body'].Value
            $invoke | Should -Match 'Ensure-AuxiliaryContourVanessaExtension\s+-ReadyContext \$ReadyContext'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "routes auxiliary monitor evidence diagnostics and cleanup through the projected runtime state" {
        $vanessa = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        $run = [regex]::Match($vanessa, '(?s)function Run-DevBranchTests \{(?<body>.*?)(?=\nfunction ConvertTo-IntOrDefault)').Groups['body'].Value
        $run | Should -Match '\$runtimeState\s*=\s*Get-VanessaVerificationRuntimeState'
        foreach ($call in @("Invoke-ForeignVanessaTestProcessPolicy", "Publish-Agent1cVanessaRunEvidence", "Test-VanessaTestClientStartupMonitor", "Stop-OwnHungVanessaTestClients", "Write-OneCVanessaProcessDiagnostics", "Stop-OwnVanessaTestProcessesAndAssert")) {
            $run | Should -Match ("(?s)" + [regex]::Escape($call) + '.{0,350}-State \$runtimeState')
        }
        $run | Should -Match 'Auxiliary event-log verification is unavailable; primary event-log evidence was not used'
    }

    It "invalidates the composite proof when an included feature changes" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{ baseMode = "managed-file"; configurationPath = "src/cf"; tests = [ordered]@{ includePrimary = $true; path = "tests/auxiliary/exchange" } }
        })
        try {
            $fingerprints = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $contour = Get-AuxiliaryContour -Name exchange
                $connection = Get-AuxiliaryContourConnection -Contour $contour
                $source = Get-AuxiliaryContourFingerprint -Contour $contour
                $ready = [pscustomobject]@{ contour = $contour; connection = $connection; source = $source }
                $paths = @("tests/features", "tests/auxiliary/exchange")
                $before = Get-AuxiliaryVerificationFingerprint -ReadyContext $ready -FeaturePaths $paths
                Set-Content -LiteralPath (Join-Path $root "tests\auxiliary\exchange\smoke.feature") -Encoding UTF8 -Value "Функционал: changed"
                $after = Get-AuxiliaryVerificationFingerprint -ReadyContext $ready -FeaturePaths $paths
                [pscustomobject]@{ before = $before; after = $after }
            }
            $fingerprints.before | Should -Match '^v1\|aux-verification-sha256\|[a-f0-9]{64}$'
            $fingerprints.after | Should -Not -Be $fingerprints.before
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "resets only a managed contour and archives its infobase recoverably" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{
            exchange = [ordered]@{ baseMode = "managed-file"; configurationPath = "src/cf" }
        })
        try {
            $basePath = & { . $HelperPath -ProjectRoot $root -Action help *> $null; Get-AuxiliaryContourConnection -Contour (Get-AuxiliaryContour -Name exchange) | Select-Object -ExpandProperty path }
            New-Item -ItemType Directory -Force -Path $basePath | Out-Null
            Set-Content -LiteralPath (Join-Path $basePath "1Cv8.1CD") -Encoding ASCII -Value "fixture database"
            & $HelperPath -ProjectRoot $root -Action reset-auxiliary-contour -AuxiliaryContourName exchange *> $null
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $basePath | Should -BeFalse
            $archives = @(Get-ChildItem -LiteralPath (Join-Path $root ".agent-1c\auxiliary-archives\itldev-auxiliary-fixture") -Directory)
            $archives.Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $archives[0].FullName "1Cv8.1CD") -PathType Leaf | Should -BeTrue
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "configures a managed contour without requiring manual project file edits" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{})
        try {
            & $HelperPath -ProjectRoot $root -Action configure-auxiliary-contour `
                -AuxiliaryContourName exchange `
                -AuxiliaryDisplayName "Приёмник обмена" `
                -AuxiliaryBaseMode managed-file `
                -AuxiliarySourceMode read-write `
                -AuxiliaryConfigurationPath "src/configs/exchange/cf" `
                -AuxiliaryIncludePrimaryTests `
                -AuxiliaryTestsPath "tests/auxiliary/exchange" `
                -AuxiliaryExtension @("ExchangeSupport=src/configs/exchange/cfe/ExchangeSupport") *> $null
            $LASTEXITCODE | Should -Be 0
            $config = Get-Content -LiteralPath (Join-Path $root ".agent-1c\project.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $config.aiRules.tools | Should -Contain "codex"
            $config.auxiliaryContours.exchange.displayName | Should -Be "Приёмник обмена"
            $config.auxiliaryContours.exchange.baseMode | Should -Be "managed-file"
            $config.auxiliaryContours.exchange.sourceMode | Should -Be "read-write"
            $config.auxiliaryContours.exchange.tests.includePrimary | Should -BeTrue
            $config.auxiliaryContours.exchange.tests.path | Should -Be "tests/auxiliary/exchange"
            $config.auxiliaryContours.exchange.extensions[0].name | Should -Be "ExchangeSupport"
            Test-Path -LiteralPath (Join-Path $root ".dev.env") | Should -BeFalse

            & $HelperPath -ProjectRoot $root -Action configure-auxiliary-contour `
                -AuxiliaryContourName exchange `
                -AuxiliaryDisplayName "Приёмник обмена" `
                -AuxiliaryBaseMode managed-file `
                -AuxiliarySourceMode read-write `
                -AuxiliaryConfigurationPath "src/configs/exchange/cf" `
                -AuxiliaryIncludePrimaryTests `
                -AuxiliaryTestsPath "tests/auxiliary/exchange" `
                -AuxiliaryExtension @("ExchangeSupport=src/configs/exchange/cfe/ExchangeSupport") `
                -AuxiliaryInfoBaseUser "AuxiliaryAdmin" `
                -AuxiliaryPasswordMode empty *> $null
            $LASTEXITCODE | Should -Be 0
            $envText = Get-Content -LiteralPath (Join-Path $root ".dev.env") -Raw -Encoding UTF8
            $envText | Should -Match 'ITL_AUX_EXCHANGE_USER=AuxiliaryAdmin'
            $envText | Should -Match 'ITL_AUX_EXCHANGE_PASSWORD='
            $connection = & { . $HelperPath -ProjectRoot $root -Action help *> $null; Get-AuxiliaryContourConnection -Contour (Get-AuxiliaryContour -Name exchange) }
            $connection.user | Should -BeExactly "AuxiliaryAdmin"
            $connection.password | Should -BeExactly ""
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "stores an attached connection atomically and reads its password from clipboard without output" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{})
        try {
            Set-Content -LiteralPath (Join-Path $root ".dev.env") -Encoding UTF8 -Value "PRESERVE_ME=yes"
            $messages = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $AuxiliaryContourName = "server-perf"
                $AuxiliaryDisplayName = "Серверный замер"
                $AuxiliaryBaseMode = "attached-disposable"
                $AuxiliarySourceMode = "load-only"
                $AuxiliaryConfigurationPath = "src/cf"
                $AuxiliaryInfoBaseKind = "server"
                $AuxiliaryInfoBasePath = "Сервер с пробелом\Тестовая база"
                $AuxiliaryInfoBaseUser = "Тестовый пользователь"
                $AuxiliaryPasswordMode = "clipboard"
                $AuxiliaryIncludePrimaryTests = $true
                $AuxiliaryTestsPath = ""
                $AuxiliaryExtension = @()
                $AuxiliaryMcpRoctup = $true
                $AuxiliaryMcpVanessaUi = $false
                function Get-Clipboard { [CmdletBinding()] param([switch]$Raw); "секрет=42" }
                Configure-AuxiliaryContour
            } *>&1
            ($messages | Out-String) | Should -Not -Match ([regex]::Escape("секрет=42"))
            $envText = Get-Content -LiteralPath (Join-Path $root ".dev.env") -Raw -Encoding UTF8
            $envLines = @($envText -split '\r?\n')
            $envLines | Should -Contain "PRESERVE_ME=yes"
            $envLines | Should -Contain "ITL_AUX_SERVER_PERF_INFOBASE_KIND=server"
            $envText | Should -Match ([regex]::Escape("ITL_AUX_SERVER_PERF_INFOBASE_PATH=Сервер с пробелом\Тестовая база"))
            $envLines | Should -Contain "ITL_AUX_SERVER_PERF_PASSWORD=секрет=42"
            $config = Get-Content -LiteralPath (Join-Path $root ".agent-1c\project.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $config.auxiliaryContours.'server-perf'.baseMode | Should -Be "attached-disposable"
            $config.auxiliaryContours.'server-perf'.mcp.roctup | Should -BeTrue
            ($config | ConvertTo-Json -Depth 12) | Should -Not -Match "секрет=42"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "rejects an unsafe setup before changing project or local connection state" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{})
        try {
            $configPath = Join-Path $root ".agent-1c\project.json"
            $before = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
            & $HelperPath -ProjectRoot $root -Action configure-auxiliary-contour -AuxiliaryContourName bad -AuxiliaryBaseMode managed-file -AuxiliarySourceMode read-write -AuxiliaryConfigurationPath src/cf *> $null
            $LASTEXITCODE | Should -Be 1
            (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8) | Should -BeExactly $before
            Test-Path -LiteralPath (Join-Path $root ".dev.env") | Should -BeFalse
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "does not let the setup questionnaire grant automation rights to a read-only base" {
        $root = New-AuxiliaryFixture -AuxiliaryContours ([ordered]@{})
        try {
            $configPath = Join-Path $root ".agent-1c\project.json"
            $before = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
            & $HelperPath -ProjectRoot $root -Action configure-auxiliary-contour -AuxiliaryContourName audit -AuxiliaryBaseMode attached-readonly -AuxiliaryInfoBaseKind server -AuxiliaryInfoBasePath "server\audit" -AuxiliaryIncludePrimaryTests *> $null
            $LASTEXITCODE | Should -Be 1
            (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8) | Should -BeExactly $before
            Test-Path -LiteralPath (Join-Path $root ".dev.env") | Should -BeFalse
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "preserves every setup choice through canonical helper reexecution" {
        $arguments = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help `
                -AuxiliaryContourName exchange `
                -AuxiliaryDisplayName "Приёмник обмена" `
                -AuxiliaryBaseMode managed-file `
                -AuxiliarySourceMode read-write `
                -AuxiliaryConfigurationPath "src/configs/exchange/cf" `
                -AuxiliaryIncludePrimaryTests `
                -AuxiliaryTestsPath "tests/auxiliary/exchange" `
                -AuxiliaryExtension @("One=src/cfe/One", "Two=src/cfe/Two") `
                -AuxiliaryMcpRoctup `
                -AuxiliaryMcpVanessaUi *> $null
            @(Get-Agent1cReexecArguments)
        }
        $joined = $arguments -join "`n"
        foreach ($expected in @("-AuxiliaryContourName", "exchange", "-AuxiliaryDisplayName", "Приёмник обмена", "-AuxiliaryBaseMode", "managed-file", "-AuxiliarySourceMode", "read-write", "-AuxiliaryConfigurationPath", "src/configs/exchange/cf", "-AuxiliaryIncludePrimaryTests", "-AuxiliaryTestsPath", "tests/auxiliary/exchange", "-AuxiliaryExtension", "One=src/cfe/One", "Two=src/cfe/Two", "-AuxiliaryMcpRoctup", "-AuxiliaryMcpVanessaUi")) {
            $joined | Should -Match ([regex]::Escape($expected))
        }
    }

    It "documents agent-led setup as the only normal user path" {
        $guidePath = Join-Path $RepoRoot "docs\itl-workflow\AUXILIARY-CONTOURS.ru.md"
        $guide = Get-Content -LiteralPath $guidePath -Raw -Encoding UTF8
        $reference = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\auxiliary-contours.md") -Raw -Encoding UTF8
        (Get-Content -LiteralPath $guidePath -Encoding UTF8).Count | Should -BeGreaterThan 120
        $decode = { param([string]$Value) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)) }
        $guide | Should -Match ([regex]::Escape((& $decode "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINC90LUg0YDQtdC00LDQutGC0LjRgNGD0LXRgg==")))
        $guide | Should -Match ([regex]::Escape((& $decode "0J/QsNGA0L7Qu9GMINC90LUg0L3Rg9C20L3QviDQvtGC0L/RgNCw0LLQu9GP0YLRjCDQsiDRh9Cw0YI=")))
        $guide | Should -Match ([regex]::Escape((& $decode "0JDQs9C10L3RgiDQv9C+0YHQu9C10LTQvtCy0LDRgtC10LvRjNC90L4g0YPRgtC+0YfQvdC40YI=")))
        $reference | Should -Match 'never edits.*project\.json.*\.dev\.env'
        $reference | Should -Match 'Never ask the user to paste a password into chat'
        $reference | Should -Match 'configure-auxiliary-contour'
    }

    Context 'Retiring auxiliary registrations' {
        BeforeAll {
            function Initialize-AuxiliaryRetirementFixture {
                param([string]$Root, [switch]$Database)
                $state = Join-Path $Root '.agent-1c/dev-branches/auxiliary-fixture.json'
                $base = Join-Path $Root '.agent-1c/infobases/auxiliary/itldev-auxiliary-fixture/exchange'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $state) | Out-Null
                @{devBranch='itldev/auxiliary-fixture'; devBranchName='auxiliary-fixture'; safeDevBranchName='auxiliary-fixture'; devBranchKind='configuration'; initializationStatus='ready'; createdWithWorktree=$true; worktreePath=$Root; devBranchInfoBasePath=(Join-Path $Root '.agent-1c/infobases/primary'); infoBaseKind='file'} |
                    ConvertTo-Json | Set-Content -LiteralPath $state -Encoding UTF8
                if ($Database) {
                    New-Item -ItemType Directory -Force -Path $base | Out-Null
                    Set-Content -LiteralPath (Join-Path $base '1Cv8.1CD') -Value 'retirement-test' -Encoding ASCII
                }
                return $base
            }

            function Set-AuxiliaryRetirementFixtureManifest {
                param([string]$Root, [object]$Profile)
                $path = Join-Path $Root '.agent-1c/project.json'
                $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $config | Add-Member -NotePropertyName vanessaAutomation -NotePropertyValue @{testClientManifestPath='tests/Профили ветки.json'} -Force
                $config | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding UTF8
                $manifest = Join-Path $Root 'tests/Профили ветки.json'
                @{schemaVersion=2; maxConcurrency=1; profiles=@($Profile)} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifest -Encoding UTF8
                return $manifest
            }
        }

        It 'requires the exact name and removes a managed contour with an archive retained by ordinary cleanup' {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file'}}
            try {
                $base = Initialize-AuxiliaryRetirementFixture $root -Database
                $envPath = Join-Path $root '.dev.env'
                $statePath = Join-Path $root '.agent-1c/auxiliary-contours/itldev-auxiliary-fixture/exchange.json'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statePath) | Out-Null
                Set-Content -LiteralPath $statePath -Value '{"contour":"exchange"}' -Encoding UTF8
                Set-Content -LiteralPath $envPath -Value @('# local comment','ITL_AUX_EXCHANGE_PASSWORD = retirement-secret','ITL_AUX_EXCHANGE_PASSWORD_OTHER=keep','OTHER=keep') -Encoding UTF8
                $missing = Invoke-Agent1cEntrypointProbe -ProbeId 'auxiliary-remove-name-required' -HelperPath $HelperPath -ProjectRoot $root -Action remove-auxiliary-contour
                $missing.exitCode | Should -Be 1
                $missing.combinedText.Contains('ITL_AUXILIARY_CONTOUR_REQUIRED') | Should -BeTrue
                $wrong = Invoke-Agent1cEntrypointProbe -ProbeId 'auxiliary-remove-name-exact' -HelperPath $HelperPath -ProjectRoot $root -Action remove-auxiliary-contour -Arguments @{AuxiliaryContourName='EXCHANGE'}
                $wrong.exitCode | Should -Be 1
                $wrong.combinedText.Contains('ITL_AUXILIARY_CONTOUR_NAME_INVALID') | Should -BeTrue
                $result = Invoke-Agent1cEntrypointProbe -ProbeId 'auxiliary-remove-managed' -HelperPath $HelperPath -ProjectRoot $root -Action remove-auxiliary-contour -Arguments @{AuxiliaryContourName='exchange'}
                $result.combinedText | Should -Not -Match 'retirement-secret'
                $result.combinedText | Should -Match 'archived.*itldev-auxiliary-fixture[/\\]exchange'
                $result.exitCode | Should -Be 0
                Test-Path -LiteralPath $base | Should -BeFalse
                Test-Path -LiteralPath $statePath | Should -BeFalse
                (Get-Content -LiteralPath $envPath -Raw -Encoding UTF8) | Should -Not -Match 'retirement-secret'
                @(Get-Content -LiteralPath $envPath -Encoding UTF8) | Should -Be @('# local comment','ITL_AUX_EXCHANGE_PASSWORD_OTHER=keep','OTHER=keep')
                $policies = & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    $plan = Get-ItlArtifactCleanupPlan -MainRoot $root
                    $archives = @($plan.entries | Where-Object category -EQ 'auxiliary-archive')
                    $archives.Count | Should -Be 1
                    $archivePath = $archives[0].path
                    $archives[0].delete | Should -BeFalse
                    $archives[0].reason | Should -Be 'newest'
                    $archives[0].group | Should -Be 'itldev-auxiliary-fixture/exchange'
                    foreach ($preview in @($true,$false,$false)) {
                        $clean = Invoke-ItlArtifactCleanup -DryRun:$preview 6>$null
                        $clean.removedBytes | Should -Be 0
                        Test-Path -LiteralPath (Join-Path $archivePath '1Cv8.1CD') | Should -BeTrue
                    }
                    $policy = Get-ItlArtifactRetentionPolicy
                    $policy.archiveKeepCount
                }
                $policies | Should -Be 2
            } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'blocks a directly referenced contour before writing and resumes after reassigning the same profile' {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file'}}
            try {
                $base = Initialize-AuxiliaryRetirementFixture $root -Database
                $manifest = Set-AuxiliaryRetirementFixtureManifest -Root $root -Profile @{name='Branch User'; contour='exchange'}
                $config = Join-Path $root '.agent-1c/project.json'
                $before = (Get-FileHash -LiteralPath $config).Hash
                $result = Invoke-Agent1cEntrypointProbe -ProbeId 'auxiliary-remove-profile-block' -HelperPath $HelperPath -ProjectRoot $root -Action remove-auxiliary-contour -Arguments @{AuxiliaryContourName='exchange'}
                $result.exitCode | Should -Be 1
                # The code is followed by the referencing profile.
                $codeAt = $result.combinedText.IndexOf('ITL_AUXILIARY_RETIREMENT_PROFILE_REFERENCE')
                $codeAt | Should -BeGreaterThan -1
                $result.combinedText.IndexOf('Branch User', $codeAt) | Should -BeGreaterThan $codeAt
                $result.combinedText | Should -Match ([regex]::Escape($manifest))
                (Get-FileHash -LiteralPath $config).Hash | Should -Be $before
                Test-Path -LiteralPath $base | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $root '.agent-1c/auxiliary-archives') | Should -BeFalse
                Set-AuxiliaryRetirementFixtureManifest -Root $root -Profile @{name='Branch User'; contour='primary'} | Out-Null
                $retry = Invoke-Agent1cEntrypointProbe -ProbeId 'auxiliary-remove-profile-continue' -HelperPath $HelperPath -ProjectRoot $root -Action remove-auxiliary-contour -Arguments @{AuxiliaryContourName='exchange'}
                $retry.combinedText | Should -Match 'archived'
                $retry.exitCode | Should -Be 0
            } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'preserves the TestClient <Reference> key and resolves the same profile through the runner' -ForEach @(
            @{Reference='userEnv'; Kept='USER'; Removed='PASSWORD'},
            @{Reference='passwordEnv'; Kept='PASSWORD'; Removed='USER'}
        ) {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file';connectionRef='EXCHANGE_PROFILE_FIXTURE'}}
            try {
                Initialize-AuxiliaryRetirementFixture $root | Out-Null
                $keptName = "ITL_AUX_EXCHANGE_PROFILE_FIXTURE_$Kept"
                $removedName = "ITL_AUX_EXCHANGE_PROFILE_FIXTURE_$Removed"
                Set-AuxiliaryRetirementFixtureManifest -Root $root -Profile @{name='Primary User'; contour='primary'; $Reference=$keptName} | Out-Null
                $envPath = Join-Path $root '.dev.env'
                Set-Content -LiteralPath $envPath -Value @("$keptName=kept-secret", "$removedName=removed-secret") -Encoding UTF8
                $result = Invoke-Agent1cEntrypointProbe -ProbeId 'auxiliary-remove-profile-env' -HelperPath $HelperPath -ProjectRoot $root -Action remove-auxiliary-contour -Arguments @{AuxiliaryContourName='exchange'}
                $result.exitCode | Should -Be 0
                $result.combinedText | Should -Match "$keptName.*Primary User"
                $result.combinedText | Should -Not -Match 'kept-secret|removed-secret'
                @(Get-Content -LiteralPath $envPath -Encoding UTF8) | Should -Be @("$keptName=kept-secret")
                & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    $profile = (Read-VanessaTestClientManifest).profiles[0]
                    $profile.(($Reference -replace 'Env$','')) -ceq 'kept-secret'
                } | Should -BeTrue
            } finally {
                [Environment]::SetEnvironmentVariable("ITL_AUX_EXCHANGE_PROFILE_FIXTURE_$Kept", $null, 'Process')
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'resumes the same name after the move succeeds and the archive marker fails' {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file';connectionRef='COMMON'}; retained=@{baseMode='managed-file';connectionRef='COMMON'}}
            try {
                $base = Initialize-AuxiliaryRetirementFixture $root -Database
                Set-Content -LiteralPath (Join-Path $root '.dev.env') -Encoding UTF8 -Value 'ITL_AUX_COMMON_USER=shared'
                & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    $AuxiliaryContourName = 'exchange'
                    function Write-AuxiliaryContourArchiveMarker { throw 'fixture interrupted after archive move' }
                    { Remove-AuxiliaryContour } | Should -Throw '*fixture interrupted after archive move*'
                }
                Test-Path -LiteralPath $base | Should -BeFalse
                $rootArchives = Join-Path $root '.agent-1c/auxiliary-archives/itldev-auxiliary-fixture'
                $archives = @(Get-ChildItem -LiteralPath $rootArchives -Directory)
                $archives.Count | Should -Be 1
                Test-Path -LiteralPath (Join-Path $archives[0].FullName 'itl-archive.json') | Should -BeFalse
                Add-Content -LiteralPath (Join-Path $root '.dev.env') -Value 'LATE_EDIT=preserved' -Encoding UTF8
                $result = Invoke-Agent1cEntrypointProbe -ProbeId 'auxiliary-remove-resume' -HelperPath $HelperPath -ProjectRoot $root -Action remove-auxiliary-contour -Arguments @{AuxiliaryContourName='exchange'}
                $result.combinedText | Should -Match 'archived'
                $result.exitCode | Should -Be 0
                @(Get-ChildItem -LiteralPath $rootArchives -Directory).Count | Should -Be 1
                Test-Path -LiteralPath (Join-Path $archives[0].FullName 'itl-archive.json') | Should -BeTrue
                @(Get-Content -LiteralPath (Join-Path $root '.dev.env') -Encoding UTF8) | Should -Be @('ITL_AUX_COMMON_USER=shared','LATE_EDIT=preserved')
            } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'plans one preserved base for disappearing attached <Mode> and managed contours with <Attached> order' -ForEach @(
            @{Mode='attached-readonly';Attached='aaa'}, @{Mode='attached-readonly';Attached='zzz'},
            @{Mode='attached-disposable';Attached='aaa'}, @{Mode='attached-disposable';Attached='zzz'}
        ) {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file'}; $Attached=@{baseMode=$Mode;connectionRef='SHARED_LOCAL'}}
            try {
                $base = Initialize-AuxiliaryRetirementFixture $root -Database
                & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    $env:ITL_AUX_SHARED_LOCAL_INFOBASE_KIND = 'file'
                    $env:ITL_AUX_SHARED_LOCAL_INFOBASE_PATH = "$base\"
                    $source = @(Get-AuxiliaryContourDefinitions | Sort-Object name)
                    $plan = New-AuxiliaryRetirementPlan -Source $source -Target @() -Names @('exchange',$Attached) -TargetCommit 'fixture'
                    @($plan.bases).Count | Should -Be 1
                    $plan.bases[0].reason | Should -Be 'attached-registration'
                    @(Get-AuxiliaryRetirementAdmissions -Plan $plan).Count | Should -Be 0
                    $plan.entries[0].base | Should -Be $plan.entries[1].base
                    Invoke-AuxiliaryRetirement -Plan $plan -Remaining @() -SaveProgress {}
                    $plan.result | Should -Not -BeNullOrEmpty
                }
                Test-Path -LiteralPath $base | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $root '.agent-1c/auxiliary-archives') | Should -BeFalse
            } finally {
                Remove-Item Env:ITL_AUX_SHARED_LOCAL_INFOBASE_KIND,Env:ITL_AUX_SHARED_LOCAL_INFOBASE_PATH -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'reconciles two clients through MCP ownership and preserves modified or unowned names' {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file';mcp=@{roctup=$true;vanessaUi=$true}}}
            try {
                Initialize-AuxiliaryRetirementFixture $root | Out-Null
                & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    $AuxiliaryContourName = 'exchange'
                    $wrapper = Write-ItlOnDemandAuxiliaryHelperWrapper -Contour (Get-AuxiliaryContour -Name exchange)
                    $endpoint = [pscustomobject]@{name='itl-roctup-aux-exchange';command='fixture-mcp.exe';transport='stdio';args=@('--helper',$wrapper)}
                    $edited = [pscustomobject]@{name='itl-vanessa-ui-aux-exchange';command='fixture-mcp.exe';transport='stdio';args=@('--helper',$wrapper)}
                    $requests = @(
                        [pscustomobject]@{client='cursor';owner='ondemand-facade';endpoints=@($endpoint,$edited)}
                        [pscustomobject]@{client='claude-code';owner='ondemand-facade';endpoints=@($endpoint)}
                    )
                    Write-ItlClientMcpEndpointSet -Requests $requests | Out-Null
                    Write-ItlClientMcpEndpoints -Endpoints @($endpoint) -Owner 'fixture-foreign' -Client codex | Out-Null
                    $cursor = @(Get-ItlClientMcpConfigPaths -Client cursor)[0]
                    $text = Read-Utf8Text -Path $cursor
                    $text = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcpServers',$edited.name,'command') -Value 'user-owned.exe'
                    Write-Utf8TextAtomic -Path $cursor -Value $text
                    $result = Remove-AuxiliaryContour *>&1 | Out-String
                    $result | Should -Match 'codex/itl-roctup-aux-exchange.*unowned'
                    $result | Should -Match 'cursor/itl-vanessa-ui-aux-exchange.*user change conflict'
                    $result | Should -Match 'Перечитайте.*claude.*cursor'
                    (Read-ItlClientMcpEntries -Client cursor).Contains($endpoint.name) | Should -BeFalse
                    (Read-ItlClientMcpEntries -Client claude-code).Contains($endpoint.name) | Should -BeFalse
                    (Read-ItlClientMcpEntries -Client cursor)[$edited.name].command | Should -Be 'user-owned.exe'
                    (Read-ItlClientMcpEntries -Client codex).Contains($endpoint.name) | Should -BeTrue
                    Test-Path -LiteralPath $wrapper | Should -BeTrue
                }
            } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'inventories only unknown local resources and leaves them through preview, cleanup and automatic cleanup' {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file'}}
            $junction = Join-Path $root '.agent-1c/infobases/linked'
            try {
                $active = Initialize-AuxiliaryRetirementFixture $root -Database
                & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    $paths = @{
                        orphan=(Join-Path $root '.agent-1c/infobases/auxiliary/itldev-auxiliary-fixture/md-fresh-085')
                        disposable=(Join-Path $root '.agent-1c/infobases/mdperf-ab-copy')
                        reference=(Join-Path $root '.agent-1c/infobases/Ручной эталон')
                        primary=(Join-Path $root '.agent-1c/infobases/primary')
                        service=(Join-Path $root '.agent-1c/infobases/vanessa-service-fixture')
                    }
                    foreach ($path in $paths.Values) {
                        New-Item -ItemType Directory -Force -Path $path | Out-Null
                        [IO.File]::WriteAllBytes((Join-Path $path '1Cv8.1CD'), [byte[]](1,2,3))
                    }
                    $state = Read-DevBranchState
                    Update-DevBranchState -State $state -Updates @{vanessaServiceInfoBasePath=$paths.service}
                    $statePath = Get-AuxiliaryContourStatePath -Contour @{name='md-fresh-085'}
                    Write-Utf8TextAtomic -Path $statePath -Value '{"contour":"md-fresh-085"}'
                    $wrapper = Write-ItlOnDemandAuxiliaryHelperWrapper -Contour @{name='md-fresh-085'}
                    Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value "ITL_AUX_MD_FRESH_085_PASSWORD=orphan-secret"
                    $endpoint = [pscustomobject]@{name='itl-roctup-aux-md-fresh-085';command='fixture-mcp.exe';transport='stdio';args=@('--helper',$wrapper)}
                    Write-ItlClientMcpEndpoints -Endpoints @($endpoint) -Owner 'ondemand-facade' -Client cursor | Out-Null
                    New-Item -ItemType Junction -Path $junction -Target $paths.reference | Out-Null
                    foreach ($preview in @($true,$false)) {
                        $output = Invoke-ItlArtifactCleanup -DryRun:$preview -IncludeAuxiliaryInventory *>&1 | Out-String
                        $output | Should -Match 'md-fresh-085'
                        $output | Should -Match 'mdperf-ab-copy.*3 bytes'
                        $output | Should -Match 'Ручной эталон.*3 bytes'
                        $output | Should -Match 'linked.*reparse-or-unavailable'
                        $output.Contains('ITL_AUX_MD_FRESH_085_PASSWORD') | Should -BeTrue
                        $output.Contains('cursor/itl-roctup-aux-md-fresh-085') | Should -BeTrue
                        $output | Should -Not -Match 'orphan-secret|vanessa-service-fixture|infobases\\primary|itldev-auxiliary-fixture\\exchange'
                    }
                    (Invoke-ItlArtifactCleanup -Automatic *>&1 | Out-String) | Should -Not -Match 'md-fresh-085|ITL_AUX_MD_FRESH_085_PASSWORD'
                    foreach ($path in @($paths.Values) + @($statePath,$wrapper,$junction,$active,(Join-Path $root '.dev.env'))) {
                        Test-Path -LiteralPath $path | Should -BeTrue
                    }
                }
            } finally {
                if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'continues reset after a foreign-session conflict and an interrupted archive while using the target profile' {
            $root = New-AuxiliaryFixture @{retained=@{baseMode='managed-file'}}
            try {
                $fixtureBaseDir = Initialize-AuxiliaryRetirementFixture $root -Database
                $targetManifest = Set-AuxiliaryRetirementFixtureManifest -Root $root -Profile @{
                    name='Target Primary'; contour='primary'; passwordEnv='ITL_AUX_EXCHANGE_PASSWORD'
                }
                $markerPath = '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
                $marker = Join-Path $root $markerPath
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
                Set-Content -LiteralPath $marker -Value '# ITL_RESET_AUXILIARY_RETIREMENT_SCHEMA=1' -Encoding ASCII
                Copy-Item -LiteralPath (Join-Path $RepoRoot 'templates/gitignore.append') -Destination (Join-Path $root '.gitignore')
                & git -C $root add -- .gitignore .agent-1c/project.json tests $markerPath
                & git -C $root commit -qm target
                $target = (& git -C $root rev-parse HEAD).Trim()
                $targetTree = (& git -C $root rev-parse 'HEAD^{tree}').Trim()
                & git -C $root branch master
                $configPath = Join-Path $root '.agent-1c/project.json'
                $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $config.auxiliaryContours | Add-Member exchange @{baseMode='managed-file'}
                $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding UTF8
                @{schemaVersion=2;maxConcurrency=1;profiles=@(@{name='Disappears with source';contour='exchange'})} |
                    ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $targetManifest -Encoding UTF8
                & git -C $root add -- .agent-1c/project.json tests
                & git -C $root commit -qm source
                $before = (& git -C $root rev-parse HEAD).Trim()
                $envPath = Join-Path $root '.dev.env'
                Set-Content -LiteralPath $envPath -Encoding UTF8 -Value @('ITL_AUX_EXCHANGE_USER=fixture-unused','ITL_AUX_EXCHANGE_PASSWORD=fixture-kept')
                & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    # Git, seed pinning and retirement are exercised through the
                    # reset entrypoint. The primary 1C runtime is a test double.
                    function Get-DevBranchResetMasterSource { [pscustomobject]@{commit=$target;tree=$targetTree;fingerprint='fixture-fingerprint';configTreeObjectId='fixture-tree'} }
                    function Open-DevBranchResetSourceInputs {
                        [pscustomobject]@{
                            lease=[IO.MemoryStream]::new(); seedIdentity=[pscustomobject]@{syncId='fixture-seed'}
                            seed=[pscustomobject]@{baselinePath='unused';sourceKey='fixture';syncId='fixture-seed';artifactKind='file-1cd';configurationFingerprint='fixture-fingerprint';baselineHash='';baselineCount=0}
                        }
                    }
                    function Restore-ExistingDevBranchRuntimeFromSeed { param($State, $ExpectedConfigurationFingerprint, $CapturedSeed, $ExistingLease); [pscustomobject]@{seed=$CapturedSeed;repositoryUnbound=$false} }
                    function Initialize-DevBranchEventLogBaseline { param($State); $State }
                    function Ensure-DevBranchEventLogPendingCursor {}
                    function Ensure-DevBranchEnterpriseNormalized {}
                    function Sync-AiRules1cManagedIgnoredFilesFromMain {}
                    function Invoke-DevBranchDefaultMcpSetup { param($State, [switch]$PreserveAuxiliaryResources); $State }
                    function Sync-KiloItlCommandSurface {}
                    function Invoke-AiRules1cManagedMcpConfigReconcile {}
                    function Sync-DevBranchContextToDotEnv {}
                    function Archive-VerificationChangeForReset {}
                    function Archive-VerificationSelectionEvidenceForReset {}
                    function Stop-ItlOnDemandBackends {
                        param([string]$InfoBasePath,[switch]$Strict)
                        $InfoBasePath | Should -Be $fixtureBaseDir
                    }
                    $testState = @{foreign=$true; crash=$true}
                    function Get-OneCInfoBaseSessionProcesses {
                        param($InfoBaseKind,$InfoBasePath)
                        if ($testState.foreign -and $InfoBasePath -eq $fixtureBaseDir) { [pscustomobject]@{pid=$PID} }
                    }
                    $originalMoveMarker = (Get-Command Write-AuxiliaryContourArchiveMarker).ScriptBlock
                    function Write-AuxiliaryContourArchiveMarker {
                        param($Path,$Name)
                        if ($testState.crash) { throw 'fixture crash after move' }
                        & $originalMoveMarker -Path $Path -Name $Name
                    }
                    { Reset-DevBranch } | Should -Throw '*EXECUTION_GUARD_EXTERNAL_CONFLICT*'
                    Get-CurrentCommit | Should -Be $before
                    (Get-StateValue (Read-DevBranchState) 'resetStatus' '') | Should -Be ''
                    Test-Path -LiteralPath $fixtureBaseDir | Should -BeTrue
                    $testState.foreign = $false
                    { Reset-DevBranch } | Should -Throw '*fixture crash after move*'
                    (Get-GitOutput @('rev-parse','HEAD^{tree}')).Trim() | Should -Be $targetTree
                    Test-Path -LiteralPath $fixtureBaseDir | Should -BeFalse
                    (Read-DevBranchState).resetPhase | Should -Be 'git-reset-complete'
                    $testState.crash = $false
                    $result = Reset-DevBranch *>&1 | Out-String
                    $result | Should -Match 'exchange.*archived'
                    # The secret name is followed by the target that still uses it.
                    $secretAt = ([string]$result).IndexOf('ITL_AUX_EXCHANGE_PASSWORD')
                    $secretAt | Should -BeGreaterThan -1
                    ([string]$result).IndexOf('Target Primary', $secretAt) | Should -BeGreaterThan $secretAt
                    $result | Should -Not -Match 'fixture-kept|fixture-unused'
                    (Read-DevBranchState).resetStatus | Should -Be 'complete'
                    (Get-GitOutput @('rev-parse','HEAD^{tree}')).Trim() | Should -Be $targetTree
                    @(Get-ItlAuxiliaryArchiveArtifactCandidates -ProjectRoot $root).Count | Should -Be 1
                    @(Get-Content -LiteralPath $envPath -Encoding UTF8) | Should -Be @('ITL_AUX_EXCHANGE_PASSWORD=fixture-kept')
                }
            } finally {
                [Environment]::SetEnvironmentVariable('ITL_AUX_EXCHANGE_PASSWORD', $null, 'Process')
                [Environment]::SetEnvironmentVariable('ITL_AUX_EXCHANGE_USER', $null, 'Process')
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'recovers a client file written before its ownership receipt and confirms the reload client' {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file';mcp=@{roctup=$true}}}
            try {
                Initialize-AuxiliaryRetirementFixture $root | Out-Null
                $key = 'itl-roctup-aux-exchange'
                $wrapper = & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    $AuxiliaryContourName = 'exchange'
                    $path = Write-ItlOnDemandAuxiliaryHelperWrapper -Contour (Get-AuxiliaryContour -Name exchange)
                    $endpoint = [pscustomobject]@{name=$key;command='fixture-mcp.exe';transport='stdio';args=@('--helper',$path)}
                    $request = [pscustomobject]@{client='cursor';owner='ondemand-facade';endpoints=@($endpoint)}
                    Write-ItlClientMcpEndpointSet -Requests @($request) | Out-Null
                    function Write-ItlManagedMcpState { throw 'fixture interruption before MCP owner receipt' }
                    { Remove-AuxiliaryContour } | Should -Throw '*fixture interruption before MCP owner receipt*'
                    (Read-ItlClientMcpEntries -Client cursor).Contains($key) | Should -BeFalse
                    @(Get-ItlManagedMcpOwnerKeys -Client cursor -Owner 'ondemand-facade') | Should -Contain $key
                    Test-Path -LiteralPath $path | Should -BeTrue
                    $path
                }
                $result = Invoke-Agent1cEntrypointProbe -ProbeId 'auxiliary-remove-mcp-resume' -HelperPath $HelperPath -ProjectRoot $root -Action remove-auxiliary-contour -Arguments @{AuxiliaryContourName='exchange'}
                $result.combinedText | Should -Match 'Перечитайте.*cursor'
                $result.exitCode | Should -Be 0
                Test-Path -LiteralPath $wrapper | Should -BeFalse
                & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    @(Get-ItlManagedMcpOwnerKeys -Client cursor -Owner 'ondemand-facade') | Should -Not -Contain $key
                }
            } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'preserves a managed path that is a junction and leaves its target untouched' {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file'}}
            $managed = Initialize-AuxiliaryRetirementFixture $root
            $other = Join-Path $root '.agent-1c/infobases/Каталог с данными'
            try {
                New-Item -ItemType Directory -Force -Path $other,(Split-Path -Parent $managed) | Out-Null
                $db = Join-Path $other '1Cv8.1CD'
                [IO.File]::WriteAllText($db, 'external bytes')
                New-Item -ItemType Junction -Path $managed -Target $other | Out-Null
                $result = Invoke-Agent1cEntrypointProbe -ProbeId 'auxiliary-remove-junction' -HelperPath $HelperPath -ProjectRoot $root -Action remove-auxiliary-contour -Arguments @{AuxiliaryContourName='exchange'}
                # The preserved item carries its reason identifier.
                $preservedAt = $result.combinedText.IndexOf('preserved')
                $preservedAt | Should -BeGreaterThan -1
                $result.combinedText.IndexOf('path-or-archive-ownership-unproved', $preservedAt) | Should -BeGreaterThan $preservedAt
                $result.exitCode | Should -Be 0
                [IO.File]::ReadAllText($db) | Should -Be 'external bytes'
                Test-Path -LiteralPath $managed | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $root '.agent-1c/auxiliary-archives') | Should -BeFalse
            } finally {
                if (Test-Path -LiteralPath $managed) { [IO.Directory]::Delete($managed) }
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'narrows the saved plan when a different database appears at the recorded path' {
            $root = New-AuxiliaryFixture @{exchange=@{baseMode='managed-file'}}
            try {
                $managed = Initialize-AuxiliaryRetirementFixture $root -Database
                & {
                    . $HelperPath -ProjectRoot $root -Action help *> $null
                    $retirement = New-AuxiliaryRetirementPlan -Source @(Get-AuxiliaryContourDefinitions) -Target @() -Names @('exchange')
                    @(Get-AuxiliaryRetirementAdmissions -Plan $retirement).Count | Should -Be 1
                    [IO.Directory]::Move($managed, (Join-Path $root '.agent-1c/infobases/prior-base'))
                    New-Item -ItemType Directory -Path $managed | Out-Null
                    [IO.File]::WriteAllText((Join-Path $managed '1Cv8.1CD'), 'different base contents')
                    Update-AuxiliaryRetirementBaseEvidence -Plan $retirement -Remaining @()
                    $retirement.bases[0].reason | Should -Be 'base-identity-changed'
                    @(Get-AuxiliaryRetirementAdmissions -Plan $retirement).Count | Should -Be 0
                    Invoke-AuxiliaryRetirement -Plan $retirement -Remaining @() -SaveProgress {}
                    [IO.File]::ReadAllText((Join-Path $managed '1Cv8.1CD')) | Should -Be 'different base contents'
                    Test-Path -LiteralPath (Join-Path $root '.agent-1c/infobases/prior-base/1Cv8.1CD') | Should -BeTrue
                    Test-Path -LiteralPath (Join-Path $root '.agent-1c/auxiliary-archives') | Should -BeFalse
                }
            } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

}
