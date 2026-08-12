BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
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
            ($result.stdout | ConvertFrom-Json).status | Should -Be "published"
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
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ReleaseQualified.Tests.ps1") -Encoding UTF8 -Value "Describe 'release-qualified publish' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: release-qualified publish" *> $null
            $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue

            $env:ITL_TEST_FAIL_DELIVERY_RELEASE = "true"
            $failed = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure
            $failed.exitCode | Should -Not -Be 0
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Not -Be $candidate
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -Not -BeNullOrEmpty
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
            @((Get-Content -LiteralPath $fixture.releaseResumeLog -Encoding UTF8)) | Should -Be @("Auto")

            Remove-Item -LiteralPath $fixture.modeLog -Force
            Remove-Item -LiteralPath $fixture.releaseResumeLog -Force
            $env:ITL_TEST_FAIL_DELIVERY_RELEASE = "false"
            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-ReleaseResumeMode", "Restart", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
            $payload = $published.stdout | ConvertFrom-Json
            $payload.releaseQualified | Should -BeTrue
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $candidate
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
            @((Get-Content -LiteralPath $fixture.releaseResumeLog -Encoding UTF8)) | Should -Be @("Restart")
        } finally {
            $env:ITL_TEST_FAIL_DELIVERY_RELEASE = $oldFailure
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
            (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $failGate + '"')) -AllowFailure).exitCode | Should -Not -Be 0
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
}
