Register-ReleaseE2EStageDefinition -Name "extension-smoke" -Version 3 -DependsOn @("config-cadence") -Paths @(
    "scripts/release-e2e/extension-recovery.ps1",
    "scripts/release-e2e/extension-recovery-owner.ps1",
    "scripts/source-delivery-process.ps1",
    ".agents/skills/1c-workflow/scripts/agent-1c.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1"
)
