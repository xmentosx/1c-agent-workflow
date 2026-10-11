BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
    It 'blocks repeated candidate corruption despite changing observed SHAs and preserves owner recovery' {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Assert-DevelopPublicationCandidateIntegrity','Register-DevelopPublicationStageFailure','Assert-DevelopPublicationStageMayRun','Clear-DevelopPublicationStageFailure','Get-DeliveryTextSha256')) { Invoke-Expression $definition.Extent.Text }
            $RequireRelease=$false; $RetryBlockedStage=$false
            $script:observedHead='unexpected-first'
            $script:writes=0
            function Invoke-WorktreeGit { param($Root,$Arguments) return [pscustomobject]@{stdout=$(if($Arguments[-1] -eq 'HEAD'){$script:observedHead}else{'expected-tree'})} }
            function Get-RepositoryGitPathList { return @() }
            function Get-DevelopPublicationPhaseRank { param($Phase) if($Phase -eq 'component-finalized'){return 3};return 1 }
            function Set-DevelopPublicationPhase { param($Attempt,$Phase) $Attempt.phase=$Phase }
            function Get-DeliveryFailureClass { return 'workflow' }
            function Write-DevelopPublicationAttempt { $script:writes++ }
            $attempt=[pscustomobject]@{candidate='qualified-sha';tree='expected-tree';phase='component-finalized';componentPublication='obsolete';failures=@()}
            { Assert-DevelopPublicationCandidateIntegrity -CandidateRoot $TestDrive -Attempt $attempt } | Should -Throw '*observed commit unexpected-first*'
            $script:observedHead='unexpected-second'
            { Assert-DevelopPublicationCandidateIntegrity -CandidateRoot $TestDrive -Attempt $attempt } | Should -Throw '*observed commit unexpected-second*'
            @($attempt.failures).Count | Should -Be 1
            $attempt.failures[0].count | Should -Be 2
            $attempt.failures[0].message | Should -Match 'unexpected-second'
            $attempt.phase | Should -Be 'develop-qualified'
            $attempt.componentPublication | Should -BeNullOrEmpty
            $script:writes | Should -Be 2
            { Assert-DevelopPublicationStageMayRun -Attempt $attempt -Stage 'component-finalizer' } | Should -Throw '*same failure twice*'
            $RetryBlockedStage=$true
            Assert-DevelopPublicationStageMayRun -Attempt $attempt -Stage 'component-finalizer'
            @($attempt.failures).Count | Should -Be 0
            $script:observedHead='qualified-sha'
            Assert-DevelopPublicationCandidateIntegrity -CandidateRoot $TestDrive -Attempt $attempt
            $attempt.candidate | Should -Be 'qualified-sha'
            $script:writes | Should -Be 3
        }
    }
It "checks the Release stand before Develop and all owned URLs before push, including resume" {
        $body = (Get-DeliveryFunctionDefinitions -Names @('Publish-AccumulatedDevelop')).Extent.Text
        $stand = $body.IndexOf('Assert-DeliveryReleaseStandReady -CandidateRoot $worktree.path')
        $develop = $body.IndexOf('Invoke-SourceGate -Mode "Develop"')
        $finalizer = $body.IndexOf('Invoke-ComponentPublicationFinalizer -CandidateRoot $worktree.path')
        $remote = $body.LastIndexOf('Assert-DeliveryOwnedAssetsPublished -CandidateRoot $worktree.path')
        $push = $body.IndexOf('"push", $script:Remote, "${candidate}:refs/heads/develop"')
        $integrityBeforeFinalizer = $body.IndexOf('Assert-DevelopPublicationCandidateIntegrity -CandidateRoot $worktree.path -Attempt $attempt')
        $integrityBeforePush = $body.LastIndexOf('Assert-DevelopPublicationCandidateIntegrity -CandidateRoot $worktree.path -Attempt $attempt')
        $stand | Should -BeGreaterThan -1
        $push | Should -BeGreaterThan -1
        $finalizer | Should -BeGreaterThan -1
        $remote | Should -BeGreaterThan -1
        $integrityBeforeFinalizer | Should -BeGreaterThan -1
        $integrityBeforeFinalizer | Should -BeLessThan $finalizer
        $integrityBeforePush | Should -BeGreaterThan $finalizer
        $integrityBeforePush | Should -BeLessThan $push
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
                return [pscustomobject]@{ phase='component-finalized'; candidate=$remoteCommit; tree=$remoteTree; queue=@($entry); startedAt='2026-09-24T00:00:00Z'; requireRelease=$true; componentPublication=$null }
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
}
