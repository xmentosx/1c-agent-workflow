Register-ReleaseE2EStageDefinition -Name "seed-parallel" -Version 3 -Paths @(
    ".agents/skills/1c-workflow/scripts/agent-1c.ps1",
    ".agents/skills/1c-workflow/scripts/run-itl-command.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.seed.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1"
)

function New-E2ERepositoryLockProbeCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    $moduleRoot = Join-Path $Root "src\cf\CommonModules"
    $module = @(
        Get-ChildItem -LiteralPath $moduleRoot -Recurse -File -Filter "Module.bsl" -ErrorAction Stop |
            Sort-Object { $_.FullName.Substring($Root.TrimEnd('\', '/').Length).Replace('\', '/') }
    ) | Select-Object -First 1
    if ($null -eq $module) {
        throw "Release repository lock probe requires at least one existing CommonModules/*/Ext/Module.bsl object."
    }

    $repoPath = $module.FullName.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
    if ($repoPath -notmatch '^src/cf/CommonModules/[^/]+/Ext/Module\.bsl$') {
        throw "Release repository lock probe selected an unmapped common-module path: $repoPath"
    }
    $bytes = [IO.File]::ReadAllBytes($module.FullName)
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $encoding = [Text.UTF8Encoding]::new($hasUtf8Bom)
    $offset = if ($hasUtf8Bom) { 3 } else { 0 }
    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $prefix = if ($text.EndsWith("`r") -or $text.EndsWith("`n")) { "" } else { $newLine }
    $probeBytes = $encoding.GetBytes($prefix + "// ITL release repository lock $Suffix" + $newLine)
    $stream = [IO.File]::Open($module.FullName, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($probeBytes, 0, $probeBytes.Length) } finally { $stream.Dispose() }

    $changedPaths = @(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @("diff", "--name-only", "-z", "--"))
    if ($changedPaths.Count -ne 1 -or [string]$changedPaths[0] -cne $repoPath) {
        throw "Release repository lock probe must change exactly one mapped common module; changed: $($changedPaths -join ', ')"
    }
    & git -C $Root add -- $repoPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to stage the release repository lock probe: $repoPath" }
    & git -C $Root commit -m "test: change mapped object for repository lock probe" *> $null
    if ($LASTEXITCODE -ne 0) { throw "Unable to commit the release repository lock probe: $repoPath" }
    if (@(& git -C $Root status --porcelain --untracked-files=no).Count -ne 0) {
        throw "Release repository lock probe branch is not clean after committing: $repoPath"
    }
    return $repoPath
}
