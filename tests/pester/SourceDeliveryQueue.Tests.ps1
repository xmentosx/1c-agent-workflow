BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
    It 'admits a source-resolved published lock conflict before integrating develop and preserves queued work through failure' {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            $lockPath = Join-Path $fixture.root 'templates/dependency-lock.json'
            $writeRules = {
                param([int]$Revision, [string]$Status)
                Set-DeliveryAiRulesLock -Fixture $fixture -CompatibilityStatus $Status
                $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $lock.dependencies.aiRules1c.ref = 'rules-r' + $Revision
                $lock.dependencies.aiRules1c.downstreamRevision = $Revision
                [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            }
            & $writeRules 45 'pending'
            & git -C $fixture.root add templates/dependency-lock.json
            & git -C $fixture.root commit --quiet -m 'base rules 45'
            $base = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root push --quiet origin HEAD:develop
            & git -C $fixture.root fetch --quiet origin develop
            & git -C $fixture.root switch --quiet -c rules-46
            & $writeRules 46 'pending'
            & git -C $fixture.root add templates/dependency-lock.json
            & git -C $fixture.root commit --quiet -m 'pending rules 46'
            $argsBase = @('-Action','RegisterChange','-RepositoryRoot',('"'+$fixture.root+'"'),'-CoverageContract','contract-one,contract-two')
            $gateArgs = @('-GateScript',('"'+$fixture.gate+'"'))
            Invoke-DeliveryTestPowerShell -Arguments @($argsBase + $gateArgs + @('-QueueId','rules')) | Out-Null
            $oldRules = (& git -C $fixture.root rev-parse HEAD).Trim()

            & git -C $fixture.root switch --quiet -c unrelated $base
            Set-Content -LiteralPath (Join-Path $fixture.root 'накопленная работа.txt') -Value 'preserve unrelated queue' -Encoding UTF8
            & git -C $fixture.root add --all
            & git -C $fixture.root commit --quiet -m 'unrelated queued work'
            Invoke-DeliveryTestPowerShell -Arguments @($argsBase + $gateArgs + @('-QueueId','unrelated')) | Out-Null
            $oldCandidate = (& git -C $fixture.root rev-parse refs/itl/develop-candidate/head).Trim()
            $unrelatedHead = (& git -C $fixture.root rev-parse refs/itl/develop-queue/unrelated/head).Trim()
            $refsBefore = @(& git -C $fixture.root for-each-ref '--format=%(refname) %(objectname)' refs/itl/develop-queue refs/itl/develop-candidate)

            & git -C $fixture.root switch --quiet -c published-45 $base
            & $writeRules 45 'passed'
            & git -C $fixture.root add templates/dependency-lock.json
            & git -C $fixture.root commit --quiet -m 'published qualification of rules 45'
            & git -C $fixture.root push --quiet origin HEAD:develop
            & git -C $fixture.root fetch --quiet origin develop
            $published = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root switch --quiet rules-46
            Set-Content -LiteralPath (Join-Path $fixture.root 'продолжение r46.txt') -Value 'source work' -Encoding UTF8
            & git -C $fixture.root add --all
            & git -C $fixture.root commit --quiet -m 'continue rules source before resolution'
            # A source head without an explicit resolution must still fail closed.
            $unresolved = Invoke-DeliveryTestPowerShell -Arguments @($argsBase + $gateArgs + @('-QueueId','rules')) -AllowFailure
            $unresolved.exitCode | Should -Not -Be 0
            $unresolved.stderr | Should -Match 'conflicts with the develop candidate'
            @(& git -C $fixture.root for-each-ref '--format=%(refname) %(objectname)' refs/itl/develop-queue refs/itl/develop-candidate) | Should -Be $refsBefore
            @(Get-Content -LiteralPath $fixture.targetBaseLog -Encoding UTF8).Count | Should -Be 2

            & git -C $fixture.root merge --no-commit origin/develop *> $null
            $LASTEXITCODE | Should -Be 1
            . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
            @(Get-RepositoryGitPathList -RepositoryRoot $fixture.root -Arguments @('diff','--name-only','--diff-filter=U','-z')) | Should -Be @('templates/dependency-lock.json')
            & $writeRules 46 'pending'
            & git -C $fixture.root add templates/dependency-lock.json
            & git -C $fixture.root commit --quiet -m 'resolve published rules 45 while retaining pending rules 46'
            $resolvedHead = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root merge-base --is-ancestor $oldRules $resolvedHead
            $LASTEXITCODE | Should -Be 0
            & git -C $fixture.root merge-base --is-ancestor $published $resolvedHead
            $LASTEXITCODE | Should -Be 0

            Add-Content -LiteralPath (Join-Path $fixture.root 'README.md') -Value 'dirty guard remains strict'
            $dirty = Invoke-DeliveryTestPowerShell -Arguments @($argsBase + $gateArgs + @('-QueueId','rules')) -AllowFailure
            $dirty.exitCode | Should -Not -Be 0
            @(& git -C $fixture.root for-each-ref '--format=%(refname) %(objectname)' refs/itl/develop-queue refs/itl/develop-candidate) | Should -Be $refsBefore
            & git -C $fixture.root checkout -- README.md
            $failingGate = Join-Path $fixture.root 'build/failing-gate.ps1'
            Set-Content -LiteralPath $failingGate -Encoding UTF8 -Value 'param([string]$Mode,[string]$BaseRef,[string[]]$CoverageContract); exit 17'
            $failed = Invoke-DeliveryTestPowerShell -Arguments @($argsBase + @('-GateScript',('"'+$failingGate+'"'),'-QueueId','rules')) -AllowFailure
            $failed.exitCode | Should -Not -Be 0
            $failed.stderr | Should -Match 'Targeted source gate failed'
            @(& git -C $fixture.root for-each-ref '--format=%(refname) %(objectname)' refs/itl/develop-queue refs/itl/develop-candidate) | Should -Be $refsBefore

            $registered = Invoke-DeliveryTestPowerShell -Arguments @($argsBase + $gateArgs + @('-QueueId','rules'))
            $payload = $registered.stdout | ConvertFrom-Json
            $payload.status | Should -Be 'registered'
            $payload.head | Should -Be $resolvedHead
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/rules/base).Trim() | Should -Be $base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/unrelated/head).Trim() | Should -Be $unrelatedHead
            @(Get-Content -LiteralPath $fixture.targetBaseLog -Encoding UTF8)[-1] | Should -Be $oldCandidate
            $candidateLock = ((& git -C $fixture.root show "$($payload.candidate):templates/dependency-lock.json") -join "`n") | ConvertFrom-Json
            $candidateLock.dependencies.aiRules1c.downstreamRevision | Should -Be 46
            $candidateLock.dependencies.aiRules1c.compatibilityStatus | Should -Be 'pending'
            $candidateLock.dependencies.aiRules1c.compatibilityCheckedAt | Should -Be ''
            (& git -C $fixture.root show "$($payload.candidate):накопленная работа.txt").Trim() | Should -Be 'preserve unrelated queue'
            foreach ($ancestor in @($oldCandidate,$resolvedHead,$published,$unrelatedHead)) {
                & git -C $fixture.root merge-base --is-ancestor $ancestor $payload.candidate
                $LASTEXITCODE | Should -Be 0
            }
            # The blocked independent task can now register normally as well.
            & git -C $fixture.root switch --quiet -c cache-fix origin/develop
            Set-Content -LiteralPath (Join-Path $fixture.root 'cache-fix.txt') -Value 'independent cache repair'
            & git -C $fixture.root add --all
            & git -C $fixture.root commit --quiet -m 'independent cache repair'
            $cache = (Invoke-DeliveryTestPowerShell -Arguments @($argsBase + $gateArgs + @('-QueueId','cache'))).stdout | ConvertFrom-Json
            $cache.status | Should -Be 'registered'
            @(& git -C $fixture.root for-each-ref '--format=%(refname)' refs/itl/develop-queue) | Should -HaveCount 6
            $cacheLock = ((& git -C $fixture.root show "$($cache.candidate):templates/dependency-lock.json") -join "`n") | ConvertFrom-Json
            $cacheLock.dependencies.aiRules1c.downstreamRevision | Should -Be 46
            $cacheLock.dependencies.aiRules1c.compatibilityStatus | Should -Be 'pending'
            (& git -C $fixture.root rev-parse origin/develop).Trim() | Should -Be $published
            @(Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8) | Should -Be @('Targeted','Targeted','Targeted','Targeted')
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
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
