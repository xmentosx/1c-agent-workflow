Describe 'Pinned catalog apply uses the common MCP writer and its physical proofs' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $HelperPath=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        $RuntimePath=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-runtime.ps1'
        function New-StartupCatalogFixture {
            return @{catalogRevision=('a'*40);inputGitObjectIds=@{};catalog=@{schemaVersion=1;products=@(@{productId='corp';name='Corp';baseConfigurationVersion='PM5';roles=@{code=@{mode='own';sourceId='corp-code'}}});projects=@(@{projectId='fixture';productId='corp';name='Fixture'});profiles=@();sources=@(@{sourceId='corp-code';role='code';namespace='native-code';endpoint=@{hostId='a';serverId='code';configId='corp'}});instances=@()};relations=@{schemaVersion=1;relations=@();knowledgeAreas=@{}};registry=@{schemaVersion=2;hosts=@(@{hostId='a';configurations=@(@{id='corp'});servers=@(@{id='code';scope='project';family='vibecoding1c';configId='corp';url='https://source.invalid/mcp'})})}}
        }
    }
    BeforeEach {
        $caseClient=if(Get-Variable Client -ErrorAction SilentlyContinue){$Client}else{''}
        $root=Join-Path $TestDrive ('Локальный проект '+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root '.agent-1c'))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{"aiRules":{"tools":["codex","claude-code"]}}',[Text.UTF8Encoding]::new($false))
        . $HelperPath -ProjectRoot $root -Action help *> $null
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-catalog.ps1')
        . $RuntimePath
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1')
        $Client=$caseClient
        $context=@{projectId='fixture';productId='corp';catalogRevision=('a'*40);settingsHash='settings-a';knowledgeHash='knowledge-a'}
        $requests=@(
            @{client='codex';owner='vibecoding1c';endpoints=@(@{name='code';url='https://new.invalid'})},
            @{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='code';url='https://new.invalid'})})
        $LowLevelWriter=${function:Write-ItlClientMcpEndpoints}
        $AtomicWriter=${function:Write-Utf8TextAtomic}
        $OwnerWriter=${function:Write-ItlManagedMcpState}
    }
    It 'applies and restores remote and Unicode stdio endpoints through <Client>' -ForEach @(
        @{Client='codex'},@{Client='claude-code'},@{Client='opencode'},@{Client='kilocode'},@{Client='cursor'},@{Client='kimi'},@{Client='qwen'},@{Client='command-code'},@{Client='cline'},@{Client='zcode'},@{Client='mimocode'},@{Client='pi'}) {
        $old=@(@{client=$Client;owner='vibecoding1c';endpoints=@(@{name='retired';transport='stdio';command='C:\Инструменты с пробелом\tool.exe';args=@('Аргумент с пробелом');env=@{TEXT='Кириллица'};toolTimeoutSeconds=35},@{name='code';url='https://old.invalid'})})
        Write-ItlClientMcpEndpointSet $old *> $null
        $before=Get-ItlMcpOwnedSemanticSignature (Read-ItlClientMcpEntries $Client) @('code','retired')
        $result=Invoke-ItlProductProjectClientApply $context @(@{client=$Client;owner='vibecoding1c';endpoints=@(@{name='code';url='https://new.invalid'},@{name='added';url='https://added.invalid'})})
        $result.status | Should -Be configured
        $result.activeClientContext | Should -Be unverified
        (Read-ItlProductProjectRecord applied).catalogRevision | Should -Be ('a'*40)
        (Invoke-ItlProductProjectClientApply -Mode restore).status | Should -Be restored
        (Get-ItlMcpOwnedSemanticSignature (Read-ItlClientMcpEntries $Client) @('code','retired')) | Should -BeExactly $before
        (Read-ItlClientMcpEntries $Client).Contains('added') | Should -BeFalse
        Test-Path -LiteralPath (Get-ItlProductProjectPath applied) | Should -BeFalse
    }
    It 'keeps JSONC comments and unrelated later edits through restore' {
        $path=Join-Path $root 'opencode.jsonc'
        Write-Utf8TextAtomic $path "{`n // Авторский комментарий`n `"theme`": `"old`",`n `"mcp`": {}`n}`n"
        $requests=@(@{client='opencode';owner='vibecoding1c';endpoints=@(@{name='code';url='https://new.invalid'})})
        $null=Invoke-ItlProductProjectClientApply $context $requests
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('"old"','"new-theme"'))
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        (Read-Utf8Text $path) | Should -Match 'Авторский комментарий'
        (Read-Utf8Text $path) | Should -Match 'new-theme'
        (Read-ItlClientMcpEntries opencode).Contains('code') | Should -BeFalse
    }
    It 'does not bless an edit of a later client after the first receipt and resumes the same SHA' {
        Write-ItlClientMcpEndpointSet @(@{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='code';url='https://old.invalid'})}) *> $null
        $later=Join-Path $root '.mcp.json';$laterBefore=Read-Utf8Text $later
        Mock Write-ItlClientMcpEndpoints {
            $value=& $LowLevelWriter @PesterBoundParameters
            if($Client -eq 'codex' -and $ReturnReceipt){Write-Utf8TextAtomic $later ((Read-Utf8Text $later).Replace('https://old.invalid','https://manual.invalid'))}
            return $value
        }
        {Invoke-ItlProductProjectClientApply $context $requests} | Should -Throw '*CLIENT_MCP_FINAL_SET_CHANGED*'
        $operation=Read-ItlProductProjectRecord operation
        $operation.status | Should -Be partial
        Test-Path -LiteralPath (Get-ItlProductProjectPath applied) | Should -BeFalse
        (Invoke-ItlProductProjectClientApply -Mode cancel).status | Should -Be needs-recovery
        {Invoke-ItlProductProjectClientApply -Mode resume} | Should -Throw '*CATALOG_CLIENT_CONFLICT*'
        (Read-Utf8Text $later) | Should -Match 'manual.invalid'
        Write-Utf8TextAtomic $later $laterBefore
        Mock Write-ItlClientMcpEndpoints { & $LowLevelWriter @PesterBoundParameters }
        $latest=@{catalogRevision=('b'*40)}
        $result=Invoke-ItlProductProjectClientApply -Context $latest -Mode resume
        $result.operationId | Should -Be $operation.operationId
        $result.catalogRevision | Should -Be ('a'*40)
        (Read-Utf8Text $later) | Should -Match 'new.invalid'
    }
    It 'recovers the gap after a physical config write and before ownership save for <Client>' -ForEach @(@{Client='codex'},@{Client='claude-code'},@{Client='opencode'}) {
        $requests=@(@{client=$Client;owner='vibecoding1c';endpoints=@(@{name='new-code';url='https://new.invalid'})})
        Mock Write-ItlManagedMcpState { throw 'injected ownership interruption' }
        {Invoke-ItlProductProjectClientApply $context $requests} | Should -Throw '*injected ownership*'
        $operation=Read-ItlProductProjectRecord operation
        $operation.activeWrite | Should -Not -BeNullOrEmpty
        (Read-ItlClientMcpEntries $Client).Contains('new-code') | Should -BeTrue
        Mock Write-ItlManagedMcpState { & $OwnerWriter @PesterBoundParameters }
        $result=Invoke-ItlProductProjectClientApply -Mode resume
        $result.status | Should -Be configured
        $result.operationId | Should -Be $operation.operationId
        (Invoke-ItlProductProjectClientApply -Mode restore).status | Should -Be restored
        (Read-ItlClientMcpEntries $Client).Contains('new-code') | Should -BeFalse
    }
    It 'refuses a changed owned key on restore and leaves the applied marker intact' {
        $null=Invoke-ItlProductProjectClientApply $context $requests
        $path=Join-Path $root '.mcp.json'
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('https://new.invalid','https://manual.invalid'))
        {Invoke-ItlProductProjectClientApply -Mode restore} | Should -Throw '*CATALOG_CLIENT_CONFLICT*'
        (Read-ItlProductProjectRecord applied).catalogRevision | Should -Be ('a'*40)
        (Read-Utf8Text $path) | Should -Match 'manual.invalid'
    }
    It 'preserves preexisting custom/disabled entries and never adopts them as owned baseline' {
        Write-Utf8TextAtomic (Join-Path $root '.mcp.json') '{"mcpServers":{"code":{"url":"https://custom.invalid","disabled":true,"headers":{"token":"harmless-fixture"}}},"custom":"keep"}'
        $null=Invoke-ItlProductProjectClientApply $context $requests
        (Read-ItlClientMcpEntries claude-code).code.disabled | Should -BeTrue
        (Read-ItlClientMcpEntries claude-code).code.url | Should -Be 'https://custom.invalid'
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        (Read-ItlClientMcpEntries claude-code).code.headers.token | Should -Be harmless-fixture
        (Get-ItlManagedMcpOwnerKeys -Client claude-code -Owner vibecoding1c) | Should -Not -Contain code
    }
    It 'retains exact policy fields on a retired key restored after removal' {
        $old=@(@{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='retired';url='https://old.invalid'})})
        Write-ItlClientMcpEndpointSet $old *> $null
        $path=Join-Path $root '.mcp.json'
        $value=ConvertTo-ItlCatalogCanonicalValue (Read-Utf8Text $path|ConvertFrom-Json)
        $value.mcpServers.retired['disabled']=$true;$value.mcpServers.retired['headers']=@{token='fixture-local'}
        Write-Utf8TextAtomic $path ($value|ConvertTo-Json -Depth 30)
        # Existing owner deliberately adopts that policy through its explicit sync.
        Write-ItlClientMcpEndpointSet $old *> $null
        $before=Get-ItlMcpOwnedSemanticSignature (Read-ItlClientMcpEntries claude-code) @('retired')
        $null=Invoke-ItlProductProjectClientApply $context @(@{client='claude-code';owner='vibecoding1c';endpoints=@()})
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        (Get-ItlMcpOwnedSemanticSignature (Read-ItlClientMcpEntries claude-code) @('retired')) | Should -BeExactly $before
    }
    It 'applies a knowledge-only marker without client or memory calls' {
        Mock Write-ItlClientMcpEndpointSet {throw 'unexpected client write'}
        (Invoke-ItlProductProjectClientApply $context @()).status | Should -Be configured
        Should -Invoke Write-ItlClientMcpEndpointSet -Times 0 -Exactly
        (Invoke-ItlProductProjectClientApply -Mode restore).status | Should -Be restored
    }
    It 'recovers a partial OpenCode write across physical JSONC layers' {
        $first=Join-Path $root 'opencode.jsonc';$second=Join-Path $root '.opencode/opencode.jsonc'
        Write-Utf8TextAtomic $first '{/* первый слой */ "mcp":{}}'
        Write-ItlClientMcpEndpointSet @(@{client='opencode';owner='vibecoding1c';endpoints=@(@{name='one';url='https://old.invalid'})}) *> $null
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $second))
        Write-Utf8TextAtomic $second '{/* второй слой */ "mcp":{}}'
        $old=@(@{client='opencode';owner='vibecoding1c';endpoints=@(@{name='one';url='https://old.invalid'},@{name='two';url='https://old.invalid'})})
        Write-ItlClientMcpEndpointSet $old *> $null
        $requests=@(@{client='opencode';owner='vibecoding1c';endpoints=@(@{name='one';url='https://new.invalid'},@{name='two';url='https://new.invalid'})})
        Mock Write-Utf8TextAtomic {
            & $AtomicWriter @PesterBoundParameters
            if($Path -eq $first -and $Value -match 'new.invalid'){throw 'injected between physical layers'}
        }
        {Invoke-ItlProductProjectClientApply $context $requests} | Should -Throw '*between physical layers*'
        (Read-Utf8Text $first) | Should -Match 'new.invalid'
        (Read-Utf8Text $second) | Should -Match 'old.invalid'
        Mock Write-Utf8TextAtomic { & $AtomicWriter @PesterBoundParameters }
        (Invoke-ItlProductProjectClientApply -Mode resume).status | Should -Be configured
        (Read-Utf8Text $second) | Should -Match 'new.invalid'
        (Invoke-ItlProductProjectClientApply -Mode restore).status | Should -Be restored
        (Read-Utf8Text $first) | Should -Match 'первый слой'
        (Read-Utf8Text $second) | Should -Match 'второй слой'
        (Read-ItlClientMcpEntries opencode).one.url | Should -Be 'https://old.invalid'
        (Read-ItlClientMcpEntries opencode).two.url | Should -Be 'https://old.invalid'
    }
    It 'cooperatively cancels between client writes and exposes actual CLI status/resume/restore' {
        Mock Write-ItlClientMcpEndpoints {
            $value=& $LowLevelWriter @PesterBoundParameters
            if($Client -eq 'codex' -and $ReturnReceipt){(Invoke-ItlProductProjectRecovery cancel).status | Should -Be cancel-requested}
            return $value
        }
        {Invoke-ItlProductProjectClientApply $context $requests} | Should -Throw '*CATALOG_CANCEL_REQUESTED*'
        (Read-ItlClientMcpEntries claude-code).Contains('code') | Should -BeFalse
        $operation=Read-ItlProductProjectRecord operation
        $operation.status | Should -Be partial
        $status=Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @('-ProjectRoot',$root,'-Action','vibecoding1c-mcp-status','-CatalogAction','status')
        $status.ExitCode | Should -Be 0
        $status.combinedText | Should -Match $operation.operationId
        $resume=Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @('-ProjectRoot',$root,'-Action','vibecoding1c-mcp-select','-CatalogAction','resume')
        $resume.ExitCode | Should -Be 0
        (Read-ItlProductProjectRecord applied).operationId | Should -Be $operation.operationId
        $restore=Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @('-ProjectRoot',$root,'-Action','vibecoding1c-mcp-select','-CatalogAction','restore')
        $restore.ExitCode | Should -Be 0
        (Read-ItlProductProjectRecord operation).status | Should -Be restored
    }
    It 'keeps pipeline-wrapped scalar values in exact signatures instead of hashing their lengths' {
        $one=@('aaaa')|ForEach-Object {$_};$two=@('bbbb')|ForEach-Object {$_}
        (Get-ItlCatalogHash @{args=@($one)}) | Should -Not -Be (Get-ItlCatalogHash @{args=@($two)})
        (Get-ItlMcpOwnedSemanticSignature @{entry=@{args=@($one)}} @('entry')) | Should -Not -Be (Get-ItlMcpOwnedSemanticSignature @{entry=@{args=@($two)}} @('entry'))
        (Get-ItlCatalogHash @{args=@($one)}) | Should -Be (Get-ItlCatalogHash @{args=@('aaaa')})
        $record=ConvertTo-ItlCatalogCanonicalValue ('{"args":["aaaa"],"nullable":null,"empty":[]}'|ConvertFrom-Json)
        $record.args[0] | Should -Be 'aaaa'
        $record.empty.Count | Should -Be 0
        $record.nullable | Should -BeNullOrEmpty
    }
    It 'retains restoration proof when resuming a failure before preflight completed' {
        $old=@(@{client='codex';owner='vibecoding1c';endpoints=@(@{name='code';url='https://old.invalid'})})
        Write-ItlClientMcpEndpointSet $old *> $null
        Mock Write-ItlClientMcpEndpoints {throw 'injected preflight failure'}
        {Invoke-ItlProductProjectClientApply $context $requests} | Should -Throw '*preflight failure*'
        $id=(Read-ItlProductProjectRecord operation).operationId
        Mock Write-ItlClientMcpEndpoints { & $LowLevelWriter @PesterBoundParameters }
        (Invoke-ItlProductProjectClientApply -Mode resume).operationId | Should -Be $id
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        (Read-ItlClientMcpEntries codex).code.url | Should -Be 'https://old.invalid'
    }
    It 'writes tracked binding before the applied marker and restores only that property' {
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context $requests -BindProject -DesiredBinding $binding
        (Read-Utf8Text $script:ConfigPath|ConvertFrom-Json).productProject.projectId|Should -Be fixture
        $config=Read-ItlProductProjectConfig;$config['userField']='keep this'
        Write-Utf8TextAtomic $script:ConfigPath ($config|ConvertTo-Json -Depth 20)
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        (Read-ItlProductProjectConfig).Contains('productProject')|Should -BeFalse
        (Read-ItlProductProjectConfig).userField|Should -Be 'keep this'
        Test-Path -LiteralPath (Get-ItlProductProjectPath applied)|Should -BeFalse
    }
    It 'restores noncanonical descriptor bytes and private later through <Recovery> with BOM=<Bom>' -ForEach @(
        @{Recovery='restore';Bom=$false;Newline="`r`n"},@{Recovery='restore-compatible';Bom=$true;Newline="`n"}) {
        $text=('{'+$Newline+'  "z": {"вложенный": "productProject", "a": 1},'+$Newline+' "aiRules" : { "tools": ["codex", "claude-code"] }'+$Newline+'}')
        [IO.File]::WriteAllText($script:ConfigPath,$text,[Text.UTF8Encoding]::new($Bom))
        $before=Get-ItlMcpFileState $script:ConfigPath
        Set-ItlProductProjectSetting selection @{associationOffer='later'} $null
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        (Get-ItlMcpFileState $script:ConfigPath)|Should -Not -Be $before
        if($Recovery -eq 'restore-compatible'){
            # A later knowledge-only operation must retain the original file receipt.
            $null=Invoke-ItlProductProjectClientApply $context @()
        }
        (Invoke-ItlProductProjectRecovery -Mode $Recovery).status|Should -Be $(if($Recovery -eq 'restore'){'restored'}else{'compatible-restored'})
        (Get-ItlMcpFileState $script:ConfigPath)|Should -BeExactly $before
        (Read-ItlProductProjectSetting selection).associationOffer|Should -Be later
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
    }
    It 'refuses a later owned binding edit instead of replacing it with saved descriptor bytes' {
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        Write-Utf8TextAtomic $script:ConfigPath ((Read-Utf8Text $script:ConfigPath).Replace('fixture','manual'))
        $changed=Get-ItlMcpFileState $script:ConfigPath
        {Invoke-ItlProductProjectClientApply -Mode restore}|Should -Throw '*CATALOG_SETTING_CONFLICT*'
        (Get-ItlMcpFileState $script:ConfigPath)|Should -BeExactly $changed
        (Read-ItlProductProjectRecord applied).operationId|Should -Not -BeNullOrEmpty
    }
    It 'recovers the saved bytes after a restore write before its receipt' {
        Write-Utf8TextAtomic $script:ConfigPath '{ "z": "исходный", "aiRules": {"tools":["codex"]} }'
        $before=Get-ItlMcpFileState $script:ConfigPath
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        $id=(Read-ItlProductProjectRecord operation).operationId
        Mock Write-Utf8TextAtomic {
            & $AtomicWriter @PesterBoundParameters
            if($Path -eq $script:ConfigPath){throw 'injected restore receipt gap'}
        }
        {Invoke-ItlProductProjectClientApply -Mode restore}|Should -Throw '*restore receipt gap*'
        (Get-ItlMcpFileState $script:ConfigPath)|Should -BeExactly $before
        Mock Write-Utf8TextAtomic { & $AtomicWriter @PesterBoundParameters }
        (Invoke-ItlProductProjectClientApply -Mode resume).operationId|Should -Be $id
        (Read-ItlProductProjectRecord operation).status|Should -Be restored
        (Get-ItlMcpFileState $script:ConfigPath)|Should -BeExactly $before
    }
    It 'keeps semantic owned recovery available for historical receipts without saved bytes' {
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        $old=Read-ItlProductProjectRecord operation;$old.binding.Remove('fileReceipt')
        Write-ItlProductProjectRecord operation $old
        (Invoke-ItlProductProjectClientApply -Mode restore).status|Should -Be restored
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
    }
    It 'resumes the exact binding intent after config write before its receipt or marker' {
        Write-Utf8TextAtomic $script:ConfigPath '{ "z": 1, "aiRules": {"tools":["codex"]} }'
        $before=Get-ItlMcpFileState $script:ConfigPath
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        Mock Write-Utf8TextAtomic {
            & $AtomicWriter @PesterBoundParameters
            if($Path -eq $script:ConfigPath -and $Value -match 'productProject'){throw 'injected binding receipt gap'}
        }
        {Invoke-ItlProductProjectClientApply $context $requests -BindProject -DesiredBinding $binding}|Should -Throw '*binding receipt gap*'
        (Read-ItlProductProjectRecord operation).binding.active|Should -BeTrue
        Test-Path -LiteralPath (Get-ItlProductProjectPath applied)|Should -BeFalse
        $id=(Read-ItlProductProjectRecord operation).operationId
        Mock Write-Utf8TextAtomic { & $AtomicWriter @PesterBoundParameters }
        (Invoke-ItlProductProjectClientApply -Mode resume).operationId|Should -Be $id
        (Read-ItlProductProjectRecord applied).operationId|Should -Be $id
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        (Read-ItlProductProjectConfig).Contains('productProject')|Should -BeFalse
        (Get-ItlMcpFileState $script:ConfigPath)|Should -BeExactly $before
    }
    It 'validates binding capability before any client writes' {
        Mock Write-ItlClientMcpEndpointSet {throw 'unexpected client writer'}
        {Invoke-ItlProductProjectClientApply $context $requests -BindProject -DesiredBinding @{schemaVersion=2}}|Should -Throw '*CATALOG_BINDING_CAPABILITY*'
        Should -Invoke Write-ItlClientMcpEndpointSet -Times 0 -Exactly
    }
    It 'retains the last proven clients and initial compatibility baseline on a knowledge-only update' {
        $null=Invoke-ItlProductProjectClientApply $context $requests
        $previous=Read-ItlProductProjectRecord applied
        $changed=ConvertTo-ItlCatalogCanonicalValue $context;$changed.catalogRevision=('b'*40);$changed.knowledgeHash='knowledge-b'
        Mock Write-ItlClientMcpEndpointSet {throw 'unexpected client writer'}
        $null=Invoke-ItlProductProjectClientApply $changed @()
        $actual=Read-ItlProductProjectRecord applied
        (Get-ItlCatalogHash $actual.proof)|Should -Be (Get-ItlCatalogHash $previous.proof)
        (Get-ItlCatalogHash $actual.compatibilityBaseline)|Should -Be (Get-ItlCatalogHash $previous.compatibilityBaseline)
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        (Read-ItlProductProjectRecord applied).catalogRevision|Should -Be ('a'*40)
        Should -Invoke Write-ItlClientMcpEndpointSet -Times 0 -Exactly
    }
    It 'includes local preferences and tracked binding in the same plan and restores each owned field' {
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $preferences=@{memoryOptIn=$false;clientOverrides=@{codex=@('code')}}
        $null=Invoke-ItlProductProjectClientApply $context $requests -BindProject -DesiredBinding $binding -SavePrivateSelection -PrivateSelection $preferences
        (Read-ItlProductProjectSetting selection).clientOverrides.codex[0]|Should -Be code
        (Get-ItlProductProjectBinding).projectId|Should -Be fixture
        $selection=ConvertTo-ItlCatalogCanonicalValue (Read-Vibecoding1cMcpSelection);$selection['personalField']='preserve'
        Write-Vibecoding1cMcpSelection $selection
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        Read-ItlProductProjectSetting selection|Should -BeNullOrEmpty
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
        (Read-Vibecoding1cMcpSelection).personalField|Should -Be preserve
    }
    It 'recovers a private-preference receipt gap through the same pinned operation' {
        $selectionPath=Get-Vibecoding1cMcpSelectionPath
        Mock Write-Utf8TextAtomic {
            & $AtomicWriter @PesterBoundParameters
            if($Path -eq $selectionPath -and $Value -match 'memoryOptIn'){throw 'injected preference receipt gap'}
        }
        {Invoke-ItlProductProjectClientApply $context $requests -SavePrivateSelection -PrivateSelection @{memoryOptIn=$false}}|Should -Throw '*preference receipt gap*'
        (Read-ItlProductProjectRecord operation).privateSelection.active|Should -BeTrue
        Test-Path -LiteralPath (Get-ItlProductProjectPath applied)|Should -BeFalse
        Mock Write-Utf8TextAtomic { & $AtomicWriter @PesterBoundParameters }
        $null=Invoke-ItlProductProjectClientApply -Mode resume
        (Read-ItlProductProjectSetting selection).memoryOptIn|Should -BeFalse
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        Read-ItlProductProjectSetting selection|Should -BeNullOrEmpty
    }
    It 'previews through the real writer, rejects a post-decision race and accepts only explicitly owned keys' {
        Write-ItlClientMcpEndpointSet @(@{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='code';url='https://old.invalid'})}) *> $null
        $path=Join-Path $root '.mcp.json'
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('https://old.invalid','https://manual.invalid'))
        $desired=@(@{client='claude-code';owner='vibecoding1c';acceptedOwnedKeys=@('code');endpoints=@(@{name='code';url='https://new.invalid'})})
        $plan=Write-ItlClientMcpEndpointSet $desired -PreserveUserChanges -ReturnPlan
        $plan.projections[0].entries.code.url|Should -Be 'https://new.invalid'
        (Read-ItlClientMcpEntries claude-code).code.url|Should -Be 'https://manual.invalid'
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('manual.invalid','later.invalid'))
        {Invoke-ItlProductProjectClientApply $context $desired -ExpectedInputStates $plan.fileStates -ExpectedOwnerState $plan.ownerState}|Should -Throw '*CLIENT_MCP_PREVIEW_CHANGED*'
        Test-Path -LiteralPath (Get-ItlProductProjectPath operation)|Should -BeFalse
        $plan=Write-ItlClientMcpEndpointSet $desired -PreserveUserChanges -ReturnPlan
        $null=Invoke-ItlProductProjectClientApply $context $desired -ExpectedInputStates $plan.fileStates -ExpectedOwnerState $plan.ownerState
        (Read-ItlClientMcpEntries claude-code).code.url|Should -Be 'https://new.invalid'
        {Write-ItlClientMcpEndpointSet @(@{client='claude-code';owner='vibecoding1c';acceptedOwnedKeys=@('unowned');endpoints=@(@{name='unowned';url='https://invalid.invalid'})}) -ReturnPlan}|Should -Throw '*cannot take ownership*'
    }
    It 'requires a decision before writes for a real three-way conflict' {
        $old=@(@{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='code';url='https://old.invalid'})})
        $null=Invoke-ItlProductProjectClientApply $context $old
        $path=Join-Path $root '.mcp.json'
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('old.invalid','manual.invalid'))
        Mock Get-Vibecoding1cMcpClientConfigEndpointSet {return @{allEndpoints=@(@{id='fixture-source';name='code';url='https://new.invalid'})}}
        $before=Get-ItlMcpFileState $path
        $changed=ConvertTo-ItlCatalogCanonicalValue $context;$changed.catalogRevision=('b'*40);$changed.settingsHash='settings-b'
        $preview=New-ItlProductProjectPreview $changed @('claude-code')
        $preview.changes[0].status|Should -Be conflict
        {Resolve-ItlProductProjectPreviewDecision $preview}|Should -Throw '*CATALOG_CONFLICT_NEEDS_USER_ACTION*'
        (Get-ItlMcpFileState $path)|Should -Be $before
        (Read-ItlProductProjectRecord applied).catalogRevision|Should -Be ('a'*40)
    }
    It 'persists keep-local and does not ask again on the next update' {
        $old=@(@{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='code';url='https://old.invalid'})})
        $null=Invoke-ItlProductProjectClientApply $context $old
        $path=Join-Path $root '.mcp.json';Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('old.invalid','manual.invalid'))
        Mock Get-Vibecoding1cMcpClientConfigEndpointSet {return @{allEndpoints=@(@{id='fixture-source';name='code';url='https://new.invalid'})}}
        $changed=ConvertTo-ItlCatalogCanonicalValue $context;$changed.catalogRevision=('b'*40);$changed.settingsHash='settings-b'
        $preview=New-ItlProductProjectPreview $changed @('claude-code')
        $decision=Resolve-ItlProductProjectPreviewDecision $preview keep-local
        $null=Invoke-ItlProductProjectClientApply $decision.context $decision.requests -SavePrivateSelection -PrivateSelection $decision.preferences -ExpectedInputStates $preview.plan.fileStates -ExpectedOwnerState $preview.plan.ownerState
        (Read-ItlClientMcpEntries claude-code).code.url|Should -Be 'https://manual.invalid'
        $next=New-ItlProductProjectPreview $changed @('claude-code')
        @($next.changes|Where-Object status -eq conflict).Count|Should -Be 0
        {Resolve-ItlProductProjectPreviewDecision $next}|Should -Not -Throw
    }
    It 'accepts catalog settings only for the approved conflicted owner keys' {
        $old=@(@{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='code';url='https://old.invalid'})})
        $null=Invoke-ItlProductProjectClientApply $context $old
        $path=Join-Path $root '.mcp.json';Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('old.invalid','manual.invalid'))
        Mock Get-Vibecoding1cMcpClientConfigEndpointSet {return @{allEndpoints=@(@{id='fixture-source';name='code';url='https://new.invalid'})}}
        $changed=ConvertTo-ItlCatalogCanonicalValue $context;$changed.catalogRevision=('b'*40);$changed.settingsHash='settings-b'
        $preview=New-ItlProductProjectPreview $changed @('claude-code')
        $decision=Resolve-ItlProductProjectPreviewDecision $preview registry
        $null=Invoke-ItlProductProjectClientApply $decision.context $decision.requests -SavePrivateSelection -PrivateSelection $decision.preferences -ExpectedInputStates $preview.plan.fileStates -ExpectedOwnerState $preview.plan.ownerState
        (Read-ItlClientMcpEntries claude-code).code.url|Should -Be 'https://new.invalid'
    }
    It 'defers all changes on the old revision without reverting the current manual edit' {
        $old=@(@{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='code';url='https://old.invalid'})})
        $null=Invoke-ItlProductProjectClientApply $context $old
        $path=Join-Path $root '.mcp.json';Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('old.invalid','manual.invalid'))
        Mock Get-Vibecoding1cMcpClientConfigEndpointSet {return @{allEndpoints=@(@{id='fixture-source';name='code';url='https://new.invalid'})}}
        $changed=ConvertTo-ItlCatalogCanonicalValue $context;$changed.catalogRevision=('b'*40);$changed.settingsHash='settings-b'
        $preview=New-ItlProductProjectPreview $changed @('claude-code')
        $decision=Resolve-ItlProductProjectPreviewDecision $preview defer
        $before=Get-ItlMcpFileState $path
        $null=Invoke-ItlProductProjectClientApply $decision.context $decision.requests -ProofRequests $decision.proofRequests -SavePrivateSelection -PrivateSelection $decision.preferences -ExpectedInputStates $preview.plan.fileStates -ExpectedOwnerState $preview.plan.ownerState
        (Get-ItlMcpFileState $path)|Should -Be $before
        (Read-ItlProductProjectRecord applied).catalogRevision|Should -Be ('a'*40)
        (Read-ItlProductProjectSetting selection).defer.settingsIntentHash|Should -Be $preview.settingsIntentHash
        $decision.deferred|Should -BeTrue
    }
    It 'distinguishes arrays from scalar policy values in native proof' {
        (Get-ItlMcpOwnedSemanticSignature @{entry=@{args=@('one')}} @('entry'))|Should -Not -Be (Get-ItlMcpOwnedSemanticSignature @{entry=@{args='one'}} @('entry'))
        (Get-ItlMcpOwnedSemanticSignature @{entry=@{args=@()}} @('entry'))|Should -Not -Be (Get-ItlMcpOwnedSemanticSignature @{entry=@{args=$null}} @('entry'))
    }
    It 'runs one startup resolve/apply then performs no client writes on no-op and publisher-only changes' {
        $snapshot=New-StartupCatalogFixture
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        Mock Read-ItlProductProjectSnapshot {return $snapshot}
        Mock Read-Vibecoding1cMcpRegistry {return $snapshot.registry}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Mock Update-Vibecoding1cMcpRegistryCheckout {throw 'unexpected network refresh'}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        $key=ConvertTo-ItlClientMcpKey '1c-code-metadata-mcp' codex
        (Read-ItlClientMcpEntries codex)[$key].url|Should -Be 'https://source.invalid/mcp'
        $first=Read-ItlProductProjectRecord applied
        Mock Write-ItlClientMcpEndpoints {if(-not $PlanOnly){throw 'unexpected no-op client write'};& $LowLevelWriter @PesterBoundParameters}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        (Read-ItlProductProjectRecord applied).operationId|Should -Be $first.operationId
        $snapshot.catalogRevision=('b'*40);$snapshot.registry['publishedAt']='publisher-only'
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        (Read-ItlProductProjectRecord applied).catalogRevision|Should -Be ('b'*40)
        Should -Invoke Read-ItlProductProjectSnapshot -Times 3 -Exactly
        Should -Invoke Update-Vibecoding1cMcpRegistryCheckout -Times 0 -Exactly
    }
    It 'continues offline with a validated applied context and blocks no-cache without guessing IDs' {
        $snapshot=New-StartupCatalogFixture
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        Mock Read-ItlProductProjectSnapshot {return $snapshot}
        Mock Read-Vibecoding1cMcpRegistry {return $snapshot.registry}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        $previous=Read-ItlProductProjectRecord applied
        Mock Read-ItlProductProjectSnapshot {throw 'fixture offline'}
        Mock Read-ItlProductCatalogSnapshot {return $snapshot}
        Mock Write-ItlClientMcpEndpointSet {throw 'unexpected offline writer'}
        Invoke-Vibecoding1cMcpRegistryOperation {
            {Initialize-ItlProductProjectContext}|Should -Not -Throw
            (Get-ItlProductProjectOperationContext).catalogRevision|Should -Be $previous.catalogRevision
        }
        Should -Invoke Write-ItlClientMcpEndpointSet -Times 0 -Exactly
        # A separate new local root has no applied baseline; the same offline
        # condition must not manufacture a project, product or fresh binding.
        $next=Join-Path $TestDrive 'No baseline'
        [void][IO.Directory]::CreateDirectory((Join-Path $next '.agent-1c'))
        $script:ProjectRoot=$next;$script:ConfigPath=Join-Path $next '.agent-1c/project.json'
        Write-Utf8TextAtomic $script:ConfigPath (@{productProject=$binding;aiRules=@{tools=@('codex')}}|ConvertTo-Json -Depth 10)
        Read-ProjectConfig
        Invoke-Vibecoding1cMcpRegistryOperation {{Initialize-ItlProductProjectContext}|Should -Throw '*fixture offline*'}
        Test-Path -LiteralPath (Get-ItlProductProjectPath applied)|Should -BeFalse
    }
    It 'blocks an unfinished initial association before main even without a tracked binding' {
        Mock Write-ItlClientMcpEndpoints {
            $value=& $LowLevelWriter @PesterBoundParameters
            if($ReturnReceipt -and $Client -eq 'codex'){throw 'injected initial interruption'}
            return $value
        }
        {Invoke-ItlProductProjectClientApply $context $requests}|Should -Throw '*initial interruption*'
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
        Mock Read-ItlProductProjectSnapshot {throw 'unexpected pending refresh'}
        Invoke-Vibecoding1cMcpRegistryOperation {{Initialize-ItlProductProjectContext}|Should -Throw '*CATALOG_OPERATION_PENDING*'}
        Should -Invoke Read-ItlProductProjectSnapshot -Times 0 -Exactly
        $probe=Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @('-ProjectRoot',$root,'-Action','sync-client-mcp','-Client','codex')
        $probe.exitCode|Should -Be 1
        $probe.combinedText|Should -Match 'CATALOG_OPERATION_PENDING'
        $diagnostic=Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @('-ProjectRoot',$root,'-Action','vibecoding1c-mcp-status','-CatalogAction','status')
        $diagnostic.exitCode|Should -Be 0
    }
    It 'keeps diagnostics available for a damaged applied record without deleting state' {
        $null=Invoke-ItlProductProjectClientApply $context $requests
        $path=Get-ItlProductProjectPath applied
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('settings-a','tampered'))
        {Read-ItlProductProjectRecord applied}|Should -Throw '*CATALOG_LOCAL_RECORD_INVALID*'
        (Invoke-ItlProductProjectRecovery status).status|Should -Be invalid-applied
        Test-Path -LiteralPath $path|Should -BeTrue
        $null=Invoke-ItlProductProjectClientApply -Mode restore
        Test-Path -LiteralPath $path|Should -BeFalse
    }
}
