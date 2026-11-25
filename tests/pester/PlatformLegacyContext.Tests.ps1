BeforeAll {
    $repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    function Import-LegacyContextOwnerFunctions {
        param([string]$Path,[string[]]$Names)
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
        if (@($errors).Count) { throw 'Owner module parse failed' }
        foreach ($name in $Names) {
            $definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
            if ($definitions.Count -ne 1) { throw ('Owner function unavailable: '+$name) }
            . ([scriptblock]::Create($definitions[0].Extent.Text))
        }
    }
    $lib=Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib'
    . Import-LegacyContextOwnerFunctions (Join-Path $lib 'agent-1c.core.ps1') @('Get-Utf8Encoding','Resolve-Agent1cFullPath','ConvertTo-NativeCommandLineArgument','Join-NativeCommandLineArguments')
    . Import-LegacyContextOwnerFunctions (Join-Path $lib 'agent-1c.runtime-values.ps1') @('Get-StateValue','Test-ItlOnDemandInfoBaseMatch')
    . Import-LegacyContextOwnerFunctions (Join-Path $lib 'agent-1c.vanessa.ps1') @('Invoke-ItlNativeProcessCapture')
    . Import-LegacyContextOwnerFunctions (Join-Path $lib 'agent-1c.lifecycle.ps1') @('Get-GitPathListAt','Get-GitPathList','Get-GitBlobBytesBatch','Get-ConfigRepositoryMetadataCollectionLabel','Get-PlatformGate6MetadataOwner','Get-DotEnvPolicyTextHash','Get-PlatformGate6OwnerHashes','New-PlatformGate6LegacyContext')
    . (Join-Path $lib 'agent-1c.platform-impact.ps1')
    function Invoke-LegacyContextGit {
        param([string]$Root,[string[]]$Arguments)
        $result=Invoke-ItlNativeProcessCapture -FilePath 'git' -WorkingDirectory $Root -Arguments (@('-C',$Root,'-c','core.quotepath=false')+@($Arguments))
        if ($result.exitCode -ne 0) { throw ('Fixture Git failed: '+$result.stderr) }
        return $result.stdout.Trim()
    }
    function Set-LegacyContextFile {
        param([string]$Root,[string]$Path,[string]$Text)
        $full=Join-Path $Root ('src/cf/'+$Path)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
        [IO.File]::WriteAllText($full,($Text -replace '\r?\n',"`r`n"),[Text.UTF8Encoding]::new($true))
    }
    function Get-LegacyContextFixtureFingerprint {
        param([string]$Root,[string]$Tree)
        # The recorded source fingerprint uses native NUL tree records, not
        # object count, display paths or a fabricated passed-context projection.
        $entries=@(Get-GitPathListAt -Root $Root -Arguments @('ls-tree','-r','-z',$Tree) | Where-Object {
            $separator=([string]$_).IndexOf("`t")
            $separator -ge 0 -and [IO.Path]::GetFileName(([string]$_).Substring($separator+1)) -ine 'ConfigDumpInfo.xml'
        })
        return 'v2|git-tree-sha256|'+(Get-DotEnvPolicyTextHash -Text ([string]::Join([char]0,[string[]]$entries)))
    }
    function New-LegacyContextFixture {
        param([string]$Change='body')
        $root=Join-Path $TestDrive ('Контекст прежней базы '+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        Invoke-LegacyContextGit $root @('init','--quiet') | Out-Null
        Invoke-LegacyContextGit $root @('config','user.name','fixture') | Out-Null
        Invoke-LegacyContextGit $root @('config','user.email','fixture@example.invalid') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.gitattributes'),"* -text`r`n",[Text.UTF8Encoding]::new($false))
        $xml='<MetaDataObject><Configuration uuid="11111111-1111-1111-1111-111111111111"><Properties><Name>Тест</Name><Comment>before</Comment></Properties><ChildObjects><CommonModule>Изменённый</CommonModule><CommonModule>Прежний</CommonModule></ChildObjects></Configuration></MetaDataObject>'
        Set-LegacyContextFile $root 'Configuration.xml' $xml
        Set-LegacyContextFile $root 'ConfigDumpInfo.xml' '<ConfigDumpInfo>first dump</ConfigDumpInfo>'
        foreach ($module in @(@{name='Изменённый';uuid='22222222-2222-2222-2222-222222222222'},@{name='Прежний';uuid='33333333-3333-3333-3333-333333333333'})) {
            Set-LegacyContextFile $root ('CommonModules/'+$module.name+'.xml') ('<MetaDataObject><CommonModule uuid="'+$module.uuid+'"><Properties><Name>'+$module.name+'</Name><Server>true</Server></Properties></CommonModule></MetaDataObject>')
            Set-LegacyContextFile $root ('CommonModules/'+$module.name+'/Ext/Module.bsl') "&НаСервере`r`nФункция Значение() Экспорт`r`n    Возврат 1;`r`nКонецФункции"
        }
        Invoke-LegacyContextGit $root @('add','--all') | Out-Null
        Invoke-LegacyContextGit $root @('commit','--quiet','-m','original source') | Out-Null
        $beforeTree=Invoke-LegacyContextGit $root @('rev-parse','HEAD:src/cf')
        $beforeFingerprint=Get-LegacyContextFixtureFingerprint $root $beforeTree
        switch ($Change) {
            'body' { Set-LegacyContextFile $root 'CommonModules/Изменённый/Ext/Module.bsl' "&НаСервере`r`nФункция Значение() Экспорт`r`n    Возврат 2;`r`nКонецФункции" }
            'comment' { Set-LegacyContextFile $root 'Configuration.xml' $xml.Replace('<Comment>before</Comment>','<Comment>комментарий</Comment>') }
            'descriptor' { Set-LegacyContextFile $root 'CommonModules/Изменённый.xml' '<MetaDataObject><CommonModule uuid="22222222-2222-2222-2222-222222222222"><Properties><Name>Изменённый</Name><Server>false</Server></Properties></CommonModule></MetaDataObject>' }
            'root property' { Set-LegacyContextFile $root 'Configuration.xml' $xml.Replace('<Comment>before</Comment>','<Comment>before</Comment><DefaultLanguage>Русский</DefaultLanguage>') }
            'dump only' { Set-LegacyContextFile $root 'ConfigDumpInfo.xml' '<ConfigDumpInfo>second dump</ConfigDumpInfo>' }
        }
        Invoke-LegacyContextGit $root @('add','--all') | Out-Null
        Invoke-LegacyContextGit $root @('commit','--quiet','-m','candidate source') | Out-Null
        $afterTree=Invoke-LegacyContextGit $root @('rev-parse','HEAD:src/cf')
        $infoBase=Join-Path $root 'База 1С'
        $state=[pscustomobject]@{lastConfigDesignerFingerprint=$beforeFingerprint;lastConfigDesignerTreeObjectId=$beforeTree;
            configLoadStatus='passed';infoBaseKind='file';devBranchInfoBasePath=$infoBase;loadReason='branch-copy-seed';
            branchSeedConfigurationFingerprint=$beforeFingerprint;branchSeedSourceKey='source-database';branchSeedSyncId='original-sync';lastConfigDesignerLoadedAt=''}
        return [pscustomobject]@{root=$root;state=$state;infoBase=$infoBase;beforeTree=$beforeTree;afterTree=$afterTree;
            beforeFingerprint=$beforeFingerprint;afterFingerprint=(Get-LegacyContextFixtureFingerprint $root $afterTree)}
    }
    function Invoke-LegacyContextFixture {
        param([object]$Fixture,[string]$InfoBasePath=$Fixture.infoBase,[switch]$IncludeAssessment)
        $oldRoot=Get-Variable -Name ProjectRoot -Scope Script -ErrorAction SilentlyContinue
        $oldValue=if($oldRoot){$oldRoot.Value}else{$null}
        $head=Invoke-LegacyContextGit $Fixture.root @('rev-parse','HEAD')
        $script:ProjectRoot=$Fixture.root
        try {
            $assessment=$null
            $context=New-PlatformGate6LegacyContext -State $Fixture.state -ChangeSet ([pscustomobject]@{
                previousTreeObjectId=$Fixture.beforeTree;currentTreeObjectId=$Fixture.afterTree}) `
                -SourceFingerprint $Fixture.afterFingerprint -InfoBaseKind file -InfoBasePath $InfoBasePath -Assessment ([ref]$assessment)
            (Invoke-LegacyContextGit $Fixture.root @('rev-parse','HEAD')) | Should -BeExactly $head
            @(Get-GitPathListAt -Root $Fixture.root -Arguments @('status','--porcelain=v1','-z','--untracked-files=all')) | Should -HaveCount 0
            if ($IncludeAssessment) { return [pscustomobject]@{context=$context;assessment=$assessment} }
            return $context
        } finally {
            if($oldRoot){$script:ProjectRoot=$oldValue}else{Remove-Variable -Name ProjectRoot -Scope Script -ErrorAction SilentlyContinue}
        }
    }
}

Describe 'Operation-local previous source binding for platform legacy context' {
    It 'binds a restored branch seed to exact previous tree and limits unchanged hash proof to outside owners' {
        $fixture=New-LegacyContextFixture
        $raw=[IO.File]::ReadAllBytes((Join-Path $fixture.root 'src/cf/CommonModules/Изменённый/Ext/Module.bsl'))
        $raw[0..2] | Should -Be @(239,187,191)
        [regex]::Matches([Text.UTF8Encoding]::new($false,$true).GetString($raw),'(?<!\r)\n').Count | Should -Be 0
        $context=Invoke-LegacyContextFixture $fixture
        $context | Should -Not -BeNullOrEmpty
        $context.binding.previousFingerprint | Should -BeExactly $fixture.beforeFingerprint
        $context.binding.previousTree | Should -BeExactly $fixture.beforeTree
        $context.binding.currentTree | Should -BeExactly $fixture.afterTree
        $context.binding.seedSourceKey | Should -BeExactly 'source-database'
        $context.binding.seedSyncId | Should -BeExactly 'original-sync'
        $context.sourceFingerprint | Should -BeExactly $fixture.afterFingerprint
        $context.changedOwners | Should -Be @('ОбщийМодуль.Изменённый')
        $context.sourceImpact.proven | Should -BeTrue
        @($context.unchangedOwnersProof | ForEach-Object owner) | Should -Be @('ОбщийМодуль.Прежний')
        $proof=$context.unchangedOwnersProof[0]
        $proof.beforeSha256 | Should -Match '^[a-f0-9]{64}$'
        $proof.afterSha256 | Should -BeExactly $proof.beforeSha256
    }

    It 'retains normal previously loaded target binding without requiring branch seed metadata' {
        $fixture=New-LegacyContextFixture
        $fixture.state.loadReason='source-load'
        $fixture.state.lastConfigDesignerLoadedAt='2026-10-04T00:00:00Z'
        $fixture.state.branchSeedConfigurationFingerprint=''
        $fixture.state.branchSeedSourceKey=''
        $fixture.state.branchSeedSyncId=''
        $context=Invoke-LegacyContextFixture $fixture
        $context | Should -Not -BeNullOrEmpty
        $context.binding.PSObject.Properties.Name | Should -Not -Contain 'seedSourceKey'
    }

    It 'uses the fingerprint exclusion without granting changed metadata for <Change>' -ForEach @(
        @{Change='comment'},@{Change='dump only'}
    ) {
        $fixture=New-LegacyContextFixture -Change $Change
        $context=Invoke-LegacyContextFixture $fixture
        $context | Should -Not -BeNullOrEmpty
        $context.changedOwners | Should -HaveCount 0
        @($context.unchangedOwnersProof | ForEach-Object owner | Sort-Object) | Should -Be @('ОбщийМодуль.Изменённый','ОбщийМодуль.Прежний')
        if($Change -eq 'dump only'){$fixture.afterFingerprint | Should -BeExactly $fixture.beforeFingerprint}
        else{$fixture.afterFingerprint | Should -Not -BeExactly $fixture.beforeFingerprint}
    }

    It 'rejects unrelated fingerprints and incomplete target proof for <Case>' -ForEach @(
        @{Case='unrelated fingerprint'},@{Case='different previous tree'},@{Case='seed mismatch'},@{Case='seed source absent'},
        @{Case='seed sync absent'},@{Case='normal loaded time absent'},@{Case='pending load'},@{Case='different database kind'},
        @{Case='moved target'},@{Case='missing current tree'}
    ) {
        $fixture=New-LegacyContextFixture
        $path=$fixture.infoBase
        switch ($Case) {
            'unrelated fingerprint' { $fixture.state.lastConfigDesignerFingerprint='v2|git-tree-sha256|'+('a'*64); $fixture.state.branchSeedConfigurationFingerprint=$fixture.state.lastConfigDesignerFingerprint }
            'different previous tree' { $fixture.beforeTree=$fixture.afterTree }
            'seed mismatch' { $fixture.state.branchSeedConfigurationFingerprint=$fixture.afterFingerprint }
            'seed source absent' { $fixture.state.branchSeedSourceKey='' }
            'seed sync absent' { $fixture.state.branchSeedSyncId='' }
            'normal loaded time absent' { $fixture.state.loadReason='source-load' }
            'pending load' { $fixture.state.configLoadStatus='pending' }
            'different database kind' { $fixture.state.infoBaseKind='server' }
            'moved target' { $path=Join-Path $fixture.root 'Другая база' }
            'missing current tree' { $fixture.afterTree='0'*40 }
        }
        $result=Invoke-LegacyContextFixture $fixture -InfoBasePath $path -IncludeAssessment
        $result.context | Should -BeNullOrEmpty
        $result.assessment.eligible | Should -BeFalse
        $expected=@{
            'unrelated fingerprint'='PREVIOUS_TREE_FINGERPRINT_MISMATCH';'different previous tree'='PREVIOUS_TREE_FINGERPRINT_MISMATCH';
            'seed mismatch'='SEED_FINGERPRINT_MISMATCH';'seed source absent'='SEED_SOURCE_KEY_MISSING';'seed sync absent'='SEED_SYNC_ID_MISSING';
            'normal loaded time absent'='PREVIOUS_LOAD_TIMESTAMP_MISSING';'pending load'='PREVIOUS_LOAD_NOT_PASSED';
            'different database kind'='INFOBASE_KIND_MISMATCH';'moved target'='INFOBASE_TARGET_MISMATCH';'missing current tree'='SOURCE_IMPACT_EVALUATION_FAILED'
        }
        # A syntactically valid but absent current tree is rejected by the
        # existing impact owner, whose exact reason must survive unchanged.
        if($Case -eq 'missing current tree') {
            $result.assessment.reason | Should -BeExactly $result.assessment.sourceImpact.reason
            $result.assessment.sourceImpact.proven | Should -BeFalse
        } else { $result.assessment.reason | Should -BeExactly $expected[$Case] }
    }

    It 'keeps unknown metadata impact on the strict path for <Change>' -ForEach @(
        @{Change='descriptor'},@{Change='root property'}
    ) {
        $fixture=New-LegacyContextFixture -Change $Change
        $dependent=(Get-FileHash -LiteralPath (Join-Path $fixture.root 'src/cf/CommonModules/Прежний/Ext/Module.bsl')).Hash
        $result=Invoke-LegacyContextFixture $fixture -IncludeAssessment
        $result.context | Should -BeNullOrEmpty
        $result.assessment.eligible | Should -BeFalse
        $result.assessment.reason | Should -BeExactly $result.assessment.sourceImpact.reason
        $result.assessment.sourceImpact.impactOwners | Should -Contain 'ОбщийМодуль.Прежний'
        if($Change -eq 'descriptor') {
            $result.assessment.sourceImpact.changedOwners | Should -Contain 'ОбщийМодуль.Изменённый'
            $result.assessment.reason | Should -BeExactly 'EXISTING_DESCRIPTOR_OR_PAYLOAD_CHANGED:CommonModules/Изменённый.xml'
            $result.assessment.path | Should -BeExactly 'CommonModules/Изменённый.xml'
        }
        (Get-FileHash -LiteralPath (Join-Path $fixture.root 'src/cf/CommonModules/Прежний/Ext/Module.bsl')).Hash | Should -BeExactly $dependent
    }

    It 'retains a failed owner read without granting a legacy context' {
        $fixture=New-LegacyContextFixture
        Mock Get-GitPathList { throw 'fixture previous tree read failed' }
        $result=Invoke-LegacyContextFixture $fixture -IncludeAssessment
        $result.context | Should -BeNullOrEmpty
        $result.assessment.reason | Should -BeExactly 'PREVIOUS_TREE_READ_FAILED'
        $result.assessment.detail | Should -BeExactly 'fixture previous tree read failed'
    }

    It 'preserves a symbol refusal without presenting the symbol as a file path' {
        $fixture=New-LegacyContextFixture
        Mock Test-ItlPlatformLegacySourceImpact {
            [pscustomobject]@{proven=$false;reason='PREEXISTING_REFERENCE_TO_ADDED_NAME:Имя';changedOwners=@();impactOwners=@()}
        }
        $result=Invoke-LegacyContextFixture $fixture -IncludeAssessment
        $result.context | Should -BeNullOrEmpty
        $result.assessment.reason | Should -BeExactly 'PREEXISTING_REFERENCE_TO_ADDED_NAME:Имя'
        $result.assessment.path | Should -BeNullOrEmpty
    }
}
