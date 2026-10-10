BeforeAll {
    $repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    function Import-ImpactOwnerFunctions {
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
    . Import-ImpactOwnerFunctions (Join-Path $lib 'agent-1c.core.ps1') @('ConvertTo-NativeCommandLineArgument','Join-NativeCommandLineArguments')
    . Import-ImpactOwnerFunctions (Join-Path $lib 'agent-1c.vanessa.ps1') @('Invoke-ItlNativeProcessCapture')
    . Import-ImpactOwnerFunctions (Join-Path $lib 'agent-1c.lifecycle.ps1') @('Get-GitPathListAt','Get-GitBlobBytesBatch','Get-ConfigRepositoryMetadataCollectionLabel','Get-PlatformGate6MetadataOwner')
    . (Join-Path $lib 'agent-1c.platform-impact.ps1')
    function Invoke-ImpactGit {
        param([string]$Root,[string[]]$Arguments)
        $result=Invoke-ItlNativeProcessCapture -FilePath 'git' -WorkingDirectory $Root -Arguments (@('-C',$Root,'-c','core.quotepath=false')+@($Arguments))
        if ($result.exitCode -ne 0) { throw ('Fixture Git failed: '+$result.stderr) }
        return $result.stdout.Trim()
    }
    function Set-ImpactFixtureFile {
        param([string]$Root,[string]$Path,[string]$Text)
        $full=Join-Path $Root ('src/cf/'+$Path)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
        [IO.File]::WriteAllText($full,($Text -replace '\r?\n',"`r`n"),[Text.UTF8Encoding]::new($true))
    }
    function Get-ImpactFixtureRootXml {
        param([string]$Comment='before',[string]$Added='', [string]$Extra='')
        return '<MetaDataObject><Configuration uuid="11111111-1111-1111-1111-111111111111"><Properties><Name>Тест</Name><Comment>'+ $Comment +'</Comment>'+ $Extra +'</Properties><ChildObjects><CommonModule>Старый</CommonModule>'+ $Added +'</ChildObjects></Configuration></MetaDataObject>'
    }
    function New-ImpactFixture {
        param([string]$BeforeBody='')
        $root=Join-Path $TestDrive ('Исходники 1С с пробелом '+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        Invoke-ImpactGit $root @('init','--quiet') | Out-Null
        Invoke-ImpactGit $root @('config','user.name','fixture') | Out-Null
        Invoke-ImpactGit $root @('config','user.email','fixture@example.invalid') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.gitattributes'),"* -text`r`n",[Text.UTF8Encoding]::new($false))
        Set-ImpactFixtureFile $root 'Configuration.xml' (Get-ImpactFixtureRootXml)
        Set-ImpactFixtureFile $root 'CommonModules/Старый.xml' '<MetaDataObject><CommonModule uuid="22222222-2222-2222-2222-222222222222"><Properties><Name>Старый</Name><Server>true</Server></Properties></CommonModule></MetaDataObject>'
        if (-not $BeforeBody) { $BeforeBody="&НаСервере`r`nФункция Получить(Знач Параметр = 1) Экспорт`r`n    Возврат Параметр + 1; // тело`r`nКонецФункции" }
        Set-ImpactFixtureFile $root 'CommonModules/Старый/Ext/Module.bsl' $BeforeBody
        Invoke-ImpactGit $root @('add','--all') | Out-Null
        Invoke-ImpactGit $root @('commit','--quiet','-m','original source') | Out-Null
        return [pscustomobject]@{root=$root;beforeTree=(Invoke-ImpactGit $root @('rev-parse','HEAD:src/cf'));beforeBody=$BeforeBody}
    }
    function Complete-ImpactFixture {
        param([object]$Fixture)
        Invoke-ImpactGit $Fixture.root @('add','--all') | Out-Null
        Invoke-ImpactGit $Fixture.root @('commit','--quiet','--allow-empty','-m','candidate source') | Out-Null
        $afterTree=Invoke-ImpactGit $Fixture.root @('rev-parse','HEAD:src/cf')
        $head=Invoke-ImpactGit $Fixture.root @('rev-parse','HEAD')
        $result=Test-ItlPlatformLegacySourceImpact -ProjectRoot $Fixture.root -PreviousTreeObjectId $Fixture.beforeTree -CurrentTreeObjectId $afterTree
        (Invoke-ImpactGit $Fixture.root @('rev-parse','HEAD')) | Should -BeExactly $head
        @(Get-GitPathListAt -Root $Fixture.root -Arguments @('status','--porcelain=v1','-z','--untracked-files=all')) | Should -HaveCount 0
        return $result
    }
    function Add-ImpactNewObject {
        param([object]$Fixture,[string]$Uuid='33333333-3333-3333-3333-333333333333',[string]$Properties='',[string]$Body='')
        Set-ImpactFixtureFile $Fixture.root 'Configuration.xml' (Get-ImpactFixtureRootXml -Comment 'new comment' -Added '<DataProcessor>НоваяПроверка</DataProcessor>')
        Set-ImpactFixtureFile $Fixture.root 'DataProcessors/НоваяПроверка.xml' ('<MetaDataObject><DataProcessor uuid="'+$Uuid+'"><Properties><Name>НоваяПроверка</Name>'+ $Properties +'</Properties><ChildObjects><Form>Форма</Form></ChildObjects></DataProcessor></MetaDataObject>')
        Set-ImpactFixtureFile $Fixture.root 'DataProcessors/НоваяПроверка/Forms/Форма.xml' '<MetaDataObject><Form uuid="44444444-4444-4444-4444-444444444444"><Properties><Name>Форма</Name></Properties></Form></MetaDataObject>'
        Set-ImpactFixtureFile $Fixture.root 'DataProcessors/НоваяПроверка/Forms/Форма/Ext/Form.xml' '<Form><Events><Event name="OnOpen">ПриОткрытии</Event></Events></Form>'
        if (-not $Body) { $Body="Процедура ЗапуститьНовуюПроверку() Экспорт`r`n    Сообщить(""готово // точные строки"");`r`nКонецПроцедуры" }
        Set-ImpactFixtureFile $Fixture.root 'DataProcessors/НоваяПроверка/Ext/ObjectModule.bsl' $Body
    }
}

Describe 'Conservative operation-local legacy source impact' {
    It 'proves body-only BSL changes with exact declarations context and availability' {
        $fixture=New-ImpactFixture
        $path=Join-Path $fixture.root 'src/cf/CommonModules/Старый/Ext/Module.bsl'
        Set-ImpactFixtureFile $fixture.root 'CommonModules/Старый/Ext/Module.bsl' $fixture.beforeBody.Replace('Параметр + 1','Параметр + 2')
        $raw=[IO.File]::ReadAllBytes($path)
        $raw[0..2] | Should -Be @(239,187,191)
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($raw)
        [regex]::Matches($text,'(?<!\r)\n').Count | Should -Be 0
        $sha=(Get-FileHash -LiteralPath $path).Hash
        $result=Complete-ImpactFixture $fixture
        $result.proven | Should -BeTrue
        $result.changedOwners | Should -Be @('ОбщийМодуль.Старый')
        $result.impactOwners | Should -Be @('ОбщийМодуль.Старый')
        (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $sha
    }

    It 'allows only the root comment to change outside object subtrees' {
        $fixture=New-ImpactFixture
        Set-ImpactFixtureFile $fixture.root 'Configuration.xml' (Get-ImpactFixtureRootXml -Comment 'комментарий без API')
        $result=Complete-ImpactFixture $fixture
        $result.proven | Should -BeTrue
        $result.changedOwners | Should -HaveCount 0
        $result.impactOwners | Should -HaveCount 0
    }

    It 'proves a self-contained new object and additive root entries without existing-object writes' {
        $fixture=New-ImpactFixture
        Add-ImpactNewObject $fixture
        $result=Complete-ImpactFixture $fixture
        $result.proven | Should -BeTrue
        $result.changedOwners | Should -Be @('Обработка.НоваяПроверка')
        $result.impactOwners | Should -Be @('Обработка.НоваяПроверка')
    }

    It 'refuses an existing descriptor availability change while a dependent module stays byte-identical' {
        $fixture=New-ImpactFixture
        $module=Join-Path $fixture.root 'src/cf/CommonModules/Старый/Ext/Module.bsl'
        $sha=(Get-FileHash -LiteralPath $module).Hash
        Set-ImpactFixtureFile $fixture.root 'CommonModules/Старый.xml' '<MetaDataObject><CommonModule uuid="22222222-2222-2222-2222-222222222222"><Properties><Name>Старый</Name><Server>false</Server></Properties></CommonModule></MetaDataObject>'
        $result=Complete-ImpactFixture $fixture
        $result.proven | Should -BeFalse
        $result.reason | Should -Match 'EXISTING_DESCRIPTOR_OR_PAYLOAD_CHANGED'
        (Get-FileHash -LiteralPath $module).Hash | Should -BeExactly $sha
    }

    It 'refuses declaration global and conditional surfaces (<Case>)' -ForEach @(
        @{Case='routine kind';Old='Функция';New='Процедура'},
        @{Case='signature';Old='Параметр = 1';New='Параметр = 2'},
        @{Case='export';Old=' Экспорт';New=''},
        @{Case='context';Old='&НаСервере';New='&НаКлиенте'},
        @{Case='conditional';Old='#Если Сервер Тогда';New='#Если Клиент Тогда'},
        @{Case='global';Old='Перем Общая Экспорт;';New='Перем Другая Экспорт;'}
    ) {
        $body="Перем Общая Экспорт;`r`n#Если Сервер Тогда`r`n&НаСервере`r`nФункция Получить(Знач Параметр = 1) Экспорт`r`n    Возврат Параметр + 1;`r`nКонецФункции`r`n#КонецЕсли"
        $fixture=New-ImpactFixture $body
        $candidate=$body.Replace($Old,$New)
        if ($Case -eq 'routine kind') { $candidate=$candidate.Replace('КонецФункции','КонецПроцедуры') }
        Set-ImpactFixtureFile $fixture.root 'CommonModules/Старый/Ext/Module.bsl' $candidate
        $result=Complete-ImpactFixture $fixture
        $result.proven | Should -BeFalse
        $result.reason | Should -Match 'BSL_SURFACE_CHANGED'
    }

    It 'keeps strings comment markers and multiline parameter defaults exact during a body edit' {
        $body="&НаСервере`r`nФункция Получить(`r`n    Знач Параметр = ""// Функция """"строка""""""`r`n) Экспорт`r`n    Возврат ""КонецФункции // строка"";`r`nКонецФункции"
        $fixture=New-ImpactFixture $body
        Set-ImpactFixtureFile $fixture.root 'CommonModules/Старый/Ext/Module.bsl' $body.Replace('КонецФункции // строка','КонецФункции // другое тело')
        (Complete-ImpactFixture $fixture).proven | Should -BeTrue
    }

    It 'refuses deletions additions to existing objects and unknown changed payloads (<Case>)' -ForEach @(
        @{Case='deletion'},@{Case='existing addition'},@{Case='unknown payload'}
    ) {
        $fixture=New-ImpactFixture
        switch ($Case) {
            'deletion' { Remove-Item -LiteralPath (Join-Path $fixture.root 'src/cf/CommonModules/Старый.xml') }
            'existing addition' { Set-ImpactFixtureFile $fixture.root 'CommonModules/Старый/Ext/NewModule.bsl' 'Процедура Новая() Экспорт КонецПроцедуры' }
            'unknown payload' { Set-ImpactFixtureFile $fixture.root 'unknown-shared.txt' 'неизвестная зависимость' }
        }
        (Complete-ImpactFixture $fixture).proven | Should -BeFalse
    }

    It 'refuses unsafe additive roots and UUID ownership (<Case>)' -ForEach @(
        @{Case='root property'},@{Case='existing child removed'},@{Case='unmatched entry'},@{Case='duplicate entry'},@{Case='UUID collision'},@{Case='missing entry'}
    ) {
        $fixture=New-ImpactFixture
        Add-ImpactNewObject $fixture
        $rootXml=Get-ImpactFixtureRootXml -Added '<DataProcessor>НоваяПроверка</DataProcessor>'
        switch ($Case) {
            'root property' { $rootXml=Get-ImpactFixtureRootXml -Added '<DataProcessor>НоваяПроверка</DataProcessor>' -Extra '<DefaultLanguage>ДругойЯзык</DefaultLanguage>' }
            'existing child removed' { $rootXml=$rootXml.Replace('<CommonModule>Старый</CommonModule>','') }
            'unmatched entry' { $rootXml=$rootXml.Replace('<DataProcessor>НоваяПроверка</DataProcessor>','<Report>НоваяПроверка</Report>') }
            'duplicate entry' { $rootXml=$rootXml.Replace('</ChildObjects>','<DataProcessor>НоваяПроверка</DataProcessor></ChildObjects>') }
            'UUID collision' { Add-ImpactNewObject $fixture -Uuid '22222222-2222-2222-2222-222222222222' }
            'missing entry' { $rootXml=Get-ImpactFixtureRootXml }
        }
        if ($Case -ne 'UUID collision') { Set-ImpactFixtureFile $fixture.root 'Configuration.xml' $rootXml }
        (Complete-ImpactFixture $fixture).proven | Should -BeFalse
    }

    It 'refuses added names already referenced by unchanged old source (<Case>)' -ForEach @(
        @{Case='object name';Reference='НоваяПроверка'},
        @{Case='definition UUID';Reference='33333333-3333-3333-3333-333333333333'},
        @{Case='exported routine';Reference='ЗапуститьНовуюПроверку'}
    ) {
        $body="Функция Получить() Экспорт`r`n    Возврат ""$Reference""; // прежняя ссылка`r`nКонецФункции"
        $fixture=New-ImpactFixture $body
        Add-ImpactNewObject $fixture
        $result=Complete-ImpactFixture $fixture
        $result.proven | Should -BeFalse
        $result.reason | Should -Match 'PREEXISTING_REFERENCE_TO_ADDED_NAME'
    }

    It 'refuses ambient or unresolved shared dependencies of a new object (<Case>)' -ForEach @(
        @{Case='ambient';Properties='<Global>true</Global>';Body=''},
        @{Case='shared reference';Properties='';Body='Процедура Новая() Экспорт Старый.Вызвать(); КонецПроцедуры'}
    ) {
        $fixture=New-ImpactFixture
        Add-ImpactNewObject $fixture -Properties $Properties -Body $Body
        $result=Complete-ImpactFixture $fixture
        $result.proven | Should -BeFalse
        $result.reason | Should -Be 'NEW_SHARED_DEPENDENCY_UNRESOLVED'
    }

    It 'returns unresolved for unavailable or unrecognizable immutable trees without changing Git' {
        $fixture=New-ImpactFixture
        $head=Invoke-ImpactGit $fixture.root @('rev-parse','HEAD')
        $result=Test-ItlPlatformLegacySourceImpact -ProjectRoot $fixture.root -PreviousTreeObjectId ('0'*40) -CurrentTreeObjectId $fixture.beforeTree
        $result.proven | Should -BeFalse
        (Invoke-ImpactGit $fixture.root @('rev-parse','HEAD')) | Should -BeExactly $head
        (Test-ItlPlatformLegacySourceImpact -ProjectRoot $fixture.root -PreviousTreeObjectId 'mutable-HEAD' -CurrentTreeObjectId $fixture.beforeTree).reason | Should -Be 'TREE_ID_UNRESOLVED'
    }
}
