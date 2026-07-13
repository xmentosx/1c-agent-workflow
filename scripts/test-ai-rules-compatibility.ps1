[CmdletBinding()]
param(
    [string]$AiRulesSource = "https://github.com/xmentosx/itl_ai_rules_1c.git",
    [string]$AiRulesRef = "itl-main-a421cf44-r4",
    [string]$WorkingDirectory = "",
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ManifestEntries {
    param([object]$Manifest)

    if ($null -eq $Manifest.files) {
        return @()
    }
    return @($Manifest.files.PSObject.Properties | ForEach-Object {
        [pscustomobject]@{
            target = [string]$_.Name
            source = [string]$_.Value.source
            owners = @($_.Value.owners)
            scope = [string]$_.Value.scope
        }
    })
}

function Assert-OpenSpecBundle {
    param(
        [string]$RulesRoot,
        [string]$ProjectRoot,
        [object]$Manifest,
        [string]$Tool
    )

    $bundleRoot = Join-Path $RulesRoot ("content\openspec-bundle\$Tool")
    if (-not (Test-Path -LiteralPath $bundleRoot -PathType Container)) {
        throw "OpenSpec bundle was not found for ${Tool}: $bundleRoot"
    }

    $basePath = (Resolve-Path -LiteralPath $bundleRoot).Path.TrimEnd('\', '/')
    $entries = @(Get-ManifestEntries -Manifest $Manifest)
    $missing = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $bundleRoot -Recurse -File)) {
        $relative = $file.FullName.Substring($basePath.Length + 1).Replace('\', '/')
        $matches = @($entries | Where-Object { $_.target -eq $relative })
        if ($matches.Count -eq 0) {
            $missing += $relative
            continue
        }
        if (@($matches | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ProjectRoot $_.target) -PathType Leaf) }).Count -gt 0) {
            $missing += $relative
        }
    }

    if ($missing.Count -gt 0) {
        throw "OpenSpec bundle for $Tool is incomplete: $($missing -join ', ')"
    }
}

function Get-CodexPromptSnapshot {
    param([string]$RulesRoot)

    $commandsRoot = Join-Path $RulesRoot "content\commands"
    $promptsRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".codex\prompts"
    $records = [ordered]@{}
    if (-not (Test-Path -LiteralPath $commandsRoot -PathType Container)) {
        return $records
    }

    foreach ($command in @(Get-ChildItem -LiteralPath $commandsRoot -File -Filter "*.md")) {
        $targetPath = Join-Path $promptsRoot $command.Name
        $records[$targetPath] = if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
        } else { "<missing>" }
    }
    return $records
}

function Assert-CodexPromptSnapshotUnchanged {
    param([System.Collections.IDictionary]$Before, [System.Collections.IDictionary]$After)
    foreach ($path in @($Before.Keys)) {
        if (-not $After.Contains($path) -or $After[$path] -ne $Before[$path]) {
            throw "Compatibility check changed user-scope Codex prompt: $path"
        }
    }
}

$workRoot = if ($WorkingDirectory) {
    [System.IO.Path]::GetFullPath($WorkingDirectory)
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-compat-" + [guid]::NewGuid().ToString("N"))
}
$codexPromptBefore = [ordered]@{}

try {
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    $rulesRoot = ""
    if (Test-Path -LiteralPath $AiRulesSource -PathType Container) {
        $rulesRoot = (Resolve-Path -LiteralPath $AiRulesSource).Path
    } else {
        $rulesRoot = Join-Path $workRoot "ai_rules_1c"
        & git clone --depth 1 --branch $AiRulesRef --single-branch $AiRulesSource $rulesRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone ai_rules_1c from $AiRulesSource"
        }
    }

    $installScript = Join-Path $rulesRoot "install.ps1"
    if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
        throw "ai_rules_1c install.ps1 was not found: $installScript"
    }

    $codexPromptBefore = Get-CodexPromptSnapshot -RulesRoot $rulesRoot

    $projectRoot = Join-Path $workRoot "project"
    New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript init `
        -ProjectRoot $projectRoot `
        -Source $rulesRoot `
        -Tools "codex,kilocode" `
        -NonInteractive `
        -AssumeYes
    if ($LASTEXITCODE -ne 0) {
        throw "ai_rules_1c init failed with exit code $LASTEXITCODE"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript doctor `
        -ProjectRoot $projectRoot `
        -Source $rulesRoot
    if ($LASTEXITCODE -ne 0) {
        throw "ai_rules_1c doctor failed with exit code $LASTEXITCODE"
    }

    $manifestPath = Join-Path $projectRoot ".ai-rules.json"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.protocol -ne "1.1") {
        throw "ai_rules_1c manifest protocol must be 1.1; actual: $($manifest.protocol)"
    }
    foreach ($tool in @("codex", "kilocode")) {
        if (@($manifest.tools) -notcontains $tool) {
            throw "ai_rules_1c manifest does not list required tool: $tool"
        }
        Assert-OpenSpecBundle -RulesRoot $rulesRoot -ProjectRoot $projectRoot -Manifest $manifest -Tool $tool
    }

    foreach ($required in @("doctor", "1c-metadata-manage", "openspec-propose")) {
        $skillPath = Join-Path $projectRoot ".agents\skills\$required\SKILL.md"
        if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) { throw "Shared skill is missing: $skillPath" }
    }
    foreach ($forbidden in @(".codex\skills", ".kilo\skills", ".kilocode", ".kilo\commands\doctor.md")) {
        if (Test-Path -LiteralPath (Join-Path $projectRoot $forbidden)) { throw "Legacy or duplicate layout exists: $forbidden" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\opsx-propose.md") -PathType Leaf)) {
        throw "Kilo OpenSpec command is missing."
    }
    foreach ($target in @(".agents/skills/doctor/SKILL.md", ".agents/skills/1c-metadata-manage/SKILL.md", ".agents/skills/openspec-propose/SKILL.md")) {
        $entry = @(Get-ManifestEntries -Manifest $manifest | Where-Object { $_.target -eq $target }) | Select-Object -First 1
        if ($null -eq $entry -or $entry.scope -ne "project" -or @($entry.owners | Sort-Object) -join "," -ne "codex,kilocode") {
            throw "Shared manifest ownership is invalid: $target"
        }
    }
    $agentsPath = Join-Path $projectRoot "AGENTS.md"
    if ((Get-Item -LiteralPath $agentsPath).Length -gt 32768) { throw "Rendered AGENTS.md exceeds 32 KiB." }
    $codexPromptAfter = Get-CodexPromptSnapshot -RulesRoot $rulesRoot
    Assert-CodexPromptSnapshotUnchanged -Before $codexPromptBefore -After $codexPromptAfter

    Write-Host "ai_rules_1c compatibility passed for codex and kilocode."
} finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $workRoot -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($KeepArtifacts) {
        Write-Host "Compatibility artifacts retained: $workRoot"
    }
}
