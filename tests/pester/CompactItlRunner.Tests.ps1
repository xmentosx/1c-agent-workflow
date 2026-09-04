Describe "compact ITL command runner" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $RunnerSource = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1"
    }

    It "removes only the PowerShell Core module root while launching the Windows PowerShell helper" {
        $runnerText = Get-Content -LiteralPath $RunnerSource -Raw -Encoding UTF8
        $runnerText | Should -Match '\$resetModulePathForWindowsPowerShell = \[string\]\$PSVersionTable\.PSEdition -eq "Core"'
        $runnerText | Should -Match '\$coreModuleRoot = \[IO\.Path\]::GetFullPath\(\(Join-Path \$PSHOME "Modules"\)\)'
        $runnerText | Should -Match 'Start-Process[\s\S]*?-FilePath "powershell"'
        $runnerText | Should -Match 'finally \{[\s\S]*?\$env:PSModulePath = \$originalPowerShellModulePath'
    }

    It "keeps Windows PowerShell built-in modules available when invoked from PowerShell Core" -Skip:(-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl pwsh boundary путь " + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            $runnerPath = Join-Path $scriptRoot "run-itl-command.ps1"
            Copy-Item -LiteralPath $RunnerSource -Destination $runnerPath
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$hash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport=$hash }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            Push-Location $tempRoot
            try {
                $output = @(& pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath -- -Action check-dev-branch 2>&1)
                $exitCode = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
            $summary = (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join [Environment]::NewLine) | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            $summary.userReport | Should -Match '^[0-9a-f]{64}$'
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
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
Write-Output 'Проверка UTF-8 журнала'
Write-Output ('x' * 12000)
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $text = ($output -join "`n")
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.action | Should -Be "check-dev-branch"
            $summary.status | Should -Be "succeeded"
            $summary.confirmationRequired | Should -BeFalse
            $summary.responseStyle.mode | Should -Be "on"
            $summary.responseStyle.level | Should -Be "full"
            $summary.responseStyle.active | Should -BeTrue
            $summary.responseStyle.profile | Should -Be "caveman-full"
            $summary.responseStyle.taskClass | Should -Be "execution"
            ($processResult.stderr -join "`n") | Should -Match 'ITL response-style: mode=on; level=full; active=true; profile=caveman-full; task=execution'
            (Get-Item -LiteralPath $summary.logPath).Length | Should -BeGreaterThan 10000
            (Get-Content -LiteralPath $summary.logPath -Raw -Encoding UTF8) | Should -Match 'Проверка UTF-8 журнала'
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.userReport | Should -BeExactly $status.userReport
            $status.nextAction | Should -Be "none"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "exposes the source integrity report in a failed compact summary and artifacts" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl source report путь с пробелом " + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$reportPath = Join-Path $ProjectRoot 'source integrity отчёт.json'
[IO.File]::WriteAllText($reportPath,'{"schemaVersion":1}',(New-Object Text.UTF8Encoding $false))
$payload = [ordered]@{ schemaVersion=1; status='failed'; action=$Action; stage='source-integrity.failed'; stageDetail='invalid merged source'; errorMessage='ONEC_SOURCE_INTEGRITY_FAILED'; errorCategory='source-integrity'; requiredAction='agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit'; exitCode=1; lastLogPath=''; sourceIntegrityReportPath=$reportPath }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 1
'@
            Push-Location $tempRoot
            try {
                $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")
            } finally {
                Pop-Location
            }
            $processResult.exitCode | Should -Be 1
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json

            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "source-integrity.failed"
            $summary.errorCategory | Should -Be "source-integrity"
            $summary.sourceIntegrityReportPath | Should -Be (Join-Path $tempRoot "source integrity отчёт.json")
            @($summary.artifacts) | Should -Contain $summary.sourceIntegrityReportPath
            $summary.requiredAction | Should -Be "agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "preserves semantic success and exposes an absolute report file for every long-report action" {
        foreach ($action in @("export-dev-branch-result", "lock-config-repository-objects", "update-workflow", "refresh-all-dev-branches")) {
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl long report путь с пробелом " + $action + "-" + [guid]::NewGuid().ToString("N"))
            try {
                $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
                New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
                Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
                Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$reportLines = [System.Collections.Generic.List[string]]::new()
$reportLines.Add("## Полный результат операции")
foreach ($index in 1..91) {
    $reportLines.Add("- Объект метаданных с длинным кириллическим именем номер ${index}: успешно обработан без сокращения")
}
$report = $reportLines -join [Environment]::NewLine
$runRoot = Split-Path -Parent $RunStatusPath
[IO.File]::WriteAllText((Join-Path $runRoot "side-effect.marker"), $Action, [Text.UTF8Encoding]::new($false))
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport=$report }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
exit 0
'@
                Push-Location $tempRoot
                try {
                    $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", $action)
                } finally {
                    Pop-Location
                }

                $text = $processResult.stdout -join "`n"
                $summary = $text | ConvertFrom-Json
                $runDiagnostic = if ($summary.logPath -and (Test-Path -LiteralPath $summary.logPath -PathType Leaf)) {
                    Get-Content -LiteralPath $summary.logPath -Raw -Encoding UTF8
                } else {
                    ($processResult.stderr + $processResult.stdout) -join [Environment]::NewLine
                }
                $processResult.exitCode | Should -Be 0 -Because $runDiagnostic
                $text.Length | Should -BeLessOrEqual 4000
                $summary.status | Should -Be "succeeded"
                $summary.userReport | Should -BeExactly ""
                $summary.userReportOmitted | Should -BeTrue
                $summary.userReportSource | Should -Be "file"
                [IO.Path]::IsPathRooted([string]$summary.userReportPath) | Should -BeTrue
                [string]$summary.userReportPath | Should -BeExactly ([IO.Path]::GetFullPath([string]$summary.userReportPath))
                [string]$summary.userReportPath | Should -Match 'user-report\.md$'
                Test-Path -LiteralPath $summary.userReportPath -PathType Leaf | Should -BeTrue
                @($summary.artifacts) | Should -Contain $summary.userReportPath

                $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $status.userReport.Length | Should -BeGreaterOrEqual 5205
                @($status.userReport -split "`r?`n").Count | Should -Be 92
                Get-Content -LiteralPath $summary.userReportPath -Raw -Encoding UTF8 | Should -BeExactly $status.userReport
                [int]$summary.userReportLength | Should -Be $status.userReport.Length
                $status.userReportPath | Should -BeExactly $summary.userReportPath
                $status.userReportSource | Should -Be "file"
                Get-Content -LiteralPath (Join-Path (Split-Path -Parent $summary.statusPath) "side-effect.marker") -Raw -Encoding UTF8 | Should -BeExactly $action
                ($processResult.stderr -join "`n") | Should -Not -Match "Compact ITL summary exceeded"
            } finally {
                if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It "falls back to the absolute status path without changing success when the report file cannot be written" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl report fallback путь с пробелом-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$runRoot = Split-Path -Parent $RunStatusPath
New-Item -ItemType Directory -Force -Path (Join-Path $runRoot "user-report.md") | Out-Null
$report = "## Результат" + [Environment]::NewLine + ("Полный кириллический отчёт без сокращения. " * 180)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport=$report }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
exit 0
'@
            Push-Location $tempRoot
            try {
                $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "lock-config-repository-objects")
            } finally {
                Pop-Location
            }

            $processResult.exitCode | Should -Be 0 -Because (($processResult.stderr + $processResult.stdout) -join [Environment]::NewLine)
            $text = $processResult.stdout -join "`n"
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            $summary.userReportOmitted | Should -BeTrue
            $summary.userReportSource | Should -Be "status-json"
            [IO.Path]::IsPathRooted([string]$summary.userReportPath) | Should -BeTrue
            $summary.userReportPath | Should -BeExactly $summary.statusPath
            $status = Get-Content -LiteralPath $summary.userReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.userReport.Length | Should -BeGreaterThan 5205
            $status.userReportPath | Should -BeExactly $summary.userReportPath
            $status.userReportSource | Should -Be "status-json"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "does not leak a handled native probe exit code from a successful helper" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-native-probe-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
& cmd.exe /d /c exit 1
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport='native probe was handled' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
& cmd.exe /d /c exit 1
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")
            $processResult.exitCode | Should -Be 0 -Because (($processResult.stderr + $processResult.stdout) -join [Environment]::NewLine)
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            [int](Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json).exitCode | Should -Be 0
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "routes update-workflow from a Cyrillic development worktree to master without switching the caller branch" {
        $cyrillicName = -join ([char[]](0x043C, 0x0430, 0x0440, 0x0448, 0x0440, 0x0443, 0x0442))
        $devBranch = "itldev/$cyrillicName"
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl update $cyrillicName " + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main project"
        $devRoot = Join-Path $tempRoot "dev branch"
        try {
            $scriptRoot = Join-Path $mainRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$branch = (& git -C $ProjectRoot branch --show-current).Trim()
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; projectRoot=$ProjectRoot; branch=$branch; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport='master updated; refresh the dev branch' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            & git -C $mainRoot init *> $null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            & git -C $mainRoot add .
            & git -C $mainRoot commit -m init *> $null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b $devBranch $devRoot *> $null
            $LASTEXITCODE | Should -Be 0

            Push-Location $devRoot
            try {
                $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $devRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1") -Arguments @("--", "-Action", "update-workflow")
            } finally {
                Pop-Location
            }

            $processResult.exitCode | Should -Be 0
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.projectRoot | Should -Be ([IO.Path]::GetFullPath($mainRoot))
            $status.branch | Should -Be "master"
            $utf8 = New-Object System.Text.UTF8Encoding $false
            $gitDirText = [IO.File]::ReadAllText((Join-Path $devRoot ".git"), $utf8).Trim()
            $gitDirValue = $gitDirText.Substring("gitdir: ".Length)
            $devGitDir = if ([IO.Path]::IsPathRooted($gitDirValue)) { $gitDirValue } else { Join-Path $devRoot $gitDirValue }
            [IO.File]::ReadAllText((Join-Path $devGitDir "HEAD"), $utf8).Trim() | Should -Be "ref: refs/heads/$devBranch"
            [IO.File]::ReadAllText((Join-Path $mainRoot ".git\HEAD"), $utf8).Trim() | Should -Be "ref: refs/heads/master"
            ($processResult.stderr -join "`n") | Should -Match "ITL update-workflow target: branch=itldev/"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "bootstraps only branch refresh actions through the clean master runner" {
        $cyrillicName = -join ([char[]](0x0432, 0x0435, 0x0442, 0x043A, 0x0430))
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl refresh $cyrillicName " + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main project"
        $devRoot = Join-Path $tempRoot "dev $cyrillicName"
        $devBranch = "itldev/$cyrillicName"
        try {
            $mainScripts = Join-Path $mainRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $mainScripts | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $mainScripts "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $mainScripts "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; projectRoot=$ProjectRoot; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="main-runtime:$Action" }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            & git -C $mainRoot init *> $null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            & git -C $mainRoot add .
            & git -C $mainRoot commit -m init *> $null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b $devBranch $devRoot *> $null
            $LASTEXITCODE | Should -Be 0

            $branchHelper = Join-Path $devRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
            Set-Content -LiteralPath $branchHelper -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; projectRoot=$ProjectRoot; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="branch-runtime:$Action" }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $branchRunner = Join-Path $devRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1"
            Push-Location $devRoot
            try {
                foreach ($refreshAction in @("refresh-dev-branch", "refresh-dev-branch-lite")) {
                    $processResult = Invoke-TestPowerShellFile -FilePath $branchRunner -Arguments @("--", "-Action", $refreshAction)
                    $processResult.exitCode | Should -Be 0 -Because (($processResult.stderr + $processResult.stdout) -join [Environment]::NewLine)
                    $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
                    $summary.userReport | Should -Be "main-runtime:$refreshAction"
                    $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $status.projectRoot | Should -Be ([IO.Path]::GetFullPath($devRoot))
                    ($processResult.stderr -join "`n") | Should -Match "ITL refresh runtime: delegating action=$refreshAction"
                }

                $localResult = Invoke-TestPowerShellFile -FilePath $branchRunner -Arguments @("--", "-Action", "check-dev-branch")
                $localResult.exitCode | Should -Be 0 -Because (($localResult.stderr + $localResult.stdout) -join [Environment]::NewLine)
                (($localResult.stdout -join "`n") | ConvertFrom-Json).userReport | Should -Be "branch-runtime:check-dev-branch"

                Add-Content -LiteralPath (Join-Path $mainScripts "agent-1c.ps1") -Encoding UTF8 -Value "# dirty runtime"
                $dirtyResult = Invoke-TestPowerShellFile -FilePath $branchRunner -Arguments @("--", "-Action", "refresh-dev-branch-lite")
                $dirtyResult.exitCode | Should -Not -Be 0
                (($dirtyResult.stderr + $dirtyResult.stdout) -join "`n") | Should -Match "REFRESH_MASTER_RUNTIME_DIRTY"
            } finally {
                Pop-Location
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "resolves the ITL Caveman mode and level matrix from project env with safe defaults" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-response-style-" + [guid]::NewGuid().ToString("N"))
        $previousMode = [Environment]::GetEnvironmentVariable("CAVEMAN", "Process")
        $previousLevel = [Environment]::GetEnvironmentVariable("CAVEMAN_LEVEL", "Process")
        try {
            [Environment]::SetEnvironmentVariable("CAVEMAN", $null, "Process")
            [Environment]::SetEnvironmentVariable("CAVEMAN_LEVEL", $null, "Process")
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport='unchanged report' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $cases = @(
                [pscustomobject]@{ mode=$null; level=$null; expectedMode='on'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='invalid'; level='invalid'; expectedMode='on'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='on'; level='lite'; expectedMode='on'; expectedLevel='lite'; active=$true; profile='caveman-lite' },
                [pscustomobject]@{ mode='on'; level='ultra'; expectedMode='on'; expectedLevel='ultra'; active=$true; profile='caveman-ultra' },
                [pscustomobject]@{ mode='auto'; level='lite'; expectedMode='auto'; expectedLevel='lite'; active=$true; profile='caveman-lite' },
                [pscustomobject]@{ mode='auto'; level='full'; expectedMode='auto'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='auto'; level='ultra'; expectedMode='auto'; expectedLevel='ultra'; active=$true; profile='caveman-ultra' },
                [pscustomobject]@{ mode='off'; level='lite'; expectedMode='off'; expectedLevel='lite'; active=$false; profile='normal' },
                [pscustomobject]@{ mode='off'; level='full'; expectedMode='off'; expectedLevel='full'; active=$false; profile='normal' },
                [pscustomobject]@{ mode='off'; level='ultra'; expectedMode='off'; expectedLevel='ultra'; active=$false; profile='normal' }
            )
            foreach ($case in $cases) {
                $envPath = Join-Path $tempRoot ".dev.env"
                if ($null -eq $case.mode -and $null -eq $case.level) {
                    Remove-Item -LiteralPath $envPath -Force -ErrorAction SilentlyContinue
                } else {
                    Set-Content -LiteralPath $envPath -Encoding UTF8 -Value "CAVEMAN=$($case.mode)`nCAVEMAN_LEVEL=$($case.level)`n"
                }
                Push-Location $tempRoot
                try {
                    $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")
                } finally { Pop-Location }
                $processResult.exitCode | Should -Be 0 -Because $processResult.combinedText
                $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
                $summary.responseStyle.mode | Should -Be $case.expectedMode
                $summary.responseStyle.level | Should -Be $case.expectedLevel
                $summary.responseStyle.active | Should -Be $case.active
                $summary.responseStyle.profile | Should -Be $case.profile
                $summary.responseStyle.taskClass | Should -Be 'execution'
                $summary.userReport | Should -BeExactly 'unchanged report'
            }
        } finally {
            [Environment]::SetEnvironmentVariable("CAVEMAN", $previousMode, "Process")
            [Environment]::SetEnvironmentVariable("CAVEMAN_LEVEL", $previousLevel, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "runs repair-session creation through the compact boundary and returns its session id" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-repair-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport='Repair session: abc123. Repair attempts: 0/3.' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "run-itl-command.ps1") -- -Action begin-verification-repair
            $LASTEXITCODE | Should -Be 0
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.action | Should -Be "begin-verification-repair"
            $summary.userReport | Should -Be "Repair session: abc123. Repair attempts: 0/3."
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "returns absolute result paths and artifacts in the successful export summary" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-result-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            $resultRoot = Join-Path $tempRoot "Результаты работы"
            $resultPath = Join-Path $resultRoot "branch1.cf"
            $manifestPath = "$resultPath.manifest.json"
            New-Item -ItemType Directory -Force -Path $scriptRoot, $resultRoot | Out-Null
            Set-Content -LiteralPath $resultPath -Encoding UTF8 -Value "artifact"
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value "{}"
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            $fixture = @"
param([string]`$ProjectRoot,[string]`$RunStatusPath,[string]`$RunLogPath,[string]`$Action)
`$report = "## Результат ветки``n- Файл: $resultPath``n- Манифест: $manifestPath"
`$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=`$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport=`$report; resultPath='$resultPath'; resultManifestPath='$manifestPath' }
[IO.File]::WriteAllText(`$RunStatusPath,((`$payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding `$false))
exit 0
"@
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value $fixture

            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "export-dev-branch-result"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.resultPath | Should -Be $status.resultPath
            $summary.resultManifestPath | Should -Be $status.resultManifestPath
            @($summary.artifacts) | Should -Contain $status.resultPath
            @($summary.artifacts) | Should -Contain $status.resultManifestPath
            $summary.userReport | Should -BeExactly $status.userReport
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "reports bounded live stage progress on stderr while keeping stdout as compact JSON" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-progress-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$running = [ordered]@{ schemaVersion=1; status='running'; action=$Action; updatedAt=$now.ToString('o'); stage='designer.wait'; stageDetail='Waiting for owned 1C processes and infobase release.'; errorMessage=''; exitCode=$null; lastLogPath=''; liveness='stalled-suspected'; noProgressSeconds=300; stallTimeoutRemainingSeconds=300; timeoutRemainingSeconds=3300 }
[IO.File]::WriteAllText($RunStatusPath,(($running | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Start-Sleep -Milliseconds 1200
$done = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport='done' }
[IO.File]::WriteAllText($RunStatusPath,(($done | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch"); $processResult.exitCode | Should -Be 0
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            $progress = $processResult.stderr -join "`n"
            $normalizedProgress = $progress -replace "\s+", ""
            $normalizedProgress | Should -Match "ITLprogress:stage=designer.wait;"
            $normalizedProgress | Should -Match "liveness=stalled-suspected"
            $normalizedProgress | Should -Match "noProgress=300s"
            $normalizedProgress | Should -Match "stallTimeoutRemaining=300s"
            $normalizedProgress | Should -Match "timeoutRemaining=3300s"
            $normalizedProgress | Should -Match "Waitingforowned1Cprocesses"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "fails a synchronously stale Designer status within the runner watchdog" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-stale-status-" + [guid]::NewGuid().ToString("N"))
        $previousWarning = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "Process")
        $previousTimeout = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "Process")
        $fixturePid = 0
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); stage='designer-wait'; stageDetail='completion probe entered'; liveness='running-waiting-release'; noProgressSeconds=4; stallTimeoutRemainingSeconds=0; timeoutRemainingSeconds=3596; exitCode=$null; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Start-Sleep -Seconds 30
exit 0
'@
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "1", "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "2", "Process")
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")
            $stopwatch.Stop()

            $processResult.exitCode | Should -Not -Be 0
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.status-stale"
            $summary.liveness | Should -Be "failed-stale-status"
            $summary.error | Should -Match '^RUNNER_STATUS_STALE\b'
            $summary.noProgressSeconds | Should -BeGreaterThan 4
            $summary.timeoutRemainingSeconds | Should -Be 0
            $progress = $processResult.stderr -join "`n"
            $progress | Should -Match 'liveness=stale-status'
            $progress | Should -Match 'statusAge=[1-9][0-9]*s'
            ([regex]::Matches($progress, 'liveness=running-waiting-release')).Count | Should -BeLessOrEqual 1

            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fixturePid = [int]$status.pid
            $status.errorCode | Should -Be "LIFECYCLE_OPERATION_STATUS_STALE"
            $status.stallTimeoutRemainingSeconds | Should -Be 0
            @(Get-Process -Id $fixturePid -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", $previousWarning, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", $previousTimeout, "Process")
            if ($fixturePid -gt 0) { Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "lets the helper own its published Designer stall budget before the runner watchdog fails" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-stall-owner-" + [guid]::NewGuid().ToString("N"))
        $previousWarning = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "Process")
        $previousTimeout = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "Process")
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); stage='designer-wait'; stageDetail='bounded completion probe'; liveness='probe-running'; noProgressSeconds=0; stallTimeoutRemainingSeconds=4; timeoutRemainingSeconds=60; exitCode=$null; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Start-Sleep -Seconds 30
exit 0
'@
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "1", "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "2", "Process")
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")
            $stopwatch.Stop()

            $processResult.exitCode | Should -Not -Be 0
            $stopwatch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 4
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.error | Should -Match 'effective watchdog 5s'
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", $previousWarning, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", $previousTimeout, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "ignores a transient epoch timestamp while an atomic status replacement is unreadable" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-status-epoch-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$running = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; stage='designer-wait'; stageDetail='atomic replacement window'; liveness='probe-running'; noProgressSeconds=0; stallTimeoutRemainingSeconds=10; timeoutRemainingSeconds=60; exitCode=$null; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($running | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
[IO.File]::SetLastWriteTimeUtc($RunStatusPath,[DateTime]::FromFileTimeUtc(0))
Start-Sleep -Seconds 2
$now = Get-Date
$done = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); finishedAt=$now.ToString('o'); stage='complete'; stageDetail='done'; liveness=''; noProgressSeconds=0; stallTimeoutRemainingSeconds=0; timeoutRemainingSeconds=0; exitCode=0; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($done | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")

            $processResult.exitCode | Should -Be 0
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            ($processResult.stderr -join "`n") | Should -Not -Match 'MethodArgumentConversionInvalidCastArgument'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "finalizes a running status when the helper process exits with an error" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-running-exit-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); finishedAt=$null; stage='reexec'; stageDetail='Starting child helper.'; errorMessage=''; exitCode=$null; lastLogPath='C:\logs\designer.log' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Write-Output 'child parameter binding failed'
exit 7
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch"); $processResult.exitCode | Should -Be 7; $output = $processResult.stdout
            $text = ($output -join "`n")
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.helper-exited"
            $summary.errorCategory | Should -Be "runner"
            $summary.error | Should -Match "exited with code 7 before writing a terminal status"
            $summary.nextAction | Should -Match "runner failure"

            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.status | Should -Be "failed"
            [int]$status.exitCode | Should -Be 7
            $status.finishedAt | Should -Not -BeNullOrEmpty
            $status.stageDetail | Should -Match "Last recorded stage: reexec"
            $status.lastLogPath | Should -Be "C:\logs\designer.log"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "recovers an exact lifecycle-owned Vanessa run after helper exit" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-vanessa-recovery-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param(
    [string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action,
    [string]$InterruptedVanessaInfoBasePath,[string]$InterruptedVanessaRunParamsPath,[string]$InterruptedVanessaTestPorts
)
$utf8 = New-Object Text.UTF8Encoding $false
if ($Action -eq 'cleanup-interrupted-vanessa-run') {
    $marker = [ordered]@{ infoBasePath=$InterruptedVanessaInfoBasePath; runParamsPath=$InterruptedVanessaRunParamsPath; testPorts=$InterruptedVanessaTestPorts }
    [IO.File]::WriteAllText((Join-Path $ProjectRoot 'cleanup-marker.json'),(($marker | ConvertTo-Json)+[Environment]::NewLine),$utf8)
    exit 0
}
$operationId = [guid]::NewGuid().ToString('N')
$paramsPath = Join-Path $ProjectRoot 'build\test-results\vanessa\fixture\VAParams.json'
$lifecyclePath = Join-Path $ProjectRoot '.agent-1c\locks\lifecycle-operation.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $paramsPath),(Split-Path -Parent $lifecyclePath) | Out-Null
[IO.File]::WriteAllText($paramsPath,'{}',$utf8)
$evidence = [ordered]@{ schemaVersion=1; operationId=$operationId; ownerPid=$PID; processId=$PID; projectRoot=$ProjectRoot; infoBasePath=(Join-Path $ProjectRoot '.agent-1c\infobases\branch1'); runParamsPath=$paramsPath; testPorts=@(48054,48055) }
$lifecycle = [ordered]@{ schemaVersion=1; status='running'; operationId=$operationId; action=$Action; projectRoot=$ProjectRoot; worktreePath=$ProjectRoot; pid=$PID; continuationPid=0; phase='vanessa.run'; activeVanessaRun=$evidence }
$status = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; stage='vanessa.run'; activeVanessaRun=$evidence }
[IO.File]::WriteAllText($lifecyclePath,(($lifecycle | ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
[IO.File]::WriteAllText($RunStatusPath,(($status | ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
exit 0
'@

            Push-Location $tempRoot
            try {
                $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch")
            } finally {
                Pop-Location
            }
            $processResult.exitCode | Should -Be 1
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.helper-exited"
            $summary.error | Should -Match "Exact interrupted Vanessa run cleanup succeeded"

            $marker = Get-Content -LiteralPath (Join-Path $tempRoot "cleanup-marker.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $marker.infoBasePath | Should -Be (Join-Path $tempRoot ".agent-1c\infobases\branch1")
            $marker.runParamsPath | Should -Be (Join-Path $tempRoot "build\test-results\vanessa\fixture\VAParams.json")
            $marker.testPorts | Should -Be "48054,48055"
            $lifecycle = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $lifecycle.status | Should -Be "failed"
            $lifecycle.phase | Should -Be "runner.helper-exited"
            $lifecycle.errorCode | Should -Be "LIFECYCLE_OPERATION_HELPER_EXITED"
            $lifecycle.finishedAt | Should -Not -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "survives a real Win32 Ctrl+C in the supported entrypoint helper console" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-real-ctrlc-" + [guid]::NewGuid().ToString("N"))
        $runnerProcess = $null
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            $runnerPath = Join-Path $scriptRoot "run-itl-command.ps1"
            $helperPath = Join-Path $scriptRoot "agent-1c.ps1"
            $signalerPath = Join-Path $tempRoot "send-ctrlc.ps1"
            $runnerStdout = Join-Path $tempRoot "runner.stdout.log"
            $runnerStderr = Join-Path $tempRoot "runner.stderr.log"
            $signalResultPath = Join-Path $tempRoot "signal-result.json"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination $runnerPath
            Set-Content -LiteralPath $helperPath -Encoding UTF8 -Value @'
param(
    [string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action,
    [string]$InterruptedVanessaInfoBasePath,[string]$InterruptedVanessaRunParamsPath,[string]$InterruptedVanessaTestPorts
)
$utf8 = New-Object Text.UTF8Encoding $false
if ($Action -eq 'cleanup-interrupted-vanessa-run') {
    $marker = [ordered]@{ infoBasePath=$InterruptedVanessaInfoBasePath; runParamsPath=$InterruptedVanessaRunParamsPath; testPorts=$InterruptedVanessaTestPorts; cleanupPid=$PID }
    [IO.File]::WriteAllText((Join-Path $ProjectRoot 'cleanup-marker.json'),(($marker | ConvertTo-Json)+[Environment]::NewLine),$utf8)
    exit 0
}
$operationId = [guid]::NewGuid().ToString('N')
$paramsPath = Join-Path $ProjectRoot 'build\test-results\vanessa\ctrlc\VAParams.json'
$lifecyclePath = Join-Path $ProjectRoot '.agent-1c\locks\lifecycle-operation.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $paramsPath),(Split-Path -Parent $lifecyclePath) | Out-Null
[IO.File]::WriteAllText($paramsPath,'{}',$utf8)
$evidence = [ordered]@{ schemaVersion=1; operationId=$operationId; ownerPid=$PID; processId=$PID; projectRoot=$ProjectRoot; infoBasePath=(Join-Path $ProjectRoot '.agent-1c\infobases\branch1'); runParamsPath=$paramsPath; testPorts=@(48054,48055) }
$lifecycle = [ordered]@{ schemaVersion=1; status='running'; operationId=$operationId; action=$Action; projectRoot=$ProjectRoot; worktreePath=$ProjectRoot; pid=$PID; continuationPid=0; phase='vanessa.run'; activeVanessaRun=$evidence }
$status = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; stage='vanessa.run'; activeVanessaRun=$evidence }
[IO.File]::WriteAllText($lifecyclePath,(($lifecycle | ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
[IO.File]::WriteAllText($RunStatusPath,(($status | ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
while ($true) { Start-Sleep -Seconds 1 }
'@
            Set-Content -LiteralPath $signalerPath -Encoding UTF8 -Value @'
param([int]$HelperPid,[string]$ResultPath)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ItlCtrlC {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
}
"@
[ItlCtrlC]::FreeConsole() | Out-Null
$attached = [ItlCtrlC]::AttachConsole([uint32]$HelperPid)
$ignored = $false
$signaled = $false
if ($attached) {
    $ignored = [ItlCtrlC]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
    $signaled = [ItlCtrlC]::GenerateConsoleCtrlEvent(0, 0)
    Start-Sleep -Milliseconds 500
}
[ItlCtrlC]::FreeConsole() | Out-Null
$result = [ordered]@{ attached=$attached; ignored=$ignored; signaled=$signaled }
[IO.File]::WriteAllText($ResultPath,(($result | ConvertTo-Json)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
if (-not $attached -or -not $signaled) { exit 1 }
exit 0
'@

            $runnerProcess = Start-Process -FilePath "powershell" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runnerPath, "--", "-Action", "check-dev-branch") `
                -WorkingDirectory $tempRoot `
                -RedirectStandardOutput $runnerStdout `
                -RedirectStandardError $runnerStderr `
                -WindowStyle Hidden `
                -PassThru
            $statusPath = ""
            $status = $null
            $stageDeadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $stageDeadline) {
                $statusFile = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot ".agent-1c\runs") -Filter status.json -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($statusFile.Count -eq 1) {
                    try { $status = Get-Content -LiteralPath $statusFile[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $status = $null }
                    if ($null -ne $status -and [string]$status.stage -eq "vanessa.run") {
                        $statusPath = $statusFile[0].FullName
                        break
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            $statusPath | Should -Not -BeNullOrEmpty
            $helperPid = [int]$status.pid
            $helperPid | Should -BeGreaterThan 0

            $signaler = Start-Process -FilePath "powershell" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $signalerPath, "-HelperPid", $helperPid, "-ResultPath", $signalResultPath) `
                -WindowStyle Hidden `
                -Wait `
                -PassThru
            $signaler.ExitCode | Should -Be 0
            $signal = Get-Content -LiteralPath $signalResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $signal.attached | Should -BeTrue
            $signal.signaled | Should -BeTrue

            $runnerDeadline = (Get-Date).AddSeconds(20)
            while (-not $runnerProcess.HasExited -and (Get-Date) -lt $runnerDeadline) { Start-Sleep -Milliseconds 100 }
            $runnerProcess.HasExited | Should -BeTrue
            $runnerProcess.WaitForExit()
            $summary = (Get-Content -LiteralPath $runnerStdout -Raw -Encoding UTF8).Trim() | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.helper-exited"
            $summary.error | Should -Match "Exact interrupted Vanessa run cleanup succeeded"
            $terminalStatus = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $terminalStatus.status | Should -Be "failed"
            $terminalStatus.finishedAt | Should -Not -BeNullOrEmpty
            $terminalLifecycle = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $terminalLifecycle.status | Should -Be "failed"
            $terminalLifecycle.phase | Should -Be "runner.helper-exited"
            Test-Path -LiteralPath (Join-Path $tempRoot "cleanup-marker.json") -PathType Leaf | Should -BeTrue
        } finally {
            if ($null -ne $runnerProcess -and -not $runnerProcess.HasExited) {
                Stop-Process -Id $runnerProcess.Id -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails closed when the helper exits successfully without any terminal status" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-no-status-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
Write-Output 'helper exited without status'
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch"); $processResult.exitCode | Should -Be 1; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.helper-exited"
            $summary.error | Should -Match "exited with code 0 before writing a terminal status"
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            [int]$status.exitCode | Should -Be 1
            $status.finishedAt | Should -Not -BeNullOrEmpty
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
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $text = ($output -join "`n")
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.action | Should -Be "refresh-dev-branch"
            $summary.status | Should -Be "succeeded"
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.userReport | Should -BeExactly $status.userReport
            $text | Should -Not -Match "DIAGNOSTIC_SECRET_SHOULD_STAY_IN_CONSOLE_LOG"
            (Get-Content -LiteralPath $summary.logPath -Raw -Encoding UTF8) | Should -Match "DIAGNOSTIC_SECRET_SHOULD_STAY_IN_CONSOLE_LOG"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "normalizes a zero helper exit without inventing confirmation for an unverified export" {
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
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "export-dev-branch-result"); $processResult.exitCode | Should -Be 1; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.confirmationRequired | Should -BeFalse
            $summary.nextAction | Should -Not -Match 'explicit confirmation'
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
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("-Windowed", "--", "-Action", "new-dev-branch", "-DevBranchName", "demo"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.action | Should -Be "new-dev-branch"
            $summary.logPath | Should -Be (Join-Path $runRoot "console.log")
            $status = Get-Content -LiteralPath (Join-Path $runRoot "status.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.userReport | Should -BeExactly $status.userReport
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
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("-Windowed", "--", "-Action", "new-extension-dev-branch", "-DevBranchName", "demo"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $status = Get-Content -LiteralPath (Join-Path $runRoot "status.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            $summary.nextAction | Should -Be $status.requiredAction
            $summary.devBranch | Should -Be "itldev/demo"
            $summary.worktreePath | Should -Be $worktree
            $summary.extensionInitializationStatus | Should -Be "pending"
            $summary.userReport | Should -BeExactly $status.userReport
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "preserves a structured Vanessa diagnostic recovery action without requiring the log tail" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-test-contract-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='failed'; action=$Action; stage='vanessa.failed'; stageDetail='undefined step'; errorMessage='undefined step'; exitCode=1; lastLogPath=''; errorCategory='unsupported-step'; requiredAction='fix-and-repeat-original-check' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 1
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch"); $processResult.exitCode | Should -Be 1; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.errorCategory | Should -Be "unsupported-step"
            $summary.requiredAction | Should -Be "fix-and-repeat-original-check"
            $summary.nextAction | Should -Be "fix-and-repeat-original-check"
            @($summary.PSObject.Properties.Name) | Should -Not -Contain "authoringStatus"
            @($summary.PSObject.Properties.Name) | Should -Not -Contain "authoringStatePath"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
