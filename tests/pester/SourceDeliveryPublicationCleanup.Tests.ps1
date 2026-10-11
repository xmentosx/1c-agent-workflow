BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1') }

Describe 'Frozen source publication membership' {
    It 'retries an actual atomic cleanup collision and preserves the advanced registration' {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        . ([scriptblock]::Create((Get-DeliveryFunctionDefinitions @('Invoke-DeliveryGit','Invoke-QueueRefTransaction','Get-QueueEntries','Clear-PublishedQueueEntries'))))
        $fixture=$null
        try {
            $fixture=New-DeliveryFixture
            $first=Add-FrozenTask $fixture alpha
            $published=Add-FrozenTask $fixture beta
            $script:frozenAdvanced=Add-FrozenTask $fixture later
            $script:Root=$fixture.root; $script:QueueRoot='refs/itl/develop-queue'
            foreach($entry in @(@('alpha',$first),@('beta',$published))){
                & git -C $fixture.root update-ref "$script:QueueRoot/$($entry[0])/base" $fixture.base
                & git -C $fixture.root update-ref "$script:QueueRoot/$($entry[0])/head" $entry[1]
            }
            $frozen=@(Get-QueueEntries)
            $script:frozenCleanupCalls=0
            $script:frozenTransaction=(Get-Item Function:Invoke-QueueRefTransaction).ScriptBlock
            Mock Invoke-QueueRefTransaction {
                if($script:frozenCleanupCalls -eq 0){
                    & git -C $script:Root update-ref "$script:QueueRoot/alpha/head" $script:frozenAdvanced
                    if($LASTEXITCODE){throw 'Could not inject private registration movement'}
                }
                $script:frozenCleanupCalls++
                & $script:frozenTransaction -Commands $Commands
            }
            Clear-PublishedQueueEntries -PublishedCommit $published -Entries $frozen
            $script:frozenCleanupCalls | Should -Be 2
            (& git -C $fixture.root rev-parse "$script:QueueRoot/alpha/head").Trim() | Should -Be $script:frozenAdvanced
            (& git -C $fixture.root rev-parse "$script:QueueRoot/alpha/base").Trim() | Should -Be $fixture.base
            @(& git -C $fixture.root for-each-ref "$script:QueueRoot/beta").Count | Should -Be 0
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { Remove-DeliveryFixture $fixture }
    }

    It 'finishes after a real post-push cleanup failure without requalifying or losing a new registration' {
        $fixture=$null; $lockPath=$null
        try {
            $fixture=New-FrozenFixture
            $first=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $injected=Join-Path $fixture.root 'build/locking-finalizer.ps1'
            $body=Get-Content -LiteralPath $fixture.finalizer -Raw -Encoding UTF8
            $at=$body.LastIndexOf('exit 0',[StringComparison]::Ordinal)
            if($at -lt 0){throw 'Fixture finalizer exit changed'}
            $hook=@'
$lock=Join-Path $SourceRepositoryRoot '.git/refs/itl/develop-queue/alpha/head.lock'
[IO.File]::WriteAllText($lock,'private test fault')
'@
            [IO.File]::WriteAllText($injected,($body.Substring(0,$at)+$hook+"`n"+$body.Substring($at)),[Text.UTF8Encoding]::new($true))
            $fixture.finalizer=$injected
            $lockPath=Join-Path $fixture.root '.git/refs/itl/develop-queue/alpha/head.lock'
            (Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure).exitCode | Should -Not -Be 0
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $first
            (Read-FrozenAttempt $fixture).phase | Should -Be 'remote-pushed'
            # Remove only the fault created above in this disposable fixture.
            Remove-Item -LiteralPath $lockPath -Force
            & git -C $fixture.root switch --quiet -c beta $fixture.base
            $beta=Add-FrozenTask $fixture beta
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            $before=@(Get-Content -LiteralPath $fixture.modeLog | Where-Object {$_ -ne 'Targeted'})
            $recovered=(Invoke-FrozenDelivery $fixture PublishDevelop).stdout | ConvertFrom-Json
            $recovered.recovered | Should -BeTrue
            $recovered.commit | Should -Be $first
            @(Get-Content -LiteralPath $fixture.modeLog | Where-Object {$_ -ne 'Targeted'}) | Should -Be $before
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/beta/head).Trim() | Should -Be $beta
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue/alpha).Count | Should -Be 0
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { Remove-DeliveryFixture $fixture }
    }
    It 'recovers the original qualified candidate after cleanup failed and remote develop advanced' {
        $fixture=$null
        try {
            $fixture=New-FrozenFixture
            $first=Add-FrozenTask $fixture alpha
            $firstTree=(& git -C $fixture.root rev-parse "$first^{tree}").Trim()
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $injected=Join-Path $fixture.root 'build/locking-finalizer.ps1'
            $body=Get-Content -LiteralPath $fixture.finalizer -Raw -Encoding UTF8
            $at=$body.LastIndexOf('exit 0',[StringComparison]::Ordinal)
            if($at -lt 0){throw 'Fixture finalizer exit changed'}
            $hook=@'
$lock=Join-Path $SourceRepositoryRoot '.git/refs/itl/develop-queue/alpha/head.lock'
[IO.File]::WriteAllText($lock,'private test fault')
'@
            [IO.File]::WriteAllText($injected,($body.Substring(0,$at)+$hook+"`n"+$body.Substring($at)),[Text.UTF8Encoding]::new($true))
            $fixture.finalizer=$injected
            (Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure).exitCode | Should -Not -Be 0
            $attempt=Read-FrozenAttempt $fixture
            $attempt.phase | Should -Be 'remote-pushed'
            $planId=[string]$attempt.planId
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $first
            # Remove only this fixture's injected fault; no runtime lock is bypassed.
            Remove-Item -LiteralPath (Join-Path $fixture.root '.git/refs/itl/develop-queue/alpha/head.lock') -Force
            & git -C $fixture.root switch --quiet -c remote-advance $first
            $later=Add-FrozenTask $fixture foreign
            & git -C $fixture.root push --quiet origin HEAD:develop
            $LASTEXITCODE | Should -Be 0
            & git -C $fixture.root switch --quiet -c beta $fixture.base
            $beta=Add-FrozenTask $fixture beta
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            $before=@(Get-Content -LiteralPath $fixture.modeLog | Where-Object {$_ -ne 'Targeted'})
            $finalizerBefore=@(Get-Content -LiteralPath $fixture.finalizerLog)
            $recovered=(Invoke-FrozenDelivery $fixture PublishDevelop @('-ResumePlan',$planId)).stdout | ConvertFrom-Json
            $recovered.recovered | Should -BeTrue
            $recovered.commit | Should -BeExactly $first
            $recovered.tree | Should -BeExactly $firstTree
            $recovered.remoteHead | Should -BeExactly $later
            @(Get-Content -LiteralPath $fixture.modeLog | Where-Object {$_ -ne 'Targeted'}) | Should -Be $before
            @(Get-Content -LiteralPath $fixture.finalizerLog) | Should -Be $finalizerBefore
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/beta/head).Trim() | Should -Be $beta
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue/alpha).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $fixture.root '.git/itl/publication-attempts/develop.json') | Should -BeFalse
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -BeExactly $later
            $stateBefore=(& git -C $fixture.root rev-parse refs/itl/develop-candidate/state).Trim()
            $closed=(Invoke-FrozenDelivery $fixture PublishDevelop @('-ResumePlan',$planId)).stdout | ConvertFrom-Json
            $closed.status | Should -BeExactly 'already-reachable'
            $closed.commit | Should -BeExactly $first
            $closed.remoteHead | Should -BeExactly $later
            $closed.qualificationStatus | Should -BeExactly 'not-revalidated'
            ($closed.PSObject.Properties.Name -contains 'dependenciesInstallable') | Should -BeFalse
            (& git -C $fixture.root rev-parse refs/itl/develop-candidate/state).Trim() | Should -BeExactly $stateBefore
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/beta/head).Trim() | Should -BeExactly $beta
            Test-Path -LiteralPath (Join-Path $fixture.root '.git/itl/publication-attempts/develop.json') | Should -BeFalse
            @(Get-Content -LiteralPath $fixture.modeLog | Where-Object {$_ -ne 'Targeted'}) | Should -Be $before
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { Remove-DeliveryFixture $fixture }
    }
}
