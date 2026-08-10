Describe "Vanessa runner TestClient topology and tag filtering" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath

        function New-VanessaRunnerFixture {
            param(
                [string]$Root,
                [string]$FeatureText,
                [AllowNull()][string]$ManifestText
            )

            $featurePath = Join-Path $Root "tests\features\fixture.feature"
            $runDirectory = Join-Path $Root "build\test-results\vanessa\run"
            $infoBasePath = Join-Path $Root "ib"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $featurePath), $runDirectory, $infoBasePath, (Join-Path $Root ".agent-1c") | Out-Null
            & git -C $Root init *> $null
            Set-Content -LiteralPath $featurePath -Encoding UTF8 -Value $FeatureText

            $manifestPath = Join-Path $Root "tests\vanessa-testclients.json"
            if (-not [string]::IsNullOrEmpty($ManifestText)) {
                Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value $ManifestText
                Set-Content -LiteralPath (Join-Path $Root ".agent-1c\project.json") -Encoding UTF8 -Value '{"vanessaAutomation":{"testClientManifestPath":"tests/vanessa-testclients.json"}}'
            } else {
                Set-Content -LiteralPath (Join-Path $Root ".agent-1c\project.json") -Encoding UTF8 -Value '{}'
            }

            return [pscustomobject]@{
                featurePath = $featurePath
                runDirectory = $runDirectory
                infoBasePath = $infoBasePath
                manifestPath = $manifestPath
                state = [pscustomobject]@{
                    devBranchName = "fixture"
                    safeDevBranchName = "fixture"
                    devBranch = "itldev/fixture"
                    stateProjectRoot = $Root
                    worktreePath = $Root
                    infoBaseKind = "file"
                    devBranchInfoBasePath = $infoBasePath
                }
            }
        }

        function Get-EncodedVanessaKey {
            param([string]$Value)
            return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
        }
    }

    It "ships the project config hook without embedding product profile names" {
        $project = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Raw -Encoding UTF8 | ConvertFrom-Json

        $project.vanessaAutomation.PSObject.Properties.Name | Should -Contain "testClientManifestPath"
        $project.vanessaAutomation.testClientManifestPath | Should -Be ""
        (Get-Content -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Raw -Encoding UTF8) | Should -Not -Match "НРС-"
    }

    It "routes unresolved profile placeholders through the test-fixture category" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-category-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:RunErrorCategory = ""
                $script:RunRequiredAction = ""
                Set-RunFailureContextFromMessage -Message "ITL_VANESSA_TEST_FIXTURE_UNRESOLVED_PROFILE: references=[]"
                $script:RunErrorCategory | Should -Be "test-fixture"
                $script:RunRequiredAction | Should -Be "/itl-verify-fix"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "supports an explicit manifest with zero profiles" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-zero-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Без клиента`nСценарий: Серверная проверка`n  Тогда Истина равна Истине" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":0,"profiles":[]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath)
                $paramsPath = New-VanessaParamsFile `
                    -FeaturePath $fixture.featurePath `
                    -RunDirectory $fixture.runDirectory `
                    -StatusPath (Join-Path $fixture.runDirectory "status.json") `
                    -State $fixture.state `
                    -TestPort 48051 `
                    -TestPorts @(48051) `
                    -TestClientTopology $topology
                $params = Get-Content -Raw -Encoding UTF8 $paramsPath | ConvertFrom-Json
                $clientKey = Get-EncodedVanessaKey "0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP"
                $clientsKey = Get-EncodedVanessaKey "0JTQsNC90L3Ri9C10JrQu9C40LXQvdGC0L7QstCi0LXRgdGC0LjRgNC+0LLQsNC90LjRjw=="

                @($topology.profiles).Count | Should -Be 0
                $topology.declaredTestClientCeiling | Should -Be 0
                $topology.requiredTestClientSlots | Should -Be 0
                $params.stoponerror | Should -BeFalse
                @($params.PSObject.Properties[$clientKey].Value.PSObject.Properties[$clientsKey].Value).Count | Should -Be 0
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "starts the legacy default TestClient when a scenario uses a VAExtension step" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-extension-client-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Код конфигурации`nСценарий: Сервер TestClient`n  И я выполняю код встроенного языка на сервере (Расширение)"
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath)
                $paramsPath = New-VanessaParamsFile `
                    -FeaturePath $fixture.featurePath `
                    -RunDirectory $fixture.runDirectory `
                    -StatusPath (Join-Path $fixture.runDirectory "status.json") `
                    -State $fixture.state `
                    -TestPort 48051 `
                    -TestPorts @(48051) `
                    -TestClientTopology $topology
                $params = Get-Content -Raw -Encoding UTF8 $paramsPath | ConvertFrom-Json
                $scenarioKey = Get-EncodedVanessaKey "0JLRi9C/0L7Qu9C90LXQvdC40LXQodGG0LXQvdCw0YDQuNC10LI="
                $startOnErrorKey = Get-EncodedVanessaKey "0J7RgdGC0LDQvdC+0LLQutCw0J/RgNC40JLQvtC30L3QuNC60L3QvtCy0LXQvdC40LjQntGI0LjQsdC60Lg="

                $topology.configured | Should -BeFalse
                $topology.requiresExtensionTestClient | Should -BeTrue
                $topology.requiredTestClientSlots | Should -Be 1
                @($topology.profiles).Count | Should -Be 1
                $params.stoponerror | Should -BeTrue
                $params.PSObject.Properties[$scenarioKey].Value.PSObject.Properties[$startOnErrorKey].Value | Should -BeTrue
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "loads one secret-safe profile and rejects a tracked password value" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-one-" + [guid]::NewGuid().ToString("N"))
        $oldPassword = [Environment]::GetEnvironmentVariable("ITL_TEST_PROFILE_ONE_PASSWORD", "Process")
        try {
            [Environment]::SetEnvironmentVariable("ITL_TEST_PROFILE_ONE_PASSWORD", "runtime-secret", "Process")
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Один профиль`nСценарий: Вход`n  Дано я подключаю профиль TestClient `"ProfileOne`"" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"ProfileOne","user":"user-one","passwordEnv":"ITL_TEST_PROFILE_ONE_PASSWORD"}]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath)
                $topology.profiles[0].name | Should -Be "ProfileOne"
                $topology.profiles[0].password | Should -Be "runtime-secret"

                $paramsPath = New-VanessaParamsFile `
                    -FeaturePath $fixture.featurePath `
                    -RunDirectory $fixture.runDirectory `
                    -StatusPath (Join-Path $fixture.runDirectory "status.json") `
                    -State $fixture.state `
                    -TestPort 48051 `
                    -TestPorts @(48051) `
                    -TestClientTopology $topology
                $params = Get-Content -Raw -Encoding UTF8 $paramsPath | ConvertFrom-Json
                $onlyOneKey = Get-EncodedVanessaKey "0KDQsNC30YDQtdGI0LXQvdC+0JfQsNC/0YPRgdC60LDRgtGM0KLQvtC70YzQutC+0J7QtNC40L3QmtC70LjQtdC90YLQotC10YHRgtC40YDQvtCy0LDQvdC40Y8="
                $scenarioKey = Get-EncodedVanessaKey "0JLRi9C/0L7Qu9C90LXQvdC40LXQodGG0LXQvdCw0YDQuNC10LI="
                $stopOnErrorKey = Get-EncodedVanessaKey "0J7RgdGC0LDQvdC+0LLQutCw0J/RgNC40JLQvtC30L3QuNC60L3QvtCy0LXQvdC40LjQntGI0LjQsdC60Lg="
                $clientKey = Get-EncodedVanessaKey "0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP"
                $closeAfterRunKey = Get-EncodedVanessaKey "0JfQsNC60YDRi9GC0YxUZXN0Q2xpZW500J/QvtGB0LvQtdCX0LDQv9GD0YHQutCw0KHRhtC10L3QsNGA0LjQtdCy"

                $topology.declaredTestClientCeiling | Should -Be 1
                $topology.requiredTestClientSlots | Should -Be 1
                $params.PSObject.Properties[$onlyOneKey].Value | Should -BeTrue
                $params.stoponerror | Should -BeTrue
                $params.PSObject.Properties[$scenarioKey].Value.PSObject.Properties[$stopOnErrorKey].Value | Should -BeTrue
                $params.PSObject.Properties[$clientKey].Value.PSObject.Properties[$closeAfterRunKey].Value | Should -BeTrue

                Set-Content -LiteralPath $fixture.manifestPath -Encoding UTF8 -Value '{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"ProfileOne","password":"tracked-secret"}]}'
                { Read-VanessaTestClientManifest } | Should -Throw "*ITL_VANESSA_TESTCLIENT_MANIFEST_SECRET_FORBIDDEN*"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_TEST_PROFILE_ONE_PASSWORD", $oldPassword, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "emits multiple named profiles with unique ports and multi-client topology" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-many-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Несколько профилей`nСценарий: Два клиента`n  Дано я подключаю профиль TestClient `"Alpha`"`n  И я подключаю профиль TestClient `"Beta`"`n  И я закрываю TestClient `"Beta`"" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":2,"profiles":[{"name":"Alpha","user":"alpha"},{"name":"Beta","user":"beta"},{"name":"Gamma","user":"gamma"}]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath)
                $paramsPath = New-VanessaParamsFile `
                    -FeaturePath $fixture.featurePath `
                    -RunDirectory $fixture.runDirectory `
                    -StatusPath (Join-Path $fixture.runDirectory "status.json") `
                    -State $fixture.state `
                    -TestPort 48051 `
                    -TestPorts @(48051, 48052, 48053) `
                    -TestClientTopology $topology
                $params = Get-Content -Raw -Encoding UTF8 $paramsPath | ConvertFrom-Json
                $clientKey = Get-EncodedVanessaKey "0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP"
                $clientsKey = Get-EncodedVanessaKey "0JTQsNC90L3Ri9C10JrQu9C40LXQvdGC0L7QstCi0LXRgdGC0LjRgNC+0LLQsNC90LjRjw=="
                $portKey = Get-EncodedVanessaKey "0J/QvtGA0YLQl9Cw0L/Rg9GB0LrQsNCi0LXRgdGC0JrQu9C40LXQvdGC0LA="
                $onlyOneKey = Get-EncodedVanessaKey "0KDQsNC30YDQtdGI0LXQvdC+0JfQsNC/0YPRgdC60LDRgtGM0KLQvtC70YzQutC+0J7QtNC40L3QmtC70LjQtdC90YLQotC10YHRgtC40YDQvtCy0LDQvdC40Y8="
                $maximizedKey = Get-EncodedVanessaKey "0JfQsNC/0YPRgdC60LDRgtGM0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP0KHQnNCw0LrRgdC40LzQuNC30LjRgNC+0LLQsNC90L3Ri9C80J7QutC90L7QvA=="
                $portRangeKey = Get-EncodedVanessaKey "0JTQuNCw0L/QsNC30L7QvdCf0L7RgNGC0L7QslRlc3RjbGllbnQ="
                $clientSettings = $params.PSObject.Properties[$clientKey].Value
                $records = @($clientSettings.PSObject.Properties[$clientsKey].Value)
                $ports = @($records | ForEach-Object { [int]$_.PSObject.Properties[$portKey].Value })

                $topology.declaredTestClientCeiling | Should -Be 2
                $topology.requiredTestClientSlots | Should -Be 2
                $topology.PSObject.Properties.Name | Should -Not -Contain "observedMaximumConcurrency"
                $topology.PSObject.Properties.Name | Should -Not -Contain "maxConcurrency"
                $records.Count | Should -Be 3
                @($ports | Sort-Object -Unique).Count | Should -Be 3
                $params.PSObject.Properties[$onlyOneKey].Value | Should -BeFalse
                $clientSettings.PSObject.Properties.Name | Should -Not -Contain $onlyOneKey
                $clientSettings.PSObject.Properties[$maximizedKey].Value | Should -BeTrue
                $params.PSObject.Properties[$portRangeKey].Value | Should -Be "48051-48053"

                Set-Content -LiteralPath $fixture.manifestPath -Encoding UTF8 -Value '{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"Alpha"},{"name":"Beta"},{"name":"Gamma"}]}'
                { Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath) } | Should -Throw "*ITL_VANESSA_TESTCLIENT_CONCURRENCY_INSUFFICIENT*"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reserves only the TestClients required by the selected scenarios below the manifest ceiling" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-selected-capacity-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Выбранная конкурентность`n@Selected`nСценарий: Один клиент`n  Дано я подключаю профиль TestClient `"Alpha`"`nСценарий: Два клиента`n  Дано я подключаю профиль TestClient `"Alpha`"`n  И я подключаю профиль TestClient `"Beta`"" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":2,"profiles":[{"name":"Alpha"},{"name":"Beta"}]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath) -FilterTags "@Selected"
                $paramsPath = New-VanessaParamsFile `
                    -FeaturePath $fixture.featurePath `
                    -RunDirectory $fixture.runDirectory `
                    -StatusPath (Join-Path $fixture.runDirectory "status.json") `
                    -State $fixture.state `
                    -TestPort 48051 `
                    -TestPorts @(48051, 48052) `
                    -TestClientTopology $topology `
                    -FilterTags "@Selected"
                $params = Get-Content -Raw -Encoding UTF8 $paramsPath | ConvertFrom-Json
                $onlyOneKey = Get-EncodedVanessaKey "0KDQsNC30YDQtdGI0LXQvdC+0JfQsNC/0YPRgdC60LDRgtGM0KLQvtC70YzQutC+0J7QtNC40L3QmtC70LjQtdC90YLQotC10YHRgtC40YDQvtCy0LDQvdC40Y8="

                $topology.declaredTestClientCeiling | Should -Be 2
                $topology.requiredTestClientSlots | Should -Be 1
                $params.PSObject.Properties[$onlyOneKey].Value | Should -BeTrue
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "allocates a bounded unique port per declared profile without a separate machine-global session cap" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-ports-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        $oldPortRange = [Environment]::GetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", "Process")
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "registry"), "Process")
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", "49001..49003", "Process")
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-OneCProcessInfo { return @() }
                $state = [pscustomobject]@{ devBranchName = "fixture"; safeDevBranchName = "fixture"; devBranch = "itldev/fixture"; stateProjectRoot = $tempRoot; worktreePath = $tempRoot }
                $ports = @(Resolve-VanessaTestPorts -State $state -Count 3)
                $ports | Should -Be @(49001, 49002, 49003)
                $registry = Read-ItlPortRegistry
                $allocations = @($registry.allocations)
                $registry.schemaVersion | Should -Be 2
                $allocations.Count | Should -Be 3
                @($allocations.key | Sort-Object -Unique).Count | Should -Be 3
                @($allocations.leaseToken | Where-Object { $_ } | Sort-Object -Unique).Count | Should -Be 1

            }
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", $oldPortRange, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports all missing profiles but classifies a truly unresolved placeholder as fixture" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-preflight-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Preflight`nСценарий: Missing`n  Дано я подключаю профиль TestClient `"MissingB`"`n  И я подключаю профиль TestClient `"MissingA`"" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"Configured"}]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $message = ""
                try { Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath) | Out-Null } catch { $message = $_.Exception.Message }
                $message | Should -Match "ITL_VANESSA_TESTCLIENT_PROFILES_MISSING"
                $message | Should -Match "MissingA"
                $message | Should -Match "MissingB"

                Set-Content -LiteralPath $fixture.featurePath -Encoding UTF8 -Value "# language: ru`nФункционал: Fixture`nСценарий: Literal placeholder`n  Дано я подключаю профиль TestClient `"<Профиль>`""
                { Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath) } | Should -Throw "*ITL_VANESSA_TEST_FIXTURE_UNRESOLVED_PROFILE*"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "resolves outline profile examples instead of reporting the placeholder as missing" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-outline-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Outline`nСтруктура сценария: Profiles`n  Дано я подключаю профиль TestClient `"<Профиль>`"`n  И я закрываю TestClient `"<Профиль>`"`nПримеры:`n  | Профиль |`n  | Alpha |`n  | Beta |" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"Alpha"},{"name":"Beta"}]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath)
                $topology.requiredProfiles | Should -Be @("Alpha", "Beta")
                $topology.requiredTestClientSlots | Should -Be 1
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "counts PM5-style inline TestClient aliases without requiring manifest profiles" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-inline-client-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Inline clients`nКонтекст:`n  Дано Я запускаю сценарий открытия TestClient или подключаю уже существующий`nСценарий: Direct aliases`n  И я подключаю TestClient `"U3`" логин `"U3`" пароль `"inline-secret`"`n  И я закрываю TestClient `"U3`"`n  И я подключаю TestClient `"U4`" логин `"U4`" пароль `"`"`n  И я закрываю сеанс текущего клиента тестирования`n  И я подключаю TestClient `"U5`" логин `"U5`" пароль `"`"" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":2,"profiles":[]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath)

                @($topology.requiredProfiles).Count | Should -Be 0
                $topology.requiredTestClientSlots | Should -Be 2
                @($topology.profiles).Count | Should -Be 0
                ($topology | ConvertTo-Json -Depth 5) | Should -Not -Match "inline-secret"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "counts PM5-style table TestClients without reading credentials as profiles" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-table-client-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Table clients`nКонтекст:`n  Дано Я запускаю сценарий открытия TestClient или подключаю уже существующий`nСценарий: Direct table`n  Когда Я подключаю клиент тестирования с параметрами:`n    | 'Имя подключения' | 'Логин' | 'Пароль' |`n    | 'НРС U5' | 'U5' | 'table-secret' |`n  И я закрываю TestClient `"НРС U5`"" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":2,"profiles":[]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath)

                @($topology.requiredProfiles).Count | Should -Be 0
                $topology.requiredTestClientSlots | Should -Be 2
                @($topology.profiles).Count | Should -Be 0
                ($topology | ConvertTo-Json -Depth 5) | Should -Not -Match "table-secret"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps profile requirements separate from a current-client concurrency baseline" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-current-profile-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Current and profile`nКонтекст:`n  Дано Я запускаю сценарий открытия TestClient или подключаю уже существующий`nСценарий: Additional profile`n  И я подключаю профиль TestClient `"U1`"`n  И я закрываю TestClient `"U1`"" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":2,"profiles":[{"name":"U1"}]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath)

                $topology.requiredProfiles | Should -Be @("U1")
                $topology.requiredTestClientSlots | Should -Be 2
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "limits profile preflight to scenarios selected by the tag filter" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-filtered-profiles-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Filtered profiles`n@V28`nСценарий: Selected`n  Дано я подключаю профиль TestClient `"SelectedProfile`"`nСценарий: Not selected`n  Дано я подключаю профиль TestClient `"MissingProfile`"" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"SelectedProfile"}]}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $topology = Get-VanessaTestClientTopology -FeatureFiles @($fixture.featurePath) -FilterTags "@V28"
                $topology.requiredProfiles | Should -Be @("SelectedProfile")
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "excludes Libraries from directory preflight and count while preserving an explicit single feature" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-application-features-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Application`n@Selected`nСценарий: Application scenario`n  Дано я подключаю профиль TestClient `"AppProfile`"" `
                -ManifestText '{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"AppProfile"}]}'
            $libraryPath = Join-Path $tempRoot "tests\features\Libraries\library.feature"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $libraryPath) | Out-Null
            Set-Content -LiteralPath $libraryPath -Encoding UTF8 -Value "# language: ru`nФункционал: Library`n@Selected`nСценарий: Library scenario`n  Дано я подключаю профиль TestClient `"LibraryProfile`""

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $applicationFiles = @(Get-VanessaApplicationFeatureFiles -FeaturePath "tests/features")
                $topology = Get-VanessaTestClientTopology -FeatureFiles $applicationFiles -FilterTags "@Selected"
                $count = Get-VanessaFilteredScenarioCount -FeatureFiles $applicationFiles -FilterTags "@Selected"
                $explicitLibrary = @(Get-VanessaApplicationFeatureFiles -FeaturePath $libraryPath)

                $applicationFiles | Should -Be @($fixture.featurePath)
                $topology.requiredProfiles | Should -Be @("AppProfile")
                $count | Should -Be 1
                $explicitLibrary | Should -Be @($libraryPath)
                { Get-VanessaTestClientTopology -FeatureFiles $explicitLibrary -FilterTags "@Selected" } | Should -Throw "*LibraryProfile*"
            }

            $helperText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
            $runStart = $helperText.IndexOf("function Run-DevBranchTests")
            $runEnd = $helperText.IndexOf("function ConvertTo-IntOrDefault", $runStart)
            $runText = $helperText.Substring($runStart, ($runEnd - $runStart))
            $runText | Should -Match 'Get-VanessaApplicationFeatureFiles -FeaturePath \$featuresPath'
            $runText | Should -Match 'Get-VanessaTestClientTopology -FeatureFiles \$applicationFeatureFiles'
            $runText | Should -Match 'Get-VanessaFilteredScenarioCount -FeatureFiles \$applicationFeatureFiles'
            $runText | Should -Match '(?s)New-VanessaParamsFile.*?-FeaturePath \$featuresPath'
            $runText | Should -Match '-InfoBasePath \$serviceInfoBase\.path'
            $runText | Should -Match '-ExpectedSessionCount 1'
            $runText | Should -Match '(?s)-AdditionalSessionAdmissions.*?infoBasePath = \[string\]\$state\.devBranchInfoBasePath.*?requiredSessions = \[int\]\$testClientTopology\.requiredTestClientSlots.*?expectedChildRole = "test-client"'
            $runText | Should -Not -Match 'Assert-VanessaTestClientCapacity'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "normalizes the official filtertags array and proves selection from JUnit count" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-tags-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-VanessaRunnerFixture `
                -Root $tempRoot `
                -FeatureText "# language: ru`nФункционал: Tags`n@V28`nСценарий: Selected`n  Тогда Истина равна Истине`nСценарий: Not selected`n  Тогда Истина равна Истине" `
                -ManifestText $null
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $expected = Get-VanessaFilteredScenarioCount -FeatureFiles @($fixture.featurePath) -FilterTags "@V28"
                $expected | Should -Be 1

                $paramsPath = New-VanessaParamsFile `
                    -FeaturePath $fixture.featurePath `
                    -RunDirectory $fixture.runDirectory `
                    -StatusPath (Join-Path $fixture.runDirectory "status.json") `
                    -State $fixture.state `
                    -TestPort 48051 `
                    -FilterTags "@V28"
                $params = Get-Content -Raw -Encoding UTF8 $paramsPath | ConvertFrom-Json
                @($params.filtertags) | Should -Be @("V28")
                $params.PSObject.Properties.Name | Should -Not -Contain "tags"

                Set-Content -LiteralPath (Join-Path $fixture.runDirectory "junit.xml") -Encoding UTF8 -Value '<testsuite tests="1" failures="0" errors="0"><testcase name="Selected"/></testsuite>'
                $evidence = Assert-VanessaTagFilterJunitEvidence -RunDirectory $fixture.runDirectory -ExpectedScenarioCount $expected -FilterTags "@V28"
                $evidence.junitScenarioCount | Should -Be 1

                Set-Content -LiteralPath (Join-Path $fixture.runDirectory "junit.xml") -Encoding UTF8 -Value '<testsuite tests="2" failures="0" errors="0"><testcase name="Selected"/><testcase name="Not selected"/></testsuite>'
                { Assert-VanessaTagFilterJunitEvidence -RunDirectory $fixture.runDirectory -ExpectedScenarioCount $expected -FilterTags "@V28" } | Should -Throw "*ITL_VANESSA_TAG_FILTER_COUNT_MISMATCH*"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Vanessa verification failure classification" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $VanessaPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1"
        $VanessaText = Get-Content -Encoding UTF8 -Raw $VanessaPath
    }

    It "classifies a JUnit TestClient connection timeout with PID zero as runner-owned" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-status-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
                $xml = @(
                    '<?xml version="1.0" encoding="UTF-8"?>'
                    '<testsuites>'
                    '  <testsuite name="suite" tests="1" failures="1" errors="0">'
                    '    <testcase name="connect profile">'
                    '      <error>Не получилось подключить TestClient. Прерывание по таймауту &lt;300&gt;'
                    'Порт запуска=48068'
                    'PID=0'
                    'password=DO_NOT_LEAK</error>'
                    '    </testcase>'
                    '  </testsuite>'
                    '</testsuites>'
                ) -join [Environment]::NewLine
                [IO.File]::WriteAllText((Join-Path $tempRoot "junit.xml"), $xml, (Get-Utf8Encoding))
                Get-VanessaVerificationStatus -RunDirectory $tempRoot -StatusPath (Join-Path $tempRoot "status.json")
            }

            $result.status | Should -Be "failed"
            $result.failureCategory | Should -Be "runner"
            $result.reason | Should -Match 'Не получилось подключить TestClient'
            $result.reason | Should -Match 'PID=0'
            $result.reason | Should -Match '<redacted>'
            $result.reason | Should -Not -Match 'DO_NOT_LEAK'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not relabel an ordinary product assertion as a runner failure" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-status-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
                $xml = @(
                    '<testsuite name="suite" tests="1" failures="1" errors="0">'
                    '  <testcase name="product assertion">'
                    '    <failure message="Expected 2, got 3">The form value differs from the fixture.</failure>'
                    '  </testcase>'
                    '</testsuite>'
                ) -join [Environment]::NewLine
                [IO.File]::WriteAllText((Join-Path $tempRoot "junit.xml"), $xml, (Get-Utf8Encoding))
                Get-VanessaVerificationStatus -RunDirectory $tempRoot -StatusPath (Join-Path $tempRoot "status.json")
            }

            $result.status | Should -Be "failed"
            $result.failureCategory | Should -Be ""
            $result.reason | Should -Match 'Expected 2, got 3'
            $VanessaText | Should -Match '(?s)failureCategory.*?-eq "runner".*?Set-RunFailureContext -Category "runner"'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "requires both connection failure and startup evidence for runner classification" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                connectionOnly = Test-VanessaTestClientConnectionFailure -Diagnostic "Не удалось подключить клиент тестирования: product fixture expected another message"
                timeoutOnly = Test-VanessaTestClientConnectionFailure -Diagnostic "PID=0 after a generic platform timeout"
                complete = Test-VanessaTestClientConnectionFailure -Diagnostic "Не удалось подключить клиент тестирования. PIDКлиентаТестирования: 0"
            }
        }

        $result.connectionOnly | Should -BeFalse
        $result.timeoutOnly | Should -BeFalse
        $result.complete | Should -BeTrue
    }

    It "stops waiting when a named profile Out file exists but its process vanished before observation" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-startup-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
                $infoBasePath = Join-Path $tempRoot "ib"
                New-Item -ItemType Directory -Force -Path $infoBasePath | Out-Null
                $paramsPath = Join-Path $tempRoot "VAParams.json"
                Set-Content -LiteralPath $paramsPath -Encoding UTF8 -Value '{}'
                $outputPath = Join-Path $tempRoot "ProfileOne_20260810235003.txt"
                Set-Content -LiteralPath $outputPath -Encoding UTF8 -Value ""
                (Get-Item -LiteralPath $outputPath).CreationTime = (Get-Date).AddSeconds(-10)
                $state = [pscustomobject]@{ infoBaseKind = "file"; devBranchInfoBasePath = $infoBasePath }
                $monitor = New-VanessaTestClientStartupMonitor -RunDirectory $tempRoot -ProfileNames @("ProfileOne") -ExitDetectionSeconds 1
                function Get-OneCProcessInfo { return @() }
                $completed = Test-VanessaTestClientStartupMonitor -Monitor $monitor -State $state -TestPorts @(48067) -RunParamsPath $paramsPath
                [pscustomobject]@{ completed = $completed; failure = $monitor.failure }
            }

            $result.completed | Should -BeTrue
            $result.failure.code | Should -Be "ITL_VANESSA_TESTCLIENT_STARTUP_EXITED"
            $result.failure.profileName | Should -Be "ProfileOne"
            $result.failure.processObserved | Should -BeFalse
            $result.failure.processId | Should -Be 0
            $result.failure.outputPath | Should -Be (Join-Path $tempRoot "ProfileOne_20260810235003.txt")
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps waiting when the exact owned TestClient Out process is observable" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-startup-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
                $infoBasePath = Join-Path $tempRoot "ib"
                New-Item -ItemType Directory -Force -Path $infoBasePath | Out-Null
                $paramsPath = Join-Path $tempRoot "VAParams.json"
                Set-Content -LiteralPath $paramsPath -Encoding UTF8 -Value '{}'
                $outputPath = Join-Path $tempRoot "ProfileOne_20260810235003.txt"
                Set-Content -LiteralPath $outputPath -Encoding UTF8 -Value ""
                (Get-Item -LiteralPath $outputPath).CreationTime = (Get-Date).AddSeconds(-10)
                $state = [pscustomobject]@{ infoBaseKind = "file"; devBranchInfoBasePath = $infoBasePath; vanessaServiceInfoBasePath = (Join-Path $tempRoot "service") }
                $monitor = New-VanessaTestClientStartupMonitor -RunDirectory $tempRoot -ProfileNames @("ProfileOne") -ExitDetectionSeconds 1
                $script:fixtureCommandLine = "1cv8c.exe /TESTCLIENT /F `"$infoBasePath`" -TPort 48067 /Out `"$outputPath`""
                function Get-OneCProcessInfo { return @([pscustomobject]@{ processId = 7811; commandLine = $script:fixtureCommandLine }) }
                $completed = Test-VanessaTestClientStartupMonitor -Monitor $monitor -State $state -TestPorts @(48067) -RunParamsPath $paramsPath
                $candidate = @($monitor.candidates.Values)[0]
                [pscustomobject]@{ completed = $completed; failure = $monitor.failure; candidate = $candidate }
            }

            $result.completed | Should -BeFalse
            $result.failure | Should -BeNullOrEmpty
            $result.candidate.processObserved | Should -BeTrue
            $result.candidate.processId | Should -Be 7811
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
