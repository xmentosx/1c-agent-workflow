BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryHistorical.TestSupport.ps1') }
Describe 'Actual historical source controller transition' {
    It 'preserves the legacy checkpoint and completes old-owner cleanup before admitting the new protocol' {
        $fixture=$null; $prior=$env:ITL_TEST_FAIL_COMPONENT_FINALIZER
        try {
            $fixture=New-HistoricalDeliveryFixture
            Add-FrozenTask $fixture alpha | Out-Null
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER='true'
            (Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure).exitCode | Should -Not -Be 0
            $original=Read-FrozenAttempt $fixture
            $oldPlan=[string]$original.planId
            $checkpointPath=Join-Path $fixture.root '.git/itl/publication-attempts/develop.json'
            $checkpoint=[IO.File]::ReadAllText($checkpointPath)
            $oldPlanPath=Join-Path $fixture.root ".git/itl/plans/v1/$oldPlan.json"
            $oldPlanBytes=[IO.File]::ReadAllText($oldPlanPath)
            Add-FrozenTask $fixture beta | Out-Null
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            Copy-FrozenSupervisorClosure -Fixture $fixture
            $activated=Add-FrozenTask $fixture transition
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','transition') | Out-Null
            $guarded=Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure
            $guarded.exitCode | Should -Not -Be 0
            $guarded.stderr | Should -Match 'DELIVERY_LEGACY_PLAN_INPUT_CHANGED'
            [IO.File]::ReadAllText($checkpointPath) | Should -BeExactly $checkpoint
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 1
            $injected=Join-Path $fixture.root 'build/transition-locking-finalizer.ps1'
            $body=[IO.File]::ReadAllText($fixture.finalizer)
            $at=$body.LastIndexOf('exit 0',[StringComparison]::Ordinal)
            if($at -lt 0){throw 'Fixture finalizer exit changed'}
            $hook=@'
$lock=Join-Path $SourceRepositoryRoot '.git/refs/itl/develop-queue/transition/head.lock'
[IO.File]::WriteAllText($lock,'private transition fault')
'@
            [IO.File]::WriteAllText($injected,($body.Substring(0,$at)+$hook+"`n"+$body.Substring($at)),[Text.UTF8Encoding]::new($true))
            $fixture.finalizer=$injected
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$null
            (Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$oldPlan) -AllowFailure).exitCode | Should -Not -Be 0
            (Read-FrozenAttempt $fixture).phase | Should -Be 'remote-pushed'
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -BeExactly $activated
            & git -C $fixture.root switch --quiet -c gamma $activated
            $gamma=Add-FrozenTask $fixture gamma
            $targetedBefore=@((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Targeted'}).Count
            $blocked=Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','gamma') -AllowFailure
            $blocked.exitCode | Should -Not -Be 0
            $blocked.stderr | Should -Match 'DELIVERY_LEGACY_PUBLICATION_ACTIVE'
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Targeted'}).Count | Should -Be $targetedBefore
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue/gamma).Count | Should -Be 0
            # Remove only this disposable fixture's injected ref-lock fault.
            Remove-Item -LiteralPath (Join-Path $fixture.root '.git/refs/itl/develop-queue/transition/head.lock') -Force
            $recovered=(Invoke-FrozenDelivery $fixture PublishDevelop).stdout | ConvertFrom-Json
            $recovered.recovered | Should -BeTrue
            $recovered.commit | Should -BeExactly $activated
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 2
            $registered=(Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','gamma')).stdout | ConvertFrom-Json
            $registered.head | Should -BeExactly $gamma
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/gamma/head).Trim() | Should -BeExactly $gamma
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue/alpha refs/itl/develop-queue/beta refs/itl/develop-queue/transition).Count | Should -Be 0
            $state=(& git -C $fixture.root rev-parse refs/itl/develop-candidate/state).Trim()
            $closed=Invoke-FrozenDelivery $fixture PublishDevelop @('-ResumePlan',$oldPlan) -AllowFailure
            $closed.exitCode | Should -Not -Be 0
            $closed.stderr | Should -Match 'DELIVERY_LEGACY_CONTROLLER_PROTOCOL'
            (& git -C $fixture.root rev-parse refs/itl/develop-candidate/state).Trim() | Should -BeExactly $state
            [IO.File]::ReadAllText($oldPlanPath) | Should -BeExactly $oldPlanBytes
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/master).Trim() | Should -BeExactly $fixture.base
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$prior; Remove-DeliveryFixture $fixture }
    }
}
