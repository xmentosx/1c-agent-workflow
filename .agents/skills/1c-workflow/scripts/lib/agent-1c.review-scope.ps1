# Review scope is a read-only projection of the branch transfer scope base:
# everything that still differs from it, by file kind. It writes no branch
# state, index, worktree, Git objects or refs and takes no lifecycle lock.

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
    $groups = @(foreach ($root in @($roots | Sort-Object)) {
        $plan = Get-ConfigRepositoryTransferPlan -ExportPath $root -BaseCommit $BaseCommit
        [pscustomobject]@{ root = $root; items = @($plan.items); unresolvedPaths = @($plan.unresolvedPaths) }
    })
    return [pscustomobject]@{ groups = $groups; unrootedPaths = @($unrooted) }
}

function Get-ReviewScopeEntries {
    param([Parameter(Mandatory = $true)][string]$BaseCommit)

    $tracked = @(Get-GitPathList -Arguments @('diff', '--no-renames', '--name-only', '-z', $BaseCommit))
    $untracked = @(Get-GitPathList -Arguments @('ls-files', '-z', '--others', '--exclude-standard'))
    $rules = Get-ReviewScopeKindRules -BaseCommit $BaseCommit
    $untrackedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $untracked) { [void]$untrackedSet.Add(([string]$path).Replace('\', '/')) }
    $entries = @(foreach ($path in @(@($tracked) + @($untracked) | ForEach-Object { ([string]$_).Replace('\', '/').Trim('/') } | Where-Object { $_ } | Sort-Object -Unique)) {
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
    param([ValidateSet('', 'review', 'self')][string]$ReviewPurpose = '')

    if (-not $ReviewPurpose) {
        throw "REVIEW_SCOPE_PURPOSE_REQUIRED: pass -Purpose review (a separately requested review) or -Purpose self (the author's self-review)."
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
    $scope = Get-ReviewScopeEntries -BaseCommit ([string]$baseline.commit)
    $subjectPaths = @($scope.entries | Where-Object kind -eq 'subject' | ForEach-Object path)
    $objects = Get-ReviewScopeSubjectObjects -Rules $scope.rules -BaseCommit ([string]$baseline.commit) -SubjectPaths $subjectPaths
    return [pscustomobject]@{
        purpose = $ReviewPurpose
        mode = $(if ($null -eq $refusal) { 'branch' } else { 'local-delta' })
        baseCommit = [string]$baseline.commit
        baseProvenance = [string]$baseline.provenance
        recordedCommit = [string](Get-StateValue -State $baseline -Name 'recordedCommit' -Default '')
        refusal = $refusal
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
    $objectCount = (@($Scope.objects.groups | ForEach-Object { @($_.items).Count }) | Measure-Object -Sum).Sum
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('## Объём ревью')
    Add-RunUserReportLine -Lines $lines -Label 'Назначение' -Value $Scope.purpose
    Add-RunUserReportLine -Lines $lines -Label 'Режим' -Value $Scope.mode
    Add-RunUserReportLine -Lines $lines -Label 'База' -Value $Scope.baseCommit
    Add-RunUserReportLine -Lines $lines -Label 'Происхождение базы' -Value $Scope.baseProvenance
    if ($Scope.recordedCommit) { Add-RunUserReportLine -Lines $lines -Label 'Записанная база ветки' -Value $Scope.recordedCommit }
    if ($null -ne $Scope.refusal) {
        Add-RunUserReportLine -Lines $lines -Label 'Охват' -Value "limited: $($Scope.refusal.code)"
        Add-RunUserReportLine -Lines $lines -Label 'Причина' -Value $Scope.refusal.message
        Add-RunUserReportLine -Lines $lines -Label 'Рекомендация пользователю' -Value $Scope.refusal.continuation
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
        $(if ($null -ne $Scope.refusal) { "; limited=$($Scope.refusal.code)" } else { '' }))
    Write-AndSetRunUserReport -Lines $lines
}

function Invoke-ReviewScopeAction {
    param([string]$ReviewPurpose)
    Write-ReviewScopeRunUserReport -Scope (Get-ReviewScope -ReviewPurpose $ReviewPurpose)
}
