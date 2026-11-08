# Review scope is a read-only projection of the branch transfer scope base:
# everything that still differs from it, by file kind. It writes no branch
# state, index, worktree, Git objects or refs and takes no lifecycle lock.
# The verification fingerprint owner builds a temporary tree; its objects go to
# a discarded object directory, so even that read leaves the repository as is.

# A separate review above this much BSL change text does not fit one reviewer
# context; measured on PM5 branches (2026-11-07), none fell between 90 KB and
# 526 KB. The commit picker shows at most this many entries.
$script:ReviewScopeLargeBslBytes = 307200
$script:ReviewScopePickerLimit = 15
$script:ReviewScopePickerScanLimit = 200

function ConvertTo-ReviewScopePowerShellLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "''" }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Test-ReviewScopePathUnder {
    param([string]$Path, [string]$Root)
    $normalizedRoot = ([string]$Root).Replace('\', '/').Trim('/')
    if (-not $normalizedRoot) { return $false }
    return $Path -ieq $normalizedRoot -or $Path.StartsWith($normalizedRoot + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Get-ReviewScopeKindRules {
    param([Parameter(Mandatory = $true)][string]$BaseCommit)

    $exportPath = ([string](Get-ExportPath)).Replace('\', '/').Trim('/')
    $extensionsPath = ([string](Get-ExtensionsPath)).Replace('\', '/').Trim('/')
    $testsExtension = [string](Get-YAxUnitTestsExtensionName)
    $subjectRoots = @($exportPath, $extensionsPath | Where-Object { $_ })
    # Test owners are the test part of the verification fingerprint; obligation
    # inputs inside the subject roots stay subject.
    $tests = @(
        (Get-VanessaVerificationFeaturesPath),
        (Get-YAxUnitTestsPath),
        'tests/verification-suites.shared.json',
        'tests/verification-suites.branch.json',
        'tests/yaxunit-suites.shared.json',
        'tests/yaxunit-suites.branch.json'
    ) + @(Get-VerificationDeclaredInputScopes)
    $testRoots = @($tests | ForEach-Object { ([string]$_).Replace('\', '/').Trim('/') } | Where-Object {
        $candidate = $_
        $candidate -and -not [IO.Path]::IsPathRooted($candidate) -and @($subjectRoots | Where-Object { Test-ReviewScopePathUnder -Path $candidate -Root $_ }).Count -eq 0
    } | Select-Object -Unique)
    $managed = @(@(Get-WorkflowUpdateManagedPathSpecs -StaticOnly) + @(Get-WorkflowUpdateManagedPathSpecs -AtCommit $BaseCommit) +
        @(Get-WorkflowUpdateManagedPathSpecs -AtCommit 'HEAD') | Select-Object -Unique)
    return [pscustomobject]@{
        exportPath = $exportPath
        extensionsPath = $extensionsPath
        testsExtensionRoot = $(if ($extensionsPath -and $testsExtension) { "$extensionsPath/$testsExtension" } else { '' })
        testRoots = $testRoots
        requirementRoots = @('openspec/changes', 'docs', 'handoffs')
        managedMatcher = New-WorkflowUpdatePathMatcher -ManagedPathSpecs $managed
        diagnosticRoot = [string](Get-ItlDiagnosticArtifactReceiptRoot)
    }
}

function Get-ReviewScopePathKind {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Rules)

    # First match wins: always excluded, excluded, subject, requirements, tests.
    if ([IO.Path]::GetFileName($Path) -ieq 'ConfigDumpInfo.xml') { return 'always-excluded' }
    if ((Test-WorkflowUpdatePathAllowed -Path $Path -Matcher $Rules.managedMatcher) -or
        (Test-ReviewScopePathUnder -Path $Path -Root $Rules.diagnosticRoot)) { return 'excluded' }
    if ($Rules.testsExtensionRoot -and (Test-ReviewScopePathUnder -Path $Path -Root $Rules.testsExtensionRoot)) { return 'tests' }
    if ((Test-ReviewScopePathUnder -Path $Path -Root $Rules.exportPath) -or (Test-ReviewScopePathUnder -Path $Path -Root $Rules.extensionsPath)) { return 'subject' }
    if (@($Rules.requirementRoots | Where-Object { Test-ReviewScopePathUnder -Path $Path -Root $_ }).Count -gt 0) { return 'requirements' }
    if (@($Rules.testRoots | Where-Object { Test-ReviewScopePathUnder -Path $Path -Root $_ }).Count -gt 0) { return 'tests' }
    return 'unclassified'
}

function Get-ReviewScopeReadCommand {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$BaseCommit, [bool]$Untracked)
    if ($Untracked) { return "new file, read it whole: $Path" }
    return "git -c core.quotepath=false diff --no-renames $BaseCommit -- $(ConvertTo-ReviewScopePowerShellLiteral -Value $Path)"
}

function Get-ReviewScopeSubjectObjects {
    param([Parameter(Mandatory = $true)][object]$Rules, [Parameter(Mandatory = $true)][string]$BaseCommit, [string[]]$SubjectPaths = @())

    # Objects come from the transfer-plan owner per dump root: the converter
    # expects paths relative to the main dump or to one extension root.
    $roots = [Collections.Generic.List[string]]::new()
    $unrooted = [Collections.Generic.List[string]]::new()
    foreach ($path in @($SubjectPaths)) {
        if (Test-ReviewScopePathUnder -Path $path -Root $Rules.exportPath) {
            if (-not $roots.Contains($Rules.exportPath)) { $roots.Add($Rules.exportPath) }
            continue
        }
        $relative = $path.Substring($Rules.extensionsPath.Length).Trim('/')
        $segments = @($relative -split '/')
        if ($segments.Count -lt 2) { $unrooted.Add($path); continue }
        $root = "$($Rules.extensionsPath)/$($segments[0])"
        if (-not $roots.Contains($root)) { $roots.Add($root) }
    }
    # The plan covers the whole root against the base; a commit range keeps
    # only the objects and parts of its own subject paths.
    $subjectSet = [Collections.Generic.HashSet[string]]::new([string[]]@($SubjectPaths), [StringComparer]::Ordinal)
    $groups = @(foreach ($root in @($roots | Sort-Object)) {
        $plan = Get-ConfigRepositoryTransferPlan -ExportPath $root -BaseCommit $BaseCommit
        $items = @(foreach ($item in @($plan.items)) {
            $kept = @($item.paths | Where-Object { $subjectSet.Contains([string]$_) })
            if ($kept.Count -eq 0) { continue }
            if ($kept.Count -eq @($item.paths).Count) { $item; continue }
            $converted = @($kept | ForEach-Object { ConvertTo-ConfigRepositoryTransferPath -RelativePath ([string]$_).Substring($root.Length).Trim('/') } | Where-Object { $null -ne $_ })
            [pscustomobject]@{
                name = $item.name
                scope = $(if (@($converted | Where-Object scope -ceq 'full').Count -gt 0) { 'full' } else { [string]$converted[0].scope })
                parts = @($converted | ForEach-Object { [string]$_.part } | Where-Object { $_ } | Sort-Object -Unique)
                paths = $kept
            }
        })
        [pscustomobject]@{ root = $root; items = $items; unresolvedPaths = @($plan.unresolvedPaths | Where-Object { $subjectSet.Contains([string]$_) }) }
    })
    return [pscustomobject]@{ groups = $groups; unrootedPaths = @($unrooted) }
}

function Test-ReviewScopePathFiltered {
    # $null means no range filter; a set keeps only the paths the range touched.
    param([string]$Path, [AllowNull()][object]$PathFilter)
    return $null -eq $PathFilter -or $PathFilter.Contains($Path)
}

function Get-ReviewScopeEntries {
    param([Parameter(Mandatory = $true)][string]$BaseCommit, [AllowNull()][object]$PathFilter = $null)

    $tracked = @(Get-GitPathList -Arguments @('diff', '--no-renames', '--name-only', '-z', $BaseCommit))
    $untracked = @(Get-GitPathList -Arguments @('ls-files', '-z', '--others', '--exclude-standard'))
    $rules = Get-ReviewScopeKindRules -BaseCommit $BaseCommit
    $untrackedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $untracked) { [void]$untrackedSet.Add(([string]$path).Replace('\', '/')) }
    $entries = @(foreach ($path in @(@($tracked) + @($untracked) | ForEach-Object { ([string]$_).Replace('\', '/').Trim('/') } |
            Where-Object { $_ -and (Test-ReviewScopePathFiltered -Path $_ -PathFilter $PathFilter) } | Sort-Object -Unique)) {
        $isUntracked = $untrackedSet.Contains($path)
        [pscustomobject]@{
            path = $path
            kind = Get-ReviewScopePathKind -Path $path -Rules $rules
            untracked = $isUntracked
            command = Get-ReviewScopeReadCommand -Path $path -BaseCommit $BaseCommit -Untracked $isUntracked
        }
    })
    return [pscustomobject]@{ rules = $rules; entries = $entries }
}

function Get-ReviewScopeGitText {
    param([string[]]$Arguments)
    # The shared path-list transport owns quoting and UTF-8 decoding; BSL diff
    # text has no NUL, so it comes back as one piece.
    return (@(Get-GitPathList -Arguments $Arguments) -join '')
}

function Test-ReviewScopeBslSubject {
    param([string]$Path, [object]$Rules)
    return $Path.EndsWith('.bsl', [StringComparison]::OrdinalIgnoreCase) -and (Get-ReviewScopePathKind -Path $Path -Rules $Rules) -ceq 'subject'
}

function Get-ReviewScopeBslSize {
    param(
        [Parameter(Mandatory = $true)][string]$BaseCommit,
        [Parameter(Mandatory = $true)][object]$Rules,
        [string[]]$UntrackedPaths = @(),
        [AllowNull()][object]$PathFilter = $null
    )

    $roots = @($Rules.exportPath, $Rules.extensionsPath | Where-Object { $_ })
    $tracked = @()
    if ($roots.Count -gt 0) {
        $tracked = @(Get-GitPathList -Arguments (@('diff', '--no-renames', '--name-only', '-z', $BaseCommit, '--') + $roots) |
            ForEach-Object { ([string]$_).Replace('\', '/') } |
            Where-Object { (Test-ReviewScopePathFiltered -Path $_ -PathFilter $PathFilter) -and (Test-ReviewScopeBslSubject -Path $_ -Rules $Rules) })
    }
    $untracked = @($UntrackedPaths | Where-Object { (Test-ReviewScopePathFiltered -Path $_ -PathFilter $PathFilter) -and (Test-ReviewScopeBslSubject -Path $_ -Rules $Rules) })
    $bytes = [long]0; $added = 0; $removed = 0
    # Chunks keep the native command line far below the Windows limit.
    for ($offset = 0; $offset -lt $tracked.Count; $offset += 100) {
        $chunk = @($tracked[$offset..([Math]::Min($offset + 99, $tracked.Count - 1))])
        $text = Get-ReviewScopeGitText -Arguments (@('diff', '--no-renames', $BaseCommit, '--') + $chunk)
        $bytes += [Text.Encoding]::UTF8.GetByteCount($text)
        foreach ($record in @(Get-GitPathList -Arguments (@('diff', '--no-renames', '--numstat', '-z', $BaseCommit, '--') + $chunk))) {
            $fields = ([string]$record) -split "`t", 3
            if ($fields.Count -lt 3) { continue }
            if ($fields[0] -match '^\d+$') { $added += [int]$fields[0] }
            if ($fields[1] -match '^\d+$') { $removed += [int]$fields[1] }
        }
    }
    foreach ($path in $untracked) {
        $full = Join-Path $script:ProjectRoot $path
        if (-not [IO.File]::Exists($full)) { continue }
        $content = [IO.File]::ReadAllBytes($full)
        $bytes += $content.Length
        $added += @($content | Where-Object { $_ -eq 10 }).Count + 1
    }
    return [pscustomobject]@{
        modules = $tracked.Count + $untracked.Count
        addedLines = $added
        removedLines = $removed
        bytes = $bytes
        sizeClass = $(if ($bytes -gt $script:ReviewScopeLargeBslBytes) { 'large' } else { 'normal' })
    }
}

function Format-ReviewScopeSize {
    param([object]$Size)
    $class = if ($Size.sizeClass -ceq 'large') { 'большой' } else { 'нормальный' }
    $kb = [Math]::Ceiling([double]$Size.bytes / 1024)
    return "модулей BSL: $($Size.modules), строк +$($Size.addedLines)/-$($Size.removedLines), текст изменений $kb КБ — $class"
}

function Get-ReviewScopeAutomaticCommitLabels {
    # Subjects of commits the helper itself creates with the developer's work
    # inside; ReviewScope.Tests checks this table against their producers.
    return @(
        @{ pattern = '^chore: checkpoint before branch refresh$'; label = 'автосохранение работы перед обновлением из master' },
        @{ pattern = '^chore: checkpoint before branch reset$'; label = 'автосохранение работы перед сбросом ветки' },
        @{ pattern = '^chore: checkpoint before source sync with (?<arg>.+)$'; label = 'автосохранение работы перед синхронизацией исходников с {0}' },
        @{ pattern = '^chore: checkpoint before source group (?<arg>.+)$'; label = 'автосохранение работы перед группой исходников {0}' },
        @{ pattern = '^chore: checkpoint before fork to (?<arg>.+)$'; label = 'автосохранение работы перед ответвлением в {0}' },
        @{ pattern = '^sync: copy combined 1C sources from (?<arg>.+)$'; label = 'копия исходников 1С из ветки {0}' }
    )
}

function Get-ReviewScopeCommitLabel {
    param([string]$Subject)
    foreach ($entry in Get-ReviewScopeAutomaticCommitLabels) {
        if ($Subject -cmatch $entry.pattern) { return ($entry.label -f [string]$Matches['arg']) }
    }
    return $Subject
}

function Get-ReviewScopeObjectName {
    param([string]$Path, [object]$Rules)
    foreach ($root in @($Rules.exportPath, $Rules.extensionsPath | Where-Object { $_ })) {
        if (-not (Test-ReviewScopePathUnder -Path $Path -Root $root)) { continue }
        $relative = $Path.Substring($root.Length).Trim('/')
        $prefix = ''
        if ($root -ceq $Rules.extensionsPath) {
            $segments = @($relative -split '/', 2)
            if ($segments.Count -lt 2) { return $Path }
            $prefix = "$($segments[0]): "; $relative = $segments[1]
        }
        $converted = ConvertTo-ConfigRepositoryTransferPath -RelativePath $relative
        if ($null -ne $converted) { return $prefix + [string]$converted.objectName }
        if ($relative -ieq 'Configuration.xml') { return $prefix + 'Конфигурация (состав объектов)' }
        return $Path
    }
    return $Path
}

function Get-ReviewScopeCommitPicker {
    param(
        [Parameter(Mandatory = $true)][string]$BranchBase,
        [Parameter(Mandatory = $true)][object]$Rules,
        [object]$State,
        [string[]]$UntrackedPaths = @(),
        [string]$VerifiedCommit = '',
        # Resolving a named commit needs only the scanned commits.
        [switch]$CommitsOnly
    )

    # First-parent commits of the branch's own work since its creation or last
    # reset. A range after the last refresh merge is the exact change since its
    # commit; an earlier one crosses a merge and is the branch-base diff of the
    # paths the branch itself changed since that commit, so master changes stay
    # out either way.
    $log = @(Get-GitPathList -Arguments @('log', '--first-parent', '-z', "--max-count=$script:ReviewScopePickerScanLimit",
        '--format=%H%x1f%P%x1f%an%x1f%aI%x1f%s', 'HEAD', "^$BranchBase"))
    $resetHead = [string](Get-StateValue -State $State -Name 'resetNewHead' -Default '')
    $commits = [Collections.Generic.List[object]]::new()
    $crossed = $false
    $exhausted = $log.Count -lt $script:ReviewScopePickerScanLimit
    foreach ($record in $log) {
        $fields = ([string]$record).Trim("`n") -split [char]0x1f, 5
        if ($fields.Count -lt 5) { continue }
        $parents = @($fields[1] -split ' ' | Where-Object { $_ })
        $anchor = if ($parents.Count -gt 1) { 'merge' } elseif ($fields[0] -ceq $resetHead -or $fields[4] -ceq 'chore: reset branch for next change') { 'reset' } else { '' }
        $commits.Add([pscustomobject]@{ commit = $fields[0]; parent = $(if ($parents.Count -gt 0) { $parents[0] } else { '' }); author = $fields[2]; date = $fields[3]; subject = $fields[4]; anchor = $anchor; crossed = $crossed })
        if ($anchor -ceq 'merge') { $crossed = $true }
        # Work before a reset is not this branch's current work.
        if ($anchor -ceq 'reset') { $exhausted = $true; break }
    }
    if ($CommitsOnly) { return [pscustomobject]@{ commits = @($commits) } }

    # Only the dump roots can hold subject paths; a commit that touches
    # thousands of other files is not classified path by path.
    $roots = @($Rules.exportPath, $Rules.extensionsPath | Where-Object { $_ })
    $touched = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @(Get-ReviewScopeUncommittedPaths -Roots $roots -UntrackedPaths $UntrackedPaths)) { [void]$touched.Add($path) }
    $items = [Collections.Generic.List[object]]::new()
    $service = 0
    $truncated = $false
    foreach ($commit in $commits) {
        if ($items.Count -ge $script:ReviewScopePickerLimit) { $truncated = $true; break }
        $base = Get-ReviewScopeSinceBase -Commit $commit -BranchBase $BranchBase
        $item = [pscustomobject]@{
            commit = $commit.commit; base = $base; author = $commit.author; date = $commit.date; anchor = $commit.anchor; crossed = $commit.crossed
            label = $(switch ($commit.anchor) { 'merge' { 'обновление из master' } 'reset' { 'сброс ветки' } default { Get-ReviewScopeCommitLabel -Subject $commit.subject } })
            objects = @(); addedLines = 0; removedLines = 0; serviceBefore = $service; size = $null
            verified = ($VerifiedCommit -and $commit.commit -ceq $VerifiedCommit)
        }
        if (-not $commit.anchor) {
            $paths = @(Get-GitPathList -Arguments (@('diff', '--no-renames', '--name-only', '-z', $commit.parent, $commit.commit, '--') + $roots) |
                ForEach-Object { ([string]$_).Replace('\', '/') } | Where-Object { (Get-ReviewScopePathKind -Path $_ -Rules $Rules) -ceq 'subject' })
            foreach ($path in $paths) { [void]$touched.Add($path) }
            if ($paths.Count -eq 0) { $service++; continue }
            $item.objects = @($paths | ForEach-Object { Get-ReviewScopeObjectName -Path $_ -Rules $Rules } | Sort-Object -Unique)
            $bsl = @($paths | Where-Object { $_.EndsWith('.bsl', [StringComparison]::OrdinalIgnoreCase) })
            if ($bsl.Count -gt 0) {
                foreach ($numstat in @(Get-GitPathList -Arguments (@('diff', '--no-renames', '--numstat', '-z', $commit.parent, $commit.commit, '--') + $bsl))) {
                    $fields = ([string]$numstat) -split "`t", 3
                    if ($fields.Count -ge 3 -and $fields[0] -match '^\d+$') { $item.addedLines += [int]$fields[0]; $item.removedLines += [int]$fields[1] }
                }
            }
        }
        $item.serviceBefore = $service
        $service = 0
        # Assigned directly: an if-expression would enumerate the set.
        $filter = $null
        if ($commit.crossed) { $filter = $touched }
        $item.size = Get-ReviewScopeBslSize -BaseCommit $base -Rules $Rules -UntrackedPaths $UntrackedPaths -PathFilter $filter
        $items.Add($item)
    }
    return [pscustomobject]@{
        items = @($items)
        serviceAfter = $service
        commits = @($commits)
        allowed = @($commits | ForEach-Object commit)
        multipleAuthors = (@($items | ForEach-Object author | Sort-Object -Unique).Count -gt 1)
        complete = ($exhausted -and -not $truncated)
    }
}

function Get-ReviewScopeSinceBase {
    # An anchor starts after itself, a commit includes itself; a range that
    # crosses a refresh merge is read from the branch base.
    param([object]$Commit, [string]$BranchBase)
    if ($Commit.crossed) { return $BranchBase }
    if ($Commit.anchor) { return [string]$Commit.commit }
    return [string]$Commit.parent
}

function Get-ReviewScopeUncommittedPaths {
    param([string[]]$Roots = @(), [string[]]$UntrackedPaths = @())
    $arguments = @('diff', '--no-renames', '--name-only', '-z', 'HEAD')
    if ($Roots.Count -gt 0) { $arguments += @('--') + $Roots }
    $tracked = @(Get-GitPathList -Arguments $arguments | ForEach-Object { ([string]$_).Replace('\', '/') })
    $untracked = @($UntrackedPaths | Where-Object { $path = $_; $Roots.Count -eq 0 -or @($Roots | Where-Object { Test-ReviewScopePathUnder -Path $path -Root $_ }).Count -gt 0 })
    return @(@($tracked) + @($untracked) | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-ReviewScopeTouchedPaths {
    # Paths the branch's own first-parent commits changed after -Exclude, plus
    # uncommitted work; refresh merges contribute nothing.
    param([Parameter(Mandatory = $true)][string]$Exclude, [string[]]$UntrackedPaths = @())
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @(Get-GitPathList -Arguments @('log', '--first-parent', '--no-merges', '--no-renames', '--name-only', '-z', '--format=', 'HEAD', "^$Exclude"))) {
        $path = ([string]$record).Trim("`n").Replace('\', '/')
        if ($path) { [void]$set.Add($path) }
    }
    foreach ($path in @(Get-ReviewScopeUncommittedPaths -UntrackedPaths $UntrackedPaths)) { [void]$set.Add($path) }
    return ,$set
}

function Resolve-ReviewScopeSinceRange {
    param([string]$ReviewSince, [object]$Picker, [string]$BranchBase, [string[]]$UntrackedPaths = @())
    $resolved = ''
    try { $resolved = ([string](Get-GitOutput @('rev-parse', '--verify', '--quiet', "$ReviewSince^{commit}"))).Trim() } catch { $resolved = '' }
    $commit = @($Picker.commits | Where-Object { $_.commit -ceq $resolved })
    if (-not $resolved -or $commit.Count -eq 0) {
        throw "REVIEW_SCOPE_SINCE_NOT_ALLOWED: commit '$ReviewSince' is not one the review range can start from: it must be on this branch's own first-parent history since its creation or last reset. Repeat get-review-scope -ReviewPurpose review without -ReviewRange and pick an entry from its list, or use -ReviewRange branch."
    }
    $commit = $commit[0]
    $filter = $null
    if ($commit.crossed) {
        $exclude = if ($commit.anchor) { [string]$commit.commit } else { [string]$commit.parent }
        $filter = Get-ReviewScopeTouchedPaths -Exclude $exclude -UntrackedPaths $UntrackedPaths
    }
    return [pscustomobject]@{ base = (Get-ReviewScopeSinceBase -Commit $commit -BranchBase $BranchBase); pathFilter = $filter }
}

function Invoke-ReviewScopeWithDiscardedObjects {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)

    # New objects land in a temporary directory; existing ones stay readable as
    # an alternate. Refs, index, worktree and the object store stay unchanged.
    $objects = ([string](Get-GitOutput @('rev-parse', '--git-path', 'objects'))).Trim()
    if (-not [IO.Path]::IsPathRooted($objects)) { $objects = Join-Path $script:ProjectRoot $objects }
    $objects = [IO.Path]::GetFullPath($objects)
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("agent-1c-review-objects-" + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temporary)
    $names = @('GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_OPTIONAL_LOCKS')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        [Environment]::SetEnvironmentVariable('GIT_OBJECT_DIRECTORY', $temporary, 'Process')
        # A quoted entry keeps a path with ';' as one alternate.
        [Environment]::SetEnvironmentVariable('GIT_ALTERNATE_OBJECT_DIRECTORIES', '"' + $objects.Replace('\', '/').Replace('"', '\"') + '"', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', '0', 'Process')
        return (& $Script)
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ReviewScopeVerification {
    param([object]$State)

    $unknown = { param([string]$Reason) [pscustomobject]@{ status = 'unknown'; label = "не определено: $Reason"; verifiedCommit = ''; verifiedAt = ''; note = ''; gate1Evidence = $false } }
    if ($null -eq $State) { return (& $unknown 'нет состояния ветки разработки') }
    try {
        $verification = Invoke-ReviewScopeWithDiscardedObjects { Get-VerificationState -State $State }
    } catch {
        return (& $unknown $_.Exception.Message)
    }
    $raw = [string]$verification.status
    $status = if ($raw -in @('', 'missing')) { 'not-run' }
        elseif ($raw -ceq 'failed') { 'failed' }
        elseif (-not [string]$verification.currentFingerprint) { 'unknown' }
        elseif ($raw -ceq 'passed' -and [string]$verification.verifiedFingerprint -and [string]$verification.verifiedFingerprint -ceq [string]$verification.currentFingerprint) { 'current' }
        elseif ($raw -ceq 'partial') { 'partial' }
        else { 'stale' }
    $label = switch ($status) {
        'current' { 'пройдена на текущем коде' }
        'stale' { 'устарела: код менялся после проверки' }
        'partial' { 'неполная: часть проверок пропущена' }
        'failed' { 'не пройдена' }
        'not-run' { 'не выполнялась' }
        default { 'не определено: текущий отпечаток кода не получен' }
    }
    $note = if ($status -ceq 'current' -and -not $verification.isFreshPassed) { 'приёмка задачи или обязательства проверки не завершены; доказательство синтаксиса это не отменяет' } else { '' }
    return [pscustomobject]@{
        status = $status; label = $label
        verifiedCommit = [string]$verification.verifiedCommit; verifiedAt = [string]$verification.verifiedAt
        note = $note; gate1Evidence = ($status -ceq 'current')
    }
}

function Get-ReviewScopeRefusal {
    param([string]$Message)

    $text = [string]$Message
    $code = if ($text -cmatch '^(?<code>[A-Z][A-Z0-9_]+):') { [string]$Matches.code } else { 'REVIEW_SCOPE_DEVELOPMENT_BRANCH_REQUIRED' }
    if ($code -cnotmatch '^(REVIEW_SCOPE_|DEV_BRANCH_)') { $code = 'REVIEW_SCOPE_DEVELOPMENT_BRANCH_REQUIRED' }
    $continuation = switch -Regex ($code) {
        '^REVIEW_SCOPE_DEVELOPMENT_BRANCH_REQUIRED$' { 'Run the review from the itldev/* worktree of this work; without a development branch take the scope per review-criteria.md -> Scope (a user-named base, otherwise CONFUSION).'; break }
        '^REVIEW_SCOPE_REFRESH_PENDING$' { 'Repeat the original /itl-refresh command in the development chat of this branch, then repeat the review.'; break }
        '^REVIEW_SCOPE_MERGE_CONFLICT$' { 'Finish the original /itl-refresh command through its conflict continuation in the development chat of this branch, then repeat the review.'; break }
        '^DEV_BRANCH_TRANSFER_BASELINE_INVALID$' { 'Repeat the original /itl-refresh or /itl-reset-branch recovery command (for a fork, the original /itl-fork request) in the development chat of this branch, then repeat the review.'; break }
        '^DEV_BRANCH_RESET_IN_PROGRESS$' { 'Repeat /itl-reset-branch in the development chat of this branch, then repeat the review.'; break }
        '^(DEV_BRANCH_MANUAL_MERGE_REFRESH_REQUIRED|DEV_BRANCH_TRANSFER_SCOPE_BASE_DIVERGED)$' { 'Run /itl-refresh in the development chat of this branch, then repeat the review.'; break }
        default { 'Finish the named lifecycle command in the development chat of this branch, then repeat the review.' }
    }
    return [pscustomobject]@{ code = $code; message = $text; continuation = $continuation }
}

function Resolve-ReviewScopeBranchBase {
    # Context first, then unfinished lifecycle work, then the base owner: the
    # base owner itself rejects a non-ready branch with a generic code.
    Assert-DevelopmentBranchWorktreeContext -State $null -Operation 'get-review-scope'
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation 'get-review-scope'
    if (Test-GitMergeInProgress) {
        throw 'REVIEW_SCOPE_MERGE_CONFLICT: a merge is in progress in this worktree; its result is not the branch work yet.'
    }
    $pending = Get-PendingDevBranchMergeTransaction -State $state
    if ($null -ne $pending) {
        if ([string]$pending.operation -in @('refresh-dev-branch', 'refresh-dev-branch-lite', '')) {
            throw "REVIEW_SCOPE_REFRESH_PENDING: refresh stage '$($pending.stage)' is unfinished; master changes are merged while the recorded base is still the previous one."
        }
        throw "REVIEW_SCOPE_LIFECYCLE_PENDING: '$($pending.operation)' stage '$($pending.stage)' is unfinished."
    }
    return (Get-DevBranchTransferScopeBaseline -State $state)
}

function Get-ReviewScope {
    param(
        [ValidateSet('', 'review', 'self')][string]$ReviewPurpose = '',
        [ValidateSet('', 'branch', 'uncommitted', 'since')][string]$ReviewRange = '',
        [string]$ReviewSince = ''
    )

    if (-not $ReviewPurpose) {
        throw "REVIEW_SCOPE_PURPOSE_REQUIRED: pass -ReviewPurpose review (a separately requested review) or -ReviewPurpose self (the author's self-review)."
    }
    if ($ReviewRange -and $ReviewPurpose -cne 'review') {
        throw "REVIEW_SCOPE_RANGE_REVIEW_ONLY: -ReviewRange applies to a separately requested review; repeat with -ReviewPurpose review, or without -ReviewRange for the self-review."
    }
    if (($ReviewRange -ceq 'since') -ne [bool]$ReviewSince) {
        throw "REVIEW_SCOPE_SINCE_REQUIRED: -ReviewRange since needs -ReviewSince <commit> from the list get-review-scope shows, and -ReviewSince needs -ReviewRange since."
    }
    $refusal = $null
    try {
        $baseline = Resolve-ReviewScopeBranchBase
    } catch {
        $refusal = Get-ReviewScopeRefusal -Message $_.Exception.Message
        if ($ReviewPurpose -ceq 'review') {
            throw "$($refusal.code): review scope was not obtained. $($refusal.message) $($refusal.continuation) A review does not run lifecycle commands itself."
        }
        # Self-review needs only the current task's files; it falls back to the
        # local delta instead of blocking full-cycle completion.
        $head = Get-GitCommitOrEmpty 'HEAD'
        if (-not $head) { throw "$($refusal.code): $($refusal.message) The local delta needs a HEAD commit." }
        $baseline = [pscustomobject]@{ commit = $head; provenance = 'local-delta'; completedAt = '' }
    }
    $state = $null
    try { $state = Read-DevBranchState -Name $DevBranchName } catch { $state = $null }
    $verification = Get-ReviewScopeVerification -State $state
    $mode = $(if ($null -eq $refusal) { 'branch' } else { 'local-delta' })
    $size = $null
    $choice = $null
    $pathFilter = $null
    if ($ReviewPurpose -ceq 'review') {
        $branchBase = [string]$baseline.commit
        $rules = Get-ReviewScopeKindRules -BaseCommit $branchBase
        $untracked = @(Get-GitPathList -Arguments @('ls-files', '-z', '--others', '--exclude-standard') | ForEach-Object { ([string]$_).Replace('\', '/') })
        $picker = $null
        if (-not $ReviewRange) {
            $size = Get-ReviewScopeBslSize -BaseCommit $branchBase -Rules $rules -UntrackedPaths $untracked
            if ($size.sizeClass -ceq 'large') {
                $picker = Get-ReviewScopeCommitPicker -BranchBase $branchBase -Rules $rules -State $state -UntrackedPaths $untracked -VerifiedCommit $verification.verifiedCommit
            }
        }
        switch ($ReviewRange) {
            'uncommitted' {
                $head = Get-GitCommitOrEmpty 'HEAD'
                $baseline = [pscustomobject]@{ commit = $head; provenance = 'uncommitted'; completedAt = '' }
                $mode = 'uncommitted'
            }
            'since' {
                $commits = Get-ReviewScopeCommitPicker -BranchBase $branchBase -Rules $rules -State $state -CommitsOnly
                $range = Resolve-ReviewScopeSinceRange -ReviewSince $ReviewSince -Picker $commits -BranchBase $branchBase -UntrackedPaths $untracked
                $baseline = [pscustomobject]@{ commit = [string]$range.base; provenance = "since:$ReviewSince"; completedAt = '' }
                $pathFilter = $range.pathFilter
                $mode = 'since'
            }
        }
        if ($ReviewRange -and -not $size) {
            $size = Get-ReviewScopeBslSize -BaseCommit ([string]$baseline.commit) -Rules $rules -UntrackedPaths $untracked -PathFilter $pathFilter
        }
        if (-not $ReviewRange -and $size.sizeClass -ceq 'large') {
            $head = Get-GitCommitOrEmpty 'HEAD'
            $uncommittedSize = Get-ReviewScopeBslSize -BaseCommit $head -Rules $rules -UntrackedPaths $untracked
            $roots = @($rules.exportPath, $rules.extensionsPath | Where-Object { $_ })
            $uncommittedSubject = @(Get-ReviewScopeUncommittedPaths -Roots $roots -UntrackedPaths $untracked |
                Where-Object { (Get-ReviewScopePathKind -Path $_ -Rules $rules) -ceq 'subject' })
            $choice = [pscustomobject]@{
                uncommitted = $(if (@($uncommittedSubject).Count -gt 0) { [pscustomobject]@{ size = $uncommittedSize; files = @($uncommittedSubject).Count } } else { $null })
                picker = $picker
            }
            $mode = 'range-required'
        }
    }
    $scope = Get-ReviewScopeEntries -BaseCommit ([string]$baseline.commit) -PathFilter $pathFilter
    $objects = $null
    if ($mode -cne 'range-required') {
        $subjectPaths = @($scope.entries | Where-Object kind -eq 'subject' | ForEach-Object path)
        $objects = Get-ReviewScopeSubjectObjects -Rules $scope.rules -BaseCommit ([string]$baseline.commit) -SubjectPaths $subjectPaths
    }
    return [pscustomobject]@{
        purpose = $ReviewPurpose
        mode = $mode
        range = $(if ($ReviewRange) { $ReviewRange } elseif ($mode -ceq 'branch') { 'branch' } else { '' })
        baseCommit = [string]$baseline.commit
        baseProvenance = [string]$baseline.provenance
        # A range that crosses a refresh merge: branch-base diff of touched paths.
        pathFiltered = ($null -ne $pathFilter)
        recordedCommit = [string](Get-StateValue -State $baseline -Name 'recordedCommit' -Default '')
        refusal = $refusal
        size = $size
        choice = $choice
        verification = $verification
        entries = @($scope.entries)
        objects = $objects
    }
}

function Add-ReviewScopeGroupedLines {
    param([Collections.Generic.List[string]]$Lines, [object[]]$Entries)

    # Large unclassified sets are grouped; tests/ and .agent-1c/ by second level.
    if (@($Entries).Count -le 20) {
        foreach ($entry in @($Entries)) { $Lines.Add("- $($entry.command)") }
        return
    }
    $groups = @($Entries | Group-Object {
        $segments = @(([string]$_.path) -split '/')
        if ($segments.Count -le 1) { '<root>' }
        elseif ($segments.Count -gt 2 -and $segments[0] -in @('tests', '.agent-1c')) { "$($segments[0])/$($segments[1])/" }
        else { "$($segments[0])/" }
    } | Sort-Object Name)
    foreach ($group in $groups) { $Lines.Add("- $($group.Name) ($($group.Count))") }
}

function Write-ReviewScopeRunUserReport {
    param([Parameter(Mandatory = $true)][object]$Scope)

    $entries = @($Scope.entries)
    $byKind = @{}
    foreach ($kind in @('subject', 'tests', 'requirements', 'unclassified', 'excluded', 'always-excluded')) { $byKind[$kind] = @($entries | Where-Object kind -eq $kind) }
    # A range choice stops before the object list is built.
    $objectCount = if ($null -eq $Scope.objects) { 0 } else { (@($Scope.objects.groups | ForEach-Object { @($_.items).Count }) | Measure-Object -Sum).Sum }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('## Объём ревью')
    Add-RunUserReportLine -Lines $lines -Label 'Назначение' -Value $Scope.purpose
    Add-RunUserReportLine -Lines $lines -Label 'Режим' -Value $Scope.mode
    Add-RunUserReportLine -Lines $lines -Label 'База' -Value $Scope.baseCommit
    Add-RunUserReportLine -Lines $lines -Label 'Происхождение базы' -Value $Scope.baseProvenance
    if ($Scope.recordedCommit) { Add-RunUserReportLine -Lines $lines -Label 'Записанная база ветки' -Value $Scope.recordedCommit }
    if ($Scope.pathFiltered) { Add-RunUserReportLine -Lines $lines -Label 'Охват диапазона' -Value 'диапазон начинается до обновления из master: в ревью только файлы, которые ветка меняла с выбранного коммита; разница от базы ветки, поэтому в них видны и более ранние правки ветки, а изменений master нет' }
    if ($null -ne $Scope.refusal) {
        Add-RunUserReportLine -Lines $lines -Label 'Охват' -Value "limited: $($Scope.refusal.code)"
        Add-RunUserReportLine -Lines $lines -Label 'Причина' -Value $Scope.refusal.message
        Add-RunUserReportLine -Lines $lines -Label 'Рекомендация пользователю' -Value $Scope.refusal.continuation
    }
    if ($null -ne $Scope.size) { Add-RunUserReportLine -Lines $lines -Label 'Размер объёма' -Value (Format-ReviewScopeSize -Size $Scope.size) }
    $verification = $Scope.verification
    $verificationText = $verification.label
    if ($verification.verifiedCommit -and $verification.status -notin @('not-run', 'unknown')) { $verificationText += "; коммит $($verification.verifiedCommit), $($verification.verifiedAt)" }
    if ($verification.note) { $verificationText += "; $($verification.note)" }
    Add-RunUserReportLine -Lines $lines -Label 'Проверка /itl-check' -Value $verificationText
    Add-RunUserReportLine -Lines $lines -Label 'Гейт 1 (синтаксис)' -Value $(if ($verification.gate1Evidence) { 'подтверждён проверкой /itl-check на текущем коде' } else { 'не подтверждён; рекомендация пользователю: запустите /itl-check в чате разработки этой ветки' })
    if ($Scope.mode -ceq 'range-required') {
        Write-ReviewScopeRangeChoice -Lines $lines -Scope $Scope
        Set-RunStage -Stage 'review-scope.range-required' -Detail ("base=$($Scope.baseCommit); bslBytes=$($Scope.size.bytes); threshold=$script:ReviewScopeLargeBslBytes; verification=$($verification.status)")
        Write-AndSetRunUserReport -Lines $lines
        return
    }
    if ($entries.Count -eq 0) {
        Add-RunUserReportLine -Lines $lines -Label 'Результат' -Value 'изменений для ревью нет'
    }
    Add-RunUserReportLine -Lines $lines -Label 'Предмет ревью' -Value "$($byKind.subject.Count) файлов, $([int]$objectCount) объектов"
    Add-RunUserReportLine -Lines $lines -Label 'Тесты доработки' -Value $byKind.tests.Count
    Add-RunUserReportLine -Lines $lines -Label 'Источник требований' -Value $byKind.requirements.Count
    Add-RunUserReportLine -Lines $lines -Label 'Не классифицирован' -Value $byKind.unclassified.Count
    Add-RunUserReportLine -Lines $lines -Label 'Исключено (управляемые ITL, квитанции диагностики)' -Value $byKind.excluded.Count
    Add-RunUserReportLine -Lines $lines -Label 'Исключено всегда (ConfigDumpInfo.xml)' -Value $byKind['always-excluded'].Count
    Add-RunUserReportLine -Lines $lines -Label 'Команды чтения' -Value 'PowerShell после [Console]::OutputEncoding = [Text.Encoding]::UTF8; читайте нужные разделы этого файла, а не весь файл'

    $lines.Add('')
    $lines.Add('## Предмет ревью: объекты')
    foreach ($group in @($Scope.objects.groups)) {
        $lines.Add('')
        $lines.Add("### $($group.root)")
        foreach ($item in @($group.items)) {
            $parts = @($item.parts)
            $suffix = if ($parts.Count -gt 0) { ": $($parts -join ', ')" } else { '' }
            $lines.Add("- $($item.name) ($($item.scope))$suffix")
        }
        foreach ($path in @($group.unresolvedPaths)) { $lines.Add("- не разобран: $path") }
    }
    foreach ($path in @($Scope.objects.unrootedPaths)) { $lines.Add("- не разобран: $path") }
    foreach ($section in @(
        @{ kind = 'subject'; title = 'Предмет ревью: файлы' },
        @{ kind = 'tests'; title = 'Тесты доработки' },
        @{ kind = 'requirements'; title = 'Источник требований' }
    )) {
        $lines.Add('')
        $lines.Add("## $($section.title)")
        foreach ($entry in $byKind[$section.kind]) { $lines.Add("- $($entry.command)") }
    }
    $lines.Add('')
    $lines.Add('## Не классифицирован')
    Add-ReviewScopeGroupedLines -Lines $lines -Entries $byKind.unclassified
    Set-RunStage -Stage 'review-scope.ready' -Detail ("mode=$($Scope.mode); base=$($Scope.baseCommit); provenance=$($Scope.baseProvenance); subject=$($byKind.subject.Count); objects=$([int]$objectCount); tests=$($byKind.tests.Count); requirements=$($byKind.requirements.Count); unclassified=$($byKind.unclassified.Count); excluded=$($byKind.excluded.Count + $byKind['always-excluded'].Count)" +
        $(if ($null -ne $Scope.size) { "; size=$($Scope.size.sizeClass); bslBytes=$($Scope.size.bytes)" } else { '' }) +
        "; verification=$($Scope.verification.status)" +
        $(if ($null -ne $Scope.refusal) { "; limited=$($Scope.refusal.code)" } else { '' }))
    Write-AndSetRunUserReport -Lines $lines
}

function Get-ReviewScopeRangeCommand {
    param([string]$Range, [string]$Since = '')
    $command = 'powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-itl-command.ps1 -- -Action get-review-scope -ReviewPurpose review -ReviewRange ' + $Range
    if ($Since) { $command += " -ReviewSince $Since" }
    return $command
}

function Write-ReviewScopeRangeChoice {
    param([Collections.Generic.List[string]]$Lines, [object]$Scope)

    $picker = $Scope.choice.picker
    $Lines.Add('')
    $Lines.Add('## Нужен выбор объёма ревью')
    $Lines.Add('')
    # Every option is one numbered entry: a commit list nested in one option
    # was squeezed into a few dialog buttons and the rest went unseen.
    $Lines.Add("Объём ревью большой (порог $([int]($script:ReviewScopeLargeBslBytes / 1024)) КБ текста изменений BSL). Не начинайте ревью. Покажите пользователю все варианты ниже одним нумерованным списком или таблицей, с их номерами, текстом и цифрами, без сокращений и без отбора, и спросите «Какой объём ревьюировать? Ответьте номером варианта или хэшем коммита». Не сводите варианты к кнопкам диалога: они не помещаются в его лимит. Затем выполните команду выбранного варианта.")
    $number = 1
    if ($null -ne $Scope.choice.uncommitted) {
        $Lines.Add('')
        $Lines.Add("### $number. Только незакоммиченные изменения")
        $Lines.Add("- $(Format-ReviewScopeSize -Size $Scope.choice.uncommitted.size); файлов предмета ревью: $($Scope.choice.uncommitted.files)")
        $Lines.Add("- команда: $(Get-ReviewScopeRangeCommand -Range uncommitted)")
        $number++
    }
    if (@($picker.items).Count -eq 0) {
        $Lines.Add('')
        $Lines.Add('Коммитов ветки с изменениями 1С нет.')
    }
    foreach ($item in @($picker.items)) {
        if ($item.serviceBefore -gt 0) {
            $Lines.Add('')
            $Lines.Add("(служебные коммиты ITL без изменений 1С: $($item.serviceBefore))")
        }
        $when = [string]$item.date
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($item.date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $when = $parsed.ToLocalTime().ToString('dd.MM HH:mm')
        }
        $short = $item.commit.Substring(0, 12)
        $title = if ($item.anchor) { "После отметки «$($item.label)» $short · $when" } else { "С коммита $short · $when · $($item.label)" }
        $Lines.Add('')
        $Lines.Add("### $number. $title")
        $parts = @()
        if ($picker.multipleAuthors) { $parts += "автор: $($item.author)" }
        if (@($item.objects).Count -gt 0) {
            $shown = @($item.objects | Select-Object -First 3) -join ', '
            if (@($item.objects).Count -gt 3) { $shown += ", ещё $(@($item.objects).Count - 3)" }
            $parts += $shown
        }
        if ($item.addedLines -gt 0 -or $item.removedLines -gt 0) { $parts += "BSL этого коммита +$($item.addedLines)/-$($item.removedLines)" }
        if ($item.verified) { $parts += 'здесь пройдена /itl-check' }
        if ($parts.Count -gt 0) { $Lines.Add("- $($parts -join ' · ')") }
        $from = if ($item.anchor) { 'после этого' } else { 'с этого коммита' }
        $Lines.Add("- объём $from`: $(Format-ReviewScopeSize -Size $item.size)")
        if ($item.crossed) { $Lines.Add('- до обновления из master: в ревью файлы, которые ветка меняла с этого места; разница показана от базы ветки, поэтому в них видны и более ранние правки ветки, а изменений master нет') }
        $Lines.Add("- команда: $(Get-ReviewScopeRangeCommand -Range since -Since $short)")
        $number++
    }
    if ($picker.serviceAfter -gt 0) {
        $Lines.Add('')
        $Lines.Add("(служебные коммиты ITL без изменений 1С: $($picker.serviceAfter))")
    }
    if (-not $picker.complete) {
        $Lines.Add('')
        $Lines.Add('(более ранние коммиты ветки в список не вошли: их можно назвать хэшем, или выберите «вся работа ветки»)')
    }
    $Lines.Add('')
    $Lines.Add("### $number. Вся работа ветки (большой объём)")
    $Lines.Add("- $(Format-ReviewScopeSize -Size $Scope.size)")
    $Lines.Add('- синтаксис подтверждается только свежей /itl-check; гейты 2–3 запускаются текстом по изменённым процедурам, выбранным по риску; остальное помечается как «не проверено автоматически»')
    $Lines.Add("- команда: $(Get-ReviewScopeRangeCommand -Range branch)")
}

function Invoke-ReviewScopeAction {
    param([string]$ReviewPurpose, [string]$ReviewRange = '', [string]$ReviewSince = '')
    Write-ReviewScopeRunUserReport -Scope (Get-ReviewScope -ReviewPurpose $ReviewPurpose -ReviewRange $ReviewRange -ReviewSince $ReviewSince)
}
