BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
It "checks the Release stand before Develop and all owned URLs before push, including resume" {
        $body = (Get-DeliveryFunctionDefinitions -Names @('Publish-AccumulatedDevelop')).Extent.Text
        $stand = $body.IndexOf('Assert-DeliveryReleaseStandReady -CandidateRoot $worktree.path')
        $develop = $body.IndexOf('Invoke-SourceGate -Mode "Develop"')
        $finalizer = $body.IndexOf('Invoke-ComponentPublicationFinalizer -CandidateRoot $worktree.path')
        $remote = $body.LastIndexOf('Assert-DeliveryOwnedAssetsPublished -CandidateRoot $worktree.path')
        $push = $body.IndexOf('"push", $script:Remote, "HEAD:refs/heads/develop"')
        $stand | Should -BeGreaterThan -1
        $stand | Should -BeLessThan $develop
        $finalizer | Should -BeLessThan $remote
        $remote | Should -BeLessThan $push
        $body | Should -Match 'Get-DevelopPublicationPhaseRank.*-ge 3'
    }
It "keeps the queue after remote push when interrupted recovery finds a missing owned asset" {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Complete-InterruptedDevelopPublication')) { Invoke-Expression $definition.Extent.Text }
            $remoteCommit = 'a' * 40
            $remoteTree = 'b' * 40
            $script:Root = $TestDrive
            $script:ComponentFinalizerScript = ''
            $script:queueCleared = $false
            $script:checkedCommit = ''
            function Read-DevelopPublicationAttempt {
                return [pscustomobject]@{ phase='component-finalized'; candidate=$remoteCommit; tree=$remoteTree; startedAt='2026-09-24T00:00:00Z'; requireRelease=$true; componentPublication=$null }
            }
            function Get-DevelopPublicationPhaseRank { return 3 }
            function Invoke-DeliveryGit { return [pscustomobject]@{ exitCode=0 } }
            function Get-GitValue { return $remoteTree }
            function Get-DevelopCommitInstallability { return [pscustomobject]@{ installable=$true; aiRulesStatus='passed' } }
            function Assert-DeliveryOwnedAssetsPublished {
                param([string]$CandidateRoot, [string]$CandidateCommit)
                $script:checkedCommit = $CandidateCommit
                throw "Required owned asset 'dependencies.vanessaMcp.vaExtension' is not published."
            }
            function Clear-PublishedQueueEntries { $script:queueCleared = $true }
            $entry = [pscustomobject]@{ head=$remoteCommit }

            { Complete-InterruptedDevelopPublication -RemoteBefore $remoteCommit -Entries @($entry) } | Should -Throw '*vanessaMcp.vaExtension*'
            $script:checkedCommit | Should -Be $remoteCommit
            $script:queueCleared | Should -BeFalse
        }
    }
It "rejects a historical supervisor that cannot publish the paired CFE" {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Assert-DeliveryBootstrapPairedAssetSupport')) { Invoke-Expression $definition.Extent.Text }
            $candidateRoot = $TestDrive
            $templateRoot = Join-Path $candidateRoot 'templates'
            New-Item -ItemType Directory -Force -Path $templateRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $templateRoot 'dependency-lock.json'), '{"dependencies":{"vanessaMcp":{"vaExtension":{"url":"https://example.invalid/paired.cfe"}}}}', [Text.UTF8Encoding]::new($false))
            $script:supervisorComponent = '# historical ZIP-only finalizer'
            function Invoke-RepositoryGit { return [pscustomobject]@{ exitCode=0; stdout=$script:supervisorComponent } }
            { Assert-DeliveryBootstrapPairedAssetSupport -SupervisorCommit ('a' * 40) } |
                Should -Throw '*DELIVERY_SUPERVISOR_ASSET_UNSUPPORTED*'
            $script:supervisorComponent = 'function Copy-DeliveryVanessaPairedExtensionFromArchive {}'
            { Assert-DeliveryBootstrapPairedAssetSupport -SupervisorCommit ('b' * 40) } |
                Should -Not -Throw
        }
    }
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
It "parses the orchestrator and exposes the bounded delivery actions" {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($DeliveryScript, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $action = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Action" } | Select-Object -First 1
        @($action.Attributes | Where-Object TypeName -match ValidateSet | Select-Object -ExpandProperty PositionalArguments | ForEach-Object SafeGetValue) | Should -Be @("RegisterChange", "Status", "Plan", "Cleanup", "DiagnoseFull", "PublishDevelop", "PromoteRelease", "ReleaseMaster")
        $text = $DeliverySourceText
        $text | Should -Not -Match 'Restore-DeliveryContinuationQualification'
        $text | Should -Match 'publication-attempts\\develop\.json'
        $text | Should -Match 'develop-qualified'
        $text | Should -Match 'component-finalized'
        $text | Should -Match 'same failure twice'
        $text | Should -Match 'Restore-PriorDevelopPublicationQualification'
        $text | Should -Match 'Invoke-SourceGate -Mode "Develop" -WorkingRoot \$worktree\.path -TargetBaseRef \$remoteDevelop'
        $text | Should -Match 'Promote-AccumulatedDevelopToMaster'
        $text | Should -Match 'source-delivery-supervisor\.ps1'
        $text | Should -Match 'refs/remotes/\$Remote/master'
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

It "runs the published develop supervisor for Plan and PublishDevelop, and master for release" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            $supervisorDirectory = Join-Path $fixture.root 'scripts'; New-Item -ItemType Directory -Force -Path $supervisorDirectory | Out-Null
            $developSupervisor = @'
[CmdletBinding()]
param([string]$Action,[string]$RepositoryRoot,[string]$SupervisorCommit,[string]$SupervisorChannel,[switch]$BootstrapSupervisor)
[pscustomobject]@{ status='develop-supervisor'; action=$Action; candidateRoot=$RepositoryRoot; supervisorCommit=$SupervisorCommit; channel=$SupervisorChannel; bootstrap=[bool]$BootstrapSupervisor } | ConvertTo-Json
'@
            [IO.File]::WriteAllText((Join-Path $supervisorDirectory 'source-delivery-supervisor.ps1'), $developSupervisor, [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add scripts/source-delivery-supervisor.ps1; & git -C $fixture.root commit --quiet -m 'test: published develop supervisor'
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

            foreach ($action in @('Plan','PublishDevelop')) {
                $payload = (Invoke-DeliveryTestPowerShell -Arguments @('-Action',$action,'-RepositoryRoot',('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json
                $payload.status | Should -Be 'develop-supervisor'
                $payload.supervisorCommit | Should -Be $developCommit
                $payload.channel | Should -Be 'develop'
                $payload.bootstrap | Should -BeFalse
            }
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
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }

It "registers base and head atomically for a path with Cyrillic and spaces" {
        $fixture = $null; $parallelRoot = ""; try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "скрипт с пробелами.ps1") -Encoding UTF8 -Value "'ok'"
            Set-Content -LiteralPath (Join-Path $tests "Behavior.Tests.ps1") -Encoding UTF8 -Value "Describe 'behavior' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: fixture" *> $null
            $head = (& git -C $fixture.root rev-parse HEAD).Trim()
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", '"codex/parallel branch"', "-CoverageContract", "contract-one,contract-two")
            $result.exitCode | Should -Be 0
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/codex/parallel-branch/base).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/codex/parallel-branch/head).Trim() | Should -Be $head
            $parallelRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl parallel worktree " + [guid]::NewGuid().ToString("N"))
            & git -C $fixture.root worktree add --quiet -b topic-two $parallelRoot $fixture.base *> $null
            New-Item -ItemType Directory -Force -Path (Join-Path $parallelRoot "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $parallelRoot "скрипт с пробелами.ps1") -Encoding UTF8 -Value "'conflicting second'"
            Set-Content -LiteralPath (Join-Path $parallelRoot "tests\pester\Second.Tests.ps1") -Encoding UTF8 -Value "Describe 'second' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $parallelRoot add --all; & git -C $parallelRoot commit -m "feat: parallel fixture" *> $null
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $parallelRoot + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "parallel-two") | Out-Null
            $status = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))
            $statusPayload = $status.stdout | ConvertFrom-Json; @($statusPayload.queue.id | Sort-Object) | Should -Be @("codex/parallel-branch", "parallel-two"); [int]$statusPayload.runHistory.count | Should -BeGreaterOrEqual 2; [int]($statusPayload.runHistory.byMode | Where-Object mode -eq Targeted | Select-Object -ExpandProperty count) | Should -BeGreaterOrEqual 2
            (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure).exitCode | Should -Not -Be 0
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -HaveCount 4
        } finally {
            if ($fixture -and $parallelRoot) { & git -C $fixture.root worktree remove --force $parallelRoot *> $null }
            Remove-DeliveryFixture -Fixture $fixture
        }
    }

It "targets only commits after the existing head of the same queue" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "first.ps1") -Encoding UTF8 -Value "'first'"
            Set-Content -LiteralPath (Join-Path $tests "First.Tests.ps1") -Encoding UTF8 -Value "Describe 'first' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: first queued change" *> $null
            $firstHead = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "same-queue") | Out-Null

            $baseTree = (& git -C $fixture.root rev-parse "$($fixture.base)^{tree}").Trim()
            $remoteHead = (& git -C $fixture.root commit-tree $baseTree -p $fixture.base -m "unrelated remote develop movement").Trim()
            & git -C $fixture.root push --quiet origin "$remoteHead`:refs/heads/develop" *> $null
            & git -C $fixture.root fetch --quiet origin develop *> $null
            (& git -C $fixture.root rev-parse origin/develop).Trim() | Should -Be $remoteHead

            Set-Content -LiteralPath (Join-Path $fixture.root "second.ps1") -Encoding UTF8 -Value "'second'"
            Set-Content -LiteralPath (Join-Path $tests "Second.Tests.ps1") -Encoding UTF8 -Value "Describe 'second' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: second queued change" *> $null
            $secondHead = (& git -C $fixture.root rev-parse HEAD).Trim()
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "same-queue")
            $payload = $result.stdout | ConvertFrom-Json

            @((Get-Content -LiteralPath $fixture.targetBaseLog -Encoding UTF8)) | Should -Be @($fixture.base, $firstHead)
            @($payload.paths | Sort-Object) | Should -Be @("second.ps1", "tests/pester/Second.Tests.ps1")
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/same-queue/base).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/same-queue/head).Trim() | Should -Be $secondHead
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }

It "refuses executable changes without tests or an explicit reused contract" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'changed'"
            & git -C $fixture.root add behavior.ps1
            & git -C $fixture.root commit -m "feat: uncovered" *> $null
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure
            $result.exitCode | Should -Not -Be 0
            $result.stderr | Should -Match "must declare an existing -CoverageContract"
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }

It "blocks a duplicate while an orphan gate is alive and journals stale recovery" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture; New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null; Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\DeliveryRecovery.Tests.ps1") -Encoding UTF8 -Value "Describe 'delivery recovery' { It 'works' { `$true | Should -BeTrue } }"; & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: recovery fixture" *> $null; Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            $lockRoot = Join-Path $fixture.root ".git\itl\delivery-operation"; New-Item -ItemType Directory -Force -Path $lockRoot | Out-Null; $acquiring = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure; $acquiring.exitCode | Should -Not -Be 0; $acquiring.stderr | Should -Match "acquiring the shared lock"; $pesterProcess = Get-Process -Id $PID
            $operation = [ordered]@{ schemaVersion=1; id=[guid]::NewGuid().ToString("N"); action="PublishDevelop"; startedAt=[DateTime]::UtcNow.AddMinutes(-1).ToString("o"); ownerPid=999999; ownerProcessStartedAt=[DateTime]::UtcNow.AddDays(-1).ToString("o"); mode="Develop"; workingRoot=""; gatePid=$PID; gateProcessStartedAt=$pesterProcess.StartTime.ToUniversalTime().ToString("o"); gateStatus="running"; runRecordPath="" }; [IO.File]::WriteAllText((Join-Path $lockRoot "operation.json"), (($operation | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $status = (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json; $status.activeOperation.status | Should -Be "running"; $status.activeOperation.gateAlive | Should -BeTrue; $duplicate = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure; $duplicate.exitCode | Should -Not -Be 0; $duplicate.stderr | Should -Match "already active"
            $summaryRoot = Join-Path $fixture.root "build\test-results\local"; New-Item -ItemType Directory -Force -Path $summaryRoot | Out-Null; $summaryStarted = [DateTime]::UtcNow.AddSeconds(-2); $summaryFinished = [DateTime]::UtcNow.AddSeconds(-1); $summary = [ordered]@{ mode="Targeted"; status="failed"; startedAt=$summaryStarted.ToString("o"); finishedAt=$summaryFinished.ToString("o"); error="fixture interrupted"; tests=[ordered]@{passed=0;failed=1;skipped=0}; stages=@() }; [IO.File]::WriteAllText((Join-Path $summaryRoot "check-summary.json"), (($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $operation.gatePid = 999998; $operation.gateProcessStartedAt = [DateTime]::UtcNow.AddDays(-1).ToString("o"); $operation.workingRoot = $fixture.root; $operation.mode = "Targeted"; [IO.File]::WriteAllText((Join-Path $lockRoot "operation.json"), (($operation | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')); ($published.stdout | ConvertFrom-Json).status | Should -Be "published"; Test-Path -LiteralPath (Join-Path $fixture.root ".git\itl\operations\$($operation.id).json") | Should -BeTrue; $history = ((Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json).runHistory; @($history.lastRuns | Where-Object { [string]$_.error -match "Recovered after the delivery wrapper" }).Count | Should -Be 1
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
}
