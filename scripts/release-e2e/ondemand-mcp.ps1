Register-ReleaseE2EStageDefinition -Name "ondemand-mcp" -Version 2 -Paths @(
    "scripts/Build-ItlOnDemandMcp.ps1",
    "tools/itl-ondemand-mcp/**/*.go",
    "tools/itl-ondemand-mcp/go.mod",
    ".agents/skills/1c-workflow/assets/ondemand-mcp/**/*",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.ports.ps1",
    "templates/dependency-lock.json"
)
