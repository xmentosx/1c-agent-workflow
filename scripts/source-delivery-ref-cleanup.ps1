# Manual, compare-and-swap cleanup for published source-delivery refs.

function Assert-DeliveryManualCleanupLease {
    $activeVariable = Get-Variable -Name ActiveOperation -Scope Script -ErrorAction SilentlyContinue
    $active = if ($activeVariable) { $activeVariable.Value } else { $null }
    if (-not $active -or [string]$active.action -cne 'Cleanup') {
        throw 'Ref cleanup requires the active manual Cleanup delivery-operation lease.'
    }

    $persisted = Read-DeliveryOperation
    if (-not $persisted -or [int]$persisted.schemaVersion -ne 1 -or
        -not [string]$persisted.id -or [string]$persisted.id -cne [string]$active.id -or
        [string]$persisted.action -cne 'Cleanup' -or [int]$persisted.ownerPid -ne $PID -or
        [string]$persisted.ownerProcessStartedAt -cne [string]$active.ownerProcessStartedAt -or
        -not (Test-DeliveryProcessIdentity -ProcessId ([int]$persisted.ownerPid) -StartedAt $persisted.ownerProcessStartedAt)) {
        throw 'The manual Cleanup delivery-operation lease is missing, changed, or owned by another process.'
    }
    return $persisted
}

function Get-DeliveryRefCleanupSnapshot {
    $result = Invoke-DeliveryGit -Arguments @(
        'for-each-ref', '--format=%(refname)%09%(objectname)%09%(symref)',
        'refs/itl/develop-queue/', 'refs/itl/develop-promotions/'
    )
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($line in @($result.stdout -split '\r?\n' | Where-Object { $_ })) {
        $parts = $line.Split([char]9)
        if ($parts.Count -ne 3) { throw 'Owned ref snapshot contains an unparseable record.' }
        $entries.Add([pscustomobject]@{
            name = [string]$parts[0]
            sha = [string]$parts[1]
            symbolicTarget = [string]$parts[2]
        }) | Out-Null
    }
    return @($entries | Sort-Object name)
}

function New-DeliveryRefCleanupBlockedPlan {
    param([Parameter(Mandatory = $true)][string]$Reason)
    return [pscustomobject][ordered]@{
        status = 'blocked'
        reason = $Reason
        attemptFingerprint = ''
        deletes = @()
    }
}

function Get-DeliveryRefCleanupPlan {
    [void](Assert-DeliveryManualCleanupLease)
    $attemptBefore = Get-DeliveryDispositionPublicationAttempt
    $initialSnapshot = @(Get-DeliveryRefCleanupSnapshot)
    if ($initialSnapshot.Count -eq 0) {
        return [pscustomobject][ordered]@{
            status = 'ready'
            reason = ''
            attemptFingerprint = [string]$attemptBefore.fingerprint
            deletes = @()
        }
    }
    $refsBefore = Get-DeliveryOwnedRefSnapshot
    $publishedState = Get-DeliveryAuthoritativePublishedTips
    $attemptState = Get-DeliveryDispositionPublicationAttempt
    $refsAfter = Get-DeliveryOwnedRefSnapshot
    $attemptStable = [string]$attemptBefore.fingerprint -ceq [string]$attemptState.fingerprint
    $refsStable = [string]$refsBefore.fingerprint -ceq [string]$refsAfter.fingerprint
    if (-not $attemptStable -or -not $refsStable) {
        return New-DeliveryRefCleanupBlockedPlan -Reason 'disposition-snapshot-unstable'
    }
    if ([string]$publishedState.status -cne 'available') {
        return New-DeliveryRefCleanupBlockedPlan -Reason 'authoritative-publication-evidence-unavailable'
    }
    $reportRefs = @(Get-DeliveryRefDispositions -WorktreeEntries @() -AttemptState $attemptState -PublishedState $publishedState -RefState $refsAfter -AttemptSnapshotStable:$attemptStable -RefSnapshotStable:$refsStable)

    $snapshot = @(Get-DeliveryRefCleanupSnapshot)
    $snapshotByName = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $snapshot) {
        if ($snapshotByName.ContainsKey([string]$entry.name)) {
            return New-DeliveryRefCleanupBlockedPlan -Reason 'duplicate-owned-ref'
        }
        $snapshotByName[[string]$entry.name] = $entry
    }

    $deletes = [Collections.Generic.List[object]]::new()
    $queueRefs = @($reportRefs | Where-Object { [string]$_.identity -clike 'refs/itl/develop-queue/*' })
    $queueGroups = @($queueRefs | Group-Object {
        if ([string]$_.identity -cmatch '^refs/itl/develop-queue/(.+)/(base|head)$') { $Matches[1] } else { [string]$_.identity }
    })
    foreach ($group in $queueGroups) {
        $eligible = @($group.Group | Where-Object { [string]$_.disposition -ceq 'eligible' })
        if ($eligible.Count -eq 0) { continue }
        $base = @($group.Group | Where-Object { [string]$_.identity -cmatch '/base$' })
        $head = @($group.Group | Where-Object { [string]$_.identity -cmatch '/head$' })
        $id = [string]$group.Name
        $canonicalId = try { ConvertTo-QueueRefName -Value $id } catch { '' }
        if ($group.Group.Count -ne 2 -or $eligible.Count -ne 2 -or $base.Count -ne 1 -or $head.Count -ne 1 -or $canonicalId -cne $id) {
            return New-DeliveryRefCleanupBlockedPlan -Reason 'eligible-queue-ownership-ambiguous'
        }
        foreach ($candidate in @($base[0], $head[0])) {
            $name = [string]$candidate.identity
            $expectedSha = [string]$candidate.expectedSha
            if ($name -cnotmatch '^refs/itl/develop-queue/[a-z0-9][a-z0-9._/-]*/(base|head)$' -or $expectedSha -cnotmatch '^[a-f0-9]{40}$' -or
                -not $snapshotByName.ContainsKey($name) -or [string]$snapshotByName[$name].sha -cne $expectedSha -or
                [string]$snapshotByName[$name].symbolicTarget) {
                return New-DeliveryRefCleanupBlockedPlan -Reason 'eligible-queue-ref-changed-or-indirect'
            }
            $deletes.Add([pscustomobject]@{ kind='queue'; name=$name; expectedSha=$expectedSha }) | Out-Null
        }
    }

    foreach ($candidate in @($reportRefs | Where-Object {
        [string]$_.disposition -ceq 'eligible' -and [string]$_.identity -clike 'refs/itl/develop-promotions/*'
    })) {
        $name = [string]$candidate.identity
        $expectedSha = [string]$candidate.expectedSha
        if ($name -cnotmatch '^refs/itl/develop-promotions/[a-f0-9]{64}$' -or $expectedSha -cnotmatch '^[a-f0-9]{40}$' -or
            -not $snapshotByName.ContainsKey($name) -or [string]$snapshotByName[$name].sha -cne $expectedSha -or
            [string]$snapshotByName[$name].symbolicTarget) {
            return New-DeliveryRefCleanupBlockedPlan -Reason 'eligible-promotion-ref-changed-or-indirect'
        }
        $deletes.Add([pscustomobject]@{ kind='promotion'; name=$name; expectedSha=$expectedSha }) | Out-Null
    }

    $unexpectedEligible = @($reportRefs | Where-Object {
        [string]$_.disposition -ceq 'eligible' -and
        [string]$_.identity -cnotlike 'refs/itl/develop-queue/*' -and
        [string]$_.identity -cnotlike 'refs/itl/develop-promotions/*'
    })
    if ($unexpectedEligible.Count -gt 0) {
        return New-DeliveryRefCleanupBlockedPlan -Reason 'eligible-ref-outside-cleanup-allowlist'
    }

    return [pscustomobject][ordered]@{
        status = 'ready'
        reason = ''
        attemptFingerprint = [string]$attemptState.fingerprint
        deletes = @($deletes | Sort-Object name)
    }
}

function Invoke-DeliveryRefCasTransaction {
    [void](Assert-DeliveryManualCleanupLease)
    $plan = Get-DeliveryRefCleanupPlan
    if ([string]$plan.status -cne 'ready') {
        return [pscustomobject]@{ status='blocked'; error=[string]$plan.reason; deletes=@() }
    }
    $deletes = @($plan.deletes)
    if ($deletes.Count -eq 0) { return [pscustomobject]@{ status='unchanged'; error=''; deletes=@() } }

    $attempt = Get-DeliveryDispositionPublicationAttempt
    if ([string]$attempt.fingerprint -cne [string]$plan.attemptFingerprint) {
        return [pscustomobject]@{ status='blocked'; error='publication-attempt-changed-before-cas'; deletes=@() }
    }

    $commands = [Collections.Generic.List[string]]::new()
    $commands.Add('start') | Out-Null
    foreach ($entry in $deletes) {
        $name = [string]$entry.name
        $expectedSha = [string]$entry.expectedSha
        $allowed = $name -cmatch '^refs/itl/develop-promotions/[a-f0-9]{64}$' -or
            $name -cmatch '^refs/itl/develop-queue/[a-z0-9][a-z0-9._/-]*/(base|head)$'
        if (-not $allowed -or $expectedSha -cnotmatch '^[a-f0-9]{40}$') {
            throw 'Ref cleanup plan contains a ref outside the exact mutation allowlist.'
        }
        $commands.Add("delete $name $expectedSha") | Out-Null
    }
    $commands.Add('prepare') | Out-Null
    $commands.Add('commit') | Out-Null
    $payload = (($commands -join "`n") + "`n")
    $result = Invoke-DeliveryGit -Arguments @('update-ref', '--no-deref', '--stdin') -StandardInput $payload -AllowFailure
    if ([int]$result.exitCode -ne 0) {
        return [pscustomobject]@{ status='blocked'; error='expected-sha-cas-failed'; deletes=@() }
    }
    return [pscustomobject]@{ status='completed'; error=''; deletes=$deletes }
}

function Invoke-DeliveryRefDispositionCleanup {
    [void](Assert-DeliveryManualCleanupLease)
    $transaction = Invoke-DeliveryRefCasTransaction
    if ([string]$transaction.status -eq 'unchanged') {
        return [pscustomobject][ordered]@{ status='unchanged'; reason='no-eligible-refs'; removed=@() }
    }
    if ([string]$transaction.status -ne 'completed') {
        return [pscustomobject][ordered]@{ status='needs-attention'; reason=[string]$transaction.error; removed=@() }
    }
    return [pscustomobject][ordered]@{
        status='completed'
        reason='expected-sha-cas-committed'
        removed=@($transaction.deletes | ForEach-Object { [pscustomobject]@{ kind=[string]$_.kind; ref=[string]$_.name; expectedSha=[string]$_.expectedSha } })
    }
}
