[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("RegisterChange", "Status", "PublishDevelop", "ReleaseMaster")]
    [string]$Action,
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Remote = "origin",
    [string]$QueueId = "",
    [string]$BaseRef = "",
    [string[]]$CoverageContract = @(),
    [string]$AiRulesSource = "",
    [string]$E2EProjectRoot = "",
    [string]$GateScript = "",
    [string]$Version = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "git-path-list.ps1")

$script:Root = [System.IO.Path]::GetFullPath($RepositoryRoot)
$script:Remote = $Remote
$script:GateScript = if ($GateScript) { [System.IO.Path]::GetFullPath($GateScript) } else { Join-Path $script:Root "scripts\check.ps1" }
$script:QueueRoot = "refs/itl/develop-queue"

function Invoke-DeliveryGit {
    param([string[]]$Arguments, [switch]$AllowFailure, [AllowNull()][string]$StandardInput = $null)
    return Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure -StandardInput $StandardInput
}

function Get-GitValue {
    param([string[]]$Arguments)
    return (Invoke-DeliveryGit -Arguments $Arguments).stdout.Trim()
}

function Assert-CleanDeliveryWorktree {
    $status = (Invoke-DeliveryGit -Arguments @("status", "--porcelain", "--untracked-files=all")).stdout
    if ($status) { throw "Source delivery requires a clean worktree. Commit or move unrelated changes first." }
}

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

function Invoke-SourceGate {
    param([string]$Mode, [string]$WorkingRoot, [string]$TargetBaseRef = "")
    $gate = if ($script:GateScript -eq (Join-Path $script:Root "scripts\check.ps1")) { Join-Path $WorkingRoot "scripts\check.ps1" } else { $script:GateScript }
    if (-not (Test-Path -LiteralPath $gate -PathType Leaf)) { throw "Source gate was not found: $gate" }
    $arguments = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $gate, "-Mode", $Mode)
    if ($TargetBaseRef) { $arguments += @("-BaseRef", $TargetBaseRef) }
    $contracts = @($CoverageContract | Where-Object { $_ })
    if ($contracts.Count -gt 0) { $arguments += @("-CoverageContract", ($contracts -join ",")) }
    if ($AiRulesSource) { $arguments += @("-AiRulesSource", ([System.IO.Path]::GetFullPath($AiRulesSource))) }
    if ($E2EProjectRoot) { $arguments += @("-E2EProjectRoot", ([System.IO.Path]::GetFullPath($E2EProjectRoot))) }
    $quoted = @($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -notmatch '[\s"]') { $value } else { '"' + $value.Replace('"', '\"') + '"' }
    })
    $logRoot = Join-Path $WorkingRoot "build\test-results\delivery"
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    $stdout = Join-Path $logRoot ("gate-$($Mode.ToLowerInvariant()).stdout.log")
    $stderr = Join-Path $logRoot ("gate-$($Mode.ToLowerInvariant()).stderr.log")
    $gateStartedAt = [DateTime]::UtcNow
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($quoted -join " ") -WorkingDirectory $WorkingRoot -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $null = $process.Handle
    $hardSeconds = switch ($Mode) { "Targeted" { 900 } "Smoke" { 120 } "Full" { 1200 } "Develop" { 5400 } "Release" { 7200 } default { 1200 } }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastLength = -1L
    $lastProgress = [DateTime]::UtcNow
    while (-not $process.WaitForExit(5000)) {
        $length = 0L
        foreach ($path in @($stdout, $stderr)) { if (Test-Path $path) { $length += (Get-Item $path).Length } }
        if ($length -ne $lastLength) { $lastLength = $length; $lastProgress = [DateTime]::UtcNow }
        if ($watch.Elapsed.TotalSeconds -ge $hardSeconds -or ([DateTime]::UtcNow - $lastProgress).TotalMinutes -ge 15) {
            try { $process.Kill(); $process.WaitForExit() } catch {}
            throw "$Mode source gate exceeded its hard/no-progress budget. See $stdout and $stderr"
        }
    }
    $process.WaitForExit(); $process.Refresh(); $watch.Stop()
    if ([int]$process.ExitCode -ne 0) { throw "$Mode source gate failed with exit code $($process.ExitCode). See $stdout and $stderr" }
    if ($gate -eq (Join-Path $WorkingRoot "scripts\check.ps1")) {
        $summaryPath = Join-Path $WorkingRoot "build\test-results\local\check-summary.json"
        if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { throw "$Mode source gate returned without an authoritative check summary." }
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$summary.mode -ne $Mode -or [string]$summary.status -ne "passed" -or [DateTime]::Parse([string]$summary.finishedAt).ToUniversalTime() -lt $gateStartedAt.AddSeconds(-2)) {
            throw "$Mode source gate did not produce a fresh passed summary. See $summaryPath"
        }
    }
}

function Register-SourceChange {
    Assert-CleanDeliveryWorktree
    $head = Get-GitValue -Arguments @("rev-parse", "HEAD")
    $base = if ($BaseRef) { Get-GitValue -Arguments @("rev-parse", $BaseRef) } else { Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop") }
    $ancestor = Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $base, $head) -AllowFailure
    if ($ancestor.exitCode -ne 0) { throw "Queue base $base is not an ancestor of HEAD $head. Rebase the task on current develop." }
    if ($base -eq $head) { throw "There are no commits to register after $base." }

    $changed = @(Get-RepositoryGitPathList -RepositoryRoot $script:Root -Arguments @("diff", "--name-only", "-z", "$base...$head", "--"))
    $testChanged = @($changed | Where-Object { ([string]$_).Replace('\', '/') -like "tests/pester/*.Tests.ps1" }).Count -gt 0
    if (-not $testChanged -and @($CoverageContract | Where-Object { $_ }).Count -eq 0) {
        throw "Executable changes without a test change must declare an existing -CoverageContract. Registration was not created."
    }
    Invoke-SourceGate -Mode "Targeted" -WorkingRoot $script:Root -TargetBaseRef $base

    $id = ConvertTo-QueueRefName -Value $(if ($QueueId) { $QueueId } else { Get-DefaultQueueId })
    $baseQueueRef = "$script:QueueRoot/$id/base"
    $headQueueRef = "$script:QueueRoot/$id/head"
    $oldBase = (Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", $baseQueueRef) -AllowFailure).stdout.Trim()
    $oldHead = (Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", $headQueueRef) -AllowFailure).stdout.Trim()
    $commands = @()
    $commands += ("update $baseQueueRef $base" + $(if ($oldBase) { " $oldBase" } else { "" }))
    $commands += ("update $headQueueRef $head" + $(if ($oldHead) { " $oldHead" } else { "" }))
    Invoke-QueueRefTransaction -Commands $commands
    return [pscustomobject]@{ status = "registered"; id = $id; base = $base; head = $head; paths = $changed }
}

function New-DeliveryWorktree {
    param([string]$StartPoint, [string]$Purpose)
    $id = [guid]::NewGuid().ToString("N")
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-source-$Purpose-$id")
    $branch = "itl/$Purpose-$id"
    [void](Invoke-DeliveryGit -Arguments @("worktree", "add", "--quiet", "-b", $branch, $path, $StartPoint))
    return [pscustomobject]@{ path = $path; branch = $branch }
}

function Remove-DeliveryWorktree {
    param([object]$Worktree)
    if (-not $Worktree) { return }
    $resolved = [System.IO.Path]::GetFullPath([string]$Worktree.path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike "itl-source-*") {
        throw "Refusing to remove unexpected delivery worktree path: $resolved"
    }
    [void](Invoke-DeliveryGit -Arguments @("worktree", "remove", "--force", $resolved) -AllowFailure)
    [void](Invoke-DeliveryGit -Arguments @("branch", "-D", [string]$Worktree.branch) -AllowFailure)
}

function Invoke-WorktreeGit {
    param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
    return Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments -AllowFailure:$AllowFailure
}

function Get-DeliveryCommonGitDirectory {
    $value = Get-GitValue -Arguments @("rev-parse", "--git-common-dir")
    if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
    return [IO.Path]::GetFullPath((Join-Path $script:Root $value))
}

function Get-DeliveryQualificationCachePath {
    param([Parameter(Mandatory = $true)][string]$Tree)
    if ($Tree -notmatch '^[a-f0-9]{40}$') { throw "Invalid candidate tree for qualification cache: $Tree" }
    return Join-Path (Get-DeliveryCommonGitDirectory) ("itl\qualifications\" + $Tree)
}

function Save-DeliveryQualification {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot, [Parameter(Mandatory = $true)][string]$Tree)
    $source = Join-Path $CandidateRoot "build\test-results\qualification"
    foreach ($name in @("full.json", "develop.json", "develop-e2e-summary.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) { throw "Develop gate did not create reusable qualification file '$name'." }
    }
    $target = Get-DeliveryQualificationCachePath -Tree $Tree
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $staging = Join-Path $parent ("." + $Tree + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        Copy-Item -LiteralPath (Join-Path $source "full.json"), (Join-Path $source "develop.json"), (Join-Path $source "develop-e2e-summary.json") -Destination $staging -Force
        if (Test-Path -LiteralPath (Join-Path $source "pester.xml") -PathType Leaf) { Copy-Item -LiteralPath (Join-Path $source "pester.xml") -Destination $staging -Force }
        if (-not (Test-Path -LiteralPath $target)) { Move-Item -LiteralPath $staging -Destination $target }
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    return $target
}

function Restore-DeliveryQualification {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot, [Parameter(Mandatory = $true)][string]$Tree)
    $source = Get-DeliveryQualificationCachePath -Tree $Tree
    foreach ($name in @("full.json", "develop.json", "develop-e2e-summary.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) { return $false }
    }
    $target = Join-Path $CandidateRoot "build\test-results\qualification"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Get-ChildItem -LiteralPath $source -File | Copy-Item -Destination $target -Force
    return $true
}

function Add-QueuedRangesToCandidate {
    param([string]$CandidateRoot, [object[]]$Entries)
    foreach ($entry in @($Entries)) {
        $already = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge-base", "--is-ancestor", [string]$entry.head, "HEAD") -AllowFailure
        if ($already.exitCode -eq 0) { continue }
        $result = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--no-edit", [string]$entry.head) -AllowFailure
        if ($result.exitCode -ne 0) {
            [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--abort") -AllowFailure)
            throw "Queued range '$($entry.id)' conflicts with the develop candidate at $($entry.head). Resolve it in its source task and register again."
        }
    }
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

function Sync-LocalDevelopAfterPublish {
    $branch = Get-GitValue -Arguments @("branch", "--show-current")
    if ($branch -ne "develop") { return }
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $ff = Invoke-DeliveryGit -Arguments @("merge", "--ff-only", "$script:Remote/develop") -AllowFailure
    if ($ff.exitCode -ne 0) { throw "Remote develop was published, but local develop could not fast-forward. Inspect local-only commits before continuing." }
}

function Publish-AccumulatedDevelop {
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $remoteBefore = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $entries = @(Get-QueueEntries)
    if ($entries.Count -eq 0) { throw "There are no registered develop changes to publish." }

    $worktree = $null
    $deliverySucceeded = $false
    try {
        $worktree = New-DeliveryWorktree -StartPoint "$script:Remote/develop" -Purpose "publish-develop"
        Add-QueuedRangesToCandidate -CandidateRoot $worktree.path -Entries $entries
        Invoke-SourceGate -Mode "Develop" -WorkingRoot $worktree.path

        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $candidateTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        $push = Invoke-WorktreeGit -Root $worktree.path -Arguments @("push", $script:Remote, "HEAD:refs/heads/develop") -AllowFailure
        if ($push.exitCode -ne 0) { throw "origin/develop changed or rejected the fast-forward push. The queue is preserved; rebuild the candidate from the new remote head." }
        $remoteAfter = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("ls-remote", $script:Remote, "refs/heads/develop")).stdout.Split([char]9)[0].Trim()
        if ($remoteAfter -ne $candidate) { throw "Published develop verification failed: expected $candidate, remote reports $remoteAfter." }
        Clear-PublishedQueueEntries -PublishedCommit $candidate
        Sync-LocalDevelopAfterPublish
        $deliverySucceeded = $true
        return [pscustomobject]@{ status = "published"; branch = "develop"; commit = $candidate; tree = $candidateTree }
    } finally {
        $customGate = $script:GateScript -ne (Join-Path $script:Root "scripts\check.ps1")
        if ($deliverySucceeded -or $customGate) { Remove-DeliveryWorktree -Worktree $worktree }
        elseif ($worktree) { Write-Warning "Develop candidate was preserved for diagnosis and retry: $($worktree.path) (branch $($worktree.branch)). The queue is unchanged." }
    }
}

function Publish-ReleaseVersion {
    param([string]$Commit)
    if (-not $Version) { return }
    if ($Version -notmatch '^itl-workflow-v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "Version must look like itl-workflow-v1.2.3." }
    [void](Invoke-DeliveryGit -Arguments @("tag", "-a", $Version, $Commit, "-m", "ITL workflow $Version"))
    [void](Invoke-DeliveryGit -Arguments @("push", $script:Remote, "refs/tags/$Version"))
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "Tag $Version was published, but GitHub CLI is unavailable; create the GitHub Release explicitly." }
    & $gh.Source release create $Version --verify-tag --title $Version --generate-notes
    if ($LASTEXITCODE -ne 0) { throw "Tag $Version was published, but GitHub Release creation failed." }
}

function Assert-ReleaseVersionRequest {
    if (-not $Version) { return }
    if ($Version -notmatch '^itl-workflow-v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "Version must look like itl-workflow-v1.2.3." }
    if ((Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", "refs/tags/$Version") -AllowFailure).exitCode -eq 0) { throw "Local tag already exists: $Version" }
    if ((Invoke-DeliveryGit -Arguments @("ls-remote", "--exit-code", "--tags", $script:Remote, "refs/tags/$Version") -AllowFailure).exitCode -eq 0) { throw "Remote tag already exists: $Version" }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI is required before a versioned master release can start." }
}

function Release-DevelopToMaster {
    Assert-ReleaseVersionRequest
    Assert-CleanDeliveryWorktree
    if (@(Get-QueueEntries).Count -gt 0) { throw "ReleaseMaster requires an empty develop queue. Publish accumulated develop changes first." }
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop", "master"))
    $localDevelop = Get-GitValue -Arguments @("rev-parse", "develop")
    $remoteDevelop = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $remoteMaster = Get-GitValue -Arguments @("rev-parse", "$script:Remote/master")
    if ($localDevelop -ne $remoteDevelop) { throw "Local develop must equal origin/develop before ReleaseMaster." }

    $worktree = $null
    $deliverySucceeded = $false
    try {
        $worktree = New-DeliveryWorktree -StartPoint "$script:Remote/develop" -Purpose "release-master"
        $masterAncestor = Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge-base", "--is-ancestor", "$script:Remote/master", "HEAD") -AllowFailure
        if ($masterAncestor.exitCode -ne 0) {
            $merge = Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge", "--no-ff", "--no-edit", "$script:Remote/master") -AllowFailure
            if ($merge.exitCode -ne 0) {
                [void](Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge", "--abort") -AllowFailure)
                throw "origin/master conflicts with develop. Resolve the release reconciliation on develop and publish it first."
            }
        }
        $candidateTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        if (-not (Restore-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)) {
            Invoke-SourceGate -Mode "Develop" -WorkingRoot $worktree.path
            [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        }
        Invoke-SourceGate -Mode "Release" -WorkingRoot $worktree.path
        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        foreach ($oldHead in @($remoteDevelop, $remoteMaster)) {
            if ((Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge-base", "--is-ancestor", $oldHead, $candidate) -AllowFailure).exitCode -ne 0) {
                throw "Release candidate does not contain both fetched remote branch histories. Nothing was published."
            }
        }
        $push = Invoke-WorktreeGit -Root $worktree.path -Arguments @("push", "--atomic", $script:Remote, "HEAD:refs/heads/develop", "HEAD:refs/heads/master") -AllowFailure
        if ($push.exitCode -ne 0) { throw "Release candidate passed, but the atomic develop/master fast-forward push was rejected. Neither branch was published and no force push was attempted." }
        foreach ($branch in @("develop", "master")) {
            $remoteCommit = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("ls-remote", $script:Remote, "refs/heads/$branch")).stdout.Split([char]9)[0].Trim()
            if ($remoteCommit -ne $candidate) { throw "Remote $branch verification failed after release." }
            $remoteTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "$remoteCommit^{tree}")).stdout.Trim()
            if ($remoteTree -ne $candidateTree) { throw "Remote $branch tree verification failed after release." }
        }
        Publish-ReleaseVersion -Commit $candidate
        Sync-LocalDevelopAfterPublish
        $deliverySucceeded = $true
        return [pscustomobject]@{ status = "released"; commit = $candidate; tree = $candidateTree; version = $Version }
    } finally {
        $customGate = $script:GateScript -ne (Join-Path $script:Root "scripts\check.ps1")
        if ($deliverySucceeded -or $customGate) { Remove-DeliveryWorktree -Worktree $worktree }
        elseif ($worktree) { Write-Warning "Release candidate was preserved for diagnosis and retry: $($worktree.path) (branch $($worktree.branch)). No force push was attempted." }
    }
}

[void](Invoke-DeliveryGit -Arguments @("rev-parse", "--git-dir"))
$result = switch ($Action) {
    "RegisterChange" { Register-SourceChange }
    "Status" { [pscustomobject]@{ status = "ok"; queue = @(Get-QueueEntries) } }
    "PublishDevelop" { Publish-AccumulatedDevelop }
    "ReleaseMaster" { Release-DevelopToMaster }
}
$result | ConvertTo-Json -Depth 8
