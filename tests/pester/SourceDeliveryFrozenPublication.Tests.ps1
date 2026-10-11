BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1') }

Describe 'Frozen source publication membership' {
    It 'resumes the original release candidate after an advanced queue and an independent registration' {
        $fixture=$null; $stand=Join-Path $TestDrive 'frozen stand'; $oldFailure=$env:ITL_TEST_FAIL_DELIVERY_RELEASE
        try {
            $fixture=New-FrozenFixture; New-FrozenStand -Root $stand
            $first=Add-FrozenTask -Fixture $fixture -Name alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $releaseArgs=@('-RequireRelease','-E2EProjectRoot',('"'+$stand+'"'))
            $env:ITL_TEST_FAIL_DELIVERY_RELEASE='true'
            (Invoke-FrozenDelivery $fixture PublishDevelop $releaseArgs -AllowFailure).exitCode | Should -Not -Be 0
            $attempt=Read-FrozenAttempt $fixture
            $attempt.candidate | Should -Be $first
            @($attempt.queue).Count | Should -Be 1
            $planId=[string]$attempt.planId
            $advanced=Add-FrozenTask -Fixture $fixture -Name later
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            & git -C $fixture.root switch --quiet -c beta $fixture.base
            $beta=Add-FrozenTask -Fixture $fixture -Name beta
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            $env:ITL_TEST_FAIL_DELIVERY_RELEASE=$null
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop ($releaseArgs+@('-ResumePlan',$planId))).stdout | ConvertFrom-Json
            $published.commit | Should -Be $first
            $published.planId | Should -Be $planId
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/alpha/head).Trim() | Should -Be $advanced
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/beta/head).Trim() | Should -Be $beta
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $first
            $next=(Invoke-FrozenDelivery $fixture PublishDevelop).stdout | ConvertFrom-Json
            & git -C $fixture.root merge-base --is-ancestor $advanced $next.commit
            $LASTEXITCODE | Should -Be 0
            & git -C $fixture.root merge-base --is-ancestor $beta $next.commit
            $LASTEXITCODE | Should -Be 0
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue).Count | Should -Be 0
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { $env:ITL_TEST_FAIL_DELIVERY_RELEASE=$oldFailure; Remove-DeliveryFixture $fixture }
    }
}
