# Branch-owned transfer of a checked configuration CF into the repository-connected
# source infobase (openspec add-configuration-repository-transfer). Boundary approved
# 2026-11-25 in docs/package-architecture.md: partial load of the task's files into
# locked objects, /UpdateDBCfg, commit of the listed objects without -keepLocked and a
# master capture without a repository update. One stage record lives in branch state.

$script:RepositoryTransferStateKey = 'repositoryTransfer'
$script:RepositoryTransferHistoryLabels = @{
    'Версия:' = 'version'; 'Пользователь:' = 'user'; 'Дата создания:' = 'date'; 'Время создания:' = 'time'
    'Комментарий:' = 'comment'; 'Добавлены:' = 'added'; 'Изменены:' = 'changed'; 'Удалены:' = 'deleted'
}

function ConvertFrom-RepositoryTransferCompareReport {
    # /CompareCfg -ReportType Full -ReportFormat txt: legend lines, then a tree
    # "<tabs>- [***|-->|<--|^]Name". Depth 1 is the configuration; depth 2 holds
    # top-level objects or the configuration's own properties.
    param([AllowEmptyString()][string]$Text)
    $objects = [System.Collections.Generic.List[string]]::new()
    $rootProperties = [System.Collections.Generic.List[string]]::new()
    $entries = 0
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^(?<tabs>\t+)- (?<body>.+)$') { continue }
        $entries++
        if ($Matches.tabs.Length -ne 2) { continue }
        $body = [string]$Matches.body
        if ($body -match '^\^?(\*\*\*|-->|<--)?(?<name>[^\s.]+\.[^\s]+)$') {
            $parts = ([string]$Matches.name).Split('.')
            $objects.Add(($parts[0] + '.' + $parts[1])) | Out-Null
        } else {
            $rootProperties.Add($body) | Out-Null
        }
    }
    return [pscustomobject]@{
        empty = ($entries -eq 0)
        objects = @($objects | Sort-Object -Unique)
        rootProperties = @($rootProperties)
    }
}

function ConvertFrom-RepositoryTransferHistoryReport {
    # /ConfigurationRepositoryReport writes MXL only; its text cells are {"#","..."}.
    param([byte[]]$Bytes)
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $cells = @([regex]::Matches($text, '\{"#","((?:[^"]|"")*)"\}') | ForEach-Object { $_.Groups[1].Value.Replace('""', '"') })
    $versions = [System.Collections.Generic.List[object]]::new()
    $current = $null
    $field = ''
    foreach ($cell in $cells) {
        $trimmed = $cell.Trim()
        if ($script:RepositoryTransferHistoryLabels.ContainsKey($trimmed)) {
            $field = $script:RepositoryTransferHistoryLabels[$trimmed]
            if ($field -eq 'version') { $current = $null }
            continue
        }
        if ($trimmed.EndsWith(':')) { $field = ''; continue }
        if (-not $field) { continue }
        if ($field -eq 'version') {
            if ($trimmed -notmatch '^\d+$') { $field = ''; continue }
            $current = [ordered]@{ version = [int]$trimmed; user = ''; date = ''; time = ''; comment = ''; added = @(); changed = @(); deleted = @() }
            $versions.Add($current) | Out-Null
            $field = ''
            continue
        }
        if ($null -eq $current) { continue }
        if ($field -in @('added', 'changed', 'deleted')) {
            if ($trimmed) { $current[$field] = @($current[$field]) + $trimmed }
            continue
        }
        $current[$field] = $cell
        $field = ''
    }
    return @($versions | ForEach-Object { [pscustomobject]$_ })
}

function Get-RepositoryTransferWorkRoot {
    param([object]$State)
    $root = Get-StateValue -State $State -Name 'stateProjectRoot' -Default $script:ProjectRoot
    $safe = [string](Get-StateValue -State $State -Name 'safeDevBranchName' -Default 'branch')
    $path = Join-Path $root ".agent-1c\dev-branches\$safe-repository-transfer"
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return (Resolve-Agent1cFullPath -Path $path)
}

function Invoke-RepositoryTransferDesigner {
    param([string[]]$DesignerArgs, [switch]$Repository)
    $arguments = if ($Repository) { (New-RepositoryConnectionArgs) + $DesignerArgs } else { $DesignerArgs }
    Invoke-Designer -InfoBasePath (Get-SourceInfoBasePath) -InfoBaseKind (Get-InfoBaseKind) -DesignerArgs $arguments | Out-Null
    $log = if ($script:LastLogPath -and (Test-Path -LiteralPath $script:LastLogPath -PathType Leaf)) { Read-Utf8Text -Path $script:LastLogPath } else { '' }
    # 8.3.27 reports a missing repository version with exit code 0.
    if ($log -match 'не существует запрашиваемой версии') {
        throw "REPOSITORY_TRANSFER_VERSION_MISSING: $($log.Trim())"
    }
    if ($log -match 'Ошибка блокировки информационной базы для конфигурирования') {
        throw 'REPOSITORY_TRANSFER_INFOBASE_BUSY: the source infobase is open in Designer. Close Designer, then repeat the same transfer step.'
    }
    return $log
}

function Invoke-RepositoryTransferCompare {
    # FirstVersion > 0 compares that repository version; 0 uses the main configuration.
    param([int]$FirstVersion = 0, [string]$SecondFile = '', [Parameter(Mandatory = $true)][string]$ReportPath)
    $first = if ($FirstVersion -gt 0) { @('-FirstConfigurationType', 'ConfigurationRepository', '-FirstVersion', [string]$FirstVersion) } else { @('-FirstConfigurationType', 'MainConfiguration') }
    $second = if ($SecondFile) { @('-SecondConfigurationType', 'File', '-SecondFile', $SecondFile) } else { @('-SecondConfigurationType', 'MainConfiguration') }
    if (Test-Path -LiteralPath $ReportPath) { Remove-Item -LiteralPath $ReportPath -Force }
    Invoke-RepositoryTransferDesigner -Repository:($FirstVersion -gt 0) -DesignerArgs (@('/CompareCfg') + $first + $second + @('-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', $ReportPath)) | Out-Null
    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        throw "REPOSITORY_TRANSFER_COMPARE_FAILED: Designer did not write $ReportPath."
    }
    $text = [IO.File]::ReadAllText($ReportPath, [Text.Encoding]::Unicode)
    Write-Utf8Text -Path ([IO.Path]::ChangeExtension($ReportPath, '.utf8.txt')) -Value $text
    $parsed = ConvertFrom-RepositoryTransferCompareReport -Text $text
    $parsed | Add-Member -NotePropertyName path -NotePropertyValue ([IO.Path]::ChangeExtension($ReportPath, '.utf8.txt'))
    $parsed | Add-Member -NotePropertyName sha256 -NotePropertyValue ((Get-FileHash -LiteralPath $ReportPath -Algorithm SHA256).Hash.ToLowerInvariant())
    return $parsed
}

function Get-RepositoryTransferVersions {
    param([int]$From, [int]$To = 0, [Parameter(Mandatory = $true)][string]$WorkRoot)
    $path = Join-Path $WorkRoot ('history-{0}-{1}.mxl' -f $From, $To)
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    $range = @('-NBegin', [string]$From)
    if ($To -gt 0) { $range += @('-NEnd', [string]$To) }
    Invoke-RepositoryTransferDesigner -Repository -DesignerArgs (@('/ConfigurationRepositoryReport', $path) + $range) | Out-Null
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    return @(ConvertFrom-RepositoryTransferHistoryReport -Bytes ([IO.File]::ReadAllBytes($path)))
}

function Get-RepositoryTransferLatestVersion {
    # A one-version report of a missing version is empty, so the latest number is
    # found without reading the whole history.
    param([int]$Hint = 0, [Parameter(Mandatory = $true)][string]$WorkRoot)
    if ($Hint -gt 0) {
        $tail = @(Get-RepositoryTransferVersions -From $Hint -WorkRoot $WorkRoot)
        if ($tail.Count -gt 0) { return [int](($tail | Measure-Object -Property version -Maximum).Maximum) }
    }
    $exists = { param([int]$Number) @(Get-RepositoryTransferVersions -From $Number -To $Number -WorkRoot $WorkRoot | Where-Object version -eq $Number).Count -gt 0 }
    if (-not (& $exists 1)) { throw 'REPOSITORY_TRANSFER_REPOSITORY_EMPTY: the configuration repository has no versions.' }
    $low = 1; $high = 2
    while (& $exists $high) { $low = $high; $high *= 2 }
    while ($high - $low -gt 1) {
        $middle = [int][math]::Floor(($low + $high) / 2)
        if (& $exists $middle) { $low = $middle } else { $high = $middle }
    }
    return $low
}

function Get-RepositoryTransferValue {
    # Records are ordered dictionaries while a step runs and objects after JSON.
    param([object]$Record, [string]$Name, [object]$Default = $null)
    if ($null -eq $Record) { return $Default }
    if ($Record -is [Collections.IDictionary]) {
        if (-not $Record.Contains($Name)) { return $Default }
        $value = $Record[$Name]
    } else {
        $property = $Record.PSObject.Properties[$Name]
        if ($null -eq $property) { return $Default }
        $value = $property.Value
    }
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $Default }
    return $value
}

function Get-RepositoryTransferRecord {
    param([object]$State)
    $record = Get-StateValue -State $State -Name $script:RepositoryTransferStateKey -Default $null
    if ($null -eq $record) { return $null }
    return $record
}

function Save-RepositoryTransferRecord {
    param([object]$State, [Collections.IDictionary]$Record)
    $Record['updatedAt'] = (Get-Date).ToString('o')
    Update-DevBranchState -State $State -Updates @{ $script:RepositoryTransferStateKey = $Record }
}

function ConvertTo-RepositoryTransferHashtable {
    param([object]$Value)
    if ($null -eq $Value) { return [ordered]@{} }
    if ($Value -is [Collections.IDictionary]) { return $Value }
    $result = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = $property.Value }
    return $result
}

function Assert-RepositoryTransferBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation 'repository-transfer'
    if ((Get-DevBranchKind -State $state) -ne 'configuration') {
        throw 'REPOSITORY_TRANSFER_EXTENSION_UNSUPPORTED: repository transfer covers configuration branches only; extension (CFE) branches keep the manual route.'
    }
    if (-not (Get-SourceUsesRepository)) {
        throw 'REPOSITORY_TRANSFER_NOT_CONFIGURED: SOURCE_USES_REPOSITORY=false; the project has no configuration repository.'
    }
    if ((Get-DevBranchInitializationStatus -State $state) -ne 'ready') {
        throw 'REPOSITORY_TRANSFER_BRANCH_NOT_READY: the development branch must be ready.'
    }
    return $state
}

function Get-RepositoryTransferCheckedResult {
    # The CF must be the fresh-passed export of the current HEAD and unchanged since.
    param([object]$State)
    $manifestPath = [string](Get-StateValue -State $State -Name 'lastResultManifestPath' -Default '')
    if (-not $manifestPath -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'REPOSITORY_TRANSFER_RESULT_MISSING: run /itl-check and /itl-result first.'
    }
    $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    $cfPath = [string]$manifest.artifact.path
    $head = Get-CurrentCommit
    $verification = Get-VerificationState -State $State
    $problems = @()
    if ([string]$manifest.operation -ne 'export-dev-branch-result' -or [string]$manifest.artifact.kind -ne 'cf') { $problems += 'the last result is not a configuration CF export' }
    if ([string]$manifest.verification.decision -ne 'fresh-passed' -or -not [bool]$manifest.verification.freshPassed) { $problems += 'the CF was exported without fresh passed verification' }
    if ([string]$manifest.commits.development -ne $head) { $problems += 'HEAD changed after the export' }
    if (-not [bool]$manifest.source.worktreeClean -or (Test-GitHasChanges)) { $problems += 'the worktree has uncommitted changes' }
    if (-not $verification.isFreshPassed -or [string]$verification.currentFingerprint -cne [string]$manifest.verification.currentFingerprint) { $problems += 'fresh passed verification no longer matches the exported content' }
    if (-not (Test-Path -LiteralPath $cfPath -PathType Leaf)) { $problems += "the CF file is missing: $cfPath" }
    elseif ((Get-FileHash -LiteralPath $cfPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.artifact.sha256) { $problems += 'the CF SHA-256 differs from its manifest' }
    if ($problems.Count -gt 0) {
        Set-RunFailureContext -Category 'source-integrity' -RequiredAction 'Run /itl-check after the final edit, then /itl-result, and repeat the transfer command.'
        throw "REPOSITORY_TRANSFER_RESULT_STALE: $($problems -join '; ')."
    }
    return [pscustomobject]@{ cfPath = $cfPath; sha256 = [string]$manifest.artifact.sha256; manifestPath = $manifestPath; head = $head }
}

function Get-RepositoryTransferScope {
    param([object]$State)
    $exportPath = Get-ExportPath
    $plan = Get-ConfigRepositoryTransferPlan -ExportPath $exportPath -State $State -ForRepositoryLock
    if (@($plan.unresolvedPaths).Count -gt 0) {
        throw "REPOSITORY_TRANSFER_UNRESOLVED_PATHS: $(@($plan.unresolvedPaths) -join ', ')"
    }
    $items = @($plan.items | Where-Object { [string]$_.name -ne 'Конфигурация' })
    if ($items.Count -eq 0) { throw 'REPOSITORY_TRANSFER_EMPTY: the branch has no configuration changes to transfer.' }
    $prefix = ([string]$plan.exportPath).TrimEnd('/') + '/'
    $rootRequired = (-not (Test-RepositoryTransferGit diff --quiet ([string]$plan.baseCommit) -- ($prefix + 'Configuration.xml'))) -or (@($plan.items | Where-Object { [string]$_.name -eq 'Конфигурация' }).Count -gt 0)
    $loadPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($repoPath in @($items | ForEach-Object { $_.paths })) {
        $full = Join-Path $script:ProjectRoot $repoPath
        if ((Test-Path -LiteralPath $full -PathType Leaf) -and ([IO.Path]::GetFileName($repoPath) -ine 'ConfigDumpInfo.xml')) { $loadPaths.Add((Resolve-Agent1cFullPath -Path $full)) | Out-Null }
    }
    if ($rootRequired) { $loadPaths.Add((Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot ($prefix + 'Configuration.xml')))) | Out-Null }
    return [ordered]@{
        baseCommit = [string]$plan.baseCommit
        exportPath = (Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot $plan.exportPath))
        objects = @($items | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
        fullObjects = @($items | Where-Object { [string]$_.scope -eq 'full' } | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
        rootRequired = [bool]$rootRequired
        loadPaths = @($loadPaths | Sort-Object -Unique)
    }
}

function Get-RepositoryTransferGitLine {
    # Empty native output casts to $null in Windows PowerShell 5.1; stderr must not
    # become a terminating NativeCommandError under ErrorActionPreference Stop.
    $ErrorActionPreference = 'Continue'
    $output = @(& git -C $script:ProjectRoot @args 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { return '' }
    return ([string]$output[0]).Trim()
}

function Test-RepositoryTransferGit {
    # Exit code 0 of a quiet Git check (diff --quiet, merge-base --is-ancestor).
    $ErrorActionPreference = 'Continue'
    & git -C $script:ProjectRoot @args 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-RepositoryTransferTopLevelNames {
    param([string[]]$Objects)
    return @($Objects | ForEach-Object { $parts = ([string]$_).Split('.'); if ($parts.Count -ge 2) { $parts[0] + '.' + $parts[1] } else { [string]$_ } } | Sort-Object -Unique)
}

function Assert-RepositoryTransferReportScope {
    param([object]$Report, [Collections.IDictionary]$Scope)
    $allowed = Get-RepositoryTransferTopLevelNames -Objects $Scope.objects
    $outside = @($Report.objects | Where-Object { $_ -notin $allowed })
    if (@($Report.rootProperties).Count -gt 0 -and -not $Scope.rootRequired) { $outside += 'Конфигурация (свойства)' }
    if ($outside.Count -gt 0) {
        Set-RunFailureContext -Category 'source-integrity' -RequiredAction 'Run /itl-refresh so the branch includes the latest repository version, then /itl-check, /itl-result and the transfer command again.'
        throw "REPOSITORY_TRANSFER_SCOPE_MISMATCH: the repository comparison changes objects outside the task: $($outside -join ', '). Report: $($Report.path)"
    }
}

function Get-RepositoryTransferVersionTime {
    param([object]$Version)
    $stamp = "$([string]$Version.date) $([string]$Version.time)".Trim()
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($stamp, 'dd.MM.yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        throw "REPOSITORY_TRANSFER_HISTORY_UNREADABLE: version $($Version.version) has no creation time ('$stamp')."
    }
    return $parsed
}

function Assert-RepositoryTransferMasterCurrent {
    # master was captured from the source infobase; it must not predate the latest
    # repository version, otherwise the branch misses that version.
    param([int]$LatestVersion, [string]$WorkRoot)
    $version = @(Get-RepositoryTransferVersions -From $LatestVersion -To $LatestVersion -WorkRoot $WorkRoot) | Select-Object -First 1
    if ($null -eq $version) { throw "REPOSITORY_TRANSFER_HISTORY_UNREADABLE: version $LatestVersion is missing from the history report." }
    $master = Get-MasterBranch
    $captured = Get-RepositoryTransferGitLine log -1 --format=%cI $master -- (Get-ExportPath)
    if (-not $captured) { throw 'REPOSITORY_TRANSFER_MASTER_UNKNOWN: master has no configuration capture.' }
    $masterTime = [datetimeoffset]::Parse($captured).LocalDateTime
    $contained = Test-RepositoryTransferGit merge-base --is-ancestor $master HEAD
    if (-not $contained -or $masterTime -lt (Get-RepositoryTransferVersionTime -Version $version)) {
        Set-RunFailureContext -Category 'source-integrity' -RequiredAction 'Run /itl-refresh, then /itl-check, /itl-result and the transfer command again.'
        $reason = if (-not $contained) { 'the branch does not contain the current master' } else { "repository version $LatestVersion was created after the last master capture" }
        throw "REPOSITORY_TRANSFER_BRANCH_BEHIND_REPOSITORY: $reason."
    }
}

function Write-RepositoryTransferObjectList {
    # A new or wholly changed object is committed with its child objects.
    param([string[]]$Objects, [string[]]$FullObjects = @(), [bool]$IncludeRoot, [string]$Path)
    $items = @($Objects | ForEach-Object { [pscustomobject]@{ name = $_; scope = $(if ($_ -in $FullObjects) { 'full' } else { 'partial' }) } })
    if ($IncludeRoot) { $items += [pscustomobject]@{ name = 'Конфигурация'; scope = 'partial' } }
    return (Write-ConfigRepositoryObjectList -Plan ([pscustomobject]@{ items = $items }) -Path $Path)
}

function Add-RepositoryTransferStatusLines {
    param([System.Collections.Generic.List[string]]$Lines, [object]$Record)
    if ($null -eq $Record) {
        Add-RunUserReportLine -Lines $Lines -Label 'Перенос' -Value 'не начат'
        return
    }
    foreach ($pair in @(
        @('Этап', 'stage'), @('Режим просмотра', 'mode'), @('Попытка', 'attempt'), @('Версия хранилища до переноса', 'baseVersion'),
        @('CF', 'cfPath'), @('SHA-256 CF', 'cfSha256'), @('Итог относительно хранилища', 'totalReportPath'), @('Изменения в ИБ сейчас', 'nowReportPath'),
        @('Решение', 'decision'), @('Дымовая проверка', 'smoke'), @('Созданная версия', 'committedVersion'), @('master', 'masterCommit'), @('Mantis', 'mantis'), @('Ошибка', 'lastError'))) {
        $value = [string](Get-RepositoryTransferValue -Record $Record -Name $pair[1] -Default '')
        if ($value) { Add-RunUserReportLine -Lines $Lines -Label $pair[0] -Value $value }
    }
    $objects = @(Get-RepositoryTransferValue -Record $Record -Name 'objects' -Default @())
    if ($objects.Count -gt 0) { $Lines.Add('Объекты: ' + ($objects -join ', ')) | Out-Null }
    $next = [string](Get-RepositoryTransferValue -Record $Record -Name 'nextAction' -Default '')
    if ($next) { Add-RunUserReportLine -Lines $Lines -Label 'Доступное действие' -Value $next }
}

function Write-RepositoryTransferReport {
    param([string]$Title, [object]$Record)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("## $Title") | Out-Null
    Add-RepositoryTransferStatusLines -Lines $lines -Record $Record
    Write-AndSetRunUserReport -Lines $lines
}

function Get-RepositoryTransferNextAction {
    param([string]$Stage, [string]$Mode)
    switch ($Stage) {
        'prepared' { if ($Mode -eq 'review') { return 'покажите человеку итоговое сравнение; после его ответа: approve или reject' } else { return 'изучите итоговое сравнение: approve или reject; непонятную деталь покажите человеку' } }
        'approved' { return 'apply' }
        'applying' { return 'apply (сверит фактическое состояние ИБ)' }
        'applied' { return 'выполните дымовой сценарий и запишите его результат: smoke' }
        'smoke-failed' { return 'исправьте ветку, затем /itl-check, /itl-result и повторите команду переноса' }
        'smoke-unavailable' { return 'решение человека: commit с -RepositoryTransferDecidedBy human или cancel' }
        'smoke-passed' { return 'commit с комментарием версии' }
        'committing' { return 'commit (сверит историю хранилища)' }
        'committed' { return 'update-master' }
        'master-updated' { return 'запишите итог в Mantis или пропустите: complete' }
        'returned' { return 'исправьте ветку по замечаниям, затем /itl-check, /itl-result и повторите команду переноса' }
        default { return '' }
    }
}

function Set-RepositoryTransferStage {
    param([object]$State, [Collections.IDictionary]$Record, [string]$Stage)
    $Record['stage'] = $Stage
    $Record['nextAction'] = Get-RepositoryTransferNextAction -Stage $Stage -Mode ([string]$Record['mode'])
    Save-RepositoryTransferRecord -State $State -Record $Record
}

function Invoke-RepositoryTransferPrepare {
    param([object]$State, [object]$Existing)
    if (-not $RepositoryTransferMode) { throw 'REPOSITORY_TRANSFER_MODE_REQUIRED: pass -RepositoryTransferMode review or auto.' }
    $existingStage = [string](Get-RepositoryTransferValue -Record $Existing -Name 'stage' -Default '')
    if ($existingStage -in @('applying', 'applied', 'committing', 'committed', 'master-updated')) {
        throw "REPOSITORY_TRANSFER_IN_PROGRESS: the transfer is at stage '$existingStage'. Continue it with: $(Get-RepositoryTransferNextAction -Stage $existingStage -Mode ([string](Get-RepositoryTransferValue -Record $Existing -Name 'mode' -Default '')))."
    }
    $applied = if ($existingStage -in @('smoke-failed', 'smoke-unavailable', 'returned', 'prepared', 'approved')) { Get-RepositoryTransferValue -Record $Existing -Name 'applied' -Default $null } else { $null }
    $workRoot = Get-RepositoryTransferWorkRoot -State $State
    Set-RunStage -Stage 'repository-transfer.result' -Detail 'Checking the fresh passed CF of the current HEAD.'
    $result = Get-RepositoryTransferCheckedResult -State $State
    $scope = Get-RepositoryTransferScope -State $State
    Set-RunStage -Stage 'repository-transfer.version' -Detail 'Reading the latest repository version.'
    $hint = [int](Get-RepositoryTransferValue -Record $Existing -Name 'baseVersion' -Default 0)
    $latest = Get-RepositoryTransferLatestVersion -Hint $hint -WorkRoot $workRoot
    $attempt = 1
    if ($null -ne $applied) {
        $attempt = [int](Get-RepositoryTransferValue -Record $Existing -Name 'attempt' -Default 1) + 1
        $base = [int](Get-RepositoryTransferValue -Record $applied -Name 'baseVersion' -Default 0)
        if ($latest -ne $base) {
            Set-RunFailureContext -Category 'source-integrity' -RequiredAction 'Решение человека: новые версии хранилища появились после первого применения; подключённую ИБ с непомещённым CF нельзя выгружать в master.'
            throw "REPOSITORY_TRANSFER_REPOSITORY_ADVANCED: the repository moved from version $base to $latest while the first CF is applied but not committed."
        }
        Set-RunStage -Stage 'repository-transfer.probe' -Detail 'Checking that the source infobase still holds only the first applied CF.'
        $probe = Invoke-RepositoryTransferCompare -SecondFile ([string]$applied.cfCopyPath) -ReportPath (Join-Path $workRoot 'probe-applied.txt')
        if (-not $probe.empty) {
            Set-RunFailureContext -Category 'source-integrity' -RequiredAction 'Решение человека: в подключённой ИБ есть изменения помимо первого применённого CF.'
            throw "REPOSITORY_TRANSFER_FOREIGN_CHANGES: the source infobase differs from the first applied CF. Report: $($probe.path)"
        }
    } else {
        Assert-RepositoryTransferMasterCurrent -LatestVersion $latest -WorkRoot $workRoot
        Set-RunStage -Stage 'repository-transfer.probe' -Detail 'Checking the source infobase for uncommitted changes.'
        $probe = Invoke-RepositoryTransferCompare -FirstVersion $latest -ReportPath (Join-Path $workRoot 'probe-repository.txt')
        if (-not $probe.empty) {
            Set-RunFailureContext -Category 'source-integrity' -RequiredAction 'Решение человека: в подключённой ИБ есть непомещённые изменения либо она отстаёт от хранилища (режим external: актуализируйте источник).'
            throw "REPOSITORY_TRANSFER_FOREIGN_CHANGES: the source infobase differs from repository version $latest. Report: $($probe.path)"
        }
    }
    Set-RunStage -Stage 'repository-transfer.compare' -Detail 'Comparing the repository version and the source infobase with the CF.'
    $total = Invoke-RepositoryTransferCompare -FirstVersion $latest -SecondFile $result.cfPath -ReportPath (Join-Path $workRoot "attempt-$attempt-total.txt")
    Assert-RepositoryTransferReportScope -Report $total -Scope $scope
    $now = if ($null -ne $applied) { Invoke-RepositoryTransferCompare -SecondFile $result.cfPath -ReportPath (Join-Path $workRoot "attempt-$attempt-now.txt") } else { $total }
    $record = [ordered]@{
        id = $(if ($Existing) { [string](Get-RepositoryTransferValue -Record $Existing -Name 'id' -Default ([guid]::NewGuid().ToString('N'))) } else { [guid]::NewGuid().ToString('N') })
        mode = $RepositoryTransferMode
        attempt = $attempt
        baseVersion = $latest
        head = $result.head
        cfPath = $result.cfPath
        cfSha256 = $result.sha256
        manifestPath = $result.manifestPath
        objects = @($scope.objects)
        fullObjects = @($scope.fullObjects)
        rootRequired = $scope.rootRequired
        exportPath = $scope.exportPath
        loadPaths = @($scope.loadPaths)
        totalReportPath = $total.path
        totalReportSha256 = $total.sha256
        nowReportPath = $now.path
        applied = $applied
        createdAt = $(if ($Existing) { [string](Get-RepositoryTransferValue -Record $Existing -Name 'createdAt' -Default (Get-Date).ToString('o')) } else { (Get-Date).ToString('o') })
    }
    Set-RepositoryTransferStage -State $State -Record $record -Stage 'prepared'
    Write-RepositoryTransferReport -Title 'Перенос в хранилище: сравнение готово' -Record $record
}

function Assert-RepositoryTransferStage {
    param([object]$Record, [string[]]$Allowed, [string]$Step)
    $stage = [string](Get-RepositoryTransferValue -Record $Record -Name 'stage' -Default '')
    if ($stage -notin $Allowed) {
        $next = Get-RepositoryTransferNextAction -Stage $stage -Mode ([string](Get-RepositoryTransferValue -Record $Record -Name 'mode' -Default ''))
        throw "REPOSITORY_TRANSFER_STAGE: '$Step' is not available at stage '$stage'.$(if ($next) { " Next: $next." })"
    }
}

function Assert-RepositoryTransferMaterialUnchanged {
    # The decision belongs to this CF, this repository version and this composition.
    param([object]$State, [Collections.IDictionary]$Record, [string]$WorkRoot)
    $result = Get-RepositoryTransferCheckedResult -State $State
    if ($result.sha256 -cne [string]$Record['cfSha256'] -or $result.cfPath -cne [string]$Record['cfPath'] -or $result.head -cne [string]$Record['head']) {
        throw 'REPOSITORY_TRANSFER_MATERIAL_CHANGED: the CF was rebuilt or HEAD moved after the review. Repeat the transfer command for a new review.'
    }
    $latest = Get-RepositoryTransferLatestVersion -Hint ([int]$Record['baseVersion']) -WorkRoot $WorkRoot
    if ($latest -ne [int]$Record['baseVersion']) {
        throw "REPOSITORY_TRANSFER_REPOSITORY_ADVANCED: repository version $latest appeared after the review of version $($Record['baseVersion']). Repeat the transfer command for a new review."
    }
    $total = Invoke-RepositoryTransferCompare -FirstVersion $latest -SecondFile $result.cfPath -ReportPath (Join-Path $WorkRoot "attempt-$($Record['attempt'])-recheck.txt")
    if ($total.sha256 -cne [string]$Record['totalReportSha256']) {
        throw "REPOSITORY_TRANSFER_MATERIAL_CHANGED: the reviewed composition changed. New report: $($total.path). Repeat the transfer command for a new review."
    }
}

function Invoke-RepositoryTransferDecision {
    param([object]$State, [object]$Existing, [bool]$Approve)
    $record = ConvertTo-RepositoryTransferHashtable -Value $Existing
    Assert-RepositoryTransferStage -Record $record -Allowed @('prepared') -Step $(if ($Approve) { 'approve' } else { 'reject' })
    if ($RepositoryTransferDecidedBy -notin @('human', 'agent')) { throw 'REPOSITORY_TRANSFER_DECIDER_REQUIRED: pass -RepositoryTransferDecidedBy human or agent.' }
    if ($RepositoryTransferDecidedBy -eq 'agent' -and [string]$record['mode'] -ne 'auto') {
        throw 'REPOSITORY_TRANSFER_HUMAN_REVIEW_REQUIRED: the review mode needs the human decision.'
    }
    $result = Get-RepositoryTransferCheckedResult -State $State
    if ($result.sha256 -cne [string]$record['cfSha256'] -or $result.head -cne [string]$record['head']) {
        throw 'REPOSITORY_TRANSFER_MATERIAL_CHANGED: the CF was rebuilt or HEAD moved after the comparison. Repeat the transfer command for a new review.'
    }
    $record['decision'] = "$(if ($Approve) { 'принято' } else { 'возвращено' }): $RepositoryTransferDecidedBy, $((Get-Date).ToString('o'))$(if ($RepositoryTransferComment) { "; $RepositoryTransferComment" })"
    Set-RepositoryTransferStage -State $State -Record $record -Stage $(if ($Approve) { 'approved' } else { 'returned' })
    Write-RepositoryTransferReport -Title $(if ($Approve) { 'Перенос в хранилище: решение принято' } else { 'Перенос в хранилище: возвращено в ветку' }) -Record $record
}

function Invoke-RepositoryTransferApply {
    param([object]$State, [object]$Existing)
    $record = ConvertTo-RepositoryTransferHashtable -Value $Existing
    Assert-RepositoryTransferStage -Record $record -Allowed @('approved', 'applying') -Step 'apply'
    $workRoot = Get-RepositoryTransferWorkRoot -State $State
    $cfPath = [string]$record['cfPath']
    $resumed = ([string]$record['stage'] -eq 'applying')
    $loadNeeded = $true
    if ($resumed) {
        $after = Invoke-RepositoryTransferCompare -SecondFile $cfPath -ReportPath (Join-Path $workRoot 'resume-main-vs-cf.txt')
        $loadNeeded = -not $after.empty
    } else {
        Assert-RepositoryTransferMaterialUnchanged -State $State -Record $record -WorkRoot $workRoot
        $applied = Get-RepositoryTransferValue -Record $record -Name 'applied' -Default $null
        $probe = if ($null -ne $applied) {
            Invoke-RepositoryTransferCompare -SecondFile ([string]$applied.cfCopyPath) -ReportPath (Join-Path $workRoot 'apply-probe-applied.txt')
        } else {
            Invoke-RepositoryTransferCompare -FirstVersion ([int]$record['baseVersion']) -ReportPath (Join-Path $workRoot 'apply-probe-repository.txt')
        }
        if (-not $probe.empty) { throw "REPOSITORY_TRANSFER_FOREIGN_CHANGES: the source infobase changed after the review. Report: $($probe.path)" }
        if ([bool]$record['rootRequired']) {
            Set-RunStage -Stage 'repository-transfer.root' -Detail 'Locking the configuration root for added or removed objects.'
            Invoke-ConfigRepositoryObjectOperation -Operation '/ConfigurationRepositoryLock' -ObjectListPath (Write-RepositoryTransferObjectList -Objects @() -IncludeRoot $true -Path (Join-Path $workRoot 'root.xml'))
        }
        $record['cfCopyPath'] = Join-Path $workRoot "attempt-$($record['attempt']).cf"
        Copy-Item -LiteralPath $cfPath -Destination $record['cfCopyPath'] -Force
        Set-RepositoryTransferStage -State $State -Record $record -Stage 'applying'
    }
    if ($loadNeeded) {
        if ($resumed) {
            # An interrupted load is repeated only when the infobase still matches its pre-load basis.
            $applied = Get-RepositoryTransferValue -Record $record -Name 'applied' -Default $null
            $basis = if ($null -ne $applied) { Invoke-RepositoryTransferCompare -SecondFile ([string]$applied.cfCopyPath) -ReportPath (Join-Path $workRoot 'resume-basis.txt') } else { Invoke-RepositoryTransferCompare -FirstVersion ([int]$record['baseVersion']) -ReportPath (Join-Path $workRoot 'resume-basis.txt') }
            if (-not $basis.empty) {
                $record['lastError'] = "the source infobase matches neither the CF nor its pre-load basis; report: $($basis.path)"
                Save-RepositoryTransferRecord -State $State -Record $record
                throw "REPOSITORY_TRANSFER_APPLY_UNKNOWN: $($record['lastError']). A human decides how to continue or cancels."
            }
        }
        Set-RunStage -Stage 'repository-transfer.load' -Detail 'Loading the task files into the locked objects of the source infobase.'
        $listPath = Join-Path $workRoot "attempt-$($record['attempt'])-files.txt"
        [IO.File]::WriteAllLines($listPath, [string[]]@($record['loadPaths']), [Text.UTF8Encoding]::new($true))
        Invoke-RepositoryTransferDesigner -DesignerArgs @('/LoadConfigFromFiles', [string]$record['exportPath'], '-listFile', $listPath, '-Format', 'Hierarchical') | Out-Null
        $after = Invoke-RepositoryTransferCompare -SecondFile $cfPath -ReportPath (Join-Path $workRoot "attempt-$($record['attempt'])-main-vs-cf.txt")
        if (-not $after.empty) {
            $record['lastError'] = "after the load the main configuration differs from the CF; report: $($after.path)"
            Save-RepositoryTransferRecord -State $State -Record $record
            throw "REPOSITORY_TRANSFER_APPLY_MISMATCH: $($record['lastError'])."
        }
    }
    Set-RunStage -Stage 'repository-transfer.update-db' -Detail 'Updating the database configuration of the source infobase.'
    Invoke-RepositoryTransferDesigner -DesignerArgs @('/UpdateDBCfg') | Out-Null
    $record['applied'] = [ordered]@{ cfCopyPath = $record['cfCopyPath']; cfSha256 = $record['cfSha256']; baseVersion = $record['baseVersion']; objects = @($record['objects']); rootRequired = $record['rootRequired']; at = (Get-Date).ToString('o') }
    $record['lastError'] = ''
    Set-RepositoryTransferStage -State $State -Record $record -Stage 'applied'
    Write-RepositoryTransferReport -Title 'Перенос в хранилище: CF применён к подключённой ИБ' -Record $record
}

function Invoke-RepositoryTransferSmoke {
    param([object]$State, [object]$Existing)
    $record = ConvertTo-RepositoryTransferHashtable -Value $Existing
    Assert-RepositoryTransferStage -Record $record -Allowed @('applied') -Step 'smoke'
    $stage = switch ($RepositoryTransferSmoke) { 'passed' { 'smoke-passed' } 'failed' { 'smoke-failed' } 'unavailable' { 'smoke-unavailable' } default { throw 'REPOSITORY_TRANSFER_SMOKE_REQUIRED: pass -RepositoryTransferSmoke passed, failed or unavailable.' } }
    $record['smoke'] = "$RepositoryTransferSmoke$(if ($RepositoryTransferComment) { ": $RepositoryTransferComment" })"
    Set-RepositoryTransferStage -State $State -Record $record -Stage $stage
    Write-RepositoryTransferReport -Title 'Перенос в хранилище: дымовая проверка записана' -Record $record
}

function Find-RepositoryTransferCommittedVersion {
    param([Collections.IDictionary]$Record, [string]$WorkRoot)
    $user = [string](Get-EnvValue -Name 'REPOSITORY_USER')
    $planned = Get-RepositoryTransferTopLevelNames -Objects @($Record['objects'])
    $candidates = @(Get-RepositoryTransferVersions -From ([int]$Record['baseVersion'] + 1) -WorkRoot $WorkRoot | Where-Object {
        $touched = Get-RepositoryTransferTopLevelNames -Objects (@($_.added) + @($_.changed) + @($_.deleted) | Where-Object { ([string]$_).Contains('.') })
        [string]$_.user -eq $user -and [string]$_.comment -ceq [string]$Record['commitComment'] -and @($touched | Where-Object { $_ -notin $planned }).Count -eq 0 -and @($touched).Count -gt 0
    })
    return @($candidates)
}

function Invoke-RepositoryTransferCommit {
    param([object]$State, [object]$Existing)
    $record = ConvertTo-RepositoryTransferHashtable -Value $Existing
    Assert-RepositoryTransferStage -Record $record -Allowed @('smoke-passed', 'smoke-unavailable', 'committing') -Step 'commit'
    if ([string]$record['stage'] -eq 'smoke-unavailable' -and $RepositoryTransferDecidedBy -ne 'human') {
        throw 'REPOSITORY_TRANSFER_HUMAN_REVIEW_REQUIRED: the smoke scenario was unavailable; commit needs -RepositoryTransferDecidedBy human.'
    }
    $workRoot = Get-RepositoryTransferWorkRoot -State $State
    if ([string]$record['stage'] -ne 'committing') {
        if (-not $RepositoryTransferComment) { throw 'REPOSITORY_TRANSFER_COMMENT_REQUIRED: pass -RepositoryTransferComment "<issue>: <title>" or a short task description.' }
        $latest = Get-RepositoryTransferLatestVersion -Hint ([int]$record['baseVersion']) -WorkRoot $workRoot
        if ($latest -ne [int]$record['baseVersion']) { throw "REPOSITORY_TRANSFER_REPOSITORY_ADVANCED: repository version $latest appeared before the commit. A human decides how to continue." }
        $probe = Invoke-RepositoryTransferCompare -SecondFile ([string]$record['cfCopyPath']) -ReportPath (Join-Path $workRoot 'commit-probe.txt')
        if (-not $probe.empty) { throw "REPOSITORY_TRANSFER_FOREIGN_CHANGES: the source infobase changed after the application. Report: $($probe.path)" }
        $record['commitComment'] = $RepositoryTransferComment
        Set-RepositoryTransferStage -State $State -Record $record -Stage 'committing'
    } else {
        $found = @(Find-RepositoryTransferCommittedVersion -Record $record -WorkRoot $workRoot)
        if ($found.Count -gt 1) { throw "REPOSITORY_TRANSFER_COMMIT_AMBIGUOUS: versions $(@($found.version) -join ', ') match this transfer. A human chooses the version." }
        if ($found.Count -eq 1) { return (Complete-RepositoryTransferCommit -State $State -Record $record -Version $found[0] -WorkRoot $workRoot) }
        $latest = Get-RepositoryTransferLatestVersion -Hint ([int]$record['baseVersion']) -WorkRoot $workRoot
        if ($latest -ne [int]$record['baseVersion']) { throw "REPOSITORY_TRANSFER_COMMIT_AMBIGUOUS: repository version $latest exists but does not match this transfer. A human decides." }
    }
    Set-RunStage -Stage 'repository-transfer.commit' -Detail 'Committing the reviewed objects to the configuration repository.'
    $listPath = Write-RepositoryTransferObjectList -Objects @($record['objects']) -FullObjects @(Get-RepositoryTransferValue -Record $record -Name 'fullObjects' -Default @()) -IncludeRoot ([bool]$record['rootRequired']) -Path (Join-Path $workRoot 'commit-objects.xml')
    Invoke-RepositoryTransferDesigner -Repository -DesignerArgs @('/ConfigurationRepositoryCommit', '-Objects', $listPath, '-comment', [string]$record['commitComment']) | Out-Null
    $found = @(Find-RepositoryTransferCommittedVersion -Record $record -WorkRoot $workRoot)
    if ($found.Count -ne 1) { throw "REPOSITORY_TRANSFER_COMMIT_UNCONFIRMED: expected one matching version after $($record['baseVersion']), found $($found.Count). Repeat commit to reconcile." }
    Complete-RepositoryTransferCommit -State $State -Record $record -Version $found[0] -WorkRoot $workRoot
}

function Complete-RepositoryTransferCommit {
    param([object]$State, [Collections.IDictionary]$Record, [object]$Version, [string]$WorkRoot)
    $check = Invoke-RepositoryTransferCompare -FirstVersion ([int]$Version.version) -ReportPath (Join-Path $WorkRoot 'committed-vs-main.txt')
    if (-not $check.empty) { throw "REPOSITORY_TRANSFER_COMMIT_INCOMPLETE: version $($Version.version) differs from the source infobase. Report: $($check.path)" }
    $Record['committedVersion'] = [int]$Version.version
    $Record['applied'] = $null
    Set-RepositoryTransferStage -State $State -Record $Record -Stage 'committed'
    Write-RepositoryTransferReport -Title "Перенос в хранилище: создана версия $($Version.version)" -Record $Record
}

function Invoke-RepositoryTransferUpdateMaster {
    param([object]$State, [object]$Existing)
    $record = ConvertTo-RepositoryTransferHashtable -Value $Existing
    Assert-RepositoryTransferStage -Record $record -Allowed @('committed') -Step 'update-master'
    try {
        Sync-Master -SeedPolicy 'EnsureCompatible' -SkipRepositoryUpdate
    } catch {
        $record['lastError'] = "master update failed after version $($record['committedVersion']): $($_.Exception.Message)"
        $branchState = Read-DevBranchState -Name $DevBranchName
        Save-RepositoryTransferRecord -State $branchState -Record $record
        throw
    }
    $branchState = Read-DevBranchState -Name $DevBranchName
    $record['masterCommit'] = Get-RepositoryTransferGitLine rev-parse (Get-MasterBranch)
    $record['lastError'] = ''
    Set-RepositoryTransferStage -State $branchState -Record $record -Stage 'master-updated'
    Write-RepositoryTransferReport -Title "Перенос в хранилище: master обновлён по версии $($record['committedVersion'])" -Record $record
}

function Invoke-RepositoryTransferComplete {
    param([object]$State, [object]$Existing)
    $record = ConvertTo-RepositoryTransferHashtable -Value $Existing
    Assert-RepositoryTransferStage -Record $record -Allowed @('master-updated') -Step 'complete'
    if ($RepositoryTransferMantis -notin @('done', 'partial', 'skipped', 'failed')) { throw 'REPOSITORY_TRANSFER_MANTIS_REQUIRED: pass -RepositoryTransferMantis done, partial, skipped or failed.' }
    $record['mantis'] = "$RepositoryTransferMantis$(if ($RepositoryTransferComment) { ": $RepositoryTransferComment" })"
    $record['completedAt'] = (Get-Date).ToString('o')
    if ($RepositoryTransferMantis -eq 'failed') {
        Save-RepositoryTransferRecord -State $State -Record $record
        Write-RepositoryTransferReport -Title "Перенос в хранилище: версия $($record['committedVersion']) создана, запись Mantis не подтверждена" -Record $record
        return
    }
    Set-RepositoryTransferStage -State $State -Record $record -Stage 'completed'
    Write-RepositoryTransferReport -Title "Перенос в хранилище завершён: версия $($record['committedVersion'])" -Record $record
}

function Invoke-RepositoryTransferCancel {
    param([object]$State, [object]$Existing)
    $record = ConvertTo-RepositoryTransferHashtable -Value $Existing
    $stage = [string](Get-RepositoryTransferValue -Record $record -Name 'stage' -Default '')
    if ($stage -in @('committed', 'master-updated', 'completed')) {
        throw "REPOSITORY_TRANSFER_ALREADY_COMMITTED: version $($record['committedVersion']) exists; continue with: $(Get-RepositoryTransferNextAction -Stage $stage -Mode ([string]$record['mode']))."
    }
    $done = @()
    if ($null -ne (Get-RepositoryTransferValue -Record $record -Name 'applied' -Default $null) -or $stage -in @('applying', 'applied', 'smoke-passed', 'smoke-failed', 'smoke-unavailable', 'committing')) {
        $done += 'CF применён к подключённой ИБ и не помещён; автоматического отката нет'
    }
    if ($stage -eq 'committing') { $done += 'помещение могло начаться: сверьте историю хранилища перед ручным продолжением' }
    $record['cancelled'] = "$((Get-Date).ToString('o'))$(if ($RepositoryTransferComment) { ": $RepositoryTransferComment" })"
    $record['lastError'] = ($done + 'захваты объектов сохранены') -join '; '
    Set-RepositoryTransferStage -State $State -Record $record -Stage 'cancelled'
    Write-RepositoryTransferReport -Title 'Перенос в хранилище отменён' -Record $record
}

function Invoke-RepositoryTransfer {
    $state = Assert-RepositoryTransferBranch
    $existing = Get-RepositoryTransferRecord -State $state
    switch ($RepositoryTransferStep) {
        'status' { Write-RepositoryTransferReport -Title 'Перенос в хранилище: статус' -Record $existing; return }
        'prepare' { Invoke-RepositoryTransferPrepare -State $state -Existing $existing; return }
        'approve' { Invoke-RepositoryTransferDecision -State $state -Existing $existing -Approve $true; return }
        'reject' { Invoke-RepositoryTransferDecision -State $state -Existing $existing -Approve $false; return }
    }
    if ($null -eq $existing) { throw "REPOSITORY_TRANSFER_NOT_STARTED: run the transfer command first (prepare)." }
    switch ($RepositoryTransferStep) {
        'apply' { Invoke-RepositoryTransferApply -State $state -Existing $existing }
        'smoke' { Invoke-RepositoryTransferSmoke -State $state -Existing $existing }
        'commit' { Invoke-RepositoryTransferCommit -State $state -Existing $existing }
        'update-master' { Invoke-RepositoryTransferUpdateMaster -State $state -Existing $existing }
        'complete' { Invoke-RepositoryTransferComplete -State $state -Existing $existing }
        'cancel' { Invoke-RepositoryTransferCancel -State $state -Existing $existing }
        default { throw 'REPOSITORY_TRANSFER_STEP_REQUIRED: pass -RepositoryTransferStep status, prepare, approve, reject, apply, smoke, commit, update-master, complete or cancel.' }
    }
}
