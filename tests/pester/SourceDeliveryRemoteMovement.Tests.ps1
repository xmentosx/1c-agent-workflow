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
}
