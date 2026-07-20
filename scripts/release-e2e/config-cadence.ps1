Register-ReleaseE2EStageDefinition -Name "config-cadence" -Version 2 -Paths @(
    ".agents/skills/1c-workflow/scripts/agent-1c.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.verification-modes.ps1"
)
