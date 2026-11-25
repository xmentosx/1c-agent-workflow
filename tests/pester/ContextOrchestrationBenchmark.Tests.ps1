Describe "Installed-project context orchestration benchmark" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HarnessPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\context-orchestration-benchmark.ps1"
        $ExactFixturePath = Join-Path $PSScriptRoot "fixtures\context-orchestration-benchmark\exact.json"

        function Copy-ContextBenchmarkFixture {
            param([scriptblock]$Mutate)

            $document = Get-Content -LiteralPath $ExactFixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
            & $Mutate $document
            $path = Join-Path ([IO.Path]::GetTempPath()) ("itl-context-orchestration-" + [guid]::NewGuid().ToString("N") + ".json")
            [IO.File]::WriteAllText($path, (($document | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            return $path
        }
    }

    BeforeEach {
        . $HarnessPath
    }

    It "compares complete S0 C R H records and selects only the mode that passes the decision gate" {
        $result = Invoke-ItlContextOrchestrationBenchmark -InputPath $ExactFixturePath

        $result.kind | Should -Be "itl-context-orchestration-benchmark-summary"
        $result.schemaVersion | Should -Be 1
        @($result.modes.mode) | Should -Be @("C", "H", "R", "S0")
        ($result.modes | Where-Object mode -eq "H").decisionStatus | Should -Be "eligible"
        ($result.modes | Where-Object mode -eq "C").decisionStatus | Should -Be "ineligible"
        ($result.modes | Where-Object mode -eq "R").decisionStatus | Should -Be "ineligible"
        ($result.modes | Where-Object mode -eq "S0").decisionStatus | Should -Be "baseline"
        $result.realPilotStatus | Should -Be "blocked-until-installed-projects-are-explicitly-named"
    }

    It "calculates total tokens across parent and child calls instead of reporting parent savings as total savings" {
        $result = Invoke-ItlContextOrchestrationBenchmark -InputPath $ExactFixturePath
        $hybrid = $result.modes | Where-Object mode -eq "H"

        $hybrid.telemetryQualification | Should -Be "exact"
        $hybrid.medianTotalTokens | Should -Be 7150
        $hybrid.totalTokenReductionPercent | Should -Be 35
        $hybrid.peakParentContextReductionPercent | Should -Be 50
        $hybrid.elapsedRegressionPercent | Should -Be 10
    }

    It "requires one comparable record for every S0 C R H mode and scenario" {
        $path = Copy-ContextBenchmarkFixture { param($document) $document.records = @($document.records | Where-Object mode -ne "R") }
        try {
            { Invoke-ItlContextOrchestrationBenchmark -InputPath $path } | Should -Throw "*ITL_CONTEXT_BENCHMARK_MATRIX_INCOMPLETE*"
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails correctness equality when a candidate outcome differs from S0" {
        $path = Copy-ContextBenchmarkFixture {
            param($document)
            ($document.records | Where-Object { $_.mode -eq "H" -and $_.scenarioId -eq "diagnostic" }).result.outcomeFingerprint = "sha256:different-result"
        }
        try {
            $result = Invoke-ItlContextOrchestrationBenchmark -InputPath $path
            $hybrid = $result.modes | Where-Object mode -eq "H"
            $hybrid.correctnessEligible | Should -BeFalse
            $hybrid.decisionStatus | Should -Be "ineligible"
            @($hybrid.reasons) | Should -Contain "OUTCOME_MISMATCH"
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects an unproven S0 baseline instead of qualifying candidates against a failed control" {
        $path = Copy-ContextBenchmarkFixture {
            param($document)
            $record = $document.records | Where-Object { $_.mode -eq "S0" -and $_.scenarioId -eq "diagnostic" }
            $record.result.status = "failed"
            $record.result.passedGates = @("scope")
        }
        try {
            { Invoke-ItlContextOrchestrationBenchmark -InputPath $path } | Should -Throw "*ITL_CONTEXT_BENCHMARK_BASELINE_INVALID*"
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails correctness equality when required gate evidence or locked decisions are lost" {
        $path = Copy-ContextBenchmarkFixture {
            param($document)
            $record = $document.records | Where-Object { $_.mode -eq "H" -and $_.scenarioId -eq "full-cycle" }
            $record.result.passedGates = @("syntaxcheck")
            $record.result.lockedDecisionsPreserved = 2
        }
        try {
            $result = Invoke-ItlContextOrchestrationBenchmark -InputPath $path
            $hybrid = $result.modes | Where-Object mode -eq "H"
            $hybrid.correctnessEligible | Should -BeFalse
            @($hybrid.reasons) | Should -Contain "REQUIRED_GATE_MISSING"
            @($hybrid.reasons) | Should -Contain "LOCKED_DECISION_LOST"
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps proxy telemetry functional-only and does not estimate token savings" {
        $path = Copy-ContextBenchmarkFixture {
            param($document)
            foreach ($record in @($document.records | Where-Object mode -eq "H")) {
                $record.telemetry.tokenEvidence = "proxy"
                foreach ($name in @("parentInputTokens", "parentOutputTokens", "childInputTokens", "childOutputTokens", "peakParentContextTokens")) {
                    $record.telemetry.PSObject.Properties.Remove($name)
                }
                $record.telemetry | Add-Member -NotePropertyName messageCharacters -NotePropertyValue 42000
            }
        }
        try {
            $result = Invoke-ItlContextOrchestrationBenchmark -InputPath $path
            $hybrid = $result.modes | Where-Object mode -eq "H"
            $hybrid.correctnessEligible | Should -BeTrue
            $hybrid.telemetryQualification | Should -Be "proxy"
            $hybrid.decisionStatus | Should -Be "functional-only"
            $hybrid.totalTokenReductionPercent | Should -BeNullOrEmpty
            $hybrid.peakParentContextReductionPercent | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps unavailable telemetry functional-only without accepting token or message counters" {
        $path = Copy-ContextBenchmarkFixture {
            param($document)
            foreach ($record in @($document.records | Where-Object mode -eq "H")) {
                $record.telemetry.tokenEvidence = "unavailable"
                foreach ($name in @("parentInputTokens", "parentOutputTokens", "childInputTokens", "childOutputTokens", "peakParentContextTokens")) {
                    $record.telemetry.PSObject.Properties.Remove($name)
                }
            }
        }
        try {
            $result = Invoke-ItlContextOrchestrationBenchmark -InputPath $path
            $hybrid = $result.modes | Where-Object mode -eq "H"
            $hybrid.telemetryQualification | Should -Be "unavailable"
            $hybrid.decisionStatus | Should -Be "functional-only"
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects mixed exact and proxy telemetry instead of inventing a token comparison" {
        $path = Copy-ContextBenchmarkFixture {
            param($document)
            $record = $document.records | Where-Object { $_.mode -eq "H" -and $_.scenarioId -eq "diagnostic" }
            $record.telemetry.tokenEvidence = "proxy"
            $record.telemetry | Add-Member -NotePropertyName messageCharacters -NotePropertyValue 42000
        }
        try {
            { Invoke-ItlContextOrchestrationBenchmark -InputPath $path } | Should -Throw "*ITL_CONTEXT_BENCHMARK_TELEMETRY_INVALID*"
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects raw transcripts tool arguments and undeclared fields" {
        $path = Copy-ContextBenchmarkFixture {
            param($document)
            $document.records[0] | Add-Member -NotePropertyName rawTranscript -NotePropertyValue "secret conversation"
        }
        try {
            { Invoke-ItlContextOrchestrationBenchmark -InputPath $path } | Should -Throw "*ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID*rawTranscript*"
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It "writes only an aggregate summary with no source records or raw content" {
        $outputPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-context-summary-" + [guid]::NewGuid().ToString("N") + ".json")
        try {
            $result = Invoke-ItlContextOrchestrationBenchmark -InputPath $ExactFixturePath -OutputPath $outputPath
            $saved = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8
            $saved | Should -Match 'itl-context-orchestration-benchmark-summary'
            $saved | Should -Not -Match 'records|transcript|toolArguments|prompt|messages'
            $result.outputPath | Should -Be $outputPath
        } finally {
            Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        }
    }
}
