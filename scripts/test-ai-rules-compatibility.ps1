[CmdletBinding()]
param(
    [string]$AiRulesSource = "https://github.com/xmentosx/itl_ai_rules_1c.git",
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
        $source = "content/openspec-bundle/$Tool/$relative"
        $matches = @($entries | Where-Object { $_.source -eq $source })
        if ($matches.Count -eq 0) {
            $missing += $source
            continue
        }
        if (@($matches | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ProjectRoot $_.target) -PathType Leaf) }).Count -gt 0) {
            $missing += $source
        }
    }

    if ($missing.Count -gt 0) {
        throw "OpenSpec bundle for $Tool is incomplete: $($missing -join ', ')"
    }
}

function Save-CodexPromptSnapshot {
    param(
        [string]$RulesRoot,
        [string]$SnapshotRoot
    )

    $commandsRoot = Join-Path $RulesRoot "content\commands"
    $promptsRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".codex\prompts"
    $records = @()
    if (-not (Test-Path -LiteralPath $commandsRoot -PathType Container)) {
        return $records
    }

    New-Item -ItemType Directory -Force -Path $SnapshotRoot | Out-Null
    foreach ($command in @(Get-ChildItem -LiteralPath $commandsRoot -File -Filter "*.md")) {
        $targetPath = Join-Path $promptsRoot $command.Name
        $snapshotPath = Join-Path $SnapshotRoot $command.Name
        $exists = Test-Path -LiteralPath $targetPath -PathType Leaf
        if ($exists) {
            Copy-Item -LiteralPath $targetPath -Destination $snapshotPath -Force
        }
        $records += [pscustomobject]@{
            targetPath = $targetPath
            snapshotPath = $snapshotPath
            existed = $exists
        }
    }
    return $records
}

function Restore-CodexPromptSnapshot {
    param([object[]]$Records)

    foreach ($record in @($Records)) {
        if ($record.existed) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $record.targetPath) | Out-Null
            Copy-Item -LiteralPath $record.snapshotPath -Destination $record.targetPath -Force
        } elseif (Test-Path -LiteralPath $record.targetPath -PathType Leaf) {
            Remove-Item -LiteralPath $record.targetPath -Force
        }
    }
}

$workRoot = if ($WorkingDirectory) {
    [System.IO.Path]::GetFullPath($WorkingDirectory)
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-compat-" + [guid]::NewGuid().ToString("N"))
}
$codexPromptSnapshot = @()

try {
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    $rulesRoot = ""
    if (Test-Path -LiteralPath $AiRulesSource -PathType Container) {
        $rulesRoot = (Resolve-Path -LiteralPath $AiRulesSource).Path
    } else {
        $rulesRoot = Join-Path $workRoot "ai_rules_1c"
        & git clone --depth 1 $AiRulesSource $rulesRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone ai_rules_1c from $AiRulesSource"
        }
    }

    $installScript = Join-Path $rulesRoot "install.ps1"
    if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
        throw "ai_rules_1c install.ps1 was not found: $installScript"
    }

    # The upstream Codex adapter writes command prompts to the user profile.
    # Preserve those files so this project-scoped compatibility check leaves no user-scope changes.
    $codexPromptSnapshot = @(Save-CodexPromptSnapshot -RulesRoot $rulesRoot -SnapshotRoot (Join-Path $workRoot "codex-prompts-snapshot"))

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
    foreach ($tool in @("codex", "kilocode")) {
        if (@($manifest.tools) -notcontains $tool) {
            throw "ai_rules_1c manifest does not list required tool: $tool"
        }
        Assert-OpenSpecBundle -RulesRoot $rulesRoot -ProjectRoot $projectRoot -Manifest $manifest -Tool $tool
    }

    Write-Host "ai_rules_1c compatibility passed for codex and kilocode."
} finally {
    if ($codexPromptSnapshot.Count -gt 0) {
        Restore-CodexPromptSnapshot -Records $codexPromptSnapshot
    }
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $workRoot -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($KeepArtifacts) {
        Write-Host "Compatibility artifacts retained: $workRoot"
    }
}
