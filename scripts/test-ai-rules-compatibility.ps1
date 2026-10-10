[CmdletBinding()]
param(
    [string]$AiRulesSource = "https://github.com/xmentosx/itl_ai_rules_1c.git",
    [string]$AiRulesRef = "",
    [string]$WorkingDirectory = "",
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi", "zcode", "mimocode")

if ([string]::IsNullOrWhiteSpace($AiRulesRef)) {
    $lockPath = Join-Path (Split-Path -Parent $PSScriptRoot) "templates\dependency-lock.json"
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw "Canonical dependency lock was not found: $lockPath" }
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $AiRulesRef = [string]$lock.dependencies.aiRules1c.ref
    if ([string]::IsNullOrWhiteSpace($AiRulesRef)) { throw "Canonical dependency lock has no aiRules1c ref: $lockPath" }
}

function Get-ManifestEntries {
    param([object]$Manifest)
    if ($null -eq $Manifest.files) { return @() }
    return @($Manifest.files.PSObject.Properties | ForEach-Object {
        $scope = if ($_.Value.PSObject.Properties['scope']) { [string]$_.Value.scope } else { '' }
        $owners = if ($_.Value.PSObject.Properties['owners']) { @($_.Value.owners) } else { @() }
        [pscustomobject]@{ target = [string]$_.Name; source = [string]$_.Value.source; owners = $owners; scope = $scope }
    })
}

function Assert-OpenSpecBundle {
    param([string]$RulesRoot, [string]$ProjectRoot, [object]$Manifest, [string]$Tool)
    $bundleRoot = Join-Path $RulesRoot ("content\openspec-bundle\$Tool")
    if (-not (Test-Path -LiteralPath $bundleRoot -PathType Container)) { return }
    $basePath = (Resolve-Path -LiteralPath $bundleRoot).Path.TrimEnd('\', '/')
    $entries = @(Get-ManifestEntries -Manifest $Manifest)
    $missing = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $bundleRoot -Recurse -File)) {
        $relative = $file.FullName.Substring($basePath.Length + 1).Replace('\', '/')
        $source = "content/openspec-bundle/$Tool/$relative"
        # Adapter destinations may differ from the physical bundle path (Codex
        # maps command skills into .agents/skills). The installer manifest is
        # the authoritative source-to-target mapping.
        $matches = @($entries | Where-Object { $_.source.Replace('\', '/') -eq $source })
        if ($matches.Count -eq 0 -or @($matches | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ProjectRoot $_.target) -PathType Leaf) }).Count -gt 0) { $missing += $relative; continue }
        foreach ($match in $matches) {
            if ($Tool -eq 'codex' -and $match.target -notlike '.agents/skills/*/*') {
                throw "Codex OpenSpec bundle must use the canonical .agents/skills directory: $($match.target)"
            }
            $installed = Join-Path $ProjectRoot $match.target
            if ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
                throw "OpenSpec bundle for $Tool contains stale or altered phase bytes: $($match.target)"
            }
        }
    }
    if ($missing.Count -gt 0) { throw "OpenSpec bundle for $Tool is incomplete: $($missing -join ', ')" }
    $bundleVersionProperty = $Manifest.integrations.openspec.PSObject.Properties['artifactsBundleVersion']
    if ($Tool -eq 'codex' -and $null -ne $bundleVersionProperty -and [string]$bundleVersionProperty.Value -eq '1.13.1') {
        $legacy = @($entries | Where-Object {
            $_.source.Replace('\','/') -like 'content/openspec-bundle/codex/*' -and
            $_.target.Replace('\','/') -match '^\.(?:codex/skills/(?:openspec-|opsx-)|agents/skills/opsx-)'
        } | ForEach-Object { $_.target })
        foreach ($phase in @('explore','propose','apply-change','archive-change','update-change','sync-specs')) {
            $relative = ".codex/skills/openspec-$phase/SKILL.md"
            if (Test-Path -LiteralPath (Join-Path $ProjectRoot $relative) -PathType Leaf) { $legacy += $relative }
        }
        foreach ($phase in @('explore','propose','apply','archive','update','sync')) {
            foreach ($directory in @('.codex/skills','.agents/skills')) {
                $relative = "$directory/opsx-$phase/SKILL.md"
                if (Test-Path -LiteralPath (Join-Path $ProjectRoot $relative) -PathType Leaf) { $legacy += $relative }
            }
        }
        if ($legacy.Count -gt 0) { throw "Codex OpenSpec 1.13.1 retains retired aliases: $(@($legacy | Sort-Object -Unique) -join ', ')" }
    }
}

function Assert-WorkflowExtensionTools {
    param(
        [string]$HelperPath,
        [string]$ProjectRoot,
        [object]$Manifest,
        [string]$Client
    )

    $resolved = @(& {
        . $HelperPath -ProjectRoot $ProjectRoot -Action help -AgentTarget $Client *> $null
        Get-ExtensionLifecycleToolPaths
    })
    if ($resolved.Count -ne 1) {
        throw "Workflow extension tool resolver returned $($resolved.Count) results for $Client."
    }

    $entries = @(Get-ManifestEntries -Manifest $Manifest)
    $required = [ordered]@{
        init = "1c-metadata-manage/tools/1c-cfe-manage/scripts/cfe-init.ps1"
        validate = "1c-metadata-manage/tools/1c-cfe-manage/scripts/cfe-validate.ps1"
    }
    foreach ($name in @($required.Keys)) {
        $suffix = [string]$required[$name]
        $matches = @($entries | Where-Object { $_.target.Replace('\', '/').EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) })
        if ($matches.Count -ne 1) {
            throw "ai_rules_1c manifest must contain exactly one $suffix target for $Client; actual: $($matches.Count)."
        }
        $manifestPath = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ([string]$matches[0].target)))
        $resolvedPath = [IO.Path]::GetFullPath([string]$resolved[0].$name)
        if (-not [string]::Equals($manifestPath, $resolvedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Workflow resolved $name outside the installed $Client manifest target. Manifest: $manifestPath. Workflow: $resolvedPath."
        }
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            throw "Workflow resolved missing $Client extension tool: $resolvedPath"
        }
    }
}

function Get-CodexPromptSnapshot {
    param([string]$RulesRoot)
    $commandsRoot = Join-Path $RulesRoot "content\commands"
    $promptsRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".codex\prompts"
    $records = [ordered]@{}
    foreach ($command in @(Get-ChildItem -LiteralPath $commandsRoot -File -Filter "*.md" -ErrorAction SilentlyContinue)) {
        $target = Join-Path $promptsRoot $command.Name
        $records[$target] = $(if (Test-Path -LiteralPath $target -PathType Leaf) { (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash } else { "<missing>" })
    }
    return $records
}

function Assert-CodexPromptSnapshotUnchanged {
    param([System.Collections.IDictionary]$Before, [System.Collections.IDictionary]$After)
    foreach ($path in @($Before.Keys)) { if (-not $After.Contains($path) -or $After[$path] -ne $Before[$path]) { throw "Compatibility check changed user-scope Codex prompt: $path" } }
}

function Get-ProjectFileDigest {
    param([string]$Root)
    $lines = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
        "$relative=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    })
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

$workRoot = if ($WorkingDirectory) { [IO.Path]::GetFullPath($WorkingDirectory) } else { Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-rules-compat-" + [guid]::NewGuid().ToString("N")) }
$createdWorkRoot = $false
try {
    if (Test-Path -LiteralPath $workRoot) { throw "Compatibility work directory already exists: $workRoot" }
    New-Item -ItemType Directory -Path $workRoot | Out-Null
    $createdWorkRoot = $true
    $rulesRoot = Join-Path $workRoot "ai_rules_1c"
    if (Test-Path -LiteralPath $AiRulesSource -PathType Container) {
        # A local development checkout may contain ignored node_modules or gate output.
        # Install from an exact Git clone, as publication would, not from those live files.
        & git clone --quiet --no-hardlinks $AiRulesSource $rulesRoot
        if ($LASTEXITCODE -ne 0) { throw "Failed to clone local ai_rules_1c source: $AiRulesSource" }
        & git -C $rulesRoot checkout --quiet --detach $AiRulesRef
        if ($LASTEXITCODE -ne 0) { throw "Failed to select ai_rules_1c ref '$AiRulesRef' in the clean clone." }
    } else {
        & git clone --depth 1 --branch $AiRulesRef --single-branch $AiRulesSource $rulesRoot
        if ($LASTEXITCODE -ne 0) { throw "Failed to clone ai_rules_1c from $AiRulesSource" }
    }
    $requestedCommit = ([string](& git -C $rulesRoot rev-parse "$AiRulesRef^{commit}" 2>$null)).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $requestedCommit) { throw "ai_rules_1c reference cannot be resolved in the selected checkout: $AiRulesRef" }
    $actualCommit = ([string](& git -C $rulesRoot rev-parse HEAD 2>$null)).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $requestedCommit) {
        throw "ai_rules_1c compatibility requires exact checkout HEAD '$requestedCommit', got '$actualCommit'. Select the requested ref in an isolated checkout before retrying."
    }
    $installScript = Join-Path $rulesRoot "install.ps1"
    if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) { throw "ai_rules_1c install.ps1 was not found: $installScript" }
    $overlayLockCheck = Join-Path $PSScriptRoot "test-ai-rules-overlay-lock.ps1"
    & $overlayLockCheck -AiRulesRoot $rulesRoot -WorkingDirectory (Join-Path $workRoot "overlay-lock") | Out-Host
    $workflowHelper = Join-Path (Split-Path -Parent $PSScriptRoot) ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    if (-not (Test-Path -LiteralPath $workflowHelper -PathType Leaf)) { throw "Workflow helper was not found: $workflowHelper" }
    $promptBefore = Get-CodexPromptSnapshot -RulesRoot $rulesRoot

    foreach ($client in $clients) {
        $projectRoot = Join-Path $workRoot "project-$client"
        New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null
        foreach ($itlSkill in @("1c-workflow", "1c-workflow-fast", "product-docs", "itl-roctup-1c-data", "itl-vanessa-ui-mcp", "itl-remote-runner", "itl-remote-agent", "itl-performance")) {
            $skillPath = Join-Path $projectRoot ".agents\skills\$itlSkill\SKILL.md"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillPath) | Out-Null
            [IO.File]::WriteAllText($skillPath, "fixture $itlSkill`n", [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText((Join-Path $projectRoot "LLM-RULES.md"), "user evolution memory`n", [Text.UTF8Encoding]::new($false))
        $llmHash = (Get-FileHash -LiteralPath (Join-Path $projectRoot "LLM-RULES.md") -Algorithm SHA256).Hash
        if ($client -eq "kilocode") {
            $kiloPath = Join-Path $projectRoot ".kilo\kilo.json"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $kiloPath) | Out-Null
            [IO.File]::WriteAllText($kiloPath, '{"instructions":["docs/custom.md"],"permission":{"bash":"ask"}}', [Text.UTF8Encoding]::new($false))
        }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript init -ProjectRoot $projectRoot -Source $rulesRoot -Tools $client -McpMode delegated -NonInteractive -AssumeYes
        if ($LASTEXITCODE -ne 0) { throw "ai_rules_1c init failed for $client with exit code $LASTEXITCODE" }
        $manifest = Get-Content -LiteralPath (Join-Path $projectRoot ".ai-rules.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$manifest.protocol -ne "1.1") { throw "ai_rules_1c manifest protocol must be 1.1 for $client" }
        if (@($manifest.tools).Count -ne 1 -or [string]$manifest.tools[0] -ne $client) { throw "Exact-one-client manifest failed for $client" }
        $installedMemory = Get-Content -LiteralPath (Join-Path $projectRoot 'memory.md') -Raw -Encoding UTF8
        if ($installedMemory -notmatch 'managed ITL project' -or
            $installedMemory -notmatch 'project-scoped `1c-templates-mcp` memory' -or
            $installedMemory -notmatch 'Outside managed ITL projects') {
            throw "Installed memory route does not preserve the managed ITL project boundary for $client"
        }
        Assert-OpenSpecBundle -RulesRoot $rulesRoot -ProjectRoot $projectRoot -Manifest $manifest -Tool $client
        Assert-WorkflowExtensionTools -HelperPath $workflowHelper -ProjectRoot $projectRoot -Manifest $manifest -Client $client
        foreach ($itlSkill in @("1c-workflow", "1c-workflow-fast", "product-docs", "itl-roctup-1c-data", "itl-vanessa-ui-mcp", "itl-remote-runner", "itl-remote-agent", "itl-performance")) {
            if (-not (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\$itlSkill\SKILL.md") -PathType Leaf)) { throw "ITL skill was removed for ${client}: $itlSkill" }
        }
        if ((Get-FileHash -LiteralPath (Join-Path $projectRoot "LLM-RULES.md") -Algorithm SHA256).Hash -ne $llmHash) { throw "LLM-RULES.md changed during init for $client" }
        if ($client -eq "kilocode") {
            $kilo = Get-Content -LiteralPath (Join-Path $projectRoot ".kilo\kilo.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            if ((@($kilo.instructions) -join ',') -ne 'docs/custom.md' -or [string]$kilo.permission.bash -ne 'ask') { throw "Kilo shared config preservation failed" }
        }
        $beforeUpdate = Get-ProjectFileDigest -Root $projectRoot
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript update -ProjectRoot $projectRoot -Source $rulesRoot -McpMode delegated -NonInteractive -AssumeYes
        if ($LASTEXITCODE -ne 0) { throw "ai_rules_1c update failed for $client with exit code $LASTEXITCODE" }
        $afterUpdate = Get-ProjectFileDigest -Root $projectRoot
        if ($beforeUpdate -ne $afterUpdate) { throw "Repeated ai_rules update was not byte-idempotent for $client" }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript doctor -ProjectRoot $projectRoot -Source $rulesRoot
        if ($LASTEXITCODE -ne 0) { throw "ai_rules_1c doctor failed for $client with exit code $LASTEXITCODE" }
    }
    Assert-CodexPromptSnapshotUnchanged -Before $promptBefore -After (Get-CodexPromptSnapshot -RulesRoot $rulesRoot)
    Write-Host "ai_rules_1c compatibility passed for all twelve supported clients. Protocol 1.1; McpMode delegated."
} finally {
    if ($createdWorkRoot -and (Test-Path -LiteralPath $workRoot -PathType Container)) {
        $actual = [IO.Path]::GetFullPath((Get-Item -LiteralPath $workRoot -Force).FullName)
        if (-not [string]::Equals($actual, $workRoot, [StringComparison]::OrdinalIgnoreCase) -or
            ((Get-Item -LiteralPath $workRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing recursive cleanup of changed compatibility work directory: $workRoot"
        }
        if (-not $KeepArtifacts) { Remove-Item -LiteralPath $workRoot -Recurse -Force }
        else { Write-Host "Compatibility artifacts retained: $workRoot" }
    }
}
