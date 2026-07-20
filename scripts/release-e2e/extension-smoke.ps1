Register-ReleaseE2EStageDefinition -Name "extension-smoke" -Version 2 -DependsOn @("config-cadence") -Paths @(
    ".agents/skills/1c-workflow/scripts/agent-1c.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1"
)
