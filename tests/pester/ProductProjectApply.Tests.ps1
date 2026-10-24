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
    It 'restores Kilo alias masks and the exact prior native entries for <AlreadyMasked>' -ForEach @(@{AlreadyMasked=$false},@{AlreadyMasked=$true}) {
        $old=@(@{name='1c-code-metadata-mcp';url='https://old.invalid/mcp'})
        if($AlreadyMasked){Write-ItlClientMcpEndpointSet @(@{client='kilocode';owner='vibecoding1c';endpoints=$old}) *> $null}
        else {Write-ItlClientMcpEndpoints -Client kilocode -Owner vibecoding1c -Endpoints $old *> $null}
        $before=Read-Utf8Text (Join-Path $root '.kilo/kilo.json')
        $null=Invoke-ItlProductProjectClientApply $context @(@{client='kilocode';owner='vibecoding1c';endpoints=@(@{name='1c-code-metadata-mcp';url='https://new.invalid/mcp'},@{name='1c-graph-metadata-mcp';url='https://graph.invalid/mcp/'})})
        (Read-ItlClientMcpEntries kilocode)['onec-code-metadata-mcp'].enabled|Should -BeFalse
        (Read-ItlClientMcpEntries kilocode)['onec-graph-metadata-mcp'].enabled|Should -BeFalse
        (Invoke-ItlProductProjectClientApply -Mode restore).status|Should -Be restored
        # JSON member ordering is not part of the native settings contract.
        # Compare every native field, including the disabled masks, not only URLs.
        (Get-ItlCatalogHash (Read-Utf8Text (Join-Path $root '.kilo/kilo.json')|ConvertFrom-Json))|Should -BeExactly (Get-ItlCatalogHash ($before|ConvertFrom-Json))
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
    It 'preserves exact surrounding JSON bytes and planned output through <Client>' -Tag G3ForeignBytes -ForEach @(@{Client='cursor'},@{Client='kilocode'},@{Client='zcode'}) {
        $old=@(@{client=$Client;owner='vibecoding1c';endpoints=@(@{name='owned';url='https://old.invalid'})})
        Write-ItlClientMcpEndpointSet $old *> $null
        $adapter=Get-ItlClientAdapter $Client;$path=Join-Path $root $adapter.mcpPath
        $open=(@($adapter.mcpContainer.Split('.')|ForEach-Object {'"'+$_+'": {'}) -join '')
        $close='}'*$adapter.mcpContainer.Split('.').Count
        $prefix=[string][char]0xfeff+"{`r`n"+' "otherRoot": {"escaped":"\u0410","number":1.00},'+"`n"+$open+"`r`n"+' "z-foreign": { "args": ["Путь с пробелом"], "url":"https://user/a,}" },'+"`n"+' "owned": '
        $suffix=","+"`r`n"+' "a-external": {"z":true, "a":false}'+"`n"+$close+","+"`r`n"+' "permission": {"*":"ask"}'+"`r`n}`r`n"
        $entry=(Read-ItlClientMcpEntries $Client).owned|ConvertTo-Json -Depth 20 -Compress
        $utf8=[Text.UTF8Encoding]::new($false,$true)
        [IO.File]::WriteAllBytes($path,$utf8.GetBytes($prefix+$entry+$suffix))
        $before=Get-ItlMcpFileState $path;$ticks=[IO.File]::GetLastWriteTimeUtc($path).Ticks
        $new=@{Client=$Client;Owner='vibecoding1c';Endpoints=@(@{name='owned';url='https://new.invalid'})}
        $plan=Write-ItlClientMcpEndpoints @new -PlanOnly
        (Get-ItlMcpFileState $path)|Should -BeExactly $before
        [IO.File]::GetLastWriteTimeUtc($path).Ticks|Should -Be $ticks
        $receipt=Write-ItlClientMcpEndpoints @new -ReturnReceipt
        $actual=$utf8.GetString([IO.File]::ReadAllBytes($path))
        $actual.StartsWith($prefix,[StringComparison]::Ordinal)|Should -BeTrue
        $actual.EndsWith($suffix,[StringComparison]::Ordinal)|Should -BeTrue
        (Read-ItlClientMcpEntries $Client).owned.url|Should -BeExactly 'https://new.invalid'
        (Get-ItlMcpFileState $path)|Should -BeExactly $plan.afterFiles[$path]
        $receipt.fileState|Should -BeExactly $plan.afterFiles[$path]
        $before=Get-ItlMcpFileState $path;$ticks=[IO.File]::GetLastWriteTimeUtc($path).Ticks
        Write-ItlClientMcpEndpoints @new *> $null
        (Get-ItlMcpFileState $path)|Should -BeExactly $before
        [IO.File]::GetLastWriteTimeUtc($path).Ticks|Should -Be $ticks
    }
    It 'keeps an external append in place after partial <Recovery>' -Tag G3ForeignBytes -ForEach @(@{Recovery='resume'},@{Recovery='restore'}) {
        $old=@(foreach($client in @('kilocode','cursor')){@{client=$client;owner='vibecoding1c';endpoints=@(@{name='1c-graph-metadata-mcp';url='https://old.invalid'})}})
        $null=Invoke-ItlProductProjectClientApply $context $old
        $path=Join-Path $root '.kilo/kilo.json';$utf8=[Text.UTF8Encoding]::new($false,$true)
        $text=$utf8.GetString([IO.File]::ReadAllBytes($path));$doc=Read-ItlJsoncDocument $text;$node=@($doc.Root.Members|Where-Object Name -CEQ 'mcp')[0].Value
        $anchor='"z-user": { "path":"C:\\Путь с пробелом", "z":1.00 }'
        [IO.File]::WriteAllBytes($path,$utf8.GetBytes($text.Insert($node.End-1,','+$anchor)))
        $next=$context.Clone();$next.catalogRevision='b'*40
        $desired=@(foreach($client in @('kilocode','cursor')){@{client=$client;owner='vibecoding1c';endpoints=@(@{name='1c-graph-metadata-mcp';url='https://new.invalid'})}})
        Mock Write-ItlClientMcpEndpoints {if($Client -eq 'cursor' -and -not $PlanOnly){throw 'controlled fault before B write'};& $LowLevelWriter @PesterBoundParameters}
        {Invoke-ItlProductProjectClientApply $next $desired}|Should -Throw '*controlled fault before B*'
        $op=Read-ItlProductProjectRecord operation;$op.activeWrite.client|Should -Be cursor
        $text=$utf8.GetString([IO.File]::ReadAllBytes($path));$doc=Read-ItlJsoncDocument $text;$node=@($doc.Root.Members|Where-Object Name -CEQ 'mcp')[0].Value
        $foreign='"g3-race-foreign-'+$Recovery+'": { "url":"https://external.invalid", "enabled":false }'
        [IO.File]::WriteAllBytes($path,$utf8.GetBytes($text.Insert($node.End-1,','+$foreign)))
        Mock Write-ItlClientMcpEndpoints {& $LowLevelWriter @PesterBoundParameters}
        $result=Invoke-ItlProductProjectClientApply -Mode $Recovery
        $result.status|Should -Be $(if($Recovery -eq 'resume'){'configured'}else{'restored'})
        $after=$utf8.GetString([IO.File]::ReadAllBytes($path))
        $after.Contains($foreign)|Should -BeTrue
        $after.IndexOf('"z-user"')|Should -BeLessThan $after.IndexOf('"g3-race-foreign-')
        (Read-ItlProductProjectRecord operation).operationId|Should -BeExactly $op.operationId
        (Read-ItlProductProjectRecord operation).context.catalogRevision|Should -BeExactly ('b'*40)
        (Read-ItlClientMcpEntries kilocode).'1c-graph-metadata-mcp'.url|Should -BeExactly $(if($Recovery -eq 'resume'){'https://new.invalid'}else{'https://old.invalid'})
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
    It 'recovers a zero-client-write defer through <Recovery> while preserving <Damage>' -Tag G3DeferRestore -ForEach @(
        @{Recovery='restore';Damage='none'},
        @{Recovery='resume';Damage='none'},
        @{Recovery='restore';Damage='selection'},
        @{Recovery='restore';Damage='owned-client-entry'}
    ) {
        $old=@(@{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='code';url='https://old.invalid'},@{name='stable';url='https://stable.invalid'})})
        $null=Invoke-ItlProductProjectClientApply $context $old
        $prior=Get-ItlCatalogHash (Read-ItlProductProjectRecord applied)
        $path=Join-Path $root '.mcp.json'
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('old.invalid','manual.invalid'))
        Mock Get-Vibecoding1cMcpClientConfigEndpointSet {return @{allEndpoints=@(@{id='fixture-code';name='code';url='https://new.invalid'},@{id='fixture-stable';name='stable';url='https://stable.invalid'})}}
        $changed=ConvertTo-ItlCatalogCanonicalValue $context;$changed.catalogRevision=('b'*40);$changed.settingsHash='settings-b'
        $preview=New-ItlProductProjectPreview $changed @('claude-code')
        $decision=Resolve-ItlProductProjectPreviewDecision $preview defer
        @($decision.requests).Count|Should -Be 0
        $null=Invoke-ItlProductProjectClientApply $decision.context $decision.requests -ProofRequests $decision.proofRequests -SavePrivateSelection -PrivateSelection $decision.preferences -ExpectedInputStates $preview.plan.fileStates -ExpectedOwnerState $preview.plan.ownerState
        $operation=Read-ItlProductProjectRecord operation
        $operation.status|Should -Be completed
        $operation.prepared|Should -BeFalse
        if($Recovery -eq 'resume'){
            # Legacy receipts can retain the failed first restore transition.
            $operation.status='partial';$operation.direction='restore'
            Write-ItlProductProjectRecord operation $operation
        }
        if($Damage -eq 'selection'){
            $selection=ConvertTo-ItlCatalogCanonicalValue (Read-ItlProductProjectSetting selection)
            $changedSelection=ConvertTo-ItlCatalogCanonicalValue $selection
            $changedSelection['conditionValues']=@{userFlag=$true}
            Set-ItlProductProjectSetting selection $changedSelection $selection
        }elseif($Damage -eq 'owned-client-entry'){
            Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('stable.invalid','external.invalid'))
        }
        $clientBefore=Get-ItlMcpFileState $path
        $selectionBefore=Get-ItlMcpFileState (Get-Vibecoding1cMcpSelectionPath)
        if($Damage -ne 'none'){
            $errorCode=if($Damage -eq 'selection'){'*CATALOG_SETTING_CONFLICT*'}else{'*CATALOG_CLIENT_CONFLICT*'}
            {Invoke-ItlProductProjectRecovery $Recovery}|Should -Throw $errorCode
            (Get-ItlMcpFileState (Get-Vibecoding1cMcpSelectionPath))|Should -BeExactly $selectionBefore
        }else{
            (Invoke-ItlProductProjectRecovery $Recovery).status|Should -Be restored
            (Get-ItlCatalogHash (Read-ItlProductProjectRecord applied))|Should -BeExactly $prior
            (Read-ItlProductProjectSetting selection)|Should -BeNullOrEmpty
        }
        (Get-ItlMcpFileState $path)|Should -BeExactly $clientBefore
    }
    It 'preserves defer through the ordinary MCP writer on the pinned applied context until an explicit registry decision' -Tag 'G3PinnedDefer' {
        $snapshot=New-StartupCatalogFixture
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        Mock Read-ItlProductProjectSnapshot {return $snapshot}
        Mock Read-Vibecoding1cMcpRegistry {return $snapshot.registry}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        $path=Join-Path $root '.codex/config.toml'
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('source.invalid','manual.invalid'))
        $snapshot.catalogRevision=('b'*40)
        $snapshot.registry.hosts[0].servers[0].url='https://changed.invalid/mcp'
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext -Decision defer}
        $preferences=Get-ItlCatalogHash (Read-ItlProductProjectSetting selection)
        $codeKey=ConvertTo-ItlClientMcpKey '1c-code-metadata-mcp' codex
        $protected=@($path,$script:ConfigPath,(Get-ItlProductProjectPath applied),(Get-ItlProductProjectPath operation),(Get-ItlManagedMcpStatePath),(Get-Vibecoding1cMcpSelectionPath))
        $before=@{};foreach($file in $protected){$before[$file]=@{state=(Get-ItlMcpFileState $file);ticks=(Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks}}
        1..2|ForEach-Object {
            Invoke-Vibecoding1cMcpRegistryOperation {
                Initialize-ItlProductProjectContext
                Write-Vibecoding1cMcpClientConfig -Client codex
            }
            (Get-ItlCatalogHash (Read-ItlProductProjectSetting selection))|Should -BeExactly $preferences
            (Read-ItlProductProjectSetting selection).defer.catalogRevision|Should -Be ('a'*40)
            (Read-ItlProductProjectRecord applied).catalogRevision|Should -Be ('a'*40)
            (Read-ItlClientMcpEntries codex)[$codeKey].url|Should -Be 'https://manual.invalid/mcp'
            foreach($file in $protected){
                (Get-ItlMcpFileState $file)|Should -BeExactly $before[$file].state
                (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks|Should -Be $before[$file].ticks
            }
        }
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext -Decision registry}
        (ConvertTo-Vibecoding1cMcpHashtable (Read-ItlProductProjectSetting selection)).Contains('defer')|Should -BeFalse
        (Read-ItlProductProjectRecord applied).catalogRevision|Should -Be ('b'*40)
        (Read-ItlClientMcpEntries codex)[$codeKey].url|Should -Be 'https://changed.invalid/mcp'
    }
    It 'distinguishes arrays from scalar policy values in native proof' {
        (Get-ItlMcpOwnedSemanticSignature @{entry=@{args=@('one')}} @('entry'))|Should -Not -Be (Get-ItlMcpOwnedSemanticSignature @{entry=@{args='one'}} @('entry'))
        (Get-ItlMcpOwnedSemanticSignature @{entry=@{args=@()}} @('entry'))|Should -Not -Be (Get-ItlMcpOwnedSemanticSignature @{entry=@{args=$null}} @('entry'))
    }
    It 'adopts publisher-only through the existing journal without preview and restores the exact prior context' -Tag G3PublisherOnlyCost {
        $snapshot=New-StartupCatalogFixture
        $snapshot.inputGitObjectIds=@{'registry.json'= ('3'*40);'catalog/catalog.json'= ('1'*40);'catalog/product-relations.json'= ('2'*40)}
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        Mock Read-ItlProductProjectSnapshot {return $snapshot}
        Mock Read-Vibecoding1cMcpRegistry {return $snapshot.registry}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        $before=Read-ItlProductProjectRecord applied
        $protected=@(Get-ItlClientMcpConfigPaths codex)+@(Get-ItlClientMcpConfigPaths claude-code)
        $states=@{};foreach($path in $protected){if(Test-Path -LiteralPath $path){$states[$path]=@{hash=Get-ItlMcpFileState $path;ticks=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks}}}
        $snapshot['checkedNoOpInputs']=Get-ItlProductProjectNoOpInputs $before.proof
        $snapshot.catalogRevision=('b'*40);$snapshot.inputGitObjectIds['registry.json']=('4'*40);$snapshot.registry['publishedAt']='publisher-only'
        Mock New-ItlProductProjectPreview {throw 'publisher-only must not rebuild the client preview'}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        $after=Read-ItlProductProjectRecord applied
        $after.catalogRevision|Should -Be ('b'*40)
        $after.context.inputGitObjectIds['registry.json']|Should -Be ('4'*40)
        $after.context.catalogPublication.baseRevision|Should -Be ('b'*40)
        $after.context.registryMetadata.publishedAt|Should -Be publisher-only
        $after.contextHash|Should -BeExactly (Get-ItlCatalogHash $after.context)
        $after.operationId|Should -Not -Be $before.operationId
        (Read-ItlProductProjectSetting selection).catalogRevision|Should -Be ('b'*40)
        (Read-ItlProductProjectRecord operation).status|Should -Be completed
        (Invoke-ItlProductProjectClientApply -Mode resume).status|Should -Be configured
        (Invoke-ItlProductProjectClientApply -Mode restore).status|Should -Be restored
        (Get-ItlCatalogHash (Read-ItlProductProjectRecord applied))|Should -BeExactly (Get-ItlCatalogHash $before)
        foreach($path in $states.Keys){(Get-ItlMcpFileState $path)|Should -BeExactly $states[$path].hash;(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks|Should -Be $states[$path].ticks}
        Should -Invoke New-ItlProductProjectPreview -Times 0 -Exactly
    }
    It 'keeps publisher-only file races outside the freshness fallback' -Tag G3PublisherOnlyCost {
        $snapshot=New-StartupCatalogFixture
        $snapshot.inputGitObjectIds=@{'registry.json'= ('3'*40);'catalog/catalog.json'= ('1'*40);'catalog/product-relations.json'= ('2'*40)}
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        Mock Read-ItlProductProjectSnapshot {return $snapshot}
        Mock Read-Vibecoding1cMcpRegistry {return $snapshot.registry}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        $prior=Read-ItlProductProjectRecord applied
        $snapshot['checkedNoOpInputs']=Get-ItlProductProjectNoOpInputs $prior.proof
        $snapshot.catalogRevision=('b'*40);$snapshot.registry['publishedAt']='publisher-only'
        $path=Join-Path $root '.codex/config.toml'
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('source.invalid','external.invalid'))
        $foreign=Get-ItlMcpFileState $path
        Invoke-Vibecoding1cMcpRegistryOperation {{Initialize-ItlProductProjectContext}|Should -Throw '*CLIENT_MCP_PREVIEW_CHANGED*'}
        (Get-ItlMcpFileState $path)|Should -BeExactly $foreign
        (Get-ItlCatalogHash (Read-ItlProductProjectRecord applied))|Should -BeExactly (Get-ItlCatalogHash $prior)
    }
    It 'uses the already validated pinned snapshot offline without resolve or a second Git decode' -Tag G3PublisherOnlyCost {
        $snapshot=New-StartupCatalogFixture
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='fixture';productId='corp'}
        $null=Invoke-ItlProductProjectClientApply $context @() -BindProject -DesiredBinding $binding
        Mock Read-ItlProductProjectSnapshot {return $snapshot}
        Mock Read-Vibecoding1cMcpRegistry {return $snapshot.registry}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        $prior=Read-ItlProductProjectRecord applied
        $snapshot['stale']=$true
        Mock Read-ItlProductProjectSnapshot { $state=(Get-Variable ItlMcpRegistryOperation -Scope Script).Value;$state['catalogSnapshot']=$snapshot;return $snapshot }
        Mock Resolve-ItlProductProjectRuntimeContext {throw 'offline must not resolve again'}
        Mock Read-ItlProductCatalogSnapshot {throw 'offline must not decode the same snapshot again'}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        (Get-ItlCatalogHash (Read-ItlProductProjectRecord applied))|Should -BeExactly (Get-ItlCatalogHash $prior)
        Should -Invoke Resolve-ItlProductProjectRuntimeContext -Times 0 -Exactly
        Should -Invoke Read-ItlProductCatalogSnapshot -Times 0 -Exactly
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
    It 'resumes a valid completed operation without writes or another registry read' -Tag G3CompletedResume {
        $result=Invoke-ItlProductProjectClientApply $context $requests
        $paths=@((Get-ItlProductProjectPath applied),(Get-ItlProductProjectPath operation))+@(Get-ItlClientMcpConfigPaths codex)+@(Get-ItlClientMcpConfigPaths claude-code)
        $before=@(foreach($path in $paths){@{path=$path;state=(Get-ItlMcpFileState $path);ticks=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks}})
        Mock Write-ItlProductProjectRecord {throw 'unexpected completed receipt write'}
        Mock Write-ItlClientMcpEndpointSet {throw 'unexpected completed client write'}
        Mock Read-ItlProductProjectSnapshot {throw 'unexpected completed registry read'}
        $resumed=Invoke-ItlProductProjectRecovery resume
        $resumed.status|Should -Be configured
        $resumed.operationId|Should -BeExactly $result.operationId
        $after=@(foreach($path in $paths){@{path=$path;state=(Get-ItlMcpFileState $path);ticks=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks}})
        (Get-ItlCatalogHash $after)|Should -BeExactly (Get-ItlCatalogHash $before)
        Should -Invoke Write-ItlProductProjectRecord -Times 0 -Exactly
        Should -Invoke Write-ItlClientMcpEndpointSet -Times 0 -Exactly
        Should -Invoke Read-ItlProductProjectSnapshot -Times 0 -Exactly
    }
    It 'rejects a completed resume with <Damage> applied state and restores the durable prior context' -Tag G3CompletedResume -ForEach @(
        @{Damage='hash'},@{Damage='missing'},@{Damage='operation'},@{Damage='revision'},@{Damage='context'}) {
        $null=Invoke-ItlProductProjectClientApply $context $requests
        $previous=Read-ItlProductProjectRecord applied
        $changed=ConvertTo-ItlCatalogCanonicalValue $context;$changed.knowledgeHash='knowledge-next'
        $result=Invoke-ItlProductProjectClientApply $changed @()
        $path=Get-ItlProductProjectPath applied
        $applied=Read-ItlProductProjectRecord applied
        switch($Damage){
            hash {$applied.contextHash=('0'*64)}
            operation {$applied.operationId='another-completed-operation'}
            revision {$applied.catalogRevision=('b'*40);$applied.context.catalogRevision=('b'*40);$applied.contextHash=Get-ItlCatalogHash $applied.context}
            context {$applied.context.knowledgeHash='another-valid-context';$applied.contextHash=Get-ItlCatalogHash $applied.context}
        }
        if($Damage -eq 'missing'){Remove-Item -LiteralPath $path}else{Write-ItlProductProjectRecord applied $applied}
        $paths=@($path,(Get-ItlProductProjectPath operation))+@(Get-ItlClientMcpConfigPaths codex)+@(Get-ItlClientMcpConfigPaths claude-code)
        $before=@(foreach($p in $paths){@{path=$p;state=(Get-ItlMcpFileState $p);ticks=$(if(Test-Path -LiteralPath $p){(Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks}else{$null})}})
        {Invoke-ItlProductProjectRecovery resume}|Should -Throw '*CATALOG_COMPLETED_RESUME_NEEDS_RESTORE*CatalogAction restore*'
        $after=@(foreach($p in $paths){@{path=$p;state=(Get-ItlMcpFileState $p);ticks=$(if(Test-Path -LiteralPath $p){(Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks}else{$null})}})
        (Get-ItlCatalogHash $after)|Should -BeExactly (Get-ItlCatalogHash $before)
        (Read-ItlProductProjectRecord operation).operationId|Should -BeExactly $result.operationId
        (Invoke-ItlProductProjectRecovery status).operationId|Should -BeExactly $result.operationId
        (Invoke-ItlProductProjectRecovery restore).status|Should -Be restored
        (Get-ItlCatalogHash (Read-ItlProductProjectRecord applied))|Should -BeExactly (Get-ItlCatalogHash $previous)
    }
    It 'validates the expected original marker when resuming completed compatibility restore with <OriginalMarker>' -Tag G3CompletedResume -ForEach @(
        @{OriginalMarker=$false},@{OriginalMarker=$true}) {
        if($OriginalMarker){
            $null=Invoke-ItlProductProjectClientApply $context $requests
            # A valid pre-association marker without an earlier compatibility
            # baseline becomes the actual original marker of the next apply.
            $original=Read-ItlProductProjectRecord applied;$original.Remove('compatibilityBaseline')
            Write-ItlProductProjectRecord applied $original
        }
        $next=ConvertTo-ItlCatalogCanonicalValue $context;$next.knowledgeHash='knowledge-next'
        $null=Invoke-ItlProductProjectClientApply $next $requests
        (Invoke-ItlProductProjectRecovery restore-compatible).status|Should -Be compatible-restored
        $before=Get-ItlMcpFileState (Get-ItlProductProjectPath applied)
        (Invoke-ItlProductProjectRecovery resume).status|Should -Be compatible-restored
        (Get-ItlMcpFileState (Get-ItlProductProjectPath applied))|Should -BeExactly $before
        if($OriginalMarker){
            $record=Read-ItlProductProjectRecord applied;$record.contextHash=('0'*64)
            Write-ItlProductProjectRecord applied $record
        }else{
            $operation=Read-ItlProductProjectRecord operation
            Write-ItlProductProjectRecord applied @{schemaVersion=1;projectRoot=$root;operationId='unexpected';catalogRevision=$operation.context.catalogRevision;context=$operation.context;contextHash=(Get-ItlCatalogHash $operation.context)}
        }
        {Invoke-ItlProductProjectRecovery resume}|Should -Throw '*CATALOG_COMPLETED_RESUME_NEEDS_RESTORE*'
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
