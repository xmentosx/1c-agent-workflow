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
$commonGitDir = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot
$cacheRoot = Join-Path $commonGitDir "itl\pester-shards\v1"; New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
$sharedInputs = @(
    "tests/pester/TestSupport.ps1", "scripts/run-pester-shard.ps1"
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
    foreach ($path in $inputs) {
        $absolute=Join-Path $RepositoryRoot $path.Replace('/','\')
        if(Test-Path -LiteralPath $absolute -PathType Leaf){$lines.Add("$path=$((Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant())")}
        else{$lines.Add("$path=<missing>")}
    }
    return Get-TextSha256 -Lines $lines
}

function Get-ShardCacheEntryRoot {
    param([string]$Digest)
    if (-not $Digest) { return $null }
    $target = Join-Path $cacheRoot $Digest
    $candidates = @($target)
    if (Test-Path -LiteralPath $target -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $target -Directory -Filter ".$Digest.*.tmp")
    }
    foreach ($candidate in $candidates) {
        $entryRoot = if ($candidate -is [IO.DirectoryInfo]) { $candidate.FullName } else { [string]$candidate }
        $cachedResult = Join-Path $entryRoot "result.json"; $cachedJunit = Join-Path $entryRoot "pester.xml"; $manifestPath = Join-Path $entryRoot "manifest.json"
        if (-not (Test-Path -LiteralPath $cachedResult -PathType Leaf) -or -not (Test-Path -LiteralPath $cachedJunit -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$manifest.schemaVersion -eq 1 -and [string]$manifest.digest -eq $Digest -and
                [string]$manifest.resultSha256 -eq (Get-FileHash -LiteralPath $cachedResult -Algorithm SHA256).Hash.ToLowerInvariant() -and
                [string]$manifest.junitSha256 -eq (Get-FileHash -LiteralPath $cachedJunit -Algorithm SHA256).Hash.ToLowerInvariant()) { return $entryRoot }
        } catch {}
    }
    return ""
}

function Restore-ShardCache {
    param([string]$Digest, [string]$ResultPath, [string]$JunitPath, [int]$Worker, [string]$TestPath)
    $entryRoot = Get-ShardCacheEntryRoot -Digest $Digest
    if (-not $entryRoot) { return $null }
    $cachedResult = Join-Path $entryRoot "result.json"; $cachedJunit = Join-Path $entryRoot "pester.xml"
    try {
        $result = Get-Content -LiteralPath $cachedResult -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$result.status -ne "passed" -or [int]$result.failed -ne 0) { return $null }
        Copy-Item -LiteralPath $cachedJunit -Destination $JunitPath -Force
        $result | Add-Member -NotePropertyName worker -NotePropertyValue $Worker -Force
        $result.paths = @($TestPath)
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
    if (Get-ShardCacheEntryRoot -Digest $Digest) { return }
    if (Test-Path -LiteralPath $target -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $target -Force).Count -gt 0) { throw "Incomplete Pester shard cache is not empty: $target" }
        Remove-Item -LiteralPath $target -Force
    }
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
$weights = @{}
foreach ($property in $timings.files.PSObject.Properties) { $weights[$property.Name] = [double]$property.Value }
$defaultSeconds = [double]$timings.defaultSeconds

$items = @($testFiles | ForEach-Object {
    [pscustomobject]@{
        name = $_.Name
        path = $_.FullName
        weight = $(if ($weights.ContainsKey($_.Name)) { [double]$weights[$_.Name] } else { $defaultSeconds })
        serial = $serialTestNames -contains $_.Name
    }
} | Sort-Object @{ Expression = "serial"; Descending = $false }, @{ Expression = "weight"; Descending = $true }, @{ Expression = "name"; Descending = $false })

$workerScript = Join-Path $PSScriptRoot "run-pester-shard.ps1"
$entries = New-Object System.Collections.Generic.List[object]
$pendingParallel = New-Object System.Collections.Generic.Queue[object]
$pendingSerial = New-Object System.Collections.Generic.Queue[object]
$results = @()
$failures = @()
$index = 0
foreach ($item in $items) {
    $index++
    $planPath = Join-Path $workerRoot ("worker-{0}.plan.json" -f $index)
    $resultPath = Join-Path $workerRoot ("worker-{0}.result.json" -f $index)
    $workerJunit = Join-Path $workerRoot ("worker-{0}.xml" -f $index)
    $stdoutPath = Join-Path $workerRoot ("worker-{0}.stdout.log" -f $index)
    $stderrPath = Join-Path $workerRoot ("worker-{0}.stderr.log" -f $index)
    $stdinPath = Join-Path $workerRoot ("worker-{0}.stdin.txt" -f $index)
    $digest = Get-ShardInputDigest -Paths @([string]$item.path)
    if ((Test-Path -LiteralPath $planPath -PathType Leaf) -and (Test-Path -LiteralPath $resultPath -PathType Leaf) -and (Test-Path -LiteralPath $workerJunit -PathType Leaf)) {
        try {
            $priorPlan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $priorResult = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$priorPlan.inputDigest -eq $digest -and @($priorPlan.paths).Count -eq 1 -and [string]$priorPlan.paths[0] -eq [string]$item.path -and
                [string]$priorResult.status -eq "passed" -and [int]$priorResult.failed -eq 0) {
                $priorResult | Add-Member -NotePropertyName execution -NotePropertyValue "executed" -Force
                $priorResult | Add-Member -NotePropertyName inputDigest -NotePropertyValue $digest -Force
                $priorResult | Add-Member -NotePropertyName worker -NotePropertyValue $index -Force
                $priorResult.paths = @([string]$item.path)
                [IO.File]::WriteAllText($resultPath, (($priorResult | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
                Save-ShardCache -Digest $digest -ResultPath $resultPath -JunitPath $workerJunit
            }
        } catch {}
    }
    Remove-Item -LiteralPath $resultPath, $workerJunit, $stdoutPath, $stderrPath, $stdinPath -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($stdinPath, "", [System.Text.UTF8Encoding]::new($false))
    $payload = [ordered]@{ schemaVersion = 1; worker = $index; estimatedSeconds = [double]$item.weight; inputDigest = $digest; paths = @([string]$item.path) }
    [System.IO.File]::WriteAllText($planPath, (($payload | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $cached = Restore-ShardCache -Digest $digest -ResultPath $resultPath -JunitPath $workerJunit -Worker $index -TestPath ([string]$item.path)
    if ($cached) { $cached | Add-Member -NotePropertyName reuseReason -NotePropertyValue "exact owner input fingerprint" -Force }
    $entry = [pscustomobject]@{
        worker = $index; serial = [bool]$item.serial; process = $null; reused = [bool]$cached; digest = $digest
        planPath = $planPath; resultPath = $resultPath; junitPath = $workerJunit; stdoutPath = $stdoutPath; stderrPath = $stderrPath; stdinPath = $stdinPath
    }
    $entries.Add($entry) | Out-Null
    if ($cached) {
        $results += $cached
    } else {
        if ([bool]$entry.serial) { $pendingSerial.Enqueue($entry) } else { $pendingParallel.Enqueue($entry) }
    }
}

function Start-PesterFileEntry {
    param([Parameter(Mandatory = $true)][object]$Entry)
    $args = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-NativeArgument $workerScript), "-PlanPath", (ConvertTo-NativeArgument $Entry.planPath), "-JunitPath", (ConvertTo-NativeArgument $Entry.junitPath), "-ResultPath", (ConvertTo-NativeArgument $Entry.resultPath))
    $Entry.process = Start-Process -FilePath "powershell.exe" -ArgumentList ($args -join " ") -WorkingDirectory $RepositoryRoot -WindowStyle Hidden -RedirectStandardInput $Entry.stdinPath -RedirectStandardOutput $Entry.stdoutPath -RedirectStandardError $Entry.stderrPath -PassThru
    $null = $Entry.process.Handle
}

function Complete-PesterFileEntry {
    param([Parameter(Mandatory = $true)][object]$Entry)
    $Entry.process.WaitForExit(); $Entry.process.Refresh()
    if (Test-Path -LiteralPath $Entry.resultPath -PathType Leaf) {
        $workerResult = Get-Content -LiteralPath $Entry.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $workerResult | Add-Member -NotePropertyName execution -NotePropertyValue "executed" -Force
        $workerResult | Add-Member -NotePropertyName inputDigest -NotePropertyValue ([string]$Entry.digest) -Force
        [IO.File]::WriteAllText($Entry.resultPath, (($workerResult | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $script:results += $workerResult
        if ([string]$workerResult.status -eq "passed" -and [int]$Entry.process.ExitCode -eq 0) {
            Save-ShardCache -Digest $Entry.digest -ResultPath $Entry.resultPath -JunitPath $Entry.junitPath
            if (-not (Get-ShardCacheEntryRoot -Digest ([string]$Entry.digest))) {
                throw "Passed Pester file cache was not persisted for worker $($Entry.worker)."
            }
            return $true
        }
        $script:failures += "worker $($Entry.worker) reported $([string]$workerResult.status): $([string]$workerResult.error)"
    } else {
        $script:failures += "worker $($Entry.worker) produced no result: $($Entry.stderrPath)"
    }
    if ([int]$Entry.process.ExitCode -ne 0) { $script:failures += "worker $($Entry.worker) exit=$($Entry.process.ExitCode): $($Entry.stderrPath)" }
    return $false
}

$active = New-Object System.Collections.Generic.List[object]
$stopScheduling = $false
$nextHeartbeat = [DateTime]::UtcNow.AddSeconds(15)
while ($active.Count -gt 0 -or (-not $stopScheduling -and $pendingParallel.Count -gt 0)) {
    while (-not $stopScheduling -and $pendingParallel.Count -gt 0 -and $active.Count -lt $WorkerCount) {
        $next = $pendingParallel.Dequeue()
        Start-PesterFileEntry -Entry $next
        $active.Add($next) | Out-Null
    }
    if ($active.Count -eq 0) { break }
    $completed = @($active | Where-Object { $_.process.HasExited })
    if ($completed.Count -eq 0) {
        if ([DateTime]::UtcNow -ge $nextHeartbeat) {
            Write-Host "Pester shard heartbeat: active=$(@($active.worker) -join ','); pending=$($pendingParallel.Count)."
            $nextHeartbeat = [DateTime]::UtcNow.AddSeconds(15)
        }
        Start-Sleep -Milliseconds 200
        continue
    }
    foreach ($entry in $completed) {
        if (-not (Complete-PesterFileEntry -Entry $entry)) { $stopScheduling = $true }
        [void]$active.Remove($entry)
    }
}

while (-not $stopScheduling -and $pendingSerial.Count -gt 0) {
    $entry = $pendingSerial.Dequeue()
    Start-PesterFileEntry -Entry $entry
    $serialDeadline = [DateTime]::UtcNow.AddMinutes(15)
    while (-not $entry.process.WaitForExit(15000) -and [DateTime]::UtcNow -lt $serialDeadline) {
        Write-Host "Pester shard heartbeat: serial=$($entry.worker); pending=$($pendingSerial.Count)."
    }
    if (-not $entry.process.HasExited) {
        try { $entry.process.Kill() } catch {}
        $failures += "worker $($entry.worker) timed out"
        $stopScheduling = $true
    } elseif (-not (Complete-PesterFileEntry -Entry $entry)) {
        $stopScheduling = $true
    }
}

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
foreach ($entry in @($entries | Where-Object { Test-Path -LiteralPath $_.junitPath -PathType Leaf } | Sort-Object worker)) {
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
    workerCount = $results.Count
    executedWorkerCount = @($entries | Where-Object { -not $_.reused -and $_.process }).Count
    reusedWorkerCount = @($entries | Where-Object { $_.reused }).Count
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
