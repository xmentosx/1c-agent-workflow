BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $helperPath = Join-Path $repoRoot '.agents\skills\1c-workflow\scripts\agent-1c.ps1'
}

Describe 'Fresh explicit verification proof' {
    It 'invalidates dependent one-off proof after a checker fix while preserving unrelated proof and expired invocation provenance' {
        $root = Join-Path $TestDrive ('Checker provenance Кириллица ' + [guid]::NewGuid().ToString('N'))
        foreach ($relative in @('.agent-1c','tests','src/cf','evidence')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $root $relative) | Out-Null
        }
        & git -C $root init -b master *> $null
        & git -C $root config user.email 'test@example.com'
        & git -C $root config user.name 'Test User'
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'src/cf/input.bsl'), 'Procedure Input() EndProcedure', [Text.UTF8Encoding]::new($false))
        $obligations = @(
            @{ id='observed'; expectedResult='Observed 42'; inputPaths=@('src/cf/input.bsl'); admissibleProof=@('runtime-observation'); retention='one-off'; retentionReason='Bounded observed check'; cadence='explicit' },
            @{ id='junit'; expectedResult='JUnit scenario passed'; inputPaths=@('src/cf/input.bsl'); admissibleProof=@('vanessa-junit'); retention='one-off'; retentionReason='Bounded temporary scenario'; cadence='explicit' }
        )
        [IO.File]::WriteAllText((Join-Path $root 'tests/verification-suites.branch.json'), (@{schemaVersion=2;suites=@();obligations=$obligations}|ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        & git -C $root add -- .agent-1c/project.json src/cf/input.bsl tests/verification-suites.branch.json
        & git -C $root commit -qm 'checker acceptance inputs'
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:CheckerState = [pscustomobject]@{stateProjectRoot=$root;infoBaseKind='file';devBranchInfoBasePath=(Join-Path $root 'base');lastConfigDesignerFingerprint='loaded-source';configLoadStatus='passed'}
            function Read-DevBranchState { $script:CheckerState }
            function Assert-DevelopmentBranchWorktreeContext { param($State,$Operation) }
            foreach ($obligation in @(Get-VerificationOneOffObligations)) {
                $started=Start-VerificationOneOffProof -ObligationId $obligation.id
                $artifact="evidence/$($obligation.id).txt"
                $content=if($obligation.id -eq 'junit') {'<testsuite tests="1" failures="0" errors="0" skipped="0"><testcase name="scenario"/></testsuite>'}else{'Actual result: 42'}
                [IO.File]::WriteAllText((Join-Path $root $artifact),$content,[Text.UTF8Encoding]::new($false))
                $evidence=[ordered]@{obligationId=$obligation.id;runToken=$started.runToken;expectedResult=$obligation.expectedResult;status='passed';proofType=$obligation.admissibleProof[0];actualResult='Observed complete result';providerId='exact-canary';runnerVersion='1';steps=@(@{action='Execute the declared check';actual='Complete expected result observed'});artifactPaths=@($artifact);invocationProvenance=@{scope='named-one-off';expiresAt='2000-01-01T00:00:00Z';persistentMode='off'}}
                $evidencePath="evidence/$($obligation.id).json"
                Write-Utf8TextAtomic -Path (Join-Path $root $evidencePath) -Value ($evidence|ConvertTo-Json -Depth 8)
                Complete-VerificationOneOffProof -EvidencePath $evidencePath | Out-Null
            }
            $observed=@(Get-VerificationOneOffObligations|Where-Object id -eq observed)[0]
            $junit=@(Get-VerificationOneOffObligations|Where-Object id -eq junit)[0]
            $before=Get-VerificationOneOffProofAssessment -Obligation $junit -State $script:CheckerState
            function Assert-VerificationOneOffJUnitEvidence { param([string]$Path) throw 'Corrected parser rejects the old false-success result' }
            $dependent=Get-VerificationOneOffProofAssessment -Obligation $junit -State $script:CheckerState
            $unrelated=Get-VerificationOneOffProofAssessment -Obligation $observed -State $script:CheckerState
            $repeat=Start-VerificationOneOffProof -ObligationId 'observed'
            $newPending=Start-VerificationOneOffProof -ObligationId 'junit'
            $invalidLegacyPath=Get-VerificationOneOffProofPath -ObligationId 'observed'
            $legacy=Read-Utf8Text -Path $invalidLegacyPath|ConvertFrom-Json
            $legacy.PSObject.Properties.Remove('checkerIdentity')
            $unknown=Get-VerificationOneOffProofAssessment -Obligation $observed -State $script:CheckerState -Proof $legacy
            $draft=Read-Utf8Text -Path (Get-VerificationOneOffProofPath -ObligationId 'junit')|ConvertFrom-Json
            function Assert-VerificationOneOffJUnitEvidence { param([string]$Path) throw 'Another parser correction during an observed run' }
            $evidence=Read-Utf8Text -Path (Join-Path $root 'evidence/junit.json')|ConvertFrom-Json
            $evidence.runToken=$draft.runToken
            Write-Utf8TextAtomic -Path (Join-Path $root 'evidence/junit.json') -Value ($evidence|ConvertTo-Json -Depth 8)
            $midRunError=''
            try {Complete-VerificationOneOffProof -EvidencePath 'evidence/junit.json'|Out-Null}catch{$midRunError=$_.Exception.Message}
            [pscustomobject]@{before=$before;dependent=$dependent;unrelated=$unrelated;repeat=$repeat;newPending=$newPending;unknown=$unknown;midRunError=$midRunError;pending=(Read-Utf8Text -Path (Get-VerificationOneOffProofPath -ObligationId 'junit')|ConvertFrom-Json).status}
        }
        $result.before.passed | Should -BeTrue
        $result.dependent.passed | Should -BeFalse
        $result.dependent.issue | Should -Match 'checker changed'
        $result.unrelated.passed | Should -BeTrue
        $result.repeat.reused | Should -BeTrue
        $result.newPending.status | Should -Be 'pending'
        $result.unknown.passed | Should -BeFalse
        $result.unknown.issue | Should -Match 'identity is unknown'
        $result.midRunError | Should -Match 'VERIFICATION_ONE_OFF_CHECKER_CHANGED'
        $result.pending | Should -Be 'pending'
    }

    It 'makes a complete retained result block-ready only after the one-off proof passes' {
        $root = Join-Path $TestDrive ('One off readiness ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{}', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $state = [pscustomobject]@{
                stateProjectRoot = $root; infoBaseKind = 'file'; devBranchInfoBasePath = (Join-Path $root 'base')
                toolingInfoBaseGeneration = 'target'; vanessaServiceInfoBaseGeneration = 'runner'
                lastConfigDesignerFingerprint = 'config'; lastExtensionDesignerFingerprint = 'extension'
                configLoadStatus = 'passed'; extensionLoadStatus = 'passed'
            }
            $updates = @{}
            Add-VanessaVerificationEvidenceUpdates -Updates $updates -State $state -Status passed -Reason complete -Commit first -Fingerprint 'source-bytes' -ReportPath report -LogPath log -RecordFullVerificationEvidence
            foreach ($name in $updates.Keys) { $state | Add-Member -NotePropertyName $name -NotePropertyValue $updates[$name] -Force }
            $script:OneOffPassed = $false
            function Get-VerificationOneOffObligations { @([pscustomobject]@{ id = 'orders-observed' }) }
            function Get-VerificationOneOffProofAssessment { param($Obligation, $State) [pscustomobject]@{ passed = $script:OneOffPassed; issue = 'VERIFICATION_ONE_OFF_PROOF_PENDING: orders-observed' } }
            $pending = Get-VerificationState -State $state -CurrentCommit second -CurrentFingerprint 'source-bytes'
            $script:OneOffPassed = $true
            $ready = Get-VerificationState -State $state -CurrentCommit second -CurrentFingerprint 'source-bytes'
            function Get-VerificationPolicy { 'block' }
            $blocked = ''
            try { Confirm-UnverifiedProceed -State $state -Operation 'export-dev-branch-result' -VerificationState $pending | Out-Null } catch { $blocked = $_.Exception.Message }
            $readyDecision = Confirm-UnverifiedProceed -State $state -Operation 'export-dev-branch-result' -VerificationState $ready
            [pscustomobject]@{ pending = $pending; ready = $ready; blocked = $blocked; readyDecision = $readyDecision }
        }
        $result.pending.isFreshPassed | Should -BeFalse
        $result.pending.effectiveStatus | Should -Be 'partial'
        $result.pending.reason | Should -Match 'VERIFICATION_ONE_OFF_PROOF_PENDING'
        $result.ready.isFreshPassed | Should -BeTrue
        $result.blocked | Should -Match 'begin-one-off-proof and complete-one-off-proof'
        $result.readyDecision | Should -BeFalse
    }

    It 'binds a passed result to the exact loaded infobase state without tying it to a commit id' {
        $root = Join-Path $TestDrive ('Loaded base Кириллица ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{}', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $state = [pscustomobject]@{
                stateProjectRoot = $root
                infoBaseKind = 'file'
                devBranchInfoBasePath = (Join-Path $root 'base')
                toolingInfoBaseGeneration = 'first-target-generation'
                vanessaServiceInfoBaseGeneration = 'first-runner-generation'
                lastConfigDesignerFingerprint = 'config-bytes'
                lastExtensionDesignerFingerprint = 'extension-bytes'
                configLoadStatus = 'passed'
                extensionLoadStatus = 'passed'
            }
            $updates = @{}
            Add-VanessaVerificationEvidenceUpdates -Updates $updates -State $state -Status passed -Reason complete -Commit first -Fingerprint 'source-bytes' -ReportPath report -LogPath log -RecordFullVerificationEvidence
            foreach ($name in $updates.Keys) { $state | Add-Member -NotePropertyName $name -NotePropertyValue $updates[$name] -Force }
            $fresh = Get-VerificationState -State $state -CurrentCommit second -CurrentFingerprint 'source-bytes'
            $state.toolingInfoBaseGeneration = 'recreated-target-generation'
            $recreated = Get-VerificationState -State $state -CurrentCommit second -CurrentFingerprint 'source-bytes'
            $state.toolingInfoBaseGeneration = 'first-target-generation'
            $state.vanessaServiceInfoBaseGeneration = 'recreated-runner-generation'
            $runnerChanged = Get-VerificationState -State $state -CurrentCommit second -CurrentFingerprint 'source-bytes'
            $state.vanessaServiceInfoBaseGeneration = 'first-runner-generation'
            $state.lastConfigDesignerFingerprint = 'other-loaded-bytes'
            $stale = Get-VerificationState -State $state -CurrentCommit second -CurrentFingerprint 'source-bytes'
            $state.lastConfigDesignerFingerprint = 'config-bytes'
            $state.PSObject.Properties.Remove('lastVerifiedLoadedBaseIdentity')
            $legacy = Get-VerificationState -State $state -CurrentCommit second -CurrentFingerprint 'source-bytes'
            [pscustomobject]@{ fresh = $fresh; recreated = $recreated; runnerChanged = $runnerChanged; stale = $stale; legacy = $legacy }
        }
        $result.fresh.isFreshPassed | Should -BeTrue
        $result.recreated.isFreshPassed | Should -BeFalse
        $result.runnerChanged.isFreshPassed | Should -BeFalse
        $result.stale.isFreshPassed | Should -BeFalse
        $result.stale.effectiveStatus | Should -Be stale
        $result.legacy.isFreshPassed | Should -BeFalse
        $result.legacy.effectiveStatus | Should -Be stale
    }

    It 'survives a later ordinary check with persistent execution switches off' {
        $root = Join-Path $TestDrive ('Proof reuse ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{}', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:updates = 0
            function Get-VerificationState { param($State) [pscustomobject]@{ isFreshPassed = $true } }
            function Update-DevBranchState { param($State, $Updates) $script:updates++ }
            $decisions = @([pscustomobject]@{ component = 'vanessa'; run = $false; reason = 'persistent off' })
            Set-ItlPartialVerificationEvidence -State ([pscustomobject]@{ lastVerificationStatus = 'passed' }) -Decisions $decisions -Trigger command
            $script:updates
        }
        $result | Should -Be 0
    }

    It 'records partial evidence when an earlier proof is stale' {
        $root = Join-Path $TestDrive ('Proof stale ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{}', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:updates = @()
            function Get-VerificationState { param($State) [pscustomobject]@{ isFreshPassed = $false } }
            function Update-DevBranchState { param($State, $Updates) $script:updates += $Updates }
            $decisions = @([pscustomobject]@{ component = 'vanessa'; run = $false; reason = 'persistent off' })
            Set-ItlPartialVerificationEvidence -State ([pscustomobject]@{ lastVerificationStatus = 'passed' }) -Decisions $decisions -Trigger command
            $script:updates[0]
        }
        $result.lastVerificationStatus | Should -Be 'partial'
        $result.lastVerifiedFingerprint | Should -Be ''
    }

    It 'keeps unrelated dependency pins out of proof freshness while tracking runner bytes' {
        $root = Join-Path $TestDrive ('Proof dependency Кириллица ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        & git -C $root init -b master *> $null
        & git -C $root config user.email 'test@example.com'
        & git -C $root config user.name 'Test User'
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{}', [Text.UTF8Encoding]::new($false))
        $lockPath = Join-Path $root '.agent-1c/dependency-lock.json'
        $lock = [ordered]@{ dependencies = [ordered]@{
            workflowPackage = @{ commit = 'old-commit' }
            yaxunit = @{ version = '25.12'; sha256 = ('a' * 64) }
            unrelatedTool = @{ version = '1'; sha256 = ('b' * 64) }
        } }
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        & git -C $root add -- .agent-1c/project.json .agent-1c/dependency-lock.json
        & git -C $root commit -qm 'baseline proof inputs'
        $baseline = (& git -C $root rev-parse HEAD).Trim()

        $lock.dependencies.workflowPackage.commit = 'new-commit-same-runner'
        $lock.dependencies.unrelatedTool.version = '2'
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        & git -C $root add -- .agent-1c/dependency-lock.json
        & git -C $root commit -qm 'unrelated pin and package identity'
        $unrelated = (& git -C $root rev-parse HEAD).Trim()
        $first = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            [pscustomobject]@{
                before = Get-VerificationRelevantDependencyLockFingerprint -Treeish $baseline
                after = Get-VerificationRelevantDependencyLockFingerprint -Treeish $unrelated
                changed = @(Get-VerificationSelectionChangedPaths -BaseTree $baseline -CurrentTree $unrelated)
            }
        }
        $first.before | Should -Be $first.after
        @($first.changed).Count | Should -Be 0

        $lock.dependencies.yaxunit.sha256 = ('c' * 64)
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        & git -C $root add -- .agent-1c/dependency-lock.json
        & git -C $root commit -qm 'runner bytes changed'
        $relevant = (& git -C $root rev-parse HEAD).Trim()
        $second = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            [pscustomobject]@{
                fingerprint = Get-VerificationRelevantDependencyLockFingerprint -Treeish $relevant
                changed = @(Get-VerificationSelectionChangedPaths -BaseTree $unrelated -CurrentTree $relevant)
            }
        }
        $second.fingerprint | Should -Not -Be $first.after
        @($second.changed) | Should -Be @('.agent-1c/dependency-lock.json')
    }

    It 'invalidates proof for a declared OpenSpec requirement but not for an unrelated change' {
        $root = Join-Path $TestDrive ('Requirement Кириллица ' + [guid]::NewGuid().ToString('N'))
        foreach ($relative in @('.agent-1c', 'tests/features', 'tests', 'openspec/changes/active/specs/orders', 'openspec/changes/other/specs/other')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $root $relative) | Out-Null
        }
        & git -C $root init -b master *> $null
        & git -C $root config user.email 'test@example.com'
        & git -C $root config user.name 'Test User'
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'tests/features/Orders.feature'), 'Функционал: Orders', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'tests/verification-suites.branch.json'), '{"schemaVersion":2,"suites":[{"id":"orders","purpose":"acceptance","featurePaths":["tests/features/Orders.feature"],"ownerPaths":["src/cf/Orders/**"]}],"obligations":[{"id":"orders-result","expectedResult":"Order total correct","inputPaths":["src/cf/Orders/**","openspec/changes/active/specs/orders/spec.md"],"admissibleProof":["vanessa-junit"],"retention":"retained","cadence":"affected","suiteId":"orders"}]}', [Text.UTF8Encoding]::new($false))
        $active = Join-Path $root 'openspec/changes/active/specs/orders/spec.md'
        $other = Join-Path $root 'openspec/changes/other/specs/other/spec.md'
        [IO.File]::WriteAllText($active, 'Requirement A', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($other, 'Unrelated B', [Text.UTF8Encoding]::new($false))
        & git -C $root add -- .agent-1c/project.json tests/features/Orders.feature tests/verification-suites.branch.json openspec/changes/active/specs/orders/spec.md openspec/changes/other/specs/other/spec.md
        & git -C $root commit -qm 'baseline requirements'
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-VerificationAcceptedMasterInput { param($ChangedPaths, $CurrentTree) [pscustomobject]@{ importedPaths = @() } }
            function Get-VerificationLegacySourceBaseline { $null }
            $feature = Join-Path $root 'tests/features/Orders.feature'
            $before = Get-VerificationFingerprint
            $initialPlan = New-VerificationSelectionPlan -ApplicationFeatureFiles @($feature)
            Complete-VerificationSelectionProof -Plan $initialPlan
            [IO.File]::WriteAllText($other, 'Unrelated B2', [Text.UTF8Encoding]::new($false))
            $unrelated = Get-VerificationFingerprint
            $unrelatedPlan = New-VerificationSelectionPlan -ApplicationFeatureFiles @($feature)
            [IO.File]::WriteAllText($active, 'Requirement A2', [Text.UTF8Encoding]::new($false))
            $relevant = Get-VerificationFingerprint
            $relevantPlan = New-VerificationSelectionPlan -ApplicationFeatureFiles @($feature)
            [pscustomobject]@{ before = $before; unrelated = $unrelated; relevant = $relevant; scopes = @(Get-VerificationDeclaredInputScopes); unrelatedPlan = $unrelatedPlan; relevantPlan = $relevantPlan }
        }
        $result.before | Should -BeExactly $result.unrelated
        $result.relevant | Should -Not -BeExactly $result.before
        $result.scopes | Should -Contain 'openspec/changes/active/specs/orders/spec.md'
        $result.scopes | Should -Not -Contain 'openspec/changes/other/specs/other/spec.md'
        $result.unrelatedPlan.mode | Should -Be 'reuse'
        $result.relevantPlan.selectedSuiteIds | Should -Contain 'orders'
    }
}
