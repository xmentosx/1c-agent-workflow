[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$JunitPath,
    [string]$AiRulesSource = "",
    [string]$SelectionPath = "",
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

function Get-TextSha256 {
    param([string[]]$Lines)
    $bytes = [Text.Encoding]::UTF8.GetBytes((@($Lines) -join "`n")); $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() } finally { $sha.Dispose() }
}

$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$AiRulesSource = $(if ($AiRulesSource) { [System.IO.Path]::GetFullPath($AiRulesSource) } else { "" })
if ($AiRulesSource) { $env:ITL_AI_RULES_SOURCE_PATH = $AiRulesSource }
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$JunitPath = [System.IO.Path]::GetFullPath($JunitPath)
$workerRoot = Join-Path $OutputRoot "pester-shards"
New-Item -ItemType Directory -Force -Path $workerRoot | Out-Null
. (Join-Path $PSScriptRoot "git-path-list.ps1")
. (Join-Path $PSScriptRoot "quality-contracts.ps1")
$catalog = Get-QualityContractCatalog -RepositoryRoot $RepositoryRoot
$trackedPaths = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @("ls-files", "-z"))
$commonGitDir = (& git -C $RepositoryRoot rev-parse --git-common-dir).Trim(); if (-not [IO.Path]::IsPathRooted($commonGitDir)) { $commonGitDir = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $commonGitDir)) }
$cacheRoot = Join-Path $commonGitDir "itl\pester-shards\v1"; New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
$sharedInputs = @(
    "tests/quality-contracts.json", "tests/pester/TestSupport.ps1", "scripts/invoke-pester-shards.ps1",
    "scripts/run-pester-shard.ps1", "scripts/git-path-list.ps1", "scripts/quality-contracts.ps1",
    "scripts/pester-timings.json", "templates/dependency-lock.json"
)

function Initialize-VanessaSourceBuildArchiveForPester {
    $lockPath = Join-Path $RepositoryRoot "templates\dependency-lock.json"
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw "Pester Vanessa source-build resolution requires the canonical dependency lock: $lockPath"
    }
    $lock = (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.vanessaAutomation
    $expected = ([string]$lock.sha256).ToLowerInvariant()
    $assetName = [string]$lock.assetName
    $folderName = ([string]$lock.compatibilityVersion) + "-" + ([string]$lock.downstreamRevision)
    if ($expected -notmatch '^[a-f0-9]{64}$' -or -not $assetName -or -not $folderName) {
        throw "Pester Vanessa source-build resolution found an incomplete dependency lock entry."
    }

    $configured = [Environment]::GetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", "Process")
    if ($configured) {
        try { $configured = [IO.Path]::GetFullPath($configured) } catch { throw "Configured Vanessa source-build path is invalid: $configured" }
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) {
            throw "Configured Vanessa source-build archive is missing: $configured"
        }
        $actual = (Get-FileHash -LiteralPath $configured -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "Configured Vanessa source-build SHA256 differs from the dependency lock: expected=$expected actual=$actual path=$configured"
        }
        $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $configured
        return
    }

    $candidateRoots = New-Object System.Collections.Generic.List[string]
    $candidateRoots.Add($RepositoryRoot)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $worktreeLines = @(& git -C $RepositoryRoot worktree list --porcelain 2>$null)
        $worktreeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($worktreeExitCode -eq 0) {
        foreach ($line in $worktreeLines) {
            if ([string]$line -match '^worktree\s+(.+)$') {
                try { $candidateRoots.Add([IO.Path]::GetFullPath($Matches[1])) } catch {}
            }
        }
    }
    foreach ($root in @($candidateRoots | Select-Object -Unique)) {
        $candidate = Join-Path $root ("build\third-party\vanessa-automation\$folderName\$assetName")
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected) {
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = [IO.Path]::GetFullPath($candidate)
            return
        }
    }

    $sharedDirectory = Join-Path $commonGitDir "itl\dependencies\vanessa-automation\$folderName"
    $sharedArchive = Join-Path $sharedDirectory ("$expected-$assetName")
    if (Test-Path -LiteralPath $sharedArchive -PathType Leaf) {
        $sharedHash = (Get-FileHash -LiteralPath $sharedArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sharedHash -ne $expected) {
            throw "Shared Vanessa source-build cache entry has an impossible SHA-address mismatch: expected=$expected actual=$sharedHash path=$sharedArchive"
        }
        $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $sharedArchive
        return
    }

    $url = [string]$lock.url
    if (-not $url) { throw "Locked Vanessa source-build URL is missing and no exact shared candidate was found." }
    New-Item -ItemType Directory -Force -Path $sharedDirectory | Out-Null
    $partial = Join-Path $sharedDirectory (".$expected." + [guid]::NewGuid().ToString("N") + ".partial")
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $partial
        $downloadedHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($downloadedHash -ne $expected) {
            throw "Downloaded Vanessa source-build SHA256 differs from the dependency lock: expected=$expected actual=$downloadedHash"
        }
        if (-not (Test-Path -LiteralPath $sharedArchive -PathType Leaf)) {
            Move-Item -LiteralPath $partial -Destination $sharedArchive
        }
        $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $sharedArchive
    } finally {
        if (Test-Path -LiteralPath $partial -PathType Leaf) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Get-ExternalInputIdentity {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if (-not $value) { return "env:$Name=<unset>" }
    $identity = "env:$Name=$value"
    if (Test-Path -LiteralPath $value -PathType Leaf) { return "$identity|sha256=$((Get-FileHash -LiteralPath $value -Algorithm SHA256).Hash.ToLowerInvariant())" }
    if (Test-Path -LiteralPath $value -PathType Container) {
        $head = (& git -C $value rev-parse HEAD 2>$null); $tree = (& git -C $value rev-parse 'HEAD^{tree}' 2>$null)
        if ($LASTEXITCODE -eq 0) { return "$identity|commit=$($head.Trim())|tree=$($tree.Trim())" }
    }
    return "$identity|unresolved"
}

function Get-ShardInputDigest {
    param([string[]]$Paths)
    $relativeTests = @($Paths | ForEach-Object { [IO.Path]::GetFullPath($_).Substring($RepositoryRoot.TrimEnd('\').Length).TrimStart('\').Replace('\','/') })
    $contracts = @($catalog.contracts | Where-Object { $tests=@($_.tests | ForEach-Object { ([string]$_).Replace('\','/') }); @($relativeTests | Where-Object { $_ -in $tests }).Count -gt 0 })
    foreach ($test in $relativeTests) { if (@($contracts | Where-Object { $test -in @($_.tests | ForEach-Object { ([string]$_).Replace('\','/') }) }).Count -eq 0) { return "" } }
    $patterns = @($contracts | ForEach-Object { @($_.paths) } | ForEach-Object { ([string]$_).Replace('\','/') } | Sort-Object -Unique)
    $inputs = @($relativeTests + $sharedInputs + @($trackedPaths | Where-Object { $path=([string]$_).Replace('\','/'); @($patterns | Where-Object { $path -like $_ }).Count -gt 0 }) | Sort-Object -Unique)
    $lines = New-Object System.Collections.Generic.List[string]
    $pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester) { return "" }
    $lines.Add("powershell=$($PSVersionTable.PSVersion)|pester=$($pester.Version)|workers=$WorkerCount")
    foreach ($name in @("ITL_AI_RULES_SOURCE_PATH", "ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE")) { $lines.Add((Get-ExternalInputIdentity -Name $name)) }
    foreach ($path in $inputs) { $absolute=Join-Path $RepositoryRoot $path.Replace('/','\'); if(Test-Path -LiteralPath $absolute -PathType Leaf){$lines.Add("$path=$((Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant())")}else{$lines.Add("$path=<missing>")} }
    return Get-TextSha256 -Lines $lines
}

function Restore-ShardCache {
    param([string]$Digest, [string]$ResultPath, [string]$JunitPath)
    if (-not $Digest) { return $null }
    $entryRoot = Join-Path $cacheRoot $Digest; $cachedResult = Join-Path $entryRoot "result.json"; $cachedJunit = Join-Path $entryRoot "pester.xml"; $manifestPath = Join-Path $entryRoot "manifest.json"
    if (-not (Test-Path -LiteralPath $cachedResult -PathType Leaf) -or -not (Test-Path -LiteralPath $cachedJunit -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.digest -ne $Digest -or [string]$manifest.resultSha256 -ne (Get-FileHash -LiteralPath $cachedResult -Algorithm SHA256).Hash.ToLowerInvariant() -or [string]$manifest.junitSha256 -ne (Get-FileHash -LiteralPath $cachedJunit -Algorithm SHA256).Hash.ToLowerInvariant()) { return $null }
        $result = Get-Content -LiteralPath $cachedResult -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$result.status -ne "passed" -or [int]$result.failed -ne 0) { return $null }
        Copy-Item -LiteralPath $cachedJunit -Destination $JunitPath -Force
        $result.junitPath = $JunitPath
        $result | Add-Member -NotePropertyName execution -NotePropertyValue "reused" -Force
        $result | Add-Member -NotePropertyName cachedDurationMs -NotePropertyValue ([int64]$result.durationMs) -Force
        [IO.File]::WriteAllText($ResultPath, (($result | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        return $result
    } catch { return $null }
}

function Save-ShardCache {
    param([string]$Digest, [string]$ResultPath, [string]$JunitPath)
    if (-not $Digest) { return }
    $result = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$result.status -ne "passed" -or [int]$result.failed -ne 0 -or -not (Test-Path -LiteralPath $JunitPath -PathType Leaf)) { return }
    $target = Join-Path $cacheRoot $Digest
    if (Test-Path -LiteralPath (Join-Path $target "result.json") -PathType Leaf) { return }
    $staging = Join-Path $cacheRoot ("." + $Digest + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        Copy-Item -LiteralPath $ResultPath -Destination (Join-Path $staging "result.json")
        Copy-Item -LiteralPath $JunitPath -Destination (Join-Path $staging "pester.xml")
        $manifest = [ordered]@{ schemaVersion = 1; digest = $Digest; resultSha256 = (Get-FileHash -LiteralPath (Join-Path $staging "result.json") -Algorithm SHA256).Hash.ToLowerInvariant(); junitSha256 = (Get-FileHash -LiteralPath (Join-Path $staging "pester.xml") -Algorithm SHA256).Hash.ToLowerInvariant() }
        [IO.File]::WriteAllText((Join-Path $staging "manifest.json"), (($manifest | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        try { Move-Item -LiteralPath $staging -Destination $target -ErrorAction Stop } catch { if (-not (Test-Path -LiteralPath $target)) { throw } }
    } finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
}

$timingPath = Join-Path $PSScriptRoot "pester-timings.json"
$timings = Get-Content -LiteralPath $timingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$testRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot "tests\pester")).TrimEnd('\') + '\'
if ($SelectionPath) {
    $selection = Get-Content -LiteralPath ([IO.Path]::GetFullPath($SelectionPath)) -Raw -Encoding UTF8 | ConvertFrom-Json
    $testFiles = @($selection.tests | ForEach-Object {
        $resolved = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot ([string]$_).Replace('/','\')))
        if (-not $resolved.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase) -or $resolved -notlike "*.Tests.ps1" -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Selected Pester path is missing or outside tests/pester: $_" }
        Get-Item -LiteralPath $resolved
    } | Sort-Object Name -Unique)
} else { $testFiles = @(Get-ChildItem -LiteralPath $testRoot -File -Filter "*.Tests.ps1" | Sort-Object Name) }
if ($testFiles.Count -eq 0) { throw "No Pester test files were discovered." }
if (@($testFiles | Where-Object Name -eq "BootstrapUpdate.Tests.ps1").Count -gt 0) {
    Initialize-VanessaSourceBuildArchiveForPester
}
$serialTestNames = @("DependencyLocks.Tests.ps1", "ReleaseGate.Tests.ps1")
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
$parallelWorkerCount = $(if ($parallelTestFiles.Count -gt 0) { [Math]::Min($WorkerCount, $parallelTestFiles.Count) } else { 0 })
for ($worker = 1; $worker -le $parallelWorkerCount; $worker++) {
    $plans += [ordered]@{ worker = $worker; weight = 0.0; paths = New-Object System.Collections.Generic.List[string] }
}
foreach ($item in $items) {
    $target = @($plans | Sort-Object @{ Expression = { [double]$_.weight }; Ascending = $true }, @{ Expression = { [int]$_.worker }; Ascending = $true })[0]
    $target.paths.Add([string]$item.path) | Out-Null
    $target.weight = [double]$target.weight + [double]$item.weight
}

$assigned = @($plans | ForEach-Object { @($_.paths) })
if (@($assigned | Sort-Object -Unique).Count -ne $parallelTestFiles.Count -or $assigned.Count -ne $parallelTestFiles.Count) {
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
    $stdinPath = Join-Path $workerRoot ("worker-{0}.stdin.txt" -f $index)
    Remove-Item -LiteralPath $resultPath, $workerJunit, $stdoutPath, $stderrPath, $stdinPath -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($stdinPath, "", [System.Text.UTF8Encoding]::new($false))
    $payload = [ordered]@{ schemaVersion = 1; worker = $index; estimatedSeconds = [double]$plan.weight; paths = @($plan.paths) }
    [System.IO.File]::WriteAllText($planPath, (($payload | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $digest = Get-ShardInputDigest -Paths @($plan.paths)
    $cached = Restore-ShardCache -Digest $digest -ResultPath $resultPath -JunitPath $workerJunit
    if ($cached) {
        $processes += [pscustomobject]@{ worker = $index; process = $null; reused = $true; digest = $digest; resultPath = $resultPath; junitPath = $workerJunit; stdoutPath = $stdoutPath; stderrPath = $stderrPath }
    } else {
        $args = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-NativeArgument $workerScript), "-PlanPath", (ConvertTo-NativeArgument $planPath), "-JunitPath", (ConvertTo-NativeArgument $workerJunit), "-ResultPath", (ConvertTo-NativeArgument $resultPath))
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($args -join " ") -WorkingDirectory $RepositoryRoot -WindowStyle Hidden -RedirectStandardInput $stdinPath -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
        $null = $process.Handle
        $processes += [pscustomobject]@{ worker = $index; process = $process; reused = $false; digest = $digest; resultPath = $resultPath; junitPath = $workerJunit; stdoutPath = $stdoutPath; stderrPath = $stderrPath }
    }
}

$results = @()
$failures = @()
foreach ($entry in $processes) {
    if ($entry.reused) { $results += Get-Content -LiteralPath $entry.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json; continue }
    $null = $entry.process.Handle
    if (-not $entry.process.WaitForExit(900000)) {
        try { $entry.process.Kill() } catch {}
        $failures += "worker $($entry.worker) timed out"
        continue
    }
    $entry.process.WaitForExit(); $entry.process.Refresh()
    if (Test-Path -LiteralPath $entry.resultPath -PathType Leaf) {
        $workerResult = Get-Content -LiteralPath $entry.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $workerResult | Add-Member -NotePropertyName execution -NotePropertyValue "executed" -Force
        $results += $workerResult
        if ([string]$workerResult.status -ne "passed") { $failures += "worker $($entry.worker) reported $([string]$workerResult.status): $([string]$workerResult.error)" } else { Save-ShardCache -Digest $entry.digest -ResultPath $entry.resultPath -JunitPath $entry.junitPath }
    } else {
        $failures += "worker $($entry.worker) produced no result: $($entry.stderrPath)"
    }
    if ([int]$entry.process.ExitCode -ne 0) { $failures += "worker $($entry.worker) exit=$($entry.process.ExitCode): $($entry.stderrPath)" }
}

# DependencyLocks and ReleaseGate own process-wide helper state or process-heavy
# fixtures. Keep them away from the parallel lifecycle workers.
if ($serialTestFiles.Count -gt 0) {
    $serialWorker = $parallelWorkerCount + 1
    $serialPlanPath = Join-Path $workerRoot ("worker-{0}.plan.json" -f $serialWorker)
    $serialResultPath = Join-Path $workerRoot ("worker-{0}.result.json" -f $serialWorker)
    $serialJunit = Join-Path $workerRoot ("worker-{0}.xml" -f $serialWorker)
    $serialStdoutPath = Join-Path $workerRoot ("worker-{0}.stdout.log" -f $serialWorker)
    $serialStderrPath = Join-Path $workerRoot ("worker-{0}.stderr.log" -f $serialWorker)
    $serialStdinPath = Join-Path $workerRoot ("worker-{0}.stdin.txt" -f $serialWorker)
    Remove-Item -LiteralPath $serialResultPath, $serialJunit, $serialStdoutPath, $serialStderrPath, $serialStdinPath -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($serialStdinPath, "", [System.Text.UTF8Encoding]::new($false))
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
    $serialDigest = Get-ShardInputDigest -Paths @($serialTestFiles.FullName)
    $serialCached = Restore-ShardCache -Digest $serialDigest -ResultPath $serialResultPath -JunitPath $serialJunit
    $serialProcess = $null
    if (-not $serialCached) {
        $serialArgs = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-NativeArgument $workerScript), "-PlanPath", (ConvertTo-NativeArgument $serialPlanPath), "-JunitPath", (ConvertTo-NativeArgument $serialJunit), "-ResultPath", (ConvertTo-NativeArgument $serialResultPath))
        $serialProcess = Start-Process -FilePath "powershell.exe" -ArgumentList ($serialArgs -join " ") -WorkingDirectory $RepositoryRoot -WindowStyle Hidden -RedirectStandardInput $serialStdinPath -RedirectStandardOutput $serialStdoutPath -RedirectStandardError $serialStderrPath -PassThru
    }
    $serialEntry = [pscustomobject]@{ worker = $serialWorker; process = $serialProcess; reused = [bool]$serialCached; digest = $serialDigest; resultPath = $serialResultPath; junitPath = $serialJunit; stdoutPath = $serialStdoutPath; stderrPath = $serialStderrPath }
    $processes += $serialEntry
    if ($serialCached) {
        $results += Get-Content -LiteralPath $serialResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
      $null = $serialProcess.Handle
      if (-not $serialProcess.WaitForExit(900000)) {
        try { $serialProcess.Kill() } catch {}
        $failures += "worker $serialWorker timed out"
      } else {
        $serialProcess.WaitForExit()
        $serialProcess.Refresh()
        if (Test-Path -LiteralPath $serialResultPath -PathType Leaf) {
            $serialResult = Get-Content -LiteralPath $serialResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $serialResult | Add-Member -NotePropertyName execution -NotePropertyValue "executed" -Force
            $results += $serialResult
            if ([string]$serialResult.status -ne "passed") { $failures += "worker $serialWorker reported $([string]$serialResult.status): $([string]$serialResult.error)" } else { Save-ShardCache -Digest $serialDigest -ResultPath $serialResultPath -JunitPath $serialJunit }
        } else {
            $failures += "worker $serialWorker produced no result: $serialStderrPath"
        }
        if ([int]$serialProcess.ExitCode -ne 0) {
            $failures += "worker $serialWorker exit=$($serialProcess.ExitCode): $serialStderrPath"
        }
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
    schemaVersion = 2
    status = $(if ($failures.Count -eq 0 -and $failed -eq 0 -and $errors -eq 0) { "passed" } else { "failed" })
    workerCount = $processes.Count
    executedWorkerCount = @($processes | Where-Object { -not $_.reused }).Count
    reusedWorkerCount = @($processes | Where-Object { $_.reused }).Count
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
