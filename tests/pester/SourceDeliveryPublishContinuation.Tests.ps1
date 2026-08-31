BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
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
}
