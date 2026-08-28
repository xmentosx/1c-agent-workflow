BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
    It "enriches a legacy exact-tree qualification cache with optional Develop route reports" {
            $fixture = $null; try {
                $fixture = New-DeliveryFixture
                New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
                Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\LegacyCache.Tests.ps1") -Encoding UTF8 -Value "Describe 'legacy cache' { It 'works' { `$true | Should -BeTrue } }"
                & git -C $fixture.root add --all
                & git -C $fixture.root commit -m "test: legacy candidate cache" *> $null
                $candidateTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
                $candidateCache = Join-Path $fixture.root ".git\itl\qualifications\$candidateTree"
                New-Item -ItemType Directory -Force -Path $candidateCache | Out-Null
                foreach ($name in @("full.json", "develop.json", "develop-e2e-summary.json")) {
                    Set-Content -LiteralPath (Join-Path $candidateCache $name) -Encoding UTF8 -Value '{}'
                }
                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "legacy-cache") | Out-Null

                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) | Out-Null

                @((Get-Content -LiteralPath $fixture.developBaseLog -Encoding UTF8)) | Should -Be @($fixture.base)
                (Get-Content -LiteralPath (Join-Path $candidateCache "develop-e2e-upgrade.json") -Raw -Encoding UTF8 | ConvertFrom-Json).source | Should -Be "candidate-upgrade"
                (Get-Content -LiteralPath (Join-Path $candidateCache "develop-e2e-fresh.json") -Raw -Encoding UTF8 | ConvertFrom-Json).source | Should -Be "candidate-fresh"
            } finally { Remove-DeliveryFixture -Fixture $fixture }
        }

    It "publishes develop only after the exact candidate passes Develop and required Release" {
            $fixture = $null; $oldFailure = $env:ITL_TEST_FAIL_DELIVERY_RELEASE
            try {
                $fixture = New-DeliveryFixture
                Set-DeliveryAiRulesLock -Fixture $fixture -CompatibilityStatus "pending"
                New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
                Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ReleaseQualified.Tests.ps1") -Encoding UTF8 -Value "Describe 'release-qualified publish' { It 'works' { `$true | Should -BeTrue } }"
                & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: release-qualified publish" *> $null
                $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
                Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue

                $env:ITL_TEST_FAIL_DELIVERY_RELEASE = "true"
                $failed = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'), "-CompatibilityPromoterScript", ('"' + $fixture.promoter + '"')) -AllowFailure
                $failed.exitCode | Should -Not -Be 0
                (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Not -Be $candidate
                @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -Not -BeNullOrEmpty
                @(& git -C $fixture.root for-each-ref refs/itl/develop-promotions) | Should -Not -BeNullOrEmpty
                @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Full", "Develop", "Release")
                @((Get-Content -LiteralPath $fixture.promoterLog -Encoding UTF8)).Count | Should -Be 1
                @((Get-Content -LiteralPath $fixture.releaseResumeLog -Encoding UTF8)) | Should -Be @("Auto")

                Remove-Item -LiteralPath $fixture.modeLog -Force
                Remove-Item -LiteralPath $fixture.releaseResumeLog -Force
                $env:ITL_TEST_FAIL_DELIVERY_RELEASE = "false"
                $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-ReleaseResumeMode", "Restart", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'), "-CompatibilityPromoterScript", ('"' + $fixture.promoter + '"'))
                $payload = $published.stdout | ConvertFrom-Json
                $payload.releaseQualified | Should -BeTrue
                $payload.developPublished | Should -BeTrue
                $payload.dependenciesInstallable | Should -BeTrue
                $payload.masterReleased | Should -BeFalse
                $payload.aiRulesCompatibility | Should -Be "passed"
                $payload.commit | Should -Not -Be $candidate
                & git -C $fixture.root merge-base --is-ancestor $candidate $payload.commit
                $LASTEXITCODE | Should -Be 0
                (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $payload.commit
                $publishedLock = (& git --git-dir=$($fixture.remote) show "$($payload.commit):templates/dependency-lock.json") | ConvertFrom-Json
                $publishedLock.dependencies.aiRules1c.compatibilityStatus | Should -Be "passed"
                @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Release")
                @((Get-Content -LiteralPath $fixture.promoterLog -Encoding UTF8)).Count | Should -Be 1
                @((Get-Content -LiteralPath $fixture.releaseResumeLog -Encoding UTF8)) | Should -Be @("Restart")
                @(& git -C $fixture.root for-each-ref refs/itl/develop-promotions) | Should -BeNullOrEmpty
                @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
            } finally {
                $env:ITL_TEST_FAIL_DELIVERY_RELEASE = $oldFailure
                Remove-DeliveryFixture -Fixture $fixture
            }
        }

    It "blocks a third identical failed stage run without repeating passed broad gates" {
            $fixture = $null; $oldFailure = $env:ITL_TEST_FAIL_DELIVERY_RELEASE
            try {
                $fixture = New-DeliveryFixture
                New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
                Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\CircuitBreaker.Tests.ps1") -Encoding UTF8 -Value "Describe 'publication circuit breaker' { It 'works' { `$true | Should -BeTrue } }"
                & git -C $fixture.root add --all; & git -C $fixture.root commit -m "test: publication circuit breaker" *> $null
                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
                Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue
                $env:ITL_TEST_FAIL_DELIVERY_RELEASE = "true"

                (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) -AllowFailure).exitCode | Should -Not -Be 0
                (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) -AllowFailure).exitCode | Should -Not -Be 0
                $beforeBlockedRetry = @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8))
                $blocked = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) -AllowFailure

                $blocked.exitCode | Should -Not -Be 0
                $blocked.stderr | Should -Match "same failure twice"
                @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be $beforeBlockedRetry
                $beforeBlockedRetry | Should -Be @("Develop", "Release", "Release")
            } finally {
                $env:ITL_TEST_FAIL_DELIVERY_RELEASE = $oldFailure
                Remove-DeliveryFixture -Fixture $fixture
            }
        }
}
