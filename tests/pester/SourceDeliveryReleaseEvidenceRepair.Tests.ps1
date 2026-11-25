BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryEvidence.TestSupport.ps1') }
Describe 'Selective Release proof repair' {
    It 'replaces only the rejected Release proof and retains the valid Develop qualification' {
        $fixture=$null; $prior=$env:ITL_TEST_FAIL_COMPONENT_FINALIZER
        try {
            $fixture=New-DeliveryProofFixture
            $stand=Join-Path $TestDrive 'Release proof путь'
            New-FrozenStand -Root $stand
            $extra=@('-RequireRelease','-E2EProjectRoot',('"'+$stand+'"'))
            $alpha=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER='true'
            (Invoke-FrozenDelivery $fixture PublishDevelop $extra -AllowFailure).exitCode | Should -Not -Be 0
            $attempt=Read-FrozenAttempt $fixture
            $attempt.phase | Should -Be 'release-qualified'
            $planId=[string]$attempt.planId
            $releasePath=@(Get-ChildItem -LiteralPath (Join-Path $fixture.root '.git/itl/evidence/v1/release.custom-gate') -Filter evidence.json -Recurse).FullName
            @($releasePath).Count | Should -Be 1
            $developPath=@(Get-ChildItem -LiteralPath (Join-Path $fixture.root '.git/itl/evidence/v1/develop.custom-gate') -Filter evidence.json -Recurse).FullName
            $developBytes=[IO.File]::ReadAllText($developPath)
            $record=Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8 | ConvertFrom-Json
            [IO.File]::WriteAllText([string]$record.proof.path,'rejected Release proof',[Text.UTF8Encoding]::new($false))
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$null
            $refused=Invoke-FrozenDelivery $fixture PublishDevelop $extra -AllowFailure
            $refused.exitCode | Should -Not -Be 0
            $refused.stderr | Should -Match 'DELIVERY_STAGE_EVIDENCE_CORRUPT'
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 1
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Release'}).Count | Should -Be 1
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop ($extra+@('-Replan',$planId))).stdout | ConvertFrom-Json
            $published.commit | Should -BeExactly $alpha
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 1
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Release'}).Count | Should -Be 2
            [IO.File]::ReadAllText($developPath) | Should -BeExactly $developBytes
            $repaired=Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8 | ConvertFrom-Json
            (Get-FileHash -LiteralPath ([string]$repaired.proof.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly ([string]$repaired.proof.sha256)
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue).Count | Should -Be 0
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$prior; Remove-DeliveryFixture $fixture }
    }
}
