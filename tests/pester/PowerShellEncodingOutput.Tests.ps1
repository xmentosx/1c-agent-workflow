BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'PowerShell encoding preflight output' {
    It 'surfaces a Cyrillic path and message intact through the child-process boundary' {
        # 2026-11-13: the preflight's failure reached the run record as mojibake because
        # Windows PowerShell wrote it in the console code page while logs are read as UTF-8.
        $root = Join-Path $TestDrive 'Кодировка с пробелом'
        foreach ($relative in @('scripts/test-powershell-encoding.ps1', 'scripts/git-path-list.ps1', 'scripts/release-e2e/test-powershell51-decoding.ps1')) {
            $target = Join-Path $root $relative; [void][IO.Directory]::CreateDirectory((Split-Path $target))
            Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target
        }
        & git -C $root init -q
        $null = & git -C $root add --all 2>&1; $null = & git -C $root -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm base 2>&1
        $base = (& git -C $root rev-parse HEAD).Trim()
        $relativeBroken = 'tests/pester/Проверка вывода.Tests.ps1'
        $broken = Join-Path $root $relativeBroken
        [void][IO.Directory]::CreateDirectory((Split-Path $broken))
        [IO.File]::WriteAllText($broken, "Describe 'Сломанный тест' {`n    It 'не разбирается' {`n        `$value = (`n", [Text.UTF8Encoding]::new($true))
        $null = & git -C $root add --all 2>&1; $null = & git -C $root -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm broken 2>&1
        $report = Join-Path $root 'build/кодировка отчёт.json'
        $result = Invoke-TestPowerShellFile -FilePath (Join-Path $root 'scripts/test-powershell-encoding.ps1') -Arguments @('-RepositoryRoot', $root, '-BaseRef', $base, '-OutputPath', $report)
        $result.exitCode | Should -Not -Be 0
        $written = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
        @($written.issues.path) | Should -Contain $relativeBroken
        # The same exact path round-trips through stdout and stderr, with no replacement
        # characters or code-page artefacts.
        ($result.stdout -join "`n") | Should -Match ([regex]::Escape($relativeBroken))
        ($result.stderr -join "`n") | Should -Match ([regex]::Escape($relativeBroken))
        $result.combinedText.IndexOf([char]0xFFFD) | Should -Be -1
    }
}
