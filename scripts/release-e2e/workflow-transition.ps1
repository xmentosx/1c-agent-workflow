function Test-E2ECompletedWorkflowTransition {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CurrentHead,
        [Parameter(Mandatory = $true)][string]$ExpectedHead,
        [Parameter(Mandatory = $true)][string]$WorkflowRoot
    )

    # Reuse the lifecycle owner's completed-transaction/lock/write-set proof.
    # An isolated module loads definitions only; no helper dispatch, operation
    # lease, environment import, branch mutation or 1C launch is performed.
    $owner = New-Module -ScriptBlock {
        param($PackageRoot, $TargetRoot)
        $script:ProjectRoot = [IO.Path]::GetFullPath($TargetRoot)
        $script:ConfigPath = Join-Path $script:ProjectRoot '.agent-1c/project.json'
        $script:Config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:DependencyLockPath = Join-Path $script:ProjectRoot '.agent-1c/dependency-lock.json'
        $script:Agent1cScriptRoot = Join-Path $PackageRoot '.agents/skills/1c-workflow/scripts'
        $script:Agent1cLibRoot = Join-Path $script:Agent1cScriptRoot 'lib'
        foreach ($library in @(Get-ChildItem -LiteralPath $script:Agent1cLibRoot -Filter 'agent-1c.*.ps1' -File | Sort-Object Name)) {
            . $library.FullName
        }
        Export-ModuleMember -Function @()
    } -ArgumentList $WorkflowRoot, $RepositoryRoot
    try {
        return & $owner {
            param($Head, $Anchor)
            if ((Get-CurrentCommit) -cne $Head -or $Head -ceq $Anchor) { return $false }
            try {
                Assert-DevBranchForkWorkflowTransition -OriginalCommit $Anchor
                return $true
            } catch {
                Write-Verbose ('Release workflow transition remains unproved: ' + $_.Exception.Message)
                return $false
            }
        } $CurrentHead $ExpectedHead
    } finally {
        Remove-Module -ModuleInfo $owner -ErrorAction SilentlyContinue
    }
}
