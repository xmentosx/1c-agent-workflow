BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1') }
Describe 'Explicit develop plan replacement' {
    It 'keeps an unchanged circuit and freezes a changed replacement across later registrations' {
        $fixture=$null; $prior=$env:ITL_TEST_FAIL_COMPONENT_FINALIZER
        try {
            $fixture=New-FrozenFixture
            $masterBefore=@(& git --git-dir=$($fixture.remote) for-each-ref '--format=%(refname) %(objectname)' refs/heads/master)
            $alpha=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER='true'
            (Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure).exitCode | Should -Not -Be 0
            $original=Read-FrozenAttempt $fixture
            $oldPlan=[string]$original.planId
            $checkpointPath=Join-Path $fixture.root '.git/itl/publication-attempts/develop.json'
            $checkpoint=[IO.File]::ReadAllText($checkpointPath)
            $oldPlanPath=Join-Path $fixture.root ".git/itl/plans/v1/$oldPlan.json"
            $oldPlanBytes=[IO.File]::ReadAllText($oldPlanPath)
            $unchanged=Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$oldPlan) -AllowFailure
            $unchanged.exitCode | Should -Not -Be 0
            $unchanged.stderr | Should -Match 'DELIVERY_REPLAN_INPUTS_UNCHANGED'
            [IO.File]::ReadAllText($checkpointPath) | Should -BeExactly $checkpoint
            Add-Content -LiteralPath $fixture.gate -Value '# changed checker input' -Encoding UTF8
            $fixed=Add-FrozenTask $fixture repair
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $mismatch=Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure
            $mismatch.exitCode | Should -Not -Be 0
            $diagnostic=$mismatch.stderr.Replace("`r",'').Replace("`n",'')
            $diagnostic | Should -Match 'DELIVERY_RESUME_PLAN_MISMATCH'
            $diagnostic | Should -Match 'inputFingerprint expected'
            $diagnostic | Should -Match ([regex]::Escape([string](($oldPlanBytes|ConvertFrom-Json).stages[0].inputFingerprint)))
            [IO.File]::ReadAllText($checkpointPath) | Should -BeExactly $checkpoint
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 1
            & git -C $fixture.root switch --quiet -c beta $fixture.base
            $beta=Add-FrozenTask $fixture beta
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            (Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$oldPlan) -AllowFailure).exitCode | Should -Not -Be 0
            $replacement=Read-FrozenAttempt $fixture
            $replacement.replacesPlanId | Should -BeExactly $oldPlan
            $replacement.planId | Should -Not -Be $oldPlan
            @($replacement.queue.id) | Should -Be @('alpha','beta')
            $newPlan=[string]$replacement.planId
            $candidate=[string]$replacement.candidate
            $replacementCheckpoint=[IO.File]::ReadAllText($checkpointPath)
            $nested=Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$newPlan) -AllowFailure
            $nested.exitCode | Should -Not -Be 0
            $nested.stderr | Should -Match 'DELIVERY_REPLAN_INPUTS_UNCHANGED'
            [IO.File]::ReadAllText($checkpointPath) | Should -BeExactly $replacementCheckpoint
            & git -C $fixture.root switch --quiet -c gamma $fixture.base
            $gamma=Add-FrozenTask $fixture gamma
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','gamma') | Out-Null
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$null
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$oldPlan)).stdout | ConvertFrom-Json
            $published.planId | Should -BeExactly $newPlan
            $published.commit | Should -BeExactly $candidate
            foreach($head in @($fixed,$beta)){ & git -C $fixture.root merge-base --is-ancestor $head $candidate; $LASTEXITCODE | Should -Be 0 }
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 2
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/gamma/head).Trim() | Should -BeExactly $gamma
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue/alpha refs/itl/develop-queue/beta).Count | Should -Be 0
            [IO.File]::ReadAllText($oldPlanPath) | Should -BeExactly $oldPlanBytes
            @(Get-ChildItem -LiteralPath (Join-Path $fixture.root ".git/itl/publication-attempts/replaced/$oldPlan") -Filter '*.json').Count | Should -Be 1
            @(& git --git-dir=$($fixture.remote) for-each-ref '--format=%(refname) %(objectname)' refs/heads/master) | Should -Be $masterBefore
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$prior; Remove-DeliveryFixture $fixture }
    }
}
