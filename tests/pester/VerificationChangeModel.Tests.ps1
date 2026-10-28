BeforeAll {
    $helperPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    function New-ChangeFixture {
        param([string]$Root, [switch]$Retained, [switch]$LegacyOneOff, [switch]$NamedProfiles, [switch]$WithoutCatalog)
        foreach($part in @('.agent-1c','src/cf','tests/features','evidence')) { New-Item -ItemType Directory -Force -Path (Join-Path $Root $part) | Out-Null }
        [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),'{}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root '.gitignore'),".agent-1c/verification-selection/`nevidence/`n.dev.env`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root '.dev.env'),"ITL_VERIFICATION_MODEL=change`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root 'requirements.md'),'AC-01: Current result. AC-02: Web acceptance.',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root 'src/cf/current.bsl'),'Procedure Current() EndProcedure',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root 'src/cf/other.bsl'),'Procedure Other() EndProcedure',[Text.UTF8Encoding]::new($false))
        if (-not $WithoutCatalog) {
            [IO.File]::WriteAllText((Join-Path $Root 'tests/verification-suites.branch.json'),'{"schemaVersion":2,"suites":[],"obligations":[]}',[Text.UTF8Encoding]::new($false))
        }
        if($LegacyOneOff) {
            $catalog=@{schemaVersion=2;suites=@();obligations=@(@{id='legacy';expectedResult='Legacy result';inputPaths=@('src/cf/other.bsl');admissibleProof=@('runtime-observation');retention='one-off';retentionReason='Previously observed behavior';cadence='explicit'})}
            [IO.File]::WriteAllText((Join-Path $Root 'tests/verification-suites.branch.json'),($catalog|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        }
        if($Retained) {
            [IO.File]::WriteAllText((Join-Path $Root 'tests/features/Existing.feature'),"Функционал: Existing UI`nСценарий: Existing result`nКогда Данные готовы`n",[Text.UTF8Encoding]::new($false))
            if($NamedProfiles) {
                [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),'{"vanessaAutomation":{"testClientManifestPath":"tests/vanessa-testclients.json"}}',[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText((Join-Path $Root 'tests/vanessa-testclients.json'),'{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"Other"}]}',[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText((Join-Path $Root 'tests/features/Existing.feature'),"Функционал: Existing UI`nСценарий: Existing result`nДано я подключаю профиль TestClient `"Required`"`n",[Text.UTF8Encoding]::new($false))
            }
            $catalog=@{schemaVersion=2;suites=@(@{id='existing';purpose='acceptance';featurePaths=@('tests/features/Existing.feature');ownerPaths=@('src/cf/current.bsl')});obligations=@(@{id='existing-result';expectedResult='Existing result is correct';inputPaths=@('src/cf/current.bsl');admissibleProof=@('vanessa-junit');retention='retained';retentionReason='Existing reusable UI coverage';cadence='affected';suiteId='existing'})}
            [IO.File]::WriteAllText((Join-Path $Root 'tests/verification-suites.branch.json'),($catalog|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        }
        & git -C $Root init -b master *> $null
        & git -C $Root config user.email 'test@example.com'
        & git -C $Root config user.name 'Test User'
        & git -C $Root add -- .
        & git -C $Root commit -qm 'branch baseline'
    }
    function Enter-ChangeFixture {
        param([string]$Root, [scriptblock]$Body)
        & {
            . $helperPath -ProjectRoot $Root -Action help *> $null
            $script:ChangeTestState=[pscustomobject]@{
                stateProjectRoot=$Root;devBranchName='change';safeDevBranchName='change';infoBaseKind='file';devBranchInfoBasePath=(Join-Path $Root 'База 1С')
                toolingInfoBaseGeneration='target';vanessaServiceInfoBaseGeneration='runner';configLoadStatus='passed'
                lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
                lastVerificationStatus='partial';lastVerifiedFingerprint='';enterpriseNormalizationStatus='passed';enterpriseNormalizationProofVersion=1
                yaxunitApplicabilityBaseline=[pscustomobject]@{schemaVersion=1;commit=(Get-CurrentCommit);legacy=$false}
            }
            function Read-DevBranchState { $script:ChangeTestState }
            function Assert-DevelopmentBranchWorktreeContext { param($State,$Operation) }
            function Get-DevBranchResultTransferBaseCommit { param($State) (Get-GitOutput @('rev-list','--max-parents=0','HEAD')).Trim() }
            function Set-CurrentObservation {
                param([string]$Id)
                $draft=Start-VerificationOneOffProof -ObligationId $Id
                Write-Utf8TextAtomic -Path (Join-Path $Root "evidence/$Id.txt") -Value 'Observed expected result'
                $obligation=@(Get-VerificationOneOffObligations | Where-Object id -eq $Id)[0]
                $evidence=@{obligationId=$Id;runToken=$draft.runToken;expectedResult=$obligation.expectedResult;status='passed';proofType='runtime-observation';actualResult='Observed expected result';providerId='test-ui';runnerVersion='1';steps=@(@{action='Read the actual result';actual='Expected value'});artifactPaths=@("evidence/$Id.txt")}
                Write-Utf8TextAtomic -Path (Join-Path $Root "evidence/$Id.json") -Value ($evidence|ConvertTo-Json -Depth 8)
                Complete-VerificationOneOffProof -EvidencePath "evidence/$Id.json" | Out-Null
            }
            function Set-CurrentEventEvidence {
                $fp=Get-VerificationFingerprint
                Write-Utf8TextAtomic -Path (Join-Path $Root 'evidence/event.json') -Value '{"status":"passed","newErrorCount":0,"scanMode":"cursor","cursorScope":"lifecycle-pending"}'
                $receipt=[pscustomobject]@{schemaVersion=1;component='event-log';status='passed';inputFingerprint=$fp;loadedBaseIdentity=(Get-VerificationLoadedBaseIdentity -State $script:ChangeTestState);checkerIdentity=(Get-VerificationOneOffCheckerIdentity -ProofType 'event-log');artifacts=@(New-VerificationArtifactReferences -Paths @((Join-Path $Root 'evidence/event.json')))}
                $script:ChangeTestState|Add-Member -NotePropertyName lastVerificationComponentEvidence -NotePropertyValue ([pscustomobject]@{'event-log'=$receipt}) -Force
            }
            function Write-CurrentPlan {
                param([string]$Id='first',[string]$Path='src/cf/current.bsl',[switch]$ReuseFirst,[switch]$Finish)
                $criteria=@(@{id='AC-01';expectedResult='Current result';decision='check';checkIds=@($Id)},@{id='AC-02';expectedResult='Web acceptance';decision='pending'})
                if($ReuseFirst){$criteria[0]=@{id='AC-01';expectedResult='Current result';decision='unaffected';reason='Only Other changed; Current has no caller or shared state dependency.'}}
                if($Finish){$criteria[1]=@{id='AC-02';expectedResult='Web acceptance';decision='check';checkIds=@($Id)}}
                $plan=@{taskId='feature';requirementPaths=@('requirements.md');checks=@(@{id=$Id;expectedResult="Expected $Id result";inputPaths=@($Path);admissibleProof=@('runtime-observation')});paths=@(@{path=$Path;checkIds=@($Id);reason='Check the changed behavior and its boundary.'});criteria=$criteria;retainedDispositions=@()}
                Write-Utf8TextAtomic -Path (Join-Path $Root "evidence/plan-$Id.json") -Value ($plan|ConvertTo-Json -Depth 10)
                return "evidence/plan-$Id.json"
            }
            & $Body
        }
    }
}

Describe 'Change mode recovery and reuse boundaries' {
    It 'assesses a catalog-free change through real selection and completion: <Fault>' -TestCases @(
        @{Fault='none'; ErrorPattern=''},
        @{Fault='missing-one-off'; ErrorPattern='*VERIFICATION_ONE_OFF_PROOF_PENDING*'},
        @{Fault='failed-one-off'; ErrorPattern='*VERIFICATION_ONE_OFF_PROOF_INVALID*'},
        @{Fault='changed-artifact'; ErrorPattern='*VERIFICATION_ONE_OFF_PROOF_INVALID*'},
        @{Fault='stale-load'; ErrorPattern='*VERIFICATION_LOADED_INPUT_STALE*'},
        @{Fault='unready-load'; ErrorPattern='*VERIFICATION_LOADED_INPUT_UNVERIFIED*'},
        @{Fault='missing-event-log'; ErrorPattern='*VERIFICATION_COMPONENT_PROOF_PENDING*'}
    ) {
        param($Fault, $ErrorPattern)
        $root=Join-Path $TestDrive ('Без каталога ' + $Fault)
        New-ChangeFixture $root -WithoutCatalog
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current fix'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Start-VerificationChange -EvidencePath (Write-CurrentPlan -Finish) | Out-Null
            if ($Fault -ne 'missing-one-off') { Set-CurrentObservation first }
            if ($Fault -ne 'missing-event-log') { Set-CurrentEventEvidence }
            switch ($Fault) {
                'failed-one-off' {
                    $path=Get-VerificationOneOffProofPath first
                    $receipt=Read-Utf8Text -Path $path | ConvertFrom-Json
                    $receipt.status='failed'
                    Write-Utf8TextAtomic -Path $path -Value ($receipt | ConvertTo-Json -Depth 16)
                }
                'changed-artifact' { Write-Utf8TextAtomic -Path (Join-Path $root 'evidence/first.txt') -Value 'Different observation' }
                'stale-load' { $script:ChangeTestState.lastConfigDesignerFingerprint='outdated' }
                'unready-load' { $script:ChangeTestState.configLoadStatus='failed' }
            }
            # Both entry points must use the actual catalog reader and selector.
            $runnerPlan=Get-ItlVanessaVerificationSelectionPlan
            $directPlan=New-VerificationSelectionPlan -ApplicationFeatureFiles @() -RequireObservedReceipts
            $runnerPlan.mode | Should -BeExactly 'reuse'
            $directPlan.mode | Should -BeExactly $runnerPlan.mode
            $runnerPlan.catalogAvailable | Should -BeFalse
            $directPlan.catalogAvailable | Should -BeFalse
            if ($Fault -eq 'none') {
                $result=Complete-VerificationChange
                $result.changeStatus | Should -BeExactly 'accepted'
                $result.taskAccepted | Should -BeTrue
            } else {
                { Complete-VerificationChange } | Should -Throw $ErrorPattern
                (Read-VerificationChange).status | Should -BeExactly 'pending'
            }
            Test-Path -LiteralPath (Join-Path $root 'tests/verification-suites.branch.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root '.agent-1c/verification-selection/proof.json') | Should -BeFalse
        }
    }

    It 'checks selected Vanessa profiles with a valid change plan before reaching the infobase loader' {
        $root=Join-Path $TestDrive 'План и профиль до загрузки'; New-ChangeFixture $root -Retained -NamedProfiles
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current UI fix'
            $file=Write-CurrentPlan -Id existing-result
            $plan=Read-Utf8Text -Path (Join-Path $root $file)|ConvertFrom-Json; $plan.checks=@(@{suiteId='existing'})
            Write-Utf8TextAtomic -Path (Join-Path $root $file) -Value ($plan|ConvertTo-Json -Depth 10)
            Start-VerificationChange -EvidencePath $file | Out-Null
            $script:ChangeLoadReached=$false
            function Update-DevBranchBase { $script:ChangeLoadReached=$true; throw 'Unexpected load' }
            function Assert-VerificationClassificationReady { param($Reason,[switch]$RequireVanessa,[switch]$RequireYAxUnit) }
            function Invoke-DevBranchVanessaRuntimeRelease { }
            { Invoke-DevBranchCheck } | Should -Throw '*ITL_VANESSA_TESTCLIENT_PROFILES_MISSING*Required*'
            $script:ChangeLoadReached | Should -BeFalse
            (Read-VerificationChange).status | Should -BeExactly 'pending'
        }
    }

    It 'adopts valid unchanged legacy observations without another run and preserves them across pending replanning' {
        $root=Join-Path $TestDrive 'Переход без повторного наблюдения'; New-ChangeFixture $root -LegacyOneOff
        Enter-ChangeFixture $root {
            Set-CurrentObservation legacy
            $oldHash=(Get-FileHash -LiteralPath (Get-VerificationOneOffProofPath legacy)).Hash
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current fix'
            $file=Write-CurrentPlan
            $plan=Read-Utf8Text -Path (Join-Path $root $file)|ConvertFrom-Json
            $plan.criteria+=@([pscustomobject]@{id='legacy';expectedResult='Legacy result';decision='unaffected';reason='Other is unchanged and independent of Current.'})
            Write-Utf8TextAtomic -Path (Join-Path $root $file) -Value ($plan|ConvertTo-Json -Depth 10)
            Start-VerificationChange -EvidencePath $file | Out-Null
            @(Get-VerificationOneOffObligations).id | Should -Be @('first')
            # A load and a further current fix do not erase that validated inheritance.
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current fix refined'
            Start-VerificationChange -EvidencePath $file | Out-Null
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Set-CurrentObservation first; Set-CurrentEventEvidence
            (Complete-VerificationChange).changeStatus | Should -BeExactly 'accepted'
            (Get-FileHash -LiteralPath (Get-VerificationOneOffProofPath legacy)).Hash | Should -BeExactly $oldHash
            @((Read-VerificationChange).criteria|Where-Object{ $_.id -eq 'legacy' -and $_.passed }).Count | Should -Be 1
        }
    }

    It 'preserves mandatory retained coverage for <kind>' -TestCases @(@{kind='always'},@{kind='full'}) {
        param($kind)
        & {
            . (Join-Path (Split-Path -Parent $helperPath) 'lib/agent-1c.verification-change.ps1')
            function Read-VerificationChange { [pscustomobject]@{retainedDispositions=@([pscustomobject]@{suiteId='existing';decision='unaffected';reason='Unrelated change'})} }
            function Assert-VerificationChangeCurrent { param($Change) }
            function Get-VanessaFeaturesPath { 'tests/features' }
            function Get-VanessaApplicationFeatureFiles { param($FeaturePath) @() }
            function Read-VerificationSuiteCatalog { param($ApplicationFeatureFiles) [pscustomobject]@{suites=@([pscustomobject]@{id='existing';always=($kind -eq 'always')})} }
            $plan=[pscustomobject]@{mode=$(if($kind -eq 'full'){'full'}else{'incremental'});selectedSuiteIds=@('existing');acceptanceSuiteIds=@('existing')}
            { Get-VerificationChangeSelectionPlan -Plan $plan } | Should -Throw ('*VERIFICATION_CHANGE_'+$(if($kind -eq 'full'){'FULL'}else{'ALWAYS'})+'_REQUIRED*')
        }
    }

    It 'previews the complete delta and supports a direct task without a new requirements document' {
        $root=Join-Path $TestDrive 'Прямой фикс без документа'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current fix'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            $script:ChangeTestState.lastVerificationStatus='passed'
            $script:ChangeTestState.lastVerifiedFingerprint=Get-VerificationFingerprint
            $script:ChangeTestState|Add-Member lastVerifiedLoadedBaseIdentity (Get-VerificationLoadedBaseIdentity -State $script:ChangeTestState)
            $legacy=Get-VerificationState -State $script:ChangeTestState
            $legacy.isFreshPassed | Should -BeFalse
            ($legacy.assessmentIssues -join ';') | Should -Match 'VERIFICATION_CHANGE_REQUIRED'
            $script:ChangeLoadReached=$false
            function Update-DevBranchBase { $script:ChangeLoadReached=$true; throw 'Unexpected load' }
            function Get-DevBranchKind { param($State) 'configuration' }
            function Assert-VerificationClassificationReady { param($Reason,[switch]$RequireVanessa,[switch]$RequireYAxUnit) }
            { Invoke-DevBranchCheck } | Should -Throw '*VERIFICATION_CHANGE_REQUIRED*'
            $script:ChangeLoadReached | Should -BeFalse
            $preview=Start-VerificationChange
            @($preview.changedPaths) | Should -Be @('src/cf/current.bsl')
            Test-Path -LiteralPath (Get-VerificationChangePath) | Should -BeFalse
            $file=Write-CurrentPlan
            $plan=Read-Utf8Text -Path (Join-Path $root $file)|ConvertFrom-Json
            $plan.checks[0].inputPaths=@('untracked-tools/source.ps1')
            { Get-VerificationChangeChecks -Plan $plan } | Should -Throw '*VERIFICATION_CHANGE_INPUT_SCOPE_REQUIRED*'
            $plan.checks[0].inputPaths=@('src/cf/current.bsl')
            $plan.requirementPaths=@(); $plan.criteria=@($plan.criteria|Where-Object id -eq 'AC-01')
            $plan|Add-Member taskDescription 'Fix the requested current result'; $plan|Add-Member sourceReference 'Named user request for this direct fix'
            Write-Utf8TextAtomic -Path (Join-Path $root $file) -Value ($plan|ConvertTo-Json -Depth 10)
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Start-VerificationChange -EvidencePath $file | Out-Null
            { Assert-VanessaVerificationPreflight } | Should -Not -Throw
            Set-CurrentObservation first; Set-CurrentEventEvidence
            (Complete-VerificationChange).taskAccepted | Should -BeTrue
            (Get-VerificationState -State $script:ChangeTestState).isFreshPassed | Should -BeTrue
        }
    }
    It 'keeps task remainder when switching mode and rejects changed observations and target generations' {
        $root=Join-Path $TestDrive 'Режим не скрывает остаток'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current fix'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Start-VerificationChange -EvidencePath (Write-CurrentPlan) | Out-Null
            Set-CurrentObservation first; Set-CurrentEventEvidence; Complete-VerificationChange | Out-Null
            $original=(Get-Command Get-EnvValue).ScriptBlock; $script:chosenModel='cumulative'
            function Get-EnvValue { param($Name,$Default) if($Name -eq 'ITL_VERIFICATION_MODEL'){return $script:chosenModel}; & $original -Name $Name -Default $Default }
            $legacy=Get-VerificationState -State $script:ChangeTestState
            $legacy.taskAccepted | Should -BeFalse
            $legacy.isFreshPassed | Should -BeFalse
            @($legacy.acceptanceRemaining) | Should -Contain 'AC-02'
            $script:chosenModel='change'
            Write-Utf8TextAtomic -Path (Join-Path $root 'evidence/first.txt') -Value 'Altered result'
            (Get-VerificationChangeAssessment -State $script:ChangeTestState -Fingerprint (Get-VerificationFingerprint)).passed | Should -BeFalse
            Write-Utf8TextAtomic -Path (Join-Path $root 'evidence/first.txt') -Value 'Observed expected result'
            $script:ChangeTestState.toolingInfoBaseGeneration='different target'
            $assessment=Get-VerificationChangeAssessment -State $script:ChangeTestState -Fingerprint (Get-VerificationFingerprint)
            $assessment.passed | Should -BeFalse
            ($assessment.issues -join ';') | Should -Match 'VERIFICATION_CHANGE_TARGET_CHANGED'
        }
    }
    It 'plans on a branch without a prepared runner and binds the runner at first use after preparation' {
        $root=Join-Path $TestDrive 'Ветка без runner'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            # 2026-10-27 Develop upgrade: the negative stand plans before any
            # Vanessa preparation, so its branch has no runner generation yet.
            $script:ChangeTestState.PSObject.Properties.Remove('vanessaServiceInfoBaseGeneration')
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current fix'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Start-VerificationChange -EvidencePath (Write-CurrentPlan) | Out-Null
            $planned=Read-VerificationChange
            [string]$planned.targetIdentity | Should -BeNullOrEmpty
            $planned.unboundTargetIdentity | Should -Match '^[a-f0-9]{64}$'
            [string](Assert-VerificationChangeReady -State $script:ChangeTestState).targetIdentity | Should -BeNullOrEmpty
            # Every infobase target field stays strict while the runner is unbound.
            $script:ChangeTestState.toolingInfoBaseGeneration='different target'
            { Assert-VerificationChangeReady -State $script:ChangeTestState } | Should -Throw '*VERIFICATION_CHANGE_TARGET_CHANGED*'
            $script:ChangeTestState.toolingInfoBaseGeneration='target'
            $script:ChangeTestState | Add-Member -NotePropertyName vanessaServiceInfoBaseGeneration -NotePropertyValue 'runner' -Force
            $bound=Assert-VerificationChangeReady -State $script:ChangeTestState
            $bound.targetIdentity | Should -BeExactly (Get-VerificationRetainedTargetIdentity -State $script:ChangeTestState)
            $stored=Read-VerificationChange
            $stored.targetIdentity | Should -BeExactly $bound.targetIdentity
            $stored.PSObject.Properties['unboundTargetIdentity'] | Should -BeNullOrEmpty
            Set-CurrentObservation first; Set-CurrentEventEvidence
            (Complete-VerificationChange).changeStatus | Should -BeExactly 'accepted'
            # Once bound, a different runner is a different target.
            $script:ChangeTestState.vanessaServiceInfoBaseGeneration='recreated runner'
            { Assert-VerificationChangeReady -State $script:ChangeTestState } | Should -Throw '*VERIFICATION_CHANGE_TARGET_CHANGED*'
        }
    }
    It 'plans on a new branch before its first tooling step through the tooling generation owner' {
        $root=Join-Path $TestDrive 'Новая ветка без tooling'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            # 2026-10-27 Develop fresh: new-dev-branch leaves neither the tooling
            # nor the runner generation before the first check plans its change.
            foreach ($name in @('toolingInfoBaseGeneration', 'vanessaServiceInfoBaseGeneration')) { $script:ChangeTestState.PSObject.Properties.Remove($name) }
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current fix'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Start-VerificationChange -EvidencePath (Write-CurrentPlan) | Out-Null
            $generation=[string]$script:ChangeTestState.toolingInfoBaseGeneration
            $generation | Should -Match '^[a-f0-9]{32}$'
            [string](Read-VerificationChange).targetIdentity | Should -BeNullOrEmpty
            # The established generation stays strict until the runner binds.
            $script:ChangeTestState.toolingInfoBaseGeneration='recreated base'
            { Assert-VerificationChangeReady -State $script:ChangeTestState } | Should -Throw '*VERIFICATION_CHANGE_TARGET_CHANGED*'
            $script:ChangeTestState.toolingInfoBaseGeneration=$generation
            $script:ChangeTestState | Add-Member -NotePropertyName vanessaServiceInfoBaseGeneration -NotePropertyValue 'runner' -Force
            (Assert-VerificationChangeReady -State $script:ChangeTestState).targetIdentity | Should -BeExactly (Get-VerificationRetainedTargetIdentity -State $script:ChangeTestState)
        }
    }
    It 'cannot mutate the frozen current scope or claim acceptance without its completed immutable record' {
        $root=Join-Path $TestDrive 'Защита границы и приёмки'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current fix'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Start-VerificationChange -EvidencePath (Write-CurrentPlan) | Out-Null
            Set-CurrentObservation first; Set-CurrentEventEvidence
            $change=Read-VerificationChange; $change.taskAccepted=$true; $change.status='accepted'
            Write-Utf8TextAtomic -Path (Get-VerificationChangePath) -Value ($change|ConvertTo-Json -Depth 16)
            (Get-VerificationChangeAssessment -State $script:ChangeTestState -Fingerprint (Get-VerificationFingerprint)).taskAccepted | Should -BeFalse
            $file=Write-CurrentPlan
            $plan=Read-Utf8Text -Path (Join-Path $root $file)|ConvertFrom-Json; $plan.taskId='forged-task'
            Write-Utf8TextAtomic -Path (Join-Path $root $file) -Value ($plan|ConvertTo-Json -Depth 10)
            { Start-VerificationChange -EvidencePath $file } | Should -Throw '*VERIFICATION_CHANGE_TASK_PENDING*'
            $change.checks=@(); Write-Utf8TextAtomic -Path (Get-VerificationChangePath) -Value ($change|ConvertTo-Json -Depth 16)
            { Read-VerificationChange } | Should -Throw '*VERIFICATION_CHANGE_RECORD_CHANGED*'
        }
    }
    It 'uses existing retained evidence and an explicit unaffected disposition without creating or rerunning a scenario' {
        $root=Join-Path $TestDrive 'Существующая регрессия'; New-ChangeFixture $root -Retained
        Enter-ChangeFixture $root {
            # This fixture isolates UI receipt reuse; applicability remains covered by its owning tests.
            function Get-YAxUnitProductionApplicability { param($Catalog,$State,[switch]$ReadOnly,$OneOffObligations) [pscustomobject]@{classificationComplete=$true;issues=@();decisions=@()} }
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Current UI fix'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            $file=Write-CurrentPlan -Id existing-result
            $p=Read-Utf8Text -Path (Join-Path $root $file)|ConvertFrom-Json; $p.checks=@(@{suiteId='existing'})
            Write-Utf8TextAtomic -Path (Join-Path $root $file) -Value ($p|ConvertTo-Json -Depth 10)
            Start-VerificationChange -EvidencePath $file | Out-Null
            Set-CurrentEventEvidence
            { Complete-VerificationChange } | Should -Throw '*VERIFICATION_CHANGE_RETAINED_RUN_DUE*'
            Write-Utf8TextAtomic -Path (Join-Path $root 'evidence/retained/junit.xml') -Value '<testsuite tests="1" failures="0" errors="0" skipped="0"><testcase name="Existing result" classname="Existing UI" /></testsuite>'
            $selection=New-VerificationSelectionPlan -ApplicationFeatureFiles @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))
            Complete-VerificationSelectionProof -Plan $selection -State $script:ChangeTestState -RunDirectory (Join-Path $root 'evidence/retained')
            Set-CurrentEventEvidence; Complete-VerificationChange | Out-Null
            $junitHash=(Get-FileHash -LiteralPath (Join-Path $root 'evidence/retained/junit.xml')).Hash
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Unrelated handler changed in the same UI module'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            $file=Write-CurrentPlan -Id second -ReuseFirst
            $p=Read-Utf8Text -Path (Join-Path $root $file)|ConvertFrom-Json
            $p.retainedDispositions=@(@{suiteId='existing';decision='unaffected';reason='The changed handler has no path to the previously checked command.'})
            Write-Utf8TextAtomic -Path (Join-Path $root $file) -Value ($p|ConvertTo-Json -Depth 10)
            Start-VerificationChange -EvidencePath $file | Out-Null
            (New-VerificationSelectionPlan -ApplicationFeatureFiles @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))).mode | Should -BeExactly 'reuse'
            Set-CurrentObservation second; Set-CurrentEventEvidence
            (Complete-VerificationChange).changeStatus | Should -BeExactly 'accepted'
            (Get-FileHash -LiteralPath (Join-Path $root 'evidence/retained/junit.xml')).Hash | Should -BeExactly $junitHash
        }
    }
}

Describe 'Verification models and migration' {
    It 'resumes the same one-time default after interruption <boundary>' -TestCases @(@{boundary='before-env'},@{boundary='after-env'}) {
        param($boundary)
        $root=Join-Path $TestDrive ("Прерывание перехода "+$boundary); New-ChangeFixture $root
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value "OTHER=Кириллица с пробелом`r`n"
            $script:InterruptMigration=$true
            $originalWrite=(Get-Command Write-Utf8TextAtomic).ScriptBlock
            $originalComplete=(Get-Command Complete-DotEnvPolicyReceipt).ScriptBlock
            function Write-Utf8TextAtomic {
                param($Path,$Value)
                if($script:InterruptMigration -and $boundary -eq 'before-env' -and $Path -eq (Join-Path $root '.dev.env')) { throw 'Simulated interruption before env' }
                & $originalWrite -Path $Path -Value $Value
            }
            function Complete-DotEnvPolicyReceipt {
                param($Receipt,$Path)
                if($script:InterruptMigration -and $boundary -eq 'after-env') { throw 'Simulated interruption after env' }
                & $originalComplete -Receipt $Receipt -Path $Path
            }
            { Invoke-VerificationModelPolicyTransition } | Should -Throw '*Simulated interruption*'
            $receipt=Get-DotEnvPolicyReceiptPath -Descriptor (Get-DotEnvPolicyTransitionDescriptor verification-model)
            (Read-Utf8Text -Path $receipt|ConvertFrom-Json).status | Should -BeExactly 'applying'
            $script:InterruptMigration=$false
            Invoke-VerificationModelPolicyTransition | Out-Null
            (Read-Utf8Text -Path $receipt|ConvertFrom-Json).status | Should -BeExactly 'completed'
            (Read-Utf8Text -Path (Join-Path $root '.dev.env')) | Should -BeExactly "OTHER=Кириллица с пробелом`r`nITL_VERIFICATION_MODEL=change`r`n"
        }
    }

    It 'defaults to change and keeps explicit cumulative and strict invalid settings' {
        $root=Join-Path $TestDrive 'Настройки с пробелом'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            function Get-EnvValue { param($Name) '' }
            Get-VerificationModel | Should -BeExactly 'change'
            function Get-EnvValue { param($Name) 'cumulative' }
            Get-VerificationModel | Should -BeExactly 'cumulative'
            function Get-EnvValue { param($Name) 'invalid' }
            { Get-VerificationModel } | Should -Throw '*VERIFICATION_MODEL_INVALID*'
        }
    }
    It 'migrates an existing absent value once, preserves later cumulative and restores setting and marker together' {
        $root=Join-Path $TestDrive 'Обновление с кириллицей'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            $before="OTHER=Кириллица с пробелом`r`n"
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value $before
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.dev.env','.agent-1c/migrations/verification-model-change-v1.json') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Invoke-VerificationModelPolicyTransition | Out-Null
            (Read-Utf8Text -Path (Join-Path $root '.dev.env')) | Should -Be ($before+"ITL_VERIFICATION_MODEL=change`r`n")
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value ($before+"ITL_VERIFICATION_MODEL=cumulative`r`n")
            Invoke-VerificationModelPolicyTransition | Out-Null
            (Read-Utf8Text -Path (Join-Path $root '.dev.env')) | Should -Match 'cumulative'
            Restore-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            (Read-Utf8Text -Path (Join-Path $root '.dev.env')) | Should -BeExactly $before
            Test-Path -LiteralPath (Join-Path $root '.agent-1c/migrations/verification-model-change-v1.json') | Should -BeFalse
            Remove-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
        }
    }
}

Describe 'Current change proof and whole task acceptance' {
    It 'accepts observed current behavior without a feature file and preserves task remainder (absent catalog: <WithoutCatalog>)' -TestCases @(@{WithoutCatalog=$false}, @{WithoutCatalog=$true}) {
        param($WithoutCatalog)
        $root=Join-Path $TestDrive ('Изменение без feature ' + $WithoutCatalog); New-ChangeFixture $root -WithoutCatalog:$WithoutCatalog
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Procedure Current() Message(42); EndProcedure'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            $plan=Write-CurrentPlan
            Start-VerificationChange -EvidencePath $plan | Out-Null
            $selection = Get-ItlVanessaVerificationSelectionPlan
            $selection.mode | Should -BeExactly 'reuse'
            $selection.catalogAvailable | Should -Be (-not $WithoutCatalog)
            $selection.reason | Should -Match 'One-off obligations'
            if ($WithoutCatalog) {
                Complete-VerificationSelectionProof -Plan $selection
                Test-Path -LiteralPath (Join-Path $root '.agent-1c/verification-selection/proof.json') | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $root 'tests/verification-suites.branch.json') | Should -BeFalse
            }
            { Complete-VerificationChange } | Should -Throw '*VERIFICATION_CHANGE_PENDING*'
            Set-CurrentObservation first
            Set-CurrentEventEvidence
            $actual=Complete-VerificationChange
            $actual.changeStatus | Should -BeExactly 'accepted'
            $acceptedTree=(Read-VerificationChange).tree
            & git -C $root gc --prune=now --quiet
            $LASTEXITCODE | Should -Be 0
            & git -C $root cat-file -e "$acceptedTree^{tree}"
            $LASTEXITCODE | Should -Be 0 -Because 'the accepted base must survive collection of unreferenced temporary trees'
            $actual.taskAccepted | Should -BeFalse
            @($actual.remaining) | Should -Contain 'AC-02'
            $history=(Read-VerificationChange).acceptedArtifact
            $historyHash=(Get-FileHash -LiteralPath (Join-Path $root $history.path)).Hash
            (Complete-VerificationChange).taskAccepted | Should -BeFalse
            (Get-FileHash -LiteralPath (Join-Path $root $history.path)).Hash | Should -BeExactly $historyHash
            @(Get-ChildItem -LiteralPath (Join-Path $root 'tests/features') -File).Count | Should -Be 0
            $state=Get-VerificationState -State $script:ChangeTestState
            $state.changeFreshPassed | Should -BeTrue
            $state.isFreshPassed | Should -BeFalse
            $state.taskAccepted | Should -BeFalse
        }
    }
    It 'preserves prior acceptance through an unrelated config load and observes only the new change' {
        $root=Join-Path $TestDrive 'Повтор без старого MCP'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Procedure Current() Message(42); EndProcedure'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Start-VerificationChange -EvidencePath (Write-CurrentPlan) | Out-Null
            Set-CurrentObservation first; Set-CurrentEventEvidence; Complete-VerificationChange | Out-Null
            $firstHash=(Get-FileHash -LiteralPath (Get-VerificationOneOffProofPath first)).Hash
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/other.bsl') -Value 'Procedure Other() Message(2); EndProcedure'
            & git -C $root add -- src
            & git -C $root commit -qm 'A new commit cannot reset the accepted base'
            $script:ChangeTestState.lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
            Start-VerificationChange -EvidencePath (Write-CurrentPlan -Id second -Path 'src/cf/other.bsl' -ReuseFirst -Finish) | Out-Null
            @(Get-VerificationOneOffObligations).id | Should -Be @('second')
            Set-CurrentObservation second; Set-CurrentEventEvidence
            $actual=Complete-VerificationChange
            $actual.taskAccepted | Should -BeTrue
            (Get-FileHash -LiteralPath (Get-VerificationOneOffProofPath first)).Hash | Should -BeExactly $firstHash
            (Get-VerificationState -State $script:ChangeTestState).isFreshPassed | Should -BeTrue
            { Start-VerificationOneOffProof -ObligationId first } | Should -Throw '*VERIFICATION_ONE_OFF_OBLIGATION_MISSING*'
        }
    }
    It 'rejects omitted source, omitted criteria and post-plan edits without advancing the base' {
        $root=Join-Path $TestDrive 'Нельзя спрятать правку'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Changed current'
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/other.bsl') -Value 'Changed other'
            $plan=Write-CurrentPlan
            { Start-VerificationChange -EvidencePath $plan } | Should -Throw '*VERIFICATION_CHANGE_PATH_PENDING*'
            & git -C $root checkout -- src/cf/other.bsl
            $p=Read-Utf8Text -Path (Join-Path $root $plan)|ConvertFrom-Json
            $p.criteria=@($p.criteria|Where-Object id -eq 'AC-01')
            Write-Utf8TextAtomic -Path (Join-Path $root $plan) -Value ($p|ConvertTo-Json -Depth 10)
            { Start-VerificationChange -EvidencePath $plan } | Should -Throw '*VERIFICATION_CHANGE_ACCEPTANCE_INCOMPLETE*'
            Start-VerificationChange -EvidencePath (Write-CurrentPlan) | Out-Null
            $base=(Read-VerificationChange).baseTree
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Changed again'
            { Complete-VerificationChange } | Should -Throw '*VERIFICATION_CHANGE_STALE*'
            (Read-VerificationChange).baseTree | Should -BeExactly $base
            $script:ChangeTestState|Add-Member resetArchivePath (Join-Path $root 'evidence/reset archive')
            $script:ChangeTestState|Add-Member resetNewHead ('1'*40)
            { Archive-VerificationChangeForReset -State $script:ChangeTestState } | Should -Throw '*VERIFICATION_CHANGE_RESET_ARCHIVE_MISSING*'
            Test-Path -LiteralPath (Get-VerificationChangePath) | Should -BeTrue
            New-Item -ItemType Directory -Force -Path $script:ChangeTestState.resetArchivePath | Out-Null
            $oldHash=(Get-FileHash -LiteralPath (Get-VerificationChangePath)).Hash
            Archive-VerificationChangeForReset -State $script:ChangeTestState
            Test-Path -LiteralPath (Get-VerificationChangePath) | Should -BeFalse
            (Get-FileHash -LiteralPath (Join-Path (Get-VerificationSelectionStateRoot) ('changes/reset-'+('1'*40)+'.json'))).Hash | Should -BeExactly $oldHash
        }
    }
    It 'cannot manufacture old acceptance or erase pending checks with a new task name' {
        $root=Join-Path $TestDrive 'Не терять приёмку'; New-ChangeFixture $root
        Enter-ChangeFixture $root {
            Write-Utf8TextAtomic -Path (Join-Path $root 'src/cf/current.bsl') -Value 'Changed'
            $plan=Write-CurrentPlan -ReuseFirst
            { Start-VerificationChange -EvidencePath $plan } | Should -Throw '*VERIFICATION_CHANGE_REUSE_UNPROVED*'
            Start-VerificationChange -EvidencePath (Write-CurrentPlan) | Out-Null
            $p=Read-Utf8Text -Path (Join-Path $root $plan)|ConvertFrom-Json; $p.taskId='different'
            Write-Utf8TextAtomic -Path (Join-Path $root $plan) -Value ($p|ConvertTo-Json -Depth 10)
            { Start-VerificationChange -EvidencePath $plan } | Should -Throw '*VERIFICATION_CHANGE_TASK_PENDING*'
        }
    }
}
