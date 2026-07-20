Register-ReleaseE2EStageDefinition -Name "verification-refresh" -Version 2 -ModuleFile "result-cleanup.ps1" -DependsOn @("config-cadence") -Paths @(
    ".agents/skills/1c-workflow/scripts/agent-1c.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.verification-modes.ps1"
)

Register-ReleaseE2EStageDefinition -Name "result-cleanup" -Version 2 -DependsOn @("config-cadence") -Paths @(
    ".agents/skills/1c-workflow/scripts/agent-1c.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.verification-modes.ps1"
)
