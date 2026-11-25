BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    $HelperPath = Join-Path $RepoRoot 'scripts\source-maintenance-context.ps1'
    $Utf8NoBom = [Text.UTF8Encoding]::new($false)
    $Cyrillic = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0L/Rg9GC0Yw='))

    function New-SourceContextRepository {
        param([string]$Name = 'context repo')

        $root = Join-Path $TestDrive ("$Name $Cyrillic " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        & git -C $root init --quiet -b main
        if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize test repository.' }
        & git -C $root config user.name 'ITL Test'
        & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'base', $Utf8NoBom)
        & git -C $root add -- tracked.txt
        & git -C $root commit --quiet -m base
        if ($LASTEXITCODE -ne 0) { throw 'Unable to create test base commit.' }
        return $root
    }

    function Get-SourceContextCommonDirectory {
        param([string]$Root)
        $marker = Join-Path $Root '.git'
        if (Test-Path -LiteralPath $marker -PathType Container) { return [IO.Path]::GetFullPath($marker) }
        $gitLine = ([IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8) -split "`r?`n" | Select-Object -First 1)
        $gitDirectory = [IO.Path]::GetFullPath((Join-Path $Root (($gitLine -replace '^gitdir:\s*','').Trim())))
        $common = [IO.File]::ReadAllText((Join-Path $gitDirectory 'commondir'), [Text.Encoding]::UTF8).Trim()
        return [IO.Path]::GetFullPath((Join-Path $gitDirectory $common))
    }

    function Write-SourceContextPayload {
        param(
            [string]$Root,
            [string]$Name = 'payload',
            [string]$Objective = 'Preserve the exact source-maintenance objective',
            [string]$Stage = 'implementation',
            [string]$NextAction = 'Run the focused regression once',
            [object[]]$Evidence = @([ordered]@{ kind='test'; commandType='focused-pester'; status='pending'; summary='Focused regression is the next evidence' }),
            [string[]]$ChangedPaths = @()
        )

        $payload = [ordered]@{
            objective = $Objective
            scope = @('Wave A manual checkpoint')
            exclusions = @('No rotation', 'No publication')
            stage = $Stage
            approvedPlan = @('Capture state', 'Resume only on exact identity')
            ownerContracts = @('source-maintenance-context')
            changedPaths = @($ChangedPaths)
            decisions = @([ordered]@{ decision='Use common Git state'; reason='It is shared by worktrees and does not dirty them'; rejectedAlternatives=@('tracked handoff') })
            evidence = @($Evidence)
            blockers = @()
            nextAction = $NextAction
            telemetry = [ordered]@{ inputTokens='unknown'; cachedInputTokens='unknown'; compactions=0; resultComplete=$false }
        }
        $path = Join-Path $TestDrive ("$Name-" + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($path, (($payload | ConvertTo-Json -Depth 10) + [Environment]::NewLine), $Utf8NoBom)
        return $path
    }

    function Invoke-SourceContextHelper {
        param([string[]]$HelperArguments)
        $parameters = @{}
        for ($index = 0; $index -lt $HelperArguments.Count; $index++) {
            $name = $HelperArguments[$index].TrimStart('-')
            if ($name -eq 'AdvanceGitState') {
                $parameters[$name] = $true
            } else {
                $index++
                $parameters[$name] = $HelperArguments[$index]
            }
        }
        $text = (& $HelperPath @parameters | Out-String).Trim()
        if (-not $text) { return $null }
        return $text | ConvertFrom-Json
    }

    function Get-SourceContextStatePath {
        param([string]$Root, [string]$TaskId)
        return Join-Path (Get-SourceContextCommonDirectory -Root $Root) ("itl\source-maintenance\v1\" + $TaskId.ToLowerInvariant() + '.json')
    }

    function Get-SourceContextStatusText {
        param([string]$Root)
        return (& git -C $Root status --porcelain=v1 --untracked-files=all) -join "`n"
    }
}

Describe 'Source maintenance durable context' {
    It 'round-trips the exact safe task state in a path with spaces and Cyrillic without dirtying the worktree' {
        $root = New-SourceContextRepository
        $before = Get-SourceContextStatusText -Root $root
        $evidence = @([ordered]@{ kind='test'; commandType='focused-pester'; artifact='build/safe-summary.json'; inputFingerprint='abc123'; status='passed'; recordedAt='2026-09-13T00:00:00Z'; summary='12 passed, 0 failed' })
        $payload = Write-SourceContextPayload -Root $root -Evidence $evidence

        $saved = Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','WF-CTX-01','-RepositoryRoot',$root,'-PayloadPath',$payload)
        $resumed = Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','WF-CTX-01','-RepositoryRoot',$root)

        $saved.status | Should -Be 'saved'
        $saved.path | Should -Be (Get-SourceContextStatePath -Root $root -TaskId 'WF-CTX-01')
        $resumed.status | Should -Be 'resumed'
        $resumed.checkpoint.objective | Should -Be 'Preserve the exact source-maintenance objective'
        @($resumed.checkpoint.scope) | Should -Be @('Wave A manual checkpoint')
        $resumed.checkpoint.stage | Should -Be 'implementation'
        $resumed.checkpoint.evidence[0].summary | Should -Be '12 passed, 0 failed'
        $resumed.checkpoint.nextAction | Should -Be 'Run the focused regression once'
        (Get-SourceContextStatusText -Root $root) | Should -Be $before
    }

    It 'redacts secret assignments and rejects raw output without replacing the valid state' {
        $root = New-SourceContextRepository
        $evidence = @([ordered]@{ kind='diagnostic'; status='passed'; summary='password=hunter2 Bearer abc.def api_key=visible' })
        $payload = Write-SourceContextPayload -Root $root -Evidence $evidence
        $saved = Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','redaction','-RepositoryRoot',$root,'-PayloadPath',$payload)
        $statePath = Get-SourceContextStatePath -Root $root -TaskId 'redaction'
        $text = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8)

        $text | Should -Not -Match 'hunter2|abc\.def|visible'
        $text | Should -Match 'password=\[REDACTED\]'
        $text | Should -Match 'Bearer \[REDACTED\]'
        $rawPayload = [IO.File]::ReadAllText($payload, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $rawPayload.evidence[0] | Add-Member -NotePropertyName rawOutput -NotePropertyValue 'full tool output'
        [IO.File]::WriteAllText($payload, (($rawPayload | ConvertTo-Json -Depth 10) + [Environment]::NewLine), $Utf8NoBom)

        { Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','redaction','-RepositoryRoot',$root,'-PayloadPath',$payload,'-ExpectedStateSha256',$saved.stateSha256) } |
            Should -Throw '*SOURCE_CONTEXT_PAYLOAD_FIELD_FORBIDDEN*'
        (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $saved.stateSha256
        [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | Should -Not -Match 'full tool output'
    }

    It 'preserves the last valid checkpoint when atomic replacement fails' {
        $root = New-SourceContextRepository
        $payload = Write-SourceContextPayload -Root $root -Objective 'valid objective'
        $saved = Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','atomic','-RepositoryRoot',$root,'-PayloadPath',$payload)
        $statePath = Get-SourceContextStatePath -Root $root -TaskId 'atomic'
        $payload = Write-SourceContextPayload -Root $root -Name 'payload-update' -Objective 'replacement objective'
        $previousFault = $env:ITL_SOURCE_CONTEXT_TEST_FAULT
        try {
            $env:ITL_SOURCE_CONTEXT_TEST_FAULT = 'before-replace'
            { Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','atomic','-RepositoryRoot',$root,'-PayloadPath',$payload,'-ExpectedStateSha256',$saved.stateSha256) } |
                Should -Throw '*SOURCE_CONTEXT_TEST_ATOMIC_FAILURE*'
        } finally {
            $env:ITL_SOURCE_CONTEXT_TEST_FAULT = $previousFault
        }

        (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $saved.stateSha256
        (Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','atomic','-RepositoryRoot',$root)).checkpoint.objective | Should -Be 'valid objective'
        @(Get-ChildItem -LiteralPath (Split-Path $statePath) -Filter '*.tmp' -Force).Count | Should -Be 0
    }

    It 'fails closed on dirty, branch, HEAD, worktree, and repository mismatches' {
        $root = New-SourceContextRepository
        $payload = Write-SourceContextPayload -Root $root
        $saved = Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','mismatch','-RepositoryRoot',$root,'-PayloadPath',$payload)

        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'dirty', $Utf8NoBom)
        { Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','mismatch','-RepositoryRoot',$root) } | Should -Throw '*dirtyState*'
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'base', $Utf8NoBom)

        & git -C $root switch --quiet -c other
        { Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','mismatch','-RepositoryRoot',$root) } | Should -Throw '*branch*'
        & git -C $root switch --quiet main

        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'next', $Utf8NoBom)
        & git -C $root add -- tracked.txt
        & git -C $root commit --quiet -m next
        { Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','mismatch','-RepositoryRoot',$root) } | Should -Throw '*headCommit*tree*'

        $sibling = Join-Path $TestDrive ("sibling worktree $Cyrillic " + [guid]::NewGuid().ToString('N'))
        & git -C $root worktree add --quiet -b sibling $sibling HEAD
        { Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','mismatch','-RepositoryRoot',$sibling) } | Should -Throw '*worktreePath*branch*'

        $foreign = New-SourceContextRepository -Name 'foreign repo'
        $foreignPath = Get-SourceContextStatePath -Root $foreign -TaskId 'mismatch'
        New-Item -ItemType Directory -Path (Split-Path $foreignPath) -Force | Out-Null
        Copy-Item -LiteralPath $saved.path -Destination $foreignPath
        { Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','mismatch','-RepositoryRoot',$foreign) } | Should -Throw '*repositoryRoot*commonGitDir*worktreePath*'
    }

    It 'requires CAS and explicit advancement before recording an intentional dirty or descendant state' {
        $root = New-SourceContextRepository
        $payload = Write-SourceContextPayload -Root $root
        $saved = Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','advance','-RepositoryRoot',$root,'-PayloadPath',$payload)
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'intentional edit', $Utf8NoBom)
        $payload = Write-SourceContextPayload -Root $root -Name 'payload-dirty' -NextAction 'Commit the reviewed edit' -ChangedPaths @('tracked.txt')

        { Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','advance','-RepositoryRoot',$root,'-PayloadPath',$payload) } |
            Should -Throw '*SOURCE_CONTEXT_EXPECTED_STATE_REQUIRED*'
        { Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','advance','-RepositoryRoot',$root,'-PayloadPath',$payload,'-ExpectedStateSha256',$saved.stateSha256) } |
            Should -Throw '*SOURCE_CONTEXT_GIT_STATE_MISMATCH*'
        $dirty = Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','advance','-RepositoryRoot',$root,'-PayloadPath',$payload,'-ExpectedStateSha256',$saved.stateSha256,'-AdvanceGitState')
        (Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','advance','-RepositoryRoot',$root)).checkpoint.nextAction | Should -Be 'Commit the reviewed edit'

        & git -C $root add -- tracked.txt
        & git -C $root commit --quiet -m intentional
        $payload = Write-SourceContextPayload -Root $root -Name 'payload-commit' -Stage verification -NextAction 'Run focused verification' -ChangedPaths @('tracked.txt')
        $committed = Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','advance','-RepositoryRoot',$root,'-PayloadPath',$payload,'-ExpectedStateSha256',$dirty.stateSha256,'-AdvanceGitState')
        $committed.stage | Should -Be 'verification'
        (Invoke-SourceContextHelper -HelperArguments @('-Action','Status','-TaskId','advance','-RepositoryRoot',$root)).status | Should -Be 'matched'
    }

    It 'keeps task IDs and worktrees independent and completes only an exact state' {
        $root = New-SourceContextRepository
        $sibling = Join-Path $TestDrive ("independent worktree $Cyrillic " + [guid]::NewGuid().ToString('N'))
        & git -C $root worktree add --quiet -b independent $sibling HEAD
        $payloadOne = Write-SourceContextPayload -Root $root -Name 'payload-one' -Objective 'task one'
        $payloadTwo = Write-SourceContextPayload -Root $sibling -Name 'payload-two' -Objective 'task two'

        $one = Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','task-one','-RepositoryRoot',$root,'-PayloadPath',$payloadOne)
        $two = Invoke-SourceContextHelper -HelperArguments @('-Action','Checkpoint','-TaskId','task-two','-RepositoryRoot',$sibling,'-PayloadPath',$payloadTwo)
        $one.path | Should -Not -Be $two.path
        (Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','task-one','-RepositoryRoot',$root)).checkpoint.objective | Should -Be 'task one'
        (Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','task-two','-RepositoryRoot',$sibling)).checkpoint.objective | Should -Be 'task two'
        (Get-SourceContextStatusText -Root $root) | Should -BeNullOrEmpty
        (Get-SourceContextStatusText -Root $sibling) | Should -BeNullOrEmpty

        $completed = Invoke-SourceContextHelper -HelperArguments @('-Action','Complete','-TaskId','task-one','-RepositoryRoot',$root,'-ExpectedStateSha256',$one.stateSha256)
        $completed.stage | Should -Be 'complete'
        $completed.nextAction | Should -Be 'none'
        (Invoke-SourceContextHelper -HelperArguments @('-Action','Resume','-TaskId','task-two','-RepositoryRoot',$sibling)).checkpoint.stage | Should -Be 'implementation'
    }

    It 'contains no delivery, gate, thread API, or Git mutation route' {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($HelperPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $text = [IO.File]::ReadAllText($HelperPath, [Text.Encoding]::UTF8)
        $text | Should -Not -Match 'source-delivery|Invoke-Pester|create_thread|send_message_to_thread|handoff_thread|wait_threads'
        $text | Should -Not -Match '@\("(add|commit|push|merge|rebase|reset|checkout|switch|worktree|update-ref)"'
        $commands = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Parent -is [Management.Automation.Language.ArrayLiteralAst] -and
            $node.Value -in @('rev-parse','symbolic-ref','diff','ls-files','merge-base')
        }, $true) | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $commands | Should -Be @('diff','ls-files','merge-base','rev-parse','symbolic-ref')
    }
}
