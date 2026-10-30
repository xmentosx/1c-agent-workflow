[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$JunitPath,
    [string]$AiRulesSource = "",
    [string]$SelectionPath = "",
    [ValidateRange(1, 8)][int]$WorkerCount = 3,
    [ValidateRange(0, 8)][int]$RequestedWorkerCount = 0,
    [switch]$WorkerCountDefaulted,
    [switch]$InputIdentityOnly,
    [switch]$PlanOnly,
    [string]$BaseRef = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$workerCountParameterExplicit = $PSBoundParameters.ContainsKey("WorkerCount")
$reportedRequestedWorkerCount = $(if ($RequestedWorkerCount -gt 0) { $RequestedWorkerCount } else { $WorkerCount })

function Get-PesterMemoryWorkerLimit {
    param([int]$Requested, [long]$AvailableBytes, [long]$CommitHeadroomBytes = -1, [int]$ActiveWorkers = 0)
    if ($AvailableBytes -lt 0 -and $CommitHeadroomBytes -lt 0) { return 0 }
    $physical = $Requested
    if ($AvailableBytes -ge 0) {
        if ($AvailableBytes -lt 256MB) { return 0 }
        # Workers running at observation already hold their memory; each new one needs 1 GiB more.
        $physical = [int][math]::Max(1, [math]::Min($Requested, $ActiveWorkers + [math]::Floor($AvailableBytes / 1GB)))
    }
    # Admission is deliberately below the remote runner's 92% hard guard:
    # retain 10% host commit headroom and allow 2 GiB per new native worker.
    if ($CommitHeadroomBytes -ge 0) { return [int][math]::Min($physical, [math]::Floor($CommitHeadroomBytes / 2GB)) }
    return $physical
}

function Get-PesterMemorySnapshot {
    param([int]$ActiveWorkers = 0)
    if (-not (Get-Variable pesterMemoryObservedAt -Scope Script -ErrorAction SilentlyContinue) -or
        ([DateTime]::UtcNow - $script:pesterMemoryObservedAt).TotalSeconds -ge 2) {
        try {
            $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -OperationTimeoutSec 2 -ErrorAction Stop
            $headroom = [long][math]::Max(0.0, ([double]$memory.CommitLimit * 0.90 - [double]$memory.CommittedBytes))
            $script:pesterMemorySnapshot = [pscustomobject]@{availableBytes=[long]$memory.AvailableBytes;commitHeadroomBytes=$headroom;activeWorkers=$ActiveWorkers}
        } catch { $script:pesterMemorySnapshot = [pscustomobject]@{availableBytes=-1L;commitHeadroomBytes=-1L;activeWorkers=$ActiveWorkers} }
        $script:pesterMemoryObservedAt = [DateTime]::UtcNow
    }
    return $script:pesterMemorySnapshot
}

function Get-PesterCurrentMemoryWorkerLimit {
    param([int]$ActiveWorkers = 0)
    # Credit only workers that existed when the cached observation was taken.
    $snapshot = Get-PesterMemorySnapshot -ActiveWorkers $ActiveWorkers
    return Get-PesterMemoryWorkerLimit -Requested $WorkerCount -AvailableBytes $snapshot.availableBytes -CommitHeadroomBytes $snapshot.commitHeadroomBytes -ActiveWorkers $snapshot.activeWorkers
}

$memoryAdmissionEnabled = $WorkerCountDefaulted -or -not $workerCountParameterExplicit
$memoryAdmissionReductions = 0
$initialMemoryLimit = $WorkerCount
if ($memoryAdmissionEnabled) {
    $initialMemoryLimit = Get-PesterCurrentMemoryWorkerLimit
    if ($PlanOnly) { $WorkerCount = [math]::Max(1, $initialMemoryLimit) }
}

function Get-PesterWorkloadEstimate {
    param([object[]]$Files, [ValidateRange(1,8)][int]$WorkerCount)
    $pending = @($Files | Where-Object {$_.execution -eq 'execute'})
    $total = 0.0
    # Match admission barriers: preflight, LPT parallel files, then serial files.
    foreach ($preflight in @($true,$false)) {
        $slots = New-Object double[] $WorkerCount
        foreach ($file in @($pending | Where-Object {-not $_.serial -and $_.preflight -eq $preflight} |
            Sort-Object @{Expression={[double]$_.estimatedSeconds};Descending=$true},@{Expression={[string]$_.path}})) {
            $next = 0
            for ($i=1; $i -lt $WorkerCount; $i++) { if ($slots[$i] -lt $slots[$next]) { $next=$i } }
            $slots[$next] += [double]$file.estimatedSeconds
        }
        $total += ($slots | Measure-Object -Maximum).Maximum
    }
    foreach ($file in $pending) { if ($file.serial) { $total += [double]$file.estimatedSeconds } }
    return [int][math]::Ceiling($total)
}


function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

. (Join-Path $PSScriptRoot "invoke-pester-runtime.ps1")

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
. (Join-Path (Split-Path -Parent $PSScriptRoot) ".agents\skills\1c-workflow\scripts\lib\agent-1c.immutable-download.ps1")
$catalog = Get-QualityContractCatalog -RepositoryRoot $RepositoryRoot
$trackedPaths = @()
$commonGitDir = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot
$cacheRoot = Join-Path $commonGitDir "itl\pester-shards\v1"; New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
# A support clone has a separate common Git directory. Read exact proofs from
# its local origin or explicitly configured repositories, without copying or
# modifying their stores. Shared ancestry prevents unrelated repositories from
# becoming implicit proof sources; the normal digest/runtime/SHA checks remain.
$proofCacheRoots = @($cacheRoot)
$proofSources = @()
$proofAncestorRoots = $null
$configuredSources = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('config','--local','--get-all','itl.pesterProofSource') -AllowFailure
if ($configuredSources.exitCode -eq 0) { $proofSources += @(([string]$configuredSources.stdout -split '\r?\n') | Where-Object { $_ }) }
$originSource = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('remote','get-url','origin') -AllowFailure
if ($originSource.exitCode -eq 0) { $proofSources += ([string]$originSource.stdout).Trim() }
foreach ($source in @($proofSources | Select-Object -Unique)) {
    try {
        $sourceRoot = if ([IO.Path]::IsPathRooted($source)) { $source } else { Join-Path $RepositoryRoot $source }
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { continue }
        if ($null -eq $proofAncestorRoots) {
            $roots = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-list','--max-parents=0','HEAD') -AllowFailure
            $proofAncestorRoots = @(([string]$roots.stdout -split '\r?\n') | Where-Object { $_ -match '^[a-f0-9]{40}$' })
        }
        $sharesHistory = $false
        foreach ($rootCommit in $proofAncestorRoots) {
            # Either checkout may have progressed since cloning; no fetch or
            # knowledge of the other's newest commit is needed to prove ancestry.
            $ancestor = Invoke-RepositoryGit -RepositoryRoot $sourceRoot -Arguments @('merge-base','--is-ancestor',$rootCommit,'HEAD') -AllowFailure
            if ($ancestor.exitCode -eq 0) { $sharesHistory = $true; break }
        }
        if (-not $sharesHistory) { continue }
        $sourceCache = Join-Path (Get-RepositoryCommonGitDirectory -RepositoryRoot $sourceRoot) 'itl\pester-shards\v1'
        if (Test-Path -LiteralPath $sourceCache -PathType Container) { $proofCacheRoots += $sourceCache }
    } catch { Write-Verbose "Pester proof source unavailable: $source" }
}
$proofCacheRoots = @($proofCacheRoots | Select-Object -Unique)
$script:pesterVanessaArchiveCandidates = @()
$script:pesterExternalIdentityCache = @{}
$script:pesterLegacyExternalIdentityCache = @{}
$script:pesterTrackedIdentityCache = @{}
$script:pesterIdentityInventoryMs = 0L
$script:pesterCacheLookupMs = 0L
$script:pesterLegacyDigestCount = 0
$script:pesterOwnerInputSnapshot = $null
$pesterExternalInputsByTest = @{}
$pesterExternalInputsProperty = $catalog.PSObject.Properties["pesterExternalInputs"]
if ($pesterExternalInputsProperty) {
    foreach ($property in @($pesterExternalInputsProperty.Value.PSObject.Properties)) {
        $pesterExternalInputsByTest[([string]$property.Name).Replace('\', '/')] = @($property.Value | ForEach-Object { [string]$_ })
    }
}
$sharedInputs = @(
    "tests/pester/TestSupport.ps1", "scripts/run-pester-shard.ps1", "scripts/invoke-pester-runtime.ps1"
)
$powerShellCommand = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$script:pesterPowerShellExecutable = $(if ($powerShellCommand) { [string]$powerShellCommand.Source } else { 'powershell.exe' })
$script:pesterRuntimeReceipt = [pscustomobject]@{status='unknown';identity=$null;reason='Runtime has not been observed.';durationMs=0}

function Start-PesterWorkerProcess {
    param([string[]]$Arguments, [string]$StdinPath, [string]$StdoutPath, [string]$StderrPath, [string[]]$ExternalInputNames = @())
    $originalPowerShellModulePath = $env:PSModulePath
    $resetModulePathForWindowsPowerShell = [string]$PSVersionTable.PSEdition -eq "Core"
    $externalValues = @{}
    try {
        # Match the actual child environment to the per-file digest contract.
        # Restore the scheduler before launching any other worker.
        foreach ($name in @(Get-QualityPesterExternalInputNames)) {
            $externalValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ($name -notin $ExternalInputNames) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        }
        if ($resetModulePathForWindowsPowerShell) {
            $coreModuleRoot = [IO.Path]::GetFullPath((Join-Path $PSHOME "Modules")).TrimEnd('\')
            $compatibleModuleRoots = @($originalPowerShellModulePath -split ';' | Where-Object {
                if ([string]::IsNullOrWhiteSpace($_)) { return $false }
                try { return -not [string]::Equals([IO.Path]::GetFullPath($_).TrimEnd('\'), $coreModuleRoot, [StringComparison]::OrdinalIgnoreCase) }
                catch { return $true }
            })
            $env:PSModulePath = $compatibleModuleRoots -join ';'
        }
        return Start-Process -FilePath $script:pesterPowerShellExecutable -ArgumentList ($Arguments -join ' ') -WorkingDirectory $RepositoryRoot -WindowStyle Hidden -RedirectStandardInput $StdinPath -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath -PassThru
    } finally {
        foreach ($name in @($externalValues.Keys)) { [Environment]::SetEnvironmentVariable($name, $externalValues[$name], 'Process') }
        if ($resetModulePathForWindowsPowerShell) {
            if ($null -eq $originalPowerShellModulePath) { Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue }
            else { $env:PSModulePath = $originalPowerShellModulePath }
        }
    }
}

function Get-PesterWorkerRuntimeReceipt {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    $probeRoot = Join-Path $workerRoot ('runtime-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText(($probeRoot + '.stdin.txt'), '', [Text.UTF8Encoding]::new($false))
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(ConvertTo-NativeArgument $workerScript),'-RuntimeIdentityOnly','-ResultPath',(ConvertTo-NativeArgument ($probeRoot + '.json')))
        $process = Start-PesterWorkerProcess -Arguments $arguments -StdinPath ($probeRoot + '.stdin.txt') -StdoutPath ($probeRoot + '.stdout.log') -StderrPath ($probeRoot + '.stderr.log')
        # Desktop Start-Process can lose ExitCode after WaitForExit unless its
        # native handle was acquired while the process was still running.
        $null = $process.Handle
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Runtime identity probe exceeded 15 seconds; execute tests without reuse.' }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Runtime identity probe failed; execute tests without reuse.' }
        $receipt = Get-Content -LiteralPath ($probeRoot + '.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($receipt.status -eq 'known') {
            if (-not $receipt.identity -or [string]$receipt.identity.identitySha256 -notmatch '^[a-f0-9]{64}$' -or
                -not [IO.Path]::IsPathRooted([string]$receipt.identity.pesterManifestPath) -or
                -not [string]::Equals([IO.Path]::GetFullPath([string]$receipt.identity.executablePath), [IO.Path]::GetFullPath($script:pesterPowerShellExecutable), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Runtime identity probe did not describe the selected executable.'
            }
        } elseif ($receipt.status -ne 'unknown') { throw 'Runtime identity probe returned an unsupported status.' }
        $receipt.durationMs = [int64]$watch.ElapsedMilliseconds
        return $receipt
    } catch {
        return [pscustomobject]@{status='unknown';identity=$null;reason=$_.Exception.Message;durationMs=[int64]$watch.ElapsedMilliseconds}
    } finally {
        if ($process) { $process.Dispose() }
        $watch.Stop()
    }
}

function Get-ShardExternalProfiles {
    param([string[]]$Paths)
    $mapping=$catalog.PSObject.Properties['pesterExternalRuntimeTests']
    if(-not $mapping){return @()}
    return @($Paths|ForEach-Object {
        $relative=Get-ShardRelativeTestPath $_
        $property=$mapping.Value.PSObject.Properties[$relative]
        if($property){@($property.Value)}
    }|Sort-Object -Unique)
}
function Get-PesterExternalWorkerReceipt {
    $mapping=$catalog.PSObject.Properties['pesterExternalRuntimeTests']
    if(-not $mapping){return [pscustomobject]@{}}
    $definitions=$catalog.PSObject.Properties['pesterExternalRuntimeProfiles']
    if(-not $definitions){return [pscustomobject]@{}}
    $profiles=[ordered]@{}
    foreach($name in @(Get-ShardExternalProfiles @($items.path))){
        $definition=$definitions.Value.PSObject.Properties[$name]
        if($definition){$profiles[$name]=$definition.Value}
    }
    if(-not $profiles.Count){return [pscustomobject]@{}}
    $script:pesterExternalSpecPath=Join-Path $workerRoot 'external-runtime.json'
    $spec=[ordered]@{repositoryRoot=$RepositoryRoot;profiles=[pscustomobject]$profiles}
    [IO.File]::WriteAllText($script:pesterExternalSpecPath,($spec|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $output=Join-Path $workerRoot ('external-runtime.receipt-'+[guid]::NewGuid().ToString('N')+'.json')
    $process=$null
    try {
        $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(ConvertTo-NativeArgument (Join-Path $PSScriptRoot 'run-pester-external-shard.ps1')),
            '-RuntimeIdentityOnly','-ProfilePath',(ConvertTo-NativeArgument $script:pesterExternalSpecPath),'-ResultPath',(ConvertTo-NativeArgument $output))
        $stdin=Join-Path $workerRoot 'external-runtime.stdin'
        [IO.File]::WriteAllText($stdin,'',[Text.UTF8Encoding]::new($false))
        $process=Start-PesterWorkerProcess -Arguments $args -StdinPath $stdin -StdoutPath ($output+'.stdout') -StderrPath ($output+'.stderr')
        $null=$process.Handle
        if(-not $process.WaitForExit(60000)){$process.Kill();$process.WaitForExit()}
        $process.WaitForExit()
        # Completed rows remain qualified even if another profile timed out.
        # The atomic receipt initializes unfinished rows as unknown.
        if(-not [IO.File]::Exists($output)){return [pscustomobject]@{}}
        return Get-Content -LiteralPath $output -Raw -Encoding UTF8|ConvertFrom-Json
    } catch {return [pscustomobject]@{}} finally {if($process){$process.Dispose()}}
}

function Test-PesterShardResultRuntime {
    param([object]$Result,[string]$TestPath='')
    $receiptVariable = Get-Variable -Name pesterRuntimeReceipt -Scope Script -ErrorAction SilentlyContinue
    if (-not $receiptVariable -or -not $receiptVariable.Value -or $receiptVariable.Value.status -ne 'known') { return $false }
    $actual = $Result.PSObject.Properties['runtimeIdentity']
    $baseMatches=$actual -and $actual.Value -and $actual.Value.PSObject.Properties['identitySha256'] -and
        [string]$actual.Value.identitySha256 -ceq [string]$receiptVariable.Value.identity.identitySha256
    if(-not $baseMatches){return $false}
    foreach($profile in @(Get-ShardExternalProfiles $(if($TestPath){@($TestPath)}else{@($Result.paths)}))){
        $expected=$script:pesterExternalRuntimeReceipt.PSObject.Properties[$profile]
        $witness=$Result.PSObject.Properties['externalRuntimeIdentity']
        $observed=if($witness){$witness.Value.PSObject.Properties[$profile]}else{$null}
        if(-not $expected -or $expected.Value.status -ne 'known' -or [string]$expected.Value.sha256 -cnotmatch '^[a-f0-9]{64}$' -or -not $observed -or
            $observed.Value.status -ne 'known' -or $observed.Value.sha256 -cne $expected.Value.sha256){return $false}
    }
    return $true
}

function Initialize-VanessaSourceBuildArchiveForPester {
    param([switch]$ReadOnly)
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
    $configuredArchive = ""
    if ($configured) {
        try { $configured = [IO.Path]::GetFullPath($configured) } catch { throw "Configured Vanessa source-build path is invalid: $configured" }
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) {
            throw "Configured Vanessa source-build archive is missing: $configured"
        }
        $actual = Get-PesterShardFileSha256 -Path $configured
        if ($actual -ne $expected) {
            throw "Configured Vanessa source-build SHA256 differs from the dependency lock: expected=$expected actual=$actual path=$configured"
        }
        $configuredArchive = $configured
    }

    $candidateRoots = New-Object System.Collections.Generic.List[string]
    $candidateRoots.Add($RepositoryRoot)
    $recentHeads = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        foreach ($head in @(& git -C $RepositoryRoot rev-list --max-count=8 HEAD 2>$null)) {
            if ([string]$head -match '^[a-f0-9]{40}$') { [void]$recentHeads.Add([string]$head) }
        }
        $worktreeLines = @(& git -C $RepositoryRoot worktree list --porcelain 2>$null)
        $worktreeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($worktreeExitCode -eq 0) {
        $candidateRoot = ""
        $recentRootByHead = @{}
        foreach ($line in $worktreeLines) {
            if ([string]$line -match '^worktree\s+(.+)$') {
                try { $candidateRoot = [IO.Path]::GetFullPath($Matches[1]) } catch { $candidateRoot = "" }
            } elseif ($candidateRoot -and [string]$line -match '^HEAD\s+([a-f0-9]{40})$' -and $recentHeads.Contains([string]$Matches[1])) {
                $head = [string]$Matches[1]
                try { $modifiedAt = (Get-Item -LiteralPath $candidateRoot -ErrorAction Stop).LastWriteTimeUtc } catch { continue }
                if (-not $recentRootByHead.ContainsKey($head) -or $modifiedAt -gt $recentRootByHead[$head].modifiedAt) {
                    $recentRootByHead[$head] = [pscustomobject]@{ path = $candidateRoot; modifiedAt = $modifiedAt }
                }
            }
        }
        foreach ($head in @($recentRootByHead.Keys | Sort-Object)) { $candidateRoots.Add([string]$recentRootByHead[$head].path) }
    }
    $validCandidates = New-Object System.Collections.Generic.List[string]
    if ($configuredArchive) { $validCandidates.Add($configuredArchive) | Out-Null }
    foreach ($root in @($candidateRoots | Select-Object -Unique)) {
        $candidate = Join-Path $root ("build\third-party\vanessa-automation\$folderName\$assetName")
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if ((Get-PesterShardFileSha256 -Path $candidate) -eq $expected) {
            $validCandidates.Add([IO.Path]::GetFullPath($candidate)) | Out-Null
        }
    }

    $sharedDirectory = Join-Path $commonGitDir "itl\dependencies\vanessa-automation\$folderName"
    $sharedArchive = Join-Path $sharedDirectory ("$expected-$assetName")
    if (Test-Path -LiteralPath $sharedArchive -PathType Leaf) {
        $sharedHash = Get-PesterShardFileSha256 -Path $sharedArchive
        if ($sharedHash -ne $expected) {
            throw "Shared Vanessa source-build cache entry has an impossible SHA-address mismatch: expected=$expected actual=$sharedHash path=$sharedArchive"
        }
        $validCandidates.Add([IO.Path]::GetFullPath($sharedArchive)) | Out-Null
    }
    $script:pesterVanessaArchiveCandidates = @($validCandidates | Select-Object -Unique)
    if ($script:pesterVanessaArchiveCandidates.Count -gt 0) {
        $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $(if ($configuredArchive) { $configuredArchive } else { [string]$script:pesterVanessaArchiveCandidates[0] })
        return
    }

    if ($ReadOnly) { return }
    $url = [string]$lock.url
    if (-not $url) { throw "Locked Vanessa source-build URL is missing and no exact shared candidate was found." }
    New-Item -ItemType Directory -Force -Path $sharedDirectory | Out-Null
    [void](Invoke-ItlImmutableFileDownload -Uri $url -DestinationPath $sharedArchive -ExpectedSha256 $expected -Label "Pester Vanessa source-build archive")
    $script:pesterVanessaArchiveCandidates = @([IO.Path]::GetFullPath($sharedArchive))
    $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $sharedArchive
}

function Get-ExternalInputIdentity {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    $cacheKey = "$Name`n$value"
    if ($script:pesterExternalIdentityCache.ContainsKey($cacheKey)) { return [string]$script:pesterExternalIdentityCache[$cacheKey] }
    if (-not $value) {
        $script:pesterExternalIdentityCache[$cacheKey] = "env:$Name=<unset>"
        return [string]$script:pesterExternalIdentityCache[$cacheKey]
    }
    $identity = "env:$Name"
    if (Test-Path -LiteralPath $value -PathType Leaf) {
        $script:pesterExternalIdentityCache[$cacheKey] = "$identity|kind=file|sha256=$(Get-PesterShardFileSha256 -Path $value)"
        return [string]$script:pesterExternalIdentityCache[$cacheKey]
    }
    if (Test-Path -LiteralPath $value -PathType Container) {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $head = @(& git -C $value rev-parse HEAD 2>$null)
            $headExitCode = $LASTEXITCODE
            $tree = @(& git -C $value rev-parse 'HEAD^{tree}' 2>$null)
            $treeExitCode = $LASTEXITCODE
            $tracked = @(& git -C $value status --porcelain --untracked-files=no 2>$null)
            $statusExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        if ($headExitCode -eq 0 -and $treeExitCode -eq 0 -and $statusExitCode -eq 0 -and $head.Count -eq 1 -and $tree.Count -eq 1) {
            $script:pesterExternalIdentityCache[$cacheKey] = "$identity|kind=git|commit=$($head[0].Trim())|tree=$($tree[0].Trim())|trackedClean=$($tracked.Count -eq 0)"
            return [string]$script:pesterExternalIdentityCache[$cacheKey]
        }
    }
    $script:pesterExternalIdentityCache[$cacheKey] = "$identity|kind=unresolved|path=$value"
    return [string]$script:pesterExternalIdentityCache[$cacheKey]
}

function Get-LegacyExternalInputIdentity {
    param([string]$Name, [string]$Value)
    $cacheKey = "$Name`n$Value"
    if ($script:pesterLegacyExternalIdentityCache.ContainsKey($cacheKey)) { return [string]$script:pesterLegacyExternalIdentityCache[$cacheKey] }
    if (-not $Value) {
        $script:pesterLegacyExternalIdentityCache[$cacheKey] = "env:$Name=<unset>"
        return [string]$script:pesterLegacyExternalIdentityCache[$cacheKey]
    }
    $identity = "env:$Name=$Value"
    if (Test-Path -LiteralPath $Value -PathType Leaf) {
        $script:pesterLegacyExternalIdentityCache[$cacheKey] = "$identity|sha256=$(Get-PesterShardFileSha256 -Path $Value)"
        return [string]$script:pesterLegacyExternalIdentityCache[$cacheKey]
    }
    if (Test-Path -LiteralPath $Value -PathType Container) {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $head = @(& git -C $Value rev-parse HEAD 2>$null)
            $headExitCode = $LASTEXITCODE
            $tree = @(& git -C $Value rev-parse 'HEAD^{tree}' 2>$null)
            $treeExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        if ($headExitCode -eq 0 -and $treeExitCode -eq 0 -and $head.Count -eq 1 -and $tree.Count -eq 1) {
            $script:pesterLegacyExternalIdentityCache[$cacheKey] = "$identity|commit=$($head[0].Trim())|tree=$($tree[0].Trim())"
            return [string]$script:pesterLegacyExternalIdentityCache[$cacheKey]
        }
    }
    $script:pesterLegacyExternalIdentityCache[$cacheKey] = "$identity|unresolved"
    return [string]$script:pesterLegacyExternalIdentityCache[$cacheKey]
}

function Initialize-PesterTrackedIdentityCache {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $dirty = @{}
        $inventoryPaths = New-Object System.Collections.Generic.List[string]
        foreach ($entry in @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @("ls-files", "-t", "-s", "-m", "-z", "--"))) {
            $match = [regex]::Match([string]$entry, '^(?<tag>[A-Z?]) [0-7]{6} (?<object>[a-f0-9]{40,64}) 0\t(?<path>.*)$')
            if (-not $match.Success) { continue }
            $path = ([string]$match.Groups['path'].Value).Replace('\', '/')
            if ([string]$match.Groups['tag'].Value -eq "C") {
                $dirty[$path] = $true
                continue
            }
            $inventoryPaths.Add($path) | Out-Null
            $script:pesterTrackedIdentityCache[$path] = "git-blob:$([string]$match.Groups['object'].Value)"
        }
        foreach ($path in $dirty.Keys) { $script:pesterTrackedIdentityCache.Remove([string]$path) }
        $script:trackedPaths = @($inventoryPaths | Sort-Object -Unique)
    } finally {
        $stopwatch.Stop()
        $script:pesterIdentityInventoryMs = [int64]$stopwatch.ElapsedMilliseconds
    }
}

function Get-ShardTrackedFileIdentity {
    param([Parameter(Mandatory = $true)][string]$RelativePath, [Parameter(Mandatory = $true)][string]$AbsolutePath)
    $cacheKey = $RelativePath.Replace('\', '/')
    if ($script:pesterTrackedIdentityCache.ContainsKey($cacheKey)) { return [string]$script:pesterTrackedIdentityCache[$cacheKey] }
    # Hash dirty and untracked bytes exactly as Git will store them. This keeps a
    # focused pre-commit proof reusable after the identical files are committed,
    # while --path still applies repository attributes and clean filters.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $worktreeBlob = @(& git -C $RepositoryRoot hash-object --path $RelativePath -- $AbsolutePath 2>$null)
        $worktreeBlobExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($worktreeBlobExitCode -eq 0 -and $worktreeBlob.Count -eq 1 -and $worktreeBlob[0].Trim() -match '^[a-f0-9]{40,64}$') {
        $script:pesterTrackedIdentityCache[$cacheKey] = "git-blob:$($worktreeBlob[0].Trim())"
        return [string]$script:pesterTrackedIdentityCache[$cacheKey]
    }
    $script:pesterTrackedIdentityCache[$cacheKey] = "worktree-sha256:$(Get-PesterShardFileSha256 -Path $AbsolutePath)"
    return [string]$script:pesterTrackedIdentityCache[$cacheKey]
}

function Get-ShardRelativeTestPath {
    param([string]$Path, [string]$Root = $RepositoryRoot)
    try {
        if (-not [IO.Path]::IsPathRooted($Path) -or -not [IO.Path]::IsPathRooted($Root)) { return '' }
        $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $absolute = [IO.Path]::GetFullPath($Path)
        if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return '' }
        return $absolute.Substring($prefix.Length).Replace('\', '/')
    } catch { return '' }
}

function Test-ShardResultTestPath {
    param([object]$Result, [string]$TestPath, [string]$SourceRoot = $RepositoryRoot)
    if (-not $Result -or -not $Result.PSObject.Properties['paths'] -or @($Result.paths).Count -ne 1) { return $false }
    $expected = Get-ShardRelativeTestPath -Path $TestPath
    $actual = Get-ShardRelativeTestPath -Path ([string]$Result.paths[0]) -Root $SourceRoot
    return $expected -and $actual -and [string]::Equals($expected, $actual, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ShardInputDigest {
    param(
        [string[]]$Paths,
        [string[]]$AdditionalInputs = @(),
        [hashtable]$ExternalIdentityOverrides,
        [switch]$IncludeLegacyGlobalExternalInputs,
        [ValidateRange(0, 4)][int]$LegacyWorkerCount = 0,
        [ref]$PreparedInputs
    )
    $relativeTests = @($Paths | ForEach-Object { Get-ShardRelativeTestPath -Path $_ })
    if (@($relativeTests | Where-Object { -not $_ }).Count -gt 0) { return '' }
    $nonReusableProperty = $catalog.PSObject.Properties['pesterNonReusableTests']
    # Unknown external runtime identity cannot qualify a reusable shard. For
    # example, the OneScript probe executes installed engine assemblies.
    if ($nonReusableProperty -and @($relativeTests | Where-Object { $_ -in @($nonReusableProperty.Value) }).Count -gt 0) { return '' }
    $externalRuntimeLines=New-Object System.Collections.Generic.List[string]
    if ($catalog.PSObject.Properties['pesterExternalRuntimeTests']) {
        $externalReceipt=Get-Variable -Name pesterExternalRuntimeReceipt -Scope Script -ErrorAction SilentlyContinue
        foreach($profile in @(Get-ShardExternalProfiles $Paths)) {
            if(-not $externalReceipt -or -not $externalReceipt.Value){return ''}
            $external=$externalReceipt.Value.PSObject.Properties[$profile]
            if(-not $external -or $external.Value.status -ne 'known' -or [string]$external.Value.sha256 -cnotmatch '^[a-f0-9]{64}$'){return ''}
            $externalRuntimeLines.Add('external-runtime='+$profile+'|'+$external.Value.sha256)
            foreach($file in @('scripts/pester-external-runtime.ps1','scripts/run-pester-external-shard.ps1')) {
                $externalRuntimeLines.Add($file+'='+(Get-PesterShardFileSha256 (Join-Path $PSScriptRoot (Split-Path $file -Leaf))))
            }
        }
    }
    $snapshotVariable=Get-Variable -Name pesterOwnerInputSnapshot -Scope Script -ErrorAction SilentlyContinue
    if (-not $snapshotVariable -or -not $snapshotVariable.Value -or
        -not [object]::ReferenceEquals($snapshotVariable.Value.catalog,$catalog) -or
        -not [object]::ReferenceEquals($snapshotVariable.Value.inventory,$trackedPaths) -or
        $snapshotVariable.Value.root -cne $RepositoryRoot) {
        $script:pesterOwnerInputSnapshot=[pscustomobject]@{catalog=$catalog;inventory=$trackedPaths;root=$RepositoryRoot}
        if($PreparedInputs) {$PreparedInputs.Value=$null}
        $script:pesterContractInputCache=@{};$script:pesterPatternInputs=@{};$script:pesterContractsByTest=@{}
        foreach ($contract in $catalog.contracts) {
            foreach ($test in @($contract.tests)) {
                $test=([string]$test).Replace('\','/')
                if (-not $script:pesterContractsByTest.ContainsKey($test)) {
                    $script:pesterContractsByTest[$test]=New-Object System.Collections.Generic.List[object]
                }
                $script:pesterContractsByTest[$test].Add($contract)
            }
        }
        $script:pesterSemanticBindings=Get-QualityPesterSemanticInputBindings -Catalog $catalog
    }
    if(-not $script:pesterSemanticBindings.complete){return ''}
    # One local reference per item holds only paths resolved from the same
    # immutable catalog/tracked inventory snapshot. Runtime/environment variants
    # below still obtain their own identity lines and verify protected results.
    $selectionKey = [ordered]@{ tests=@($relativeTests); additionalInputs=@($AdditionalInputs) } | ConvertTo-Json -Compress
    if ($PreparedInputs -and $PreparedInputs.Value -and $PreparedInputs.Value.selectionKey -ceq $selectionKey) {
        $inputs = @($PreparedInputs.Value.paths)
    } else {
        if ($PreparedInputs) { $PreparedInputs.Value = $null }
        foreach ($test in $relativeTests) { if (-not $script:pesterContractsByTest.ContainsKey($test)) { return '' } }
        $contracts = @($relativeTests | ForEach-Object { $script:pesterContractsByTest[$_].ToArray() })
        # Loaded dependencies qualify reuse without widening Targeted selection.
        $reusePatterns = @($contracts | ForEach-Object { Get-QualityContractReuseInputPaths -Contract $_ } | Sort-Object -Unique)
        $patterns = @(@($contracts | ForEach-Object { @($_.paths) }) + $reusePatterns | ForEach-Object { ([string]$_).Replace('\','/') } | Sort-Object -Unique)
        $patternKey = @($patterns + '<required>' + $reusePatterns) -join [char]0
        if (-not $script:pesterContractInputCache.ContainsKey($patternKey)) {
            foreach ($pattern in $patterns) {
                if (-not $script:pesterPatternInputs.ContainsKey($pattern)) {
                    $script:pesterPatternInputs[$pattern] = @(Select-QualityPaths -Paths $trackedPaths -Pattern @($pattern))
                }
            }
            $complete = @($reusePatterns | Where-Object {$script:pesterPatternInputs[$_].Count -eq 0}).Count -eq 0
            $script:pesterContractInputCache[$patternKey] = [pscustomobject]@{
                complete=$complete; paths=@($patterns | ForEach-Object {$script:pesterPatternInputs[$_]} | Sort-Object -Unique)
            }
        }
        $resolved = $script:pesterContractInputCache[$patternKey]
        if (-not $resolved.complete) { return '' }
        $semanticInputs=@($relativeTests|ForEach-Object {$script:pesterSemanticBindings.byTest[[string]$_]}|Where-Object {$_})
        # Unknown supplemental inputs remain mandatory. Known semantic inputs
        # use their authoritative test owners, including in a Full inventory.
        $supplemental=@($AdditionalInputs|Where-Object {$_ -notin $script:pesterSemanticBindings.paths -or $_ -in $semanticInputs})
        $inputs = @($relativeTests + $sharedInputs + $supplemental + $semanticInputs + @($resolved.paths) | Sort-Object -Unique)
        if ($PreparedInputs) { $PreparedInputs.Value = [pscustomobject]@{ selectionKey=$selectionKey; paths=$inputs } }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    # Old receipts were produced with undeclared inherited inputs. They cannot
    # qualify the isolated child contract, including through legacy lookup keys.
    $lines.Add('external-input-scope=declared-v1')
    # The selected tests are distinct from their shared owner input set.
    # Deduplicating that set must never make different test files one shard.
    foreach ($test in @($relativeTests | Sort-Object -Unique)) { $lines.Add("selected-test=$test") }
    $receiptVariable = Get-Variable -Name pesterRuntimeReceipt -Scope Script -ErrorAction SilentlyContinue
    if (-not $receiptVariable -or -not $receiptVariable.Value -or $receiptVariable.Value.status -ne 'known') { return '' }
    $runtime = $receiptVariable.Value.identity
    # Parallelism belongs to the parent scheduler; each isolated child receives
    # the same test/runner inputs. Retain old keys only for verified cache lookup.
    $runtimeIdentity = "powershell=$($runtime.powerShellVersion)|pester=$($runtime.pesterVersion)|child=$($runtime.identitySha256)"
    # Old scheduler keys are lookup candidates only. Their protected result must
    # independently prove the current child identity before any reuse.
    if ($LegacyWorkerCount -gt 0) { $runtimeIdentity = "powershell=$($runtime.powerShellVersion)|pester=$($runtime.pesterVersion)|workers=$LegacyWorkerCount" }
    $lines.Add($runtimeIdentity)
    foreach($externalLine in $externalRuntimeLines){$lines.Add($externalLine)}
    $externalInputNames = if ($IncludeLegacyGlobalExternalInputs) {
        @(Get-QualityPesterExternalInputNames)
    } else {
        @($relativeTests | ForEach-Object {
            if ($pesterExternalInputsByTest.ContainsKey([string]$_)) { @($pesterExternalInputsByTest[[string]$_]) }
        } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }
    foreach ($name in $externalInputNames) {
        if ($ExternalIdentityOverrides -and $ExternalIdentityOverrides.ContainsKey($name)) { $lines.Add([string]$ExternalIdentityOverrides[$name]) }
        else { $lines.Add((Get-ExternalInputIdentity -Name $name)) }
    }
    foreach ($path in $inputs) {
        $absolute=[IO.Path]::Combine($RepositoryRoot,$path.Replace('/','\'))
        if([IO.File]::Exists($absolute)) {$lines.Add("$path=$(Get-ShardTrackedFileIdentity -RelativePath $path -AbsolutePath $absolute)")}
        else {$lines.Add("$path=<missing>")}
    }
    return Get-TextSha256 -Lines $lines
}

function Get-ShardCacheEntryRoot {
    param([string]$Digest, [string]$TestPath = '', [switch]$LocalOnly)
    if (-not $Digest) { return $null }
    $candidates = @()
    foreach ($store in $(if ($LocalOnly) { @($cacheRoot) } else { $proofCacheRoots })) {
        $target = Join-Path $store $Digest
        $candidates += $target
        if (Test-Path -LiteralPath $target -PathType Container) {
            $candidates += @(Get-ChildItem -LiteralPath $target -Directory -Filter ".$Digest.*.tmp")
        }
    }
    foreach ($candidate in $candidates) {
        $entryRoot = if ($candidate -is [IO.DirectoryInfo]) { $candidate.FullName } else { [string]$candidate }
        $cachedResult = Join-Path $entryRoot "result.json"; $cachedJunit = Join-Path $entryRoot "pester.xml"; $manifestPath = Join-Path $entryRoot "manifest.json"
        if (-not (Test-Path -LiteralPath $cachedResult -PathType Leaf) -or -not (Test-Path -LiteralPath $cachedJunit -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$manifest.schemaVersion -eq 1 -and [string]$manifest.digest -eq $Digest -and
                [string]$manifest.resultSha256 -eq (Get-PesterShardFileSha256 -Path $cachedResult) -and
                [string]$manifest.junitSha256 -eq (Get-PesterShardFileSha256 -Path $cachedJunit)) {
                if ($TestPath) {
                    $producerRoot = $manifest.PSObject.Properties['repositoryRoot']
                    if (-not $producerRoot -or -not [string]$producerRoot.Value) { continue }
                    $result = Get-Content -LiteralPath $cachedResult -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$result.status -ne 'passed' -or [int]$result.failed -ne 0) { continue }
                    if (-not (Test-ShardResultTestPath -Result $result -TestPath $TestPath -SourceRoot ([string]$producerRoot.Value))) { continue }
                    if (-not (Test-PesterShardResultRuntime -Result $result -TestPath $TestPath)) { continue }
                }
                return $entryRoot
            }
        } catch {}
    }
    return ""
}

function Restore-ShardCache {
    param([string]$Digest, [string]$ResultPath, [string]$JunitPath, [int]$Worker, [string]$TestPath, [switch]$ReadOnly)
    $entryRoot = Get-ShardCacheEntryRoot -Digest $Digest -TestPath $TestPath
    if (-not $entryRoot) { return $null }
    $cachedResult = Join-Path $entryRoot "result.json"; $cachedJunit = Join-Path $entryRoot "pester.xml"
    try {
        $result = Get-Content -LiteralPath $cachedResult -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$result.status -ne "passed" -or [int]$result.failed -ne 0) { return $null }
        $result | Add-Member -NotePropertyName proofSource -NotePropertyValue $entryRoot -Force
        if ($ReadOnly) { return $result }
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
    if (-not (Test-PesterShardResultRuntime -Result $result)) { return }
    if ([string]$result.status -ne "passed" -or [int]$result.failed -ne 0 -or -not (Test-Path -LiteralPath $JunitPath -PathType Leaf)) { return }
    if (-not $result.PSObject.Properties['paths'] -or @($result.paths).Count -ne 1) { return }
    $testPath = [string]$result.paths[0]
    if (-not (Get-ShardRelativeTestPath -Path $testPath)) { return }
    $target = Join-Path $cacheRoot $Digest
    if (Get-ShardCacheEntryRoot -Digest $Digest -TestPath $testPath -LocalOnly) { return }
    if (Test-Path -LiteralPath $target -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $target -Force).Count -gt 0) {
            if (-not (Get-ShardCacheEntryRoot -Digest $Digest -LocalOnly)) { throw "Incomplete Pester shard cache is not empty: $target" }
            # Preserve an integrity-valid entry for another test. The existing
            # concurrent-writer layout admits our completed candidate below it.
        } else { Remove-Item -LiteralPath $target -Force }
    }
    $staging = Join-Path $cacheRoot ("." + $Digest + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        Copy-Item -LiteralPath $ResultPath -Destination (Join-Path $staging "result.json")
        Copy-Item -LiteralPath $JunitPath -Destination (Join-Path $staging "pester.xml")
        $manifest = [ordered]@{ schemaVersion = 1; digest = $Digest; repositoryRoot = $RepositoryRoot; resultSha256 = (Get-PesterShardFileSha256 -Path (Join-Path $staging "result.json")); junitSha256 = (Get-PesterShardFileSha256 -Path (Join-Path $staging "pester.xml")) }
        [IO.File]::WriteAllText((Join-Path $staging "manifest.json"), (($manifest | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        try { Move-Item -LiteralPath $staging -Destination $target -ErrorAction Stop } catch { if (-not (Test-Path -LiteralPath $target)) { throw } }
    } finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
}

$timingPath = Join-Path $PSScriptRoot "pester-timings.json"
$timings = Get-Content -LiteralPath $timingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$testRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot "tests\pester")).TrimEnd('\') + '\'
$selectionAdditionalInputs = @()
if ($SelectionPath) {
    $selection = Get-Content -LiteralPath ([IO.Path]::GetFullPath($SelectionPath)) -Raw -Encoding UTF8 | ConvertFrom-Json
    $schemaProperty = $selection.PSObject.Properties["schemaVersion"]
    if ($schemaProperty -and [int]$schemaProperty.Value -eq 2) {
        foreach ($requiredProperty in @("paths", "contracts", "tests", "semanticImpacts", "additionalInputs")) {
            if (-not $selection.PSObject.Properties[$requiredProperty]) { throw "Targeted selection schemaVersion 2 requires $requiredProperty." }
        }
        $selectionAdditionalInputs = @($selection.additionalInputs | ForEach-Object { ([string]$_).Replace('\', '/') })
        if (@($selectionAdditionalInputs | Sort-Object -Unique).Count -ne $selectionAdditionalInputs.Count -or
            @($selectionAdditionalInputs | Where-Object { -not $_ -or [IO.Path]::IsPathRooted($_) -or $_ -match '[*?\[]' -or $_ -match '(^|/)\.\.(/|$)' }).Count -gt 0) {
            throw "Targeted selection additionalInputs must contain unique exact repository-relative paths."
        }
        foreach ($relativeInput in $selectionAdditionalInputs) {
            $absoluteInput = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relativeInput.Replace('/', '\')))
            if (-not $absoluteInput.StartsWith($RepositoryRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $absoluteInput -PathType Leaf)) {
                throw "Targeted selection additional input is missing or outside the repository: $relativeInput"
            }
        }
        $semanticCatalogProperty = $catalog.PSObject.Properties["semanticTargeting"]
        if ($semanticCatalogProperty) {
            $semanticPath = ([string]$semanticCatalogProperty.Value.path).Replace('\', '/')
            $semanticAbsolutePath = Join-Path $RepositoryRoot $semanticPath.Replace('/', '\')
            if ((Test-Path -LiteralPath $semanticAbsolutePath -PathType Leaf) -and
                ($semanticPath -in @($selection.paths | ForEach-Object { ([string]$_).Replace('\', '/') }) -or @($selection.semanticImpacts).Count -gt 0) -and
                $semanticPath -notin $selectionAdditionalInputs) {
                throw "Targeted semantic selection must include the complete entrypoint in additionalInputs: $semanticPath"
            }
            $libraries = $semanticCatalogProperty.Value.PSObject.Properties['libraries']
            if ($libraries) {
                foreach ($libraryPath in @($libraries.Value.PSObject.Properties | ForEach-Object { [string]$_.Name })) {
                    if (($libraryPath -in @($selection.paths) -or $libraryPath -in @($selection.semanticImpacts | ForEach-Object { [string]$_.owner })) -and
                        (Test-Path -LiteralPath (Join-Path $RepositoryRoot $libraryPath) -PathType Leaf) -and
                        $libraryPath -notin $selectionAdditionalInputs) {
                        throw "Targeted semantic selection must include the complete library in additionalInputs: $libraryPath. Regenerate the selection with resolve-targeted-tests.ps1."
                    }
                }
            }
        }
    } elseif ($schemaProperty -and [int]$schemaProperty.Value -ne 1) {
        throw "Unsupported Pester selection schemaVersion: $($schemaProperty.Value)."
    }
    $testFiles = @($selection.tests | ForEach-Object {
        $resolved = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot ([string]$_).Replace('/','\')))
        if (-not $resolved.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase) -or $resolved -notlike "*.Tests.ps1" -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Selected Pester path is missing or outside tests/pester: $_" }
        Get-Item -LiteralPath $resolved
    } | Sort-Object Name -Unique)
} else { $testFiles = @(Get-ChildItem -LiteralPath $testRoot -File -Filter "*.Tests.ps1" | Sort-Object Name) }
if ($testFiles.Count -eq 0) { throw "No Pester test files were discovered." }
if (@($testFiles | Where-Object Name -eq "BootstrapUpdate.Tests.ps1").Count -gt 0) {
    Initialize-VanessaSourceBuildArchiveForPester -ReadOnly:$PlanOnly
}
# CompactItlRunner sends a real console Ctrl+C to process-group zero, which
# broadcasts within its attached console. Keep it out of the parallel set.
# DevelopManifestContinuation uses private Temp/Git fixtures and no console
# interruption. Keep actual console/global boundaries in the serial cohort.
$serialTestNames = @("CompactItlRunner.Tests.ps1", "DependencyLocks.Tests.ps1", "ReleaseGate.Tests.ps1", "ReleaseOrchestration.Tests.ps1", "E2EClientSelection.Tests.ps1", "ReleaseSnapshotContinuation.Tests.ps1", "ReleaseAdmission.Tests.ps1")
# These existing short owner checks finish before costly native files start.
# Keep this scheduling policy beside serial admission; cached files stay reused.
$preflightTestNames = @("SourceDeliveryAdmission.Tests.ps1", "ReleaseRouting.Tests.ps1")
$weights = @{}
foreach ($property in $timings.files.PSObject.Properties) { $weights[$property.Name] = [double]$property.Value }
$defaultSeconds = [double]$timings.defaultSeconds

$items = @($testFiles | ForEach-Object {
    [pscustomobject]@{
        name = $_.Name
        path = $_.FullName
        weight = $(if ($weights.ContainsKey($_.Name)) { [double]$weights[$_.Name] } else { $defaultSeconds })
        serial = $serialTestNames -contains $_.Name
        preflight = $preflightTestNames -contains $_.Name
    }
} | Sort-Object @{ Expression = "serial"; Descending = $false }, @{ Expression = "preflight"; Descending = $true }, @{ Expression = "weight"; Descending = $true }, @{ Expression = "name"; Descending = $false })

$workerScript = Join-Path $PSScriptRoot "run-pester-shard.ps1"
$script:pesterRuntimeReceipt = Get-PesterWorkerRuntimeReceipt
$script:pesterExternalSpecPath=''
$script:pesterExternalRuntimeReceipt=Get-PesterExternalWorkerReceipt
$entries = New-Object System.Collections.Generic.List[object]
$pendingParallel = New-Object System.Collections.Generic.Queue[object]
$pendingSerial = New-Object System.Collections.Generic.Queue[object]
$results = @()
$preview = New-Object System.Collections.Generic.List[object]
$previewChangedPaths=@()
if($PlanOnly -and $BaseRef) {$previewChangedPaths=@(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @("diff","--name-only","-z",$BaseRef,"HEAD","--"))}
$failures = @()
$index = 0
Initialize-PesterTrackedIdentityCache
$fingerprintPlanStopwatch = [Diagnostics.Stopwatch]::StartNew()
if ($InputIdentityOnly) {
    $inputEntries = @($items | ForEach-Object {
        [pscustomobject]@{paths=@([string]$_.path); inputDigest=(Get-ShardInputDigest -Paths @([string]$_.path) -AdditionalInputs $selectionAdditionalInputs)}
    })
    $identity = New-PesterInputIdentity -RepositoryRoot $RepositoryRoot -Entries $inputEntries -RuntimeReceipt $script:pesterRuntimeReceipt
    $fingerprintPlanStopwatch.Stop()
    $identity | Add-Member -NotePropertyName durationMs -NotePropertyValue ([int64]$fingerprintPlanStopwatch.ElapsedMilliseconds + [int64]$script:pesterRuntimeReceipt.durationMs)
    [IO.File]::WriteAllText((Join-Path $workerRoot 'input-identity.json'), (($identity | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $identity | ConvertTo-Json -Depth 8
    return
}
foreach ($item in $items) {
    $index++
    $planPath = Join-Path $workerRoot ("worker-{0}.plan.json" -f $index)
    $resultPath = Join-Path $workerRoot ("worker-{0}.result.json" -f $index)
    $workerJunit = Join-Path $workerRoot ("worker-{0}.xml" -f $index)
    $stdoutPath = Join-Path $workerRoot ("worker-{0}.stdout.log" -f $index)
    $stderrPath = Join-Path $workerRoot ("worker-{0}.stderr.log" -f $index)
    $stdinPath = Join-Path $workerRoot ("worker-{0}.stdin.txt" -f $index)
    $preparedInputs = $null
    $digest = Get-ShardInputDigest -Paths @([string]$item.path) -AdditionalInputs $selectionAdditionalInputs -PreparedInputs ([ref]$preparedInputs)
    $legacyDigests = New-Object System.Collections.Generic.List[string]
    if (-not $PlanOnly -and (Test-Path -LiteralPath $planPath -PathType Leaf) -and (Test-Path -LiteralPath $resultPath -PathType Leaf) -and (Test-Path -LiteralPath $workerJunit -PathType Leaf)) {
        try {
            $priorPlan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $priorResult = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$priorPlan.inputDigest -eq $digest -and @($priorPlan.paths).Count -eq 1 -and [string]$priorPlan.paths[0] -eq [string]$item.path -and
                [string]$priorResult.status -eq "passed" -and [int]$priorResult.failed -eq 0 -and
                (Test-ShardResultTestPath -Result $priorResult -TestPath ([string]$item.path))) {
                $priorResult | Add-Member -NotePropertyName execution -NotePropertyValue "executed" -Force
                $priorResult | Add-Member -NotePropertyName inputDigest -NotePropertyValue $digest -Force
                $priorResult | Add-Member -NotePropertyName worker -NotePropertyValue $index -Force
                $priorResult.paths = @([string]$item.path)
                [IO.File]::WriteAllText($resultPath, (($priorResult | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
                Save-ShardCache -Digest $digest -ResultPath $resultPath -JunitPath $workerJunit
            }
        } catch {}
    }
    if (-not $PlanOnly) {
        Remove-Item -LiteralPath $resultPath, $workerJunit, $stdoutPath, $stderrPath, $stdinPath -Force -ErrorAction SilentlyContinue
        [System.IO.File]::WriteAllText($stdinPath, "", [System.Text.UTF8Encoding]::new($false))
    }

    $lookupStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $cached = Restore-ShardCache -Digest $digest -ResultPath $resultPath -JunitPath $workerJunit -Worker $index -TestPath ([string]$item.path) -ReadOnly:$PlanOnly
    $lookupStopwatch.Stop()
    $script:pesterCacheLookupMs += [int64]$lookupStopwatch.ElapsedMilliseconds
    $reuseReason = "exact owner input fingerprint"
    if (-not $cached) {
        foreach ($legacyWorkerCount in 1..4) {
            $priorWorkerDigest = Get-ShardInputDigest -Paths @([string]$item.path) -AdditionalInputs $selectionAdditionalInputs -LegacyWorkerCount $legacyWorkerCount -PreparedInputs ([ref]$preparedInputs)
            if ($priorWorkerDigest) { $legacyDigests.Add($priorWorkerDigest) | Out-Null }
        }
        # Legacy global receipts were written only under the former 1..4
        # worker ceiling; a larger run has no such key to look up.
        if ($WorkerCount -le 4) {
        $priorGlobalDigest = Get-ShardInputDigest -Paths @([string]$item.path) -AdditionalInputs $selectionAdditionalInputs -IncludeLegacyGlobalExternalInputs -LegacyWorkerCount $WorkerCount -PreparedInputs ([ref]$preparedInputs)
        if ($priorGlobalDigest -and $priorGlobalDigest -ne $digest) { $legacyDigests.Add($priorGlobalDigest) | Out-Null }
        $relativeItemPath = [string]$item.path.Substring($RepositoryRoot.TrimEnd('\').Length).TrimStart('\').Replace('\','/')
        $requiredExternalInputs = $(if ($pesterExternalInputsByTest.ContainsKey($relativeItemPath)) { @($pesterExternalInputsByTest[$relativeItemPath]) } else { @() })
        if ("ITL_AI_RULES_SOURCE_PATH" -notin $requiredExternalInputs) {
            $priorUnsetAiRulesDigest = Get-ShardInputDigest -Paths @([string]$item.path) -AdditionalInputs $selectionAdditionalInputs -IncludeLegacyGlobalExternalInputs -LegacyWorkerCount $WorkerCount -PreparedInputs ([ref]$preparedInputs) -ExternalIdentityOverrides @{
                ITL_AI_RULES_SOURCE_PATH = "env:ITL_AI_RULES_SOURCE_PATH=<unset>"
            }
            if ($priorUnsetAiRulesDigest -and $priorUnsetAiRulesDigest -ne $digest -and -not $legacyDigests.Contains($priorUnsetAiRulesDigest)) { $legacyDigests.Add($priorUnsetAiRulesDigest) | Out-Null }
        }
        if ("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE" -notin $requiredExternalInputs) {
            $priorUnsetExternalDigest = Get-ShardInputDigest -Paths @([string]$item.path) -AdditionalInputs $selectionAdditionalInputs -IncludeLegacyGlobalExternalInputs -LegacyWorkerCount $WorkerCount -PreparedInputs ([ref]$preparedInputs) -ExternalIdentityOverrides @{
                ITL_AI_RULES_SOURCE_PATH = $(if ("ITL_AI_RULES_SOURCE_PATH" -in $requiredExternalInputs) { Get-ExternalInputIdentity -Name "ITL_AI_RULES_SOURCE_PATH" } else { "env:ITL_AI_RULES_SOURCE_PATH=<unset>" })
                ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = "env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE=<unset>"
            }
            if ($priorUnsetExternalDigest -and $priorUnsetExternalDigest -ne $digest -and -not $legacyDigests.Contains($priorUnsetExternalDigest)) { $legacyDigests.Add($priorUnsetExternalDigest) | Out-Null }
        }
        if ($script:pesterVanessaArchiveCandidates.Count -gt 0) {
            $legacyAiRulesIdentity = Get-LegacyExternalInputIdentity -Name "ITL_AI_RULES_SOURCE_PATH" -Value ([Environment]::GetEnvironmentVariable("ITL_AI_RULES_SOURCE_PATH", "Process"))
            foreach ($archiveCandidate in $script:pesterVanessaArchiveCandidates) {
                $overrides = @{
                    ITL_AI_RULES_SOURCE_PATH = $legacyAiRulesIdentity
                    ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = (Get-LegacyExternalInputIdentity -Name "ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE" -Value ([string]$archiveCandidate))
                }
                $legacyDigest = Get-ShardInputDigest -Paths @([string]$item.path) -AdditionalInputs $selectionAdditionalInputs -ExternalIdentityOverrides $overrides -IncludeLegacyGlobalExternalInputs -LegacyWorkerCount $WorkerCount -PreparedInputs ([ref]$preparedInputs)
                if ($legacyDigest -and $legacyDigest -ne $digest -and -not $legacyDigests.Contains($legacyDigest)) { $legacyDigests.Add($legacyDigest) | Out-Null }
            }
        }
        }
        $script:pesterLegacyDigestCount += $legacyDigests.Count
        foreach ($legacyDigest in $legacyDigests) {
            $lookupStopwatch.Restart()
            $cached = Restore-ShardCache -Digest $legacyDigest -ResultPath $resultPath -JunitPath $workerJunit -Worker $index -TestPath ([string]$item.path) -ReadOnly:$PlanOnly
            $lookupStopwatch.Stop()
            $script:pesterCacheLookupMs += [int64]$lookupStopwatch.ElapsedMilliseconds
            if (-not $cached) { continue }
            $cached | Add-Member -NotePropertyName inputDigest -NotePropertyValue $digest -Force
            if (-not $PlanOnly) {
                [IO.File]::WriteAllText($resultPath, (($cached | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
                Save-ShardCache -Digest $digest -ResultPath $resultPath -JunitPath $workerJunit
            }
            $reuseReason = "legacy scheduler or external identity normalized to exact owner inputs"
            break
        }
    }
    $relativeItemPath = Get-ShardRelativeTestPath -Path ([string]$item.path)
    $nonReusable = $catalog.PSObject.Properties['pesterNonReusableTests']
    $changedInputs=@($previewChangedPaths | Where-Object {$preparedInputs -and $preparedInputs.paths -contains $_})
    $unknownExternal=@(foreach($profile in @(Get-ShardExternalProfiles @([string]$item.path))){
        $witness=$script:pesterExternalRuntimeReceipt.PSObject.Properties[$profile]
        if(-not $witness){$profile+': identity unavailable'}elseif($witness.Value.status -ne 'known'){$profile+': '+$witness.Value.reason}
    })
    $repeatReason = if ($cached) { $reuseReason } elseif ($nonReusable -and $relativeItemPath -in @($nonReusable.Value)) {
        'unqualified external runtime; mandatory native boundary'
    } elseif ($unknownExternal.Count) { 'unqualified external runtime: '+($unknownExternal -join '; ') }
    elseif ($script:pesterRuntimeReceipt.status -ne 'known') { 'unknown child runtime identity' }
    elseif (-not $digest) { 'incomplete owner inputs' }
    elseif($changedInputs.Count) {'changed owner inputs; exact passed proof unavailable'} else { 'no valid passed proof for exact owner inputs and runtime' }
    $preview.Add([pscustomobject]@{path=$relativeItemPath;execution=$(if($cached){'reuse'}else{'execute'});reason=$repeatReason;
        inputDigest=$digest;proofSource=$(if($cached){[string]$cached.proofSource}else{''});changedInputs=$changedInputs;estimatedSeconds=$(if($cached){0.0}else{[double]$item.weight});serial=[bool]$item.serial;preflight=[bool]$item.preflight})
    if ($PlanOnly) { continue }
    $externalProfiles=@(Get-ShardExternalProfiles @([string]$item.path))
    $payload = [ordered]@{
        schemaVersion = 1
        worker = $index
        repeatReason = $repeatReason
        estimatedSeconds = [double]$item.weight
        inputDigest = $digest
        legacyInputDigests = @($legacyDigests)
        legacyArchiveCandidates = @($script:pesterVanessaArchiveCandidates)
        runtimeIdentity = $script:pesterRuntimeReceipt.identity
        paths = @([string]$item.path)
    }
    [System.IO.File]::WriteAllText($planPath, (($payload | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    if ($cached) { $cached | Add-Member -NotePropertyName reuseReason -NotePropertyValue $reuseReason -Force }
    $externalPath=''
    if($externalProfiles.Count){
        $externalPath=Join-Path $workerRoot ('worker-'+$index+'.external.json')
        $profiles=[ordered]@{}
        foreach($name in $externalProfiles){
            $definitions=$catalog.PSObject.Properties['pesterExternalRuntimeProfiles']
            $definition=if($definitions){$definitions.Value.PSObject.Properties[$name]}else{$null}
            $profiles[$name]=if($definition){$definition.Value}else{[pscustomobject]@{kind='unknown'}}
        }
        [IO.File]::WriteAllText($externalPath,([ordered]@{repositoryRoot=$RepositoryRoot;profiles=[pscustomobject]$profiles}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    }
    $entry = [pscustomobject]@{
        externalPath=$externalPath
        worker = $index; serial = [bool]$item.serial; preflight = [bool]$item.preflight; process = $null; reused = [bool]$cached; digest = $digest
        testPath = [string]$item.path
        planPath = $planPath; resultPath = $resultPath; junitPath = $workerJunit; stdoutPath = $stdoutPath; stderrPath = $stderrPath; stdinPath = $stdinPath
    }
    $entries.Add($entry) | Out-Null
    if ($cached) {
        $results += $cached
    } else {
        if ([bool]$entry.serial) { $pendingSerial.Enqueue($entry) } else { $pendingParallel.Enqueue($entry) }
    }
}
$fingerprintPlanStopwatch.Stop()
if ($PlanOnly) {
    [pscustomobject]@{schemaVersion=1;kind='itl-pester-reuse-plan';workerCount=$WorkerCount;
        admission=[pscustomobject]@{state=$(if($initialMemoryLimit -eq 0 -and @($preview | Where-Object execution -eq execute).Count -gt 0){'waiting-for-host-memory'}else{'ready'});initialWorkerLimit=$initialMemoryLimit};
        estimatedSeconds=(Get-PesterWorkloadEstimate -Files @($preview.ToArray()) -WorkerCount $WorkerCount);
        executedCount=@($preview | Where-Object execution -eq execute).Count;reusedCount=@($preview | Where-Object execution -eq reuse).Count;
        runtimeIdentityStatus=$script:pesterRuntimeReceipt.status;files=@($preview.ToArray());
        durationMs=([int64]$fingerprintPlanStopwatch.ElapsedMilliseconds + [int64]$script:pesterRuntimeReceipt.durationMs)} | ConvertTo-Json -Depth 8
    return
}

function Start-PesterFileEntry {
    param([Parameter(Mandatory = $true)][object]$Entry)
    $selectedWorker=if($Entry.externalPath){Join-Path $PSScriptRoot 'run-pester-external-shard.ps1'}else{$workerScript}
    $args = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-NativeArgument $selectedWorker), "-PlanPath", (ConvertTo-NativeArgument $Entry.planPath), "-JunitPath", (ConvertTo-NativeArgument $Entry.junitPath), "-ResultPath", (ConvertTo-NativeArgument $Entry.resultPath))
    if($Entry.externalPath){$args+=@('-ProfilePath',(ConvertTo-NativeArgument $Entry.externalPath))}
    $relativePath = Get-ShardRelativeTestPath -Path $Entry.testPath
    $externalInputs = @(if ($pesterExternalInputsByTest.ContainsKey($relativePath)) { $pesterExternalInputsByTest[$relativePath] })
    $Entry.process = Start-PesterWorkerProcess -Arguments $args -StdinPath $Entry.stdinPath -StdoutPath $Entry.stdoutPath -StderrPath $Entry.stderrPath -ExternalInputNames $externalInputs
    $null = $Entry.process.Handle
}

function Complete-PesterFileEntry {
    param([Parameter(Mandatory = $true)][object]$Entry)
    $Entry.process.WaitForExit(); $Entry.process.Refresh()
    if (Test-Path -LiteralPath $Entry.resultPath -PathType Leaf) {
        $workerResult = Get-Content -LiteralPath $Entry.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $plan = Get-Content -LiteralPath $Entry.planPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@($plan.paths).Count -ne 1 -or -not (Test-ShardResultTestPath -Result $workerResult -TestPath ([string]$plan.paths[0]))) {
            $script:failures += "worker $($Entry.worker) result does not match its planned test path"
            return $false
        }
        $workerResult | Add-Member -NotePropertyName execution -NotePropertyValue "executed" -Force
        $workerResult | Add-Member -NotePropertyName repeatReason -NotePropertyValue ([string]$plan.repeatReason) -Force
        if ($Entry.digest -and -not (Test-PesterShardResultRuntime -Result $workerResult)) {
            $Entry.digest = ''
            $workerResult | Add-Member -NotePropertyName reuseReason -NotePropertyValue 'Actual worker runtime or external inputs differ from the qualified probe or changed during execution; result is not reusable.' -Force
        }
        $workerResult | Add-Member -NotePropertyName inputDigest -NotePropertyValue ([string]$Entry.digest) -Force
        [IO.File]::WriteAllText($Entry.resultPath, (($workerResult | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $script:results += $workerResult
        if ([string]$workerResult.status -eq "passed" -and [int]$Entry.process.ExitCode -eq 0) {
            Save-ShardCache -Digest $Entry.digest -ResultPath $Entry.resultPath -JunitPath $Entry.junitPath
            if ($Entry.digest -and -not (Get-ShardCacheEntryRoot -Digest ([string]$Entry.digest) -TestPath ([string]$plan.paths[0]))) {
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
$peakActiveWorkerCount = 0
$stopScheduling = $false
$nextHeartbeat = [DateTime]::UtcNow.AddSeconds(15)
$workerSpanStopwatch = [Diagnostics.Stopwatch]::StartNew()
while ($active.Count -gt 0 -or (-not $stopScheduling -and $pendingParallel.Count -gt 0)) {
    while (-not $stopScheduling -and $pendingParallel.Count -gt 0 -and $active.Count -lt $WorkerCount) {
        if ($active.Count -gt 0 -and $active[0].preflight -and -not $pendingParallel.Peek().preflight) { break }
        if ($memoryAdmissionEnabled) {
            $admitted = Get-PesterCurrentMemoryWorkerLimit -ActiveWorkers $active.Count
            if ($active.Count -ge $admitted) { $memoryAdmissionReductions++; break }
        }
        $next = $pendingParallel.Dequeue()
        Start-PesterFileEntry -Entry $next
        $active.Add($next) | Out-Null
        $peakActiveWorkerCount = [math]::Max($peakActiveWorkerCount, $active.Count)
    }
    if ($active.Count -eq 0) {
        if (-not $stopScheduling -and $pendingParallel.Count -gt 0) {
            if ([DateTime]::UtcNow -ge $nextHeartbeat) {
                Write-Host "Pester admission waiting for host physical/commit memory; pending=$($pendingParallel.Count). Existing gate deadline and checkpoint remain in force."
                $nextHeartbeat = [DateTime]::UtcNow.AddSeconds(15)
            }
            Start-Sleep -Milliseconds 200
            continue
        }
        break
    }
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
    if ($memoryAdmissionEnabled -and (Get-PesterCurrentMemoryWorkerLimit) -eq 0) {
        $memoryAdmissionReductions++
        if ([DateTime]::UtcNow -ge $nextHeartbeat) {
            Write-Host "Pester serial admission waiting for host physical/commit memory; pending=$($pendingSerial.Count). Existing gate deadline and checkpoint remain in force."
            $nextHeartbeat = [DateTime]::UtcNow.AddSeconds(15)
        }
        Start-Sleep -Milliseconds 200
        continue
    }
    $entry = $pendingSerial.Dequeue()
    Start-PesterFileEntry -Entry $entry
    $peakActiveWorkerCount = [math]::Max($peakActiveWorkerCount, 1)
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
$workerSpanStopwatch.Stop()

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
    memoryAdmissionReductions = $memoryAdmissionReductions
    peakActiveWorkers = $peakActiveWorkerCount
    initialMemoryLimit = $initialMemoryLimit
    status = $(if ($failures.Count -eq 0 -and $failed -eq 0 -and $errors -eq 0) { "passed" } else { "failed" })
    workerCount = $results.Count
    pesterWorkers = [ordered]@{
        requested = [int]$reportedRequestedWorkerCount
        explicit = ([bool]$workerCountParameterExplicit -and -not [bool]$WorkerCountDefaulted)
        effective = $(if ($memoryAdmissionEnabled) { [int][math]::Max(1, [math]::Max($initialMemoryLimit, $peakActiveWorkerCount)) } else { [int]$WorkerCount })
    }
    executedWorkerCount = @($entries | Where-Object { -not $_.reused -and $_.process }).Count
    reusedWorkerCount = @($entries | Where-Object { $_.reused }).Count
    fingerprintPlanMs = [int64]$fingerprintPlanStopwatch.ElapsedMilliseconds
    cacheLookupMs = [int64]$script:pesterCacheLookupMs
    workerSpanMs = [int64]$workerSpanStopwatch.ElapsedMilliseconds
    identityInventoryMs = [int64]$script:pesterIdentityInventoryMs
    runtimeProbeMs = [int64]$script:pesterRuntimeReceipt.durationMs
    runtimeIdentityStatus = [string]$script:pesterRuntimeReceipt.status
    runtimeIdentityReason = [string]$script:pesterRuntimeReceipt.reason
    runtimeIdentity = $script:pesterRuntimeReceipt.identity
    inputIdentity = New-PesterInputIdentity -RepositoryRoot $RepositoryRoot -Entries @($results) -RuntimeReceipt $script:pesterRuntimeReceipt
    legacyDigestCount = [int]$script:pesterLegacyDigestCount
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
