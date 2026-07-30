Register-ReleaseE2EStageDefinition -Name "seed-parallel" -Version 1 -Paths @(
    ".agents/skills/1c-workflow/scripts/agent-1c.ps1",
    ".agents/skills/1c-workflow/scripts/run-itl-command.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.seed.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1"
)
