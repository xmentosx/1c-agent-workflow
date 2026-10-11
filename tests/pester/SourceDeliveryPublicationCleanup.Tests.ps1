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
}
