BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
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
}
