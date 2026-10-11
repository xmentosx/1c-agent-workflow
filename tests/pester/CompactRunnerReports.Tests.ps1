Describe "compact ITL command runner" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $RunnerSource = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1"
        $TimeoutPolicySource = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\itl-runner-timeout.ps1"
        function Copy-RunnerFixture {
            param([string]$Destination)
            $scriptRoot = Split-Path -Parent $Destination
            $libRoot = Join-Path $scriptRoot "lib"
            New-Item -ItemType Directory -Force -Path $libRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination $Destination
            Copy-Item -LiteralPath $TimeoutPolicySource -Destination (Join-Path $libRoot "itl-runner-timeout.ps1")
        }
    }

    It "stores full output and returns a bounded successful summary" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-success-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            [IO.File]::WriteAllText((Join-Path $scriptRoot "agent-1c.ps1"), @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="## Результат`n- Browser: включён`n- Рекомендация: выполните /reload" }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Write-Output 'Проверка UTF-8 журнала'
Write-Output ('x' * 12000)
exit 0
'@, [Text.UTF8Encoding]::new($true))
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $text = ($output -join "`n")
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.action | Should -Be "check-dev-branch"
            $summary.status | Should -Be "succeeded"
            $summary.confirmationRequired | Should -BeFalse
            $summary.responseStyle.mode | Should -Be "auto"
            $summary.responseStyle.level | Should -Be "full"
            $summary.responseStyle.active | Should -BeTrue
            $summary.responseStyle.profile | Should -Be "caveman-full"
            $summary.responseStyle.taskClass | Should -Be "execution"
            ($processResult.stderr -join "`n") | Should -Match 'ITL response-style: mode=auto; level=full; active=true; profile=caveman-full; task=execution'
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
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            [IO.File]::WriteAllText((Join-Path $scriptRoot "agent-1c.ps1"), @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$reportPath = Join-Path $ProjectRoot 'source integrity отчёт.json'
[IO.File]::WriteAllText($reportPath,'{"schemaVersion":1}',(New-Object Text.UTF8Encoding $false))
$payload = [ordered]@{ schemaVersion=1; status='failed'; action=$Action; stage='source-integrity.failed'; stageDetail='invalid merged source'; errorMessage='ONEC_SOURCE_INTEGRITY_FAILED'; errorCategory='source-integrity'; requiredAction='agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit'; exitCode=1; lastLogPath=''; sourceIntegrityReportPath=$reportPath }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 1
'@, [Text.UTF8Encoding]::new($true))
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

    It "preserves a complete long repository-lock report and recovery action on failure" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('itl partial report захват с пробелом ' + [guid]::NewGuid().ToString('N'))
        try {
            $scriptRoot = Join-Path $tempRoot '.agents/skills/1c-workflow/scripts'
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot 'run-itl-command.ps1')
            [IO.File]::WriteAllText((Join-Path $scriptRoot 'agent-1c.ps1'), @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$lines = @('## Захват объектов в хранилище', '- Результат: операция завершилась с ошибкой', '### Захваченные объекты')
$lines += @(1..90 | ForEach-Object { "- ОбщийМодуль.ЗахваченныйОбъектСДлиннымКириллическимИменем$_ (partial)" })
$lines += @('### Не захвачены', '- Справочник.Планы.Форма.ФормаЭлемента — ДругойПользователь', '### Отсутствуют', '- Константа.Новая')
$report = $lines -join [Environment]::NewLine
$payload = [ordered]@{ schemaVersion=1; status='failed'; action=$Action; stage='repository-lock.conflict'; stageDetail='partial lock'; errorMessage='LOCK_CONFIG_REPOSITORY_OBJECT_CONFLICT'; errorCategory='runner'; requiredAction='Согласуйте освобождение с ДругойПользователь'; exitCode=1; lastLogPath=''; userReport=$report }
[IO.File]::WriteAllText($RunStatusPath,($payload | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
exit 1
'@, [Text.UTF8Encoding]::new($true))
            Push-Location $tempRoot
            try {
                $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot 'run-itl-command.ps1') -Arguments @('--', '-Action', 'lock-config-repository-objects')
            } finally { Pop-Location }
            $processResult.exitCode | Should -Be 1
            $text = $processResult.stdout -join "`n"
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.status | Should -Be 'failed'
            $summary.userReportOmitted | Should -BeTrue
            $summary.userReportSource | Should -Be 'file'
            [IO.Path]::IsPathRooted($summary.userReportPath) | Should -BeTrue
            $summary.requiredAction | Should -Be 'Согласуйте освобождение с ДругойПользователь'
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fullReport = Get-Content -LiteralPath $summary.userReportPath -Raw -Encoding UTF8
            $fullReport | Should -BeExactly $status.userReport
            ([regex]::Matches($fullReport, '(?m)^- ОбщийМодуль\.')).Count | Should -Be 90
            $fullReport | Should -Match 'ДругойПользователь'
            $fullReport | Should -Match 'Константа.Новая'
            @($summary.artifacts) | Should -Contain $summary.userReportPath
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    It "preserves semantic success and exposes an absolute report file for every long-report action" {
        foreach ($action in @("export-dev-branch-result", "lock-config-repository-objects", "update-workflow", "refresh-all-dev-branches")) {
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl long report путь с пробелом " + $action + "-" + [guid]::NewGuid().ToString("N"))
            try {
                $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
                New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
                Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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
$payload.refreshMasterCommit = '77ba2ef1c135802fef6de34a92bb86307ba7f0d6'
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
                $summary.refreshMasterCommit | Should -Be '77ba2ef1c135802fef6de34a92bb86307ba7f0d6'
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
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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

    It "runs repair-session creation through the compact boundary and returns its session id" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-repair-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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

    It 'forwards a named one-off proof run and its evidence path through the compact boundary' {
        $tempRoot = Join-Path $TestDrive ('One off compact Кириллица ' + [guid]::NewGuid().ToString('N'))
        $scriptRoot = Join-Path $tempRoot '.agents/skills/1c-workflow/scripts'
        New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
        Copy-RunnerFixture -Destination (Join-Path $scriptRoot 'run-itl-command.ps1')
        Set-Content -LiteralPath (Join-Path $scriptRoot 'agent-1c.ps1') -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action,[string]$VerificationObligationId,[string]$VerificationEvidencePath)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="$Action|$VerificationObligationId|$VerificationEvidencePath" }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
        Push-Location $tempRoot
        try {
            $begin = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'run-itl-command.ps1') -- -Action begin-one-off-proof -VerificationObligationId orders-result | ConvertFrom-Json
            $begin.userReport | Should -Be 'begin-one-off-proof|orders-result|'
            $complete = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'run-itl-command.ps1') -- -Action complete-one-off-proof -VerificationEvidencePath 'evidence/Результат.json' | ConvertFrom-Json
            $complete.userReport | Should -Be 'complete-one-off-proof||evidence/Результат.json'
        } finally { Pop-Location }
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
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            $fixture = @"
param([string]`$ProjectRoot,[string]`$RunStatusPath,[string]`$RunLogPath,[string]`$Action)
`$report = "## Результат ветки``n- Файл: $resultPath``n- Манифест: $manifestPath"
`$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=`$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport=`$report; resultPath='$resultPath'; resultManifestPath='$manifestPath' }
[IO.File]::WriteAllText(`$RunStatusPath,((`$payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding `$false))
exit 0
"@
            [IO.File]::WriteAllText((Join-Path $scriptRoot "agent-1c.ps1"), $fixture, [Text.UTF8Encoding]::new($true))

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
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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

    It "returns the refresh user report byte-for-byte without exposing the diagnostic log" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-refresh-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            [IO.File]::WriteAllText((Join-Path $scriptRoot "run-agent-1c-window.ps1"), @"
`$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action='new-extension-dev-branch'; stage='extension-init.pending'; stageDetail='waiting'; errorMessage=''; exitCode=0; lastLogPath=''; requiredAction='Уточните режим расширения в чате; не показывайте PowerShell.'; devBranch='itldev/demo'; worktreePath='$($worktree.Replace("'", "''"))'; extensionInitializationStatus='pending'; userReport="## Ветка разработки`n- Тип: расширение`n- Инициализация расширения: ожидает настройки`n`n## Инструкции и рекомендации`n- Уточните режим расширения в чате." }
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\status.json',((`$payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding `$false))
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\console.log','pending branch log',(New-Object Text.UTF8Encoding `$false))
Write-Output 'Run directory: $runRoot'
exit 0
"@, [Text.UTF8Encoding]::new($true))
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
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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
