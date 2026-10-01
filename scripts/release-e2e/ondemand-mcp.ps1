Register-ReleaseE2EStageDefinition -Name "ondemand-mcp" -Version 5 -Paths @(
    "scripts/Build-ItlOnDemandMcp.ps1",
    "tools/itl-ondemand-mcp/**/*.go",
    "tools/itl-ondemand-mcp/go.mod",
    ".agents/skills/1c-workflow/assets/ondemand-mcp/**/*",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1",
    ".agents/skills/1c-workflow/scripts/agent-1c.ps1",
    ".agents/skills/1c-workflow/scripts/lib/*.ps1",
    "scripts/vanessa-build-runtime.ps1",
    "scripts/git-path-list.ps1",
    ".agents/skills/itl-remote-runner/scripts/ExecutionGuard.ps1",
    ".agents/skills/itl-remote-runner/scripts/PythonRuntime.ps1",
    ".agents/skills/itl-remote-runner/scripts/itl_remote/__init__.py",
    ".agents/skills/itl-remote-runner/scripts/itl_remote/execution_guard.py",
    ".agents/skills/itl-remote-runner/scripts/itl_remote/execution_guard_host.py",
    ".agents/skills/itl-remote-runner/scripts/itl_remote/common.py",
    "scripts/build-client-mcp-patched.ps1",
    "scripts/client-mcp-build.ps1",
    "third-party/client-mcp/**/*",
    ".agents/skills/1c-workflow/scripts/lib/agent-1c.ports.ps1",
    "templates/dependency-lock.json"
)

function Get-ReleaseClientMcpArtifactEvidence {
    param([string]$Root, [string]$BranchName, [object]$Lock)
    & {
        param($Root, $BranchName, $Lock)
        . (Join-Path $Root '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ProjectRoot $Root -Action help *> $null
        $state = Read-DevBranchState -Name $BranchName
        if (-not (Test-VanessaMcpSafeModeProofMatchesState -State $state)) { throw 'Release clientMcp installation/runtime ownership proof is incomplete.' }
        $proof = $state.vanessaMcpSafeModeProof
        $installedSha = [string]$state.vanessaMcpClientMcpSha256
        if ($installedSha -cne [string]$Lock.sha256 -or [string]$proof.clientMcp.artifactSha256 -cne [string]$Lock.sha256 -or
            [string]$state.vanessaMcpClientMcpVersion -cne [string]$Lock.version) {
            throw 'Release Vanessa live smoke did not use the exact workflow-pinned clientMcp CFE.'
        }
        [pscustomobject]@{ sha256=$installedSha; version=[string]$Lock.version; serviceInfoBasePath=[string]$state.vanessaServiceInfoBasePath; proof=$proof.clientMcp; runtimeHash=[string]$proof.clientRuntimeHash }
    } $Root $BranchName $Lock
}
