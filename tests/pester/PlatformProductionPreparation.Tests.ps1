BeforeAll {
    $helper = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    function Invoke-PlatformPurposeFixture {
        param([string]$Case,[string]$Extension='',[string]$Purpose='production',
            [ValidateSet('development','executed','reused','legacy')][string]$ReportPreparation='development',
            [switch]$VerificationFails,[switch]$ReportFails,[switch]$FinalRestoreFails)
        $root = Join-Path $TestDrive ('Проверка с пробелом ' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        & {
            . $helper -ProjectRoot $root -Action help *> $null
            $script:Action = 'export-dev-branch-result'
            $script:ResultPurpose = 'development'
            $script:calls = [Collections.Generic.List[string]]::new()
            $script:sourceFile = Join-Path $root 'Модуль.bsl'
            [IO.File]::WriteAllText($script:sourceFile,'Процедура Тест() КонецПроцедуры')
            $script:problem = ''
            function Get-ConfigSourceFingerprint {
                param($ExportPath)
                [pscustomobject]@{fingerprint=('v2|git-tree-sha256|' + (Get-FileHash -LiteralPath $script:sourceFile -Algorithm SHA256).Hash.ToLowerInvariant())}
            }
            function Get-PlatformPath { (Get-Process -Id $PID).Path }
            function Invoke-PlatformGate6NativeCheck {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$Arguments,$ResultPath)
                $script:calls.Add($Arguments[0])
                $log = $ResultPath + '.log'
                $code = if ($script:problem -ceq $Arguments[0]) {101} else {0}
                [IO.File]::WriteAllText($ResultPath,[string]$code)
                [IO.File]::WriteAllText($log,$(if($code){'Ошибка проверки'}else{'Ошибок: 0; предупреждений: 0'}))
                if ($script:problem -eq 'mutate-source' -and $Arguments[0] -eq '/CheckConfig') {
                    [IO.File]::AppendAllText($script:sourceFile,' // changed during native check')
                }
                [pscustomobject]@{logPath=$log;resultPath=$ResultPath;verdict=(Get-DesignerBatchCheckVerdict -ExitCode $code -ResultPath $ResultPath -LogPath $log)}
            }
            function New-DesignerGate6Snapshot {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$EnclosingSnapshot)
                $script:calls.Add('snapshot')
                $path=Join-Path $root 'snapshot.dt';[IO.File]::WriteAllText($path,'snapshot')
                [pscustomobject]@{path=$path;sha256=(Get-FileHash $path).Hash.ToLowerInvariant();owned=$true;completed=$false;duty='fixture'}
            }
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,$RestorationDuty,[string[]]$DesignerArgs)
                $script:calls.Add($DesignerArgs[0])
                $script:LastLogPath=Join-Path $root 'load.log';[IO.File]::WriteAllText($script:LastLogPath,'Loaded')
            }
            function Complete-OneCDatabaseRestorationDuty { param($Duty,$Resolution) }
            function Remove-CompletedInfobaseSnapshot { param($SnapshotPath) }
            $fp = (Get-ConfigSourceFingerprint $root).fingerprint
            $target=Join-Path $root 'ИБ'
            $params=@{InfoBasePath=$target;InfoBaseKind='file';SourceFingerprint=$fp;ExtensionName=$Extension;User='';Password=''}
            $failure='';$failureId='';$proof=$null;$second=$null;$script:reportPreparation=$null
            switch ($Case) {
                'development' { $proof=Invoke-DesignerGate6CheckLadder @params -CheckProfile development }
                'production' { $proof=Invoke-DesignerGate6CheckLadder @params -CheckProfile production }
                'development-load' {
                    $proof=Invoke-ConfigLoadDesignerAttempt -InfoBasePath $target -InfoBaseKind file -SourceFingerprint $fp -RequireGate6 -CheckProfile development `
                        -LegacyContext ([pscustomobject]@{unusable='must not capture before'}) -User '' -Password '' -DesignerArgs @('/LoadConfigFromFiles',$root,'/UpdateDBCfg')
                }
                'modules-fail' {
                    $script:problem='/CheckModules'
                    try { Invoke-ConfigLoadDesignerAttempt -InfoBasePath $target -InfoBaseKind file -SourceFingerprint $fp -RequireGate6 -CheckProfile development `
                        -User '' -Password '' -DesignerArgs @('/LoadConfigFromFiles',$root,'/UpdateDBCfg') | Out-Null } catch { $failure=$_.Exception.Message }
                }
                'applicability-fail' {
                    $script:problem='/CheckCanApplyConfigurationExtensions'
                    try { Invoke-ConfigLoadDesignerAttempt -InfoBasePath $target -InfoBaseKind file -SourceFingerprint $fp -ExtensionName 'Расширение' -CheckProfile development `
                        -User '' -Password '' -DesignerArgs @('/LoadConfigFromFiles',$root,'-Extension','Расширение','/UpdateDBCfg') | Out-Null } catch { $failure=$_.Exception.Message }
                }
                {$_ -in @('reuse','drift-log','drift-target','drift-source','no-baseline','wrong-source','development-export','disposed-snapshot','purpose-variant')} {
                    $script:ResultPurpose=if($Case -eq 'development-export'){'development'}else{$Purpose}
                    $args=@{ExportPath=$root;SourceFingerprint=$fp;InfoBaseKind='file';InfoBasePath=$target;LoadedBaseIdentity='loaded-1';User='';Password=''}
                    if($Case -eq 'no-baseline'){$script:problem='/CheckConfig'}
                    if($Case -eq 'drift-source'){$script:problem='mutate-source'}
                    if($Case -eq 'wrong-source'){$args.SourceFingerprint='other-source'}
                    try {
                        $proof=Confirm-ProductionPlatformCheck @args
                        $firstCount=$script:calls.Count
                        if($Case -eq 'drift-log'){[IO.File]::AppendAllText($proof.evidence.steps[0].logPath,'changed')}
                        if($Case -eq 'drift-target'){$args.LoadedBaseIdentity='loaded-2'}
                        # No snapshot exists for a standalone read-only check. Reuse must not create one.
                        if($Case -in @('reuse','drift-log','drift-target','disposed-snapshot')){
                            $second=Confirm-ProductionPlatformCheck @args -Evidence $proof.evidence
                        }
                    } catch {$failure=$_.Exception.Message}
                }
                'profile-matrix' {
                    $matrix=@{}
                    foreach($name in @('check-dev-branch','refresh-dev-branch','export-dev-branch-result','close-dev-branch','install-yaxunit','release-e2e-extension-smoke')){
                        $script:Action=$name;$matrix[$name]=Get-PlatformCheckProfile
                    }
                    $script:Action='export-dev-branch-result';$script:ResultPurpose='production';$matrix.production=Get-PlatformCheckProfile
                    $proof=$matrix
                }
                'origin-rejection' {
                    $state=[pscustomobject]@{loadReason='source-load';lastConfigDesignerFingerprint='previous'}
                    $delta=[pscustomobject]@{previousTreeObjectId=('a'*40);currentTreeObjectId=('b'*40)}
                    $proof=New-ProductionPlatformLegacyContext -State $state -ChangeSet $delta -SourceFingerprint $fp -InfoBaseKind file -InfoBasePath $target
                }
                { $_ -in @('check-report','partial-check-report') } {
                    $script:VerificationTrigger='command'; $script:ExplicitVerificationComponent=''
                    $script:DevBranchName='fixture'; $script:reportPartial=($Case -eq 'partial-check-report')
                    $script:reportMode=$ReportPreparation; $script:verificationFails=[bool]$VerificationFails
                    $script:reportState=[pscustomobject]@{devBranch='itldev/fixture';lastVerificationSkippedComponents=@('event-log');lastVerifiedReportPath='previous-verification.html'}
                    function Assert-ItlVerificationRepairScope {}
                    function Read-DevBranchState { $script:reportState }
                    function Get-DevBranchKind { 'configuration' }
                    function Get-ExportPath { $root }
                    $script:dumpLock=$null; $script:dumpSnapshot=$null; $script:recoveryCompleted=$false
                    if ($FinalRestoreFails) {
                        # Use the real snapshot/restore/remove owners. Only the native
                        # verification boundary acquires a lock after its first restore.
                        [IO.File]::WriteAllText((Join-Path $root 'ConfigDumpInfo.xml'),'исходный курсор')
                        function Register-OneCFileRestorationDuty { param($Snapshot) $script:dumpSnapshot=$Snapshot }
                    } else {
                        function New-ConfigDumpInfoLoadSnapshot { [pscustomobject]@{} }
                        function Restore-ConfigDumpInfoLoadSnapshot {}
                        function Remove-ConfigDumpInfoLoadSnapshot {}
                    }
                    function Invoke-DevBranchVanessaRuntimeRelease {}
                    function Assert-VanessaVerificationPreflight {}
                    # This report fixture supplies completed platform preparation
                    # and a delegated verification cycle, not a Git test catalog.
                    function Repair-OneCSourceLineEndings {}
                    function Assert-VerificationClassificationReady {}
                    function Test-ItlFullVerificationProofEligible { $true }
                    function Ensure-DevBranchEventLogBaseline { $script:reportState }
                    function Ensure-DevBranchEventLogPendingCursor { [pscustomobject]@{path='cursor';capturedAt=[datetime]::UtcNow} }
                    function Update-DevBranchBase {
                        param([switch]$PassThruPlatformPreparation)
                        if (-not $PassThruPlatformPreparation) { return }
                        if ($script:reportMode -eq 'legacy') {
                            $script:reportPreparation=[pscustomobject]@{purpose='production';status='accepted-with-preexisting-findings';receiptPath=(Join-Path $root 'legacy-receipt.json')}
                        } elseif ($script:reportMode -eq 'development') {
                            $script:reportPreparation=Confirm-ProductionPlatformCheck -ExportPath $root
                        } else {
                            $script:ResultPurpose='production'
                            $preparationArgs=@{ExportPath=$root;SourceFingerprint=$fp;InfoBaseKind='file';InfoBasePath=$target;LoadedBaseIdentity='loaded-1';User='';Password=''}
                            $script:reportPreparation=Confirm-ProductionPlatformCheck @preparationArgs
                            if ($script:reportMode -eq 'reused') {
                                $script:reportPreparation=Confirm-ProductionPlatformCheck @preparationArgs -Evidence $script:reportPreparation.evidence
                            }
                        }
                        return $script:reportPreparation
                    }
                    function Invoke-ItlVerificationCycle {
                        if ($FinalRestoreFails) {
                            $script:dumpLock=[IO.File]::Open((Join-Path $root 'ConfigDumpInfo.xml'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                        }
                        if ($script:verificationFails) { throw 'FOLLOWING_VERIFICATION_FAILED: YAxUnit regression failed.' }
                    }
                    function Complete-PendingDevBranchRefreshAfterVerifiedRecovery { $script:recoveryCompleted=$true }
                    function Get-VerificationState {
                        [pscustomobject]@{status='passed';effectiveStatus=$(if($script:reportPartial){'partial'}else{'passed'});isFreshPassed=(-not $script:reportPartial);assessmentIssues=$(if($script:reportPartial){@('event-log proof missing')}else{@()})}
                    }
                    if ($ReportFails) { function Set-RunUserReport { throw 'REPORT_RENDER_FAILED' } }
                    try { Invoke-DevBranchCheck 3>$null 6>$null } catch { $failure=$_.Exception.Message; $failureId=$_.FullyQualifiedErrorId }
                    finally { if ($null -ne $script:dumpLock) { $script:dumpLock.Dispose() } }
                }
                'legacy-report' {
                    $proof=[pscustomobject]@{purpose='production';status='accepted-with-preexisting-findings';receiptPath=(Join-Path $root 'legacy-receipt.json')}
                }
            }
            if ($Case -notin @('check-report','partial-check-report')) {
                $lines=[Collections.Generic.List[string]]::new(); $lines.Add('## Результат ветки')
                Write-AndSetRunUserReport -Lines $lines -PlatformPreparation $(if($null -ne $second){$second}else{$proof}) 6>$null
            }
            $snapshotRetained=$false; $cursorRestored=$false
            if ($FinalRestoreFails -and $null -ne $script:dumpSnapshot) {
                $snapshotRetained=$script:dumpSnapshot.preserveBackup -and (Test-Path -LiteralPath $script:dumpSnapshot.backupPath)
                $cursorRestored=[IO.File]::ReadAllText($script:dumpSnapshot.path) -ceq 'исходный курсор'
                # The production owner must retain it on failure; the test owns
                # removal only after observing its content and recovery status.
                if ($snapshotRetained) {
                    $snapshotRetained=[IO.File]::ReadAllText($script:dumpSnapshot.backupPath) -ceq 'исходный курсор'
                    Remove-Item -LiteralPath $script:dumpSnapshot.backupPath -Force
                }
            }
            [pscustomobject]@{calls=@($script:calls.ToArray());proof=$proof;second=$second;failure=$failure;failureId=$failureId;preparation=$script:reportPreparation;report=$script:RunUserReport;snapshotRetained=$snapshotRetained;cursorRestored=$cursorRestored;recoveryCompleted=$(if($Case -in @('check-report','partial-check-report')){$script:recoveryCompleted}else{$false});firstCount=$(if(Get-Variable firstCount -ErrorAction SilentlyContinue){$firstCount}else{0})}
        }
    }
}

Describe 'Development versus explicit production preparation' {
    It 'runs only modules for development CF and retains an explicit unselected configuration step' {
        $r=Invoke-PlatformPurposeFixture development
        $r.calls | Should -Be @('/CheckModules')
        $r.proof.steps[-1].status | Should -BeExactly 'not-required-development'
        $r.proof.steps[-1].nativePassed | Should -BeFalse
        $r.proof.cleanPassed | Should -BeFalse
    }
    It 'retains extension applicability during development' {
        (Invoke-PlatformPurposeFixture development -Extension 'Расширение').calls | Should -Be @('/CheckModules','/CheckCanApplyConfigurationExtensions')
    }
    It 'runs the full ladder only for production' {
        (Invoke-PlatformPurposeFixture production -Extension 'Расширение').calls | Should -Be @('/CheckModules','/CheckCanApplyConfigurationExtensions','/CheckConfig')
    }
    It 'requires full preparation for ResultPurpose <Purpose>' -ForEach @(
        @{Purpose='production'},@{Purpose='Production'},@{Purpose='PRODUCTION'}
    ) {
        $r=Invoke-PlatformPurposeFixture purpose-variant -Purpose $Purpose
        $r.failure | Should -BeNullOrEmpty
        $r.proof.purpose | Should -BeExactly 'production'
        $r.proof.status | Should -BeExactly 'passed'
        $r.calls | Should -Be @('/CheckModules','/CheckConfig')
    }
    It 'keeps snapshot load compilation and apply without a hidden before-CheckConfig' {
        (Invoke-PlatformPurposeFixture development-load).calls | Should -Be @('snapshot','/LoadConfigFromFiles','/CheckModules','/UpdateDBCfg')
    }
    It 'rolls back failed compilation without applying' {
        $r=Invoke-PlatformPurposeFixture modules-fail
        $r.failure | Should -Match 'GATE6_CHECK_FAILED'
        $r.calls | Should -Contain '/RestoreIB'
        $r.calls | Should -Not -Contain '/UpdateDBCfg'
    }
    It 'rolls back failed applicability without applying' {
        $r=Invoke-PlatformPurposeFixture applicability-fail
        $r.failure | Should -Match 'GATE6_CHECK_FAILED'
        $r.calls | Should -Contain '/RestoreIB'
        $r.calls | Should -Not -Contain '/UpdateDBCfg'
    }
    It 'does not launch native checks for an intermediate export' {
        $r=Invoke-PlatformPurposeFixture development-export
        $r.calls.Count | Should -Be 0
        $r.proof.status | Should -BeExactly 'not-required-development'
    }
    It 'checks an already loaded candidate and reuses its exact complete proof' {
        $r=Invoke-PlatformPurposeFixture reuse
        $r.failure | Should -BeNullOrEmpty
        $r.calls | Should -Be @('/CheckModules','/CheckConfig')
        $r.second.status | Should -BeExactly 'passed'
    }
    It 'rechecks changed <Case> evidence' -ForEach @(@{Case='drift-log'},@{Case='drift-target'}) {
        $r=Invoke-PlatformPurposeFixture $Case
        $r.failure | Should -BeNullOrEmpty
        $r.calls | Should -Be @('/CheckModules','/CheckConfig','/CheckModules','/CheckConfig')
    }
    It 'does not require a disposed rollback snapshot for completed read-only proof' {
        (Invoke-PlatformPurposeFixture disposed-snapshot).calls | Should -Be @('/CheckModules','/CheckConfig')
    }
    It 'does not invent a legacy baseline when configuration checking fails' {
        $r=Invoke-PlatformPurposeFixture no-baseline
        $r.failure | Should -Match 'GATE6_CHECK_FAILED'
        $r.calls | Should -Be @('/CheckModules','/CheckConfig')
    }
    It 'rejects a mismatched loaded source before native execution' {
        $r=Invoke-PlatformPurposeFixture wrong-source
        $r.failure | Should -Match 'PRODUCTION_PLATFORM_SOURCE_UNPROVEN'
        $r.calls.Count | Should -Be 0
    }
    It 'refuses production proof if source bytes change during the native check' {
        $r=Invoke-PlatformPurposeFixture drift-source
        $r.failure | Should -Match 'PRODUCTION_PLATFORM_SOURCE_CHANGED'
        $r.proof | Should -BeNullOrEmpty
        $r.calls | Should -Be @('/CheckModules','/CheckConfig')
    }
    It 'keeps all ordinary routes in development and retains explicit Release qualification' {
        $r=Invoke-PlatformPurposeFixture profile-matrix
        $r.proof['check-dev-branch'] | Should -Be development
        $r.proof['refresh-dev-branch'] | Should -Be development
        $r.proof['export-dev-branch-result'] | Should -Be development
        $r.proof['close-dev-branch'] | Should -Be development
        $r.proof['install-yaxunit'] | Should -Be development
        $r.proof['release-e2e-extension-smoke'] | Should -Be production
        $r.proof.production | Should -Be production
    }
    It 'cannot use the last unqualified development load as the legacy origin' {
        (Invoke-PlatformPurposeFixture origin-rejection).proof | Should -BeNullOrEmpty
    }
    It 'explains a skipped configuration check once in the intermediate result report without running it' {
        $r=Invoke-PlatformPurposeFixture development-export
        $r.calls.Count | Should -Be 0
        ([regex]::Matches($r.report,'Полная проверка конфигурации .* не выполнялась')).Count | Should -Be 1
        $r.report | Should -Match 'до подготовки к рабочей ИБ или прямого вызова'
        $r.report | Should -Match 'логическую целостность|ссылки на отсутствующие объекты'
        $r.report | Should -Match 'наличие обработчиков'
        $r.report | Should -Match 'свойствам, методам'
        $r.report | Should -Match 'Выполни полную проверку конфигурации CheckConfig'
    }
    It 'shows the completed check result and receipt without a skipped-check notice' {
        $r=Invoke-PlatformPurposeFixture purpose-variant
        $r.report | Should -Match 'CheckConfig: пройдена'
        $r.report | Should -Match ([regex]::Escape($r.proof.receiptPath))
        $r.report | Should -Not -Match 'не выполнялась|Для запуска напишите'
    }
    It 'shows reused proof as a result without rerunning or claiming the check was skipped' {
        $r=Invoke-PlatformPurposeFixture reuse
        $r.calls | Should -Be @('/CheckModules','/CheckConfig')
        $r.report | Should -Match 'CheckConfig: пройдена'
        $r.report | Should -Match ([regex]::Escape($r.second.receiptPath))
        $r.report | Should -Not -Match 'не выполнялась|Для запуска напишите'
    }
    It 'keeps accepted preexisting findings visible instead of reporting a clean check' {
        $r=Invoke-PlatformPurposeFixture legacy-report
        $r.report | Should -Match 'допущена с прежними замечаниями'
        $r.report | Should -Not -Match 'CheckConfig: пройдена|не выполнялась'
    }
    It 'does not infer a skipped or passed configuration check from missing evidence' {
        $r=Invoke-PlatformPurposeFixture origin-rejection
        $r.report | Should -Not -Match 'CheckConfig|не выполнялась|Для запуска напишите'
    }
    It 'includes the notice in the actual final development check report' {
        $r=Invoke-PlatformPurposeFixture check-report
        $r.failure | Should -BeNullOrEmpty
        $r.calls.Count | Should -Be 0
        $r.report | Should -Match '## Проверка доработок'
        $r.report | Should -Match 'Результат: fresh passed'
        $r.report | Should -Match 'не выполнялась'
    }
    It 'preserves partial verification and missing obligations alongside the notice' {
        $r=Invoke-PlatformPurposeFixture partial-check-report
        $r.failure | Should -BeNullOrEmpty
        $r.report | Should -Match 'Результат: partial'
        $r.report | Should -Match 'Пропущенные компоненты: event-log'
        $r.report | Should -Match 'event-log proof missing'
        $r.report | Should -Not -Match 'fresh passed'
    }
    It 'retains the <Preparation> CheckConfig result when later verification fails' -ForEach @(
        @{Preparation='executed';Display='пройдена'}
        @{Preparation='reused';Display='пройдена'}
        @{Preparation='legacy';Display='допущена с прежними замечаниями'}
    ) {
        $r=Invoke-PlatformPurposeFixture check-report -ReportPreparation $Preparation -VerificationFails
        $r.failure | Should -BeExactly 'FOLLOWING_VERIFICATION_FAILED: YAxUnit regression failed.'
        $r.failureId | Should -BeExactly $r.failure
        $r.report | Should -Match 'Результат: failed'
        $r.report | Should -Match ([regex]::Escape($r.failure))
        $r.report | Should -Match ('CheckConfig: ' + $Display)
        $r.report | Should -Match ([regex]::Escape($r.preparation.receiptPath))
        $r.report | Should -Not -Match 'fresh passed|не выполнялась|Для запуска напишите|previous-verification.html'
        if ($Preparation -eq 'legacy') {
            $r.report | Should -Not -Match 'CheckConfig: пройдена'
            $r.calls.Count | Should -Be 0
        } else { $r.calls | Should -Be @('/CheckModules','/CheckConfig') }
    }
    It 'retains the development skip notice without turning a later failure into success' {
        $r=Invoke-PlatformPurposeFixture check-report -VerificationFails
        $r.failure | Should -BeExactly 'FOLLOWING_VERIFICATION_FAILED: YAxUnit regression failed.'
        $r.report | Should -Match 'Результат: failed'
        ([regex]::Matches($r.report,'Полная проверка конфигурации .* не выполнялась')).Count | Should -Be 1
        $r.report | Should -Not -Match 'fresh passed|CheckConfig: пройдена|previous-verification.html'
        $r.calls.Count | Should -Be 0
    }
    It 'preserves the original verification error even if failure reporting also fails' {
        $r=Invoke-PlatformPurposeFixture check-report -VerificationFails -ReportFails
        $r.failure | Should -BeExactly 'FOLLOWING_VERIFICATION_FAILED: YAxUnit regression failed.'
        $r.failureId | Should -BeExactly $r.failure
    }
    It 'reports failed and retains <Preparation> CheckConfig proof when final cursor restoration fails' -ForEach @(
        @{Preparation='executed';Display='пройдена'}
        @{Preparation='reused';Display='пройдена'}
        @{Preparation='legacy';Display='допущена с прежними замечаниями'}
    ) {
        $r=Invoke-PlatformPurposeFixture check-report -ReportPreparation $Preparation -FinalRestoreFails
        $r.failure | Should -Match 'ConfigDumpInfo rollback failed.*Recovery snapshot was preserved'
        $r.report | Should -Match 'Результат: failed'
        $r.report | Should -Match ([regex]::Escape($r.failure))
        $r.report | Should -Match ('CheckConfig: '+$Display)
        $r.report | Should -Match ([regex]::Escape($r.preparation.receiptPath))
        $r.report | Should -Not -Match 'fresh passed|не выполнялась|previous-verification.html'
        $r.snapshotRetained | Should -BeTrue
        $r.cursorRestored | Should -BeTrue
        $r.recoveryCompleted | Should -BeFalse
    }
}
