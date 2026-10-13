
    . (Join-Path $PSScriptRoot 'SourceDelivery.TestSupport.ps1')
    function Copy-FrozenSupervisorClosure {
        param([object]$Fixture)
        $fixture=$Fixture
        # Resume requires an actual published supervisor, including its imports.
        $scripts=Join-Path $fixture.root 'scripts'
        New-Item -ItemType Directory -Force -Path $scripts | Out-Null
        $paths=@($DeliverySourcePaths)+@('release-artifact-paths.ps1','git-path-list.ps1','release-qualification.ps1','quality-contracts.ps1','develop-e2e-qualification.ps1','stand-env-identity.ps1','source-proof-json.ps1','invoke-pester-runtime.ps1','develop-e2e-cleanup.ps1' | ForEach-Object {Join-Path $RepoRoot "scripts/$_"})
        foreach($path in @($paths|Sort-Object -Unique)){Copy-Item -LiteralPath $path -Destination $scripts}
        $relative='.agents/skills/1c-workflow/scripts/lib/agent-1c.immutable-download.ps1'
        $target=Join-Path $fixture.root $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target
    }
    function New-FrozenFixture {
        $fixture=New-DeliveryFixture
        Copy-FrozenSupervisorClosure -Fixture $fixture
        & git -C $fixture.root add --all
        & git -C $fixture.root commit --quiet -m 'test: publish production supervisor closure'
        & git -C $fixture.root push --quiet origin HEAD:develop
        if($LASTEXITCODE){throw 'Could not publish the disposable supervisor'}
        $fixture.base=(& git -C $fixture.root rev-parse HEAD).Trim()
        return $fixture
    }
    function Add-FrozenTask {
        param([object]$Fixture, [string]$Name)
        New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.root 'tests/pester') | Out-Null
        Set-Content -LiteralPath (Join-Path $Fixture.root "$Name.ps1") -Value "'$Name'" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $Fixture.root "tests/pester/$Name.Tests.ps1") -Value "Describe '$Name' { It 'exists' { `$true | Should -BeTrue } }" -Encoding UTF8
        & git -C $Fixture.root add --all
        & git -C $Fixture.root commit --quiet -m "test: $Name"
        if ($LASTEXITCODE) { throw 'Could not commit frozen publication task' }
        return (& git -C $Fixture.root rev-parse HEAD).Trim()
    }
    function Invoke-FrozenDelivery {
        param([object]$Fixture, [string]$Action, [string[]]$Extra=@(), [switch]$AllowFailure)
        if($Action -eq 'RegisterChange'){$Extra=@('-BaseRef',$Fixture.base)+$Extra}
        return Invoke-DeliveryTestPowerShell -Arguments (@('-Action',$Action,'-RepositoryRoot',('"'+$Fixture.root+'"'),'-GateScript',('"'+$Fixture.gate+'"'),'-ComponentFinalizerScript',('"'+$Fixture.finalizer+'"')) + $Extra) -AllowFailure:$AllowFailure
    }
    function Read-FrozenAttempt {
        param([object]$Fixture)
        return Get-Content -LiteralPath (Join-Path $Fixture.root '.git/itl/publication-attempts/develop.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    function New-FrozenStand {
        param([string]$Root)
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        Set-Content -LiteralPath (Join-Path $Root '.dev.env') -Value 'IDENTITY=frozen' -Encoding UTF8
        & git -C $Root init --quiet
        & git -C $Root config user.email 'test@example.invalid'
        & git -C $Root config user.name 'ITL Test'
        & git -C $Root add --all
        & git -C $Root commit --quiet -m 'stand identity'
        if ($LASTEXITCODE) { throw 'Could not prepare private stand identity' }
    }
    function Invoke-FrozenSavedPlan {
        param([string]$Record,[bool]$Legacy)
        $fixture=$null
        try {
            $fixture=New-FrozenFixture
            $first=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $plan=(Invoke-FrozenDelivery $fixture Plan).stdout | ConvertFrom-Json
            $plan.candidate.commit | Should -Be $first
            @($plan.queue.id) | Should -Be @('alpha')
            $advanced=''
            if($Legacy){
                . ([scriptblock]::Create((Get-DeliveryFunctionDefinitions @('Get-DeliveryPlanIdentity','Get-DeliveryCanonicalJsonSha256','Get-DeliveryTextSha256'))))
                $plan.PSObject.Properties.Remove('queue')
                $plan.planId=Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanIdentity $plan)
                $plan.path=Join-Path $fixture.root ".git/itl/plans/v1/$($plan.planId).json"
                [IO.File]::WriteAllText($plan.path,($plan|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
                $advanced=Add-FrozenTask $fixture later
                Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            }
            & git -C $fixture.root switch --quiet -c beta $fixture.base
            $beta=Add-FrozenTask $fixture beta
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop @('-ResumePlan',[string]$plan.planId)).stdout | ConvertFrom-Json
            $published.commit | Should -Be $first
            $published.planId | Should -Be $plan.planId
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/beta/head).Trim() | Should -Be $beta
            if($Legacy){
                (& git -C $fixture.root rev-parse refs/itl/develop-queue/alpha/head).Trim() | Should -Be $advanced
            }else{
                @(& git -C $fixture.root for-each-ref refs/itl/develop-queue/alpha).Count | Should -Be 0
            }
        } finally { Remove-DeliveryFixture $fixture }
    }
