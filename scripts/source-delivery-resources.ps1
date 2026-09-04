Set-StrictMode -Version Latest

function Get-DeliveryResourceLedgerPath {
    $root = Join-Path (Get-DeliveryCommonGitDirectory) "itl\resources\v1"
    return Join-Path $root "ledger.json"
}

function Read-DeliveryResourceLedger {
    $path = Get-DeliveryResourceLedgerPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ schemaVersion=1; resources=@(); updatedAt=[DateTime]::UtcNow.ToString("o") }
    }
    try {
        $ledger = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$ledger.schemaVersion -ne 1) { throw "unsupported schema" }
        return $ledger
    } catch { throw "DELIVERY_RESOURCE_LEDGER_CORRUPT: $path. $($_.Exception.Message)" }
}

function Write-DeliveryResourceLedger {
    param([Parameter(Mandatory = $true)][object]$Ledger)
    $path = Get-DeliveryResourceLedgerPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $Ledger.updatedAt = [DateTime]::UtcNow.ToString("o")
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (($Ledger | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $path -Force
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    return $path
}

function Register-DeliveryResource {
    param(
        [Parameter(Mandatory = $true)][string]$PlanId,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][object]$Identity,
        [ValidateSet("active", "retained", "cleanup-pending", "removed")][string]$State = "active",
        [datetime]$RetainUntil = ([DateTime]::UtcNow.AddDays(7))
    )
    $identitySha = Get-DeliveryCanonicalJsonSha256 -Value $Identity
    $resourceId = Get-DeliveryTextSha256 -Text "$PlanId|$Kind|$Owner|$identitySha"
    $ledger = Read-DeliveryResourceLedger
    $resources = @($ledger.resources)
    $existing = $resources | Where-Object { [string]$_.resourceId -eq $resourceId } | Select-Object -First 1
    if ($existing) {
        $existing.state = $State
        $existing.retainUntil = $RetainUntil.ToUniversalTime().ToString("o")
        $existing.updatedAt = [DateTime]::UtcNow.ToString("o")
    } else {
        $resources += [pscustomobject][ordered]@{
            resourceId=$resourceId; planId=$PlanId; kind=$Kind; owner=$Owner; identity=$Identity; identitySha256=$identitySha
            state=$State; createdAt=[DateTime]::UtcNow.ToString("o"); updatedAt=[DateTime]::UtcNow.ToString("o")
            retainUntil=$RetainUntil.ToUniversalTime().ToString("o"); cleanupAttempts=0; lastAttemptAt=""; lastError=""
        }
    }
    $ledger.resources = @($resources)
    [void](Write-DeliveryResourceLedger -Ledger $ledger)
    return $resourceId
}

function Set-DeliveryResourceState {
    param([Parameter(Mandatory = $true)][string]$ResourceId, [Parameter(Mandatory = $true)][ValidateSet("active", "retained", "cleanup-pending", "removed")][string]$State, [string]$ErrorMessage = "")
    $ledger = Read-DeliveryResourceLedger
    $record = @($ledger.resources | Where-Object { [string]$_.resourceId -eq $ResourceId } | Select-Object -First 1)
    if ($record.Count -eq 0) { return $false }
    $record[0].state = $State
    $record[0].updatedAt = [DateTime]::UtcNow.ToString("o")
    if ($State -eq "cleanup-pending") {
        $record[0].cleanupAttempts = [int]$record[0].cleanupAttempts + 1
        $record[0].lastAttemptAt = [DateTime]::UtcNow.ToString("o")
        $record[0].lastError = $ErrorMessage
    } elseif ($State -eq "removed") { $record[0].lastError = "" }
    [void](Write-DeliveryResourceLedger -Ledger $ledger)
    return $true
}

function Update-DeliveryFailedPlanRetention {
    $ledger = Read-DeliveryResourceLedger
    $now = [DateTime]::UtcNow
    $retainedPlans = @($ledger.resources | Where-Object { [string]$_.state -eq "retained" } | Group-Object planId | ForEach-Object {
        $latest = @($_.Group | Sort-Object { [DateTime]::Parse([string]$_.updatedAt) } -Descending | Select-Object -First 1)[0]
        [pscustomobject]@{ planId=$_.Name; updatedAt=[DateTime]::Parse([string]$latest.updatedAt) }
    } | Sort-Object updatedAt -Descending)
    $keepPlans = @($retainedPlans | Select-Object -First 2 | ForEach-Object { [string]$_.planId })
    $changed = $false
    foreach ($resource in @($ledger.resources | Where-Object { [string]$_.state -eq "retained" })) {
        $expired = [DateTime]::Parse([string]$resource.retainUntil).ToUniversalTime() -le $now
        if ($expired -or [string]$resource.planId -notin $keepPlans) {
            $resource.state = "cleanup-pending"; $resource.updatedAt = $now.ToString("o"); $changed = $true
        }
    }
    if ($changed) { [void](Write-DeliveryResourceLedger -Ledger $ledger) }
}

function Get-DeliveryResourceLedgerSummary {
    $ledger = Read-DeliveryResourceLedger
    $pending = @($ledger.resources | Where-Object { [string]$_.state -in @("cleanup-pending", "retained") })
    $bytes = [int64]0
    foreach ($resource in $pending) {
        $pathProperty = $resource.identity.PSObject.Properties["path"]
        if (-not $pathProperty -or -not [string]$pathProperty.Value) { continue }
        $path = [string]$pathProperty.Value
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) { $bytes += [int64](Get-Item -LiteralPath $path).Length }
            elseif (Test-Path -LiteralPath $path -PathType Container) { $bytes += [int64]((Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction Stop | Measure-Object Length -Sum).Sum) }
        } catch {}
    }
    $oldest = @($pending | Sort-Object createdAt | Select-Object -First 1)
    $oldestAgeSeconds = if ($oldest.Count) {
        [int64][Math]::Max(0, ([DateTime]::UtcNow - [DateTime]::Parse([string]$oldest[0].createdAt).ToUniversalTime()).TotalSeconds)
    } else { 0 }
    return [pscustomobject][ordered]@{
        path=(Get-DeliveryResourceLedgerPath); total=@($ledger.resources).Count
        pending=@($pending | Where-Object state -eq "cleanup-pending").Count; retained=@($pending | Where-Object state -eq "retained").Count
        bytes=$bytes; oldestAt=$(if($oldest.Count){[string]$oldest[0].createdAt}else{""}); oldestAgeSeconds=$oldestAgeSeconds
        nextAttempt="next PublishDevelop, PromoteRelease, ReleaseMaster, or Cleanup"
        entries=@($pending | ForEach-Object { [pscustomobject]@{ resourceId=$_.resourceId; planId=$_.planId; kind=$_.kind; owner=$_.owner; state=$_.state; retainUntil=$_.retainUntil; cleanupAttempts=$_.cleanupAttempts; lastError=$_.lastError; identity=$_.identity } })
    }
}

function Test-DeliveryResourcePathWithinRoot {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $resolvedPath.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DeliveryResourceWorktreeMayBeCleaned {
    param([Parameter(Mandatory = $true)][string]$WorktreePath)
    if (-not (Test-Path -LiteralPath $WorktreePath -PathType Container)) { throw "resource worktree is missing: $WorktreePath" }
    if (Test-SourceDeliveryPathInUse -Path $WorktreePath) { throw "resource worktree is used by an active process: $WorktreePath" }
    $status = Invoke-RepositoryGit -RepositoryRoot $WorktreePath -Arguments @('status', '--porcelain', '--untracked-files=no') -AllowFailure
    if ($status.exitCode -ne 0 -or [string]$status.stdout) { throw "resource worktree has tracked drift: $WorktreePath" }
}

function Remove-DeliveryPendingLedgerResource {
    param([Parameter(Mandatory = $true)][object]$Resource)
    $identity = $Resource.identity
    switch ([string]$Resource.kind) {
        "release-snapshot" {
            $path = [IO.Path]::GetFullPath([string]$identity.path)
            $worktreePath = [IO.Path]::GetFullPath([string]$identity.worktreePath)
            $snapshotRoot = Join-Path $worktreePath '.agent-1c\snapshots'
            if (-not (Test-DeliveryResourcePathWithinRoot -Path $path -Root $snapshotRoot) -or (Split-Path -Leaf $path) -notmatch '^(release-e2e-|extension-init-).+\.dt$') {
                throw "snapshot path is outside the owned Release snapshot root: $path"
            }
            Assert-DeliveryResourceWorktreeMayBeCleaned -WorktreePath $worktreePath
            if ((Get-DeliveryFileSha256 -Path $path) -ne ([string]$identity.sha256).ToLowerInvariant()) { throw "snapshot SHA differs from the ledger: $path" }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            return $true
        }
        "release-artifact" {
            $path = [IO.Path]::GetFullPath([string]$identity.path)
            $manifestPath = [IO.Path]::GetFullPath([string]$identity.manifestPath)
            $worktreePath = [IO.Path]::GetFullPath([string]$identity.worktreePath)
            Assert-DeliveryResourceWorktreeMayBeCleaned -WorktreePath $worktreePath
            $project = Get-Content -LiteralPath (Join-Path $worktreePath '.agent-1c\project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $artifactsPath = if ($project.PSObject.Properties['artifactsPath'] -and [string]$project.artifactsPath) { [string]$project.artifactsPath } else { 'build/result' }
            $artifactRoot = if ([IO.Path]::IsPathRooted($artifactsPath)) { [IO.Path]::GetFullPath($artifactsPath) } else { [IO.Path]::GetFullPath((Join-Path $worktreePath $artifactsPath)) }
            if (-not (Test-DeliveryResourcePathWithinRoot -Path $path -Root $artifactRoot) -or -not (Test-DeliveryResourcePathWithinRoot -Path $manifestPath -Root $artifactRoot)) { throw "artifact or manifest is outside configured artifactsPath" }
            if ((Get-DeliveryFileSha256 -Path $manifestPath) -ne ([string]$identity.manifestSha256).ToLowerInvariant()) { throw "artifact manifest SHA differs from the ledger: $manifestPath" }
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $artifactSha = Get-DeliveryFileSha256 -Path $path
            if ($artifactSha -ne ([string]$identity.sha256).ToLowerInvariant() -or $artifactSha -ne ([string]$manifest.artifact.sha256).ToLowerInvariant()) { throw "artifact SHA differs from manifest or ledger: $path" }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            Remove-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
            return $true
        }
        "capability-generation" {
            $path = [IO.Path]::GetFullPath([string]$identity.path)
            $manifestPath = [IO.Path]::GetFullPath([string]$identity.manifestPath)
            $worktreePath = [IO.Path]::GetFullPath([string]$identity.worktreePath)
            Assert-DeliveryResourceWorktreeMayBeCleaned -WorktreePath $worktreePath
            $cacheRoot = Join-Path $worktreePath '.agent-1c\release-capability-cache'
            if (-not (Test-DeliveryResourcePathWithinRoot -Path $path -Root $cacheRoot) -or -not (Test-DeliveryResourcePathWithinRoot -Path $manifestPath -Root $path)) { throw "capability generation is outside the owned cache root" }
            if ((Get-DeliveryFileSha256 -Path $manifestPath) -ne ([string]$identity.manifestSha256).ToLowerInvariant()) { throw "capability manifest SHA differs from the ledger: $manifestPath" }
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            return $true
        }
        "owned-process-port" {
            $pidValue = [int]$identity.pid
            if ($pidValue -gt 0 -and (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) { throw "owned process PID $pidValue is still active" }
            $listeners = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners())
            foreach ($portProperty in @('port', 'testClientPort')) {
                $property = $identity.PSObject.Properties[$portProperty]
                $port = if ($property) { [int]$property.Value } else { 0 }
                if ($port -gt 0 -and @($listeners | Where-Object Port -eq $port).Count -gt 0) { throw "owned port $port is still active" }
            }
            return $true
        }
    }
    return $false
}

function Register-DeliveryGateResources {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][ValidateSet("Develop", "Release")][string]$Mode,
        [switch]$Failed
    )
    $checkSummaryPath = Join-Path $CandidateRoot "build\test-results\local\check-summary.json"
    if (-not (Test-Path -LiteralPath $checkSummaryPath -PathType Leaf)) { return @() }
    try { $checkSummary = Get-Content -LiteralPath $checkSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    if (-not [string]$checkSummary.e2eReportPath -or -not (Test-Path -LiteralPath ([string]$checkSummary.e2eReportPath) -PathType Leaf)) { return @() }
    try { $report = Get-Content -LiteralPath ([string]$checkSummary.e2eReportPath) -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    $registered = [Collections.Generic.List[string]]::new()
    $planId = [string]$Plan.planId
    $state = if ($Failed -or [string]$report.status -ne "passed") { "retained" } else { "active" }

    if ([string]$report.projectRoot) {
        $id = Register-DeliveryResource -PlanId $planId -Kind "reusable-stand" -Owner "$Mode-e2e" -Identity ([ordered]@{ path=[IO.Path]::GetFullPath([string]$report.projectRoot); configured=$true }) -State active -RetainUntil ([DateTime]::MaxValue)
        $registered.Add($id) | Out-Null
    }
    if ($Mode -eq "Develop" -and [string]$report.freshProjectRoot) {
        $freshPath = [IO.Path]::GetFullPath([string]$report.freshProjectRoot)
        $branchPath = if ([string]$report.freshBranchRoot) { [IO.Path]::GetFullPath([string]$report.freshBranchRoot) } else { "$freshPath-develop-golden" }
        $freshIdentity = [ordered]@{ path=$freshPath; branchPath=$branchPath; launcherSection=(Split-Path -Leaf $freshPath); launcherList=(Get-DevelopE2ELauncherListPath) }
        $id = Register-DeliveryResource -PlanId $planId -Kind "develop-fresh-project" -Owner "develop-e2e" -Identity $freshIdentity -State $state
        $registered.Add($id) | Out-Null
    }
    if ($Mode -eq "Release") {
        $retention = $report.artifactRetention
        $artifactPath = if ($retention) { [string]$retention.retainedResultArtifact } else { "" }
        $manifestPath = if ($retention) { [string]$retention.retainedResultManifest } else { "" }
        if ($artifactPath -and $manifestPath -and (Test-Path -LiteralPath $artifactPath -PathType Leaf) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $artifactSha = Get-DeliveryFileSha256 -Path $artifactPath
            if ([string]$manifest.artifact.sha256 -and $artifactSha -ne ([string]$manifest.artifact.sha256).ToLowerInvariant()) { throw "DELIVERY_RESOURCE_ARTIFACT_SHA_MISMATCH: $artifactPath" }
            $id = Register-DeliveryResource -PlanId $planId -Kind "release-artifact" -Owner "release-e2e" -Identity ([ordered]@{ path=[IO.Path]::GetFullPath($artifactPath); sha256=$artifactSha; manifestPath=[IO.Path]::GetFullPath($manifestPath); manifestSha256=(Get-DeliveryFileSha256 -Path $manifestPath); worktreePath=[IO.Path]::GetFullPath([string]$report.worktreePath) }) -State $state
            $registered.Add($id) | Out-Null
        }
        $capabilityManifest = if ($retention) { [string]$retention.retainedCapabilityManifest } else { "" }
        if ($capabilityManifest -and (Test-Path -LiteralPath $capabilityManifest -PathType Leaf)) {
            $id = Register-DeliveryResource -PlanId $planId -Kind "capability-generation" -Owner "release-e2e" -Identity ([ordered]@{ path=(Split-Path -Parent ([IO.Path]::GetFullPath($capabilityManifest))); manifestPath=[IO.Path]::GetFullPath($capabilityManifest); manifestSha256=(Get-DeliveryFileSha256 -Path $capabilityManifest); worktreePath=[IO.Path]::GetFullPath([string]$report.worktreePath) }) -State $state
            $registered.Add($id) | Out-Null
        }
        $snapshotProperties = if ($report.snapshots) { @($report.snapshots.PSObject.Properties) } else { @() }
        foreach ($snapshotProperty in $snapshotProperties) {
            if (-not [string]$snapshotProperty.Value.path) { continue }
            $snapshotPath = [IO.Path]::GetFullPath([string]$snapshotProperty.Value.path)
            $snapshotState = if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) { if($Failed){"retained"}else{"cleanup-pending"} } else { "removed" }
            $id = Register-DeliveryResource -PlanId $planId -Kind "release-snapshot" -Owner "release-e2e" -Identity ([ordered]@{ path=$snapshotPath; name=$snapshotProperty.Name; sha256=[string]$snapshotProperty.Value.sha256; worktreePath=[IO.Path]::GetFullPath([string]$report.worktreePath) }) -State $snapshotState
            $registered.Add($id) | Out-Null
        }
        if ([string]$report.onDemandMcpEvidencePath -and (Test-Path -LiteralPath ([string]$report.onDemandMcpEvidencePath) -PathType Leaf)) {
            $mcp = Get-Content -LiteralPath ([string]$report.onDemandMcpEvidencePath) -Raw -Encoding UTF8 | ConvertFrom-Json
            $familyProperties = if ($mcp.families) { @($mcp.families.PSObject.Properties) } else { @() }
            foreach ($familyProperty in $familyProperties) {
                foreach ($instance in @($familyProperty.Value.instances)) {
                    $id = Register-DeliveryResource -PlanId $planId -Kind "owned-process-port" -Owner "release-e2e.$($familyProperty.Name)" -Identity ([ordered]@{ pid=[int]$instance.pid; port=[int]$instance.port; testClientPort=$(if($instance.PSObject.Properties["testClientPort"]){[int]$instance.testClientPort}else{0}) }) -State $(if([bool]$familyProperty.Value.cleanupPassed){"removed"}else{$state})
                    $registered.Add($id) | Out-Null
                }
            }
        }
    }
    return @($registered)
}

function Invoke-DeliveryCleanupSweep {
    param([string]$FreshProjectsRoot = "C:\itlj", [string]$E2EProjectRoot = "", [string]$Phase = "manual")
    $staleActiveLedger = Read-DeliveryResourceLedger
    $staleActiveChanged = $false
    foreach ($resource in @($staleActiveLedger.resources | Where-Object { [string]$_.state -eq 'active' -and [string]$_.kind -eq 'candidate-worktree' })) {
        $resource.state = 'retained'; $resource.updatedAt = [DateTime]::UtcNow.ToString('o'); $staleActiveChanged = $true
    }
    if ($staleActiveChanged) { [void](Write-DeliveryResourceLedger -Ledger $staleActiveLedger) }
    Update-DeliveryFailedPlanRetention
    $before = Read-DeliveryResourceLedger
    $preservePaths = @($before.resources | Where-Object { [string]$_.state -in @("active", "retained") -and $_.identity.PSObject.Properties["path"] } | ForEach-Object { [string]$_.identity.path } | Where-Object { $_ })
    $cleanup = Invoke-SourceDeliveryPostSuccessCleanup -FreshProjectsRoot $FreshProjectsRoot -E2EProjectRoot $E2EProjectRoot -PreservePaths $preservePaths
    $ledger = Read-DeliveryResourceLedger
    $attemptedAt = [DateTime]::UtcNow.ToString("o")
    $ledgerWarnings = [Collections.Generic.List[string]]::new()
    foreach ($resource in @($ledger.resources | Where-Object { [string]$_.state -ne "removed" })) {
        if ([string]$resource.state -eq "cleanup-pending") {
            $resource.cleanupAttempts = [int]$resource.cleanupAttempts + 1
            $resource.lastAttemptAt = $attemptedAt
            $resource.updatedAt = $attemptedAt
        }
        $pathProperty = $resource.identity.PSObject.Properties["path"]
        if ($pathProperty -and [string]$pathProperty.Value -and -not (Test-Path -LiteralPath ([string]$pathProperty.Value))) {
            $resource.state = "removed"; $resource.lastError = ""
        }
        if ([string]$resource.kind -eq "cleanup-sweep" -and [string]$resource.state -eq "cleanup-pending") {
            # A sweep warning describes one completed attempt, not a persistent
            # resource identity. Retire it before recording this attempt's warnings.
            $resource.state = "removed"; $resource.lastError = ""
            continue
        }
        if ([string]$resource.state -eq "cleanup-pending") {
            try {
                $handled = Remove-DeliveryPendingLedgerResource -Resource $resource
                if ($handled) { $resource.state = "removed"; $resource.lastError = "" }
                elseif ($pathProperty -and [string]$pathProperty.Value) {
                    $message = "safe cleanup adapter did not remove $([string]$resource.kind): $([string]$pathProperty.Value)"
                    $resource.lastError = $message; $ledgerWarnings.Add($message) | Out-Null
                }
            } catch {
                $message = "$([string]$resource.kind): $($_.Exception.Message)"
                $resource.lastError = $message; $ledgerWarnings.Add($message) | Out-Null
            }
        }
    }
    [void](Write-DeliveryResourceLedger -Ledger $ledger)
    $allWarnings = @($cleanup.warnings) + @($ledgerWarnings)
    foreach ($warning in $allWarnings) {
        $identity = [ordered]@{ phase=$Phase; freshProjectsRoot=[IO.Path]::GetFullPath($FreshProjectsRoot); e2eProjectRoot=$(if($E2EProjectRoot){[IO.Path]::GetFullPath($E2EProjectRoot)}else{""}); warning=[string]$warning }
        $id = Register-DeliveryResource -PlanId "housekeeping" -Kind "cleanup-sweep" -Owner "source-delivery-cleanup" -Identity $identity -State "cleanup-pending" -RetainUntil ([DateTime]::UtcNow)
        [void](Set-DeliveryResourceState -ResourceId $id -State "cleanup-pending" -ErrorMessage ([string]$warning))
    }
    $summary = Get-DeliveryResourceLedgerSummary
    return [pscustomobject][ordered]@{
        status=$(if($allWarnings.Count -gt 0){"completed-with-warnings"}else{"completed"})
        phase=$Phase; warnings=$allWarnings; cleanup=$cleanup; debt=$summary
    }
}
