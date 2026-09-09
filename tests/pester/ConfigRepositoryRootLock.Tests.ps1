BeforeAll {
    $script:RootLockHelper = Join-Path $PSScriptRoot '../../.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    function Write-RootLockMetadata {
        param($Root, $Collection, $Type, $Name, $Uuid = ([guid]::NewGuid().ToString('D')), $Extra = '')
        $path = Join-Path $Root "src/cf/$Collection/$Name.xml"
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, "<MetaDataObject><$Type uuid=`"$Uuid`"><Properties><Name>$Name</Name></Properties>$Extra</$Type></MetaDataObject>", [Text.UTF8Encoding]::new($true))
    }
    function Write-RootLockConfiguration {
        param($Root, $Children = '')
        [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Configuration.xml'), "<MetaDataObject><Configuration uuid=`"11111111-1111-4111-8111-111111111111`"><ChildObjects><Catalog>Существующий</Catalog>$Children</ChildObjects></Configuration></MetaDataObject>", [Text.UTF8Encoding]::new($true))
    }
    function New-RootLockFixture {
        param($Root)
        Write-RootLockMetadata $Root 'Catalogs' 'Catalog' 'Существующий' '22222222-2222-4222-8222-222222222222'
        Write-RootLockConfiguration $Root
        [void][IO.Directory]::CreateDirectory((Join-Path $Root 'src/cf/Ext'))
        [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Ext/CommandInterface.xml'), '<CommandInterface />')
        & git -C $Root init --quiet
        & git -C $Root config user.email test@example.com
        & git -C $Root config user.name Test
        & git -C $Root config core.autocrlf false
        & git -C $Root add .
        & git -C $Root commit --quiet -m baseline
        & git -C $Root branch -M master
        & git -C $Root checkout --quiet -b itldev/root-lock
    }
}

Describe 'Configuration root lock dependencies' {
    It 'adds one root-only dependency for top-level objects across committed staged dirty and untracked changes' {
        $root = Join-Path $TestDrive 'Корень с пробелом'
        New-RootLockFixture $root
        $categories = @(
            @('Catalogs', 'Catalog'), @('Documents', 'Document'), @('CommonForms', 'CommonForm'), @('CommonModules', 'CommonModule'),
            @('Constants', 'Constant'), @('SessionParameters', 'SessionParameter'), @('Roles', 'Role'), @('InformationRegisters', 'InformationRegister')
        )
        $children = ''
        for ($i = 0; $i -lt $categories.Count; $i++) {
            $collection, $type = $categories[$i]
            $name = "Новый $i"
            Write-RootLockMetadata $root $collection $type $name
            $children += "<$type>$name</$type>"
            if ($i -eq 1) { & git -C $root add .; & git -C $root commit --quiet -m committed }
            if ($i -eq 3) { & git -C $root add . }
        }
        Write-RootLockConfiguration $root $children
        Write-RootLockMetadata $root 'Catalogs' 'Catalog' 'Существующий' '22222222-2222-4222-8222-222222222222' '<ChildObjects><Attribute uuid="33333333-3333-4333-8333-333333333333" /></ChildObjects>'
        $result = & {
            . $script:RootLockHelper -ProjectRoot $root -Action help *> $null
            function Get-MasterBranch { 'master' }
            $plan = Get-ConfigRepositoryTransferPlan -ExportPath src/cf -ForRepositoryLock
            $path = Write-ConfigRepositoryObjectList -Plan $plan -Path (Join-Path $root 'Список объектов.xml')
            [pscustomobject]@{ plan = $plan; xml = [xml](Read-Utf8Text -Path $path) }
        }
        @($result.plan.rootLockRequiredBy).Count | Should -Be 8
        @($result.plan.items | Where-Object name -eq 'Конфигурация').Count | Should -Be 1
        $result.xml.Objects.Configuration.includeChildObjects | Should -Be 'false'
        @($result.xml.Objects.Object).Count | Should -Be 9
        @($result.xml.Objects.Object | Where-Object fullName -eq 'Конфигурация').Count | Should -Be 0
        @($result.plan.rootLockRequiredBy) | Should -Not -Contain 'Справочник.Существующий'
    }

    It 'does not lock the root for a new form or attribute inside an existing catalog' {
        $root = Join-Path $TestDrive 'Дочерние с пробелом'
        New-RootLockFixture $root
        Write-RootLockMetadata $root 'Catalogs' 'Catalog' 'Существующий' '22222222-2222-4222-8222-222222222222' '<ChildObjects><Attribute uuid="33333333-3333-4333-8333-333333333333" /></ChildObjects>'
        $form = Join-Path $root 'src/cf/Catalogs/Существующий/Forms/Новая форма.xml'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $form))
        [IO.File]::WriteAllText($form, '<MetaDataObject><Form uuid="44444444-4444-4444-8444-444444444444"><Properties><Name>Новая форма</Name></Properties></Form></MetaDataObject>')
        $plan = & {
            . $script:RootLockHelper -ProjectRoot $root -Action help *> $null
            function Get-MasterBranch { 'master' }
            Get-ConfigRepositoryTransferPlan -ExportPath src/cf -ForRepositoryLock
        }
        @($plan.items | Where-Object name -eq 'Конфигурация').Count | Should -Be 0
        @($plan.items | Where-Object name -eq 'Справочник.Существующий.Форма.Новая форма').Count | Should -Be 1
    }

    It 'recognizes a rename by UUID instead of treating its new descriptor path as an addition' {
        $root = Join-Path $TestDrive 'Переименование с пробелом'
        New-RootLockFixture $root
        Remove-Item -LiteralPath (Join-Path $root 'src/cf/Catalogs/Существующий.xml')
        Write-RootLockMetadata $root 'Catalogs' 'Catalog' 'НовоеИмя' '22222222-2222-4222-8222-222222222222'
        Write-RootLockConfiguration $root '<Catalog>НовоеИмя</Catalog>'
        $plan = & {
            . $script:RootLockHelper -ProjectRoot $root -Action help *> $null
            function Get-MasterBranch { 'master' }
            Get-ConfigRepositoryTransferPlan -ExportPath src/cf -ForRepositoryLock
        }
        @($plan.items | Where-Object name -eq 'Конфигурация').Count | Should -Be 0
    }

    It 'rejects malformed metadata missing root membership and duplicate identity before requesting locks' -TestCases @(
        @{ defect = 'malformed' }, @{ defect = 'missing-member' }, @{ defect = 'duplicate' }, @{ defect = 'wrong-type' }
    ) {
        param($defect)
        $root = Join-Path $TestDrive ('Неоднозначность с пробелом ' + $defect)
        New-RootLockFixture $root
        Write-RootLockMetadata $root 'Constants' 'Constant' 'Новая'
        Write-RootLockConfiguration $root '<Constant>Новая</Constant>'
        switch ($defect) {
            malformed { [IO.File]::WriteAllText((Join-Path $root 'src/cf/Constants/Новая.xml'), '<invalid') }
            missing-member { Write-RootLockConfiguration $root }
            duplicate { Write-RootLockMetadata $root 'Catalogs' 'Catalog' 'Копия' '22222222-2222-4222-8222-222222222222' }
            wrong-type { Write-RootLockMetadata $root 'Constants' 'Catalog' 'Новая' }
        }
        $result = & {
            . $script:RootLockHelper -ProjectRoot $root -Action help *> $null
            function Get-MasterBranch { 'master' }
            function Read-DevBranchState { [pscustomobject]@{ devBranch = 'itldev/root-lock'; devBranchKind = 'configuration'; initializationStatus = 'ready' } }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Repair-OneCSourceLineEndings {}
            function Get-SourceUsesRepository { $true }
            function Get-ExportPath { 'src/cf' }
            $script:Calls = 0
            function Invoke-Designer { $script:Calls++ }
            $errorText = ''
            try { Lock-ConfigRepositoryObjects 6>$null } catch { $errorText = $_.Exception.Message }
            [pscustomobject]@{ error = $errorText; calls = $script:Calls }
        }
        $result.error | Should -Match 'LOCK_CONFIG_REPOSITORY_METADATA_AMBIGUOUS'
        $result.calls | Should -Be 0
    }

    It 'orders a root-only request before the remaining objects and preserves both phase outcomes' -TestCases @(
        @{ failurePhase = 0; silentRoot = $false }, @{ failurePhase = 1; silentRoot = $false },
        @{ failurePhase = 2; silentRoot = $false }, @{ failurePhase = 0; silentRoot = $true }
    ) {
        param($failurePhase, $silentRoot)
        $root = Join-Path $TestDrive ("Порядок с пробелом $failurePhase $silentRoot")
        New-RootLockFixture $root
        Write-RootLockMetadata $root 'Constants' 'Constant' 'Новая'
        Write-RootLockConfiguration $root '<Constant>Новая</Constant>'
        Write-RootLockMetadata $root 'Catalogs' 'Catalog' 'Существующий' '22222222-2222-4222-8222-222222222222' '<ChildObjects />'
        $result = & {
            . $script:RootLockHelper -ProjectRoot $root -Action help *> $null
            function Get-MasterBranch { 'master' }
            function Read-DevBranchState { [pscustomobject]@{ devBranch = 'itldev/root-lock'; devBranchKind = 'configuration'; initializationStatus = 'ready' } }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Repair-OneCSourceLineEndings {}
            function Get-SourceUsesRepository { $true }
            function Get-SourceInfoBasePath { 'source' }
            function Get-InfoBaseKind { 'file' }
            function Get-ExportPath { 'src/cf' }
            function New-RepositoryConnectionArgs { @() }
            function Get-EnvValue { param($Name) 'TestOwner' }
            function Set-RunStage {}
            $script:Requests = [Collections.Generic.List[object]]::new()
            function Invoke-Designer {
                param($InfoBasePath, $InfoBaseKind, $DesignerArgs)
                $request = [xml](Read-Utf8Text -Path $DesignerArgs[2])
                $script:Requests.Add($request)
                $script:LastLogPath = Join-Path $root ('designer-' + $script:Requests.Count + '.log')
                $lines = @('---- Начало операции с хранилищем конфигурации ----')
                if ($script:Requests.Count -eq 1) {
                    if (-not $silentRoot) {
                        $lines += if ($failurePhase -eq 1) { 'Объект захвачен для редактирования другим пользователем: Конфигурация (ЧужойВладелец)' } else { 'Объект захвачен для редактирования: Конфигурация' }
                    }
                } else {
                    $lines = @('Объекты, отсутствующие в обеих конфигурациях:', 'Константа.Новая') + $lines
                    $lines += if ($failurePhase -eq 2) { 'Объект захвачен для редактирования другим пользователем: Справочник.Существующий (ЧужойВладелец)' } else { 'Объект захвачен для редактирования: Справочник.Существующий' }
                }
                $lines += '---- Операция с хранилищем конфигурации завершена ----'
                Write-Utf8Text -Path $script:LastLogPath -Value ($lines -join "`r`n")
                if ($failurePhase -eq $script:Requests.Count) { throw 'native lock failed' }
            }
            $errorText = ''
            try { Lock-ConfigRepositoryObjects 6>$null } catch { $errorText = $_.Exception.Message }
            $outcomePath = @(Get-ChildItem -LiteralPath (Join-Path $root '.agent-1c/runs') -Recurse -Filter repository-lock-result.json)[0].FullName
            [pscustomobject]@{ requests = @($script:Requests); error = $errorText; report = $script:RunUserReport; outcome = (Read-Utf8Text -Path $outcomePath | ConvertFrom-Json) }
        }
        $result.requests[0].Objects.Configuration.includeChildObjects | Should -Be 'false'
        @($result.requests[0].SelectNodes('//*[local-name()="Object"]')).Count | Should -Be 0
        $result.report | Should -Match 'Константа.Новая'
        if ($failurePhase -eq 1) {
            @($result.requests).Count | Should -Be 1
            $result.error | Should -Match 'ЧужойВладелец'
            $result.report | Should -Match 'захват остальных объектов не запускался'
            @($result.outcome.items | Where-Object name -eq 'Конфигурация')[0].status | Should -Be 'conflict'
            @($result.outcome.items | Where-Object name -eq 'Константа.Новая')[0].status | Should -Be 'unconfirmed'
        } else {
            if ($failurePhase -eq 2) { $result.error | Should -Match 'ЧужойВладелец' } else { $result.error | Should -BeNullOrEmpty }
            @($result.requests).Count | Should -Be 2
            @($result.requests[1].SelectNodes('//*[local-name()="Configuration"]')).Count | Should -Be 0
            @($result.requests[1].Objects.Object).Count | Should -Be 2
            $expectedRootStatus = if ($silentRoot) { 'unconfirmed' } else { 'captured' }
            @($result.outcome.items | Where-Object name -eq 'Конфигурация')[0].status | Should -Be $expectedRootStatus
            @($result.outcome.items | Where-Object name -eq 'Константа.Новая')[0].status | Should -Be 'absent'
            Test-Path -LiteralPath $result.outcome.rootOperation.logPath | Should -BeTrue
        }
    }

    It 'detects a replacement UUID at the same path and deduplicates an existing root module dependency' {
        $root = Join-Path $TestDrive 'Замена с пробелом'
        New-RootLockFixture $root
        Write-RootLockMetadata $root 'Catalogs' 'Catalog' 'Существующий' '55555555-5555-4555-8555-555555555555'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'src/cf/Ext'))
        [IO.File]::WriteAllText((Join-Path $root 'src/cf/Ext/SessionModule.bsl'), '// session change')
        $plan = & {
            . $script:RootLockHelper -ProjectRoot $root -Action help *> $null
            function Get-MasterBranch { 'master' }
            Get-ConfigRepositoryTransferPlan -ExportPath src/cf -ForRepositoryLock
        }
        @($plan.items | Where-Object name -eq 'Конфигурация').Count | Should -Be 1
        @($plan.rootLockRequiredBy) | Should -Be @('Справочник.Существующий')
        @($plan.items | Where-Object name -eq 'Конфигурация')[0].scope | Should -Be 'partial'
    }
}
