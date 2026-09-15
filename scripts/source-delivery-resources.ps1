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

function Get-DeliveryResourceArchiveRoot {
    return Join-Path (Split-Path -Parent (Get-DeliveryResourceLedgerPath)) "archive"
}

if (-not (Get-Variable -Name DeliveryResourceArchiveCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DeliveryResourceArchiveCache = @{}
}
$script:DeliveryResourceArchivePhysicalReadCount = 0

function Test-DeliveryRemovedResourceArchivable {
    param([Parameter(Mandatory = $true)][object]$Resource)
    if (-not $Resource.PSObject.Properties['state'] -or [string]$Resource.state -cne 'removed') { return $false }
    $ownership = Test-DeliveryLedgerResourceOwnership -Resource $Resource
    if (-not [bool]$ownership.owned) { return $false }
    foreach ($name in @('createdAt','updatedAt','retainUntil','cleanupAttempts','lastAttemptAt','lastError')) {
        if (-not $Resource.PSObject.Properties[$name]) { return $false }
    }
    try {
        [void](ConvertFrom-DeliveryUtcTimestamp -Value $Resource.createdAt)
        [void](ConvertFrom-DeliveryUtcTimestamp -Value $Resource.updatedAt)
        [void](ConvertFrom-DeliveryUtcTimestamp -Value $Resource.retainUntil)
        [void][int]$Resource.cleanupAttempts
    } catch { return $false }
    return $true
}

function Read-DeliveryResourceArchive {
    param([Parameter(Mandatory = $true)][object]$Descriptor)
    $sha = [string]$Descriptor.sha256
    $prefix = [string]$Descriptor.prefix
    if ($prefix -notmatch '^[a-f0-9]{2}$' -or $sha -notmatch '^[a-f0-9]{64}$' -or [string]$Descriptor.file -cne "$sha.json") {
        throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: invalid archive descriptor."
    }
    $path = Join-Path (Get-DeliveryResourceArchiveRoot) ([string]$Descriptor.file)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: missing or SHA-mismatched archive '$path'."
    }
    $item = Get-Item -LiteralPath $path
    $cacheKey = "$sha|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
    if ($script:DeliveryResourceArchiveCache.ContainsKey($cacheKey)) {
        $archive = $script:DeliveryResourceArchiveCache[$cacheKey]
    } else {
        if ((Get-DeliveryFileSha256 -Path $path) -cne $sha) {
            throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: missing or SHA-mismatched archive '$path'."
        }
        try { $archive = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: unreadable archive '$path'. $($_.Exception.Message)" }
        $script:DeliveryResourceArchivePhysicalReadCount++
        $script:DeliveryResourceArchiveCache[$cacheKey] = $archive
    }
    if ([int]$archive.schemaVersion -ne 1 -or [string]$archive.kind -cne 'itl-delivery-resource-archive' -or
        [string]$archive.prefix -cne $prefix -or
        @($archive.resources).Count -ne [int]$Descriptor.count) {
        throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: invalid archive contract '$path'."
    }
    foreach ($resource in @($archive.resources)) {
        if (-not $resource.PSObject.Properties['resourceId'] -or [string]$resource.resourceId -notmatch "^$prefix[a-f0-9]{62}$") {
            throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: resource outside shard '$prefix' in '$path'."
        }
    }
    return $archive
}

function Get-DeliveryArchivedResource {
    param(
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$ResourceId
    )
    if ($ResourceId -notmatch '^[a-f0-9]{64}$') { return $null }
    $prefix = $ResourceId.Substring(0, 2)
    $descriptors = if ($Ledger.PSObject.Properties['archives']) { @($Ledger.archives) } else { @() }
    $matchingDescriptors = @($descriptors | Where-Object { $_.PSObject.Properties['prefix'] -and [string]$_.prefix -ceq $prefix })
    if ($matchingDescriptors.Count -eq 0) { return $null }
    if ($matchingDescriptors.Count -ne 1) { throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: duplicate shard '$prefix'." }
    $archive = Read-DeliveryResourceArchive -Descriptor $matchingDescriptors[0]
    $matches = @($archive.resources | Where-Object { [string]$_.resourceId -ceq $ResourceId })
    if ($matches.Count -eq 0) { return $null }
    foreach ($resource in $matches) {
        if (-not (Test-DeliveryRemovedResourceArchivable -Resource $resource)) {
            throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: archived resource '$ResourceId' is not an exact terminal delivery resource."
        }
    }
    return @($matches | Sort-Object { ConvertFrom-DeliveryUtcTimestamp -Value $_.updatedAt }, resourceId -Descending | Select-Object -First 1)[0]
}

function Write-DeliveryResourceArchiveShard {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][object[]]$Resources
    )
    $payload = [pscustomobject][ordered]@{
        schemaVersion=1; kind='itl-delivery-resource-archive'; prefix=$Prefix; resources=@($Resources)
    }
    $content = ($payload | ConvertTo-Json -Depth 24 -Compress) + [Environment]::NewLine
    $sha = Get-DeliveryTextSha256 -Text $content
    $archiveRoot = Get-DeliveryResourceArchiveRoot
    New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
    $archivePath = Join-Path $archiveRoot "$sha.json"
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        if ((Get-DeliveryFileSha256 -Path $archivePath) -cne $sha) { throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: content-address collision at '$archivePath'." }
    } else {
        $temporary = Join-Path $archiveRoot ("$sha." + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($temporary, $content, [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporary -Destination $archivePath
        } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{
        descriptor=[pscustomobject][ordered]@{ prefix=$Prefix; sha256=$sha; file="$sha.json"; count=$Resources.Count }
        sha256=$sha; path=$archivePath
    }
}

function Compact-DeliveryResourceLedger {
    $ledger = Read-DeliveryResourceLedger
    $selected = @($ledger.resources | Where-Object {
        Test-DeliveryRemovedResourceArchivable -Resource $_
    } | Sort-Object resourceId, updatedAt)
    if ($selected.Count -eq 0) {
        return [pscustomobject]@{ status='unchanged'; archived=0; retained=@($ledger.resources).Count; archiveSha256='' }
    }

    # Each two-hex resourceId prefix owns one bounded lookup shard. Complete
    # records (including unknown fields) are retained, while old immutable blobs
    # remain valid crash evidence after the ledger atomically points at a new SHA.
    $archives = if ($ledger.PSObject.Properties['archives']) { @($ledger.archives) } else { @() }
    $writes = [Collections.Generic.List[object]]::new()
    foreach ($group in @($selected | Group-Object { ([string]$_.resourceId).Substring(0, 2) } | Sort-Object Name)) {
        $prefix = [string]$group.Name
        $descriptors = @($archives | Where-Object { $_.PSObject.Properties['prefix'] -and [string]$_.prefix -ceq $prefix })
        if ($descriptors.Count -gt 1) { throw "DELIVERY_RESOURCE_ARCHIVE_CORRUPT: duplicate shard '$prefix'." }
        $prior = if ($descriptors.Count -eq 1) { @((Read-DeliveryResourceArchive -Descriptor $descriptors[0]).resources) } else { @() }
        $byId = [ordered]@{}
        foreach ($resource in @($prior) + @($group.Group)) {
            $id = [string]$resource.resourceId
            if (-not $byId.Contains($id) -or
                (ConvertFrom-DeliveryUtcTimestamp -Value $resource.updatedAt) -ge (ConvertFrom-DeliveryUtcTimestamp -Value $byId[$id].updatedAt)) {
                $byId[$id] = $resource
            }
        }
        $resources = @($byId.Values | Sort-Object resourceId)
        $write = Write-DeliveryResourceArchiveShard -Prefix $prefix -Resources $resources
        $writes.Add($write) | Out-Null
        $archives = @($archives | Where-Object { -not $_.PSObject.Properties['prefix'] -or [string]$_.prefix -cne $prefix }) + @($write.descriptor)
    }

    $selectedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($resource in $selected) { [void]$selectedIds.Add([string]$resource.resourceId) }
    $ledger.resources = @($ledger.resources | Where-Object {
        -not ($selectedIds.Contains([string]$_.resourceId) -and (Test-DeliveryRemovedResourceArchivable -Resource $_))
    })
    $archives = @($archives | Sort-Object prefix)
    if ($ledger.PSObject.Properties['archives']) { $ledger.archives = $archives }
    else { $ledger | Add-Member -NotePropertyName archives -NotePropertyValue $archives }
    [void](Write-DeliveryResourceLedger -Ledger $ledger)
    $first = @($writes | Select-Object -First 1)
    return [pscustomobject]@{
        status='compacted'; archived=$selected.Count; retained=@($ledger.resources).Count; archivesWritten=$writes.Count
        archiveSha256=$(if($first.Count){[string]$first[0].sha256}else{''})
        archivePath=$(if($first.Count){[string]$first[0].path}else{''})
        archiveSha256s=@($writes | ForEach-Object { [string]$_.sha256 })
    }
}

function ConvertFrom-DeliveryUtcTimestamp {
    param([Parameter(Mandatory = $true)][object]$Value)
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).UtcDateTime
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
    if (-not $existing) {
        $existing = Get-DeliveryArchivedResource -Ledger $ledger -ResourceId $resourceId
        if ($existing) { $resources += $existing }
    }
    if ($existing) {
        $existing.identity = $Identity
        $existing.identitySha256 = $identitySha
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
        $latest = @($_.Group | Sort-Object { ConvertFrom-DeliveryUtcTimestamp -Value $_.updatedAt } -Descending | Select-Object -First 1)[0]
        [pscustomobject]@{ planId=$_.Name; updatedAt=(ConvertFrom-DeliveryUtcTimestamp -Value $latest.updatedAt) }
    } | Sort-Object updatedAt -Descending)
    $keepPlans = @($retainedPlans | Select-Object -First 2 | ForEach-Object { [string]$_.planId })
    $changed = $false
    foreach ($resource in @($ledger.resources | Where-Object { [string]$_.state -eq "retained" })) {
        $expired = (ConvertFrom-DeliveryUtcTimestamp -Value $resource.retainUntil) -le $now
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
        [int64][Math]::Max(0, ([DateTime]::UtcNow - (ConvertFrom-DeliveryUtcTimestamp -Value $oldest[0].createdAt)).TotalSeconds)
    } else { 0 }
    $archived = [int64]0
    if ($ledger.PSObject.Properties['archives']) {
        foreach ($archive in @($ledger.archives)) { $archived += [int64]$archive.count }
    }
    return [pscustomobject][ordered]@{
        path=(Get-DeliveryResourceLedgerPath); total=@($ledger.resources).Count
        archived=$archived
        pending=@($pending | Where-Object state -eq "cleanup-pending").Count; retained=@($pending | Where-Object state -eq "retained").Count
        bytes=$bytes; oldestAt=$(if($oldest.Count){[string]$oldest[0].createdAt}else{""}); oldestAgeSeconds=$oldestAgeSeconds
        nextAttempt="next PublishDevelop, PromoteRelease, ReleaseMaster, or Cleanup"
        entries=@($pending | ForEach-Object { [pscustomobject]@{ resourceId=$_.resourceId; planId=$_.planId; kind=$_.kind; owner=$_.owner; state=$_.state; retainUntil=$_.retainUntil; cleanupAttempts=$_.cleanupAttempts; lastError=$_.lastError; identity=$_.identity } })
    }
}

function New-DeliveryDispositionEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][ValidateSet('keep', 'eligible', 'not-owned')][string]$Disposition,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$ExpectedSha = '',
        [string]$ObservedSha = '',
        [string]$ResourceId = ''
    )
    return [pscustomobject][ordered]@{
        scope=$Scope; identity=$Identity; disposition=$Disposition; reason=$Reason
        expectedSha=$ExpectedSha; observedSha=$ObservedSha; resourceId=$ResourceId
    }
}

function Get-DeliveryDispositionGroups {
    param([object[]]$Entries)
    return @($Entries | Group-Object disposition, reason | Sort-Object Name | ForEach-Object {
        [pscustomobject][ordered]@{
            disposition=[string]$_.Group[0].disposition
            reason=[string]$_.Group[0].reason
            count=[int]$_.Count
        }
    })
}

function Invoke-DeliveryBoundedLsRemote {
    param([int]$TimeoutMilliseconds = 15000)
    $arguments = @('-C', $script:Root, '-c', 'core.quotepath=false', '-c', 'credential.interactive=never', 'ls-remote', '--exit-code', '--refs', $script:Remote, 'refs/heads/develop', 'refs/heads/master')
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git.exe'
    $startInfo.Arguments = @($arguments | ForEach-Object { ConvertTo-GitProcessArgument -Value ([string]$_) }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $startInfo.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.EnvironmentVariables['GCM_INTERACTIVE'] = 'Never'
    $startInfo.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'never'
    $startInfo.EnvironmentVariables['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes -o ConnectTimeout=5'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            return [pscustomobject]@{ status='start-failed'; exitCode=-1; stdout=''; stderr='git did not start' }
        }
        $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(1, $TimeoutMilliseconds))
        $rootCreatedAt = $process.StartTime.ToUniversalTime()
        $capturedDescendants = @{}
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while ($true) {
            $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) {
                if (Get-Command Get-DeliveryDescendantProcessIdentities -ErrorAction SilentlyContinue) {
                    foreach ($identity in @(Get-DeliveryDescendantProcessIdentities -RootProcessId $process.Id -RootCreatedAt $rootCreatedAt)) {
                        $capturedDescendants["$([int]$identity.processId)|$(([DateTime]$identity.createdAt).ToUniversalTime().Ticks)"] = $identity
                    }
                }
                if (Get-Command Stop-DeliveryProcessTree -ErrorAction SilentlyContinue) { Stop-DeliveryProcessTree -Process $process -TimeoutMilliseconds 5000 -CapturedDescendants @($capturedDescendants.Values) }
                else { try { if (-not $process.HasExited) { $process.Kill() } } catch {} }
                return [pscustomobject]@{ status='timed-out'; exitCode=-1; stdout=''; stderr="ls-remote exceeded ${TimeoutMilliseconds}ms" }
            }
            if ($process.WaitForExit([Math]::Min(100, $remaining))) { break }
            if (Get-Command Get-DeliveryDescendantProcessIdentities -ErrorAction SilentlyContinue) {
                foreach ($identity in @(Get-DeliveryDescendantProcessIdentities -RootProcessId $process.Id -RootCreatedAt $rootCreatedAt)) {
                    $capturedDescendants["$([int]$identity.processId)|$(([DateTime]$identity.createdAt).ToUniversalTime().Ticks)"] = $identity
                }
            }
        }
        $readersComplete = $true
        foreach ($reader in @($stdoutTask, $stderrTask)) {
            $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            try { if (-not $reader.Wait($remaining)) { $readersComplete = $false; break } }
            catch { $readersComplete = $false; break }
        }
        if (-not $readersComplete) {
            if (Get-Command Get-DeliveryDescendantProcessIdentities -ErrorAction SilentlyContinue) {
                foreach ($identity in @(Get-DeliveryDescendantProcessIdentities -RootProcessId $process.Id -RootCreatedAt $rootCreatedAt)) {
                    $capturedDescendants["$([int]$identity.processId)|$(([DateTime]$identity.createdAt).ToUniversalTime().Ticks)"] = $identity
                }
            }
            if (Get-Command Stop-DeliveryProcessTree -ErrorAction SilentlyContinue) { Stop-DeliveryProcessTree -Process $process -TimeoutMilliseconds 5000 -CapturedDescendants @($capturedDescendants.Values) }
            else { try { if (-not $process.HasExited) { $process.Kill() } } catch {} }
            return [pscustomobject]@{ status='timed-out'; exitCode=-1; stdout=''; stderr="ls-remote output drain exceeded ${TimeoutMilliseconds}ms" }
        }
        return [pscustomobject]@{
            status='completed'; exitCode=[int]$process.ExitCode
            stdout=[string]$stdoutTask.Result
            stderr=[string]$stderrTask.Result
        }
    } catch {
        return [pscustomobject]@{ status='start-failed'; exitCode=-1; stdout=''; stderr=$_.Exception.Message }
    } finally { $process.Dispose() }
}

function Get-DeliveryAuthoritativePublishedTips {
    $result = Invoke-DeliveryBoundedLsRemote
    if ([string]$result.status -eq 'timed-out') {
        return [pscustomobject]@{ status='timeout'; remote=$script:Remote; tips=@() }
    }
    if ([string]$result.status -ne 'completed' -or $result.exitCode -ne 0) {
        return [pscustomobject]@{ status='unavailable'; remote=$script:Remote; tips=@() }
    }
    $tips = [Collections.Generic.List[object]]::new()
    foreach ($line in @($result.stdout -split '\r?\n' | Where-Object { $_ })) {
        if ($line -notmatch '^([a-f0-9]{40})\s+(refs/heads/(develop|master))$') {
            return [pscustomobject]@{ status='unavailable'; remote=$script:Remote; tips=@() }
        }
        $tips.Add([pscustomobject]@{ sha=[string]$Matches[1]; ref=[string]$Matches[2] }) | Out-Null
    }
    if ($tips.Count -eq 0) {
        return [pscustomobject]@{ status='unavailable'; remote=$script:Remote; tips=@() }
    }
    return [pscustomobject]@{ status='available'; remote=$script:Remote; tips=@($tips) }
}

function Get-DeliveryPublishedCommitDisposition {
    param(
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][object]$PublishedState
    )
    if ($Commit -notmatch '^[a-f0-9]{40}$') {
        return [pscustomobject]@{ disposition='not-owned'; reason='invalid-commit'; observedSha=$Commit }
    }
    if ([string]$PublishedState.status -ne 'available') {
        return [pscustomobject]@{ disposition='keep'; reason='authoritative-published-refs-unavailable'; observedSha=$Commit }
    }
    $candidateTreeResult = Invoke-DeliveryGit -Arguments @('rev-parse', "$Commit^{tree}") -AllowFailure
    if ($candidateTreeResult.exitCode -ne 0) {
        return [pscustomobject]@{ disposition='not-owned'; reason='missing-commit'; observedSha=$Commit }
    }
    $candidateTree = $candidateTreeResult.stdout.Trim()
    $missingPublishedObject = $false
    foreach ($tip in @($PublishedState.tips)) {
        $publishedCommit = [string]$tip.sha
        $publishedTreeResult = Invoke-DeliveryGit -Arguments @('rev-parse', "$publishedCommit^{tree}") -AllowFailure
        if ($publishedTreeResult.exitCode -ne 0) {
            $missingPublishedObject = $true
            continue
        }
        $ancestor = Invoke-DeliveryGit -Arguments @('merge-base', '--is-ancestor', $Commit, $publishedCommit) -AllowFailure
        if ($ancestor.exitCode -eq 0) {
            return [pscustomobject]@{ disposition='eligible'; reason='published-ancestor'; observedSha=$Commit }
        }
        if ($publishedTreeResult.stdout.Trim() -ceq $candidateTree) {
            return [pscustomobject]@{ disposition='eligible'; reason='published-tree-equivalent'; observedSha=$Commit }
        }
    }
    return [pscustomobject]@{
        disposition='keep'
        reason=$(if($missingPublishedObject){'authoritative-published-object-unavailable'}else{'not-published'})
        observedSha=$Commit
    }
}

function Get-DeliveryPathUseAdvisory {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $escaped = [regex]::Escape(([IO.Path]::GetFullPath($Path)).TrimEnd('\'))
        $inUse = @((Get-CimInstance Win32_Process -ErrorAction Stop) | Where-Object {
            [string]$_.CommandLine -match $escaped
        }).Count -gt 0
        return [pscustomobject]@{ status=$(if($inUse){'advisory-active'}else{'advisory-clear'}); detail='' }
    } catch {
        # Status is diagnostic. An unavailable runtime probe protects the target
        # from future deletion without turning the read-only report into FAIL.
        return [pscustomobject]@{ status='unknown'; detail=$_.Exception.Message }
    }
}

function Test-DeliveryLedgerResourceOwnership {
    param([Parameter(Mandatory = $true)][object]$Resource)
    if (-not $Resource.PSObject.Properties['kind'] -or -not $Resource.PSObject.Properties['owner']) {
        return [pscustomobject]@{ owned=$false; reason='missing-owner-contract' }
    }
    $kind = [string]$Resource.kind
    $owner = [string]$Resource.owner
    $known = switch ($kind) {
        'candidate-worktree' { $owner -ceq 'source-delivery' }
        'reusable-stand' { $owner -cin @('Develop-e2e', 'Release-e2e') }
        'develop-fresh-project' { $owner -ceq 'develop-e2e' }
        'release-artifact' { $owner -ceq 'release-e2e' }
        'capability-generation' { $owner -ceq 'release-e2e' }
        'release-snapshot' { $owner -ceq 'release-e2e' }
        'owned-process-port' { $owner -cmatch '^release-e2e\.[A-Za-z0-9._-]+$' }
        'cleanup-sweep' { $owner -ceq 'source-delivery-cleanup' }
        default { $false }
    }
    if (-not $known) { return [pscustomobject]@{ owned=$false; reason='unknown-kind-owner' } }
    if (-not $Resource.PSObject.Properties['identity'] -or -not $Resource.PSObject.Properties['identitySha256']) {
        return [pscustomobject]@{ owned=$false; reason='missing-identity-proof' }
    }
    $actualIdentitySha = Get-DeliveryCanonicalJsonSha256 -Value $Resource.identity
    if ($actualIdentitySha -cne [string]$Resource.identitySha256) {
        return [pscustomobject]@{ owned=$false; reason='identity-proof-mismatch' }
    }
    if (-not $Resource.PSObject.Properties['planId'] -or -not $Resource.PSObject.Properties['resourceId']) {
        return [pscustomobject]@{ owned=$false; reason='missing-resource-id-proof' }
    }
    $expectedResourceId = Get-DeliveryTextSha256 -Text "$([string]$Resource.planId)|$kind|$owner|$actualIdentitySha"
    if ([string]$Resource.resourceId -cne $expectedResourceId) {
        return [pscustomobject]@{ owned=$false; reason='resource-id-proof-mismatch' }
    }
    return [pscustomobject]@{ owned=$true; reason='exact-ledger-owner' }
}

function Get-DeliveryCandidateWorktreeDispositions {
    param([Parameter(Mandatory = $true)][object]$Ledger)
    $entries = [Collections.Generic.List[object]]::new()
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $candidateResources = @($Ledger.resources | Where-Object {
        $_.PSObject.Properties['kind'] -and $_.PSObject.Properties['owner'] -and
        [string]$_.kind -eq 'candidate-worktree' -and [string]$_.owner -eq 'source-delivery'
    })
    foreach ($worktree in @(Get-DevelopE2ERegisteredWorktrees -ProjectRoot $script:Root)) {
        $path = [IO.Path]::GetFullPath([string]$worktree.path).TrimEnd('\', '/')
        $branch = [string]$worktree.branch
        $leaf = Split-Path -Leaf $path
        $shapeMatch = [regex]::Match($leaf, '^itl-source-(publish-develop|release-master)-([0-9a-f]{32})$')
        $candidateLike = $shapeMatch.Success -or $branch -cmatch '^refs/heads/itl/(publish-develop|release-master)-[0-9a-f]{32}$'
        if (-not $candidateLike) { continue }
        $identity = "$path|$branch"
        if (-not $shapeMatch.Success -or
            -not [string]::Equals((Split-Path -Parent $path), $tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $branch -cne "refs/heads/itl/$($shapeMatch.Groups[1].Value)-$($shapeMatch.Groups[2].Value)") {
            $entries.Add((New-DeliveryDispositionEntry -Scope worktree -Identity $identity -Disposition not-owned -Reason 'generated-shape-mismatch')) | Out-Null
            continue
        }
        $resourceMatches = @($candidateResources | Where-Object {
            if (-not $_.PSObject.Properties['identity'] -or -not $_.identity -or
                -not $_.identity.PSObject.Properties['path'] -or -not $_.identity.PSObject.Properties['branch']) { return $false }
            try {
                return [string]::Equals(([IO.Path]::GetFullPath([string]$_.identity.path).TrimEnd('\', '/')), $path, [StringComparison]::OrdinalIgnoreCase) -and
                    [string]$_.identity.branch -ceq $branch.Substring('refs/heads/'.Length)
            } catch { return $false }
        })
        if ($resourceMatches.Count -ne 1) {
            $entries.Add((New-DeliveryDispositionEntry -Scope worktree -Identity $identity -Disposition not-owned -Reason 'exact-ledger-owner-missing')) | Out-Null
            continue
        }
        $resource = $resourceMatches[0]
        $ownership = Test-DeliveryLedgerResourceOwnership -Resource $resource
        if (-not [bool]$ownership.owned -or -not $resource.identity.PSObject.Properties['candidate']) {
            $reason = if (-not [bool]$ownership.owned) { [string]$ownership.reason } else { 'missing-candidate-sha' }
            $entries.Add((New-DeliveryDispositionEntry -Scope worktree -Identity $identity -Disposition not-owned -Reason $reason -ResourceId ([string]$resource.resourceId))) | Out-Null
            continue
        }
        $expectedSha = [string]$resource.identity.candidate
        if ([string]$resource.state -ne 'cleanup-pending') {
            $entries.Add((New-DeliveryDispositionEntry -Scope worktree -Identity $identity -Disposition keep -Reason "ledger-state-$([string]$resource.state)" -ExpectedSha $expectedSha -ResourceId ([string]$resource.resourceId))) | Out-Null
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            $entries.Add((New-DeliveryDispositionEntry -Scope worktree -Identity $identity -Disposition keep -Reason 'worktree-path-missing' -ExpectedSha $expectedSha -ResourceId ([string]$resource.resourceId))) | Out-Null
            continue
        }
        $headResult = Invoke-RepositoryGit -RepositoryRoot $path -Arguments @('rev-parse', 'HEAD') -AllowFailure
        $observedSha = if ($headResult.exitCode -eq 0) { $headResult.stdout.Trim() } else { '' }
        if ($observedSha -cne $expectedSha) {
            $entries.Add((New-DeliveryDispositionEntry -Scope worktree -Identity $identity -Disposition keep -Reason 'expected-sha-mismatch' -ExpectedSha $expectedSha -ObservedSha $observedSha -ResourceId ([string]$resource.resourceId))) | Out-Null
            continue
        }
        $status = Invoke-RepositoryGit -RepositoryRoot $path -Arguments @('--no-optional-locks', 'status', '--porcelain', '--untracked-files=all') -AllowFailure
        if ($status.exitCode -ne 0 -or [string]$status.stdout) {
            $entries.Add((New-DeliveryDispositionEntry -Scope worktree -Identity $identity -Disposition keep -Reason 'worktree-not-clean' -ExpectedSha $expectedSha -ObservedSha $observedSha -ResourceId ([string]$resource.resourceId))) | Out-Null
            continue
        }
        $use = Get-DeliveryPathUseAdvisory -Path $path
        $useReason = if ([string]$use.status -eq 'advisory-active') { 'worktree-process-advisory-active' } elseif ([string]$use.status -eq 'unknown') { 'worktree-process-advisory-unknown' } else { 'process-free-proof-required' }
        # Command-line inspection is only an advisory signal: no match cannot
        # prove that handles, cwd, or an unobservable process do not use the
        # worktree. Until a complete proof exists the candidate stays protected.
        $entries.Add((New-DeliveryDispositionEntry -Scope worktree -Identity $identity -Disposition keep -Reason $useReason -ExpectedSha $expectedSha -ObservedSha $observedSha -ResourceId ([string]$resource.resourceId))) | Out-Null
    }
    return @($entries)
}

function Get-DeliveryDispositionPublicationAttempt {
    $path = Get-DevelopPublicationAttemptPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ status='absent'; path=$path; attempt=$null; fingerprint='absent' }
    }
    $fingerprint = ''
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $fingerprint = Get-DeliveryTextSha256 -Text $raw
        $attempt = $raw | ConvertFrom-Json
        if ([int]$attempt.schemaVersion -ne 1) { throw 'unsupported schema' }
        return [pscustomobject]@{ status='valid'; path=$path; attempt=$attempt; fingerprint="valid:$fingerprint" }
    } catch {
        $malformedFingerprint = if ($fingerprint) { $fingerprint } else { Get-DeliveryTextSha256 -Text $_.Exception.Message }
        return [pscustomobject]@{ status='malformed'; path=$path; attempt=$null; fingerprint="malformed:$malformedFingerprint" }
    }
}

function Get-DeliveryOwnedRefSnapshot {
    $raw = Invoke-DeliveryGit -Arguments @('for-each-ref', '--format=%(refname) %(objectname)', 'refs/itl/develop-queue/', 'refs/itl/develop-promotions/', 'refs/heads/itl/publish-develop-', 'refs/heads/itl/release-master-')
    $entries = @($raw.stdout -split '\r?\n' | Where-Object { $_ } | ForEach-Object {
        $parts = $_.Split(' ', 2); [pscustomobject]@{ name=[string]$parts[0]; sha=[string]$parts[1] }
    } | Sort-Object name)
    $snapshotText = @($entries | ForEach-Object { "$($_.name) $($_.sha)" }) -join "`n"
    $fingerprint = Get-DeliveryTextSha256 -Text "owned-refs-v1`n$snapshotText"
    return [pscustomobject]@{ entries=$entries; fingerprint=$fingerprint }
}

function Get-DeliveryRefDispositions {
    param(
        [object[]]$WorktreeEntries,
        [Parameter(Mandatory = $true)][object]$AttemptState,
        [Parameter(Mandatory = $true)][object]$PublishedState,
        [Parameter(Mandatory = $true)][object]$RefState,
        [bool]$AttemptSnapshotStable = $true,
        [bool]$RefSnapshotStable = $true
    )
    $entries = [Collections.Generic.List[object]]::new()
    $refs = @($RefState.entries)
    if (-not $RefSnapshotStable) {
        foreach ($ref in $refs) {
            $exactOwnedShape = [string]$ref.name -match '^refs/itl/develop-queue/.+/(base|head)$' -or
                [string]$ref.name -match '^refs/itl/develop-promotions/[a-f0-9]{64}$' -or
                [string]$ref.name -match '^refs/heads/itl/(publish-develop|release-master)-[a-f0-9]{32}$'
            $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition $(if($exactOwnedShape){'keep'}else{'not-owned'}) -Reason $(if($exactOwnedShape){'local-ref-snapshot-changed'}else{'owned-ref-shape-mismatch'}) -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null
        }
        return @($entries)
    }
    $queueGroups = @($refs | Where-Object name -like 'refs/itl/develop-queue/*' | Group-Object {
        if ($_.name -match '^refs/itl/develop-queue/(.+)/(base|head)$') { $Matches[1] } else { $_.name }
    })
    foreach ($group in $queueGroups) {
        $base = @($group.Group | Where-Object name -match '/base$')
        $head = @($group.Group | Where-Object name -match '/head$')
        if ($base.Count -ne 1 -or $head.Count -ne 1 -or $group.Group.Count -ne 2) {
            foreach ($ref in $group.Group) { $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition not-owned -Reason 'incomplete-queue-pair' -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null }
            continue
        }
        $baseSha = [string]$base[0].sha
        $headSha = [string]$head[0].sha
        $queueAncestry = if ($baseSha -match '^[a-f0-9]{40}$' -and $headSha -match '^[a-f0-9]{40}$') {
            Invoke-DeliveryGit -Arguments @('merge-base', '--is-ancestor', $baseSha, $headSha) -AllowFailure
        } else { [pscustomobject]@{ exitCode=1 } }
        if ($queueAncestry.exitCode -ne 0) {
            foreach ($ref in @($base[0], $head[0])) { $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition not-owned -Reason 'invalid-queue-ancestry' -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null }
            continue
        }
        $published = Get-DeliveryPublishedCommitDisposition -Commit ([string]$head[0].sha) -PublishedState $PublishedState
        $disposition = if ([string]$published.disposition -eq 'eligible') { 'eligible' } elseif ([string]$published.disposition -eq 'not-owned') { 'not-owned' } else { 'keep' }
        $reason = if ($disposition -eq 'eligible') { "queue-$([string]$published.reason)" } elseif ($disposition -eq 'keep') { 'queue-open' } else { [string]$published.reason }
        foreach ($ref in @($base[0], $head[0])) { $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition $disposition -Reason $reason -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null }
    }
    foreach ($ref in @($refs | Where-Object name -like 'refs/itl/develop-promotions/*')) {
        if ($ref.name -notmatch '^refs/itl/develop-promotions/[a-f0-9]{64}$') {
            $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition not-owned -Reason 'promotion-ref-shape-mismatch' -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null
            continue
        }
        if (-not $AttemptSnapshotStable) {
            $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition keep -Reason 'publication-attempt-changed-during-status' -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null
            continue
        }
        if ([string]$AttemptState.status -eq 'malformed') {
            $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition keep -Reason 'publication-attempt-unreadable' -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null
            continue
        }
        $attempt = if ([string]$AttemptState.status -eq 'valid') { $AttemptState.attempt } else { $null }
        $hasPromotionRef = $attempt -and $attempt.PSObject.Properties['promotionRef'] -and [string]$attempt.promotionRef
        $hasPromotionCommit = $attempt -and $attempt.PSObject.Properties['promotionCommit'] -and [string]$attempt.promotionCommit
        if ($hasPromotionRef -or $hasPromotionCommit) {
            $attemptRef = if ($hasPromotionRef) { [string]$attempt.promotionRef } else { '' }
            $attemptCommit = if ($hasPromotionCommit) { [string]$attempt.promotionCommit } else { '' }
            if (-not $hasPromotionRef -or -not $hasPromotionCommit -or
                $attemptRef -notmatch '^refs/itl/develop-promotions/[a-f0-9]{64}$' -or
                $attemptCommit -notmatch '^[a-f0-9]{40}$') {
                $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition keep -Reason 'active-promotion-attempt-malformed' -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null
                continue
            }
            if ($attemptRef -ceq [string]$ref.name) {
                $reason = if ($attemptCommit -ceq [string]$ref.sha) { 'active-promotion' } else { 'active-promotion-sha-mismatch' }
                $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition keep -Reason $reason -ExpectedSha $attemptCommit -ObservedSha $ref.sha)) | Out-Null
                continue
            }
        }
        $published = Get-DeliveryPublishedCommitDisposition -Commit ([string]$ref.sha) -PublishedState $PublishedState
        $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition ([string]$published.disposition) -Reason "promotion-$([string]$published.reason)" -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null
    }
    foreach ($ref in @($refs | Where-Object name -match '^refs/heads/itl/(publish-develop|release-master)-')) {
        $worktree = @($WorktreeEntries | Where-Object { ([string]$_.identity).EndsWith("|$([string]$ref.name)", [StringComparison]::Ordinal) })
        if ($ref.name -notmatch '^refs/heads/itl/(publish-develop|release-master)-[a-f0-9]{32}$' -or $worktree.Count -ne 1) {
            $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition not-owned -Reason 'candidate-worktree-owner-missing' -ExpectedSha $ref.sha -ObservedSha $ref.sha)) | Out-Null
            continue
        }
        $entries.Add((New-DeliveryDispositionEntry -Scope ref -Identity $ref.name -Disposition ([string]$worktree[0].disposition) -Reason "candidate-$([string]$worktree[0].reason)" -ExpectedSha $ref.sha -ObservedSha $ref.sha -ResourceId ([string]$worktree[0].resourceId))) | Out-Null
    }
    return @($entries)
}

function Get-DeliveryResourceDispositions {
    param([Parameter(Mandatory = $true)][object]$Ledger, [object[]]$WorktreeEntries)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($resource in @($Ledger.resources)) {
        $kind = if ($resource.PSObject.Properties['kind']) { [string]$resource.kind } else { '' }
        $owner = if ($resource.PSObject.Properties['owner']) { [string]$resource.owner } else { '' }
        $resourceId = if ($resource.PSObject.Properties['resourceId']) { [string]$resource.resourceId } else { '' }
        $ownership = Test-DeliveryLedgerResourceOwnership -Resource $resource
        if (-not [bool]$ownership.owned) {
            $entries.Add((New-DeliveryDispositionEntry -Scope resource -Identity "$kind|$owner" -Disposition not-owned -Reason ([string]$ownership.reason) -ResourceId $resourceId)) | Out-Null
            continue
        }
        if ($kind -eq 'candidate-worktree') {
            $worktree = @($WorktreeEntries | Where-Object resourceId -eq $resourceId)
            if ($worktree.Count -eq 1) {
                $entries.Add((New-DeliveryDispositionEntry -Scope resource -Identity $resourceId -Disposition ([string]$worktree[0].disposition) -Reason "candidate-$([string]$worktree[0].reason)" -ExpectedSha ([string]$worktree[0].expectedSha) -ObservedSha ([string]$worktree[0].observedSha) -ResourceId $resourceId)) | Out-Null
            } else {
                $entries.Add((New-DeliveryDispositionEntry -Scope resource -Identity $resourceId -Disposition keep -Reason 'candidate-worktree-not-registered' -ExpectedSha $(if($resource.identity.PSObject.Properties['candidate']){[string]$resource.identity.candidate}else{''}) -ResourceId $resourceId)) | Out-Null
            }
            continue
        }
        $state = if ($resource.PSObject.Properties['state']) { [string]$resource.state } else { 'unknown' }
        $reason = if ($state -eq 'removed') { 'raw-history-preserved' } else { "ledger-state-$state" }
        $entries.Add((New-DeliveryDispositionEntry -Scope resource -Identity $resourceId -Disposition keep -Reason $reason -ResourceId $resourceId)) | Out-Null
    }
    return @($entries)
}

function Get-DeliveryDispositionReport {
    $ledger = Read-DeliveryResourceLedger
    $attemptBefore = Get-DeliveryDispositionPublicationAttempt
    $refsBefore = Get-DeliveryOwnedRefSnapshot
    $publishedState = Get-DeliveryAuthoritativePublishedTips
    $worktrees = @(Get-DeliveryCandidateWorktreeDispositions -Ledger $ledger)
    $attemptState = Get-DeliveryDispositionPublicationAttempt
    $refState = Get-DeliveryOwnedRefSnapshot
    $attemptSnapshotStable = [string]$attemptBefore.fingerprint -ceq [string]$attemptState.fingerprint
    $refSnapshotStable = [string]$refsBefore.fingerprint -ceq [string]$refState.fingerprint
    $refs = @(Get-DeliveryRefDispositions -WorktreeEntries $worktrees -AttemptState $attemptState -PublishedState $publishedState -RefState $refState -AttemptSnapshotStable:$attemptSnapshotStable -RefSnapshotStable:$refSnapshotStable)
    $resources = @(Get-DeliveryResourceDispositions -Ledger $ledger -WorktreeEntries $worktrees)
    $all = @($refs) + @($worktrees) + @($resources)
    $counts = [ordered]@{ keep=0; eligible=0; notOwned=0 }
    foreach ($entry in $all) {
        if ([string]$entry.disposition -eq 'not-owned') { $counts.notOwned++ } else { $counts[[string]$entry.disposition]++ }
    }
    return [pscustomobject][ordered]@{
        schemaVersion=1
        readOnly=$true
        deleteSupported=$false
        futureDeleteContract=@('exact-ownership', 'expected-sha-cas', 'clean-worktree', 'complete-process-free-proof-required', 'authoritative-published-ancestry-or-exact-tree-equivalence')
        snapshot=[pscustomobject]@{ stable=($attemptSnapshotStable -and $refSnapshotStable); attemptStable=$attemptSnapshotStable; refsStable=$refSnapshotStable }
        publicationAttemptGuard=[pscustomobject]@{ status=[string]$attemptState.status; path=[string]$attemptState.path }
        publishedEvidence=[pscustomobject]@{ status=[string]$publishedState.status; remote=[string]$publishedState.remote }
        counts=[pscustomobject]$counts
        refs=[pscustomobject]@{ total=$refs.Count; groups=@(Get-DeliveryDispositionGroups -Entries $refs); entries=@($refs) }
        worktrees=[pscustomobject]@{ total=$worktrees.Count; groups=@(Get-DeliveryDispositionGroups -Entries $worktrees); entries=@($worktrees) }
        resources=[pscustomobject]@{
            total=$resources.Count
            groups=@(Get-DeliveryDispositionGroups -Entries $resources)
            entries=@($resources | Where-Object { [string]$_.reason -ne 'raw-history-preserved' })
        }
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

function Test-DeliveryReleaseSnapshotPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$WorktreePath)
    $path = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($WorktreePath).TrimEnd('\', '/')
    if (-not (Test-DeliveryResourcePathWithinRoot -Path $path -Root $root)) { return $false }
    $relative = $path.Substring($root.Length + 1) -replace '\\', '/'
    # Current and resumable legacy layouts are produced by Set-E2ERunPaths.
    if ($relative -match '^\.agent-1c/(runs/release-e2e|release-e2e-runs)/[A-Za-z0-9_.-]+/snapshots/(baseline|post-config)\.dt$') { return $true }
    $legacyRoot = Join-Path $root '.agent-1c\snapshots'
    return ((Test-DeliveryResourcePathWithinRoot -Path $path -Root $legacyRoot) -and
        (Split-Path -Leaf $path) -match '^(release-e2e-|extension-init-).+\.dt$')
}

function Assert-DeliverySnapshotOwnership {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$WorktreePath)
    if (-not (Test-DeliveryReleaseSnapshotPath -Path $Path -WorktreePath $WorktreePath)) {
        throw "snapshot path is outside the owned Release snapshot root: $Path"
    }
    $root = [IO.Path]::GetFullPath($WorktreePath).TrimEnd('\', '/')
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::Equals($cursor.TrimEnd('\', '/'), $root, [StringComparison]::OrdinalIgnoreCase)) {
        if ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "snapshot path contains a reparse point below its owned worktree: $cursor"
        }
        $cursor = Split-Path -Parent $cursor
    }
    # A reusable run filename can be registered by several plans. The old
    # pending record must not delete bytes still owned by a retained/active one,
    # even if both snapshots happen to have the same SHA.
    foreach ($other in @((Read-DeliveryResourceLedger).resources | Where-Object {
        [string]$_.kind -eq 'release-snapshot' -and [string]$_.state -in @('active', 'retained')
    })) {
        $otherPath = [IO.Path]::GetFullPath([string]$other.identity.path)
        if ([string]::Equals([IO.Path]::GetFullPath($Path), $otherPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "snapshot path is retained or active in another ledger record: $Path"
        }
    }
}

function Remove-DeliveryPendingLedgerResource {
    param([Parameter(Mandatory = $true)][object]$Resource)
    $identity = $Resource.identity
    switch ([string]$Resource.kind) {
        "release-snapshot" {
            $path = [IO.Path]::GetFullPath([string]$identity.path)
            $worktreePath = [IO.Path]::GetFullPath([string]$identity.worktreePath)
            Assert-DeliverySnapshotOwnership -Path $path -WorktreePath $worktreePath
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
    try { return @(Register-DeliveryGateResourcesCore @PSBoundParameters) }
    catch {
        if (-not $Failed) { throw }
        Write-Warning "Could not journal failed $Mode resources: $($_.Exception.Message)"
        return @()
    }
}

function Register-DeliveryGateResourcesCore {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][ValidateSet("Develop", "Release")][string]$Mode,
        [switch]$Failed
    )
    $checkSummaryPath = Join-Path $CandidateRoot "build\test-results\local\check-summary.json"
    if (-not (Test-Path -LiteralPath $checkSummaryPath -PathType Leaf)) { return @() }
    try { $checkSummary = Get-Content -LiteralPath $checkSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    if (-not $checkSummary.PSObject.Properties["e2eReportPath"] -or -not [string]$checkSummary.e2eReportPath -or -not (Test-Path -LiteralPath ([string]$checkSummary.e2eReportPath) -PathType Leaf)) { return @() }
    try { $report = Get-Content -LiteralPath ([string]$checkSummary.e2eReportPath) -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    $registered = [Collections.Generic.List[string]]::new()
    $planId = [string]$Plan.planId
    $state = if ($Failed -or [string]$report.status -ne "passed") { "retained" } else { "active" }

    # Failed E2E reports can precede creation of optional resources. Keep known
    # resources without inventing paths or weakening successful-report checks.
    if ($state -eq "retained") {
        foreach ($name in @("projectRoot", "freshProjectRoot", "freshBranchRoot", "onDemandMcpEvidencePath")) {
            if (-not $report.PSObject.Properties[$name]) { $report | Add-Member -NotePropertyName $name -NotePropertyValue "" }
        }
        if (-not $report.PSObject.Properties["snapshots"]) { $report | Add-Member -NotePropertyName snapshots -NotePropertyValue $null }
        if (-not $report.PSObject.Properties["artifactRetention"] -or $null -eq $report.artifactRetention) {
            $report | Add-Member -NotePropertyName artifactRetention -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        foreach ($name in @("retainedResultArtifact", "retainedResultManifest", "retainedCapabilityManifest")) {
            if (-not $report.artifactRetention.PSObject.Properties[$name]) { $report.artifactRetention | Add-Member -NotePropertyName $name -NotePropertyValue "" }
        }
    }

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
    $cleanup = Invoke-SourceDeliveryPostSuccessCleanup -FreshProjectsRoot $FreshProjectsRoot -E2EProjectRoot $E2EProjectRoot -PreservePaths $preservePaths -Phase $Phase
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
    # Reused run filenames can leave earlier SHA-mismatched records in this
    # pass even after a later matching owner safely removes the file. Retire
    # those now-missing snapshot identities without another cleanup invocation.
    foreach ($resource in @($ledger.resources | Where-Object { [string]$_.kind -eq 'release-snapshot' -and [string]$_.state -eq 'cleanup-pending' })) {
        if (-not (Test-Path -LiteralPath ([string]$resource.identity.path))) {
            [void]$ledgerWarnings.Remove([string]$resource.lastError)
            $resource.state = 'removed'; $resource.lastError = ''
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
