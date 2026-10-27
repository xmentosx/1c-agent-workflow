BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    . (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.runtime-values.ps1')
    . (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
    . (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1')
    function New-DiagnosticFixture {
        param([string]$Name, [string]$Kind = 'native-temp')
        $root = Join-Path $TestDrive ("Проект с пробелами $Name")
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c'), (Join-Path $root 'build/case-temp') | Out-Null
        $receipt = Join-Path $root 'build/result.json'
        [IO.File]::WriteAllText($receipt, '{"status":"completed","cleanupConfirmed":true}', [Text.UTF8Encoding]::new($false))
        $relative = if ($Kind -eq 'native-temp') { 'build/case-temp/v8_AA_1.tmp' } else { 'build/case-temp/events.xml' }
        [IO.File]::WriteAllText((Join-Path $root $relative), 'original-disposable', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'build/original.etl'), 'original-trace')
        [IO.File]::WriteAllText((Join-Path $root 'build/answer.raw.json'), 'original-answer')
        $manifest = Register-ItlDiagnosticArtifacts -ProjectRoot $root -Producer 'test-producer' -TerminalReceipt 'build/result.json' -Kind $Kind -DisposablePath @($relative) -RetainedPath @('build/original.etl', 'build/answer.raw.json')
        return [pscustomobject]@{ root = $root; relative = $relative; path = (Join-Path $root $relative); manifest = $manifest }
    }
    function Set-DiagnosticFixtureAge {
        param($Fixture, [int]$Days)
        $text = [IO.File]::ReadAllText($Fixture.manifest)
        $replacement = '"completedUtc": "' + [datetime]::UtcNow.AddDays(-$Days).ToString('o') + '"'
        [IO.File]::WriteAllText($Fixture.manifest, ([regex]::Replace($text, '"completedUtc"\s*:\s*"[^"]+"', $replacement)))
    }
    function New-AgentTaskFixture {
        param([string]$Name)
        $root = Join-Path $TestDrive ("Задача агента с пробелами $Name")
        $taskRoot = 'build/agent-artifacts/task-1'
        foreach ($folder in '.agent-1c', "$taskRoot/tmp", "$taskRoot/evidence", "$taskRoot/recovery") {
            New-Item -ItemType Directory -Path (Join-Path $root $folder) -Force | Out-Null
        }
        $relative = "$taskRoot/tmp/Промежуточная выгрузка.cf"
        [IO.File]::WriteAllBytes((Join-Path $root $relative), [byte[]](0, 255, 13, 10, 1, 2))
        [IO.File]::WriteAllText((Join-Path $root "$taskRoot/evidence/result.json"), '{"status":"passed"}')
        [IO.File]::WriteAllBytes((Join-Path $root "$taskRoot/recovery/original.dt"), [byte[]](4, 3, 2, 1))
        [IO.File]::WriteAllText((Join-Path $root "$taskRoot/tmp/unknown.txt"), 'unclassified input')
        $completion = "$taskRoot/completion.json"
        $receipt = @{status='completed';cleanupConfirmed=$true;producer='agent-task';kind='agent-task-temp';taskRoot=$taskRoot;disposablePaths=@($relative);retainedPaths=@("$taskRoot/evidence/result.json", "$taskRoot/recovery/original.dt")}
        [IO.File]::WriteAllText((Join-Path $root $completion), ($receipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{root=$root;taskRoot=$taskRoot;relative=$relative;path=(Join-Path $root $relative);completion=$completion;receipt=$receipt}
    }
    function New-SupersededAttemptFixture {
        param([string]$Name)
        $root = Join-Path $TestDrive ("Старые проверки $Name")
        foreach ($folder in '.agent-1c', 'build/checks/v58', 'build/checks/v66') {
            New-Item -ItemType Directory -Path (Join-Path $root $folder) -Force | Out-Null
        }
        $relative = 'build/checks/v58/answer.raw.json'
        [IO.File]::WriteAllText((Join-Path $root $relative), '{"findings":["old failure"]}')
        [IO.File]::WriteAllText((Join-Path $root 'build/checks/v58/shared.bsl'), 'older dependency')
        [IO.File]::WriteAllText((Join-Path $root 'build/checks/v66/result.json'), '{"status":"passed"}')
        $receipt = @{status='failed';cleanupConfirmed=$true;producer='branch-check';kind='superseded-attempt';attemptRoot='build/checks/v58';supersededBy='build/checks/v66/result.json';disposablePaths=@($relative);retainedPaths=@('build/checks/v58/shared.bsl')}
        [IO.File]::WriteAllText((Join-Path $root 'build/completion.json'), ($receipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $manifest = @(Complete-ItlDiagnosticArtifacts -ProjectRoot $root -CompletionPath 'build/completion.json')[0]
        return [pscustomobject]@{root=$root;relative=$relative;path=(Join-Path $root $relative);manifest=$manifest;receipt=$receipt}
    }
}

Describe 'Completed agent task artifact cleanup' {
    BeforeEach {
        Mock Get-ItlArtifactProtectedPaths { return @() }
    }

    It 'completes and retries a task through clean-artifacts without deleting its proof, recovery or unknown files' {
        $f = New-AgentTaskFixture 'Общий helper'
        & git -C $f.root init --quiet
        $LASTEXITCODE | Should -Be 0
        $kept = @($f.receipt.retainedPaths) + @("$($f.taskRoot)/tmp/unknown.txt", $f.completion)
        $hashes = @{}
        foreach ($relative in $kept) { $hashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $f.root $relative)).Hash }
        $clientRunner = Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/run-itl-command.ps1'
        $arguments = @('-Action', 'clean-artifacts', '-CleanupDiagnosticsOnly', '-DiagnosticCompletionPath', $f.completion)
        Push-Location $f.root
        try {
            $preview = Invoke-TestPowerShellFile -FilePath $clientRunner -Arguments (@('--') + $arguments + '-CleanupDryRun')
            $preview.exitCode | Should -Be 0 -Because $preview.combinedText
            (Test-Path -LiteralPath $f.path) | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $f.root '.agent-1c/diagnostic-artifacts')) | Should -BeFalse
            foreach ($attempt in 1..2) {
                $done = Invoke-TestPowerShellFile -FilePath $clientRunner -Arguments (@('--') + $arguments)
                $done.exitCode | Should -Be 0 -Because $done.combinedText
                (Test-Path -LiteralPath $f.path) | Should -BeFalse
            }
        } finally { Pop-Location }
        @(Get-ChildItem -LiteralPath (Join-Path $f.root '.agent-1c/diagnostic-artifacts') -Filter '*.json').Count | Should -Be 1
        foreach ($relative in $kept) {
            (Get-FileHash -LiteralPath (Join-Path $f.root $relative)).Hash | Should -Be $hashes[$relative]
        }
    }

    It 'retries an opened disposable through automatic cleanup after the real reset archive and Git tree replacement' {
        $f = New-AgentTaskFixture 'Сброс ветки'
        [IO.File]::WriteAllText((Join-Path $f.root '.gitignore'), "build/`n.agent-1c/`n")
        [IO.File]::WriteAllText((Join-Path $f.root 'master.txt'), 'master source')
        & git -C $f.root init --quiet
        & git -C $f.root config user.name 'ITL test'
        & git -C $f.root config user.email 'test@example.invalid'
        & git -C $f.root add -- .gitignore master.txt
        & git -C $f.root commit --quiet -m master
        $master = (& git -C $f.root rev-parse HEAD).Trim()
        & git -C $f.root checkout --quiet -b itldev/task
        [IO.File]::WriteAllText((Join-Path $f.root 'branch.txt'), 'branch work')
        & git -C $f.root add -- branch.txt
        & git -C $f.root commit --quiet -m branch
        $oldHead = (& git -C $f.root rev-parse HEAD).Trim()
        $active = 'build/agent-artifacts/unfinished/tmp/input.txt'
        New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $f.root $active)) -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.root $active), 'unfinished input')
        [IO.File]::SetLastWriteTimeUtc((Join-Path $f.root $active), [datetime]::UtcNow.AddYears(-1))
        $result = & {
            . $context.HelperPath -ProjectRoot $f.root -Action help *> $null
            function Get-MainWorktreePath { return $f.root }
            function Invoke-Designer {
                param($InfoBasePath, $InfoBaseKind, $DesignerArgs)
                [IO.File]::WriteAllBytes($DesignerArgs[1], [byte[]](9, 8, 7, 6))
            }
            function Set-RunStage {}
            Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion | Out-Null
            $reader = [IO.File]::Open($f.path, 'Open', 'Read', 'Read')
            try { $blocked = Invoke-ItlArtifactCleanup -Automatic -WarningAction SilentlyContinue }
            finally { $reader.Dispose() }
            $state = [pscustomobject]@{devBranch='itldev/task';safeDevBranchName='task';devBranchInfoBasePath='fixture';infoBaseKind='file'}
            $archivePath = Join-Path (Get-DevBranchArchiveRoot) 'task/fixture'
            $archive = New-DevBranchResetArchive -State $state -MasterCommit $master -OldHead $oldHead -ArchivePath $archivePath
            $archiveHash = (Get-FileHash -LiteralPath $archive.dtPath).Hash
            Set-DevBranchTreeToMasterCommit -MasterCommit $master | Out-Null
            $beforeCleanup = Test-Path -LiteralPath $f.path
            $cleaned = Invoke-ItlArtifactCleanup -Automatic
            [pscustomobject]@{blocked=$blocked;beforeCleanup=$beforeCleanup;cleaned=$cleaned;archive=$archive;archiveHash=$archiveHash;tree=(Get-GitOutput @('rev-parse', 'HEAD^{tree}')).Trim();masterTree=(Get-GitOutput @('rev-parse', "$master`^{tree}")).Trim()}
        }
        $result.blocked.failed.Count | Should -Be 1
        $result.beforeCleanup | Should -BeTrue
        $result.cleaned.failed.Count | Should -Be 0
        $result.cleaned.removedBytes | Should -Be 6
        $result.tree | Should -Be $result.masterTree
        (Test-Path -LiteralPath $f.path) | Should -BeFalse
        (Get-FileHash -LiteralPath $result.archive.dtPath).Hash | Should -Be $result.archiveHash
        foreach ($relative in @($f.receipt.retainedPaths) + @($active, "$($f.taskRoot)/tmp/unknown.txt", $f.completion)) {
            (Test-Path -LiteralPath (Join-Path $f.root $relative)) | Should -BeTrue
        }
    }

    It 'rejects cross-task paths and retained aliases before enrolling any batch' {
        $f = New-AgentTaskFixture 'Границы задачи'
        foreach ($relative in @("$($f.taskRoot)/evidence/result.json", "$($f.taskRoot)/recovery/original.dt", 'build/agent-artifacts/other/tmp/file.txt', 'build/unowned.txt', '../outside.txt')) {
            $f.receipt.disposablePaths = @($f.relative, $relative)
            [IO.File]::WriteAllText((Join-Path $f.root $f.completion), ($f.receipt | ConvertTo-Json))
            { Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion } | Should -Throw '*own task tmp*'
            (Test-Path -LiteralPath (Join-Path $f.root '.agent-1c/diagnostic-artifacts')) | Should -BeFalse
        }
        $f.receipt.disposablePaths = @($f.relative)
        $f.receipt.retainedPaths += './' + $f.relative
        [IO.File]::WriteAllText((Join-Path $f.root $f.completion), ($f.receipt | ConvertTo-Json))
        { Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion } | Should -Throw '*retained originals*'
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'preserves running and unconfirmed tasks and honors automatic cleanup disablement' {
        $f = New-AgentTaskFixture 'Незавершённая'
        foreach ($values in @(@{status='running';cleanupConfirmed=$true}, @{status='completed';cleanupConfirmed=$false})) {
            $f.receipt.status=$values.status; $f.receipt.cleanupConfirmed=$values.cleanupConfirmed
            [IO.File]::WriteAllText((Join-Path $f.root $f.completion), ($f.receipt | ConvertTo-Json))
            { Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion } | Should -Throw '*cleanup*'
        }
        $f.receipt.status='completed';$f.receipt.cleanupConfirmed=$true
        [IO.File]::WriteAllText((Join-Path $f.root $f.completion), ($f.receipt | ConvertTo-Json))
        Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion | Out-Null
        $script:ProjectRoot=$f.root
        Mock Get-MainWorktreePath { return $script:ProjectRoot }
        Mock Get-ItlResultArtifactCandidates { return @() }
        Mock Get-ItlRunArtifactCandidates { return @() }
        Mock Get-ItlArchiveArtifactCandidates { return @() }
        Mock Get-ItlAuxiliaryArchiveArtifactCandidates { return @() }
        Mock Get-ItlWorkflowIncidentArchiveCandidates { return @() }
        Mock Get-EnvValue { param($Name,$Default) if($Name -eq 'ITL_ARTIFACT_CLEANUP_ENABLED'){return 'false'};return $Default }
        Invoke-ItlArtifactCleanup -Automatic | Out-Null
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root).Count | Should -Be 1
    }

    It 'keeps databases, DT backups, original traces and source snapshots outside automatic task disposal' {
        $f = New-AgentTaskFixture 'Оригиналы'
        foreach ($suffix in @('base.1CD', 'before.dt', 'original.etl', 'state.sqlite-wal', 'source-snapshots/id/Module.bsl', 'handoffs/resume.md')) {
            $relative = "$($f.taskRoot)/tmp/$suffix"
            $path = Join-Path $f.root $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllText($path, 'required original')
            $f.receipt.disposablePaths=@($relative)
            [IO.File]::WriteAllText((Join-Path $f.root $f.completion), ($f.receipt | ConvertTo-Json))
            { Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion } | Should -Throw '*Retain databases*'
            (Test-Path -LiteralPath $path) | Should -BeTrue
        }
    }

    It 'replays bounded completion batches and rejects an outside final entry before any enrollment' {
        $f = New-AgentTaskFixture 'Пакеты'
        $files = @(1..257 | ForEach-Object {
            $relative="$($f.taskRoot)/tmp/part-$_.txt"
            [IO.File]::WriteAllText((Join-Path $f.root $relative), 'disposable')
            $relative
        })
        $f.receipt.disposablePaths=$files + @('build/foreign.txt')
        [IO.File]::WriteAllText((Join-Path $f.root $f.completion), ($f.receipt | ConvertTo-Json))
        { Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion } | Should -Throw '*own task tmp*'
        (Test-Path -LiteralPath (Join-Path $f.root '.agent-1c/diagnostic-artifacts')) | Should -BeFalse
        $f.receipt.disposablePaths=$files
        [IO.File]::WriteAllText((Join-Path $f.root $f.completion), ($f.receipt | ConvertTo-Json))
        $first=@(Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion)
        $second=@(Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion)
        $first.Count | Should -Be 2
        $second | Should -Be $first
        @(Get-ChildItem -LiteralPath (Join-Path $f.root '.agent-1c/diagnostic-artifacts') -Filter '*.json').Count | Should -Be 2
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root).Count | Should -Be 257
    }

    It 'rechecks workflow references, retained dependencies and exact file bytes after preview' {
        $f = New-AgentTaskFixture 'Доказательства'
        $manifest = Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion
        $entry = @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root)[0]
        $script:AgentTaskProtectedPath = $f.path
        Mock Get-ItlArtifactProtectedPaths { return @($script:AgentTaskProtectedPath) }
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*current workflow evidence*'
        Mock Get-ItlArtifactProtectedPaths { return @() }
        $proof = Join-Path $f.root $f.receipt.retainedPaths[0]
        $originalProof = [IO.File]::ReadAllBytes($proof)
        [IO.File]::WriteAllText($proof, 'changed proof')
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*original changed*'
        [IO.File]::WriteAllBytes($proof, $originalProof)
        [IO.File]::WriteAllBytes($f.path, [byte[]](0, 254, 13, 10, 1, 2))
        [IO.File]::SetLastWriteTimeUtc($f.path, ([datetime]$entry.diagnosticRecord.modifiedUtc).ToUniversalTime())
        # Repeating completion must not re-enroll replacement bytes at an old path.
        (Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion) | Should -Be $manifest
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*hash changed*'
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'protects evidence-only completions from another completed task' {
        $f = New-AgentTaskFixture 'Только доказательства'
        $f.receipt.disposablePaths = @()
        $f.receipt.retainedPaths += $f.relative
        [IO.File]::WriteAllText((Join-Path $f.root $f.completion), ($f.receipt | ConvertTo-Json))
        $retainedManifest = Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion
        (Test-Path -LiteralPath $retainedManifest) | Should -BeTrue
        $otherCompletion = "$($f.taskRoot)/other-completion.json"
        $f.receipt.disposablePaths=@($f.relative)
        $f.receipt.retainedPaths=@("$($f.taskRoot)/evidence/result.json")
        [IO.File]::WriteAllText((Join-Path $f.root $otherCompletion), ($f.receipt | ConvertTo-Json))
        Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $otherCompletion | Out-Null
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root).Count | Should -Be 0
        (Invoke-ItlDiagnosticArtifactCleanup -ProjectRoot $f.root).removedBytes | Should -Be 0
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'rejects linked task roots and linked temporary directories' {
        $f = New-AgentTaskFixture 'Junction'
        $foreign = Join-Path $TestDrive 'Чужая папка с пробелами'
        New-Item -ItemType Directory -Path $foreign -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $foreign 'foreign.txt'), 'foreign input')
        $link = Join-Path $f.root "$($f.taskRoot)/tmp/linked"
        New-Item -ItemType Junction -Path $link -Target $foreign | Out-Null
        try {
            $f.receipt.disposablePaths=@("$($f.taskRoot)/tmp/linked/foreign.txt")
            [IO.File]::WriteAllText((Join-Path $f.root $f.completion), ($f.receipt | ConvertTo-Json))
            { Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath $f.completion } | Should -Throw '*linked*'
        } finally { [IO.Directory]::Delete($link) }
        (Test-Path -LiteralPath (Join-Path $foreign 'foreign.txt')) | Should -BeTrue
    }
}

Describe 'Producer-owned diagnostic retention' {
    It 'cleans an explicitly superseded attempt through the real branch command, preserving the older dependency and current proof' {
        $f = New-SupersededAttemptFixture 'Команда ветки'
        & git -C $f.root init --quiet
        $LASTEXITCODE | Should -Be 0
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root).Count | Should -Be 0
        Set-DiagnosticFixtureAge $f 8
        $arguments = @('-Action', 'clean-artifacts', '-ProjectRoot', $f.root, '-CleanupDiagnosticsOnly')
        $preview = Invoke-TestPowerShellFile -FilePath $context.HelperPath -Arguments ($arguments + '-CleanupDryRun')
        $preview.exitCode | Should -Be 0 -Because $preview.combinedText
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
        $done = Invoke-TestPowerShellFile -FilePath $context.HelperPath -Arguments $arguments
        $done.exitCode | Should -Be 0 -Because $done.combinedText
        (Test-Path -LiteralPath $f.path) | Should -BeFalse
        foreach ($kept in 'build/checks/v58/shared.bsl', 'build/checks/v66/result.json', 'build/completion.json') {
            (Test-Path -LiteralPath (Join-Path $f.root $kept)) | Should -BeTrue
        }
    }

    It 'preserves an attempt when its replacement fails, disappears or changes after the preview' {
        $f = New-SupersededAttemptFixture 'Замена'
        $entry = @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0)[0]
        $successor = Join-Path $f.root 'build/checks/v66/result.json'
        [IO.File]::WriteAllText($successor, '{"status":"failed"}')
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0 -WarningAction SilentlyContinue).Count | Should -Be 0
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*successor*'
        [IO.File]::WriteAllText($successor, '{"status":"passed","changed":true}')
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*original changed*'
        Remove-Item -LiteralPath $successor
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0 -WarningAction SilentlyContinue).Count | Should -Be 0
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'rejects directory heuristics, outside files, raw traces, snapshots and executable helpers' {
        $f = New-SupersededAttemptFixture 'Границы'
        $completion = Join-Path $f.root 'build/completion.json'
        foreach ($relative in 'build/checks/v66/outside.json', 'build/checks/v58/native.etl', 'build/checks/v58/repair.ps1', 'build/checks/v58/source-snapshots/id/Module.bsl') {
            $full = Join-Path $f.root $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            [IO.File]::WriteAllText($full, 'keep')
            { Register-ItlDiagnosticArtifacts -ProjectRoot $f.root -Producer p -TerminalReceipt 'build/completion.json' -Kind superseded-attempt -DisposablePath $relative } | Should -Throw
            (Test-Path -LiteralPath $full) | Should -BeTrue
        }
        $f.receipt.Remove('supersededBy')
        [IO.File]::WriteAllText($completion, ($f.receipt | ConvertTo-Json))
        { Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath 'build/completion.json' } | Should -Throw
    }

    It 'protects dependencies declared by other completed attempts, including after a preview' {
        $f = New-SupersededAttemptFixture 'Связанные попытки'
        $entry = @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0)[0]
        $other = 'build/checks/v58/other.raw.json'
        [IO.File]::WriteAllText((Join-Path $f.root $other), 'other old answer')
        Register-ItlDiagnosticArtifacts -ProjectRoot $f.root -Producer another -TerminalReceipt 'build/completion.json' -Kind superseded-attempt -DisposablePath @($other) -RetainedPath @($f.relative) | Out-Null
        $remaining = @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0)
        @($remaining | Where-Object path -eq $f.path).Count | Should -Be 0
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*retained dependency*'
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'retains the attempt artifacts named by current branch verification state' {
        $f = New-SupersededAttemptFixture 'Актуальные доказательства'
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0 -ProtectedPaths @($f.path)).Count | Should -Be 0
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'runs the real completion command without Codex, honors env disablement, and removes only expired files' {
        $f = New-DiagnosticFixture 'Штатный вызов'
        & git -C $f.root init --quiet
        $LASTEXITCODE | Should -Be 0
        Set-DiagnosticFixtureAge $f 8
        $fresh = 'build/case-temp/v8_AB_2.tmp'
        [IO.File]::WriteAllText((Join-Path $f.root $fresh), 'fresh')
        $completion = @{status='completed';cleanupConfirmed=$true;producer='itl-performance';kind='native-temp';disposablePaths=@($fresh);retainedPaths=@('build/answer.raw.json')}
        [IO.File]::WriteAllText((Join-Path $f.root 'build/completion.json'), ($completion | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $envFile = Join-Path $f.root '.dev.env'
        [IO.File]::WriteAllText($envFile, 'ITL_ARTIFACT_CLEANUP_ENABLED=false')
        $arguments = @('-Action', 'clean-artifacts', '-ProjectRoot', $f.root, '-CleanupDiagnosticsOnly', '-DiagnosticCompletionPath', 'build/completion.json')
        $disabled = Invoke-TestPowerShellFile -FilePath $context.HelperPath -Arguments $arguments
        $disabled.exitCode | Should -Be 0 -Because $disabled.combinedText
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $f.manifest) -Filter '*.json').Count | Should -Be 1
        [IO.File]::WriteAllText($envFile, "ITL_ARTIFACT_CLEANUP_ENABLED=true`nITL_DIAGNOSTIC_ARTIFACT_RETENTION_DAYS=7")
        $enabled = Invoke-TestPowerShellFile -FilePath $context.HelperPath -Arguments $arguments
        $enabled.exitCode | Should -Be 0 -Because $enabled.combinedText
        (Test-Path -LiteralPath $f.path) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $f.root $fresh)) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $f.root 'build/answer.raw.json')) | Should -BeTrue
    }

    It 'enrolls a terminal producer completion in bounded batches and applies the existing age policy' {
        $f = New-DiagnosticFixture 'Завершение производителя'
        $completion = @{status='failed';cleanupConfirmed=$true;producer='itl-performance';kind='native-temp';disposablePaths=@($f.relative);retainedPaths=@('build/answer.raw.json')}
        $receipt = Join-Path $f.root 'build/completion.json'
        [IO.File]::WriteAllText($receipt, ($completion | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $registered = @(Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath 'build/completion.json')
        $registered.Count | Should -Be 1
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root).Count | Should -Be 0
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
        $completion.cleanupConfirmed = $false
        [IO.File]::WriteAllText($receipt, ($completion | ConvertTo-Json))
        { Complete-ItlDiagnosticArtifacts -ProjectRoot $f.root -CompletionPath 'build/completion.json' } | Should -Throw '*cleanup*'
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'retains unknown files and fresh registrations; deletes the exact aged disposable and keeps original evidence' {
        $f = New-DiagnosticFixture 'Возраст'
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root).Count | Should -Be 0
        Set-DiagnosticFixtureAge $f 8
        $preview = Invoke-ItlDiagnosticArtifactCleanup -ProjectRoot $f.root -DryRun
        $preview.entries.Count | Should -Be 1
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
        $done = Invoke-ItlDiagnosticArtifactCleanup -ProjectRoot $f.root
        $done.failed.Count | Should -Be 0
        $done.removedBytes | Should -BeGreaterThan 0
        (Test-Path -LiteralPath $f.path) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $f.root 'build/original.etl')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $f.root 'build/answer.raw.json')) | Should -BeTrue
        (Invoke-ItlDiagnosticArtifactCleanup -ProjectRoot $f.root).removedBytes | Should -Be 0
    }

    It 'retains a file opened by another reader and can continue after that reader completes' {
        $f = New-DiagnosticFixture 'Занят'
        $reader = [IO.File]::Open($f.path, 'Open', 'Read', 'Read')
        try {
            $result = Invoke-ItlDiagnosticArtifactCleanup -ProjectRoot $f.root -MinimumAgeDays 0
            $result.failed.Count | Should -Be 1
            (Test-Path -LiteralPath $f.path) | Should -BeTrue
        } finally { $reader.Dispose() }
        (Invoke-ItlDiagnosticArtifactCleanup -ProjectRoot $f.root -MinimumAgeDays 0).failed.Count | Should -Be 0
        (Test-Path -LiteralPath $f.path) | Should -BeFalse
    }

    It 'rejects altered bytes even when length and timestamp were restored after preview' {
        $f = New-DiagnosticFixture 'Изменён'
        $entry = @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0)[0]
        $stamp = (Get-Item -LiteralPath $f.path).LastWriteTimeUtc
        [IO.File]::WriteAllText($f.path, 'modified-disposable', [Text.UTF8Encoding]::new($false))
        [IO.File]::SetLastWriteTimeUtc($f.path, $stamp)
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*hash changed*'
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'requires the retained original trace to remain intact before deleting its derivative' {
        $f = New-DiagnosticFixture 'Оригинал' 'derived-trace'
        $entry = @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0)[0]
        [IO.File]::WriteAllText((Join-Path $f.root 'build/original.etl'), 'changed')
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*original changed*'
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'rejects a changed manifest and a saved preview retargeted to another file' {
        $f = New-DiagnosticFixture 'Список'
        $entry = @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0)[0]
        $entry.path = Join-Path $f.root 'build/answer.raw.json'
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*differs from its manifest*'
        $entry.path = $f.path
        Add-Content -LiteralPath $f.manifest -Value ' '
        { Remove-ItlDiagnosticArtifact -Entry $entry } | Should -Throw '*manifest changed*'
        (Test-Path -LiteralPath $f.path) | Should -BeTrue
    }

    It 'rejects running or unconfirmed producers and does not register raw evidence as disposable' {
        $f = New-DiagnosticFixture 'Владелец'
        [IO.File]::WriteAllText((Join-Path $f.root 'build/result.json'), '{"status":"running","cleanupConfirmed":true}')
        { Register-ItlDiagnosticArtifacts -ProjectRoot $f.root -Producer p -TerminalReceipt 'build/result.json' -Kind native-temp -DisposablePath $f.relative } | Should -Throw '*terminal receipt*'
        [IO.File]::WriteAllText((Join-Path $f.root 'build/result.json'), '{"status":"completed","cleanupConfirmed":false}')
        { Register-ItlDiagnosticArtifacts -ProjectRoot $f.root -Producer p -TerminalReceipt 'build/result.json' -Kind native-temp -DisposablePath $f.relative } | Should -Throw '*terminal receipt*'
        { Resolve-ItlDiagnosticArtifactPath -ProjectRoot $f.root -RelativePath 'build/answer.raw.json' -Kind native-temp } | Should -Throw '*Unrecognized*'
        { Resolve-ItlDiagnosticArtifactPath -ProjectRoot $f.root -RelativePath 'build/original.etl' -Kind derived-trace } | Should -Throw '*Only derived*'
        { Resolve-ItlDiagnosticArtifactPath -ProjectRoot $f.root -RelativePath '../outside.xml' -Kind derived-trace } | Should -Throw
    }

    It 'retains state-referenced files and future-dated completion records' {
        $f = New-DiagnosticFixture 'Ссылка'
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0 -ProtectedPaths @($f.path)).Count | Should -Be 0
        Set-DiagnosticFixtureAge $f -1
        @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $f.root -MinimumAgeDays 0).Count | Should -Be 0
    }

    It 'rejects junction traversal even when the apparent filename is permitted' {
        $f = New-DiagnosticFixture 'Ссылка на каталог'
        $target = Join-Path $TestDrive 'Другой каталог'
        New-Item -ItemType Directory -Path $target | Out-Null
        [IO.File]::WriteAllText((Join-Path $target 'v8_AA_1.tmp'), 'foreign')
        $link = Join-Path $f.root 'build/linked-temp'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        try { { Resolve-ItlDiagnosticArtifactPath -ProjectRoot $f.root -RelativePath 'build/linked-temp/v8_AA_1.tmp' -Kind native-temp } | Should -Throw }
        finally { [IO.Directory]::Delete($link) }
        (Test-Path -LiteralPath (Join-Path $target 'v8_AA_1.tmp')) | Should -BeTrue
    }

    It 'uses the configured retention age and rejects a disabled zero-day automatic policy' {
        Mock Get-EnvValue { param($Name, $Default) if ($Name -eq 'ITL_DIAGNOSTIC_ARTIFACT_RETENTION_DAYS') { return '4' }; return $Default }
        (Get-ItlArtifactRetentionPolicy).diagnosticDays | Should -Be 4
        Mock Get-EnvValue { param($Name, $Default) if ($Name -eq 'ITL_DIAGNOSTIC_ARTIFACT_RETENTION_DAYS') { return '0' }; return $Default }
        { Get-ItlArtifactRetentionPolicy } | Should -Throw '*ITL_DIAGNOSTIC_ARTIFACT_RETENTION_DAYS*'
    }

    It 'rejects retained aliases and integrates <Kind> deletion into ordinary automatic clean-artifacts' -TestCases @(@{Kind='native-temp'}, @{Kind='superseded-attempt'}) {
        param($Kind)
        $f = if ($Kind -eq 'native-temp') { New-DiagnosticFixture 'Общий владелец' } else { New-SupersededAttemptFixture 'Общий владелец' }
        $receipt = if ($Kind -eq 'native-temp') { 'build/result.json' } else { 'build/completion.json' }
        { Register-ItlDiagnosticArtifacts -ProjectRoot $f.root -Producer p -TerminalReceipt $receipt -Kind $Kind -DisposablePath $f.relative -RetainedPath ('./' + $f.relative) } | Should -Throw '*retained original*'
        Set-DiagnosticFixtureAge $f 8
        $script:ProjectRoot = $f.root
        Mock Get-EnvValue { param($Name, $Default) return $Default }
        Mock Get-MainWorktreePath { return $script:ProjectRoot }
        Mock Get-ItlArtifactProtectedPaths { return @() }
        Mock Get-ItlResultArtifactCandidates { return @() }
        Mock Get-ItlRunArtifactCandidates { return @() }
        Mock Get-ItlAuxiliaryArchiveArtifactCandidates { return @() }
        Mock Get-ItlWorkflowIncidentArchiveCandidates { return @() }
        Mock Get-ItlArchiveArtifactCandidates { return @() }
        (Invoke-ItlArtifactCleanup -Automatic).removedBytes | Should -BeGreaterThan 0
        (Test-Path -LiteralPath $f.path) | Should -BeFalse
        $kept = if ($Kind -eq 'native-temp') { 'build/answer.raw.json' } else { 'build/checks/v66/result.json' }
        (Test-Path -LiteralPath (Join-Path $f.root $kept)) | Should -BeTrue
    }
}
