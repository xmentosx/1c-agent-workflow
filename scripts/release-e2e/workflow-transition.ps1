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

function Test-E2EAdmissionManagedRefreshHead {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CurrentHead,
        [Parameter(Mandatory = $true)][string]$ExpectedHead,
        [Parameter(Mandatory = $true)][string]$MasterHead,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExportPath,
        [string]$WorkflowRoot = ''
    )
    $currentRecord = (Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-list', '--parents', '-n', '1', $CurrentHead)).stdout.Trim()
    $currentParts = @($currentRecord -split '\s+' | Where-Object { $_ })
    if ($currentParts.Count -eq 3 -and $currentParts[1] -eq $ExpectedHead -and $currentParts[2] -eq $MasterHead) { return $true }
    if ($currentParts.Count -ne 2) { return $false }
    try {
        if ($WorkflowRoot -and (Test-E2ECompletedWorkflowTransition -RepositoryRoot $RepositoryRoot -CurrentHead $CurrentHead -ExpectedHead $ExpectedHead -WorkflowRoot $WorkflowRoot)) { return $true }
    } catch { Write-Verbose ('Release workflow transition remains unproved: ' + $_.Exception.Message) }
    $mergeHead = [string]$currentParts[1]
    $mergeRecord = (Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-list', '--parents', '-n', '1', $mergeHead)).stdout.Trim()
    $mergeParts = @($mergeRecord -split '\s+' | Where-Object { $_ })
    if ($mergeParts.Count -ne 3 -or $mergeParts[1] -ne $ExpectedHead -or $mergeParts[2] -ne $MasterHead) { return $false }
    $subject = (Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('show', '-s', '--format=%s', $CurrentHead)).stdout.Trim()
    $cursorPath = (($ExportPath -replace '\\', '/').Trim('/')) + '/ConfigDumpInfo.xml'
    $changedPaths = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', $CurrentHead, '--') | ForEach-Object { ([string]$_ -replace '\\', '/') })
    if ($changedPaths.Count -eq 0) { return $false }
    if ($subject -ceq 'chore: persist branch configuration synchronization cursor') { return $changedPaths.Count -eq 1 -and $changedPaths[0] -ceq $cursorPath }
    if ($subject -ceq 'chore: persist branch refresh state') {
        $allowedPaths = @($cursorPath, '.kilo/kilo.json')
        return $changedPaths -ccontains '.kilo/kilo.json' -and @($changedPaths | Where-Object { $allowedPaths -cnotcontains $_ }).Count -eq 0
    }
    return $false
}
