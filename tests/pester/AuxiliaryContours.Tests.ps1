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
}
