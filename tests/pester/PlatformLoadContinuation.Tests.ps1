BeforeAll {
    $repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $helperPath=Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    $lib=Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib'
    foreach ($group in @(
        @{file='agent-1c.core.ps1';names=@('ConvertTo-NativeCommandLineArgument','Join-NativeCommandLineArguments')},
        @{file='agent-1c.vanessa.ps1';names=@('Invoke-ItlNativeProcessCapture')}
    )) {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $lib $group.file),[ref]$tokens,[ref]$errors)
        if(@($errors).Count){throw 'Fixture native transport owner parse failed'}
        foreach($name in $group.names){
            $definition=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
            if($definition.Count -ne 1){throw ('Fixture transport unavailable: '+$name)}
            . ([scriptblock]::Create($definition[0].Extent.Text))
        }
    }
    function Invoke-ContinuationGit {
        param([string]$Root,[string[]]$Arguments)
        $capture=Invoke-ItlNativeProcessCapture -FilePath 'git' -WorkingDirectory $Root -Arguments (@('-C',$Root,'-c','core.quotepath=false')+@($Arguments))
        if($capture.exitCode -ne 0){throw ('Fixture Git failed: '+$capture.stderr)}
        return $capture.stdout.Trim()
    }
    function Write-ContinuationJson {
        param([string]$Path,[object]$Value)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
        [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))
    }
    function Write-ContinuationSource {
        param([string]$Root,[string]$Path,[string]$Text)
        $full=Join-Path $Root ('src/cf/'+$Path)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
        [IO.File]::WriteAllText($full,($Text -replace '\r?\n',"`r`n"),[Text.UTF8Encoding]::new($true))
    }
    function New-ContinuationProject {
        $root=Join-Path $TestDrive ('Продолжение загрузки 1С '+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        Invoke-ContinuationGit $root @('init','--quiet') | Out-Null
        Invoke-ContinuationGit $root @('config','user.name','fixture') | Out-Null
        Invoke-ContinuationGit $root @('config','user.email','fixture@example.invalid') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.gitattributes'),"src/cf/** -text`r`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'),".agent-1c/`r`nlogs/`r`nbuild/`r`n",[Text.UTF8Encoding]::new($false))
        Write-ContinuationSource $root 'Configuration.xml' '<MetaDataObject><Configuration uuid="11111111-1111-1111-1111-111111111111"><Properties><Name>Тест</Name><Comment>исходный</Comment></Properties><ChildObjects><CommonModule>Изменённый</CommonModule><CommonModule>Прежний</CommonModule></ChildObjects></Configuration></MetaDataObject>'
        foreach($module in @(@{name='Изменённый';uuid='22222222-2222-2222-2222-222222222222'},@{name='Прежний';uuid='33333333-3333-3333-3333-333333333333'})){
            Write-ContinuationSource $root ('CommonModules/'+$module.name+'.xml') ('<MetaDataObject><CommonModule uuid="'+$module.uuid+'"><Properties><Name>'+$module.name+'</Name><Server>true</Server></Properties></CommonModule></MetaDataObject>')
            Write-ContinuationSource $root ('CommonModules/'+$module.name+'/Ext/Module.bsl') "&НаСервере`r`nФункция Значение() Экспорт`r`n    Возврат 1;`r`nКонецФункции"
        }
        Write-ContinuationSource $root 'ConfigDumpInfo.xml' '<ConfigDumpInfo>original cursor</ConfigDumpInfo>'
        Invoke-ContinuationGit $root @('add','--all') | Out-Null
        Invoke-ContinuationGit $root @('commit','--quiet','-m','original configuration') | Out-Null
        return [pscustomobject]@{root=$root;sourceRoot=(Join-Path $root 'src/cf');infoBase=(Join-Path $root '.agent-1c/infobases/База');
            database=(Join-Path $root '.agent-1c/infobases/База/fixture-database.bin');module='CommonModules/Изменённый/Ext/Module.bsl';
            evidence=(Join-Path $root '.agent-1c/proofs/coverage.json');fault='';calls=[Collections.Generic.List[object]]::new();applied=$false}
    }
    function Save-ContinuationCoverage {
        param([object]$Fixture)
        $requestPath=Join-Path $Fixture.root '.agent-1c/proofs/request.json'
        $resultPath=Join-Path $Fixture.root '.agent-1c/proofs/result.json'
        Write-ContinuationJson $requestPath @{name='syntaxcheck_file';arguments=@{file_path=$Fixture.module;lines=''}}
        Write-ContinuationJson $resultPath @{isError=$false;structuredContent=@{
            diagnostics=@();summary=@{total=0;returned=0;truncated=$false};
            filters=@{line_filter_applied=$false;severity_filter_applied=$false;suppression_applied=$false};
            provenance=@{tool='syntaxcheck_file';analyzer_version='0.2.81';file_metrics_scope='whole_file'};
            request_rewrite=@{applied=$false;requested=@{file_path=$Fixture.module};used=@{file_path=$Fixture.module}}
        }}
        $receipt=@{schemaVersion=1;kind='itl-mcp-source-validation';taskPath='quick-fix';projectRoot=$Fixture.root;
            sourceRoot=$Fixture.sourceRoot;sourceFingerprint=$Fixture.current.fingerprint;infoBaseKind='file';infoBasePath=$Fixture.infoBase;
            entries=@(@{relativePath=$Fixture.module;inputSha256=(Get-ItlPlatformEvidenceHash (Join-Path $Fixture.sourceRoot $Fixture.module));
                checker=@{server='fixture-recorded-schema-checker';capability='syntaxcheck_file';versionOrId='0.2.81'};
                request=@{path='request.json';sha256=(Get-ItlPlatformEvidenceHash $requestPath)};
                result=@{path='result.json';sha256=(Get-ItlPlatformEvidenceHash $resultPath)}})}
        Write-ContinuationJson $Fixture.evidence $receipt
        (Test-ItlPlatformSourceCoverage -EvidencePath $Fixture.evidence -SourceRoot $Fixture.sourceRoot -SourceFingerprint $Fixture.current.fingerprint `
            -Files @($Fixture.module) -ProjectRoot $Fixture.root -InfoBaseKind file -InfoBasePath $Fixture.infoBase).covered | Should -BeTrue
    }
}

Describe 'Checked load proof continuation and current MCP exemption' {
    BeforeEach {
        $script:continuationFixture=New-ContinuationProject
        $f=$script:continuationFixture
        $global:LASTEXITCODE=0
        . $helperPath -ProjectRoot $f.root -DevBranchName 'continuation' -Action help *> $null
        $script:OneCNativeOperationJournal=$null
        $script:VerificationEvidencePath=''
        $f | Add-Member -NotePropertyName previous -NotePropertyValue (Get-ConfigSourceFingerprint -ExportPath 'src/cf')
        [IO.Directory]::CreateDirectory($f.infoBase) | Out-Null
        [IO.File]::WriteAllBytes($f.database,[byte[]](1,2,3,4))
        $before=@{safeDevBranchName='continuation';devBranchName='continuation';infoBaseKind='file';devBranchInfoBasePath=$f.infoBase;
            worktreePath=$f.root;configLoadStatus='passed';lastConfigDesignerFingerprint=$f.previous.fingerprint;
            lastConfigDesignerTreeObjectId=$f.previous.treeObjectId;lastConfigDesignerLoadedAt='2026-10-04T00:00:00Z';
            loadReason='source-load';lastGate6Evidence=@{id='previous-proof'};customSetting='сохранить';enterpriseNormalizationStatus='passed'}
        $statePath=Save-DevBranchState -SafeDevBranchName 'continuation' -State $before
        $f | Add-Member -NotePropertyName statePath -NotePropertyValue $statePath
        Write-ContinuationSource $f.root $f.module "&НаСервере`r`nФункция Значение() Экспорт`r`n    Возврат 2;`r`nКонецФункции"
        Invoke-ContinuationGit $f.root @('add','--all') | Out-Null
        Invoke-ContinuationGit $f.root @('commit','--quiet','-m','candidate body change') | Out-Null
        $f | Add-Member -NotePropertyName current -NotePropertyValue (Get-ConfigSourceFingerprint -ExportPath 'src/cf')
        $f | Add-Member -NotePropertyName cursorBytes -NotePropertyValue ([IO.File]::ReadAllBytes((Join-Path $f.sourceRoot 'ConfigDumpInfo.xml')))
        # This unit qualifies the load/rollback owner, not controlled-fork
        # validator installation. Git/source/receipt/state admission stays real.
        Mock Assert-OneCConfigurationSourceIntegrity {} -ParameterFilter {$ExportPath -eq $script:continuationFixture.sourceRoot}
        function Get-PlatformPath { 'fixture-1cv8.exe' }
        function Invoke-Designer {
            param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,$RestorationDuty,[string[]]$DesignerArgs)
            $f=$script:continuationFixture
            $f.calls.Add([pscustomobject]@{arguments=@($DesignerArgs);kind=$InfoBaseKind;target=$InfoBasePath})
            $script:LastNativeProcessStarted=$true
            $script:LastLogPath=Join-Path $f.root ('logs/1c/native-'+$f.calls.Count+'.log')
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:LastLogPath)) | Out-Null
            $code=0;$log='Ошибок: 0; предупреждений: 0'
            switch($DesignerArgs[0]) {
                '/DumpIB' { [IO.File]::Copy($f.database,$DesignerArgs[1],$true) }
                '/LoadConfigFromFiles' {
                    [IO.File]::WriteAllBytes($f.database,[byte[]](7,8,9))
                    Write-ContinuationSource $f.root 'ConfigDumpInfo.xml' '<ConfigDumpInfo>editable cursor</ConfigDumpInfo>'
                    switch($f.fault){
                        'source changed' { [IO.File]::AppendAllText((Join-Path $f.sourceRoot $f.module),"`r`n// позднее изменение",[Text.UTF8Encoding]::new($false)) }
                        'receipt changed' { [IO.File]::AppendAllText($f.evidence,"`r`n",[Text.UTF8Encoding]::new($false)) }
                        'result changed' { [IO.File]::WriteAllText((Join-Path $f.root '.agent-1c/proofs/result.json'),'{"isError":true}',[Text.UTF8Encoding]::new($false)) }
                        'owner drift' { Update-DevBranchState -State (Read-DevBranchStateFile $f.statePath) -Updates @{devBranchInfoBasePath=(Join-Path $f.root 'Другая база');customSetting='поздний выбор'} }
                    }
                }
                '/CheckModules' {
                    if($f.fault -in @('module failure','restore uncertain','borrowed failure','owner drift')){$code=101;$log='Ошибка компиляции текущего модуля.'}
                }
                '/CheckConfig' {$code=101;$log='ОбщийМодуль.Прежний.Модуль Возможно ошибочный метод: "ПрежнийМетод"'}
                '/UpdateDBCfg' {$f.applied=$true}
                '/RestoreIB' {
                    if($f.fault -eq 'restore uncertain'){throw 'fixture exact restore failed'}
                    [IO.File]::Copy($DesignerArgs[1],$f.database,$true)
                }
            }
            [IO.File]::WriteAllText($script:LastLogPath,$log,[Text.UTF8Encoding]::new($false))
            $index=[Array]::IndexOf($DesignerArgs,'/DumpResult')
            if($index -ge 0){[IO.File]::WriteAllText($DesignerArgs[$index+1],[string]$code,[Text.UTF8Encoding]::new($false))}
            if($code){
                $failure=[InvalidOperationException]::new('Original native '+$DesignerArgs[0]+' failed with '+$code)
                $failure.Data['ItlDesignerBatchResult']=[pscustomobject]@{exitCode=$code;logPath=$script:LastLogPath;operation=$DesignerArgs[0];
                    infoBaseKind=$InfoBaseKind;infoBasePath=$InfoBasePath;ownedProcessesReleased=$true}
                throw $failure
            }
            # Preserve the observed legacy combined-load behavior in RED.
            if(@($DesignerArgs|Where-Object{$_ -ceq '/UpdateDBCfg'}).Count -eq 1){$f.applied=$true}
        }
    }

    AfterEach {$script:OneCNativeOperationJournal=$null;$script:VerificationEvidencePath=''}

    It 'applies an actually admitted current MCP proof through snapshot editable load revalidation and one database boundary' {
        $f=$script:continuationFixture
        Save-ContinuationCoverage $f
        $script:VerificationEvidencePath=$f.evidence
        $result=Load-ConfigFromFiles -InfoBasePath $f.infoBase -InfoBaseKind file -State (Read-DevBranchStateFile $f.statePath) -ExportPath 'src/cf'
        $operations=@($f.calls|ForEach-Object{$_.arguments[0]})
        $operations | Should -Be @('/DumpIB','/LoadConfigFromFiles','/UpdateDBCfg')
        @($f.calls|Where-Object{$_.arguments[0] -eq '/LoadConfigFromFiles'})[0].arguments | Should -Not -Contain '/UpdateDBCfg'
        $f.applied | Should -BeTrue
        $result.loaded | Should -BeTrue
        $state=Read-DevBranchStateFile $f.statePath
        $state.lastConfigDesignerFingerprint | Should -BeExactly $f.current.fingerprint
        $state.configLoadStatus | Should -BeExactly 'passed'
        $state.customSetting | Should -BeExactly 'сохранить'
    }

    It 'refuses changed current MCP inputs after editable load and restores the exact original target for <Fault>' -ForEach @(
        @{Fault='source changed'},@{Fault='receipt changed'},@{Fault='result changed'}
    ) {
        $f=$script:continuationFixture
        Save-ContinuationCoverage $f
        $script:VerificationEvidencePath=$f.evidence
        $f.fault=$Fault
        {Load-ConfigFromFiles -InfoBasePath $f.infoBase -InfoBaseKind file -State (Read-DevBranchStateFile $f.statePath) -ExportPath 'src/cf'} | Should -Throw
        $f.applied | Should -BeFalse
        @($f.calls|ForEach-Object{$_.arguments[0]}) | Should -Contain '/RestoreIB'
        @($f.calls|ForEach-Object{$_.arguments[0]}) | Should -Not -Contain '/UpdateDBCfg'
        [IO.File]::ReadAllBytes($f.database) | Should -Be ([byte[]](1,2,3,4))
        [IO.File]::ReadAllBytes((Join-Path $f.sourceRoot 'ConfigDumpInfo.xml')) | Should -Be $f.cursorBytes
        $state=Read-DevBranchStateFile $f.statePath
        $state.lastConfigDesignerFingerprint | Should -BeExactly $f.previous.fingerprint
        $state.lastConfigDesignerTreeObjectId | Should -BeExactly $f.previous.treeObjectId
        $state.lastGate6Evidence.id | Should -BeExactly 'previous-proof'
        $state.customSetting | Should -BeExactly 'сохранить'
        if($Fault -eq 'source changed'){[IO.File]::ReadAllText((Join-Path $f.sourceRoot $f.module)) | Should -Match 'позднее изменение'}
    }

    It 'retains previous loaded proof only after exact checked rollback and completes the same owner operation after repair' {
        $f=$script:continuationFixture
        $f.fault='module failure'
        {Load-ConfigFromFiles -InfoBasePath $f.infoBase -InfoBaseKind file -State (Read-DevBranchStateFile $f.statePath) -ExportPath 'src/cf'} | Should -Throw
        [IO.File]::ReadAllBytes($f.database) | Should -Be ([byte[]](1,2,3,4))
        $restored=Read-DevBranchStateFile $f.statePath
        $restored.lastConfigDesignerFingerprint | Should -BeExactly $f.previous.fingerprint
        $restored.lastConfigDesignerTreeObjectId | Should -BeExactly $f.previous.treeObjectId
        $restored.lastConfigDesignerLoadedAt | Should -BeExactly '2026-10-04T00:00:00Z'
        $restored.configLoadStatus | Should -BeExactly 'passed'
        $restored.lastGate6Evidence.id | Should -BeExactly 'previous-proof'
        $f.applied | Should -BeFalse
        $f.fault=''
        $f.calls.Clear()
        $result=Load-ConfigFromFiles -InfoBasePath $f.infoBase -InfoBaseKind file -State $restored -ExportPath 'src/cf'
        $f.applied | Should -BeTrue
        $result.loaded | Should -BeTrue
        $configuration=@($result.gate6Evidence.steps|Where-Object step -eq 'configuration')[0]
        $configuration.nativePassed | Should -BeFalse
        $configuration.exitCode | Should -Be 101
        $configuration.assessment.status | Should -BeExactly 'accepted-with-preexisting-findings'
        $configuration.assessment.cleanPassed | Should -BeFalse
        (Read-DevBranchStateFile $f.statePath).lastConfigDesignerFingerprint | Should -BeExactly $f.current.fingerprint
    }

    It 'does not restore previous proof from uncertain borrowed or changed ownership for <Fault>' -ForEach @(
        @{Fault='restore uncertain'},@{Fault='borrowed failure'},@{Fault='owner drift'}
    ) {
        $f=$script:continuationFixture
        $f.fault=$Fault
        if($Fault -eq 'borrowed failure'){
            $script:OneCNativeOperationJournal=New-OneCNativeOperationJournal
            $dt=Join-Path $f.root '.agent-1c/enclosing.dt'
            [IO.File]::Copy($f.database,$dt,$true)
            $duty=Register-OneCDatabaseRestorationDuty -State ([pscustomobject]@{infoBaseKind='file';devBranchInfoBasePath=$f.infoBase}) -SnapshotPath $dt -Policy always
        }
        {Load-ConfigFromFiles -InfoBasePath $f.infoBase -InfoBaseKind file -State (Read-DevBranchStateFile $f.statePath) -ExportPath 'src/cf'} | Should -Throw
        $state=Read-DevBranchStateFile $f.statePath
        $state.lastConfigDesignerFingerprint | Should -BeNullOrEmpty
        $state.configLoadStatus | Should -BeExactly 'pending'
        $f.applied | Should -BeFalse
        if($Fault -eq 'borrowed failure'){
            @($f.calls|ForEach-Object{$_.arguments[0]}) | Should -Not -Contain '/RestoreIB'
            $duty.payload.status | Should -BeExactly 'pending'
        }
        if($Fault -eq 'owner drift'){
            $state.devBranchInfoBasePath | Should -BeExactly (Join-Path $f.root 'Другая база')
            $state.customSetting | Should -BeExactly 'поздний выбор'
        }
    }

    It 'does not restore old loaded proof or replay rollback when database apply loses its completion acknowledgement' {
        $f=$script:continuationFixture
        Save-ContinuationCoverage $f
        $script:VerificationEvidencePath=$f.evidence
        Mock Complete-OneCDatabaseRestorationDuty {throw 'fixture committed acknowledgement lost'} -ParameterFilter {$Resolution -eq 'committed'}
        {Load-ConfigFromFiles -InfoBasePath $f.infoBase -InfoBaseKind file -State (Read-DevBranchStateFile $f.statePath) -ExportPath 'src/cf'} | Should -Throw '*acknowledgement lost*'
        $f.applied | Should -BeTrue
        @($f.calls|ForEach-Object{$_.arguments[0]}) | Should -Not -Contain '/RestoreIB'
        $state=Read-DevBranchStateFile $f.statePath
        $state.lastConfigDesignerFingerprint | Should -BeNullOrEmpty
        $state.configLoadStatus | Should -BeExactly 'pending'
    }
}
