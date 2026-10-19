Describe 'Pinned catalog apply uses the common MCP writer and its physical proofs' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $HelperPath=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        $RuntimePath=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-runtime.ps1'
    }
    BeforeEach {
        $caseClient=if(Get-Variable Client -ErrorAction SilentlyContinue){$Client}else{''}
        $root=Join-Path $TestDrive ('Локальный проект '+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root '.agent-1c'))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{"aiRules":{"tools":["codex","claude-code"]}}',[Text.UTF8Encoding]::new($false))
        . $HelperPath -ProjectRoot $root -Action help *> $null
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-catalog.ps1')
        . $RuntimePath
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
}
