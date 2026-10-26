BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1') }
Describe 'Explicit develop plan replacement' {
    It 'transfers frozen recovery to published develop and preserves late and advanced registrations' {
        $fixture=$null; $prior=$env:ITL_TEST_FAIL_COMPONENT_FINALIZER
        try {
            $fixture=New-FrozenFixture
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
            $advanced=Add-FrozenTask $fixture advanced
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            & git -C $fixture.root switch --quiet -c beta $fixture.base
            $beta=Add-FrozenTask $fixture beta
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            & git -C $fixture.root switch --quiet -c support $fixture.base
            Add-Content -LiteralPath (Join-Path $fixture.root 'scripts/source-delivery-supervisor.ps1') -Value '# published recovery support generation' -Encoding UTF8
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1
            & git -C $fixture.root commit --quiet -m 'test: publish recovery support separately'
            $support=(& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root push --quiet origin HEAD:develop
            $options=@('-Replan',$oldPlan,'-ReplanQueueScope','Frozen')
            # Even a matching checkpoint hash cannot transfer inconsistent scope.
            $tampered=$checkpoint | ConvertFrom-Json
            $tampered.queue[0].head=$advanced
            [IO.File]::WriteAllText($checkpointPath,($tampered|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($false))
            $bad=Invoke-FrozenDelivery $fixture PublishDevelop $options -AllowFailure
            $bad.stderr | Should -Match 'DELIVERY_FROZEN_REPLAN_IDENTITY'
            (Read-FrozenAttempt $fixture).queue[0].head | Should -BeExactly $advanced
            [IO.File]::WriteAllText($checkpointPath,$checkpoint,[Text.UTF8Encoding]::new($false))
            (Invoke-FrozenDelivery $fixture PublishDevelop $options -AllowFailure).exitCode | Should -Not -Be 0
            $replacement=Read-FrozenAttempt $fixture
            $replacement.replacesPlanId | Should -BeExactly $oldPlan
            $replacement.replanQueueScope | Should -BeExactly 'Frozen'
            @($replacement.queue.id) | Should -Be @('alpha')
            $replacement.queue[0].head | Should -BeExactly $alpha
            $newPlan=Get-Content -LiteralPath (Join-Path $fixture.root ".git/itl/plans/v1/$($replacement.planId).json") -Raw | ConvertFrom-Json
            $newPlan.supervisor.commit | Should -BeExactly $support
            $newPlan.replanQueueScope | Should -BeExactly 'Frozen'
            foreach($head in @($alpha,$support)) { & git -C $fixture.root merge-base --is-ancestor $head $replacement.candidate; $LASTEXITCODE | Should -Be 0 }
            foreach($head in @($advanced,$beta)) { & git -C $fixture.root merge-base --is-ancestor $head $replacement.candidate; $LASTEXITCODE | Should -Be 1 }
            $wrongScope=Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$oldPlan) -AllowFailure
            $wrongScope.stderr | Should -Match 'DELIVERY_REPLAN_SCOPE_CHANGED'
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$null
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop $options).stdout | ConvertFrom-Json
            $published.planId | Should -BeExactly $replacement.planId
            $published.commit | Should -BeExactly $replacement.candidate
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/alpha/head).Trim() | Should -BeExactly $advanced
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/beta/head).Trim() | Should -BeExactly $beta
            [IO.File]::ReadAllText($oldPlanPath) | Should -BeExactly $oldPlanBytes
            @(Get-ChildItem -LiteralPath (Join-Path $fixture.root ".git/itl/publication-attempts/replaced/$oldPlan") -Filter '*.json').Count | Should -Be 1
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$prior; Remove-DeliveryFixture $fixture }
    }
    It 'replaces the explicitly named active Frozen plan with Current while preserving the previous replay scope' {
        $fixture=$null; $prior=$env:ITL_TEST_FAIL_COMPONENT_FINALIZER
        try {
            $fixture=New-FrozenFixture
            $masterBefore=@(& git --git-dir=$($fixture.remote) for-each-ref '--format=%(refname) %(objectname)' refs/heads/master)
            $alpha=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER='true'
            (Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure).exitCode | Should -Not -Be 0
            $original=Read-FrozenAttempt $fixture; $originalId=[string]$original.planId
            $originalPath=Join-Path $fixture.root ".git/itl/plans/v1/$originalId.json"
            $originalBytes=[IO.File]::ReadAllText($originalPath)
            $originalSha=(Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
            & git -C $fixture.root switch --quiet -c beta $fixture.base
            $beta=Add-FrozenTask $fixture beta
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            & git -C $fixture.root switch --quiet -c support $fixture.base
            Add-Content -LiteralPath (Join-Path $fixture.root 'scripts/source-delivery-supervisor.ps1') -Value '# separately published recovery support' -Encoding UTF8
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1
            & git -C $fixture.root commit --quiet -m 'test: publish support before Frozen transfer'
            & git -C $fixture.root push --quiet origin HEAD:develop
            $frozenResult=Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$originalId,'-ReplanQueueScope','Frozen') -AllowFailure
            $frozenResult.exitCode | Should -Not -Be 0
            $frozen=Read-FrozenAttempt $fixture; $frozenId=[string]$frozen.planId
            $frozen.replanQueueScope | Should -BeExactly 'Frozen'
            @($frozen.queue.id) | Should -Be @('alpha')
            $frozenPath=Join-Path $fixture.root ".git/itl/plans/v1/$frozenId.json"
            $frozenBytes=[IO.File]::ReadAllText($frozenPath)
            $frozenSha=(Get-FileHash -LiteralPath $frozenPath -Algorithm SHA256).Hash
            $wrong=Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$originalId) -AllowFailure
            $wrong.stderr | Should -Match 'DELIVERY_REPLAN_SCOPE_CHANGED'
            $currentResult=Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$frozenId) -AllowFailure
            $currentResult.exitCode | Should -Not -Be 0
            $currentResult.stderr | Should -Not -Match 'DELIVERY_REPLAN_SCOPE_CHANGED'
            $current=Read-FrozenAttempt $fixture
            $current.replacesPlanId | Should -BeExactly $frozenId
            # Current is the existing default; only Frozen is serialized.
            $current.PSObject.Properties['replanQueueScope'] | Should -BeNullOrEmpty
            @($current.queue.id) | Should -Be @('alpha','beta')
            foreach($head in @($alpha,$beta)){& git -C $fixture.root merge-base --is-ancestor $head $current.candidate; $LASTEXITCODE | Should -Be 0}
            & git -C $fixture.root switch --quiet -c gamma $fixture.base
            $gamma=Add-FrozenTask $fixture gamma
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','gamma') | Out-Null
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$null
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$frozenId)).stdout | ConvertFrom-Json
            $published.planId | Should -BeExactly $current.planId
            $published.commit | Should -BeExactly $current.candidate
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/gamma/head).Trim() | Should -BeExactly $gamma
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue/alpha refs/itl/develop-queue/beta).Count | Should -Be 0
            [IO.File]::ReadAllText($originalPath) | Should -BeExactly $originalBytes
            [IO.File]::ReadAllText($frozenPath) | Should -BeExactly $frozenBytes
            (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash | Should -BeExactly $originalSha
            (Get-FileHash -LiteralPath $frozenPath -Algorithm SHA256).Hash | Should -BeExactly $frozenSha
            foreach($id in @($originalId,$frozenId)){
                @(Get-ChildItem -LiteralPath (Join-Path $fixture.root ".git/itl/publication-attempts/replaced/$id") -Filter '*.json').Count | Should -Be 1
            }
            @(& git --git-dir=$($fixture.remote) for-each-ref '--format=%(refname) %(objectname)' refs/heads/master) | Should -Be $masterBefore
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally {$env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$prior; Remove-DeliveryFixture $fixture}
    }
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
