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

    It "promotes one exact qualified candidate through develop and master without repeating gates" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            & git -C $fixture.root push --quiet origin "HEAD:refs/heads/master" *> $null
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ReleaseTrain.Tests.ps1") -Encoding UTF8 -Value "Describe 'release train' { It 'works' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'release-train'"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: release train" *> $null
            $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue

            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PromoteRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
            $payload = $result.stdout | ConvertFrom-Json

            $payload.status | Should -Be "released"
            $payload.releaseTrain | Should -BeTrue
            $payload.qualificationReused | Should -BeTrue
            $payload.developPublished | Should -BeTrue
            $payload.masterReleased | Should -BeTrue
            $payload.developQualificationCommit | Should -Be $candidate
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $candidate
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/master).Trim() | Should -Be $candidate
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }

    It "resumes a durable release train after develop was published by an earlier process" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            & git -C $fixture.root push --quiet origin "HEAD:refs/heads/master" *> $null
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ResumeTrain.Tests.ps1") -Encoding UTF8 -Value "Describe 'resume train' { It 'works' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'resume-train'"
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: resume release train" *> $null
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue
            $published = (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))).stdout | ConvertFrom-Json
            $attemptPath = Join-Path $fixture.root ".git\itl\publication-attempts\develop.json"; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $attemptPath) | Out-Null
            $attempt = [ordered]@{ schemaVersion=1; phase='remote-pushed'; candidate=$published.commit; tree=$published.tree; requireRelease=$true; startedAt=$published.qualificationStartedAt }
            [IO.File]::WriteAllText($attemptPath, (($attempt | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

            $released = (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PromoteRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'))).stdout | ConvertFrom-Json
            $released.status | Should -Be 'released'; $released.resumedReleaseTrain | Should -BeTrue; $released.qualificationReused | Should -BeTrue
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @('Develop','Release')
            Test-Path -LiteralPath $attemptPath | Should -BeFalse
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

It "rebuilds the same merge candidate after a failed release" {
        $fixture = $null; $standRoot = $null; $oldFailure = $env:ITL_TEST_FAIL_DELIVERY_RELEASE
        try {
            $fixture = New-DeliveryFixture
            $standRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl delivery stand " + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path $standRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $standRoot ".dev.env") -Encoding UTF8 -Value "IDENTITY=before"
            & git -C $standRoot init | Out-Null
            & git -C $standRoot config user.email "itl-tests@example.invalid"
            & git -C $standRoot config user.name "ITL Tests"
            & git -C $standRoot add -- .dev.env
            & git -C $standRoot commit -m "test: create clean publication stand" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to create clean publication stand fixture." }
            $base = $fixture.base
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null

            & git -C $fixture.root switch --quiet -c task-z $base *> $null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ZChange.Tests.ps1") -Encoding UTF8 -Value "Describe 'z change' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit --quiet -m "test: add z change" *> $null
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "z-change") | Out-Null

            & git -C $fixture.root switch --quiet -c task-a $base *> $null
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\AChange.Tests.ps1") -Encoding UTF8 -Value "Describe 'a change' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit --quiet -m "test: add a change" *> $null
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "a-change") | Out-Null

            $env:ITL_TEST_FAIL_DELIVERY_RELEASE = "true"
            $failed = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'), "-E2EProjectRoot", ('"' + $standRoot + '"')) -AllowFailure
            $failed.exitCode | Should -Not -Be 0
            $failedCandidate = ((Get-Content -LiteralPath $fixture.candidateLog -Encoding UTF8 | Where-Object { $_ -like 'Release *' } | Select-Object -Last 1) -split ' ', 2)[1]
            $failedCandidate | Should -Match '^[0-9a-f]{40}$'
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8) | Where-Object { $_ -eq "Develop" }).Count | Should -Be 1

            $env:ITL_TEST_FAIL_DELIVERY_RELEASE = "false"
            Set-Content -LiteralPath (Join-Path $standRoot ".dev.env") -Encoding UTF8 -Value "IDENTITY=after"
            & git -C $standRoot add -- .dev.env
            & git -C $standRoot commit -m "test: change publication stand identity" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to change publication stand fixture identity." }
            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'), "-E2EProjectRoot", ('"' + $standRoot + '"'))
            $payload = $published.stdout | ConvertFrom-Json
            $payload.commit | Should -Be $failedCandidate
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $failedCandidate
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8) | Where-Object { $_ -eq "Develop" }).Count | Should -Be 2
        } finally {
            $env:ITL_TEST_FAIL_DELIVERY_RELEASE = $oldFailure
            if ($standRoot) { Remove-Item -LiteralPath $standRoot -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-DeliveryFixture -Fixture $fixture
        }
    }

It "imports an exact-tree qualification and revalidates Develop before Release" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\Continuation.Tests.ps1") -Encoding UTF8 -Value "Describe 'continuation' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "test: continuation candidate" *> $null
            $tree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue

            $qualification = Join-Path $fixture.root "build\test-results\qualification"
            New-Item -ItemType Directory -Force -Path $qualification | Out-Null
            [IO.File]::WriteAllText((Join-Path $qualification "full.json"), (([ordered]@{status="passed";repository=[ordered]@{tree=$tree}} | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $qualification "develop.json"), (([ordered]@{status="passed";repository=[ordered]@{tree=$tree}} | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $qualification "develop-e2e-summary.json") -Encoding UTF8 -Value '{}'

            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
            ($published.stdout | ConvertFrom-Json).releaseQualified | Should -BeTrue
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
            Test-Path -LiteralPath (Join-Path $fixture.root ".git\itl\qualifications\$tree\develop.json") | Should -BeTrue
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }

It "imports an ancestor qualification and revalidates Develop before Release" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            $catalog = [ordered]@{ continuationScopes = [ordered]@{ static = @("tests/pester/*"); gate = @(); develop = @(); release = @() } }
            [IO.File]::WriteAllText((Join-Path $fixture.root "tests\quality-contracts.json"), (($catalog | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "test: add continuation catalog" *> $null
            & git -C $fixture.root push --quiet origin develop *> $null
            $qualifiedCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            $qualifiedTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            $cache = Join-Path $fixture.root ".git\itl\qualifications\$qualifiedTree"
            New-Item -ItemType Directory -Force -Path $cache | Out-Null
            $qualification = [ordered]@{ status = "passed"; repository = [ordered]@{ commit = $qualifiedCommit; tree = $qualifiedTree } }
            foreach ($name in @("full.json", "develop.json")) {
                [IO.File]::WriteAllText((Join-Path $cache $name), (($qualification | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            }
            Set-Content -LiteralPath (Join-Path $cache "develop-e2e-summary.json") -Encoding UTF8 -Value '{}'

            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\Harness.Tests.ps1") -Encoding UTF8 -Value "Describe 'harness repair' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "test: repair harness" *> $null
            $candidateCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            $candidateTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            $runRoot = Join-Path $fixture.root ".git\itl\runs"
            New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
            $targeted = [ordered]@{ schemaVersion=1; mode="Targeted"; status="passed"; exitCode=0; commit=$candidateCommit; tree=$candidateTree; finishedAt=[DateTime]::UtcNow.ToString("o"); stages=@([ordered]@{name="pester";status="passed"},[ordered]@{name="tracked-state";status="passed"},[ordered]@{name="git-diff-check";status="passed"}) }
            [IO.File]::WriteAllText((Join-Path $runRoot "fixture-targeted-continuation.json"), (($targeted | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue

            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
            ($published.stdout | ConvertFrom-Json).releaseQualified | Should -BeTrue
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }

It "preserves the queue when origin develop moves during qualification" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content (Join-Path $fixture.root "tests\pester\Drift.Tests.ps1") "Describe 'drift' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: queued" *> $null
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            $failGate = Join-Path $fixture.root 'build\fail-gate.ps1'; New-Item -ItemType Directory -Force -Path (Split-Path $failGate) | Out-Null
            Set-Content -LiteralPath $failGate -Value 'param([string]$Mode, [string]$BaseRef, [string[]]$CoverageContract, [string]$AiRulesSource, [string]$E2EProjectRoot); exit 8'
            (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $failGate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) -AllowFailure).exitCode | Should -Not -Be 0
            $tree = (& git -C $fixture.root rev-parse "$($fixture.base)^{tree}").Trim()
            $drift = (& git -C $fixture.root commit-tree $tree -p $fixture.base -m "remote drift").Trim()
            $driftGate = Join-Path $fixture.root 'build\drift-gate.ps1'
            $driftBody = 'param([string]$Mode, [string]$BaseRef, [string[]]$CoverageContract, [string]$AiRulesSource, [string]$E2EProjectRoot); $q=Join-Path (Get-Location) ''build\test-results\qualification''; New-Item -ItemType Directory -Force -Path $q|Out-Null; foreach($n in @(''full.json'',''develop.json'',''develop-e2e-summary.json'')){Set-Content (Join-Path $q $n) ''{}''}; & git push origin ''__SHA__:refs/heads/develop'' *> $null; if($LASTEXITCODE -ne 0){exit 9}; exit 0'.Replace('__SHA__', $drift)
            Set-Content -LiteralPath $driftGate -Value $driftBody
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $driftGate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) -AllowFailure
            $result.exitCode | Should -Not -Be 0
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -Not -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }

It "never uses force push for develop or master" {
        $text = $DeliverySourceText; $text | Should -Not -Match 'push[^\r\n]*(--force|-f\b|--force-with-lease)'
        foreach ($marker in @('HEAD:refs/heads/develop', 'push", "--atomic"', 'HEAD:refs/heads/master')) { $text | Should -Match ([regex]::Escape($marker)) }
    }

It "uses a GitHub pull request for protected master and reconciles develop without force" {
        $fixture = $null
        $fakeBin = $null
        $oldPath = $env:PATH
        $oldGhScript = $env:ITL_TEST_GH_SCRIPT
        $oldGhRemote = $env:ITL_TEST_GH_REMOTE
        try {
            $fixture = New-DeliveryFixture
            & git --git-dir=$($fixture.remote) update-ref refs/heads/master $fixture.base
            Set-Content -LiteralPath (Join-Path $fixture.root "release.txt") -Encoding UTF8 -Value "qualified"
            & git -C $fixture.root add release.txt
            & git -C $fixture.root commit --quiet -m "feat: protected release" *> $null
            & git -C $fixture.root push --quiet origin develop *> $null
            $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
            $candidateTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()

            $fakeBin = Join-Path ([IO.Path]::GetTempPath()) ("fake gh путь " + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
            $fakeGhScript = Join-Path $fakeBin "fake-gh.ps1"
            [IO.File]::WriteAllText($fakeGhScript, @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)
if ($CliArgs[0] -eq 'repo' -and $CliArgs[1] -eq 'view') { 'fixture/repository'; exit 0 }
if ($CliArgs[0] -eq 'pr' -and $CliArgs[1] -eq 'list') { exit 0 }
if ($CliArgs[0] -eq 'pr' -and $CliArgs[1] -eq 'create') { 'https://github.com/fixture/repository/pull/17'; exit 0 }
if ($CliArgs[0] -eq 'pr' -and $CliArgs[1] -eq 'view') { '17'; exit 0 }
if ($CliArgs[0] -eq 'pr' -and $CliArgs[1] -eq 'merge') {
    if ($CliArgs -contains '--rebase') { "GraphQL: This branch can't be rebased"; exit 33 }
    if (-not ($CliArgs -contains '--squash')) { exit 34 }
    $line = @(& git --git-dir=$env:ITL_TEST_GH_REMOTE for-each-ref '--format=%(objectname) %(refname)' 'refs/heads/itl/release-master-*' | Select-Object -First 1)
    if (-not $line) { exit 31 }
    $parts = $line[0] -split ' ', 2
    $candidate = $parts[0]
    $releaseRef = $parts[1]
    $tree = (& git --git-dir=$env:ITL_TEST_GH_REMOTE rev-parse "$candidate^{tree}").Trim()
    $master = (& git --git-dir=$env:ITL_TEST_GH_REMOTE rev-parse refs/heads/master).Trim()
    $env:GIT_AUTHOR_NAME = 'GitHub Fixture'; $env:GIT_AUTHOR_EMAIL = 'fixture@example.invalid'
    $env:GIT_COMMITTER_NAME = 'GitHub Fixture'; $env:GIT_COMMITTER_EMAIL = 'fixture@example.invalid'
    $rebased = (& git --git-dir=$env:ITL_TEST_GH_REMOTE commit-tree $tree -p $master -m 'rebase protected release').Trim()
    & git --git-dir=$env:ITL_TEST_GH_REMOTE update-ref refs/heads/master $rebased $master
    if ($LASTEXITCODE -ne 0) { exit 32 }
    & git --git-dir=$env:ITL_TEST_GH_REMOTE update-ref -d $releaseRef $candidate
    'merged'; exit 0
}
exit 30
'@, [Text.UTF8Encoding]::new($false))
            $fakeGhCommand = @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ITL_TEST_GH_SCRIPT%" %*
exit /b %ERRORLEVEL%
'@
            [IO.File]::WriteAllText((Join-Path $fakeBin "gh.cmd"), $fakeGhCommand, [Text.Encoding]::ASCII)
            $env:ITL_TEST_GH_SCRIPT = $fakeGhScript
            $env:ITL_TEST_GH_REMOTE = $fixture.remote
            $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath

            $definitions = @(Get-DeliveryFunctionDefinitions -Names @(
                'Invoke-DeliveryGitHubCli',
                'Get-ReleaseRemoteCommit',
                'Complete-ReleaseDevelopReconciliation',
                'Publish-ReleaseThroughGitHubPullRequest'
            ) | ForEach-Object { $_.Extent.Text })
            $payload = & {
                param([string[]]$FunctionDefinitions, [string]$Root, [string]$Repository, [string]$Commit, [string]$Tree, [string]$ExpectedMaster)
                . (Join-Path $RepoRoot "scripts\git-path-list.ps1")
                function Invoke-WorktreeGit {
                    param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
                    return Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments -AllowFailure:$AllowFailure
                }
                foreach ($definition in $FunctionDefinitions) { Invoke-Expression $definition }
                $script:Remote = "origin"
                Publish-ReleaseThroughGitHubPullRequest -CandidateRoot $Root -Repository $Repository -Candidate $Commit -CandidateTree $Tree -ExpectedDevelop $Commit -ExpectedMaster $ExpectedMaster
            } $definitions $fixture.root "fixture/repository" $candidate $candidateTree $fixture.base

            $payload.mode | Should -Be "github-pull-request"
            $payload.pullRequest | Should -Be "17"
            $payload.masterCommit | Should -Not -Be $candidate
            (& git --git-dir=$($fixture.remote) rev-parse "$($payload.masterCommit)^{tree}").Trim() | Should -Be $candidateTree
            (& git --git-dir=$($fixture.remote) rev-parse "$($payload.developCommit)^{tree}").Trim() | Should -Be $candidateTree
            & git --git-dir=$($fixture.remote) merge-base --is-ancestor $payload.masterCommit $payload.developCommit
            $LASTEXITCODE | Should -Be 0
            $releaseSource = (Get-DeliveryFunctionDefinitions -Names @('Release-DevelopToMaster')).Extent.Text
            $releaseSource | Should -Match ([regex]::Escape('Publish-ReleaseThroughGitHubPullRequest'))
        } finally {
            $env:PATH = $oldPath
            if ($null -eq $oldGhScript) { Remove-Item Env:ITL_TEST_GH_SCRIPT -ErrorAction SilentlyContinue } else { $env:ITL_TEST_GH_SCRIPT = $oldGhScript }
            if ($null -eq $oldGhRemote) { Remove-Item Env:ITL_TEST_GH_REMOTE -ErrorAction SilentlyContinue } else { $env:ITL_TEST_GH_REMOTE = $oldGhRemote }
            Remove-DeliveryFixture -Fixture $fixture
            if ($fakeBin) { Remove-Item -LiteralPath $fakeBin -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
