BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Delivery target report" {
    It "reports weekly targets from existing run records, counting retries of a qualified tree" {
        $runRoot = Join-Path $TestDrive "журнал прогонов с пробелом"
        New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
        $records = @(
            @{ mode = "Targeted"; status = "passed"; at = "2026-11-17T08:00:00Z"; min = 5; tree = "t1" },
            @{ mode = "Targeted"; status = "passed"; at = "2026-11-17T09:00:00Z"; min = 8; tree = "t2" },
            @{ mode = "Targeted"; status = "failed"; at = "2026-11-17T10:00:00Z"; min = 60; tree = "t3"; error = "Targeted source gate exceeded its hard/no-progress budget." },
            @{ mode = "Targeted"; status = "failed"; at = "2026-11-17T11:00:00Z"; min = 4; tree = "t3"; error = "Targeted source gate failed with exit code 1." },
            @{ mode = "Develop"; status = "passed"; at = "2026-11-18T08:00:00Z"; min = 30; tree = "c1" },
            @{ mode = "Release"; status = "failed"; at = "2026-11-18T09:00:00Z"; min = 20; tree = "c1"; error = "release-e2e failed with exit code 1." },
            @{ mode = "Release"; status = "passed"; at = "2026-11-18T10:00:00Z"; min = 25; tree = "c1" },
            @{ mode = "Targeted"; status = "passed"; at = "2026-10-01T08:00:00Z"; min = 99; tree = "old" }
        )
        $index = 0
        foreach ($record in $records) {
            $index++
            $run = [ordered]@{ schemaVersion = 3; mode = $record.mode; status = $record.status; startedAt = $record.at; durationMs = [int64]($record.min * 60000); tree = $record.tree; error = $(if ($record.ContainsKey("error")) { $record.error } else { "" }) }
            [IO.File]::WriteAllText((Join-Path $runRoot ("run-$index.json")), ($run | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText((Join-Path $runRoot "broken.json"), "{ not json", [Text.UTF8Encoding]::new($false))

        $run = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot "scripts\delivery-metrics.ps1") -Arguments @("-RunRoot", $runRoot, "-Weeks", "1", "-Now", "2026-11-20T12:00:00Z")
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $report = ($run.stdout -join [Environment]::NewLine) | ConvertFrom-Json
        $report.targets.targetedP90Minutes | Should -Be 10
        @($report.weeks).Count | Should -Be 1
        $week = $report.weeks[0]
        $week.week | Should -Be "2026-11-16"
        $week.runs | Should -Be 7
        $week.targetedRuns | Should -Be 4
        $week.targetedTimeouts | Should -Be 1
        $week.targetedFailureRate | Should -Be 0.5
        $week.targetedP90Minutes | Should -Be 8
        $week.publications | Should -Be 1
        # Develop 30 + failed Release 20 + passed Release 25 on the qualified tree.
        $week.publicationP90Minutes | Should -Be 75
        $week.repeatedFailuresOnUnchangedTree | Should -Be 1
        $week.failedHours | Should -Be 1.4
        $report.latestWeek | Should -Be "missed: publicationP90Minutes, repeatedFailuresOnUnchangedTree"
    }
}
