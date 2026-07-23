Describe "compact ITL command runner" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $RunnerSource = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1"
    }

    It "stores full output and returns a bounded successful summary" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-success-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="## Результат`n- Browser: включён`n- Рекомендация: выполните /reload" }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Write-Output ('x' * 12000)
exit 0
'@
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "run-itl-command.ps1") -- -Action check-dev-branch
            $LASTEXITCODE | Should -Be 0
            $text = ($output -join "`n")
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.action | Should -Be "check-dev-branch"
            $summary.status | Should -Be "succeeded"
            $summary.confirmationRequired | Should -BeFalse
            $summary.userReport | Should -Be "## Результат`n- Browser: включён`n- Рекомендация: выполните /reload"
            (Get-Item -LiteralPath $summary.logPath).Length | Should -BeGreaterThan 10000
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.nextAction | Should -Be "none"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "returns the refresh user report byte-for-byte without exposing the diagnostic log" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-refresh-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$report = "## Обновление ветки разработки`n- Результат: успешно`n- Ветка: itldev/perf1`n- Enterprise-автообновление: выполнено`n`n## MCP`n- Kilo Browser Automation: включена`n`n## Инструкции и рекомендации`n- Выполните /reload.`n- Выполните /itl-check."
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport=$report }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Write-Output 'DIAGNOSTIC_SECRET_SHOULD_STAY_IN_CONSOLE_LOG'
exit 0
'@
            $expected = "## Обновление ветки разработки`n- Результат: успешно`n- Ветка: itldev/perf1`n- Enterprise-автообновление: выполнено`n`n## MCP`n- Kilo Browser Automation: включена`n`n## Инструкции и рекомендации`n- Выполните /reload.`n- Выполните /itl-check."
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "run-itl-command.ps1") -- -Action refresh-dev-branch
            $LASTEXITCODE | Should -Be 0
            $text = ($output -join "`n")
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.action | Should -Be "refresh-dev-branch"
            $summary.status | Should -Be "succeeded"
            $summary.userReport | Should -BeExactly $expected
            $text | Should -Not -Match "DIAGNOSTIC_SECRET_SHOULD_STAY_IN_CONSOLE_LOG"
            (Get-Content -LiteralPath $summary.logPath -Raw -Encoding UTF8) | Should -Match "DIAGNOSTIC_SECRET_SHOULD_STAY_IN_CONSOLE_LOG"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "marks an unverified export as requiring confirmation" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-confirm-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='failed'; action=$Action; stage='verification'; stageDetail='missing'; errorMessage='Fresh verification is missing. Rerun with -AllowUnverifiedResult.'; exitCode=1; lastLogPath='' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Write-Output 'unverified export refused'
exit 1
'@
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "run-itl-command.ps1") -- -Action export-dev-branch-result
            $LASTEXITCODE | Should -Be 1
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.confirmationRequired | Should -BeTrue
            $summary.nextAction | Should -Match 'explicit confirmation'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "delegates branch creation to the existing window launcher contract" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-window-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            $runRoot = Join-Path $tempRoot ".agent-1c\runs\fixture"
            New-Item -ItemType Directory -Force -Path $scriptRoot, $runRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "run-agent-1c-window.ps1") -Encoding UTF8 -Value @"
`$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action='new-dev-branch'; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="## Ветка разработки`n- Ветка: itldev/demo`n- Kilo Browser Automation: отключена`n- Рекомендация: откройте worktree" }
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\status.json',((`$payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding `$false))
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\console.log','full branch log',(New-Object Text.UTF8Encoding `$false))
Write-Output 'Run directory: $runRoot'
exit 0
"@
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "run-itl-command.ps1") -Windowed -- -Action new-dev-branch -DevBranchName demo
            $LASTEXITCODE | Should -Be 0
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.action | Should -Be "new-dev-branch"
            $summary.logPath | Should -Be (Join-Path $runRoot "console.log")
            $summary.userReport | Should -Be "## Ветка разработки`n- Ветка: itldev/demo`n- Kilo Browser Automation: отключена`n- Рекомендация: откройте worktree"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "returns a successful pending extension branch with a structured agent next step" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-extension-pending-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            $runRoot = Join-Path $tempRoot ".agent-1c\runs\fixture"
            $worktree = Join-Path $tempRoot "worktrees\demo"
            New-Item -ItemType Directory -Force -Path $scriptRoot, $runRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "run-agent-1c-window.ps1") -Encoding UTF8 -Value @"
`$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action='new-extension-dev-branch'; stage='extension-init.pending'; stageDetail='waiting'; errorMessage=''; exitCode=0; lastLogPath=''; requiredAction='Уточните режим расширения в чате; не показывайте PowerShell.'; devBranch='itldev/demo'; worktreePath='$($worktree.Replace("'", "''"))'; extensionInitializationStatus='pending'; userReport="## Ветка разработки`n- Тип: расширение`n- Инициализация расширения: ожидает настройки`n`n## Инструкции и рекомендации`n- Уточните режим расширения в чате." }
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\status.json',((`$payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding `$false))
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\console.log','pending branch log',(New-Object Text.UTF8Encoding `$false))
Write-Output 'Run directory: $runRoot'
exit 0
"@
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "run-itl-command.ps1") -Windowed -- -Action new-extension-dev-branch -DevBranchName demo
            $LASTEXITCODE | Should -Be 0
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            $summary.nextAction | Should -Be "Уточните режим расширения в чате; не показывайте PowerShell."
            $summary.devBranch | Should -Be "itldev/demo"
            $summary.worktreePath | Should -Be $worktree
            $summary.extensionInitializationStatus | Should -Be "pending"
            $summary.userReport | Should -Be "## Ветка разработки`n- Тип: расширение`n- Инициализация расширения: ожидает настройки`n`n## Инструкции и рекомендации`n- Уточните режим расширения в чате."
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "returns structured Vanessa authoring failure without requiring the log tail" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-authoring-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$authoring = Join-Path $ProjectRoot '.agent-1c\vanessa-authoring\state.json'
$payload = [ordered]@{ schemaVersion=1; status='failed'; action=$Action; stage='vanessa.preflight'; stageDetail='stale'; errorMessage='authoring pass stale'; exitCode=1; lastLogPath=''; errorCategory='unsupported-step'; requiredAction='/itl-vanessa-author'; authoringStatus='reload-required'; authoringStatePath=$authoring }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 1
'@
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "run-itl-command.ps1") -- -Action check-dev-branch
            $LASTEXITCODE | Should -Be 1
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.errorCategory | Should -Be "unsupported-step"
            $summary.requiredAction | Should -Be "/itl-vanessa-author"
            $summary.nextAction | Should -Be "/itl-vanessa-author"
            $summary.authoringStatus | Should -Be "reload-required"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
