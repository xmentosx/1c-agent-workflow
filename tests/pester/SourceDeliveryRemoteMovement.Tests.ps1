BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1') }
Describe 'Pre-push remote movement recovery' {
    It 'preserves the original checkpoint and explicitly qualifies the new remote combination' {
        $fixture=$null; $prior=$env:ITL_TEST_FAIL_COMPONENT_FINALIZER
        try {
            $fixture=New-FrozenFixture
            $alpha=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER='true'
            (Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure).exitCode | Should -Not -Be 0
            $attempt=Read-FrozenAttempt $fixture
            $oldPlan=[string]$attempt.planId
            $checkpointPath=Join-Path $fixture.root '.git/itl/publication-attempts/develop.json'
            $checkpoint=[IO.File]::ReadAllText($checkpointPath)
            & git -C $fixture.root switch --quiet -c foreign $fixture.base
            $foreign=Add-FrozenTask $fixture foreign
            & git -C $fixture.root push --quiet origin HEAD:develop
            $LASTEXITCODE | Should -Be 0
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$null
            $refused=Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure
            $refused.exitCode | Should -Not -Be 0
            $refused.stderr | Should -Match 'DELIVERY_REMOTE_MOVED'
            $unwrapped=$refused.stderr.Replace("`r",'').Replace("`n",'')
            $unwrapped | Should -Match $fixture.base
            $unwrapped | Should -Match $foreign
            [IO.File]::ReadAllText($checkpointPath) | Should -BeExactly $checkpoint
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 1
            $planned=(Invoke-FrozenDelivery $fixture Plan).stdout | ConvertFrom-Json
            & git -C $fixture.root merge-base --is-ancestor $foreign $planned.candidate.commit
            $LASTEXITCODE | Should -Be 0
            [IO.File]::ReadAllText($checkpointPath) | Should -BeExactly $checkpoint
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$oldPlan)).stdout | ConvertFrom-Json
            $published.commit | Should -BeExactly $planned.candidate.commit
            $published.planId | Should -Not -Be $oldPlan
            foreach($head in @($alpha,$foreign)){ & git -C $fixture.root merge-base --is-ancestor $head $published.commit; $LASTEXITCODE | Should -Be 0 }
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 2
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue).Count | Should -Be 0
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$prior; Remove-DeliveryFixture $fixture }
    }
    It 'rebuilds a checkpoint that failed before pinning its plan from the re-registered fix' {
        $fixture=$null; $prior=$env:ITL_TEST_FAIL_DELIVERY_FULL
        try {
            $fixture=New-FrozenFixture
            Set-DeliveryAiRulesLock -Fixture $fixture -CompatibilityStatus 'pending'
            $broken=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $promoter=@('-CompatibilityPromoterScript',('"'+$fixture.promoter+'"'))
            $env:ITL_TEST_FAIL_DELIVERY_FULL='true'
            (Invoke-FrozenDelivery $fixture PublishDevelop $promoter -AllowFailure).exitCode | Should -Not -Be 0
            $attempt=Read-FrozenAttempt $fixture
            [string]$(if($attempt.PSObject.Properties['planId']){$attempt.planId}) | Should -BeNullOrEmpty
            @($attempt.queue.head) | Should -Be @($broken)
            $env:ITL_TEST_FAIL_DELIVERY_FULL=$null
            $fixed=Add-FrozenTask $fixture fix
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop $promoter).stdout | ConvertFrom-Json
            & git -C $fixture.root merge-base --is-ancestor $fixed $published.commit
            $LASTEXITCODE | Should -Be 0
            @(Get-ChildItem -LiteralPath (Join-Path $fixture.root '.git/itl/publication-attempts/replaced/unplanned') -Filter '*.json').Count | Should -Be 1
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Full'}).Count | Should -Be 2
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue).Count | Should -Be 0
        } finally { $env:ITL_TEST_FAIL_DELIVERY_FULL=$prior; Remove-DeliveryFixture $fixture }
    }
}
Describe 'Failing registered range deferral' {
    It 'defers the one range that alone fails, publishes the rest in the same operation, and re-registration lifts it' {
        $fixture=$null
        try {
            $fixture=New-FrozenFixture
            Set-DeliveryAiRulesLock -Fixture $fixture -CompatibilityStatus 'pending'
            # Attribution reruns only the failing files through the candidate's own runner.
            Set-Content -LiteralPath (Join-Path $fixture.root 'scripts/test.ps1') -Encoding UTF8 -Value "param([string[]]`$Path) if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot '..\broken.marker')) { exit 1 }; exit 0"
            & git -C $fixture.root add --all; & git -C $fixture.root commit --quiet -m 'test: focused runner'; & git -C $fixture.root push --quiet origin HEAD:develop
            $fixture.base=(& git -C $fixture.root rev-parse HEAD).Trim()
            $alpha=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            & git -C $fixture.root switch --quiet -c beta $fixture.base
            Set-Content -LiteralPath (Join-Path $fixture.root 'broken.marker') -Encoding UTF8 -Value 'tests/pester/beta.Tests.ps1'
            $beta=Add-FrozenTask $fixture beta
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            $promoter=@('-CompatibilityPromoterScript',('"'+$fixture.promoter+'"'))

            $run=Invoke-FrozenDelivery $fixture PublishDevelop $promoter
            $published=$run.stdout | ConvertFrom-Json
            & git -C $fixture.root merge-base --is-ancestor $alpha $published.commit; $LASTEXITCODE | Should -Be 0
            & git -C $fixture.root merge-base --is-ancestor $beta $published.commit; $LASTEXITCODE | Should -Not -Be 0
            @($published.deferredEntries.id) | Should -Be @('beta')
            $published.deferredEntries[0].reason | Should -Match 'tests/pester/beta\.Tests\.ps1'
            $status=(Invoke-FrozenDelivery $fixture Status).stdout | ConvertFrom-Json
            @($status.queue.id) | Should -Be @('beta')
            @($status.deferredQueue.id) | Should -Be @('beta')
            $status.deferredQueue[0].head | Should -Be $beta

            & git -C $fixture.root rm --quiet broken.marker
            Add-Content -LiteralPath (Join-Path $fixture.root 'tests/pester/beta.Tests.ps1') -Value '# fixed' -Encoding UTF8
            & git -C $fixture.root add --all; & git -C $fixture.root commit --quiet -m 'fix: beta'
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue/beta/deferred).Count | Should -Be 0
        } finally { Remove-DeliveryFixture $fixture }
    }
}
