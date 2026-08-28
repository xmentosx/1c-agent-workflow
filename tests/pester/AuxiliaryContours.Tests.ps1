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
            $config = [ordered]@{ schemaVersion = 1; auxiliaryContours = $AuxiliaryContours; aiRules = [ordered]@{ tools = @("codex") } }
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
            & $HelperPath -ProjectRoot $root -Action update-auxiliary-contour -AuxiliaryContourName server *> $null
            $LASTEXITCODE | Should -Be 1
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
                Save-AuxiliaryContourState -Contour $contour -Updates @{ readinessStatus = "ready"; connectionIdentityHash = $connection.identityHash; sourceFingerprint = $source.combined } | Out-Null
                $profile = [pscustomobject]@{ name = "Receiver"; contour = "exchange"; user = ""; password = "" }
                Get-VanessaTestClientProfileConnection -Profile $profile -DefaultState ([pscustomobject]@{ infoBaseKind = "file"; devBranchInfoBasePath = (Join-Path $root "primary") })
            }
            $result.contour | Should -Be "exchange"
            $result.kind | Should -Be "file"
            $result.path | Should -Match 'infobases[\\/]auxiliary'
            $result.path | Should -Match 'exchange$'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
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
}
