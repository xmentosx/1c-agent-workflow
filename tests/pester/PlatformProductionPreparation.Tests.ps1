BeforeAll {
    $helper = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    function Invoke-PlatformPurposeFixture {
        param([string]$Case,[string]$Extension='')
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
            $failure='';$proof=$null;$second=$null
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
                {$_ -in @('reuse','drift-log','drift-target','drift-source','no-baseline','wrong-source','development-export','disposed-snapshot')} {
                    $script:ResultPurpose=if($Case -eq 'development-export'){'development'}else{'production'}
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
            }
            [pscustomobject]@{calls=@($script:calls.ToArray());proof=$proof;second=$second;failure=$failure;firstCount=$(if(Get-Variable firstCount -ErrorAction SilentlyContinue){$firstCount}else{0})}
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
}
