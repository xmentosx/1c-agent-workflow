BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
It "blocks a ZIP-only published supervisor before gates and preserves the queued CFE candidate on resume" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            $supervisorDirectory = Join-Path $fixture.root 'scripts'
            New-Item -ItemType Directory -Force -Path $supervisorDirectory | Out-Null
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), "throw 'historical supervisor must not execute'`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-component.ps1'), "# historical ZIP-only component finalizer`n", [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1 scripts/source-delivery-component.ps1
            & git -C $fixture.root commit --quiet -m 'test: published ZIP-only supervisor'
            $published = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root push --quiet origin HEAD:develop

            $templateRoot = Join-Path $fixture.root 'templates'
            New-Item -ItemType Directory -Force -Path $templateRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $templateRoot 'dependency-lock.json'),
                '{"dependencies":{"vanessaMcp":{"vaExtension":{"url":"https://github.com/owner/repo/releases/download/tag/paired.cfe"}}}}',
                [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add templates/dependency-lock.json
            & git -C $fixture.root commit --quiet -m 'test: candidate requires paired CFE'
            $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root update-ref refs/itl/develop-queue/develop/base $published
            & git -C $fixture.root update-ref refs/itl/develop-queue/develop/head $candidate

            $planId = 'c' * 64
            $planRoot = Join-Path $fixture.root '.git\itl\plans\v1'
            New-Item -ItemType Directory -Force -Path $planRoot | Out-Null
            $plan = [ordered]@{ schemaVersion=1; kind='itl-delivery-plan'; planId=$planId; supervisor=[ordered]@{ commit=$published; channel='develop' } }
            [IO.File]::WriteAllText((Join-Path $planRoot "$planId.json"), ($plan | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

            foreach ($arguments in @(
                @('-Action','PublishDevelop','-RepositoryRoot',('"' + $fixture.root + '"')),
                @('-Action','PublishDevelop','-RepositoryRoot',('"' + $fixture.root + '"'),'-ResumePlan',$planId)
            )) {
                $result = Invoke-DeliveryTestPowerShell -Arguments $arguments -AllowFailure
                $result.exitCode | Should -Not -Be 0
                $result.stderr | Should -Match 'DELIVERY_SUPERVISOR_ASSET_UNSUPPORTED'
                (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $published
                (& git -C $fixture.root rev-parse refs/itl/develop-queue/develop/base).Trim() | Should -Be $published
                (& git -C $fixture.root rev-parse refs/itl/develop-queue/develop/head).Trim() | Should -Be $candidate
                Test-Path -LiteralPath $fixture.modeLog | Should -BeFalse
            }
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
It "resolves the repository root after parameter binding in Windows PowerShell 5.1" {
        $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status")
        $result.exitCode | Should -Be 0
        $status = $result.stdout | ConvertFrom-Json
        $status.status | Should -Be "ok"
        @($status.PSObject.Properties.Name) | Should -Contain "queue"
        $status.statusReader.role | Should -Be 'read-only-inspector'
        $status.statusReader.commit | Should -Be ((& git -C $RepoRoot rev-parse HEAD).Trim())
        $status.authoritySupervisor.role | Should -Be 'lock-queue-push-owner'
        $status.supervisor.commit | Should -Be $status.authoritySupervisor.commit
        $status.developAuthoritySupervisor.commit | Should -Be ((& git -C $RepoRoot rev-parse refs/remotes/origin/develop).Trim())
        $status.masterAuthoritySupervisor.commit | Should -Be ((& git -C $RepoRoot rev-parse refs/remotes/origin/master).Trim())
        $status.cleanupPolicy.manualDefault | Should -Be 'develop'
        $status.cleanupPolicy.publishDevelop | Should -Be 'develop'
        $status.cleanupPolicy.releaseMaster | Should -Be 'master'
        @($status.cleanupPolicy.promoteRelease) | Should -Be @('develop', 'master')
    }
It "runs published develop for registration, Plan, publication and default Cleanup, and master only when selected (<Layout>)" -TestCases @(@{Layout='opaque'},@{Layout='older-plan-module'}) {
        param($Layout)
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            $supervisorDirectory = Join-Path $fixture.root 'scripts'; New-Item -ItemType Directory -Force -Path $supervisorDirectory | Out-Null
            $developSupervisor = @'
[CmdletBinding()]
param([string]$Action,[string]$RepositoryRoot,[string]$SupervisorCommit,[string]$SupervisorChannel,[string]$CleanupChannel,[switch]$BootstrapSupervisor)
[pscustomobject]@{ status='develop-supervisor'; action=$Action; candidateRoot=$RepositoryRoot; supervisorCommit=$SupervisorCommit; channel=$SupervisorChannel; bootstrap=[bool]$BootstrapSupervisor } | ConvertTo-Json
'@
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), $developSupervisor, [Text.UTF8Encoding]::new($false))
            if($Layout -eq 'older-plan-module') {
                # A historical module without the accepted-candidate readers
                # does not promise the current read-only preview protocol.
                [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-plan.ps1'), 'function New-AccumulatedDeliveryPlan { throw "old controller owns this protocol" }',[Text.UTF8Encoding]::new($false))
            }
            & git -C $fixture.root add scripts; & git -C $fixture.root commit --quiet -m 'test: published develop supervisor'
            $developCommit = (& git -C $fixture.root rev-parse HEAD).Trim(); & git -C $fixture.root push --quiet origin HEAD:develop
            & git -C $fixture.root switch --quiet -c master $fixture.base
            New-Item -ItemType Directory -Force -Path $supervisorDirectory | Out-Null
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), "param([string]`$Action,[string]`$RepositoryRoot,[string]`$SupervisorCommit,[switch]`$BootstrapSupervisor); [pscustomobject]@{ status='master-supervisor'; action=`$Action; supervisorCommit=`$SupervisorCommit } | ConvertTo-Json", [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1; & git -C $fixture.root commit --quiet -m 'test: published master supervisor'
            $masterCommit = (& git -C $fixture.root rev-parse HEAD).Trim(); & git -C $fixture.root push --quiet origin HEAD:master
            & git -C $fixture.root switch --quiet develop
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), "throw 'candidate supervisor must not execute'", [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1; & git -C $fixture.root commit --quiet -m 'test: candidate supervisor differs'
            & git -C $fixture.root fetch --quiet origin master:refs/remotes/origin/master

            foreach ($action in @('RegisterChange','Plan','PublishDevelop','Cleanup')) {
                $payload = (Invoke-DeliveryTestPowerShell -Arguments @('-Action',$action,'-RepositoryRoot',('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json
                $payload.status | Should -Be 'develop-supervisor'
                $payload.supervisorCommit | Should -Be $developCommit
                $payload.channel | Should -Be 'develop'
                $payload.bootstrap | Should -BeFalse
            }
            $explicitCleanup = (Invoke-DeliveryTestPowerShell -Arguments @('-Action','Cleanup','-CleanupChannel','Develop','-RepositoryRoot',('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json
            $explicitCleanup.supervisorCommit | Should -Be $developCommit
            $explicitCleanup.channel | Should -Be 'develop'
            foreach ($action in @('PromoteRelease','ReleaseMaster')) {
                $payload = (Invoke-DeliveryTestPowerShell -Arguments @('-Action',$action,'-RepositoryRoot',('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json
                $payload.status | Should -Be 'master-supervisor'
                $payload.supervisorCommit | Should -Be $masterCommit
            }
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $developCommit
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/master).Trim() | Should -Be $masterCommit
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
It "fails closed when published develop has no supervisor outside a custom gate fixture" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            $result = Invoke-DeliveryTestPowerShell -Arguments @('-Action','Plan','-RepositoryRoot',('"' + $fixture.root + '"')) -AllowFailure
            $result.exitCode | Should -Not -Be 0
            $result.stderr | Should -Match 'DELIVERY_DEVELOP_SUPERVISOR_UNAVAILABLE'
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $fixture.base
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
It "resumes the pinned develop supervisor after develop advances, including a channel-less transition plan" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            $supervisorDirectory = Join-Path $fixture.root 'scripts'
            New-Item -ItemType Directory -Force -Path $supervisorDirectory | Out-Null
            $recordedText = @'
[CmdletBinding()]
param([string]$Action,[string]$RepositoryRoot,[string]$SupervisorCommit,[switch]$BootstrapSupervisor,[string]$ResumePlan)
[pscustomobject]@{ status='recorded-develop'; supervisorCommit=$SupervisorCommit; resumePlan=$ResumePlan } | ConvertTo-Json
'@
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), $recordedText, [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1
            & git -C $fixture.root commit --quiet -m 'test: recorded develop supervisor'
            $recordedCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root push --quiet origin HEAD:develop

            $latestText = $recordedText.Replace('recorded-develop','latest-develop')
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), $latestText, [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1
            & git -C $fixture.root commit --quiet -m 'test: latest develop supervisor'
            $latestCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root push --quiet origin HEAD:develop

            $planRoot = Join-Path $fixture.root '.git\itl\plans\v1'
            New-Item -ItemType Directory -Force -Path $planRoot | Out-Null
            foreach ($case in @(
                [pscustomobject]@{ id=('d' * 64); channel='develop' },
                [pscustomobject]@{ id=('e' * 64); channel='' }
            )) {
                $supervisor = [ordered]@{ commit=$recordedCommit }
                if ($case.channel) { $supervisor.channel = $case.channel }
                $plan = [ordered]@{ schemaVersion=1; kind='itl-delivery-plan'; planId=$case.id; supervisor=$supervisor }
                [IO.File]::WriteAllText((Join-Path $planRoot "$($case.id).json"), (($plan | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
                $resumed = (Invoke-DeliveryTestPowerShell -Arguments @('-Action','PublishDevelop','-RepositoryRoot',('"' + $fixture.root + '"'),'-ResumePlan',$case.id)).stdout | ConvertFrom-Json
                $resumed.status | Should -Be 'recorded-develop'
                $resumed.supervisorCommit | Should -Be $recordedCommit
            }
            $fresh = (Invoke-DeliveryTestPowerShell -Arguments @('-Action','Plan','-RepositoryRoot',('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json
            $fresh.status | Should -Be 'latest-develop'
            $fresh.supervisorCommit | Should -Be $latestCommit
            $wrongAction = Invoke-DeliveryTestPowerShell -Arguments @('-Action','PromoteRelease','-RepositoryRoot',('"' + $fixture.root + '"'),'-ResumePlan',('d' * 64)) -AllowFailure
            $wrongAction.exitCode | Should -Not -Be 0
            $wrongAction.stderr | Should -Match 'DELIVERY_RESUME_PLAN_INVALID'
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
It "pins a legacy master ResumePlan after master advances while a fresh Plan uses develop" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            & git -C $fixture.root switch --quiet -c master $fixture.base
            $supervisorDirectory = Join-Path $fixture.root 'scripts'
            New-Item -ItemType Directory -Force -Path $supervisorDirectory | Out-Null
            $recordedSupervisorText = @'
[CmdletBinding()]
param([string]$Action,[string]$RepositoryRoot,[string]$SupervisorCommit,[string]$SupervisorChannel,[switch]$BootstrapSupervisor,[string]$ResumePlan)
[pscustomobject]@{ status='recorded-supervisor'; supervisorCommit=$SupervisorCommit; channel=$SupervisorChannel; resumePlan=$ResumePlan } | ConvertTo-Json
'@
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), $recordedSupervisorText, [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1
            & git -C $fixture.root commit --quiet -m 'test: recorded supervisor'
            $recordedCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root push --quiet origin HEAD:master

            $planId = 'a' * 64
            $commonGitDirectory = Join-Path $fixture.root '.git'
            $planRoot = Join-Path $commonGitDirectory 'itl\plans\v1'
            New-Item -ItemType Directory -Force -Path $planRoot | Out-Null
            $plan = [ordered]@{ schemaVersion=1; kind='itl-delivery-plan'; planId=$planId; supervisor=[ordered]@{commit=$recordedCommit} }
            $planPath = Join-Path $planRoot "$planId.json"
            [IO.File]::WriteAllText($planPath, (($plan | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Test-Path -LiteralPath $planPath -PathType Leaf | Should -BeTrue

            $latestSupervisorText = @'
[CmdletBinding()]
param([string]$Action,[string]$RepositoryRoot,[string]$SupervisorCommit,[switch]$BootstrapSupervisor,[string]$ResumePlan)
[pscustomobject]@{ status='latest-supervisor'; supervisorCommit=$SupervisorCommit; resumePlan=$ResumePlan } | ConvertTo-Json
'@
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), $latestSupervisorText, [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1
            & git -C $fixture.root commit --quiet -m 'test: latest supervisor'
            $latestCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root push --quiet origin HEAD:master
            & git -C $fixture.root switch --quiet develop
            New-Item -ItemType Directory -Force -Path $supervisorDirectory | Out-Null
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), "param([string]`$Action,[string]`$RepositoryRoot,[string]`$SupervisorCommit,[switch]`$BootstrapSupervisor); [pscustomobject]@{ status='develop-supervisor'; supervisorCommit=`$SupervisorCommit } | ConvertTo-Json", [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1
            & git -C $fixture.root commit --quiet -m 'test: published develop supervisor'
            $developCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root push --quiet origin HEAD:develop
            & git -C $fixture.root fetch --quiet origin master:refs/remotes/origin/master

            $resumed = Invoke-DeliveryTestPowerShell -Arguments @('-Action','PublishDevelop','-RepositoryRoot',('"' + $fixture.root + '"'),'-ResumePlan',$planId)
            $resumedPayload = $resumed.stdout | ConvertFrom-Json
            $resumedPayload.status | Should -Be 'recorded-supervisor'
            $resumedPayload.supervisorCommit | Should -Be $recordedCommit
            $resumedPayload.channel | Should -Be 'master'
            $resumedPayload.resumePlan | Should -Be $planId

            $fresh = Invoke-DeliveryTestPowerShell -Arguments @('-Action','Plan','-RepositoryRoot',('"' + $fixture.root + '"'))
            $freshPayload = $fresh.stdout | ConvertFrom-Json
            $freshPayload.status | Should -Be 'develop-supervisor'
            $freshPayload.supervisorCommit | Should -Be $developCommit
            $latestCommit | Should -Not -Be $developCommit
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
It "rejects a ResumePlan whose recorded supervisor is not trusted by origin master" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            & git -C $fixture.root switch --quiet -c master $fixture.base
            $supervisorDirectory = Join-Path $fixture.root 'scripts'
            New-Item -ItemType Directory -Force -Path $supervisorDirectory | Out-Null
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), "param([string]`$Action)", [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1
            & git -C $fixture.root commit --quiet -m 'test: trusted master supervisor'
            & git -C $fixture.root push --quiet origin HEAD:master
            & git -C $fixture.root switch --quiet develop
            & git -C $fixture.root fetch --quiet origin master:refs/remotes/origin/master
            & git -C $fixture.root commit --allow-empty --quiet -m 'test: untrusted develop supervisor commit'
            $untrustedCommit = (& git -C $fixture.root rev-parse HEAD).Trim()

            $malformed = Invoke-DeliveryTestPowerShell -Arguments @('-Action','PublishDevelop','-RepositoryRoot',('"' + $fixture.root + '"'),'-ResumePlan','not-a-plan') -AllowFailure
            $malformed.exitCode | Should -Not -Be 0
            $malformed.stderr | Should -Match 'DELIVERY_RESUME_PLAN_INVALID'
            $missingId = 'c' * 64
            $missing = Invoke-DeliveryTestPowerShell -Arguments @('-Action','PublishDevelop','-RepositoryRoot',('"' + $fixture.root + '"'),'-ResumePlan',$missingId) -AllowFailure
            $missing.exitCode | Should -Not -Be 0
            $missing.stderr | Should -Match 'DELIVERY_RESUME_PLAN_MISSING'

            $planId = 'b' * 64
            $commonGitDirectory = Join-Path $fixture.root '.git'
            $planRoot = Join-Path $commonGitDirectory 'itl\plans\v1'
            New-Item -ItemType Directory -Force -Path $planRoot | Out-Null
            $plan = [ordered]@{ schemaVersion=1; kind='itl-delivery-plan'; planId=$planId; supervisor=[ordered]@{commit=$untrustedCommit} }
            $planPath = Join-Path $planRoot "$planId.json"
            [IO.File]::WriteAllText($planPath, (($plan | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Test-Path -LiteralPath $planPath -PathType Leaf | Should -BeTrue

            $result = Invoke-DeliveryTestPowerShell -Arguments @('-Action','PublishDevelop','-RepositoryRoot',('"' + $fixture.root + '"'),'-ResumePlan',$planId) -AllowFailure
            $result.exitCode | Should -Not -Be 0
            $result.stderr | Should -Match 'DELIVERY_RESUME_SUPERVISOR_UNTRUSTED'
            $attemptRoot=Join-Path $commonGitDirectory 'itl/publication-attempts'
            New-Item -ItemType Directory -Force -Path $attemptRoot | Out-Null
            $checkpointPath=Join-Path $attemptRoot 'develop.json'
            $checkpoint='{"planId":"'+$planId+'"}'
            [IO.File]::WriteAllText($checkpointPath,$checkpoint,[Text.UTF8Encoding]::new($false))
            $frozen=Invoke-DeliveryTestPowerShell -Arguments @('-Action','PublishDevelop','-RepositoryRoot',('"' + $fixture.root + '"'),'-Replan',$planId,'-ReplanQueueScope','Frozen') -AllowFailure
            $frozen.exitCode | Should -Not -Be 0
            $frozen.stderr | Should -Match 'DELIVERY_RESUME_SUPERVISOR_UNTRUSTED'
            [IO.File]::ReadAllText($checkpointPath) | Should -BeExactly $checkpoint
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
}
