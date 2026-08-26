Register-ReleaseE2EStageDefinition -Name "server-reset" -Version 1 -Paths @(
    ".agents/skills/1c-workflow/scripts/agent-1c.ps1",
    ".agents/skills/1c-workflow/scripts/run-itl-command.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1"
)

function Get-ReleaseE2EServerResetDisposition {
    param(
        [string]$ServerProjectRoot,
        [string]$ServerWorktreePath,
        [string]$ServerDevBranchName,
        [switch]$TestFixture
    )

    if ($TestFixture) {
        return [ordered]@{ status = "test-fixture"; configured = $false; reason = "test-only server reset fixture" }
    }
    $values = @($ServerProjectRoot, $ServerWorktreePath, $ServerDevBranchName)
    $presentCount = @($values | Where-Object { [string]$_ }).Count
    if ($presentCount -eq 0) {
        return [ordered]@{ status = "unverified"; configured = $false; reason = "server stand is not configured" }
    }
    if ($presentCount -ne $values.Count) {
        return [ordered]@{ status = "invalid"; configured = $false; reason = "server stand configuration is partial" }
    }
    return [ordered]@{ status = "configured"; configured = $true; reason = "server stand is configured" }
}
