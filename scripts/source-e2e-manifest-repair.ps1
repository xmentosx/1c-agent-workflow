function Read-SourceE2ECompactSummary {
    param([object]$ProcessResult)
    $lines = @(Get-Content -LiteralPath $ProcessResult.stdout -Encoding UTF8 -ErrorAction Stop | Where-Object { $_.Trim().StartsWith('{') })
    if ($lines.Count -eq 0) { throw "Compact action did not write its JSON summary: $($ProcessResult.stdout)" }
    return ($lines[-1] | ConvertFrom-Json)
}
function Repair-SourceE2EManifestConflict {
    param([string]$Root, [string]$BranchName, [object]$ProcessResult, [ValidateSet('refresh-dev-branch','refresh-dev-branch-lite')][string]$Operation='refresh-dev-branch')

    # This is the documented agent repair for one E2E manifest conflict, not
    # another installed merge policy. All admission comes from the installed
    # transaction and verifier; unsupported semantics retain the failed step.
    $path = Join-Path $Root '.ai-rules.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $conflictHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $summary = Read-SourceE2ECompactSummary -ProcessResult $ProcessResult
    if ([int]$ProcessResult.exitCode -eq 0 -or [string]$summary.action -cne $Operation -or
        [string]$summary.status -cne 'failed' -or [string]$summary.errorCategory -cne 'merge-conflict' -or
        [string]$summary.requiredAction -cne 'agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit') { return $false }
    $unmerged = @(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @('diff','--name-only','--diff-filter=U','-z'))
    if ($unmerged.Count -ne 1 -or $unmerged[0] -cne '.ai-rules.json') { return $false }

    $contract = New-Module -ArgumentList $Root -ScriptBlock {
        param($InstalledRoot)
        $script:ProjectRoot = $InstalledRoot
        $lib = Join-Path $InstalledRoot '.agents/skills/1c-workflow/scripts/lib'
        foreach ($name in @('runtime-values','core','vanessa','lifecycle','ai-rules-migration')) {
            . (Join-Path $lib ("agent-1c.$name.ps1"))
        }
    }
    try {
        $transaction = & $contract {
            param($Name,$ExpectedOperation)
            $state = Read-DevBranchState -Name $Name
            $pending = Get-PendingDevBranchMergeTransaction -State $state
            if ($null -eq $pending -or $pending.operation -cne $ExpectedOperation -or
                $pending.stage -cne 'conflicts' -or $pending.branch -cne "itldev/$Name" -or
                @($pending.conflictPaths).Count -ne 1 -or $pending.conflictPaths[0] -cne '.ai-rules.json') { return $null }
            return $pending
        } $BranchName $Operation
        if ($null -eq $transaction) { return $false }
        $branchCommit = [string]$transaction.branchCommit
        $targetCommit = [string]$transaction.targetCommit
        if ($branchCommit -cnotmatch '^[a-f0-9]{40}$' -or $targetCommit -cnotmatch '^[a-f0-9]{40}$') { return $false }
        $currentHead = (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('rev-parse','HEAD')).stdout.Trim()
        $mergeHead = (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('rev-parse','MERGE_HEAD')).stdout.Trim()
        $currentBranch = (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('branch','--show-current')).stdout.Trim()
        if ($currentHead -cne $branchCommit -or $mergeHead -cne $targetCommit -or $currentBranch -cne $transaction.branch) { return $false }
        $indexBefore = @(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @('ls-files','--stage','-z'))
        $stages = @($indexBefore | Where-Object { $_ -match "^[0-7]+ [a-f0-9]{40} [123]`t\.ai-rules\.json$" })
        if ($stages.Count -ne 3) { return $false }
        $baseCommit = (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('merge-base',$branchCommit,$targetCommit)).stdout.Trim()
        foreach ($binding in @(@(1,$baseCommit),@(2,$branchCommit),@(3,$targetCommit))) {
            $blob = (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('rev-parse',($binding[1] + ':.ai-rules.json'))).stdout.Trim()
            if (@($stages | Where-Object { $_ -cmatch ("^100644 " + $blob + ' ' + $binding[0] + "`t\.ai-rules\.json$") }).Count -ne 1) { return $false }
        }
        $branchManifest = (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('show',($branchCommit + ':.ai-rules.json'))).stdout | ConvertFrom-Json
        $targetManifest = (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('show',($targetCommit + ':.ai-rules.json'))).stdout | ConvertFrom-Json
        $candidate = & $contract {
            param($Branch,$Target)
            $same = {
                param($Left,$Right)
                if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
                if ($Left -is [Collections.IDictionary] -or $Left -is [pscustomobject]) {
                    if ($Right -isnot [Collections.IDictionary] -and $Right -isnot [pscustomobject]) { return $false }
                    $a=ConvertTo-Agent1cHashtable $Left; $b=ConvertTo-Agent1cHashtable $Right
                    if ($a.Count -ne $b.Count) { return $false }
                    foreach ($key in $a.Keys) { if (-not $b.Contains($key) -or -not (& $same $a[$key] $b[$key])) { return $false } }
                    return $true
                }
                if ($Left -is [Collections.IEnumerable] -and $Left -isnot [string]) {
                    if ($Right -isnot [Collections.IEnumerable] -or $Right -is [string]) { return $false }
                    $a=@($Left); $b=@($Right)
                    if ($a.Count -ne $b.Count) { return $false }
                    for ($i=0;$i -lt $a.Count;$i++) { if (-not (& $same $a[$i] $b[$i])) { return $false } }
                    return $true
                }
                return [object]::Equals($Left,$Right)
            }
            $branchMap=ConvertTo-Agent1cHashtable $Branch; $targetMap=ConvertTo-Agent1cHashtable $Target
            if ([string]$branchMap['version'] -cne [string]$targetMap['version']) { return $null }
            foreach ($key in @($branchMap.Keys)+@($targetMap.Keys) | Select-Object -Unique) {
                if ($key -in @('version','updatedAt','files','foreignFiles','integrations')) { continue }
                if (-not $branchMap.Contains($key) -or -not $targetMap.Contains($key) -or
                    -not (& $same $branchMap[$key] $targetMap[$key])) { return $null }
            }
            $branchFiles=ConvertTo-Agent1cHashtable $branchMap['files']
            $targetFiles=ConvertTo-Agent1cHashtable $targetMap['files']
            foreach ($path in $branchFiles.Keys) { if (-not $targetFiles.Contains($path) -and $path -cne 'openspec/project.md') { return $null } }
            $branchIntegrations=ConvertTo-Agent1cHashtable $branchMap['integrations']
            $targetIntegrations=ConvertTo-Agent1cHashtable $targetMap['integrations']
            $branchOpenSpec=ConvertTo-Agent1cHashtable $branchIntegrations['openspec']
            $targetOpenSpec=ConvertTo-Agent1cHashtable $targetIntegrations['openspec']
            $branchGenerated=Get-ConfigValueFromObject -Object $Branch -Path 'integrations.openspec.projectMdGenerated' -Default $null
            $targetGenerated=Get-ConfigValueFromObject -Object $Target -Path 'integrations.openspec.projectMdGenerated' -Default $null
            if (-not (& $same $branchGenerated $targetGenerated) -and
                ($branchGenerated -isnot [bool] -or -not $branchGenerated -or
                 -not $branchFiles.Contains('openspec/project.md') -or $targetFiles.Contains('openspec/project.md'))) { return $null }
            [void]$branchOpenSpec.Remove('projectMdGenerated'); [void]$targetOpenSpec.Remove('projectMdGenerated')
            $branchIntegrations['openspec']=$branchOpenSpec; $targetIntegrations['openspec']=$targetOpenSpec
            if (-not (& $same $branchIntegrations $targetIntegrations)) { return $null }
            $result=ConvertTo-Agent1cHashtable $Target
            $result['files']=ConvertTo-Agent1cHashtable $result['files']
            $result['foreignFiles']=ConvertTo-Agent1cHashtable $result['foreignFiles']
            $branchForeign=ConvertTo-Agent1cHashtable $branchMap['foreignFiles']
            foreach ($client in $branchForeign.Keys) {
                if (-not $result['foreignFiles'].Contains($client)) { return $null }
                $union=New-Object 'Collections.Generic.List[string]'
                foreach ($path in @($result['foreignFiles'][$client])+@($branchForeign[$client])) { if ([string]$path -cnotin $union) { $union.Add([string]$path) } }
                $result['foreignFiles'][$client]=$union.ToArray()
            }
            if (-not $result['files'].Contains('openspec/project.md') -and $branchFiles.Contains('openspec/project.md')) {
                $result['files']['openspec/project.md']=$branchFiles['openspec/project.md']
                $result['integrations']=ConvertTo-Agent1cHashtable $result['integrations']
                $result['integrations']['openspec']=ConvertTo-Agent1cHashtable $result['integrations']['openspec']
                $result['integrations']['openspec']['projectMdGenerated']=Get-ConfigValueFromObject -Object $Branch -Path 'integrations.openspec.projectMdGenerated' -Default $false
            }
            if (-not (Test-AiRulesPendingMergeManifestProvenance -Root $script:ProjectRoot -Candidate $result -Branch $Branch -Target $Target)) { return $null }
            return ,$result
        } $branchManifest $targetManifest
        if ($null -eq $candidate) { return $false }
        $candidateText = ($candidate | ConvertTo-Json -Depth 100) + [Environment]::NewLine
        # Check the same transaction/index again immediately before its sole write.
        if ((Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('rev-parse','HEAD')).stdout.Trim() -cne $branchCommit -or
            (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('rev-parse','MERGE_HEAD')).stdout.Trim() -cne $targetCommit -or
            (@(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @('ls-files','--stage','-z')) -join [char]0) -cne ($indexBefore -join [char]0) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $conflictHash) { return $false }
        [IO.File]::WriteAllText($path,$candidateText,[Text.UTF8Encoding]::new($false))
        [void](Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('--literal-pathspecs','add','--','.ai-rules.json'))
        return $true
    } finally { Remove-Module $contract -ErrorAction SilentlyContinue }
}
