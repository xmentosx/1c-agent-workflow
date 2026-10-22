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
}

Describe 'Producer-owned diagnostic retention' {
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

    It 'rejects retained path aliases and integrates diagnostic deletion into ordinary clean-artifacts' {
        $f = New-DiagnosticFixture 'Общий владелец'
        { Register-ItlDiagnosticArtifacts -ProjectRoot $f.root -Producer p -TerminalReceipt 'build/result.json' -Kind native-temp -DisposablePath $f.relative -RetainedPath ('./' + $f.relative) } | Should -Throw '*retained original*'
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
        (Test-Path -LiteralPath (Join-Path $f.root 'build/answer.raw.json')) | Should -BeTrue
    }
}
