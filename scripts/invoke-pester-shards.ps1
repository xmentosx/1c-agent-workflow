[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$JunitPath,
    [ValidateRange(1, 4)][int]$WorkerCount = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$JunitPath = [System.IO.Path]::GetFullPath($JunitPath)
$workerRoot = Join-Path $OutputRoot "pester-shards"
New-Item -ItemType Directory -Force -Path $workerRoot | Out-Null

$timingPath = Join-Path $PSScriptRoot "pester-timings.json"
$timings = Get-Content -LiteralPath $timingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$testFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "tests\pester") -File -Filter "*.Tests.ps1" | Sort-Object Name)
if ($testFiles.Count -eq 0) { throw "No Pester test files were discovered." }
$serialTestNames = @("ReleaseGate.Tests.ps1")
$serialTestFiles = @($testFiles | Where-Object { $serialTestNames -contains $_.Name })
$parallelTestFiles = @($testFiles | Where-Object { $serialTestNames -notcontains $_.Name })
$weights = @{}
foreach ($property in $timings.files.PSObject.Properties) { $weights[$property.Name] = [double]$property.Value }
$defaultSeconds = [double]$timings.defaultSeconds

$items = @($parallelTestFiles | ForEach-Object {
    [pscustomobject]@{
        name = $_.Name
        path = $_.FullName
        weight = $(if ($weights.ContainsKey($_.Name)) { [double]$weights[$_.Name] } else { $defaultSeconds })
    }
} | Sort-Object @{ Expression = "weight"; Descending = $true }, @{ Expression = "name"; Descending = $false })

$plans = @()
for ($worker = 1; $worker -le $WorkerCount; $worker++) {
    $plans += [ordered]@{ worker = $worker; weight = 0.0; paths = New-Object System.Collections.Generic.List[string] }
}
foreach ($item in $items) {
    $target = @($plans | Sort-Object @{ Expression = { [double]$_.weight }; Ascending = $true }, @{ Expression = { [int]$_.worker }; Ascending = $true })[0]
    $target.paths.Add([string]$item.path) | Out-Null
    $target.weight = [double]$target.weight + [double]$item.weight
}

$assigned = @($plans | ForEach-Object { @($_.paths) })
if (($assigned | Sort-Object -Unique).Count -ne $parallelTestFiles.Count -or $assigned.Count -ne $parallelTestFiles.Count) {
    throw "Pester shard assignment omitted or duplicated test files."
}

$workerScript = Join-Path $PSScriptRoot "run-pester-shard.ps1"
$processes = @()
foreach ($plan in $plans) {
    $index = [int]$plan.worker
    $planPath = Join-Path $workerRoot ("worker-{0}.plan.json" -f $index)
    $resultPath = Join-Path $workerRoot ("worker-{0}.result.json" -f $index)
    $workerJunit = Join-Path $workerRoot ("worker-{0}.xml" -f $index)
    $stdoutPath = Join-Path $workerRoot ("worker-{0}.stdout.log" -f $index)
    $stderrPath = Join-Path $workerRoot ("worker-{0}.stderr.log" -f $index)
    Remove-Item -LiteralPath $resultPath, $workerJunit, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    $payload = [ordered]@{ schemaVersion = 1; worker = $index; estimatedSeconds = [double]$plan.weight; paths = @($plan.paths) }
    [System.IO.File]::WriteAllText($planPath, (($payload | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $args = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-NativeArgument $workerScript), "-PlanPath", (ConvertTo-NativeArgument $planPath), "-JunitPath", (ConvertTo-NativeArgument $workerJunit), "-ResultPath", (ConvertTo-NativeArgument $resultPath))
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($args -join " ") -WorkingDirectory $RepositoryRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $processes += [pscustomobject]@{ worker = $index; process = $process; resultPath = $resultPath; junitPath = $workerJunit; stdoutPath = $stdoutPath; stderrPath = $stderrPath }
}

$results = @()
$failures = @()
foreach ($entry in $processes) {
    $null = $entry.process.Handle
    if (-not $entry.process.WaitForExit(900000)) {
        try { $entry.process.Kill() } catch {}
        $failures += "worker $($entry.worker) timed out"
        continue
    }
    $entry.process.WaitForExit(); $entry.process.Refresh()
    if (Test-Path -LiteralPath $entry.resultPath -PathType Leaf) {
        $results += Get-Content -LiteralPath $entry.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $failures += "worker $($entry.worker) produced no result: $($entry.stderrPath)"
    }
    if ([int]$entry.process.ExitCode -ne 0) { $failures += "worker $($entry.worker) exit=$($entry.process.ExitCode): $($entry.stderrPath)" }
}

# ReleaseGate owns a process-heavy release-E2E fixture. Running it beside the
# lifecycle shards makes unrelated child-process tests contend for the same
# Windows host resources, so execute it only after all parallel workers finish.
if ($serialTestFiles.Count -gt 0) {
    $serialWorker = $WorkerCount + 1
    $serialPlanPath = Join-Path $workerRoot ("worker-{0}.plan.json" -f $serialWorker)
    $serialResultPath = Join-Path $workerRoot ("worker-{0}.result.json" -f $serialWorker)
    $serialJunit = Join-Path $workerRoot ("worker-{0}.xml" -f $serialWorker)
    $serialStdoutPath = Join-Path $workerRoot ("worker-{0}.stdout.log" -f $serialWorker)
    $serialStderrPath = Join-Path $workerRoot ("worker-{0}.stderr.log" -f $serialWorker)
    Remove-Item -LiteralPath $serialResultPath, $serialJunit, $serialStdoutPath, $serialStderrPath -Force -ErrorAction SilentlyContinue
    $serialWeight = [double](($serialTestFiles | ForEach-Object {
        if ($weights.ContainsKey($_.Name)) { [double]$weights[$_.Name] } else { $defaultSeconds }
    } | Measure-Object -Sum).Sum)
    $serialPayload = [ordered]@{
        schemaVersion = 1
        worker = $serialWorker
        estimatedSeconds = $serialWeight
        paths = @($serialTestFiles.FullName)
    }
    [System.IO.File]::WriteAllText($serialPlanPath, (($serialPayload | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $serialArgs = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-NativeArgument $workerScript), "-PlanPath", (ConvertTo-NativeArgument $serialPlanPath), "-JunitPath", (ConvertTo-NativeArgument $serialJunit), "-ResultPath", (ConvertTo-NativeArgument $serialResultPath))
    $serialProcess = Start-Process -FilePath "powershell.exe" -ArgumentList ($serialArgs -join " ") -WorkingDirectory $RepositoryRoot -WindowStyle Hidden -RedirectStandardOutput $serialStdoutPath -RedirectStandardError $serialStderrPath -PassThru
    $serialEntry = [pscustomobject]@{
        worker = $serialWorker
        process = $serialProcess
        resultPath = $serialResultPath
        junitPath = $serialJunit
        stdoutPath = $serialStdoutPath
        stderrPath = $serialStderrPath
    }
    $processes += $serialEntry
    $null = $serialProcess.Handle
    if (-not $serialProcess.WaitForExit(900000)) {
        try { $serialProcess.Kill() } catch {}
        $failures += "worker $serialWorker timed out"
    } else {
        $serialProcess.WaitForExit()
        $serialProcess.Refresh()
        if (Test-Path -LiteralPath $serialResultPath -PathType Leaf) {
            $results += Get-Content -LiteralPath $serialResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } else {
            $failures += "worker $serialWorker produced no result: $serialStderrPath"
        }
        if ([int]$serialProcess.ExitCode -ne 0) {
            $failures += "worker $serialWorker exit=$($serialProcess.ExitCode): $serialStderrPath"
        }
    }
}

if ($results.Count -ne $processes.Count) { $failures += "expected $($processes.Count) worker results, got $($results.Count)" }
$reportedPaths = @($results | ForEach-Object { @($_.paths) })
$expectedPaths = @($testFiles | ForEach-Object { $_.FullName })
if ($reportedPaths.Count -ne $expectedPaths.Count -or @($reportedPaths | Sort-Object -Unique).Count -ne $expectedPaths.Count -or
    (Compare-Object -ReferenceObject @($expectedPaths | Sort-Object) -DifferenceObject @($reportedPaths | Sort-Object))) {
    $failures += "worker results omitted or duplicated test files"
}

$document = New-Object System.Xml.XmlDocument
$declaration = $document.CreateXmlDeclaration("1.0", "utf-8", "no")
$document.AppendChild($declaration) | Out-Null
$root = $document.CreateElement("testsuites")
$root.SetAttribute("name", "Pester")
$document.AppendChild($root) | Out-Null
$tests = 0; $errors = 0; $failed = 0; $skipped = 0; $time = 0.0
foreach ($entry in $processes | Sort-Object worker) {
    if (-not (Test-Path -LiteralPath $entry.junitPath -PathType Leaf)) { continue }
    [xml]$source = Get-Content -LiteralPath $entry.junitPath -Raw -Encoding UTF8
    $sourceRoot = $source.DocumentElement
    $tests += [int]$sourceRoot.tests; $errors += [int]$sourceRoot.errors; $failed += [int]$sourceRoot.failures
    if ($sourceRoot.HasAttribute("disabled")) { $skipped += [int]$sourceRoot.disabled }
    $time += [double]::Parse([string]$sourceRoot.time, [Globalization.CultureInfo]::InvariantCulture)
    foreach ($suite in @($sourceRoot.SelectNodes("testcase") + $sourceRoot.SelectNodes("testsuite"))) {
        $root.AppendChild($document.ImportNode($suite, $true)) | Out-Null
    }
}
$reportedTestCount = [int](($results | Measure-Object -Property passed -Sum).Sum) + [int](($results | Measure-Object -Property failed -Sum).Sum) + [int](($results | Measure-Object -Property skipped -Sum).Sum)
if ($tests -ne $reportedTestCount) { $failures += "merged JUnit test count $tests differs from worker count $reportedTestCount" }
$root.SetAttribute("tests", [string]$tests); $root.SetAttribute("errors", [string]$errors); $root.SetAttribute("failures", [string]$failed)
$root.SetAttribute("disabled", [string]$skipped); $root.SetAttribute("time", $time.ToString("0.###", [Globalization.CultureInfo]::InvariantCulture))
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $JunitPath) | Out-Null
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = New-Object System.Text.UTF8Encoding($false); $settings.Indent = $true
$writer = [System.Xml.XmlWriter]::Create($JunitPath, $settings)
try { $document.Save($writer) } finally { $writer.Dispose() }

$summary = [ordered]@{
    schemaVersion = 1
    status = $(if ($failures.Count -eq 0 -and $failed -eq 0 -and $errors -eq 0) { "passed" } else { "failed" })
    workerCount = $processes.Count
    workers = @($results | Sort-Object worker)
    junitPath = $JunitPath
    passed = [int](($results | Measure-Object -Property passed -Sum).Sum)
    failed = [int](($results | Measure-Object -Property failed -Sum).Sum)
    skipped = [int](($results | Measure-Object -Property skipped -Sum).Sum)
    pesterVersion = [string](@($results | Select-Object -First 1).pesterVersion)
    errors = @($failures)
}
$summaryPath = Join-Path $workerRoot "summary.json"
[System.IO.File]::WriteAllText($summaryPath, (($summary | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
if ([string]$summary.status -ne "passed") { throw "Pester shards failed: $($failures -join '; ')" }
$summary | ConvertTo-Json -Depth 10
