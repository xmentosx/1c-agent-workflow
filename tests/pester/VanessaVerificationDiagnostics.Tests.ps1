Describe "Vanessa verification diagnostics output" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $FixtureRoot = Join-Path $RepoRoot 'tests\fixtures\vanessa-verification-diagnostics'

        function New-DiagnosticsProjectRoot {
            # Every user-controlled path carries whitespace and Cyrillic together.
            $root = Join-Path ([IO.Path]::GetTempPath()) ('itl диагностика проверки ' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            return $root
        }

        function New-EventLogFixtureState {
            param([string]$Root)
            $logDir = Join-Path $Root 'База ветки\1Cv8Log'
            New-Item -ItemType Directory -Force -Path $logDir, (Join-Path $Root '.agent-1c\event-log-baselines') | Out-Null
            Copy-Item -LiteralPath (Join-Path $FixtureRoot '1Cv8.lgf') -Destination $logDir
            Copy-Item -LiteralPath (Join-Path $FixtureRoot '20261102000000.lgp') -Destination $logDir
            $baselinePath = Join-Path $Root '.agent-1c\event-log-baselines\branch10.json'
            [IO.File]::WriteAllText($baselinePath, '{"schemaVersion":2,"signatures":[]}', [Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{
                devBranchName = 'branch10'
                safeDevBranchName = 'branch10'
                infoBaseKind = 'file'
                devBranchInfoBasePath = (Join-Path $Root 'База ветки')
                stateProjectRoot = $Root
                eventLogBaselinePath = $baselinePath
            }
        }

        function New-LegacyDiagnosticRun {
            # Layout written by the 2026-11-03 PM5 runner: a copied
            # lifecycle-pending cursor without a run window and the
            # diagnostic-inputs manifest; the run's last file marks its end.
            param([string]$Root, [string]$RunId, [datetime]$LastWrite, [switch]$Proof)
            $run = Join-Path $Root "build\test-results\vanessa\$RunId"
            New-Item -ItemType Directory -Force -Path $run | Out-Null
            [IO.File]::WriteAllText((Join-Path $run 'event-log-cursor.json'), '{"schemaVersion":1,"sourceKey":"pending","capturedAt":"2026-11-02T23:11:46.1128728Z","activeSegment":"20261102000000.lgp","segments":[],"scope":"lifecycle-pending","boundaryAt":"2026-11-02T23:11:46.1128728Z"}', [Text.UTF8Encoding]::new($false))
            if (-not $Proof) { [IO.File]::WriteAllText((Join-Path $run 'diagnostic-inputs.json'), '{"schemaVersion":1,"kind":"vanessa-diagnostic-inputs"}', [Text.UTF8Encoding]::new($false)) }
            foreach ($name in @('event-log-cursor.json', 'diagnostic-inputs.json')) {
                $path = Join-Path $run $name
                if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).LastWriteTime = $LastWrite.AddMinutes(-1) }
            }
            $status = Join-Path $run 'status.json'
            [IO.File]::WriteAllText($status, '1', [Text.UTF8Encoding]::new($false))
            (Get-Item -LiteralPath $status).LastWriteTime = $LastWrite
            return $run
        }
    }

    It "puts the 2026-11-03 PM5 ErrorDetails cause before the Vanessa service error" {
        $root = New-DiagnosticsProjectRoot
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $run = Join-Path $root 'build\test-results\vanessa\run-20261103-091851-324'
                New-Item -ItemType Directory -Force -Path $run | Out-Null
                $junit = Join-Path $run 'junit.xml'
                Copy-Item -LiteralPath (Join-Path $FixtureRoot 'junit-run-20261103-091851-324.xml') -Destination $junit
                $xml = New-Object System.Xml.XmlDocument
                $xml.Load($junit)
                $raw = [string]$xml.SelectSingleNode('//*[local-name()="error"]').InnerText
                $summary = Get-VanessaJunitSummary -RunDirectory $run
                [pscustomobject]@{
                    case = @($summary.testCases | Where-Object error)[0]
                    status = Get-VanessaVerificationStatus -RunDirectory $run -StatusPath (Join-Path $run 'status.json')
                    rawSignature = Get-VanessaDiagnosticSignature -Text $raw
                    rawProtected = Protect-VanessaVerificationDiagnosticText -Text $raw
                    junit = $junit
                }
            }

            $expectedHead = 'Контроль OPEN начат до ожидания очереди либо не наблюдался при реальном сохранении {tests ОбщийМодуль.ТестПоддержкаЗаписатьПланыКак.Модуль(3085)}:'
            $result.case.diagnostic.StartsWith($expectedHead) | Should -BeTrue
            $result.status.reason | Should -Match ('First failure: ' + [regex]::Escape($expectedHead))
            $result.case.diagnostic | Should -Match ([regex]::Escape('| Vanessa: Ошибка при вызове метода контекста (ПолучитьПредставлениеДанных)'))
            $result.case.diagnostic | Should -Match ([regex]::Escape("| Technical data: $($result.junit)"))
            $result.case.diagnostic | Should -Not -Match 'PIDКлиентаТестирования|ДопПараметрыПодключения'
            $result.case.diagnosticFocus | Should -BeExactly 'vanessa-error-details'
            $result.case.diagnosticSource | Should -BeExactly 'junit-failure'
            # Decisions keep the complete original text.
            $result.case.diagnosticSignature | Should -BeExactly $result.rawSignature
            $result.status.primaryErrorSignature | Should -BeExactly $result.rawSignature
            $result.case.classificationDiagnostic | Should -BeExactly $result.rawProtected
            $result.status.status | Should -Be 'failed'
            $result.status.failureCategory | Should -Be ''
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps prior output without the marker and supports the English Vanessa locale" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            Get-VanessaErrorDetailsFocus -Text "Ошибка шага`n{Модуль(1)}:" | Should -BeNullOrEmpty
            Get-VanessaErrorDetailsFocus -Text "Шаг`nТехнические данные:`n  ИмяФичи: Ф" | Should -BeNullOrEmpty

            $english = @(
                'Context method call error (GetDataPresentation)',
                '',
                'Technical data:',
                '        ActiveFormName: ErrorWindow',
                '        ErrorDetails:',
                '                Business check failed in "Проект A"',
                '                {tests CommonModule.Checks.Module(12)}:',
                'Raise "Business check failed";'
            ) -join "`r`n"
            $focus = Get-VanessaErrorDetailsFocus -Text $english -ReportPath 'C:\Отчёты прогона\junit.xml'
            $focus.exception | Should -BeExactly 'Business check failed in "Проект A"'
            $focus.stack | Should -BeExactly '{tests CommonModule.Checks.Module(12)}:'
            $focus.text | Should -BeExactly 'Business check failed in "Проект A" {tests CommonModule.Checks.Module(12)}: | Vanessa: Context method call error (GetDataPresentation) | Technical data: C:\Отчёты прогона\junit.xml'
        }

        $root = New-DiagnosticsProjectRoot
        try {
            $case = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $xml = '<testsuite name="suite" tests="1" failures="1" errors="0"><testcase name="Без маркера"><failure message="Expected 2, got 3">The form   value differs.</failure></testcase></testsuite>'
                [IO.File]::WriteAllText((Join-Path $root 'junit.xml'), $xml, (Get-Utf8Encoding))
                @((Get-VanessaJunitSummary -RunDirectory $root).testCases)[0]
            }
            $case.diagnostic | Should -BeExactly 'Expected 2, got 3 The form value differs.'
            $case.diagnosticFocus | Should -BeExactly ''
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "selects the cause before masking and truncation and classifies on the original text" {
        $root = New-DiagnosticsProjectRoot
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $tail = 'x' * 3000
                $text = @(
                    'Не удалось подключить клиент тестирования. Прерывание по таймауту',
                    '',
                    'Технические данные:',
                    '        PIDКлиентаТестирования: 0',
                    "        Хвост: $tail",
                    '        ДеталиОшибки:',
                    '                Ошибка входа password=Секрет123 в базу',
                    '                {tests ОбщийМодуль.Вход.Модуль(7)}:'
                ) -join "`n"
                $document = New-Object System.Xml.XmlDocument
                $suite = $document.AppendChild($document.CreateElement('testsuite'))
                $suite.SetAttribute('tests', '1'); $suite.SetAttribute('failures', '0'); $suite.SetAttribute('errors', '1')
                $case = $suite.AppendChild($document.CreateElement('testcase'))
                $case.SetAttribute('name', 'Подключение')
                [void]$case.AppendChild($document.CreateElement('error')).AppendChild($document.CreateTextNode($text))
                $document.Save((Join-Path $root 'junit.xml'))
                [pscustomobject]@{
                    case = @((Get-VanessaJunitSummary -RunDirectory $root).testCases)[0]
                    status = Get-VanessaVerificationStatus -RunDirectory $root -StatusPath (Join-Path $root 'status.json')
                }
            }
            $result.case.diagnostic | Should -Match '^Ошибка входа password=<redacted> в базу \{tests ОбщийМодуль\.Вход\.Модуль\(7\)\}: \| Vanessa: Не удалось подключить клиент тестирования'
            $result.case.diagnostic | Should -Not -Match 'Секрет123'
            $result.case.diagnostic.Length | Should -BeLessOrEqual 1500
            # The TestClient startup route reads PID 0 from technical data, which
            # the display omits; the decision must still be made on the full text.
            $result.status.failureCategory | Should -BeExactly 'runner'
            $result.status.failureRequiredAction | Should -BeExactly 'inspect-testclient-startup-diagnostics-and-repeat-original-command'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "marks the 2026-11-03 errors from diagnostic Vanessa runs by window while the event-log debt stays blocking" {
        $root = New-DiagnosticsProjectRoot
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $state = New-EventLogFixtureState -Root $root
                # Last JUnit/status writes of the real PM5 run directories.
                New-LegacyDiagnosticRun -Root $root -RunId 'run-20261103-020805-934' -LastWrite ([datetime]'2026-11-03T02:09:03.908') | Out-Null
                New-LegacyDiagnosticRun -Root $root -RunId 'run-20261103-091851-324' -LastWrite ([datetime]'2026-11-03T09:20:04.432') | Out-Null
                New-LegacyDiagnosticRun -Root $root -RunId 'run-20261103-092631-297' -LastWrite ([datetime]'2026-11-03T09:27:39.111') | Out-Null
                New-LegacyDiagnosticRun -Root $root -RunId 'run-20261103-093620-260' -LastWrite ([datetime]'2026-11-03T09:37:21.584') | Out-Null
                $checkDirectory = Join-Path $root '.agent-1c\event-log-checks\run-20261103-093854-827'
                New-Item -ItemType Directory -Force -Path $checkDirectory | Out-Null
                $output = & {
                    $verification = Test-DevBranchEventLogAfterVanessa -State $state `
                        -RunStartedAt ([datetime]'2026-11-03T09:38:54.827') -RunFinishedAt ([datetime]'2026-11-03T09:38:54.827') `
                        -RunDirectory $checkDirectory -BoundaryStartedAt ([datetime]::Parse('2026-11-02T23:11:46.1128728Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()) `
                        -CursorScope 'lifecycle-pending'
                    $script:EventLogVerification = $verification
                } 6>&1 | ForEach-Object { [string]$_ }
                $verification = $script:EventLogVerification
                $debt = Resolve-DevBranchEventLogDebt -State $state -Verification $verification -Fingerprint 'fingerprint-1' -Trigger 'explicit'
                [pscustomobject]@{
                    verification = $verification
                    report = Read-Utf8Text -Path $verification.reportPath | ConvertFrom-Json
                    original = Read-Utf8Text -Path (Join-Path $FixtureRoot 'event-log-new-errors-run-20261103-093854-827.json') | ConvertFrom-Json
                    debt = $debt
                    output = @($output)
                }
            }

            $result.verification.status | Should -Be 'failed'
            $result.verification.newErrorCount | Should -Be 3
            @($result.report.errors.comment) | Should -Be @($result.original.errors.comment)
            @($result.report.errors.signature) | Should -Be @($result.original.errors.signature)
            @($result.report.errors.diagnosticRunId) | Should -Be @('run-20261103-091851-324', 'run-20261103-092631-297', 'run-20261103-093620-260')
            @($result.report.diagnosticRuns.runId) | Should -Be @('run-20261103-091851-324', 'run-20261103-092631-297', 'run-20261103-093620-260')
            $result.verification.diagnosticRunErrorCount | Should -Be 3
            $result.verification.reason | Should -Match 'contains 3 new error signature'
            $result.verification.reason | Should -Match ([regex]::Escape('run-20261103-091851-324=1, run-20261103-092631-297=1, run-20261103-093620-260=1'))
            $result.verification.reason | Should -Match 'remain event-log evidence'
            @($result.output | Where-Object { $_ -match '^Event-log errors during diagnostic Vanessa run run-20261103-091851-324: 1; .*first: Контроль OPEN начат до ожидания очереди' }) | Should -HaveCount 1
            @($result.output | Where-Object { $_ -match 'run-20261103-020805-934' }) | Should -HaveCount 0
            # User decision 2026-11-05 (variant a): marking is output only.
            $result.debt.updates['eventLogDebtStatus'] | Should -BeExactly 'failed'
            $result.debt.updates['eventLogDebtFingerprint'] | Should -BeExactly 'fingerprint-1'
            $result.debt.verification.status | Should -Be 'failed'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "uses recorded run windows and never marks errors from proof runs" {
        $root = New-DiagnosticsProjectRoot
        try {
            $windows = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                foreach ($item in @(
                    @{ id = 'run-20261103-091851-324'; diagnostic = $true; finished = '2026-11-03T09:20:30.0000000+03:00' },
                    @{ id = 'run-20261103-092631-297'; diagnostic = $false; finished = '2026-11-03T09:28:00.0000000+03:00' }
                )) {
                    $run = Join-Path $root "build\test-results\vanessa\$($item.id)"
                    New-Item -ItemType Directory -Force -Path $run | Out-Null
                    $cursor = [ordered]@{ schemaVersion = 1; sourceKey = 'k'; capturedAt = '2026-11-02T23:11:46.1128728Z'; segments = @()
                        scope = 'lifecycle-pending'; runStartedAt = ([datetime]::ParseExact($item.id, "'run-'yyyyMMdd-HHmmss-fff", $null)).ToString('o')
                        diagnosticRun = $item.diagnostic; runFinishedAt = $item.finished }
                    Write-Utf8TextAtomic -Path (Join-Path $run 'event-log-cursor.json') -Value ($cursor | ConvertTo-Json -Depth 4)
                    # A manifest alone never overrides the recorded role.
                    [IO.File]::WriteAllText((Join-Path $run 'diagnostic-inputs.json'), '{}')
                }
                @(Get-VanessaDiagnosticRunWindows -From ([datetime]'2026-11-03T00:00:00') -To ([datetime]'2026-11-03T23:00:00'))
            }
            @($windows.runId) | Should -Be @('run-20261103-091851-324')
            $windows[0].finishedAt | Should -Be ([datetimeoffset]::Parse('2026-11-03T09:20:30.0000000+03:00').LocalDateTime)
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "warns about a background-job error during a named Vanessa run without evidence or cursor changes" {
        $root = New-DiagnosticsProjectRoot
        try {
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $state = New-EventLogFixtureState -Root $root
                $logDir = Join-Path $state.devBranchInfoBasePath '1Cv8Log'
                $cursorPath = Join-Path $root 'build\test-results\vanessa\run-20261103-091851-324\event-log-cursor.json'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cursorPath) | Out-Null
                New-DevBranchEventLogCursor -State $state -Path $cursorPath | Out-Null
                $pendingPath = Get-DevBranchEventLogPendingCursorPath -State $state
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pendingPath) | Out-Null
                Copy-Item -LiteralPath $cursorPath -Destination $pendingPath
                $pendingHash = (Get-FileHash -LiteralPath $pendingPath -Algorithm SHA256).Hash
                # The background job runs in its own session; the record is
                # appended to the active segment after the run cursor.
                $segment = Join-Path $logDir '20261102000000.lgp'
                $record = @(
                    '{20261103100130,N,',
                    '{0,0},1,1,2,1,29,E,"Фоновое задание: деление на ноль в ""Проект A""',
                    '{ОбщийМодуль.ФоновыйРасчет.Модуль(12)}:Результат = 1 / 0;",0,',
                    '{"U"},"",0,0,0,1,0,',
                    '{2,1,1,2,1}',
                    '},',
                    ''
                ) -join "`n"
                [IO.File]::AppendAllText($segment, $record, [Text.UTF8Encoding]::new($false))
                $runDirectory = Split-Path -Parent $cursorPath
                $output = & {
                    # The fixture segment's earlier records predate this window,
                    # including the reader's deliberately repeated safe tail.
                    Write-VanessaRunEventLogPreview -State $state -RunDirectory $runDirectory -CursorPath $cursorPath `
                        -RunStartedAt ([datetime]'2026-11-03T10:00:00') -RunFinishedAt ([datetime]'2026-11-03T10:05:00')
                } 6>&1 | ForEach-Object { [string]$_ }
                [pscustomobject]@{
                    output = @($output)
                    pendingUnchanged = (Get-FileHash -LiteralPath $pendingPath -Algorithm SHA256).Hash -eq $pendingHash
                    preview = Test-Path -LiteralPath (Join-Path $runDirectory 'event-log-preview.json')
                    evidence = Test-Path -LiteralPath (Join-Path $runDirectory 'event-log-new-errors.json')
                    baseline = Read-Utf8Text -Path $state.eventLogBaselinePath
                }
            }
            $warning = @($result.output | Where-Object { $_ -like '`[WARN`] VANESSA_EVENT_LOG_PREVIEW:*' })
            $warning | Should -HaveCount 1
            $warning[0] | Should -Match '1 new 1C event-log error signature\(s\) during this run window, including background jobs; first: Фоновое задание: деление на ноль в "Проект A"; report=.*event-log-preview\.json; durationMs=\d+\. Diagnostic output only'
            $result.preview | Should -BeTrue
            $result.evidence | Should -BeFalse
            $result.pendingUnchanged | Should -BeTrue
            $result.baseline | Should -BeExactly '{"schemaVersion":2,"signatures":[]}'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "requests the preview only for a named run that leaves event-log out of scope" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlVerificationMode { param($Component) [pscustomobject]@{ valid = $true; effective = $script:FixtureEventLogMode } }
            $script:FixtureEventLogMode = 'auto'
            $script:ItlSkipEventLogForVerification = $true
            $ExplicitVerificationComponent = 'vanessa'
            Test-VanessaRunEventLogPreviewRequested | Should -BeTrue
            Test-VanessaRunEventLogPreviewRequested -AuxiliaryVerification | Should -BeFalse
            $script:FixtureEventLogMode = 'off'
            Test-VanessaRunEventLogPreviewRequested | Should -BeFalse
            $script:FixtureEventLogMode = 'manual'
            $ExplicitVerificationComponent = ''
            Test-VanessaRunEventLogPreviewRequested | Should -BeFalse
            $ExplicitVerificationComponent = 'vanessa'
            $script:ItlSkipEventLogForVerification = $false
            Test-VanessaRunEventLogPreviewRequested | Should -BeFalse
        }
    }

    It "keeps the preview outside the verification result and its event-log evidence" {
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot '.agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1') -Raw -Encoding UTF8
        $body = $text.Substring($text.IndexOf('function Write-VanessaRunEventLogPreview'))
        $body = $body.Substring(0, $body.IndexOf("`nfunction ", 10))
        $body | Should -Not -Match 'Resolve-DevBranchEventLogDebt|Complete-DevBranchEventLogObservation|Update-DevBranchState|Update-ActiveVanessaVerificationState|\$verification'
        $success = $text.Substring($text.IndexOf('$verification = Get-VanessaVerificationStatus -RunDirectory $runDirectory -StatusPath $statusPath'))
        $success.IndexOf('$postProcessStopwatch.Stop()') | Should -BeLessThan $success.IndexOf('Write-VanessaRunEventLogPreview')
        # The scan is bounded by a run-local cursor taken before TestManager,
        # never by the copied lifecycle-pending debt range.
        $text | Should -Match ([regex]::Escape('New-DevBranchEventLogCursor -State $state -Path (Join-Path $runDirectory "event-log-preview-cursor.json")'))
        ([regex]::Matches($text, [regex]::Escape('Write-VanessaRunEventLogPreview -State $state -RunDirectory $runDirectory -CursorPath $eventLogPreviewCursorPath'))).Count | Should -Be 2
        $text.IndexOf('event-log-preview-cursor.json') | Should -BeLessThan $text.IndexOf('-Stage "vanessa.run"')
    }
}
