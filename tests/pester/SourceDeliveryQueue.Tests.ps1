BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
It "registers Unicode queue refs atomically and rejects the original parallel conflict before publication" {
        $fixture = $null; $parallelRoot = ""; try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "скрипт с пробелами.ps1") -Encoding UTF8 -Value "'ok'"
            Set-Content -LiteralPath (Join-Path $tests "Behavior.Tests.ps1") -Encoding UTF8 -Value "Describe 'behavior' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: fixture" *> $null
            $head = (& git -C $fixture.root rev-parse HEAD).Trim()
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", '"codex/parallel branch"', "-CoverageContract", "contract-one,contract-two")
            $result.exitCode | Should -Be 0
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/codex/parallel-branch/base).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/codex/parallel-branch/head).Trim() | Should -Be $head
            $parallelRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl parallel worktree " + [guid]::NewGuid().ToString("N"))
            & git -C $fixture.root worktree add --quiet -b topic-two $parallelRoot $fixture.base *> $null
            New-Item -ItemType Directory -Force -Path (Join-Path $parallelRoot "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $parallelRoot "скрипт с пробелами.ps1") -Encoding UTF8 -Value "'conflicting second'"
            Set-Content -LiteralPath (Join-Path $parallelRoot "tests\pester\Second.Tests.ps1") -Encoding UTF8 -Value "Describe 'second' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $parallelRoot add --all; & git -C $parallelRoot commit -m "feat: parallel fixture" *> $null
            $conflict = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $parallelRoot + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "parallel-two") -AllowFailure
            $conflict.exitCode | Should -Not -Be 0
            $conflict.stderr | Should -Match 'conflicts with the develop candidate'
            $status = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))
            $statusPayload = $status.stdout | ConvertFrom-Json
            @($statusPayload.queue.id) | Should -Be @("codex/parallel-branch")
            [int]($statusPayload.runHistory.byMode | Where-Object mode -eq Targeted | Select-Object -ExpandProperty count) | Should -Be 1
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -HaveCount 2
            (& git -C $fixture.root rev-parse refs/itl/develop-candidate/head).Trim() | Should -Be $head
        } finally {
            if ($fixture -and $parallelRoot) { & git -C $fixture.root worktree remove --force $parallelRoot *> $null }
            Remove-DeliveryFixture -Fixture $fixture
        }
    }
It "targets only commits after the existing head of the same queue" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "first.ps1") -Encoding UTF8 -Value "'first'"
            Set-Content -LiteralPath (Join-Path $tests "First.Tests.ps1") -Encoding UTF8 -Value "Describe 'first' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: first queued change" *> $null
            $firstHead = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "same-queue") | Out-Null

            $baseTree = (& git -C $fixture.root rev-parse "$($fixture.base)^{tree}").Trim()
            $remoteHead = (& git -C $fixture.root commit-tree $baseTree -p $fixture.base -m "unrelated remote develop movement").Trim()
            & git -C $fixture.root push --quiet origin "$remoteHead`:refs/heads/develop" *> $null
            & git -C $fixture.root fetch --quiet origin develop *> $null
            (& git -C $fixture.root rev-parse origin/develop).Trim() | Should -Be $remoteHead

            Set-Content -LiteralPath (Join-Path $fixture.root "second.ps1") -Encoding UTF8 -Value "'second'"
            Set-Content -LiteralPath (Join-Path $tests "Second.Tests.ps1") -Encoding UTF8 -Value "Describe 'second' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: second queued change" *> $null
            $secondHead = (& git -C $fixture.root rev-parse HEAD).Trim()
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "same-queue")
            $payload = $result.stdout | ConvertFrom-Json

            @((Get-Content -LiteralPath $fixture.targetBaseLog -Encoding UTF8)) | Should -Be @($fixture.base, $firstHead)
            @($payload.paths | Sort-Object) | Should -Be @("second.ps1", "tests/pester/Second.Tests.ps1")
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/same-queue/base).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/same-queue/head).Trim() | Should -Be $secondHead
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
It "refuses executable changes without tests or an explicit reused contract" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'changed'"
            & git -C $fixture.root add behavior.ps1
            & git -C $fixture.root commit -m "feat: uncovered" *> $null
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure
            $result.exitCode | Should -Not -Be 0
            $result.stderr | Should -Match "must declare an existing -CoverageContract"
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
}
