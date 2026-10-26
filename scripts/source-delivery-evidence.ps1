# Retention belongs to the existing source-delivery owner and manual operation lease.
# Only bulky recovery payloads expire; proof, indexes and test evidence stay intact.
function Get-DeliveryRecoveryPolicy {
    $common = Get-DeliveryCommonGitDirectory
    $envPath = Join-Path $script:Root '.dev.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        $envPath = Join-Path (Split-Path -Parent $common) '.dev.env'
    }
    $values = @{}
    if (Test-Path -LiteralPath $envPath -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $envPath -Encoding UTF8) {
            if ($line -match '^\s*(ITL_SOURCE_RECOVERY_(?:RETENTION_DAYS|KEEP_COUNT))\s*=\s*["'']?(\d+)["'']?\s*(?:#.*)?$') {
                $values[$matches[1]] = $matches[2]
            } elseif ($line -match '^\s*ITL_SOURCE_RECOVERY_(RETENTION_DAYS|KEEP_COUNT)\s*=') {
                throw 'Invalid source recovery retention setting in .dev.env; use nonnegative integers.'
            }
        }
    }
    $settings = @{}
    foreach ($setting in @(@('RETENTION_DAYS', 7), @('KEEP_COUNT', 2))) {
        $name = 'ITL_SOURCE_RECOVERY_' + $setting[0]
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ([string]::IsNullOrEmpty($value)) { $value = if ($values.ContainsKey($name)) { $values[$name] } else { [string]$setting[1] } }
        $number = 0
        if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 0) { throw "Invalid $name; use a nonnegative integer." }
        $settings[$setting[0]] = $number
    }
    return [pscustomobject]@{ retentionDays=$settings.RETENTION_DAYS; keepCount=$settings.KEEP_COUNT; envPath=$envPath }
}

function Get-DeliveryRecoveryFiles {
    param([string]$Path, [string]$CommonGit)
    # Check ancestors before walking. Get-ChildItem -Recurse must never follow a link.
    $common = [IO.Path]::GetFullPath($CommonGit).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (-not $full.StartsWith($common + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Recovery path escapes common Git.' }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery path contains a reparse point.' }
        }
        if ($cursor -ieq $common) { break }
        $cursor = Split-Path -Parent $cursor
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($full)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery tree contains a reparse point.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $item }
        }
    }
}

function Get-DeliveryRecoveryReferences {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        if ([IO.Path]::IsPathRooted($Value)) { [IO.Path]::GetFullPath($Value).TrimEnd('\', '/') }
    } elseif ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { Get-DeliveryRecoveryReferences $Value[$key] }
    } elseif ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) { Get-DeliveryRecoveryReferences $item }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) { Get-DeliveryRecoveryReferences $property.Value }
    }
}

function Get-DeliveryRecoveryGuards {
    param([string]$CommonGit)
    $references = [Collections.Generic.List[string]]::new()
    # A resumable publication can own inputs outside its live process. Preserve
    # archives until that existing owner closes the attempt, even after failure.
    $attemptRoot = Join-Path $CommonGit 'itl/publication-attempts'
    if (Test-Path -LiteralPath $attemptRoot) {
        if (@(Get-ChildItem -LiteralPath $attemptRoot -File -Force -ErrorAction Stop).Count) {
            return [pscustomobject]@{ reason='publication-attempt-present'; references=@() }
        }
    }
    $operation = Get-DeliveryOperationStatus
    if (-not $operation -and (Test-Path -LiteralPath (Join-Path $CommonGit 'itl/delivery-operation'))) {
        return [pscustomobject]@{ reason='delivery-operation-unreadable'; references=@() }
    }
    if ($operation -and ($operation.action -ne 'Cleanup' -or $operation.ownerPid -ne $PID)) {
        return [pscustomobject]@{ reason='delivery-operation-present'; references=@() }
    }
    $ledgerPath = Join-Path $CommonGit 'itl/resources/v1/ledger.json'
    if (Test-Path -LiteralPath $ledgerPath) {
        $ledger = Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $ledger.PSObject.Properties['resources'] -or [int]$ledger.schemaVersion -ne 1) { throw 'Unknown resource ledger.' }
        foreach ($resource in @($ledger.resources)) {
            if ([string]$resource.state -ne 'removed') {
                foreach ($path in @(Get-DeliveryRecoveryReferences $resource.identity)) { $references.Add($path) }
            }
        }
    }
    $planRoot = Join-Path $CommonGit 'itl/plans/v1'
    if (Test-Path -LiteralPath $planRoot) {
        foreach ($file in @(Get-DeliveryRecoveryFiles -Path $planRoot -CommonGit $CommonGit | Where-Object Name -like '*checkpoint*.json')) {
            $checkpoint = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($path in @(Get-DeliveryRecoveryReferences $checkpoint)) { $references.Add($path) }
        }
    }
    return [pscustomobject]@{ reason=''; references=@($references) }
}

function Get-DeliveryRecoveryInventory {
    param([switch]$IncludeEntries)
    $common = Get-DeliveryCommonGitDirectory
    $root = Join-Path $common 'itl/evidence/fixture-cleanup'
    $entries = [Collections.Generic.List[object]]::new()
    $warnings = @()
    $policy = $null
    try { $policy = Get-DeliveryRecoveryPolicy; $guards = Get-DeliveryRecoveryGuards -CommonGit $common }
    catch { $guards = [pscustomobject]@{ reason='guard-unavailable'; references=@() }; $warnings += $_.Exception.Message }
    try { if (Test-Path -LiteralPath $root) {
        # Validate the namespace itself before enumerating children.
        $null = @(Get-DeliveryRecoveryFiles -Path $root -CommonGit $common | Select-Object -First 1)
        foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop) {
            $entry = [pscustomobject][ordered]@{ path=$directory.FullName; phase=''; disposition='keep'; reason='ownership-unverified'; bytes=0L; lastWriteUtc=$null; copyRoots=@(); proofHashes=@(); payloads=@() }
            $entries.Add($entry)
            try {
                if ($directory.Name -notmatch '^(develop|release)-[0-9a-f]{12}-([0-9a-f]{12})(?:-[0-9a-f]{8})?$') { continue }
                $phase = $matches[1]; $candidatePrefix = $matches[2]
                $files = @(Get-DeliveryRecoveryFiles -Path $directory.FullName -CommonGit $common)
                $payloads = @($files | Where-Object { $_.Name -in @('recovery.zip','source.bundle','branch-working.patch','project-working.patch') -and
                    $_.DirectoryName -in @($directory.FullName, (Join-Path $directory.FullName 'archived-inactive')) })
                foreach ($payload in $payloads) { $entry.bytes += $payload.Length }
                if (-not $payloads.Count) { $entry.reason='no-recovery-payload'; continue }
                $proofs = @($files | Where-Object { $_.Name -eq 'cleanup-proof.json' -and $_.DirectoryName -in @($directory.FullName, (Join-Path $directory.FullName 'archived-inactive')) })
                if (-not $proofs.Count) { continue }
                $copyRoots = @()
                foreach ($proofFile in $proofs) {
                    $proof = Get-Content -LiteralPath $proofFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$proof.kind -cne 'itl-fixture-copy-cleanup-proof' -or
                        [string]$proof.candidateCommit -notmatch '^[0-9a-f]{40}$' -or -not ([string]$proof.candidateCommit).StartsWith($candidatePrefix) -or
                        [IO.Path]::GetFullPath([string]$proof.workflowCommonGit).TrimEnd('\','/') -ine $common.TrimEnd('\','/') -or
                        [string]$proof.reason -notin @('archive-inactive-qualification','incomplete-develop-factory','passed-negative','passed-positive') -or
                        -not [IO.Path]::IsPathRooted([string]$proof.copyRoot) -or (Split-Path -Leaf ([string]$proof.copyRoot)) -ine $directory.Name) { throw 'Recovery proof ownership mismatch.' }
                    $copyRoots += [IO.Path]::GetFullPath([string]$proof.copyRoot).TrimEnd('\','/')
                    $entry.proofHashes += Get-DeliveryFileSha256 -Path $proofFile.FullName
                }
                $entry.phase = $phase
                $entry.copyRoots = $copyRoots
                $entry.lastWriteUtc = ($files | Where-Object Name -ne 'retention.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
                $entry.payloads = @($payloads | ForEach-Object { [pscustomobject]@{ path=$_.FullName; bytes=$_.Length; ticks=$_.LastWriteTimeUtc.Ticks } })
                if (@($copyRoots | Where-Object { Test-Path -LiteralPath $_ }).Count) { $entry.reason='original-copy-present'; continue }
                if ($guards.reason) { $entry.reason=$guards.reason; continue }
                $protected = $false
                foreach ($path in @($guards.references)) {
                    foreach ($target in @($directory.FullName) + $copyRoots) {
                        if ($path -ieq $target -or $path.StartsWith($target + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                            $target.StartsWith($path + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $protected=$true }
                    }
                }
                if ($protected) { $entry.reason='owner-or-checkpoint-reference'; continue }
                if ($policy.retentionDays -eq 0) { $entry.reason='retention-disabled'; continue }
                if ($entry.lastWriteUtc -gt [DateTime]::UtcNow.AddDays(-$policy.retentionDays)) { $entry.reason='within-retention'; continue }
                $entry.disposition='eligible'; $entry.reason='expired-recovery-payload'
            } catch { $entry.reason='ownership-or-tree-unverified'; $warnings += "$($directory.Name): $($_.Exception.Message)" }
        }
        # Quota includes all owned archives, including currently protected ones.
        if ($policy) {
            foreach ($phase in @('develop','release')) {
                foreach ($entry in @($entries | Where-Object { $_.phase -eq $phase -and $_.payloads.Count } | Sort-Object lastWriteUtc -Descending | Select-Object -First $policy.keepCount)) {
                    if ($entry.disposition -eq 'eligible') { $entry.disposition='keep'; $entry.reason='newest-recovery-quota' }
                }
            }
        }
    } } catch { $warnings += $_.Exception.Message; foreach ($entry in $entries) { $entry.disposition='keep'; $entry.reason='inventory-unavailable' } }
    $eligible = @($entries | Where-Object disposition -eq 'eligible')
    [int64]$eligibleBytes=0; [int64]$keptBytes=0
    foreach ($entry in $entries) {
        if ($entry.disposition -eq 'eligible') { $eligibleBytes += $entry.bytes } else { $keptBytes += $entry.bytes }
    }
    return [pscustomobject][ordered]@{ readOnly=$true; policy=$policy; root=$root; warnings=$warnings; total=$entries.Count;
        eligible=$eligible.Count; eligibleBytes=$eligibleBytes; keptBytes=$keptBytes;
        entries=@($entries | Where-Object { $IncludeEntries }) }
}

function Write-DeliveryRecoveryReceipt {
    param([string]$Path, [object]$Policy, [object[]]$Files)
    $receipt = [ordered]@{ schemaVersion=1; kind='itl-source-recovery-retention'; policy=$Policy; files=@($Files) }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Invoke-DeliveryRecoveryCleanup {
    [void](Assert-DeliveryManualCleanupLease)
    $result = [ordered]@{ status='completed'; removedFiles=0; freedBytes=0L; warnings=@(); entries=@() }
    # Never consume a previously displayed inventory. Recompute under the lease.
    $inventory = Get-DeliveryRecoveryInventory -IncludeEntries
    $result.warnings = @($inventory.warnings)
    foreach ($entry in @($inventory.entries | Where-Object disposition -eq 'eligible')) {
        $streams = @{}
        try {
            [void](Assert-DeliveryManualCleanupLease)
            $fresh = Get-DeliveryRecoveryInventory -IncludeEntries
            $current = @($fresh.entries | Where-Object { $_.path -ieq $entry.path -and $_.disposition -eq 'eligible' })
            if ($current.Count -ne 1 -or
                ($current[0].payloads | ConvertTo-Json -Compress) -cne ($entry.payloads | ConvertTo-Json -Compress) -or
                ($current[0].proofHashes -join ',') -cne ($entry.proofHashes -join ',')) { throw 'Recovery inventory changed; repeat Cleanup.' }
            $receiptPath = Join-Path $entry.path 'retention.json'
            $records = @()
            if (Test-Path -LiteralPath $receiptPath) {
                $prior = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$prior.kind -cne 'itl-source-recovery-retention') { throw 'Unknown retention receipt.' }
                $records = @($prior.files)
            }
            # Admit the complete recovery set before deleting any part. A reader
            # of source.bundle also protects its matching ZIP and patches.
            foreach ($payload in $entry.payloads) {
                $stream = [IO.File]::Open($payload.path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Delete)
                $streams[$payload.path] = $stream
                $item = Get-Item -LiteralPath $payload.path -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $stream.Length -ne $payload.bytes -or $item.LastWriteTimeUtc.Ticks -ne $payload.ticks) { throw 'Recovery payload changed; repeat Cleanup.' }
            }
            foreach ($payload in $entry.payloads) {
                $stream = $null; $sha = $null
                try {
                    # Share only deletion: existing/new readers and writers prevent
                    # admission. Delete the exact payload while this handle is held;
                    # no recursive directory removal or process termination is used.
                    $stream = $streams[$payload.path]
                    $item = Get-Item -LiteralPath $payload.path -Force
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $stream.Length -ne $payload.bytes -or $item.LastWriteTimeUtc.Ticks -ne $payload.ticks) { throw 'Recovery payload changed; repeat Cleanup.' }
                    $sha = [Security.Cryptography.SHA256]::Create()
                    $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
                    $records = @($records | Where-Object path -ine $payload.path)
                    $record = [pscustomobject]@{ path=$payload.path; bytes=$payload.bytes; sha256=$hash; status='pending'; expiredAt=[DateTime]::UtcNow.ToString('o') }
                    $records += $record
                    Write-DeliveryRecoveryReceipt -Path $receiptPath -Policy $inventory.policy -Files $records
                    [void](Assert-DeliveryManualCleanupLease)
                    $guard = Get-DeliveryRecoveryGuards -CommonGit (Get-DeliveryCommonGitDirectory)
                    if ($guard.reason) { throw 'Recovery guard changed; repeat Cleanup.' }
                    if (@($entry.copyRoots | Where-Object { Test-Path -LiteralPath $_ }).Count) { throw 'Original copy reappeared; repeat Cleanup.' }
                    $currentPolicy = Get-DeliveryRecoveryPolicy
                    if ($currentPolicy.retentionDays -ne $inventory.policy.retentionDays -or $currentPolicy.keepCount -ne $inventory.policy.keepCount) { throw 'Retention policy changed; repeat Cleanup.' }
                    # Recheck directory/link ownership after the potentially long hash.
                    $null = @(Get-DeliveryRecoveryFiles -Path $entry.path -CommonGit (Get-DeliveryCommonGitDirectory))
                    # A reference acquired during hashing protects this payload too.
                    foreach ($path in @($guard.references)) {
                        foreach ($target in @($entry.path) + @($entry.copyRoots)) {
                            if ($path -ieq $target -or $path.StartsWith($target + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                                $target.StartsWith($path + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Recovery owner reference changed; repeat Cleanup.' }
                        }
                    }
                    [IO.File]::Delete($payload.path)
                    $result.removedFiles++; $result.freedBytes += $payload.bytes
                    $record.status='removed'
                    Write-DeliveryRecoveryReceipt -Path $receiptPath -Policy $inventory.policy -Files $records
                } finally { if ($sha) { $sha.Dispose() } }
            }
            $result.entries += [pscustomobject]@{ path=$entry.path; receipt=$receiptPath }
        } catch { $result.warnings += "$($entry.path): $($_.Exception.Message)" }
        finally { foreach ($handle in $streams.Values) { $handle.Dispose() } }
    }
    if ($result.warnings.Count) { $result.status='completed-with-warnings' }
    return [pscustomobject]$result
}
