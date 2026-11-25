BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryIntegrity.TestSupport.ps1') }

Describe 'Exact qualified source candidate before external publication' {
It 'refuses finalizer worktree changes before push and repeats finalization without repeating Develop' {
        $fixture=$null; $prior=[Environment]::GetEnvironmentVariable('ITL_TEST_MUTATE_PUBLICATION_STAGE','Process')
        try {
            $fixture=New-FrozenFixture
            Add-IntegrityFixtureCallback $fixture finalizer
            $candidate=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $env:ITL_TEST_MUTATE_PUBLICATION_STAGE='finalizer'
            $failed=Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure
            $failed.exitCode | Should -Not -Be 0
            $failed.stderr | Should -Match 'DELIVERY_CANDIDATE_INTEGRITY'
            $failed.stderr | Should -Match 'dirty records 1'
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/alpha/head).Trim() | Should -Be $candidate
            $attempt=Read-FrozenAttempt $fixture
            $attempt.candidate | Should -Be $candidate
            $attempt.phase | Should -Be 'develop-qualified'
            $attempt.componentPublication | Should -BeNullOrEmpty
            $env:ITL_TEST_MUTATE_PUBLICATION_STAGE=$null
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop @('-ResumePlan',[string]$attempt.planId)).stdout | ConvertFrom-Json
            $published.commit | Should -Be $candidate
            $published.planId | Should -Be $attempt.planId
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $candidate
            @((Get-Content -LiteralPath $fixture.modeLog) | Where-Object {$_ -eq 'Develop'}).Count | Should -Be 1
            @(Get-Content -LiteralPath $fixture.finalizerLog).Count | Should -Be 2
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue).Count | Should -Be 0
        } finally {
            [Environment]::SetEnvironmentVariable('ITL_TEST_MUTATE_PUBLICATION_STAGE',$prior,'Process')
            Remove-DeliveryFixture -Fixture $fixture
        }
    }
}
