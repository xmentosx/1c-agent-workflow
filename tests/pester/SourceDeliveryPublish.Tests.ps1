BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
    It "keeps function names unique across the split delivery implementation" {
            $names = foreach ($path in $DeliverySourcePaths) {
                $tokens = $null
                $parseErrors = $null
                $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
                @($parseErrors) | Should -BeNullOrEmpty
                @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
            }
            @($names | Group-Object | Where-Object Count -gt 1 | Select-Object -ExpandProperty Name) | Should -BeNullOrEmpty
        }

    It "publishes the qualified candidate and clears only reachable queue entries" {
            $fixture = $null; try {
                $fixture = New-DeliveryFixture
                $tests = Join-Path $fixture.root "tests\pester"
                New-Item -ItemType Directory -Force -Path $tests | Out-Null
                Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'published'"
                Set-Content -LiteralPath (Join-Path $tests "Behavior.Tests.ps1") -Encoding UTF8 -Value "Describe 'behavior' { It 'works' { `$true | Should -BeTrue } }"
                & git -C $fixture.root add --all
                & git -C $fixture.root commit -m "feat: publish" *> $null
                $head = (& git -C $fixture.root rev-parse HEAD).Trim()
                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "publish") | Out-Null
                $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
                $payload = $result.stdout | ConvertFrom-Json
                $payload.status | Should -Be "published"
                $payload.developPublished | Should -BeTrue
                $payload.dependenciesInstallable | Should -BeTrue
                $payload.masterReleased | Should -BeFalse
                $payload.aiRulesCompatibility | Should -Be "not-applicable"
                $finalizerRecord = Get-Content -LiteralPath $fixture.finalizerLog -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
                $finalizerRecord.candidateCommit | Should -Be $head
                $finalizerRecord.remoteHead | Should -Be $fixture.base
                $finalizerRecord.releaseQualified | Should -BeFalse
                (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $head
                $tree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
                Test-Path -LiteralPath (Join-Path $fixture.root ".git\itl\qualifications\$tree\develop.json") | Should -BeTrue
                @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
            } finally { Remove-DeliveryFixture -Fixture $fixture }
        }

    It "rejects a malformed component finalizer before broad qualification" {
            $fixture = $null
            $brokenFinalizer = Join-Path ([IO.Path]::GetTempPath()) ("itl-broken-finalizer-" + [guid]::NewGuid().ToString("N") + ".ps1")
            try {
                $fixture = New-DeliveryFixture
                New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
                Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\Preflight.Tests.ps1") -Encoding UTF8 -Value "Describe 'preflight' { It 'works' { `$true | Should -BeTrue } }"
                & git -C $fixture.root add --all
                & git -C $fixture.root commit -m "test: finalizer preflight" *> $null
                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
                Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue
                [IO.File]::WriteAllText($brokenFinalizer, "param([string]`$RepositoryRoot", [Text.UTF8Encoding]::new($false))

                $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $brokenFinalizer + '"')) -AllowFailure

                $result.exitCode | Should -Not -Be 0
                $result.stderr | Should -Match "parse errors"
                Test-Path -LiteralPath $fixture.modeLog | Should -BeFalse
                (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $fixture.base
                @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -Not -BeNullOrEmpty
            } finally {
                Remove-Item -LiteralPath $brokenFinalizer -Force -ErrorAction SilentlyContinue
                Remove-DeliveryFixture -Fixture $fixture
            }
        }

    It "classifies incompatible dependencies before qualification or push" {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Get-DependencyLockInstallability')) { Invoke-Expression $definition.Extent.Text }
            foreach ($status in @("pending", "failed", "")) {
                $lock = [pscustomobject]@{ dependencies = [pscustomobject]@{ aiRules1c = [pscustomobject]@{ ref = "itl-v1-r99"; compatibilityStatus = $status } } }
                $state = Get-DependencyLockInstallability -Lock $lock
                $state.installable | Should -BeFalse
                @($state.blockers).Count | Should -Be 1
            }
            $missing = Get-DependencyLockInstallability -Lock ([pscustomobject]@{ dependencies = [pscustomobject]@{ aiRules1c = [pscustomobject]@{ ref = "itl-v1-r99" } } })
            $missing.installable | Should -BeFalse
            $missing.aiRulesStatus | Should -Be "missing"
            (Get-DependencyLockInstallability -Lock ([pscustomobject]@{ dependencies = [pscustomobject]@{ aiRules1c = [pscustomobject]@{ ref = "itl-v1-r99"; compatibilityStatus = "passed" } } })).installable | Should -BeTrue
            $publisher = (Get-DeliveryFunctionDefinitions -Names @('Publish-AccumulatedDevelop')).Extent.Text
            $publisher.IndexOf('[void](Assert-DevelopCandidateInstallable -CandidateRoot $worktree.path)') | Should -BeLessThan $publisher.IndexOf('Invoke-SourceGate -Mode "Develop"')
            $publisher.IndexOf('Assert-ComponentPublicationFinalizerPreflight') | Should -BeLessThan $publisher.IndexOf('Invoke-SourceGate -Mode "Develop"')
            $publisher.LastIndexOf('Assert-DevelopCandidateInstallable -CandidateRoot $worktree.path') | Should -BeLessThan $publisher.IndexOf('@("push", $script:Remote')
            $promotion = (Get-DeliveryFunctionDefinitions -Names @('Invoke-DevelopCompatibilityPromotion')).Extent.Text
            $promotion | Should -Match 'Restore-DevelopCompatibilityQualification'
            $promotion.IndexOf('Write-DevelopPublicationAttempt -Attempt $Attempt') | Should -BeLessThan $promotion.IndexOf('Assert-DevelopPublicationStageMayRun -Attempt $Attempt -Stage "compatibility-promotion"')
        }

    It "passes origin develop as the Develop base and restores its route reports before the gate" {
            $fixture = $null; try {
                $fixture = New-DeliveryFixture
                $baseTree = (& git -C $fixture.root rev-parse "$($fixture.base)^{tree}").Trim()
                $baselineCache = Join-Path $fixture.root ".git\itl\qualifications\$baseTree"
                New-Item -ItemType Directory -Force -Path $baselineCache | Out-Null
                foreach ($name in @("full.json", "develop.json", "develop-e2e-summary.json")) {
                    Set-Content -LiteralPath (Join-Path $baselineCache $name) -Encoding UTF8 -Value '{}'
                }
                Set-Content -LiteralPath (Join-Path $baselineCache "develop-e2e-upgrade.json") -Encoding UTF8 -Value '{"source":"baseline-upgrade"}'
                Set-Content -LiteralPath (Join-Path $baselineCache "develop-e2e-fresh.json") -Encoding UTF8 -Value '{"source":"baseline-fresh"}'

                New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
                Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\Routing.Tests.ps1") -Encoding UTF8 -Value "Describe 'routing' { It 'works' { `$true | Should -BeTrue } }"
                & git -C $fixture.root add --all
                & git -C $fixture.root commit -m "test: route from develop baseline" *> $null
                $candidateTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "develop-route") | Out-Null

                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) | Out-Null

                @((Get-Content -LiteralPath $fixture.developBaseLog -Encoding UTF8)) | Should -Be @($fixture.base)
                $routeInput = Get-Content -LiteralPath $fixture.developRouteInputLog -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
                $routeInput.'develop-e2e-upgrade.json'.source | Should -Be "baseline-upgrade"
                $routeInput.'develop-e2e-fresh.json'.source | Should -Be "baseline-fresh"
                $candidateCache = Join-Path $fixture.root ".git\itl\qualifications\$candidateTree"
                (Get-Content -LiteralPath (Join-Path $candidateCache "develop-e2e-upgrade.json") -Raw -Encoding UTF8 | ConvertFrom-Json).source | Should -Be "candidate-upgrade"
                (Get-Content -LiteralPath (Join-Path $candidateCache "develop-e2e-fresh.json") -Raw -Encoding UTF8 | ConvertFrom-Json).source | Should -Be "candidate-fresh"
            } finally { Remove-DeliveryFixture -Fixture $fixture }
        }
}
