function Get-AuxiliaryRetirementLocalPath {
    param([string]$Directory, [string]$Leaf)
    Join-Path $script:ProjectRoot ".agent-1c/$Directory/$(Get-AuxiliaryContourBranchKey)/$Leaf"
}

function Test-AuxiliaryRetirementLocalPath {
    param([string]$Path, [switch]$Recursive)
    if (-not (Test-ItlArtifactPathInside -Root $script:ProjectRoot -Path $Path)) { return $false }
    $existing = $Path
    while (-not (Get-Item -LiteralPath $existing -Force -ErrorAction SilentlyContinue)) {
        $existing = Split-Path -Parent $existing
        if (-not $existing) { return $false }
    }
    return (Test-ItlArtifactPathWithoutReparse -Root $script:ProjectRoot -Path $existing -Recursive:($Recursive -and $existing -eq $Path))
}

function Get-AuxiliaryRetirementFileEvidence {
    param([string]$Path)
    try {
        if (-not (Test-AuxiliaryRetirementLocalPath -Path $Path -Recursive)) { return '' }
    } catch { return '' }
    $directory = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $database = Get-Item -LiteralPath (Join-Path $Path '1Cv8.1CD') -Force -ErrorAction SilentlyContinue
    if ($null -eq $directory -or -not $directory.PSIsContainer -or $null -eq $database -or $database.PSIsContainer) { return '' }
    return "$($directory.CreationTimeUtc.Ticks)/$($database.CreationTimeUtc.Ticks)/$($database.LastWriteTimeUtc.Ticks)/$($database.Length)"
}

function Get-AuxiliaryRetirementConnectionKeys {
    param([string]$ConnectionRef)
    foreach ($suffix in @('USER','PASSWORD','INFOBASE_KIND','INFOBASE_PATH')) {
        "ITL_AUX_$($ConnectionRef)_$suffix"
        "AGENT_1C_ITL_AUX_$($ConnectionRef)_$suffix"
    }
}

function Get-AuxiliaryRetirementProfileReferences {
    param([string]$TargetCommit)
    $path = Get-VanessaTestClientManifestPath
    if (-not $path) { return $null }
    $text = ''
    if ($TargetCommit -and (Test-ItlArtifactPathInside -Root $script:ProjectRoot -Path $path)) {
        $relative = ConvertTo-ProjectRelativePath $path
        $text = Get-GitBlobTextAtCommit -Commit $TargetCommit -RepoPath $relative
        if (-not $text -and (Test-ItlArtifactPathTracked -ProjectRoot $script:ProjectRoot -Path $path)) {
            throw "ITL_VANESSA_TESTCLIENT_MANIFEST_NOT_FOUND: '$path' in reset target '$TargetCommit'. Correct the target manifest configuration and repeat reset-dev-branch."
        }
    }
    if (-not $text) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "ITL_VANESSA_TESTCLIENT_MANIFEST_NOT_FOUND: $path" }
        $text = Read-Utf8Text -Path $path
    }
    return (ConvertFrom-VanessaTestClientManifestDeclaration -Path $path -Text $text)
}

function Assert-AuxiliaryRetirementProfileReferences {
    param([object]$Manifest, [string[]]$Names)
    if ($null -eq $Manifest) { return }
    foreach ($profile in $Manifest.profiles) {
        if ($profile.contour -ne 'primary' -and $profile.contour -in $Names) {
            Set-RunFailureContext -Category 'test-fixture' -RequiredAction 'reassign-or-remove-the-named-testclient-profile-then-repeat-original-command'
            throw "ITL_AUXILIARY_RETIREMENT_PROFILE_REFERENCE: profile='$($profile.name)' contour='$($profile.contour)' manifest='$($Manifest.path)'. Reassign or remove that profile in the effective manifest and repeat the original command."
        }
    }
}

function Resolve-AuxiliaryAttachedFileBase {
    param([string]$Path)
    # An attached registration can name the same database through a junction.
    # Follow declared connection aliases for comparison only. The move path
    # itself must still be the ordinary managed directory without reparse points.
    for ($hop=0; $hop -lt 16; $hop++) {
        $cursor = $Path
        $rewritten = $false
        while ($cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $target = @(Get-StateValue $item 'Target' @() | Where-Object { $_ })
                if ($target.Count -ne 1 -or $target[0].StartsWith('\??\Volume{', [StringComparison]::OrdinalIgnoreCase)) { return '' }
                $destination = [string]$target[0]
                $parent = Split-Path -Parent $cursor
                if (-not [IO.Path]::IsPathRooted($destination)) { $destination = Join-Path $parent $destination }
                $suffix = $Path.Substring($cursor.Length).TrimStart('\','/')
                $Path = Resolve-Agent1cFullPath $(if ($suffix) { Join-Path $destination $suffix } else { $destination })
                $rewritten = $true
                break
            }
            $cursor = Split-Path -Parent $cursor
        }
        if (-not $rewritten) { return $Path }
    }
    return ''
}

function Get-AuxiliaryRetirementConnectionIdentity {
    param([object]$Contour)
    try {
        $connection = Get-AuxiliaryContourConnection -Contour $Contour
        $path = $connection.path
        if ($connection.kind -eq 'file' -and $Contour.baseMode -like 'attached-*') {
            $path = Resolve-AuxiliaryAttachedFileBase -Path $path
            if (-not $path) { return $null }
        }
        return (Get-OneCInfoBaseIdentity -InfoBaseKind $connection.kind -InfoBasePath $path)
    } catch {
        if ($_.Exception.Message -like 'ITL_AUXILIARY_CONNECTION_MISSING:*') { return $null }
        throw
    }
}

function Get-AuxiliaryRetirementSourceFileBase {
    if ((Get-InfoBaseKind) -ne 'file') { return }
    $configured = Get-Setting -EnvName 'SOURCE_INFOBASE_PATH' -ConfigName 'sourceInfoBasePath'
    if ($configured -or (Get-EnvValue -Name 'INFOBASE_PATH')) {
        Resolve-ProjectPath (Get-SourceInfoBasePath)
    }
}

function Get-AuxiliaryRetirementBaseGroups {
    param([object[]]$Source, [object[]]$Target, [object]$State)
    $groups = @{}
    $entryGroups = @{}
    $uncertain = $false
    $basePaths = @(
        [string](Get-StateValue $State 'devBranchInfoBasePath' '')
        [string](Get-StateValue $State 'vanessaServiceInfoBasePath' '')
        Get-AuxiliaryRetirementSourceFileBase
    ) | Where-Object { $_ }
    foreach ($set in @(@{ contours=$Source; target=$false }, @{ contours=$Target; target=$true })) {
        foreach ($contour in $set.contours) {
            $identity = Get-AuxiliaryRetirementConnectionIdentity -Contour $contour
            if ($null -eq $identity) { $uncertain = $true }
            $key = if ($identity) { $identity.key } else { "unknown|$($contour.name)" }
            if (-not $groups.ContainsKey($key)) {
                $protected = $identity -and $identity.kind -eq 'file' -and @(
                    $basePaths | Where-Object { Test-ItlOnDemandInfoBaseMatch -First $_ -Second $identity.value }
                ).Count -gt 0
                $groups[$key] = [pscustomobject]@{ identity=$identity; names=@(); attached=$false; retained=$protected }
            }
            $group = $groups[$key]
            $group.names = @($group.names + $contour.name | Sort-Object -Unique)
            $group.attached = $group.attached -or ($contour.baseMode -like 'attached-*')
            $group.retained = $group.retained -or $set.target
            if (-not $set.target) { $entryGroups[$contour.name] = $group }
        }
    }
    return [pscustomobject]@{ byContour=$entryGroups; uncertain=$uncertain }
}

function New-AuxiliaryRetirementPlan {
    param([object[]]$Source, [object[]]$Target, [string[]]$Names, [object]$State, [string]$TargetCommit)
    $groups = Get-AuxiliaryRetirementBaseGroups -Source $Source -Target $Target -State $State
    $resources = [ordered]@{}
    $definitions = Get-ConfigValue -Path 'auxiliaryContours'
    $entries = @(foreach ($contour in $Source | Where-Object { $_.name -in $Names }) {
        $group = $groups.byContour[$contour.name]
        $resourceName = $group.names[0]
        if (-not $resources.Contains($resourceName)) {
            $path = if ($group.identity -and $group.identity.kind -eq 'file' -and (Test-ItlArtifactPathInside -Root $script:ProjectRoot -Path $group.identity.value)) { [string]$group.identity.value } else { '' }
            $resource = [pscustomobject][ordered]@{
                name=$resourceName; names=@($group.names); path=$path; archivePath=''; fileEvidence=''; outcome=''; reason=''
            }
            $resources[$resourceName] = $resource
            if ($group.attached) {
                $resource.outcome = 'preserved'
                $resource.reason = 'attached-registration'
            } elseif ($group.retained) {
                $resource.outcome = 'preserved'
                $resource.reason = 'shared-with-retained-base'
            } elseif ($groups.uncertain) {
                $resource.outcome = 'preserved'
                $resource.reason = 'other-connection-unresolved'
            } else {
                $expected = Resolve-Agent1cFullPath (Get-AuxiliaryRetirementLocalPath -Directory 'infobases/auxiliary' -Leaf $contour.name)
                $archive = Resolve-Agent1cFullPath (Get-AuxiliaryRetirementLocalPath -Directory 'auxiliary-archives' -Leaf ("$($contour.name)-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
                if ($path -ine $expected -or -not (Test-AuxiliaryRetirementLocalPath $path) -or
                    -not (Test-AuxiliaryRetirementLocalPath $archive) -or (Test-Path -LiteralPath $archive)) {
                    $resource.outcome = 'preserved'
                    $resource.reason = 'path-or-archive-ownership-unproved'
                } elseif (-not (Test-Path -LiteralPath $path)) {
                    $resource.outcome = 'absent'
                    $resource.reason = 'base-absent'
                } else {
                    $resource.fileEvidence = Get-AuxiliaryRetirementFileEvidence $path
                    if ($resource.fileEvidence) { $resource.archivePath = $archive }
                    else {
                        $resource.outcome = 'preserved'
                        $resource.reason = 'file-base-ownership-unproved'
                    }
                }
            }
        }
        $statePath = Get-AuxiliaryContourStatePath -Contour $contour
        $stateHash = if ((Test-AuxiliaryRetirementLocalPath $statePath) -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            Get-ItlFileSha256 -Path $statePath
        } else { '' }
        $property = @($definitions.PSObject.Properties | Where-Object { $_.Name.Trim() -ieq $contour.name })[0]
        [pscustomobject][ordered]@{
            name=$contour.name; connectionRef=$contour.connectionRef; base=$resourceName
            definitionSha256=(Get-StringSha256 -Value (ConvertTo-Json -InputObject $property.Value -Depth 64 -Compress))
            stateSha256=[string]$stateHash; stateOutcome=''
        }
    })
    return [pscustomobject][ordered]@{
        schemaVersion=1; root=$script:ProjectRoot; branch=(Get-CurrentBranch); sourceHead=(Get-CurrentCommit); targetCommit=$TargetCommit
        entries=$entries; bases=@($resources.Values); mcpIntent=$null; mcpChangedClients=@(); result=$null
    }
}

function Assert-AuxiliaryRetirementPlan {
    param([object]$Plan, [string]$TargetCommit = '')
    if ($null -eq $Plan -or [int]$Plan.schemaVersion -ne 1 -or $Plan.root -ine $script:ProjectRoot -or
        $Plan.branch -cne (Get-CurrentBranch) -or [string]$Plan.targetCommit -cne $TargetCommit) {
        throw 'ITL_AUXILIARY_RETIREMENT_PLAN_MISMATCH: preserve the retirement journal and repeat from its original worktree and branch.'
    }
    foreach ($base in $Plan.bases) {
        if (-not $base.archivePath) { continue }
        $name = ConvertTo-AuxiliaryContourId -Name $base.name
        $leaf = Split-Path -Leaf $base.archivePath
        if ($base.path -ine (Resolve-Agent1cFullPath (Get-AuxiliaryRetirementLocalPath -Directory 'infobases/auxiliary' -Leaf $name)) -or
            $base.archivePath -ine (Resolve-Agent1cFullPath (Get-AuxiliaryRetirementLocalPath -Directory 'auxiliary-archives' -Leaf $leaf)) -or
            $leaf -cnotmatch ('^' + [regex]::Escape($name) + '-\d{8}-\d{6}-\d{3}$')) {
            throw 'ITL_AUXILIARY_RETIREMENT_PLAN_PATH_INVALID: preserve the journal and its archive.'
        }
    }
}

function Update-AuxiliaryRetirementBaseEvidence {
    param([object]$Plan, [object[]]$Remaining)
    $identities = @(foreach ($contour in $Remaining) { Get-AuxiliaryRetirementConnectionIdentity -Contour $contour })
    foreach ($base in $Plan.bases | Where-Object { $_.archivePath -and -not $_.outcome }) {
        if (-not (Test-AuxiliaryRetirementLocalPath $base.path) -or -not (Test-AuxiliaryRetirementLocalPath $base.archivePath)) {
            $base.outcome = 'preserved'; $base.reason = 'path-identity-changed'
            continue
        }
        $atArchive = Test-Path -LiteralPath $base.archivePath
        $atSource = Test-Path -LiteralPath $base.path
        if ($atArchive) {
            if ($atSource -or (Get-AuxiliaryRetirementFileEvidence $base.archivePath) -cne $base.fileEvidence) {
                $base.outcome = 'preserved'; $base.reason = 'archive-identity-unconfirmed'
            }
            continue
        }
        if (@($identities | Where-Object {
            $null -eq $_ -or ($_.kind -eq 'file' -and (Test-ItlOnDemandInfoBaseMatch -First $_.value -Second $base.path))
        }).Count -gt 0) {
            $base.outcome = 'preserved'; $base.reason = 'remaining-connection-uses-or-may-use-base'
        } elseif (-not $atSource -or (Get-AuxiliaryRetirementFileEvidence $base.path) -cne $base.fileEvidence) {
            $base.outcome = 'preserved'; $base.reason = 'base-identity-changed'
        }
    }
}

function Get-AuxiliaryRetirementAdmissions {
    param([object]$Plan)
    foreach ($base in $Plan.bases | Where-Object { $_.archivePath -and -not $_.outcome }) {
        [pscustomobject]@{ infoBaseKind='file'; infoBasePath=$base.path }
    }
}

function Assert-AuxiliaryRetirementExclusiveUse {
    param([object]$Plan)
    foreach ($base in $Plan.bases | Where-Object { $_.archivePath -and -not $_.outcome }) {
        if (Test-Path -LiteralPath $base.archivePath) { continue }
        Stop-ItlOnDemandBackends -InfoBasePath $base.path -Strict
        $sessions = @(Get-OneCInfoBaseSessionProcesses -InfoBaseKind file -InfoBasePath $base.path)
        if ($sessions.Count -gt 0) {
            Set-RunFailureContext -Category 'execution-conflict' -RequiredAction 'release-the-named-infobase-holder-then-repeat-original-command'
            throw "EXECUTION_GUARD_EXTERNAL_CONFLICT: contour='$($base.name)' pids='$($sessions.pid -join ',')'. Repeat the original command after the current session releases the base."
        }
    }
}

function Complete-AuxiliaryRetirementArchive {
    param([object]$Base)
    if ($Base.outcome) { return }
    $source = [string]$Base.path
    $archive = [string]$Base.archivePath
    if (-not (Test-Path -LiteralPath $archive)) {
        if (@(Get-OneCInfoBaseSessionProcesses -InfoBaseKind file -InfoBasePath $source).Count -gt 0) {
            Set-RunFailureContext -Category 'execution-conflict' -RequiredAction 'release-the-named-infobase-holder-then-repeat-original-command'
            throw "EXECUTION_GUARD_EXTERNAL_CONFLICT: contour='$($Base.name)'. Repeat the original command after the current session releases the base."
        }
        if ((Get-AuxiliaryRetirementFileEvidence $source) -cne $Base.fileEvidence -or -not (Test-AuxiliaryRetirementLocalPath $archive)) {
            $Base.outcome = 'preserved'; $Base.reason = 'base-identity-changed'; return
        }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $archive))
        if (-not (Test-AuxiliaryRetirementLocalPath $archive)) { throw 'ITL_AUXILIARY_RETIREMENT_ARCHIVE_UNSAFE: correct the archive path and repeat the original command.' }
        [IO.Directory]::Move($source, $archive)
    }
    if ((Test-Path -LiteralPath $source) -or (Get-AuxiliaryRetirementFileEvidence $archive) -cne $Base.fileEvidence) {
        throw "ITL_AUXILIARY_RETIREMENT_ARCHIVE_UNCONFIRMED: '$archive'. Preserve both paths and repeat the original command when the recorded base location is verified."
    }
    Write-AuxiliaryContourArchiveMarker -Path $archive -Name $Base.name
    $Base.outcome = 'archived'; $Base.reason = 'newest-in-branch-and-contour-group'
}

function Remove-AuxiliaryRetirementDotEnvKeys {
    param([string[]]$Keys)
    $path = Join-Path $script:ProjectRoot '.dev.env'
    if (@($Keys | Where-Object { $_ }).Count -eq 0 -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if (-not (Test-AuxiliaryRetirementLocalPath $path)) { throw 'ITL_AUXILIARY_RETIREMENT_ENV_UNSAFE: restore a local .dev.env file and repeat the original command.' }
    $before = Read-Utf8Text -Path $path
    $alternatives = ($Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $after = [regex]::Replace($before, "(?im)^[^\S\r\n]*(?:$alternatives)[^\S\r\n]*=[^\r\n]*(?:\r?\n|$)", '')
    if ($before -ceq $after) { return }
    if ((Read-Utf8Text -Path $path) -cne $before) { throw 'ITL_AUXILIARY_RETIREMENT_ENV_CHANGED: repeat the original command with the current .dev.env.' }
    Write-Utf8TextAtomic -Path $path -Value $after -RetryCount 1
    foreach ($key in $Keys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
}

function Invoke-AuxiliaryRetirement {
    param([object]$Plan, [object[]]$Remaining, [object]$Manifest, [scriptblock]$SaveProgress)
    if ($null -ne $Plan.result) { return }
    Assert-AuxiliaryRetirementProfileReferences -Manifest $Manifest -Names @($Plan.entries.name)
    foreach ($base in $Plan.bases | Where-Object { -not $_.outcome }) {
        Complete-AuxiliaryRetirementArchive -Base $base
        & $SaveProgress
    }

    $keptKeys = @{}
    foreach ($contour in $Remaining) {
        foreach ($key in @(Get-AuxiliaryRetirementConnectionKeys $contour.connectionRef)) { $keptKeys[$key] = "contour '$($contour.name)'" }
    }
    if ($null -ne $Manifest) {
        foreach ($profile in $Manifest.profiles) {
            foreach ($key in @($profile.userEnv, $profile.passwordEnv) | Where-Object { $_ }) {
                $keptKeys[$key] = "profile '$($profile.name)'"
                $keptKeys["AGENT_1C_$key"] = "profile '$($profile.name)'"
            }
        }
    }
    $retiringKeys = @($Plan.entries.connectionRef | Sort-Object -Unique | ForEach-Object { Get-AuxiliaryRetirementConnectionKeys $_ })
    Remove-AuxiliaryRetirementDotEnvKeys -Keys @($retiringKeys | Where-Object { -not $keptKeys.ContainsKey($_) })
    $mcp = Remove-ItlOnDemandAuxiliaryClientEntries -Plan $Plan -SaveProgress $SaveProgress
    foreach ($entry in $Plan.entries) {
        $statePath = Get-AuxiliaryContourStatePath -Contour $entry
        $entry.stateOutcome = 'absent-or-removed'
        if (Get-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue) {
            if ((Test-AuxiliaryRetirementLocalPath $statePath) -and $entry.stateSha256 -and
                (Test-Path -LiteralPath $statePath -PathType Leaf) -and
                (Get-ItlFileSha256 -Path $statePath) -ceq $entry.stateSha256) {
                [IO.File]::Delete($statePath)
            } else { $entry.stateOutcome = 'preserved-state-identity-unproved' }
        }
    }
    $Plan.result = [pscustomobject]@{
        retainedKeys=@($retiringKeys | Where-Object { $keptKeys.ContainsKey($_) } | ForEach-Object { [pscustomobject]@{name=$_; consumer=$keptKeys[$_]} })
        mcp=$mcp
    }
    & $SaveProgress
}

function Add-AuxiliaryRetirementReport {
    param([System.Collections.Generic.List[string]]$Lines, [object]$Plan)
    foreach ($entry in $Plan.entries) {
        $base = @($Plan.bases | Where-Object name -CEQ $entry.base)[0]
        $text = "$($entry.name): $($base.outcome) [$($base.reason)]"
        if ($base.outcome -eq 'archived') {
            $group = "$(Get-AuxiliaryContourBranchKey)/$($base.name)"
            $keep = (Get-ItlArtifactRetentionPolicy).archiveKeepCount
            $text += " $($base.archivePath). Группа $group. Политика хранит $keep последних архивов группы, включая единственный архив."
        } elseif ($base.path) { $text += " $($base.path)" }
        if ($entry.stateOutcome -like 'preserved-*') { $text += ". $($entry.stateOutcome)" }
        $Lines.Add($text)
    }
    foreach ($key in $Plan.result.retainedKeys) { $Lines.Add("Сохранён ключ $($key.name) ($($key.consumer)).") }
    foreach ($setting in $Plan.result.mcp.preserved) { $Lines.Add("Сохранена настройка MCP $setting.") }
    foreach ($path in $Plan.result.mcp.wrappersPreserved) { $Lines.Add("Сохранена обёртка с оставшейся ссылкой или неподтверждённым владением $path.") }
    if ($Plan.result.mcp.reloadClients.Count -gt 0) {
        $Lines.Add("Конфигурация MCP применена на диске. Перечитайте её в клиентах $($Plan.result.mcp.reloadClients -join ', '), затем откройте новый чат. Перечитывание не проверено.")
    }
}

function Remove-AuxiliaryContour {
    if ([string]::IsNullOrWhiteSpace($AuxiliaryContourName)) { throw 'ITL_AUXILIARY_CONTOUR_REQUIRED: pass -AuxiliaryContourName.' }
    $name = ConvertTo-AuxiliaryContourId -Name $AuxiliaryContourName
    if ($name -cne $AuxiliaryContourName) { throw 'ITL_AUXILIARY_CONTOUR_NAME_INVALID: pass the exact registered name.' }
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation 'remove-auxiliary-contour'
    $journal = Get-AuxiliaryRetirementLocalPath -Directory 'auxiliary-contours' -Leaf 'retirement.pending'
    if (-not (Test-AuxiliaryRetirementLocalPath $journal)) { throw 'ITL_AUXILIARY_RETIREMENT_JOURNAL_UNSAFE: restore the worktree-local state directory and repeat the original command.' }
    $source = @(Get-AuxiliaryContourDefinitions)
    $remaining = @($source | Where-Object name -CNE $name)
    Assert-AuxiliaryRetirementProfileReferences -Manifest (Get-AuxiliaryRetirementProfileReferences) -Names @($name)
    $persisted = Test-Path -LiteralPath $journal -PathType Leaf
    $journalInput = if ($persisted) { Read-Utf8Text -Path $journal } else { '' }
    if ($persisted) {
        $retirementPlan = $journalInput | ConvertFrom-Json
        Assert-AuxiliaryRetirementPlan -Plan $retirementPlan
        if ($retirementPlan.entries.Count -ne 1 -or $retirementPlan.entries[0].name -cne $name) {
            throw "ITL_AUXILIARY_RETIREMENT_PENDING: repeat remove-auxiliary-contour -AuxiliaryContourName '$($retirementPlan.entries[0].name)' first."
        }
    } else {
        Get-AuxiliaryContour -Name $name | Out-Null
        $retirementPlan = New-AuxiliaryRetirementPlan -Source $source -Target $remaining -Names @($name) -State $state
    }

    if (-not (Test-AuxiliaryRetirementLocalPath $script:ConfigPath)) {
        throw 'ITL_AUXILIARY_RETIREMENT_CONFIG_UNSAFE: restore a local project.json and repeat the original command.'
    }
    $configInput = Read-Utf8Text -Path $script:ConfigPath
    $saveProgress = { Write-Utf8TextAtomic -Path $journal -Value ($retirementPlan | ConvertTo-Json -Depth 24) }
    $work = {
        if ((Read-Utf8Text -Path $script:ConfigPath) -cne $configInput -or
            -not (Test-AuxiliaryRetirementLocalPath $journal) -or
            (Test-Path -LiteralPath $journal -PathType Leaf) -ne $persisted -or
            ($persisted -and (Read-Utf8Text -Path $journal) -cne $journalInput)) {
            throw 'ITL_AUXILIARY_RETIREMENT_INPUT_CHANGED: repeat the original command with the current project state.'
        }
        $manifest = Get-AuxiliaryRetirementProfileReferences
        Assert-AuxiliaryRetirementProfileReferences -Manifest $manifest -Names @($name)
        Update-AuxiliaryRetirementBaseEvidence -Plan $retirementPlan -Remaining $remaining
        Assert-AuxiliaryRetirementExclusiveUse -Plan $retirementPlan

        $config = ConvertTo-Agent1cHashtable -Object ($configInput | ConvertFrom-Json)
        $contours = ConvertTo-Agent1cHashtable -Object $config['auxiliaryContours']
        $definitionKey = @($contours.Keys | Where-Object { $_.Trim() -ieq $name })
        if ($definitionKey.Count -gt 0) {
            $raw = ($configInput | ConvertFrom-Json).auxiliaryContours.PSObject.Properties[$definitionKey[0]].Value
            $hash = Get-StringSha256 -Value (ConvertTo-Json -InputObject $raw -Depth 64 -Compress)
            if ($hash -cne $retirementPlan.entries[0].definitionSha256) {
                throw "ITL_AUXILIARY_RETIREMENT_DEFINITION_CHANGED: contour='$name'. Restore the intended definition and repeat the original command."
            }
        }
        & $saveProgress
        if ($definitionKey.Count -gt 0) {
            [void]$contours.Remove($definitionKey[0])
            $config['auxiliaryContours'] = $contours
            if ((Read-Utf8Text -Path $script:ConfigPath) -cne $configInput) { throw 'ITL_AUXILIARY_RETIREMENT_INPUT_CHANGED: repeat the original command with the current project state.' }
            Write-Utf8TextAtomic -Path $script:ConfigPath -Value (($config | ConvertTo-Json -Depth 64) + [Environment]::NewLine) -RetryCount 1
            Read-ProjectConfig
        }
        Invoke-AuxiliaryRetirement -Plan $retirementPlan -Remaining $remaining -Manifest $manifest -SaveProgress $saveProgress
        $report = [System.Collections.Generic.List[string]]::new()
        $report.Add('## Регистрация вспомогательного контура снята')
        Add-AuxiliaryRetirementReport -Lines $report -Plan $retirementPlan
        [IO.File]::Delete($journal)
        Write-AndSetRunUserReport -Lines $report
    }
    Invoke-WithAuxiliaryRetirementGuard -Plan $retirementPlan -Purpose 'remove-auxiliary-contour' -ScriptBlock $work
}

function Invoke-WithAuxiliaryRetirementGuard {
    param([object]$Plan, [string]$Purpose, [scriptblock]$ScriptBlock)
    $admissions = @(Get-AuxiliaryRetirementAdmissions -Plan $Plan)
    if ($admissions.Count -eq 0) { return (& $ScriptBlock) }
    try {
        return (Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose $Purpose -ScriptBlock $ScriptBlock)
    } catch {
        if ($_.Exception.Message -match '^EXECUTION_GUARD_WAIT_TIMEOUT\b') {
            Set-RunFailureContext -Category 'execution-conflict' -RequiredAction 'release-the-named-infobase-holder-then-repeat-original-command'
            throw "$($_.Exception.Message) Repeat the original command after the current holder releases the base."
        }
        throw
    }
}

function Get-AuxiliaryRetirementInventory {
    $root = $script:ProjectRoot
    $items = [Collections.Generic.List[object]]::new()
    $unavailable = [Collections.Generic.List[string]]::new()
    $limits = @{ entries=12000; deadline=[datetime]::UtcNow.AddSeconds(5) }
    $registered = @{}
    $activeBases = @{}
    $activeKeys = @{}
    $branchKey = Get-AuxiliaryContourBranchKey
    try {
        foreach ($contour in @(Get-AuxiliaryContourDefinitions)) {
            $registered[$contour.name] = $true
            foreach ($key in Get-AuxiliaryRetirementConnectionKeys $contour.connectionRef) { $activeKeys[$key] = $true }
            $identity = Get-AuxiliaryRetirementConnectionIdentity -Contour $contour
            if ($identity -and $identity.kind -eq 'file') { $activeBases[$identity.key] = $true }
        }
        $manifest = Get-AuxiliaryRetirementProfileReferences
        if ($manifest) {
            foreach ($profile in $manifest.profiles) {
                foreach ($key in @($profile.userEnv, $profile.passwordEnv) | Where-Object { $_ }) {
                    $activeKeys[$key] = $true
                    $activeKeys["AGENT_1C_$key"] = $true
                }
            }
        }
    } catch { $unavailable.Add('Не удалось установить все действующие регистрации или профили.') }

    $statesRoot = Join-Path $root '.agent-1c/dev-branches'
    $knownBases = @(Get-AuxiliaryRetirementSourceFileBase)
    if ((Test-Path -LiteralPath $statesRoot -PathType Container) -and (Test-AuxiliaryRetirementLocalPath $statesRoot)) {
        foreach ($stateFile in Get-ChildItem -LiteralPath $statesRoot -File -Filter '*.json' -ErrorAction SilentlyContinue) {
            if ($stateFile.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            try {
                $state = Read-DevBranchStateFile -Path $stateFile.FullName
                $knownBases += [string](Get-StateValue $state 'vanessaServiceInfoBasePath' '')
                if ((Get-StateValue $state 'infoBaseKind' 'file') -eq 'file') {
                    $knownBases += [string](Get-StateValue $state 'devBranchInfoBasePath' '')
                }
            } catch { $unavailable.Add("Состояние ветки недоступно ($($stateFile.Name)).") }
        }
    }
    foreach ($path in $knownBases | Where-Object { $_ }) {
        $activeBases[(Get-OneCInfoBaseIdentity -InfoBaseKind file -InfoBasePath $path).key] = $true
    }

    $baseRoot = Join-Path $root '.agent-1c/infobases'
    $pending = [Collections.Generic.Stack[object]]::new()
    if (Get-Item -LiteralPath $baseRoot -Force -ErrorAction SilentlyContinue) { $pending.Push([pscustomobject]@{path=$baseRoot; depth=0}) }
    while ($pending.Count -gt 0 -and $limits.entries -gt 0 -and [datetime]::UtcNow -lt $limits.deadline) {
        $folder = $pending.Pop()
        $path = [string]$folder.path
        try {
            if (-not (Test-AuxiliaryRetirementLocalPath $path)) {
                $items.Add([pscustomobject]@{kind='infobase-path'; location=$path; reason='reparse-or-unavailable'; bytes=$null})
                continue
            }
            if ($activeBases.ContainsKey((Get-OneCInfoBaseIdentity -InfoBaseKind file -InfoBasePath $path).key)) { continue }
            $database = Get-Item -LiteralPath (Join-Path $path '1Cv8.1CD') -Force -ErrorAction SilentlyContinue
            if ($database -and -not $database.PSIsContainer) {
                $size = Measure-AuxiliaryRetirementInventoryBase -Path $path -Limits $limits
                $items.Add([pscustomobject]@{kind='file-infobase'; location=$path; reason=$size.reason; bytes=$size.bytes})
                continue
            }
            if ($folder.depth -ge 5) { $unavailable.Add("Достигнута глубина обхода ($path)."); continue }
            foreach ($child in ([IO.DirectoryInfo]::new($path)).EnumerateDirectories()) {
                if (--$limits.entries -le 0 -or [datetime]::UtcNow -ge $limits.deadline) { break }
                $pending.Push([pscustomobject]@{path=$child.FullName; depth=$folder.depth+1})
            }
        } catch { $unavailable.Add("Каталог недоступен ($path).") }
    }
    if ($limits.entries -le 0 -or [datetime]::UtcNow -ge $limits.deadline) { $unavailable.Add('Достигнут лимит обхода локальных баз.') }

    $stateRoot = Join-Path $root '.agent-1c/auxiliary-contours'
    if (Test-Path -LiteralPath $stateRoot) {
        if (Test-AuxiliaryRetirementLocalPath $stateRoot) {
            foreach ($directory in Get-ChildItem -LiteralPath $stateRoot -Directory -ErrorAction SilentlyContinue) {
                if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { $unavailable.Add("Пропущена ссылка ($($directory.FullName))."); continue }
                foreach ($file in Get-ChildItem -LiteralPath $directory.FullName -File -Filter '*.json' -ErrorAction SilentlyContinue) {
                    if ($directory.Name -eq $branchKey -and $registered.ContainsKey($file.BaseName)) { continue }
                    $items.Add([pscustomobject]@{kind='contour-state'; location=$file.FullName; reason='registration-unproved'; bytes=$null})
                }
            }
        } else { $unavailable.Add("Каталог состояния недоступен ($stateRoot).") }
    }
    $wrapperRoot = Join-Path $root '.agent-1c/mcp/ondemand/helpers'
    if (Test-Path -LiteralPath $wrapperRoot) {
        if (Test-AuxiliaryRetirementLocalPath $wrapperRoot) {
            foreach ($wrapper in Get-ChildItem -LiteralPath $wrapperRoot -File -Filter '*.ps1' -ErrorAction SilentlyContinue) {
                if ($registered.ContainsKey($wrapper.BaseName)) { continue }
                $items.Add([pscustomobject]@{kind='mcp-wrapper'; location=$wrapper.FullName; reason='registration-unproved'; bytes=$null})
            }
        } else { $unavailable.Add("Каталог обёрток недоступен ($wrapperRoot).") }
    }
    $dotEnv = Join-Path $root '.dev.env'
    if (Test-Path -LiteralPath $dotEnv -PathType Leaf) {
        if (Test-AuxiliaryRetirementLocalPath $dotEnv) {
            try {
                foreach ($key in @(Read-Utf8Lines -Path $dotEnv | ForEach-Object {
                    if ($_ -match '^\s*((?:AGENT_1C_)?ITL_AUX_[A-Z0-9_]+)\s*=') { $Matches[1] }
                } | Sort-Object -Unique)) {
                    if ($activeKeys.ContainsKey($key)) { continue }
                    $items.Add([pscustomobject]@{kind='dotenv-key'; location=$key; reason='registration-unproved'; bytes=$null})
                }
            } catch { $unavailable.Add('Не удалось прочитать имена ключей .dev.env.') }
        } else { $unavailable.Add('Пропущена ссылка .dev.env.') }
    }
    foreach ($client in (Get-ItlClientAdapterRegistry).Keys) {
        try {
            $paths = @(Get-ItlClientMcpConfigPaths -Client $client)
            if (@($paths | Where-Object { -not (Test-AuxiliaryRetirementLocalPath $_) }).Count -gt 0) { throw 'unsafe path' }
            foreach ($key in @(Get-ItlClientMcpEndpointKeys -Client $client)) {
                if ($key -notmatch '^itl-(?:roctup|vanessa-ui)-aux-(?<name>[a-z0-9][a-z0-9-]{0,47})$' -or $registered.ContainsKey($Matches.name)) { continue }
                $items.Add([pscustomobject]@{kind='mcp-entry'; location="$client/$key"; reason='registration-unproved'; bytes=$null})
            }
        } catch { $unavailable.Add("Не удалось прочитать имена записей MCP ($client).") }
    }
    return [pscustomobject]@{ items=$items.ToArray(); incomplete=$unavailable.ToArray() }
}

function Measure-AuxiliaryRetirementInventoryBase {
    param([string]$Path, [hashtable]$Limits)
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push([IO.DirectoryInfo]::new($Path))
    $total = [long]0
    $linked = $false
    try {
        while ($pending.Count -gt 0) {
            $folder = $pending.Pop()
            if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { $linked = $true; continue }
            foreach ($entry in $folder.EnumerateFileSystemInfos()) {
                if (--$Limits.entries -le 0 -or [datetime]::UtcNow -ge $Limits.deadline) {
                    return [pscustomobject]@{ bytes=$null; reason='size-budget-exhausted' }
                }
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $linked = $true; continue }
                if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry) } else { $total += $entry.Length }
            }
        }
    } catch { return [pscustomobject]@{ bytes=$null; reason='size-unavailable' } }
    if ($linked) { return [pscustomobject]@{ bytes=$null; reason='size-incomplete-reparse-point' } }
    return [pscustomobject]@{ bytes=$total; reason='registration-unproved' }
}
