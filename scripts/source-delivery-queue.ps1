# Queue registration and atomic shared-ref transactions for source delivery.

function ConvertTo-QueueRefName {
    param([string]$Value)
    $name = $Value.Trim().Replace('\', '/').ToLowerInvariant()
    $name = [regex]::Replace($name, '[^a-z0-9._/-]+', '-')
    $name = [regex]::Replace($name, '/+', '/')
    $name = $name.Trim('/', '.', '-')
    if (-not $name) { throw "Queue id cannot be converted to a safe Git ref name." }
    return $name
}

function Get-DefaultQueueId {
    $branch = Get-GitValue -Arguments @("branch", "--show-current")
    if ($branch) { return $branch }
    return "detached-" + (Get-GitValue -Arguments @("rev-parse", "--short=12", "HEAD"))
}

function Invoke-QueueRefTransaction {
    param([string[]]$Commands)
    $payload = (($Commands -join "`n") + "`n")
    [void](Invoke-DeliveryGit -Arguments @("update-ref", "--stdin") -StandardInput $payload)
}

function Get-QueueEntries {
    $result = Invoke-DeliveryGit -Arguments @("for-each-ref", "--format=%(refname) %(objectname)", "$script:QueueRoot/")
    $records = @{}
    foreach ($line in @($result.stdout -split "`r?`n" | Where-Object { $_ })) {
        $parts = $line.Split(' ', 2)
        $ref = [string]$parts[0]
        $sha = [string]$parts[1]
        if ($ref -notmatch ('^' + [regex]::Escape($script:QueueRoot) + '/(.+)/(base|head)$')) { continue }
        $id = $Matches[1]
        $kind = $Matches[2]
        if (-not $records.ContainsKey($id)) { $records[$id] = [ordered]@{ id = $id; base = ""; head = "" } }
        $records[$id][$kind] = $sha
    }
    return @($records.Values | Where-Object { $_.base -and $_.head } | Sort-Object id | ForEach-Object { [pscustomobject]$_ })
}

function Clear-PublishedQueueEntries {
    param([string]$PublishedCommit)
    $commands = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-QueueEntries)) {
        $reachable = Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", [string]$entry.head, $PublishedCommit) -AllowFailure
        if ($reachable.exitCode -eq 0) {
            $commands.Add("delete $script:QueueRoot/$($entry.id)/base $($entry.base)") | Out-Null
            $commands.Add("delete $script:QueueRoot/$($entry.id)/head $($entry.head)") | Out-Null
        }
    }
    if ($commands.Count -gt 0) { Invoke-QueueRefTransaction -Commands @($commands) }
}

function Register-SourceChange {
    Assert-CleanDeliveryWorktree
    $head = Get-GitValue -Arguments @("rev-parse", "HEAD")
    $base = if ($BaseRef) { Get-GitValue -Arguments @("rev-parse", $BaseRef) } else { Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop") }
    $id = ConvertTo-QueueRefName -Value $(if ($QueueId) { $QueueId } else { Get-DefaultQueueId })
    $baseQueueRef = "$script:QueueRoot/$id/base"
    $headQueueRef = "$script:QueueRoot/$id/head"
    $oldBase = (Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", $baseQueueRef) -AllowFailure).stdout.Trim()
    $oldHead = (Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", $headQueueRef) -AllowFailure).stdout.Trim()
    if ([bool]$oldBase -ne [bool]$oldHead) { throw "Queue $id has incomplete base/head refs. Repair the shared queue before registering another change." }

    if ($oldHead) {
        if ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $oldBase, $oldHead) -AllowFailure).exitCode -ne 0) {
            throw "Queue $id is corrupt: its base $oldBase is not an ancestor of its head $oldHead. Repair the shared queue before registering another change."
        }
        if ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $oldHead, $head) -AllowFailure).exitCode -ne 0) {
            throw "Existing queue head $oldHead is not an ancestor of HEAD $head. Continue the same QueueId from its registered head or use a different QueueId."
        }
    } elseif ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $base, $head) -AllowFailure).exitCode -ne 0) {
        throw "Queue base $base is not an ancestor of HEAD $head. Rebase the task on current develop."
    }
    $targetBase = if ($oldHead) { $oldHead } else { $base }
    if ($targetBase -eq $head) { throw "There are no commits to register after $targetBase." }

    $changed = @(Get-RepositoryGitPathList -RepositoryRoot $script:Root -Arguments @("diff", "--name-only", "-z", "$targetBase...$head", "--"))
    $testChanged = @($changed | Where-Object { ([string]$_).Replace('\', '/') -like "tests/pester/*.Tests.ps1" }).Count -gt 0
    if (-not $testChanged -and @($CoverageContract | Where-Object { $_ }).Count -eq 0) {
        throw "Executable changes without a test change must declare an existing -CoverageContract. Registration was not created."
    }
    Invoke-SourceGate -Mode "Targeted" -WorkingRoot $script:Root -TargetBaseRef $targetBase

    $queueBase = if ($oldBase) { $oldBase } else { $base }
    $commands = @()
    $commands += ("update $baseQueueRef $queueBase" + $(if ($oldBase) { " $oldBase" } else { "" }))
    $commands += ("update $headQueueRef $head" + $(if ($oldHead) { " $oldHead" } else { "" }))
    Invoke-QueueRefTransaction -Commands $commands
    return [pscustomobject]@{ status = "registered"; id = $id; base = $queueBase; head = $head; paths = $changed }
}
