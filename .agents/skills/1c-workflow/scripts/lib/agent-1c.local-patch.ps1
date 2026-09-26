# Loaded only by explicit patch capture/sealing and update/refresh retirement.
function Get-WorkflowPatchHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Resolve-WorkflowPatchPath {
    param([string]$RelativePath, [switch]$Receipt)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '[\\:]|(^|/)\.\.?(/|$)|//|[\x00-\x1f]' -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "WORKFLOW_PATCH_PATH_INVALID: $RelativePath"
    }
    if (-not $Receipt -and $RelativePath -notmatch '^\.agents/skills/(1c-workflow|1c-workflow-fast|itl-performance|itl-remote-runner|itl-remote-agent|itl-roctup-1c-data|itl-vanessa-ui-mcp|product-docs)/.+\.(ps1|md|py|json)$') {
        throw "WORKFLOW_PATCH_NOT_ITL_OWNED: $RelativePath"
    }
    $root = [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "WORKFLOW_PATCH_PATH_OUTSIDE_PROJECT: $RelativePath"
    }
    $probe = $full
    while ($probe -and $probe -ne $root) {
        if ((Test-Path -LiteralPath $probe) -and ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "WORKFLOW_PATCH_REPARSE_POINT: $RelativePath"
        }
        $probe = Split-Path -Parent $probe
    }
    return $full
}

function Get-WorkflowPatchIndexEntry {
    param([string]$Path)
    $records = @(Get-GitPathList -Arguments @('ls-files', '--stage', '-z', '--', ":(literal)$Path"))
    if ($records.Count -ne 1 -or $records[0] -notmatch '^(100644|100755) ([a-f0-9]{40,64}) 0\t') {
        throw "WORKFLOW_PATCH_INDEX_CHANGED: $Path; preserve the index and resolve this file before retrying."
    }
    return [pscustomobject]@{mode=[string]$Matches[1];blob=[string]$Matches[2]}
}

function Get-WorkflowPatchIndexBlob {
    param([string]$Path)
    return (Get-WorkflowPatchIndexEntry $Path).blob
}

function Write-WorkflowPatchReceipt {
    param([object]$Receipt)
    $activePath = Resolve-WorkflowPatchPath -RelativePath '.agent-1c/snapshots/workflow-incidents/active.json' -Receipt
    Write-Utf8TextAtomic -Path $activePath -Value (($Receipt | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
}

function Read-WorkflowPatchReceipt {
    $activePath = Resolve-WorkflowPatchPath -RelativePath '.agent-1c/snapshots/workflow-incidents/active.json' -Receipt
    if (-not (Test-Path -LiteralPath $activePath -PathType Leaf)) { return $null }
    try { $receipt = Read-Utf8Text -Path $activePath | ConvertFrom-Json }
    catch { throw "WORKFLOW_PATCH_RECEIPT_INVALID: preserve '$activePath' and reconcile it using workflow-incidents.md. $($_.Exception.Message)" }
    # Archived history never creates a prerequisite in a later branch.
    if ($receipt.schemaVersion -eq 1 -and $receipt.phase -eq 'retired') { return $receipt }
    if ($receipt.schemaVersion -ne 1 -or [string]$receipt.id -notmatch '^[a-f0-9]{32}$' -or
        [string]$receipt.phase -notin @('captured', 'active', 'retiring', 'retired') -or
        [IO.Path]::GetFullPath([string]$receipt.projectRoot) -ne [IO.Path]::GetFullPath($script:ProjectRoot) -or
        [string]$receipt.branch -cne (Get-CurrentBranch)) {
        throw "WORKFLOW_PATCH_SCOPE_MISMATCH: '$activePath' belongs to another project/branch or has an unsupported schema; preserve it."
    }
    return $receipt
}

function New-WorkflowPatchReceipt {
    param([string[]]$Paths, [string]$ReportPath)
    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/project.json') -PathType Leaf)) {
        throw 'WORKFLOW_PATCH_INSTALLED_PROJECT_REQUIRED'
    }
    $branch = Get-CurrentBranch
    if (-not $branch) { throw 'WORKFLOW_PATCH_BRANCH_REQUIRED' }
    Assert-DevBranchCheckpointGitState -Operation 'workflow patch capture'
    $previous = Read-WorkflowPatchReceipt
    if ($null -ne $previous -and $previous.phase -eq 'retiring') {
        throw 'WORKFLOW_PATCH_RETIREMENT_PENDING: repeat the original update/refresh before changing its recorded files.'
    }
    if ($null -ne $previous -and $previous.phase -eq 'active') {
        # Capture again before a further authorized edit; retain the first
        # baseline rather than stacking independent, overlapping patch records.
        Get-WorkflowPatchRetirementPlan -Operation 'workflow patch capture' | Out-Null
    }
    if (-not $ReportPath -or -not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        throw 'WORKFLOW_PATCH_REPORT_REQUIRED: write the incident and scoped user authorization to a file first.'
    }
    if (@($Paths).Count -eq 0) { throw 'WORKFLOW_PATCH_PATHS_REQUIRED' }
    $captureCommit = Get-CurrentCommit
    $files = @(if ($null -ne $previous -and $previous.phase -ne 'retired') { $previous.files })
    foreach ($path in $Paths) {
        $full = Resolve-WorkflowPatchPath -RelativePath $path
        if (@($files | Where-Object { $_.path -ieq $path }).Count) { continue }
        $indexEntry = Get-WorkflowPatchIndexEntry -Path $path
        $blob = $indexEntry.blob
        $headBlob = (Get-GitOutput @('rev-parse', "HEAD:$path")).Trim()
        $changed = @(Get-GitPathList -Arguments @('diff', 'HEAD', '--name-only', '-z', '--', ":(literal)$path"))
        if ($changed.Count -or $blob -cne $headBlob -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "WORKFLOW_PATCH_CAPTURE_NEEDS_BASELINE: '$path' must match HEAD before editing; preserve existing edits and establish their original baseline separately."
        }
        $bytes = [IO.File]::ReadAllBytes($full)
        $files += [pscustomobject]@{ path=$path; mode=$indexEntry.mode; knownBlobs=@($blob); beforeCommit=$captureCommit; before=[Convert]::ToBase64String($bytes); beforeSha256=(Get-WorkflowPatchHash $bytes); beforeBlob=$blob; after=''; afterSha256=''; afterBlob='' }
    }
    $id = if ($null -ne $previous -and $previous.phase -ne 'retired') { $previous.id } else { [guid]::NewGuid().ToString('N') }
    $reportCopy = Resolve-WorkflowPatchPath -RelativePath ".agent-1c/snapshots/workflow-incidents/$id/report.md" -Receipt
    New-Item -ItemType Directory -Path (Split-Path -Parent $reportCopy) -Force | Out-Null
    if ([IO.Path]::GetFullPath($ReportPath) -ne [IO.Path]::GetFullPath($reportCopy)) { Copy-Item -LiteralPath $ReportPath -Destination $reportCopy -Force }
    $receipt = [pscustomobject]@{
        schemaVersion=1; id=$id; projectRoot=[IO.Path]::GetFullPath($script:ProjectRoot); branch=$branch
        baseCommit=$(if ($null -ne $previous -and $previous.phase -ne 'retired') { $previous.baseCommit } else { $captureCommit })
        captureCommit=$captureCommit; phase='captured'; reportPath=$reportCopy; files=@($files)
    }
    Write-WorkflowPatchReceipt -Receipt $receipt
    return $receipt
}

function Set-WorkflowPatchSealed {
    $receipt = Read-WorkflowPatchReceipt
    if ($null -eq $receipt -or $receipt.phase -ne 'captured') { throw 'WORKFLOW_PATCH_CAPTURE_REQUIRED' }
    Assert-DevBranchCheckpointGitState -Operation 'workflow patch seal'
    foreach ($file in @($receipt.files)) {
        $full = Resolve-WorkflowPatchPath -RelativePath $file.path
        $indexEntry = Get-WorkflowPatchIndexEntry $file.path
        if ($indexEntry.blob -cnotin @($file.knownBlobs) -or $indexEntry.mode -cne $file.mode -or (Get-CurrentCommit) -cne $receipt.captureCommit) {
            throw 'WORKFLOW_PATCH_SEAL_BEFORE_COMMIT: seal the patch before staging or committing it.'
        }
        $bytes = [IO.File]::ReadAllBytes($full)
        $file.after = [Convert]::ToBase64String($bytes)
        $file.afterSha256 = Get-WorkflowPatchHash $bytes
        $file.afterBlob = (Get-GitOutput @('hash-object', "--path=$($file.path)", '--', $full)).Trim()
        $file.knownBlobs = @(@($file.knownBlobs) + $file.afterBlob | Select-Object -Unique)
    }
    $receipt.phase = 'active'
    Write-WorkflowPatchReceipt -Receipt $receipt
    return $receipt
}

function Get-WorkflowPatchRetirementPlan {
    param([string]$Operation)
    $receipt = Read-WorkflowPatchReceipt
    if ($null -eq $receipt -or $receipt.phase -eq 'retired') { return $null }
    if ($receipt.phase -eq 'captured') { throw 'WORKFLOW_PATCH_NOT_SEALED: seal the recorded edit before update/refresh; no files were replaced.' }
    Assert-DevBranchCheckpointGitState -Operation $Operation
    $base = [string]$receipt.baseCommit
    if ($base -notmatch '^[a-f0-9]{40,64}$') { throw 'WORKFLOW_PATCH_BASE_INVALID' }
    Invoke-Git @('merge-base', '--is-ancestor', $base, 'HEAD')
    $paths = @()
    $indices = @{}
    $heads = @{}
    foreach ($file in @($receipt.files)) {
        $full = Resolve-WorkflowPatchPath -RelativePath $file.path
        if ($paths -icontains $file.path) { throw 'WORKFLOW_PATCH_DUPLICATE_PATH' }
        $paths += [string]$file.path
        foreach ($side in @('before', 'after')) {
            $bytes = [Convert]::FromBase64String([string]$file.$side)
            if ((Get-WorkflowPatchHash $bytes) -cne [string]$file.($side + 'Sha256')) { throw "WORKFLOW_PATCH_SNAPSHOT_HASH_MISMATCH: $($file.path)" }
        }
        $actual = Get-WorkflowPatchHash ([IO.File]::ReadAllBytes($full))
        if ($actual -cne $file.afterSha256 -and -not ($receipt.phase -eq 'retiring' -and $actual -ceq $file.beforeSha256)) {
            throw "WORKFLOW_PATCH_ADDITIONAL_EDITS: '$($file.path)' differs from the recorded patch; preserve and reconcile the extra edits, then retry. Report: $($receipt.reportPath)"
        }
        $indexEntry = Get-WorkflowPatchIndexEntry $file.path
        $indices[$file.path] = $indexEntry.blob
        $heads[$file.path] = (Get-GitOutput @('rev-parse', "HEAD:$($file.path)")).Trim()
        $fileBase = [string]$file.beforeCommit
        if ($fileBase -notmatch '^[a-f0-9]{40,64}$') { throw 'WORKFLOW_PATCH_FILE_BASE_INVALID' }
        Invoke-Git @('merge-base', '--is-ancestor', $fileBase, 'HEAD')
        $baseline = (Get-GitOutput @('rev-parse', "$fileBase`:$($file.path)")).Trim()
        if ($baseline -cne $file.beforeBlob -or $indexEntry.mode -cne $file.mode -or $indices[$file.path] -cnotin @($file.knownBlobs) -or $heads[$file.path] -cnotin @($file.knownBlobs)) {
            throw "WORKFLOW_PATCH_GIT_DIVERGED: '$($file.path)' has additional committed/staged changes; preserve them and reconcile the patch."
        }
    }
    if (-not $paths.Count) { throw 'WORKFLOW_PATCH_EMPTY_RECEIPT' }
    if ($Operation -eq 'update-workflow') {
        $others = @(Get-WorkflowUpdateTrackedChangePaths | Where-Object { $paths -cnotcontains $_ })
        if ($others.Count) { throw "WORKFLOW_PATCH_UNRELATED_EDITS: update-workflow preserves other tracked changes: $($others -join ', ')" }
    }
    return [pscustomobject]@{ receipt=$receipt; paths=$paths; indexBlobs=$indices; headBlobs=$heads; operation=$Operation }
}

function Start-WorkflowPatchRetirement {
    param([object]$Plan)
    if ($null -eq $Plan) { return }
    foreach ($file in @($Plan.receipt.files)) {
        $actual = Get-WorkflowPatchHash ([IO.File]::ReadAllBytes((Resolve-WorkflowPatchPath $file.path)))
        $indexEntry = Get-WorkflowPatchIndexEntry $file.path
        if ($actual -cnotin @($file.beforeSha256, $file.afterSha256) -or
            $indexEntry.blob -cne $Plan.indexBlobs[$file.path] -or $indexEntry.mode -cne $file.mode) {
            throw "WORKFLOW_PATCH_CHANGED_AFTER_PLAN: preserve '$($file.path)' and reconcile the new edits."
        }
    }
    $Plan.receipt.phase = 'retiring'
    Write-WorkflowPatchReceipt -Receipt $Plan.receipt
    foreach ($file in @($Plan.receipt.files)) {
        $full = Resolve-WorkflowPatchPath -RelativePath $file.path
        [IO.File]::WriteAllBytes($full, [Convert]::FromBase64String($file.before))
        # Only the recorded file's staging is removed; foreign staging survives.
        if ($Plan.indexBlobs[$file.path] -cne $Plan.headBlobs[$file.path]) {
            Invoke-Git @('restore', '--staged', '--', ":(literal)$($file.path)")
        }
    }
    $committed = @($Plan.receipt.files | Where-Object { $Plan.headBlobs[$_.path] -cne $_.beforeBlob })
    if ($committed.Count) {
        $literalPaths = @($Plan.paths | ForEach-Object { ":(literal)$_" })
        Invoke-Git (@('commit', '--only', '-m', 'chore: retire temporary ITL workflow patch', '--') + $literalPaths)
    }
}

function Complete-WorkflowPatchRetirement {
    param([object]$Plan)
    if ($null -eq $Plan) { return }
    $Plan.receipt.phase = 'retired'
    $archivePath = Resolve-WorkflowPatchPath -RelativePath ".agent-1c/snapshots/workflow-incidents/$($Plan.receipt.id)/patch.json" -Receipt
    Write-Utf8TextAtomic -Path $archivePath -Value (($Plan.receipt | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    Write-WorkflowPatchReceipt -Receipt $Plan.receipt
    Write-Warning "Temporary workflow patch retired; original incident still needs reproduction against the installed version. Report: $($Plan.receipt.reportPath); saved bytes: $archivePath"
}

function Undo-WorkflowPatchRetirement {
    param([object]$Plan)
    if ($null -eq $Plan) { return }
    # Called only before the owning operation's installation/merge boundary.
    foreach ($file in @($Plan.receipt.files)) {
        $full = Resolve-WorkflowPatchPath -RelativePath $file.path
        $hash = Get-WorkflowPatchHash ([IO.File]::ReadAllBytes($full))
        $indexEntry = Get-WorkflowPatchIndexEntry $file.path
        if ($hash -cnotin @($file.beforeSha256, $file.afterSha256) -or
            $indexEntry.blob -cnotin @($file.knownBlobs) -or $indexEntry.mode -cne $file.mode) {
            throw "WORKFLOW_PATCH_ROLLBACK_DIVERGED: preserve '$($file.path)' and recover using $($Plan.receipt.reportPath)"
        }
    }
    foreach ($file in @($Plan.receipt.files)) {
        [IO.File]::WriteAllBytes((Resolve-WorkflowPatchPath $file.path), [Convert]::FromBase64String($file.after))
        Invoke-Git @('update-index', '--cacheinfo', "$($file.mode),$($Plan.indexBlobs[$file.path]),$($file.path)")
        # A corrective retirement commit is retained. Reapplication is explicit
        # working-tree state, never a reset/rewrite of that commit or foreign index.
    }
    $Plan.receipt.phase = 'active'
    Write-WorkflowPatchReceipt -Receipt $Plan.receipt
}
