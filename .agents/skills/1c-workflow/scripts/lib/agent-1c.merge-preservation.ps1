# Three-way evidence for helper-owned merges. No index or source mutations.
function Get-MergePreservationRawChanges {
    param([string]$BaseCommit, [string]$OtherCommit = '', [switch]$Index)
    $arguments = @('diff', '--raw', '--no-abbrev', '--no-renames', '-z')
    if ($Index) { $arguments += '--cached' }
    $arguments += $BaseCommit
    if (-not $Index) { $arguments += $OtherCommit }
    $arguments += '--'
    $records = @(Get-GitPathList -Arguments $arguments)
    $changes = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if ($records.Count % 2 -ne 0) { throw 'LIFECYCLE_MERGE_REVIEW_RAW_INVALID' }
    for ($position = 0; $position -lt $records.Count; $position += 2) {
        if ($records[$position] -cnotmatch '^:([0-7]{6}) ([0-7]{6}) ([a-f0-9]{40,64}) ([a-f0-9]{40,64}) ([AMDT])$') {
            throw 'LIFECYCLE_MERGE_REVIEW_RAW_INVALID'
        }
        $changes.Add($records[$position + 1], [pscustomobject]@{
            oldMode = $Matches[1]; mode = $Matches[2]; oldBlob = $Matches[3]; blob = $Matches[4]
        })
    }
    return ,$changes
}

function Test-MergePreservationCleanParentResult {
    param([object]$Left, [object]$Right, [object]$Result)
    # A parent can already contain the other side's compatible text delta.
    # Prove that with Git's ordinary three-way text merge before requesting review.
    if ($Left.oldBlob -match '^0+$' -or $Left.blob -match '^0+$' -or $Right.blob -match '^0+$' -or
        $Left.oldMode -cne '100644' -or $Left.mode -cne '100644' -or $Right.mode -cne '100644') { return $false }
    $blobs = Get-GitBlobBytesBatch -ObjectIds @($Left.oldBlob, $Left.blob, $Right.blob)
    $tempParent = [IO.Path]::GetFullPath((Get-Agent1cTempRoot))
    $root = Join-Path $tempParent ('merge-analysis-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $process = $null
    $memory = [IO.MemoryStream]::new()
    try {
        [IO.File]::WriteAllBytes((Join-Path $root 'ours'), [byte[]]$blobs[$Left.blob])
        [IO.File]::WriteAllBytes((Join-Path $root 'base'), [byte[]]$blobs[$Left.oldBlob])
        [IO.File]::WriteAllBytes((Join-Path $root 'theirs'), [byte[]]$blobs[$Right.blob])
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = 'git'
        $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-C', $script:ProjectRoot, 'merge-file', '-p', '--',
            (Join-Path $root 'ours'), (Join-Path $root 'base'), (Join-Path $root 'theirs'))
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        $copy = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); return $false }
        [void]$copy.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { return $false }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $actual = [BitConverter]::ToString($sha.ComputeHash($memory.ToArray()))
            $expected = [BitConverter]::ToString($sha.ComputeHash([byte[]]$blobs[$Result.blob]))
            return $actual -ceq $expected
        } finally { $sha.Dispose() }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        $memory.Dispose()
        # Delete only the three files written above, never an enumerated tree.
        foreach ($name in @('ours', 'base', 'theirs')) { [IO.File]::Delete((Join-Path $root $name)) }
        [IO.Directory]::Delete($root, $false)
    }
}

function Test-MergePreservationDuplicateAddition {
    param([string]$Path, [object]$Left, [object]$Right)
    if ($Left.oldMode -cne '100644' -or $Left.mode -cne '100644' -or $Right.mode -cne '100644' -or $Left.oldBlob -match '^0+$') { return $false }
    $isBsl = $Path.EndsWith('.bsl', [StringComparison]::OrdinalIgnoreCase)
    $isXml = $Path -match '^src/(?:cf|cfe)/.*(?:Configuration|Form)\.xml$'
    if (-not $isBsl -and -not $isXml) { return $false }
    $ids = @($Left.oldBlob, $Left.blob, $Right.blob)
    $blobs = Get-GitBlobBytesBatch -ObjectIds $ids
    try { $texts = @($ids | ForEach-Object { [Text.UTF8Encoding]::new($false, $true).GetString([byte[]]$blobs[$_]).TrimStart([char]0xFEFF) }) }
    catch { return $false }
    $signatures = @()
    if ($isBsl) {
        # Only complete, identical new declarations can move. Never compare a
        # bag of executable lines: statement order and existing bodies matter.
        $pattern = '(?im)^[\t ]*(?:Процедура|Функция|Procedure|Function)[\t ]+([\p{L}_][\p{L}\p{N}_]*)[\t ]*\([^\r\n]*\)[^\r\n]*\r?\n(?s:.*?)^[\t ]*(?:КонецПроцедуры|КонецФункции|EndProcedure|EndFunction)[\t ]*(?=\r?$)'
        $baseNames = @(Get-OneCBslDeclarationRecords -Text $texts[0] | ForEach-Object name)
        $normalize = { param($value) [regex]::Replace($value.Replace("`r`n", "`n"), '(?m)^[\t ]*\n', '').TrimEnd("`n") }
        foreach ($text in $texts[1..2]) {
            $remaining = $text
            $added = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
            $matchesFound = @([regex]::Matches($text, $pattern))
            for ($i = $matchesFound.Count - 1; $i -ge 0; $i--) {
                $match = $matchesFound[$i]; $name = $match.Groups[1].Value
                if ($baseNames -contains $name) { continue }
                if ($added.ContainsKey($name)) { return $false }
                $added.Add($name, $match.Value.Replace("`r`n", "`n"))
                $remaining = $remaining.Remove($match.Index, $match.Length)
            }
            if ($added.Count -eq 0 -or (& $normalize $remaining) -cne (& $normalize $texts[0])) { return $false }
            $names = @($added.Keys); [Array]::Sort($names, [StringComparer]::Ordinal)
            $signatures += (ConvertTo-Json -InputObject @($names | ForEach-Object { @($_, $added[$_]) }) -Compress)
        }
    } elseif ($isXml) {
        # Remove only new, identical definitions in known metadata containers.
        # The complete remaining document must equal the base, in original order.
        if (@($texts | Where-Object { $_.Contains('<!DOCTYPE') }).Count -gt 0) { return $false }
        $baseXml = [Xml.XmlDocument]::new(); $baseXml.XmlResolver = $null
        try { $baseXml.LoadXml($texts[0]) } catch { return $false }
        foreach ($text in $texts[1..2]) {
            $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver = $null
            try { $xml.LoadXml($text) } catch { return $false }
            $added = [Collections.Generic.List[string]]::new()
            $containers = @($xml.SelectNodes('//*[local-name()="ChildObjects" or local-name()="Items" or local-name()="ChildItems" or local-name()="Commands" or local-name()="Attributes" or local-name()="Parameters"]'))
            foreach ($container in $containers) {
                $steps = @(); $node = $container
                while ($node -is [Xml.XmlElement]) {
                    $position = 1; $sibling = $node.PreviousSibling
                    while ($null -ne $sibling) {
                        if ($sibling -is [Xml.XmlElement] -and $sibling.LocalName -ceq $node.LocalName -and $sibling.NamespaceURI -ceq $node.NamespaceURI) { $position++ }
                        $sibling = $sibling.PreviousSibling
                    }
                    $steps = @('*[local-name()="' + $node.LocalName + '" and namespace-uri()="' + $node.NamespaceURI + '"][' + $position + ']') + $steps
                    $node = $node.ParentNode
                }
                $location = '/' + ($steps -join '/')
                $baseContainer = $baseXml.SelectSingleNode($location)
                if ($null -eq $baseContainer) { continue }
                $baseChildren = @($baseContainer.ChildNodes | ForEach-Object OuterXml)
                foreach ($child in @($container.ChildNodes)) {
                    if ($child -isnot [Xml.XmlElement] -or $baseChildren -ccontains $child.OuterXml) { continue }
                    $definition = $location + '|' + $child.OuterXml
                    if ($added.Contains($definition)) { return $false }
                    $added.Add($definition)
                    [void]$container.RemoveChild($child)
                }
            }
            if ($added.Count -eq 0 -or $xml.OuterXml -cne $baseXml.OuterXml) { return $false }
            $values = $added.ToArray(); [Array]::Sort($values, [StringComparer]::Ordinal)
            $signatures += (ConvertTo-Json -InputObject $values -Compress)
        }
    } else { return $false }
    return $signatures.Count -eq 2 -and $signatures[0] -ceq $signatures[1]
}

function Get-MergePreservationReportRoot {
    param([string]$BranchCommit, [string]$TargetCommit)
    $common = (Get-GitOutput @('rev-parse', '--git-common-dir')).Trim()
    if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $script:ProjectRoot $common }
    $identity = ([IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\', '/').ToUpperInvariant()) + '|' + $BranchCommit + '|' + $TargetCommit
    Join-Path ([IO.Path]::GetFullPath($common)) ('itl/merge-review/' + (Get-StringSha256 -Value $identity))
}

function Get-MergePreservationPlan {
    param([string]$BranchCommit, [string]$TargetCommit, [string[]]$ExcludedPaths = @(), [string]$ResultCommit = '')
    $branch = (Get-GitOutput @('rev-parse', '--verify', ($BranchCommit + '^{commit}'))).Trim()
    $target = (Get-GitOutput @('rev-parse', '--verify', ($TargetCommit + '^{commit}'))).Trim()
    $bases = @(Get-GitOutput @('merge-base', '--all', $branch, $target))
    if ($bases.Count -eq 0) { throw 'LIFECYCLE_MERGE_REVIEW_BASE_REQUIRED' }
    [Array]::Sort($bases, [StringComparer]::Ordinal)
    $resultChanges = if ($ResultCommit) {
        Get-MergePreservationRawChanges -BaseCommit $branch -OtherCommit $ResultCommit
    } else { Get-MergePreservationRawChanges -BaseCommit $branch -Index }
    $risks = [Collections.Generic.List[object]]::new()
    $declarations = @{}
    foreach ($base in $bases) {
        $ours = Get-MergePreservationRawChanges -BaseCommit $base -OtherCommit $branch
        $theirs = Get-MergePreservationRawChanges -BaseCommit $base -OtherCommit $target
        $paths = @($ours.Keys | Where-Object { $theirs.ContainsKey($_) -and $ExcludedPaths -cnotcontains $_ })
        [Array]::Sort($paths, [StringComparer]::Ordinal)
        foreach ($path in $paths) {
            $left = $ours[$path]; $right = $theirs[$path]
            $result = if ($resultChanges.ContainsKey($path)) { $resultChanges[$path] } else { $left }
            $sameParents = $left.blob -ceq $right.blob -and $left.mode -ceq $right.mode
            if ($sameParents -and $result.blob -ceq $left.blob -and $result.mode -ceq $left.mode) { continue }
            $replaced = if ($result.blob -ceq $left.oldBlob -and $result.mode -ceq $left.oldMode) { 'both' }
                elseif ($result.blob -ceq $left.blob -and $result.mode -ceq $left.mode) { 'target' }
                elseif ($result.blob -ceq $right.blob -and $result.mode -ceq $right.mode) { 'branch' } else { '' }
            if ($replaced -in @('branch', 'target') -and (Test-MergePreservationCleanParentResult -Left $left -Right $right -Result $result)) { $replaced = '' }
            if ($replaced -in @('branch', 'target') -and (Test-MergePreservationDuplicateAddition -Path $path -Left $left -Right $right)) { $replaced = '' }
            $lostDeclarations = @()
            if ($path.EndsWith('.bsl', [StringComparison]::OrdinalIgnoreCase)) {
                $ids = @($left.oldBlob, $left.blob, $right.blob, $result.blob | Where-Object { $_ -notmatch '^0+$' -and -not $declarations.ContainsKey($_) })
                $blobs = Get-GitBlobBytesBatch -ObjectIds $ids
                foreach ($id in $ids) {
                    $text = [Text.Encoding]::UTF8.GetString([byte[]]$blobs[$id]).TrimStart([char]0xFEFF)
                    $declarations[$id] = @(Get-OneCBslDeclarationRecords -Text $text | ForEach-Object name)
                }
                $originalNames = @($declarations[$left.oldBlob])
                $resultNames = @($declarations[$result.blob])
                foreach ($side in @('branch', 'target')) {
                    $sideBlob = if ($side -eq 'branch') { $left.blob } else { $right.blob }
                    foreach ($name in @($declarations[$sideBlob] | Sort-Object -Unique)) {
                        if ($name -and $originalNames -notcontains $name -and $resultNames -notcontains $name) {
                            $lostDeclarations += [pscustomobject]@{ side = $side; name = $name }
                        }
                    }
                }
            }
            if ($replaced -or $lostDeclarations.Count -gt 0) {
                $risks.Add([pscustomobject][ordered]@{
                    path = $path; baseCommit = $base; baseBlob = $left.oldBlob
                    branchBlob = $left.blob; branchMode = $left.mode; targetBlob = $right.blob; targetMode = $right.mode
                    resultBlob = $result.blob; resultMode = $result.mode; discardedSide = $replaced; lostDeclarations = $lostDeclarations
                })
            }
        }
    }
    # Bind decisions to every staged delta: changing a caller or supporting test
    # can invalidate the explanation even when the flagged module is unchanged.
    # Do not use write-tree: it may update the user's index cache extension.
    $resultPaths = @($resultChanges.Keys); [Array]::Sort($resultPaths, [StringComparer]::Ordinal)
    $resultEntries = @($resultPaths | ForEach-Object { [ordered]@{ path = $_; blob = $resultChanges[$_].blob; mode = $resultChanges[$_].mode } })
    $identity = [ordered]@{ schemaVersion = 1; branchCommit = $branch; targetCommit = $target; resultEntries = $resultEntries; risks = @($risks) }
    [pscustomobject]@{ schemaVersion = 1; planId = (Get-StringSha256 -Value ($identity | ConvertTo-Json -Depth 12 -Compress));
        branchCommit = $branch; targetCommit = $target; risks = @($risks) }
}

function Assert-DevBranchMergePreservation {
    param([string]$BranchCommit, [string]$TargetCommit, [string[]]$ExcludedPaths = @())
    $plan = Get-MergePreservationPlan -BranchCommit $BranchCommit -TargetCommit $TargetCommit -ExcludedPaths $ExcludedPaths
    $root = Get-MergePreservationReportRoot -BranchCommit $plan.branchCommit -TargetCommit $plan.targetCommit
    $reportPath = Join-Path $root 'review.json'
    $decisionPath = Join-Path $root 'decisions.json'
    if ($plan.risks.Count -eq 0) {
        if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
            $previous = Read-Utf8Text -Path $reportPath | ConvertFrom-Json
            $previous.status = 'resolved-by-repair'
            $previous | Add-Member -NotePropertyName resolvedPlanId -NotePropertyValue $plan.planId -Force
            Write-Utf8TextAtomic -Path $reportPath -Value ($previous | ConvertTo-Json -Depth 20)
        }
        return
    }
    [void][IO.Directory]::CreateDirectory($root)
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        $previous = Read-Utf8Text -Path $reportPath | ConvertFrom-Json
        if ($previous.planId -cnotmatch '^[a-f0-9]{64}$') { throw 'LIFECYCLE_MERGE_REVIEW_REPORT_INVALID' }
        if ($previous.planId -cne $plan.planId) {
            $history = Join-Path $root 'history'
            [void][IO.Directory]::CreateDirectory($history)
            $historyPath = Join-Path $history ($previous.planId + '.json')
            if (-not (Test-Path -LiteralPath $historyPath)) { Write-Utf8TextAtomic -Path $historyPath -Value ($previous | ConvertTo-Json -Depth 20) }
        }
    }
    $items = @()
    for ($index = 0; $index -lt $plan.risks.Count; $index++) {
        $risk = $plan.risks[$index]
        $prefix = Get-StringSha256 -Value ($risk.path + '|' + $risk.baseCommit)
        $patches = [ordered]@{}
        foreach ($side in @('branch', 'target')) {
            $commit = if ($side -eq 'branch') { $plan.branchCommit } else { $plan.targetCommit }
            $patchPath = Join-Path $root ($prefix + '-' + $side + '.patch')
            $patch = @(Get-GitOutput @('-c', 'core.quotepath=false', 'diff', '--no-ext-diff', '--no-textconv', '--binary', '--full-index', $risk.baseCommit, $commit, '--', $risk.path)) -join "`n"
            Write-Utf8TextAtomic -Path $patchPath -Value $patch
            $patches[$side] = $patchPath
        }
        $items += [pscustomobject]@{ path = $risk.path; baseCommit = $risk.baseCommit; risk = $risk; patches = $patches }
    }
    $report = [ordered]@{ schemaVersion = 1; planId = $plan.planId; branchCommit = $plan.branchCommit; targetCommit = $plan.targetCommit;
        decisionPath = $decisionPath; items = $items; status = 'review-required' }
    $accepted = $false
    $decisionIssues = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $decisionPath -PathType Leaf) {
        try {
            $decision = Read-Utf8Text -Path $decisionPath | ConvertFrom-Json -ErrorAction Stop
            # Get-StateValue treats an object's empty string representation as
            # absent; read the JSON array itself so a single record is retained.
            $itemsProperty = $decision.PSObject.Properties['items']
            $records = @(if ($null -ne $itemsProperty -and $null -ne $itemsProperty.Value) { $itemsProperty.Value })
            if ((Get-StateValue -State $decision -Name 'schemaVersion' -Default 0) -ne 1) { $decisionIssues.Add('Decision schemaVersion must be 1.') }
            if ((Get-StateValue -State $decision -Name 'planId' -Default '') -cne $plan.planId) { $decisionIssues.Add('Decision planId is stale.') }
            if ($records.Count -ne $items.Count) { $decisionIssues.Add("Decision item count $($records.Count) does not match report count $($items.Count).") }
            $accepted = $decisionIssues.Count -eq 0
            $seen = @{}
            foreach ($record in $records) {
                $key = [string](Get-StateValue -State $record -Name 'path' -Default '') + '|' + [string](Get-StateValue -State $record -Name 'baseCommit' -Default '')
                $matchingItems = @($items | Where-Object { ($_.path + '|' + $_.baseCommit) -ceq $key })
                $disposition = [string](Get-StateValue -State $record -Name 'disposition' -Default '')
                $entryAccepted = $matchingItems.Count -eq 1 -and -not $seen.ContainsKey($key) -and
                    $disposition -cin @('equivalent-result', 'superseded-by-authoritative-change', 'authorized-incompatible-change')
                if (-not $entryAccepted) { $decisionIssues.Add('Decision item has an unknown/duplicate identity or unsupported disposition.') }
                $accepted = $accepted -and $entryAccepted
                foreach ($field in @('reason', 'preservationEvidence', 'verificationEvidence')) {
                    if ([string]::IsNullOrWhiteSpace([string](Get-StateValue -State $record -Name $field -Default ''))) {
                        $decisionIssues.Add('Missing decision evidence: ' + $field); $accepted = $false
                    }
                }
                if ($disposition -ceq 'authorized-incompatible-change') {
                    if ([string]::IsNullOrWhiteSpace([string](Get-StateValue -State $record -Name 'userAuthorization' -Default ''))) {
                        $decisionIssues.Add('Incompatible replacement lacks userAuthorization.'); $accepted = $false
                    }
                }
                $seen[$key] = $true
            }
        } catch { $accepted = $false; $decisionIssues.Add('Decision could not be read or validated: ' + $_.Exception.Message) }
    } else { $decisionIssues.Add('Decision file is absent; repair compatible changes or provide supported replacement evidence.') }
    $report.decisionIssues = @($decisionIssues)
    if ($accepted) { $report.status = 'reviewed-intentional-replacement'; $report.decisionEvidence = $decision }
    Write-Utf8TextAtomic -Path $reportPath -Value ($report | ConvertTo-Json -Depth 16)
    if ($accepted) { Write-Host "Merge replacement evidence retained: $reportPath"; return }
    Set-RunFailureContext -Category 'merge-conflict' -RequiredAction 'agent-review-discarded-merge-changes-then-repeat-same-itl-command'
    throw "LIFECYCLE_MERGE_PRESERVATION_REVIEW_REQUIRED report='$reportPath' decisions='$decisionPath'. Restore compatible changes from both sides, run git add and repeat the same ITL command. For a justified replacement retain result-bound semantic and verification evidence as described in merge-preservation.md. Ask the user only for unresolved incompatible business intent. Do not manually commit the lifecycle merge."
}
