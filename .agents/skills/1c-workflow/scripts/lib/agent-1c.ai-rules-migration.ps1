function Get-AiRulesBaselineTarget {
    $projectTemplatePath = Join-Path $script:ProjectRoot "templates\project.json"
    $lockTemplatePath = Join-Path $script:ProjectRoot "templates\dependency-lock.json"
    if (-not (Test-Path -LiteralPath $projectTemplatePath -PathType Leaf) -or -not (Test-Path -LiteralPath $lockTemplatePath -PathType Leaf)) {
        return [pscustomobject]@{ isConfigured = $false; reason = "workflow templates are missing" }
    }

    $projectTemplate = Read-Utf8Text -Path $projectTemplatePath | ConvertFrom-Json
    $lockTemplate = Read-Utf8Text -Path $lockTemplatePath | ConvertFrom-Json
    $repo = [string](Get-ConfigValueFromObject -Object $projectTemplate -Path "aiRules.repo" -Default "")
    $ref = [string](Get-ConfigValueFromObject -Object $projectTemplate -Path "aiRules.ref" -Default "")
    $entry = Get-ConfigValueFromObject -Object $lockTemplate -Path "dependencies.aiRules1c" -Default $null
    $commit = [string](Get-ConfigValueFromObject -Object $entry -Path "commit" -Default "")
    $status = [string](Get-ConfigValueFromObject -Object $entry -Path "compatibilityStatus" -Default "")

    $configured = (Test-AiRules1cForkRepository -Repo $repo) -and $ref -like "itl-*" -and $commit -and $status -eq "passed"
    return [pscustomobject]@{
        isConfigured = [bool]$configured
        reason = $(if ($configured) { "" } else { "verified fork repo/tag/commit baseline is not configured" })
        repo = $repo
        ref = $ref
        commit = $commit
        upstreamRepo = [string](Get-ConfigValueFromObject -Object $entry -Path "upstreamRepo" -Default "")
        upstreamRef = [string](Get-ConfigValueFromObject -Object $entry -Path "upstreamRef" -Default "")
        upstreamCommit = [string](Get-ConfigValueFromObject -Object $entry -Path "upstreamCommit" -Default "")
        downstreamRevision = [int](Get-ConfigValueFromObject -Object $entry -Path "downstreamRevision" -Default 0)
        compatibilityStatus = $status
        compatibilityCheckedAt = [string](Get-ConfigValueFromObject -Object $entry -Path "compatibilityCheckedAt" -Default "")
        lockEntry = $entry
    }
}

function Test-AiRulesManifestPathOwnedByWorkflow {
    param([string]$Path)
    return $Path.Replace("\", "/").TrimStart("./") -eq "dev.env"
}

function Get-AiRulesManifestUserModifiedPaths {
    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return @()
    }
    $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    if ($null -eq $manifest.files) {
        return @()
    }
    return @($manifest.files.PSObject.Properties | Where-Object {
        -not (Test-AiRulesManifestPathOwnedByWorkflow -Path ([string]$_.Name)) -and
        [bool](Get-ConfigValueFromObject -Object $_.Value -Path "userModified" -Default $false)
    } | ForEach-Object { [string]$_.Name })
}

function Test-AiRulesManifestHasUserChanges {
    return @(Get-AiRulesManifestUserModifiedPaths).Count -gt 0
}

function Get-AiRulesUtf8Sha256 {
    param(
        [string]$Text,
        [switch]$WithBom
    )

    $encoding = Get-Utf8Encoding
    $contentBytes = $encoding.GetBytes($Text)
    $bytes = $contentBytes
    if ($WithBom) {
        $preamble = (Get-Utf8BomEncoding).GetPreamble()
        $bytes = New-Object byte[] ($preamble.Length + $contentBytes.Length)
        [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
        [Array]::Copy($contentBytes, 0, $bytes, $preamble.Length, $contentBytes.Length)
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-AiRulesBytesSha256 {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-AiRulesFileMatchesInstalledHash {
    param(
        [string]$Path,
        [string]$InstalledHash
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or $InstalledHash -notmatch '^[0-9a-fA-F]{64}$') {
        return $false
    }
    $expected = $InstalledHash.ToLowerInvariant()
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected) {
        return $true
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        $text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
    } catch {
        return $false
    }
    foreach ($character in $text.ToCharArray()) {
        $code = [int]$character
        if ($code -eq 0 -or ($code -lt 32 -and $code -notin @(9, 10, 13))) {
            return $false
        }
    }

    $lf = [regex]::Replace($text, "`r`n|`r|`n", "`n")
    foreach ($variant in @($lf, $lf.Replace("`n", "`r`n"))) {
        $body = $strictUtf8.GetBytes($variant)
        if ($hasBom) {
            $candidate = New-Object byte[] ($body.Length + 3)
            $candidate[0] = 0xEF
            $candidate[1] = 0xBB
            $candidate[2] = 0xBF
            [Array]::Copy($body, 0, $candidate, 3, $body.Length)
        } else {
            $candidate = $body
        }
        if ((Get-AiRulesBytesSha256 -Bytes $candidate) -eq $expected) {
            return $true
        }
    }
    return $false
}

function Clear-StaleAiRulesEolModifiedMarkers {
    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return 0
    }
    $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    if ($null -eq $manifest.files) {
        return 0
    }

    $projectRootFull = [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $cleared = 0
    foreach ($property in @($manifest.files.PSObject.Properties)) {
        if (-not [bool](Get-ConfigValueFromObject -Object $property.Value -Path "userModified" -Default $false)) {
            continue
        }
        $relative = ([string]$property.Name).Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (Test-AiRulesManifestPathOwnedByWorkflow -Path $relative) {
            continue
        }
        if ([IO.Path]::IsPathRooted($relative)) {
            continue
        }
        $path = [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $relative))
        if (-not $path.StartsWith($projectRootFull, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $installedHash = [string](Get-ConfigValueFromObject -Object $property.Value -Path "installedHash" -Default "")
        if (Test-AiRulesFileMatchesInstalledHash -Path $path -InstalledHash $installedHash) {
            $property.Value | Add-Member -NotePropertyName userModified -NotePropertyValue $false -Force
            $cleared++
        }
    }
    if ($cleared -gt 0) {
        Write-Utf8Text -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
        Write-Host "Cleared $cleared stale ai_rules_1c userModified marker(s) for byte- or LF/CRLF-equivalent managed UTF-8 files."
    }
    return $cleared
}

function Test-AiRulesUserRulesMatchesControlledSourcePrefix {
    param([string]$Text)

    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }
    try {
        $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    } catch {
        return $false
    }
    $sourceRoot = [string](Get-ConfigValueFromObject -Object $manifest -Path "source" -Default "")
    $currentRef = [string](Get-ConfigValue -Path "aiRules.ref" -Default "")
    $currentRepo = [string](Get-ConfigValue -Path "aiRules.repo" -Default "")
    $currentEntry = Get-DependencyLockEntry -Name "aiRules1c"
    $currentCommit = [string](Get-ConfigValueFromObject -Object $currentEntry -Path "commit" -Default "")
    if (-not $sourceRoot -or -not $currentRef -or -not $currentCommit -or
        [string](Get-ConfigValueFromObject -Object $manifest -Path "version" -Default "") -ne $currentRef -or
        -not (Test-AiRules1cForkRepository -Repo $currentRepo) -or
        -not (Test-Path -LiteralPath (Join-Path $sourceRoot ".git"))) {
        return $false
    }

    $sourceHead = @(& git -C $sourceRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $sourceHead.Count -ne 1 -or [string]$sourceHead[0] -ne $currentCommit) {
        return $false
    }
    $sourceStatus = @(& git -C $sourceRoot status --porcelain --untracked-files=no 2>$null)
    if ($LASTEXITCODE -ne 0 -or $sourceStatus.Count -ne 0) {
        return $false
    }
    $sourceOrigin = @(& git -C $sourceRoot remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or $sourceOrigin.Count -ne 1 -or
        (Get-AiRules1cRepositoryIdentity -Repo ([string]$sourceOrigin[0])) -ne (Get-AiRules1cRepositoryIdentity -Repo $currentRepo)) {
        return $false
    }

    $sourcePath = Join-Path $sourceRoot "USER-RULES.md"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        return $false
    }
    $sourceText = Read-Utf8Text -Path $sourcePath
    $legacyHeadingMatches = [regex]::Matches($sourceText, '(?m)^## ITL hard gates\s*$')
    if ($legacyHeadingMatches.Count -ne 1) {
        return $false
    }
    $legacyHeading = $legacyHeadingMatches[0]
    if ([string]::IsNullOrWhiteSpace($sourceText.Substring($legacyHeading.Index + $legacyHeading.Length))) {
        return $false
    }

    $startMarker = "<!-- ITL-WORKFLOW-USER-RULES:START -->"
    $endMarker = "<!-- ITL-WORKFLOW-USER-RULES:END -->"
    if ([regex]::Matches($Text, [regex]::Escape($startMarker)).Count -ne 1 -or
        [regex]::Matches($Text, [regex]::Escape($endMarker)).Count -ne 1) {
        return $false
    }
    $managedMatch = [regex]::Match($Text, "(?s)" + [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker))
    if (-not $managedMatch.Success) {
        return $false
    }
    $outsideOverlay = $Text.Substring(0, $managedMatch.Index) + $Text.Substring($managedMatch.Index + $managedMatch.Length)
    $sourcePrefix = $sourceText.Substring(0, $legacyHeading.Index)
    $normalize = {
        param([string]$Value)
        return ([regex]::Replace($Value, "\r\n?|\n", "`n")).Trim()
    }
    return (& $normalize $outsideOverlay) -ceq (& $normalize $sourcePrefix)
}

function Test-AiRulesUserRulesContainsOnlyWorkflowOverlayChange {
    param([object]$ManifestEntry)

    $installedHash = [string](Get-ConfigValueFromObject -Object $ManifestEntry -Path "installedHash" -Default "")
    if ($installedHash -notmatch '^[0-9a-fA-F]{64}$') {
        return $false
    }
    $path = Join-Path $script:ProjectRoot "USER-RULES.md"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $false
    }

    $text = Read-Utf8Text -Path $path
    $startMarker = "<!-- ITL-WORKFLOW-USER-RULES:START -->"
    $endMarker = "<!-- ITL-WORKFLOW-USER-RULES:END -->"
    if ([regex]::Matches($text, [regex]::Escape($startMarker)).Count -ne 1 -or
        [regex]::Matches($text, [regex]::Escape($endMarker)).Count -ne 1) {
        return $false
    }
    $managedPattern = "(?s)" + [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker)
    $managedMatch = [regex]::Match($text, $managedPattern)
    if (-not $managedMatch.Success) {
        return $false
    }

    $before = $text.Substring(0, $managedMatch.Index)
    $after = $text.Substring($managedMatch.Index + $managedMatch.Length)
    if ([string]::IsNullOrWhiteSpace($before + $after)) {
        return $true
    }
    $beforeWithoutOneNewLine = [regex]::Replace($before, '(?:\r\n|\n|\r)$', '', 1)
    $afterWithoutOneNewLine = [regex]::Replace($after, '^(?:\r\n|\n|\r)', '', 1)
    $candidates = @(
        ($before + $after),
        ($beforeWithoutOneNewLine + $after),
        ($before + $afterWithoutOneNewLine),
        ($beforeWithoutOneNewLine + $afterWithoutOneNewLine)
    ) | Select-Object -Unique
    $expected = $installedHash.ToLowerInvariant()
    foreach ($candidate in $candidates) {
        if ((Get-AiRulesUtf8Sha256 -Text $candidate) -eq $expected -or
            (Get-AiRulesUtf8Sha256 -Text $candidate -WithBom) -eq $expected) {
            return $true
        }
    }
    return (Test-AiRulesUserRulesMatchesControlledSourcePrefix -Text $text)
}

function Clear-StaleAiRulesUserRulesModifiedIfWorkflowOwned {
    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }
    $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    if ($null -eq $manifest.files) {
        return $false
    }
    $candidate = @($manifest.files.PSObject.Properties | Where-Object {
        (($_.Name -replace '\\', '/').TrimStart('./')) -eq "USER-RULES.md" -and
        [bool](Get-ConfigValueFromObject -Object $_.Value -Path "userModified" -Default $false)
    }) | Select-Object -First 1
    if ($null -eq $candidate -or -not (Test-AiRulesUserRulesContainsOnlyWorkflowOverlayChange -ManifestEntry $candidate.Value)) {
        return $false
    }

    $candidate.Value | Add-Member -NotePropertyName userModified -NotePropertyValue $false -Force
    Write-Utf8Text -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    Write-Host "Cleared stale ai_rules_1c USER-RULES.md userModified marker because the file differs from installedHash only by the ITL-managed overlay."
    return $true
}

function Test-AiRulesMcpSnapshotMatchesCurrent {
    param([object]$Snapshot)

    foreach ($path in @($Snapshot.Keys)) {
        $entry = $Snapshot[$path]
        $exists = Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue
        if ($exists -ne [bool]$entry.exists) {
            return $false
        }
        if ($exists) {
            $current = [System.IO.File]::ReadAllBytes($path)
            if ([Convert]::ToBase64String($current) -ne [Convert]::ToBase64String([byte[]]$entry.bytes)) {
                return $false
            }
        }
    }
    return $true
}

function Test-AiRulesMcpSnapshotHasUnknownEntries {
    param(
        [object]$Snapshot,
        [string[]]$Paths,
        [string[]]$KnownServerIds
    )

    $known = @($KnownServerIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    foreach ($serverId in @($known)) {
        if ($serverId -match '^(?i)1c(?<suffix>.*)$') {
            $known += ("onec" + $Matches["suffix"])
        }
    }
    $known = @($known | Select-Object -Unique)

    foreach ($path in @($Paths | Select-Object -Unique)) {
        if (-not $Snapshot.Contains($path) -or -not [bool]$Snapshot[$path].exists) {
            continue
        }
        $text = [System.Text.Encoding]::UTF8.GetString([byte[]]$Snapshot[$path].bytes)
        if ($path -like "*.toml") {
            foreach ($match in [regex]::Matches($text, '(?m)^\[mcp_servers\.(?:"(?<quoted>[^"]+)"|(?<bare>[^\]\s]+))\]\s*$')) {
                $serverId = if ($match.Groups["quoted"].Success) { $match.Groups["quoted"].Value } else { $match.Groups["bare"].Value }
                if ($known -contains $serverId -or (Test-TextIndexInsideVibecoding1cMcpManagedBlock -Text $text -Index $match.Index)) {
                    continue
                }
                return $true
            }
            continue
        }

        if ($path -like "*.json") {
            try {
                $config = $text | ConvertFrom-Json
            } catch {
                return $true
            }
            if ($config.mcp) {
                foreach ($property in @($config.mcp.PSObject.Properties)) {
                    $managedBy = [string](Get-ConfigValueFromObject -Object $property.Value -Path "managedBy" -Default "")
                    if ($known -contains $property.Name -or $managedBy -eq "vibecoding1c-mcp") {
                        continue
                    }
                    return $true
                }
            }
        }
    }
    return $false
}

function Test-AiRulesMcpSnapshotContainsOnlyVibecoding1cManagedEntries {
    param(
        [object]$Snapshot,
        [string[]]$Paths
    )

    $foundManagedEntry = $false
    foreach ($path in @($Paths | Select-Object -Unique)) {
        if (-not $Snapshot.Contains($path) -or -not [bool]$Snapshot[$path].exists) {
            return $false
        }
        $text = [System.Text.Encoding]::UTF8.GetString([byte[]]$Snapshot[$path].bytes)
        if ($path -like "*.toml") {
            $sections = @([regex]::Matches($text, '(?m)^\[mcp_servers\.(?:"[^"]+"|[^\]\s]+)\]\s*$'))
            if ($sections.Count -eq 0) {
                return $false
            }
            foreach ($section in $sections) {
                if (-not (Test-TextIndexInsideVibecoding1cMcpManagedBlock -Text $text -Index $section.Index)) {
                    return $false
                }
                $foundManagedEntry = $true
            }
            continue
        }

        if ($path -notlike "*.json") {
            return $false
        }
        try {
            $config = $text | ConvertFrom-Json
        } catch {
            return $false
        }
        $properties = @()
        if ($config.mcp) {
            $properties = @($config.mcp.PSObject.Properties)
        }
        if ($properties.Count -eq 0) {
            return $false
        }
        foreach ($property in $properties) {
            $managedBy = [string](Get-ConfigValueFromObject -Object $property.Value -Path "managedBy" -Default "")
            $family = [string](Get-ConfigValueFromObject -Object $property.Value -Path "family" -Default "")
            if ($managedBy -ne "vibecoding1c-mcp" -or $family -ne "vibecoding1c") {
                return $false
            }
            $foundManagedEntry = $true
        }
    }
    return $foundManagedEntry
}

function Clear-StaleAiRulesMcpUserModifiedIfWorkflowOwned {
    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }
    $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    if ($null -eq $manifest.files) {
        return $false
    }

    $mcpFileNames = @(".codex/config.toml", ".kilo/kilo.json")
    $candidates = @($manifest.files.PSObject.Properties | Where-Object {
        $normalized = $_.Name -replace '\\', '/'
        $mcpFileNames -contains $normalized -and [bool](Get-ConfigValueFromObject -Object $_.Value -Path "userModified" -Default $false)
    })
    if ($candidates.Count -eq 0) {
        return $false
    }

    $selection = Read-Vibecoding1cMcpSelection
    $selectionCompleteness = Get-Vibecoding1cMcpSelectionCompleteness -Selection $selection
    if (-not $selectionCompleteness.isComplete) {
        return $false
    }
    try {
        $managedServerIds = @(Get-AiRules1cManagedMcpServerIds)
        $readyClientNames = @(Get-Vibecoding1cMcpReadyClientConfigNames)
        $replacementServerIds = @($readyClientNames | Where-Object { $managedServerIds -contains $_ } | Select-Object -Unique)
        if ($replacementServerIds.Count -eq 0) {
            return $false
        }
    } catch {
        return $false
    }

    $snapshot = New-AiRules1cMcpConfigSnapshot -Paths (Get-AiRules1cMcpClientConfigPaths)
    $candidatePaths = @($candidates | ForEach-Object {
        Join-Path $script:ProjectRoot (($_.Name -replace '/', '\').TrimStart('\'))
    })
    if (Test-AiRulesMcpSnapshotHasUnknownEntries -Snapshot $snapshot -Paths $candidatePaths -KnownServerIds (@($managedServerIds) + @($readyClientNames))) {
        return $false
    }
    $containsOnlyWorkflowOwnedEntries = Test-AiRulesMcpSnapshotContainsOnlyVibecoding1cManagedEntries -Snapshot $snapshot -Paths $candidatePaths
    $matchesWorkflowState = $false
    try {
        Write-Vibecoding1cMcpClientConfig
        Remove-AiRules1cManagedMcpConfig -ServerIds $replacementServerIds | Out-Null
        Remove-StaleAiRules1cDataMcpConfig | Out-Null
        $matchesWorkflowState = Test-AiRulesMcpSnapshotMatchesCurrent -Snapshot $snapshot
    } finally {
        Restore-AiRules1cMcpConfigSnapshot -Snapshot $snapshot
    }
    if (-not $matchesWorkflowState -and -not $containsOnlyWorkflowOwnedEntries) {
        return $false
    }

    foreach ($candidate in $candidates) {
        $candidate.Value | Add-Member -NotePropertyName userModified -NotePropertyValue $false -Force
    }
    Write-Utf8Text -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    Write-Host "Cleared stale ai_rules_1c MCP userModified markers because client config matches or contains only explicit ITL ownership state."
    return $true
}

function Get-AiRulesMigrationPlan {
    $target = Get-AiRulesBaselineTarget
    if (-not $target.isConfigured) {
        return [pscustomobject]@{ status = "dormant"; eligible = $false; suppressRegularUpdate = $false; reason = $target.reason; target = $target }
    }

    $currentRepo = [string](Get-ConfigValue -Path "aiRules.repo" -Default "https://github.com/comol/ai_rules_1c.git")
    $currentRef = [string](Get-ConfigValue -Path "aiRules.ref" -Default "")
    $currentIdentity = Get-AiRules1cRepositoryIdentity -Repo $currentRepo
    $targetIdentity = Get-AiRules1cRepositoryIdentity -Repo $target.repo
    $currentEntry = Get-DependencyLockEntry -Name "aiRules1c"
    $currentCommit = [string](Get-ConfigValueFromObject -Object $currentEntry -Path "commit" -Default "")
    $currentRevision = [int](Get-ConfigValueFromObject -Object $currentEntry -Path "downstreamRevision" -Default 0)
    if ($currentIdentity -eq $targetIdentity -and $currentRef -eq $target.ref -and $currentCommit -eq $target.commit -and $currentRevision -eq $target.downstreamRevision) {
        return [pscustomobject]@{ status = "current"; eligible = $false; suppressRegularUpdate = $false; reason = "project already uses the workflow fork baseline"; target = $target }
    }

    $isLegacyUpstream = $currentIdentity -eq "https://github.com/comol/ai_rules_1c"
    $isControlledFork = $currentIdentity -eq $targetIdentity
    if (-not $isLegacyUpstream -and -not $isControlledFork) {
        return [pscustomobject]@{ status = "custom"; eligible = $false; suppressRegularUpdate = $true; reason = "custom aiRules repository is preserved without automatic update"; target = $target }
    }

    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject]@{ status = "manifest-missing"; eligible = $false; suppressRegularUpdate = $true; reason = "legacy ai_rules_1c manifest is missing"; target = $target }
    }
    Clear-StaleAiRulesEolModifiedMarkers | Out-Null
    Clear-StaleAiRulesMcpUserModifiedIfWorkflowOwned | Out-Null
    Clear-StaleAiRulesUserRulesModifiedIfWorkflowOwned | Out-Null
    if (Test-AiRulesManifestHasUserChanges) {
        return [pscustomobject]@{ status = "user-modified"; eligible = $false; suppressRegularUpdate = $true; reason = "legacy ai_rules_1c manifest contains userModified files"; target = $target }
    }

    $tools = @(Get-AiRules1cTools)
    $unsupported = @($tools | Where-Object { $_ -notin (Get-SupportedAgentTargets) })
    if ($unsupported.Count -gt 0) {
        return [pscustomobject]@{ status = "unsupported-tools"; eligible = $false; suppressRegularUpdate = $true; reason = "unsupported migration tools: $($unsupported -join ', ')"; target = $target }
    }

    if (-not $currentCommit) {
        return [pscustomobject]@{ status = "legacy-commit-missing"; eligible = $false; suppressRegularUpdate = $true; reason = "legacy aiRules commit is not recorded"; target = $target }
    }

    if ($isControlledFork) {
        if ($currentRef -notlike "itl-*") {
            return [pscustomobject]@{ status = "controlled-ref-invalid"; eligible = $false; suppressRegularUpdate = $true; reason = "controlled fork project does not use an immutable itl-* ref"; target = $target }
        }
        $lockRepo = [string](Get-ConfigValueFromObject -Object $currentEntry -Path "repo" -Default "")
        if ((Get-AiRules1cRepositoryIdentity -Repo $lockRepo) -ne $targetIdentity) {
            return [pscustomobject]@{ status = "controlled-lock-mismatch"; eligible = $false; suppressRegularUpdate = $true; reason = "controlled fork lock repository does not match project configuration"; target = $target }
        }
        if ($target.downstreamRevision -le $currentRevision) {
            return [pscustomobject]@{ status = "not-newer"; eligible = $false; suppressRegularUpdate = $true; reason = "target downstream revision is not newer than the installed controlled fork"; target = $target }
        }
        $currentUpstreamCommit = [string](Get-ConfigValueFromObject -Object $currentEntry -Path "upstreamCommit" -Default "")
        if (-not $currentUpstreamCommit) {
            return [pscustomobject]@{ status = "controlled-provenance-missing"; eligible = $false; suppressRegularUpdate = $true; reason = "installed controlled fork does not record upstreamCommit"; target = $target }
        }
        return [pscustomobject]@{
            status = "eligible"
            eligible = $true
            suppressRegularUpdate = $true
            reason = "verified controlled fork revision can migrate to a newer verified revision"
            sourceKind = "controlled-fork"
            target = $target
            fromCommit = $currentCommit
            comparisonCommit = $currentUpstreamCommit
            fromDownstreamRevision = $currentRevision
            tools = @($tools)
        }
    }

    return [pscustomobject]@{
        status = "eligible"
        eligible = $true
        suppressRegularUpdate = $true
        reason = "standard legacy upstream project can migrate to verified fork baseline"
        sourceKind = "legacy-upstream"
        target = $target
        fromCommit = $currentCommit
        comparisonCommit = $currentCommit
        tools = @($tools)
    }
}

function Assert-AiRulesMigrationCandidateScope {
    param([string]$RulesRoot)

    $codexAdapter = Read-Utf8Text -Path (Join-Path $RulesRoot "adapters\codex.yaml")
    if ($codexAdapter -match '(?im)copyTo:\s*["'']?~/') {
        throw "Fork candidate still writes user-scope Codex artifacts."
    }
    if ($codexAdapter -notmatch '(?im)^skills:\s*\r?\n\s+copyTo:\s*["'']?\.agents/skills/') {
        throw "Fork candidate does not place Codex project skills under .agents/skills."
    }
}

function Invoke-AiRulesMigrationCandidatePreflight {
    param([object]$Plan)

    $target = $Plan.target
    $checkout = Sync-AiRules1cCheckout -RepoOverride $target.repo -RefOverride $target.ref -CommitOverride $target.commit
    Assert-AiRulesMigrationCandidateScope -RulesRoot $checkout.root

    if (-not $target.upstreamCommit) {
        throw "Fork baseline does not record upstreamCommit."
    }
    & git -C $checkout.root merge-base --is-ancestor $Plan.comparisonCommit $target.upstreamCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Installed aiRules upstream provenance is not an ancestor of the target upstream baseline: $($Plan.comparisonCommit)"
    }

    $preflightRoot = Join-Path (Get-Agent1cTempRoot) ("itl-ai-rules-preflight-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $preflightRoot | Out-Null
        $installScript = Join-Path $checkout.root "install.ps1"
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installScript init `
            -ProjectRoot $preflightRoot -Source $checkout.root -Tools ($Plan.tools -join ",") -NonInteractive -AssumeYes 2>&1 |
            ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "Fork candidate preflight installer failed with exit code $LASTEXITCODE"
        }
        $manifestPath = Join-Path $preflightRoot ".ai-rules.json"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Fork candidate preflight did not create .ai-rules.json"
        }
    } finally {
        Remove-Item -LiteralPath $preflightRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $checkout
}

function New-AiRulesMigrationSnapshot {
    $runRoot = Join-Path $script:ProjectRoot (".agent-1c\runs\ai-rules-migration-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
    $payloadRoot = Join-Path $runRoot "payload"
    New-Item -ItemType Directory -Force -Path $payloadRoot | Out-Null
    $relativePaths = @(
        ".agent-1c\project.json",
        ".agent-1c\dependency-lock.json",
        ".ai-rules.json",
        ".dev.env",
        "AGENTS.md",
        "USER-RULES.md",
        "LLM-RULES.md",
        "memory.md",
        "openspec",
        ".codex",
        ".kilo",
        ".kilocode",
        ".claude",
        ".cursor",
        ".opencode",
        ".kimi-code",
        ".qwen",
        ".commandcode",
        ".cline",
        ".pi",
        "QWEN.md",
        ".mcp.json",
        "opencode.json",
        ".agents"
    )
    $entries = @()
    foreach ($relativePath in $relativePaths) {
        $source = Join-Path $script:ProjectRoot $relativePath
        $present = Test-Path -LiteralPath $source
        $isDirectory = $present -and (Test-Path -LiteralPath $source -PathType Container)
        if ($present) {
            $destination = Join-Path $payloadRoot $relativePath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            if ($isDirectory -and ($relativePath -replace '/', '\').TrimEnd('\') -eq ".kilo") {
                New-Item -ItemType Directory -Force -Path $destination | Out-Null
                foreach ($child in @(Get-ChildItem -LiteralPath $source -Force | Where-Object { $_.Name -ne "worktrees" })) {
                    Copy-Item -LiteralPath $child.FullName -Destination $destination -Recurse -Force
                }
            } else {
                Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
            }
        }
        $entries += [ordered]@{ path = $relativePath; present = [bool]$present; isDirectory = [bool]$isDirectory }
    }
    $manifest = [ordered]@{ schemaVersion = 1; createdAt = (Get-Date).ToString("o"); entries = $entries }
    Write-Utf8Text -Path (Join-Path $runRoot "snapshot.json") -Value (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return [pscustomobject]@{ root = $runRoot; payloadRoot = $payloadRoot; entries = $entries }
}

function Get-LegacyCodexPromptPaths {
    param([string]$RulesRoot)

    $commandsRoot = Join-Path $RulesRoot "content\commands"
    if (-not (Test-Path -LiteralPath $commandsRoot -PathType Container)) {
        return @()
    }
    $promptsRoot = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex\prompts"
    $paths = @()
    foreach ($command in @(Get-ChildItem -LiteralPath $commandsRoot -File -Filter "*.md")) {
        $candidate = Join-Path $promptsRoot $command.Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $paths += $candidate
        }
    }
    return @($paths)
}

function Restore-AiRulesMigrationSnapshot {
    param([object]$Snapshot)

    foreach ($entry in @($Snapshot.entries)) {
        $relativePath = [string]$entry.path
        $target = Join-Path $script:ProjectRoot $relativePath
        if (($relativePath -replace '/', '\').TrimEnd('\') -eq ".kilo") {
            if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Container)) {
                Remove-Item -LiteralPath $target -Force
            }
            if (Test-Path -LiteralPath $target -PathType Container) {
                foreach ($child in @(Get-ChildItem -LiteralPath $target -Force | Where-Object { $_.Name -ne "worktrees" })) {
                    Remove-Item -LiteralPath $child.FullName -Recurse -Force
                }
            }
            if ([bool]$entry.present) {
                $source = Join-Path $Snapshot.payloadRoot $relativePath
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                foreach ($child in @(Get-ChildItem -LiteralPath $source -Force)) {
                    Copy-Item -LiteralPath $child.FullName -Destination $target -Recurse -Force
                }
            }
            continue
        }
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        if ([bool]$entry.present) {
            $source = Join-Path $Snapshot.payloadRoot ([string]$entry.path)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
        }
    }
    [void](Read-ProjectConfig)
}

function Set-AiRulesMigrationTarget {
    param([object]$Target)

    $config = ConvertTo-Agent1cHashtable -Object (Read-Utf8Text -Path $script:ConfigPath | ConvertFrom-Json)
    $aiRules = ConvertTo-Agent1cHashtable -Object $config["aiRules"]
    $aiRules["repo"] = [string]$Target.repo
    $aiRules["ref"] = [string]$Target.ref
    $aiRules["tools"] = @((Get-AiRules1cTools | Select-Object -First 1))
    $config["aiRules"] = $aiRules
    Write-Utf8Text -Path $script:ConfigPath -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

    $lock = ConvertTo-Agent1cHashtable -Object (Read-DependencyLockManifest)
    $dependencies = ConvertTo-Agent1cHashtable -Object $lock["dependencies"]
    $dependencies["aiRules1c"] = ConvertTo-Agent1cHashtable -Object $Target.lockEntry
    $lock["dependencies"] = $dependencies
    Write-DependencyLockManifest -Manifest $lock
    [void](Read-ProjectConfig)
}

function New-AiRulesMigrationRecoveryReport {
    param([object]$Plan)

    $runRoot = Join-Path $script:ProjectRoot (".agent-1c\runs\ai-rules-migration-recovery-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $currentEntry = Get-DependencyLockEntry -Name "aiRules1c"
    $recommendedAction = switch ([string]$Plan.status) {
        "custom" { "Review and pin the custom repository manually; ITL will not replace or update it automatically." }
        "user-modified" { "Back up and review userModified managed files, resolve them explicitly, then retry update-workflow." }
        default { "Review the recorded current and target provenance, repair the blocking condition, then retry update-workflow." }
    }
    $report = [ordered]@{
        schemaVersion = 1
        status = "blocked"
        migrationStatus = [string]$Plan.status
        reason = [string]$Plan.reason
        recordedAt = (Get-Date).ToString("o")
        current = [ordered]@{
            repo = [string](Get-ConfigValue -Path "aiRules.repo" -Default "")
            ref = [string](Get-ConfigValue -Path "aiRules.ref" -Default "")
            commit = [string](Get-ConfigValueFromObject -Object $currentEntry -Path "commit" -Default "")
            upstreamCommit = [string](Get-ConfigValueFromObject -Object $currentEntry -Path "upstreamCommit" -Default "")
            downstreamRevision = [int](Get-ConfigValueFromObject -Object $currentEntry -Path "downstreamRevision" -Default 0)
        }
        target = [ordered]@{
            repo = [string]$Plan.target.repo
            ref = [string]$Plan.target.ref
            commit = [string]$Plan.target.commit
            upstreamCommit = [string]$Plan.target.upstreamCommit
            downstreamRevision = [int]$Plan.target.downstreamRevision
        }
        userModifiedFiles = $(if ([string]$Plan.status -eq "user-modified") { @(Get-AiRulesManifestUserModifiedPaths) } else { @() })
        recommendedAction = $recommendedAction
    }
    $path = Join-Path $runRoot "recovery-report.json"
    Write-Utf8Text -Path $path -Value (($report | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Write-Host "ai_rules_1c recovery report: $path"
    return $path
}

function Assert-AiRulesBaselineMigrationResult {
    param([object]$Migration)

    if ([bool]$Migration.migrated -or -not [bool]$Migration.suppressRegularUpdate -or [string]$Migration.status -eq "custom") {
        return
    }
    $recoveryReportPath = [string](Get-ConfigValueFromObject -Object $Migration -Path "recoveryReportPath" -Default "")
    Set-RunFailureContext -Category "ai-rules-migration-blocked" -RequiredAction "Resolve the ai_rules_1c migration recovery report, then retry /itl-update-workflow."
    $reportSuffix = if ($recoveryReportPath) { " Recovery report: $recoveryReportPath" } else { "" }
    throw "ai_rules_1c migration is blocked ($($Migration.status)): $($Migration.reason).$reportSuffix"
}

function Invoke-AiRulesBaselineMigration {
    $plan = Get-AiRulesMigrationPlan
    if (-not $plan.eligible) {
        $recoveryReportPath = ""
        if ($plan.status -notin @("dormant", "current")) {
            Write-Host "ai_rules_1c baseline migration not applied: $($plan.reason)"
            $recoveryReportPath = New-AiRulesMigrationRecoveryReport -Plan $plan
        }
        return [pscustomobject]@{ migrated = $false; suppressRegularUpdate = [bool]$plan.suppressRegularUpdate; status = $plan.status; reason = $plan.reason; recoveryReportPath = $recoveryReportPath }
    }

    $preflightOutput = @(Invoke-AiRulesMigrationCandidatePreflight -Plan $plan)
    $candidate = @($preflightOutput | Where-Object { $_ -and $_.PSObject.Properties.Name -contains "root" }) | Select-Object -Last 1
    if ($null -eq $candidate) {
        throw "ai_rules_1c migration preflight did not return a candidate checkout."
    }
    $legacyPrompts = @(Get-LegacyCodexPromptPaths -RulesRoot ([string]$candidate.root))
    $snapshot = New-AiRulesMigrationSnapshot
    try {
        Set-AiRulesMigrationTarget -Target $plan.target | Out-Null
        Update-AiRules1c | Out-Null
        $report = [ordered]@{
            schemaVersion = 1
            status = "passed"
            migratedAt = (Get-Date).ToString("o")
            sourceKind = $plan.sourceKind
            fromCommit = $plan.fromCommit
            fromUpstreamCommit = $plan.comparisonCommit
            fromDownstreamRevision = $(if ($plan.sourceKind -eq "controlled-fork") { $plan.fromDownstreamRevision } else { $null })
            forkRepo = $plan.target.repo
            forkRef = $plan.target.ref
            forkCommit = $plan.target.commit
            upstreamRef = $plan.target.upstreamRef
            upstreamCommit = $plan.target.upstreamCommit
            legacyUserScopePrompts = @($legacyPrompts)
        }
        Write-Utf8Text -Path (Join-Path $snapshot.root "migration-report.json") -Value (($report | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        Write-Host "ai_rules_1c migrated to $($plan.target.ref) at $($plan.target.commit)."
        if ($legacyPrompts.Count -gt 0) {
            Write-Host "Legacy user-scope Codex prompts were preserved and require separate manual review:"
            foreach ($promptPath in $legacyPrompts) { Write-Host "  $promptPath" }
        }
        return [pscustomobject]@{ migrated = $true; suppressRegularUpdate = $true; status = "migrated"; snapshotRoot = $snapshot.root }
    } catch {
        $failure = $_.Exception.Message
        Restore-AiRulesMigrationSnapshot -Snapshot $snapshot
        Write-Utf8Text -Path (Join-Path $snapshot.root "migration-failure.txt") -Value ($failure + [Environment]::NewLine)
        throw "ai_rules_1c migration failed and project files were restored from $($snapshot.root): $failure"
    }
}

function Write-AiRules1cStatusLines {
    $repo = [string](Get-ConfigValue -Path "aiRules.repo" -Default "https://github.com/comol/ai_rules_1c.git")
    $ref = [string](Get-ConfigValue -Path "aiRules.ref" -Default "")
    $entry = Get-DependencyLockEntry -Name "aiRules1c"
    $commit = [string](Get-ConfigValueFromObject -Object $entry -Path "commit" -Default "")
    Write-Host "ai_rules_1c repo: $repo"
    Write-Host "ai_rules_1c ref: $(if ($ref) { $ref } else { '<legacy dynamic>' })"
    Write-Host "ai_rules_1c commit: $(if ($commit) { $commit } else { '<not recorded>' })"
    $upstreamRef = [string](Get-ConfigValueFromObject -Object $entry -Path "upstreamRef" -Default "")
    $upstreamCommit = [string](Get-ConfigValueFromObject -Object $entry -Path "upstreamCommit" -Default "")
    if ($upstreamRef -or $upstreamCommit) {
        Write-Host "ai_rules_1c upstream provenance: $upstreamRef@$upstreamCommit"
    }
    $plan = Get-AiRulesMigrationPlan
    if ($plan.status -eq "eligible") {
        Write-Host "ai_rules_1c migration: pending -> $($plan.target.ref)"
    } elseif ($plan.status -notin @("dormant", "current")) {
        Write-Host "ai_rules_1c migration: $($plan.status) ($($plan.reason))"
    }
}
