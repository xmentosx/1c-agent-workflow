[CmdletBinding()]
param(
    [string]$InputPath = "",
    [string]$OutputPath = "",
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-ItlContextBenchmarkProperties {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $true)][string]$Location
    )

    if ($null -eq $Value -or $null -eq $Value.PSObject) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $Location must be an object."
    }
    $names = @($Value.PSObject.Properties.Name)
    $unknown = @($names | Where-Object { $Allowed -notcontains $_ } | Sort-Object -Unique)
    if ($unknown.Count -gt 0) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $Location contains undeclared field(s): $($unknown -join ', ')."
    }
    $missing = @($Required | Where-Object { $names -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $Location is missing field(s): $($missing -join ', ')."
    }
}

function Assert-ItlContextBenchmarkString {
    param($Value, [string]$Location)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $Location must be a non-empty string."
    }
}

function Assert-ItlContextBenchmarkCounter {
    param($Value, [string]$Location)
    $number = 0L
    if ($null -eq $Value -or -not [long]::TryParse(([string]$Value), [ref]$number) -or $number -lt 0) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $Location must be a non-negative integer."
    }
}

function Assert-ItlContextBenchmarkStringArray {
    param($Value, [string]$Location)
    if ($null -eq $Value) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $Location must be an array."
    }
    foreach ($item in @($Value)) {
        Assert-ItlContextBenchmarkString -Value $item -Location $Location
    }
    if (@($Value).Count -ne @($Value | Sort-Object -Unique).Count) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $Location contains duplicate values."
    }
}

function Test-ItlContextBenchmarkHasProperty {
    param($Value, [string]$Name)
    return $null -ne $Value.PSObject.Properties[$Name]
}

function Assert-ItlContextBenchmarkRecord {
    param($Record, [int]$Index)

    $location = "records[$Index]"
    $recordFields = @("schemaVersion", "kind", "runId", "scenarioId", "mode", "client", "model", "projectFingerprint", "checkout", "result", "telemetry", "privacy")
    Assert-ItlContextBenchmarkProperties -Value $Record -Allowed $recordFields -Required $recordFields -Location $location
    if ([int]$Record.schemaVersion -ne 1 -or [string]$Record.kind -ne "itl-context-orchestration-record") {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $location has unsupported schemaVersion or kind."
    }
    foreach ($name in @("runId", "scenarioId", "client", "model", "projectFingerprint")) {
        Assert-ItlContextBenchmarkString -Value $Record.$name -Location "$location.$name"
    }
    if (@("S0", "C", "R", "H") -notcontains [string]$Record.mode) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $location.mode must be one of S0, C, R, H."
    }

    $checkoutFields = @("commit", "dirtyFingerprint", "infobaseFingerprint")
    Assert-ItlContextBenchmarkProperties -Value $Record.checkout -Allowed $checkoutFields -Required $checkoutFields -Location "$location.checkout"
    foreach ($name in $checkoutFields) {
        Assert-ItlContextBenchmarkString -Value $Record.checkout.$name -Location "$location.checkout.$name"
    }

    $resultFields = @("status", "outcomeFingerprint", "requiredGates", "passedGates", "lockedDecisionsTotal", "lockedDecisionsPreserved", "wrongScopeActions", "dirtyStateViolations")
    Assert-ItlContextBenchmarkProperties -Value $Record.result -Allowed $resultFields -Required $resultFields -Location "$location.result"
    if (@("passed", "failed", "blocked") -notcontains [string]$Record.result.status) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $location.result.status is invalid."
    }
    Assert-ItlContextBenchmarkString -Value $Record.result.outcomeFingerprint -Location "$location.result.outcomeFingerprint"
    Assert-ItlContextBenchmarkStringArray -Value $Record.result.requiredGates -Location "$location.result.requiredGates"
    Assert-ItlContextBenchmarkStringArray -Value $Record.result.passedGates -Location "$location.result.passedGates"
    foreach ($name in @("lockedDecisionsTotal", "lockedDecisionsPreserved", "wrongScopeActions", "dirtyStateViolations")) {
        Assert-ItlContextBenchmarkCounter -Value $Record.result.$name -Location "$location.result.$name"
    }
    if ([long]$Record.result.lockedDecisionsPreserved -gt [long]$Record.result.lockedDecisionsTotal) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $location preserves more locked decisions than declared."
    }

    $commonTelemetry = @("tokenEvidence", "duplicateArtifactReads", "duplicateUnchangedGates", "elapsedMilliseconds", "resumeTargetedReads", "checkpointTokens", "handoffCount", "subtaskCount", "contextOverflowEvents")
    $exactTelemetry = @("parentInputTokens", "parentOutputTokens", "childInputTokens", "childOutputTokens", "peakParentContextTokens")
    $proxyTelemetry = @("messageCharacters")
    $telemetryFields = @($commonTelemetry + $exactTelemetry + $proxyTelemetry)
    Assert-ItlContextBenchmarkProperties -Value $Record.telemetry -Allowed $telemetryFields -Required $commonTelemetry -Location "$location.telemetry"
    foreach ($name in @($commonTelemetry | Where-Object { $_ -ne "tokenEvidence" })) {
        Assert-ItlContextBenchmarkCounter -Value $Record.telemetry.$name -Location "$location.telemetry.$name"
    }
    if ([long]$Record.telemetry.elapsedMilliseconds -le 0) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: $location.telemetry.elapsedMilliseconds must be greater than zero."
    }

    $evidence = [string]$Record.telemetry.tokenEvidence
    if (@("exact", "proxy", "unavailable") -notcontains $evidence) {
        throw "ITL_CONTEXT_BENCHMARK_TELEMETRY_INVALID: $location.telemetry.tokenEvidence must be exact, proxy, or unavailable."
    }
    $presentExact = @($exactTelemetry | Where-Object { Test-ItlContextBenchmarkHasProperty -Value $Record.telemetry -Name $_ })
    $hasProxy = Test-ItlContextBenchmarkHasProperty -Value $Record.telemetry -Name "messageCharacters"
    switch ($evidence) {
        "exact" {
            $missing = @($exactTelemetry | Where-Object { $presentExact -notcontains $_ })
            if ($missing.Count -gt 0 -or $hasProxy) {
                throw "ITL_CONTEXT_BENCHMARK_TELEMETRY_INVALID: $location exact telemetry is incomplete or mixed with proxy data."
            }
            foreach ($name in $exactTelemetry) {
                Assert-ItlContextBenchmarkCounter -Value $Record.telemetry.$name -Location "$location.telemetry.$name"
            }
        }
        "proxy" {
            if ($presentExact.Count -gt 0 -or -not $hasProxy) {
                throw "ITL_CONTEXT_BENCHMARK_TELEMETRY_INVALID: $location proxy telemetry must contain messageCharacters and no token counters."
            }
            Assert-ItlContextBenchmarkCounter -Value $Record.telemetry.messageCharacters -Location "$location.telemetry.messageCharacters"
        }
        "unavailable" {
            if ($presentExact.Count -gt 0 -or $hasProxy) {
                throw "ITL_CONTEXT_BENCHMARK_TELEMETRY_INVALID: $location unavailable telemetry must not contain token or proxy counters."
            }
        }
    }

    $privacyFields = @("sanitized", "containsRawTranscript", "containsSecrets", "containsToolArguments")
    Assert-ItlContextBenchmarkProperties -Value $Record.privacy -Allowed $privacyFields -Required $privacyFields -Location "$location.privacy"
    if (-not [bool]$Record.privacy.sanitized -or [bool]$Record.privacy.containsRawTranscript -or [bool]$Record.privacy.containsSecrets -or [bool]$Record.privacy.containsToolArguments) {
        throw "ITL_CONTEXT_BENCHMARK_PRIVACY_INVALID: $location must be sanitized and must not contain raw transcripts, secrets, or tool arguments."
    }
}

function Get-ItlContextBenchmarkMedian {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $middle = [math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Get-ItlContextBenchmarkPercentChange {
    param([double]$Baseline, [double]$Candidate, [switch]$Reduction)
    if ($Baseline -le 0) { return $null }
    $value = if ($Reduction) { (($Baseline - $Candidate) / $Baseline) * 100 } else { (($Candidate - $Baseline) / $Baseline) * 100 }
    return [math]::Round($value, 2)
}

function Test-ItlContextBenchmarkSetEqual {
    param($Left, $Right)
    return (@($Left | Sort-Object) -join "`n") -ceq (@($Right | Sort-Object) -join "`n")
}

function Get-ItlContextBenchmarkRecordReasons {
    param($Baseline, $Candidate)
    $reasons = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @("client", "model", "projectFingerprint")) {
        if ([string]$Candidate.$name -cne [string]$Baseline.$name) { $reasons.Add("INPUT_MISMATCH") }
    }
    foreach ($name in @("commit", "dirtyFingerprint", "infobaseFingerprint")) {
        if ([string]$Candidate.checkout.$name -cne [string]$Baseline.checkout.$name) { $reasons.Add("INPUT_MISMATCH") }
    }
    if (-not (Test-ItlContextBenchmarkSetEqual -Left $Candidate.result.requiredGates -Right $Baseline.result.requiredGates)) {
        $reasons.Add("INPUT_MISMATCH")
    }
    if ([string]$Candidate.result.status -ne "passed") { $reasons.Add("RESULT_NOT_PASSED") }
    if ([string]$Candidate.result.outcomeFingerprint -cne [string]$Baseline.result.outcomeFingerprint) { $reasons.Add("OUTCOME_MISMATCH") }
    $missingGates = @($Baseline.result.requiredGates | Where-Object { @($Candidate.result.passedGates) -notcontains $_ })
    if ($missingGates.Count -gt 0) { $reasons.Add("REQUIRED_GATE_MISSING") }
    if ([long]$Candidate.result.lockedDecisionsTotal -ne [long]$Baseline.result.lockedDecisionsTotal -or [long]$Candidate.result.lockedDecisionsPreserved -ne [long]$Candidate.result.lockedDecisionsTotal) {
        $reasons.Add("LOCKED_DECISION_LOST")
    }
    if ([long]$Candidate.result.wrongScopeActions -gt 0) { $reasons.Add("WRONG_SCOPE_ACTION") }
    if ([long]$Candidate.result.dirtyStateViolations -gt 0) { $reasons.Add("DIRTY_STATE_VIOLATION") }
    if ([long]$Candidate.telemetry.duplicateUnchangedGates -gt 0) { $reasons.Add("UNCHANGED_GATE_REPEATED") }
    if ([long]$Candidate.telemetry.resumeTargetedReads -gt 5) { $reasons.Add("RESUME_READ_BUDGET_EXCEEDED") }
    if ([long]$Candidate.telemetry.checkpointTokens -gt 1500) { $reasons.Add("CHECKPOINT_BUDGET_EXCEEDED") }
    if ([long]$Candidate.telemetry.contextOverflowEvents -gt 0) { $reasons.Add("CONTEXT_OVERFLOW") }
    return @($reasons | Sort-Object -Unique)
}

function Get-ItlContextBenchmarkTotalTokens {
    param($Record)
    return [long]$Record.telemetry.parentInputTokens + [long]$Record.telemetry.parentOutputTokens + [long]$Record.telemetry.childInputTokens + [long]$Record.telemetry.childOutputTokens
}

function Invoke-ItlContextOrchestrationBenchmark {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [string]$OutputPath = ""
    )

    $resolvedInput = [IO.Path]::GetFullPath($InputPath)
    if (-not (Test-Path -LiteralPath $resolvedInput -PathType Leaf)) {
        throw "ITL_CONTEXT_BENCHMARK_INPUT_MISSING: $resolvedInput"
    }
    $document = Get-Content -LiteralPath $resolvedInput -Raw -Encoding UTF8 | ConvertFrom-Json
    $documentFields = @("schemaVersion", "kind", "benchmarkId", "records")
    Assert-ItlContextBenchmarkProperties -Value $document -Allowed $documentFields -Required $documentFields -Location "document"
    if ([int]$document.schemaVersion -ne 1 -or [string]$document.kind -ne "itl-context-orchestration-benchmark-set") {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: unsupported document schemaVersion or kind."
    }
    Assert-ItlContextBenchmarkString -Value $document.benchmarkId -Location "document.benchmarkId"
    $records = @($document.records)
    if ($records.Count -eq 0) { throw "ITL_CONTEXT_BENCHMARK_MATRIX_INCOMPLETE: no records were provided." }
    for ($index = 0; $index -lt $records.Count; $index++) {
        Assert-ItlContextBenchmarkRecord -Record $records[$index] -Index $index
    }

    $duplicateRuns = @($records | Group-Object runId | Where-Object Count -gt 1)
    if ($duplicateRuns.Count -gt 0) {
        throw "ITL_CONTEXT_BENCHMARK_SCHEMA_INVALID: duplicate runId(s): $(@($duplicateRuns.Name) -join ', ')."
    }
    $requiredModes = @("S0", "C", "R", "H")
    $scenarioIds = @($records.scenarioId | Sort-Object -Unique)
    foreach ($scenarioId in $scenarioIds) {
        foreach ($mode in $requiredModes) {
            $matches = @($records | Where-Object { $_.scenarioId -eq $scenarioId -and $_.mode -eq $mode })
            if ($matches.Count -ne 1) {
                throw "ITL_CONTEXT_BENCHMARK_MATRIX_INCOMPLETE: scenario '$scenarioId' requires exactly one $mode record; found $($matches.Count)."
            }
        }
        $baseline = $records | Where-Object { $_.scenarioId -eq $scenarioId -and $_.mode -eq "S0" }
        $baselineMissingGates = @($baseline.result.requiredGates | Where-Object { @($baseline.result.passedGates) -notcontains $_ })
        $baselineInvalid = (
            [string]$baseline.result.status -ne "passed" -or
            $baselineMissingGates.Count -gt 0 -or
            [long]$baseline.result.lockedDecisionsPreserved -ne [long]$baseline.result.lockedDecisionsTotal -or
            [long]$baseline.result.wrongScopeActions -gt 0 -or
            [long]$baseline.result.dirtyStateViolations -gt 0 -or
            [long]$baseline.telemetry.duplicateUnchangedGates -gt 0
        )
        if ($baselineInvalid) {
            throw "ITL_CONTEXT_BENCHMARK_BASELINE_INVALID: scenario '$scenarioId' has no proven correct S0 control."
        }
    }

    $modeSummaries = [System.Collections.Generic.List[object]]::new()
    foreach ($mode in @($requiredModes | Sort-Object)) {
        $modeRecords = @($records | Where-Object mode -eq $mode)
        $evidenceKinds = @($modeRecords.telemetry.tokenEvidence | Sort-Object -Unique)
        $telemetryQualification = if ($evidenceKinds.Count -eq 1) { [string]$evidenceKinds[0] } else { "mixed" }
        $medianElapsed = Get-ItlContextBenchmarkMedian -Values @($modeRecords | ForEach-Object { [double]$_.telemetry.elapsedMilliseconds })
        $medianMessageCharacters = $null
        if ($telemetryQualification -eq "proxy") {
            $medianMessageCharacters = Get-ItlContextBenchmarkMedian -Values @($modeRecords | ForEach-Object { [double]$_.telemetry.messageCharacters })
        }

        $summary = [ordered]@{
            mode = $mode
            scenarioCount = $modeRecords.Count
            correctnessEligible = $true
            telemetryQualification = $telemetryQualification
            decisionStatus = $(if ($mode -eq "S0") { "baseline" } else { "functional-only" })
            reasons = @()
            medianTotalTokens = $null
            medianPeakParentContextTokens = $null
            medianMessageCharacters = $medianMessageCharacters
            medianElapsedMilliseconds = $medianElapsed
            totalTokenReductionPercent = $null
            peakParentContextReductionPercent = $null
            elapsedRegressionPercent = $null
        }

        if ($mode -ne "S0") {
            $reasons = [System.Collections.Generic.List[string]]::new()
            foreach ($candidate in $modeRecords) {
                $baseline = $records | Where-Object { $_.scenarioId -eq $candidate.scenarioId -and $_.mode -eq "S0" }
                foreach ($reason in @(Get-ItlContextBenchmarkRecordReasons -Baseline $baseline -Candidate $candidate)) { $reasons.Add($reason) }
            }
            $summary.reasons = @($reasons | Sort-Object -Unique)
            $summary.correctnessEligible = $summary.reasons.Count -eq 0
            if (-not $summary.correctnessEligible) { $summary.decisionStatus = "ineligible" }
        }

        if ($telemetryQualification -eq "exact") {
            $summary.medianTotalTokens = Get-ItlContextBenchmarkMedian -Values @($modeRecords | ForEach-Object { [double](Get-ItlContextBenchmarkTotalTokens -Record $_) })
            $summary.medianPeakParentContextTokens = Get-ItlContextBenchmarkMedian -Values @($modeRecords | ForEach-Object { [double]$_.telemetry.peakParentContextTokens })
        }
        $modeSummaries.Add([pscustomobject]$summary)
    }

    $baselineSummary = $modeSummaries | Where-Object mode -eq "S0"
    foreach ($candidateSummary in @($modeSummaries | Where-Object mode -ne "S0")) {
        $candidateSummary.elapsedRegressionPercent = Get-ItlContextBenchmarkPercentChange -Baseline $baselineSummary.medianElapsedMilliseconds -Candidate $candidateSummary.medianElapsedMilliseconds
        if ($baselineSummary.telemetryQualification -eq "exact" -and $candidateSummary.telemetryQualification -eq "exact") {
            $candidateSummary.totalTokenReductionPercent = Get-ItlContextBenchmarkPercentChange -Baseline $baselineSummary.medianTotalTokens -Candidate $candidateSummary.medianTotalTokens -Reduction
            $candidateSummary.peakParentContextReductionPercent = Get-ItlContextBenchmarkPercentChange -Baseline $baselineSummary.medianPeakParentContextTokens -Candidate $candidateSummary.medianPeakParentContextTokens -Reduction
            if ($candidateSummary.correctnessEligible -and $candidateSummary.totalTokenReductionPercent -ge 25 -and $candidateSummary.peakParentContextReductionPercent -ge 40 -and $candidateSummary.elapsedRegressionPercent -le 15) {
                $candidateSummary.decisionStatus = "eligible"
            } elseif ($candidateSummary.correctnessEligible) {
                $candidateSummary.decisionStatus = "ineligible"
                $metricReasons = [System.Collections.Generic.List[string]]::new()
                foreach ($reason in @($candidateSummary.reasons)) { $metricReasons.Add([string]$reason) }
                if ($candidateSummary.totalTokenReductionPercent -lt 25) { $metricReasons.Add("TOTAL_TOKEN_REDUCTION_BELOW_THRESHOLD") }
                if ($candidateSummary.peakParentContextReductionPercent -lt 40) { $metricReasons.Add("PEAK_PARENT_CONTEXT_REDUCTION_BELOW_THRESHOLD") }
                if ($candidateSummary.elapsedRegressionPercent -gt 15) { $metricReasons.Add("ELAPSED_REGRESSION_ABOVE_THRESHOLD") }
                $candidateSummary.reasons = @($metricReasons | Sort-Object -Unique)
            }
        }
    }

    $summaryDocument = [ordered]@{
        schemaVersion = 1
        kind = "itl-context-orchestration-benchmark-summary"
        benchmarkId = [string]$document.benchmarkId
        generatedAt = [DateTime]::UtcNow.ToString("o")
        sourceRecordCount = $records.Count
        scenarioCount = $scenarioIds.Count
        modes = @($modeSummaries)
        realPilotStatus = "blocked-until-installed-projects-are-explicitly-named"
        outputPath = ""
    }

    if ($OutputPath) {
        $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
        if ([string]::Equals($resolvedInput, $resolvedOutput, [StringComparison]::OrdinalIgnoreCase)) {
            throw "ITL_CONTEXT_BENCHMARK_OUTPUT_INVALID: output must not overwrite the input record set."
        }
        $parent = Split-Path -Parent $resolvedOutput
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        $summaryDocument.outputPath = $resolvedOutput
        [IO.File]::WriteAllText($resolvedOutput, (($summaryDocument | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }
    return [pscustomobject]$summaryDocument
}

if ($MyInvocation.InvocationName -ne "." -and $InputPath) {
    $result = Invoke-ItlContextOrchestrationBenchmark -InputPath $InputPath -OutputPath $OutputPath
    if ($PassThru) { return $result }
    $result | ConvertTo-Json -Depth 10
}
