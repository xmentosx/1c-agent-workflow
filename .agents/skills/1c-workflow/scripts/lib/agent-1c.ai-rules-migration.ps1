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

function Test-AiRulesManifestHasUserChanges {
    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }
    $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    if ($null -eq $manifest.files) {
        return $false
    }
    foreach ($property in @($manifest.files.PSObject.Properties)) {
        if ([bool](Get-ConfigValueFromObject -Object $property.Value -Path "userModified" -Default $false)) {
            return $true
        }
    }
    return $false
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
        return [pscustomobject]@{ status = "custom"; eligible = $false; suppressRegularUpdate = $false; reason = "custom aiRules repository is preserved"; target = $target }
    }

    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject]@{ status = "manifest-missing"; eligible = $false; suppressRegularUpdate = $true; reason = "legacy ai_rules_1c manifest is missing"; target = $target }
    }
    if (Test-AiRulesManifestHasUserChanges) {
        return [pscustomobject]@{ status = "user-modified"; eligible = $false; suppressRegularUpdate = $true; reason = "legacy ai_rules_1c manifest contains userModified files"; target = $target }
    }

    $tools = @(Get-AiRules1cTools)
    $unsupported = @($tools | Where-Object { $_ -notin @("codex", "kilocode") })
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
    $kiloAdapter = Read-Utf8Text -Path (Join-Path $RulesRoot "adapters\kilocode.yaml")
    if ($codexAdapter -match '(?im)copyTo:\s*["'']?~/') {
        throw "Fork candidate still writes user-scope Codex artifacts."
    }
    foreach ($entry in @($codexAdapter, $kiloAdapter)) {
        if ($entry -notmatch '(?im)^skills:\s*\r?\n\s+copyTo:\s*["'']?\.agents/skills/') {
            throw "Fork candidate does not place shared skills under .agents/skills."
        }
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

    $preflightRoot = Join-Path (Resolve-Agent1cFullPath -Path $env:TEMP) ("itl-ai-rules-preflight-" + [guid]::NewGuid().ToString("N"))
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
        "AGENTS.md",
        "USER-RULES.md",
        "memory.md",
        ".codex",
        ".kilo",
        ".kilocode",
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
            Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
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
        $target = Join-Path $script:ProjectRoot ([string]$entry.path)
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        if ([bool]$entry.present) {
            $source = Join-Path $Snapshot.payloadRoot ([string]$entry.path)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
        }
    }
    Read-ProjectConfig
}

function Set-AiRulesMigrationTarget {
    param([object]$Target)

    $config = ConvertTo-Agent1cHashtable -Object (Read-Utf8Text -Path $script:ConfigPath | ConvertFrom-Json)
    $aiRules = ConvertTo-Agent1cHashtable -Object $config["aiRules"]
    $aiRules["repo"] = [string]$Target.repo
    $aiRules["ref"] = [string]$Target.ref
    $config["aiRules"] = $aiRules
    Write-Utf8Text -Path $script:ConfigPath -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

    $lock = ConvertTo-Agent1cHashtable -Object (Read-DependencyLockManifest)
    $dependencies = ConvertTo-Agent1cHashtable -Object $lock["dependencies"]
    $dependencies["aiRules1c"] = ConvertTo-Agent1cHashtable -Object $Target.lockEntry
    $lock["dependencies"] = $dependencies
    Write-DependencyLockManifest -Manifest $lock
    Read-ProjectConfig
}

function Invoke-AiRulesBaselineMigration {
    $plan = Get-AiRulesMigrationPlan
    if (-not $plan.eligible) {
        if ($plan.status -notin @("dormant", "current")) {
            Write-Host "ai_rules_1c baseline migration not applied: $($plan.reason)"
        }
        return [pscustomobject]@{ migrated = $false; suppressRegularUpdate = [bool]$plan.suppressRegularUpdate; status = $plan.status; reason = $plan.reason }
    }

    $preflightOutput = @(Invoke-AiRulesMigrationCandidatePreflight -Plan $plan)
    $candidate = @($preflightOutput | Where-Object { $_ -and $_.PSObject.Properties.Name -contains "root" }) | Select-Object -Last 1
    if ($null -eq $candidate) {
        throw "ai_rules_1c migration preflight did not return a candidate checkout."
    }
    $legacyPrompts = @(Get-LegacyCodexPromptPaths -RulesRoot ([string]$candidate.root))
    $snapshot = New-AiRulesMigrationSnapshot
    try {
        Set-AiRulesMigrationTarget -Target $plan.target
        Update-AiRules1c
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
