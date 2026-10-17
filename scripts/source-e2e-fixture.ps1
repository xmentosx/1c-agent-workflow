[CmdletBinding()]
param(
    [ValidateSet('','Capture','Prepare','DisposeCopy')][string]$Action='',
    [string]$ProjectRoot='',
    [ValidateSet('Develop','Release')][string]$Phase='Develop',
    [string]$CandidateRoot='',
    [string]$AiRulesSource='',
    [string]$FreshProjectsRoot='C:\itlj',
    [string]$AgentTarget='',
    [switch]$Recapture,
    [switch]$AcknowledgeWorkflowUpdate,
    [string]$OutputPath='',
    [string]$FixtureReceiptPath='',
    [string]$TerminalReportPath='',
    [string]$DiagnosticRoot=''
)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'git-path-list.ps1')
. (Join-Path $PSScriptRoot 'source-e2e-manifest-repair.ps1')
. (Join-Path $PSScriptRoot 'source-proof-json.ps1')
. (Join-Path $PSScriptRoot 'source-delivery-process.ps1')
. (Join-Path $PSScriptRoot 'stand-env-identity.ps1')
$fixtureLib = Join-Path (Split-Path -Parent $PSScriptRoot) '.agents/skills/1c-workflow/scripts/lib'
. (Join-Path $fixtureLib 'agent-1c.core.ps1')
. (Join-Path $fixtureLib 'agent-1c.lifecycle.ps1')
. (Join-Path $fixtureLib 'agent-1c.vanessa.ps1')
. (Join-Path $fixtureLib 'agent-1c.ai-rules-migration.ps1')
. (Join-Path $PSScriptRoot 'lifecycle-qualification-fixture.ps1')
. (Join-Path $PSScriptRoot 'source-e2e-storage.ps1')

function Invoke-SourceFixtureInstalledAction {
    param([string]$Root, [string]$Action, [string[]]$Arguments=@(), [string]$AgentTarget='', [string]$LogRoot, [int]$TimeoutSeconds=7200, [switch]$AllowFailure)
    # Keep the factory's public call stable across published/frozen candidates.
    # The guarded continuation owns only its exact existing refresh invocation;
    # its AllowFailure children go directly to the one native process owner.
    if(-not $AllowFailure -and $TimeoutSeconds -eq 5400 -and
        $Action -in @('refresh-dev-branch','refresh-dev-branch-lite') -and
        $Arguments.Count -eq 4 -and $Arguments[0] -ceq '-DevBranchName' -and
        $Arguments[2] -ceq '-ExpectedMasterCommit' -and $Arguments[1] -and
        $Arguments[3] -cmatch '^[a-f0-9]{40}$'){
        return Invoke-SourceFixtureRefresh -Root $Root -BranchName $Arguments[1] -ExpectedMasterCommit $Arguments[3] -Action $Action -AgentTarget $AgentTarget -LogRoot $LogRoot
    }
    return Invoke-SourceFixtureInstalledProcess -Root $Root -Action $Action -Arguments $Arguments -AgentTarget $AgentTarget -LogRoot $LogRoot -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure
}

function Invoke-SourceFixtureInstalledProcess {
    param([string]$Root, [string]$Action, [string[]]$Arguments=@(), [string]$AgentTarget='', [string]$LogRoot, [int]$TimeoutSeconds=7200, [switch]$AllowFailure)
    [void][IO.Directory]::CreateDirectory($LogRoot)
    $token = $Action+'-'+[guid]::NewGuid().ToString('N')
    $stdout = Join-Path $LogRoot ($token+'.stdout.log'); $stderr = Join-Path $LogRoot ($token+'.stderr.log')
    $client = Resolve-SourceE2EAgentTarget -ProjectRoot $Root -AgentTarget $AgentTarget
    $internalAction = $Action -in @('release-e2e-snapshot','release-e2e-restore')
    $createFixtureBase = $Action -eq 'qualification-create-infobase'
    $runner = if($createFixtureBase){Join-Path $PSScriptRoot 'source-e2e-create-infobase.ps1'}else{Join-Path $Root $(if($internalAction){'.agents/skills/1c-workflow/scripts/agent-1c.ps1'}else{'.agents/skills/1c-workflow/scripts/run-itl-command.ps1'})}
    $entryArguments = if($internalAction -or $createFixtureBase){@('-ProjectRoot',$Root)}else{@('--')}
    $actionArguments = if($createFixtureBase){@()}else{@('-Action',$Action,'-AgentTarget',$client)}
    $argv = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runner)+$entryArguments+$actionArguments+$Arguments
    $line = (@($argv|ForEach-Object { ConvertTo-GitProcessArgument -Value $_ }) -join ' ')
    $job = Start-DeliveryProcess -ArgumentList $line -WorkingDirectory $Root -StandardOutputPath $stdout -StandardErrorPath $stderr
    $process = $job.process; $errorText=''; $watch=[Diagnostics.Stopwatch]::StartNew()
    $lastLength=-1L; $lastProgress=[DateTime]::UtcNow; $lastNotice=[DateTime]::UtcNow
    try {
        while (-not $process.WaitForExit(1000)) {
            $length=0L; foreach($path in @($stdout,$stderr)){if(Test-Path -LiteralPath $path){$length+=(Get-Item -LiteralPath $path).Length}}
            if($length -ne $lastLength){$lastLength=$length;$lastProgress=[DateTime]::UtcNow}
            if(([DateTime]::UtcNow-$lastNotice).TotalSeconds -ge 30){
                Assert-SourceE2ENativeDisk -Process $process -LogPaths @($stdout,$stderr) -EvidencePath (Join-Path $LogRoot ($token+'.disk-full.json')) -VolumePaths @($Root,[IO.Path]::GetTempPath()) -InspectWindows
            }
            if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds -or ([DateTime]::UtcNow-$lastProgress).TotalMinutes -ge 15){throw "FIXTURE_ACTION_TIMEOUT: $Action; retained logs=$LogRoot; repeat the same qualification after diagnosis"}
            if(([DateTime]::UtcNow-$lastNotice).TotalSeconds -ge 30){Write-Host "Fixture ${Action}: $([int]$watch.Elapsed.TotalSeconds)s; logs=$LogRoot";$lastNotice=[DateTime]::UtcNow}
        }
        $process.WaitForExit();$process.Refresh()
        Assert-SourceE2ENativeDisk -Process $process -LogPaths @($stdout,$stderr) -EvidencePath (Join-Path $LogRoot ($token+'.disk-full.json')) -VolumePaths @($Root,[IO.Path]::GetTempPath())
        if([int]$process.ExitCode -ne 0 -and -not $AllowFailure){throw "FIXTURE_ACTION_FAILED: $Action exit=$($process.ExitCode); see $stdout and $stderr; repeat the same qualification after diagnosis"}
        return [pscustomobject]@{exitCode=[int]$process.ExitCode;stdout=$stdout;stderr=$stderr;durationMs=[int64]$watch.ElapsedMilliseconds}
    } catch {$errorText=$_.Exception.Message;throw}
    finally {
        try { Close-DeliveryProcessJob -JobHandle $job.jobHandle -Process $process -PriorErrorMessage $errorText }
        finally { $process.Dispose(); $watch.Stop() }
    }
}

function Invoke-SourceFixtureRefresh {
    param([string]$Root, [string]$BranchName, [string]$ExpectedMasterCommit, [string]$AgentTarget, [string]$LogRoot,
        [ValidateSet('refresh-dev-branch','refresh-dev-branch-lite')][string]$Action='refresh-dev-branch')
    $arguments=@('-DevBranchName',$BranchName,'-ExpectedMasterCommit',$ExpectedMasterCommit)
    $result=Invoke-SourceFixtureInstalledAction -Root $Root -Action $Action -Arguments $arguments -AgentTarget $AgentTarget -LogRoot $LogRoot -TimeoutSeconds 5400 -AllowFailure
    $summary=Read-SourceE2ECompactSummary -ProcessResult $result
    if([int]$result.exitCode -eq 0 -and [string]$summary.action -ceq $Action -and [string]$summary.status -ceq 'succeeded'){return $result}
    $repaired=Repair-SourceE2EManifestConflict -Root $Root -BranchName $BranchName -ProcessResult $result -Operation $Action
    if($repaired){
        $retry=Invoke-SourceFixtureInstalledAction -Root $Root -Action $Action -Arguments $arguments -AgentTarget $AgentTarget -LogRoot $LogRoot -TimeoutSeconds 5400 -AllowFailure
        $retrySummary=Read-SourceE2ECompactSummary -ProcessResult $retry
        if([int]$retry.exitCode -eq 0 -and [string]$retrySummary.action -ceq $Action -and [string]$retrySummary.status -ceq 'succeeded'){return $retry}
        throw "FIXTURE_ACTION_FAILED: $Action continuation exit=$($retry.exitCode); see $($retry.stdout) and $($retry.stderr); original failure retained at $($result.stdout)"
    }
    throw "FIXTURE_ACTION_FAILED: $Action exit=$($result.exitCode); see $($result.stdout) and $($result.stderr); semantic repair refused"
}

function Assert-SourceFixtureGitClean {
    param([string]$Root)
    if(@(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @('status','--porcelain=v1','--untracked-files=all','-z')).Count){throw "FIXTURE_SEED_DIRTY: preserve changes at $Root and repeat qualification after their owning task finishes"}
}

function Get-SourceFixtureSemanticState {
    param([object]$State)
    $result=[ordered]@{}
    foreach($p in @($State.PSObject.Properties|Sort-Object Name)){
        if($p.Name -match '^(pendingMerge|pendingRefresh|lifecycleMerge|eventLogPendingCursor|lastConfigDesigner|lastExtensionDesigner|sourceFingerprint|lastConfigBaseUpdatedCommit|enterpriseNormalization|lastEnterpriseAutoUpdateResultPath|eventLogBaseline|branchSeedBaseline)'){$result[$p.Name]=$p.Value}
    }
    return ConvertTo-DeliveryProofJson -InputObject $result -Depth 32 -Compress
}

function Get-SourceFixtureContextFiles {
    param([object]$State, [string]$ProjectRoot, [string]$BranchRoot)
    $records=New-Object Collections.Generic.List[object]
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $registered=@(Get-RepositoryGitPathList -RepositoryRoot $ProjectRoot -Arguments @('worktree','list','--porcelain','-z')|Where-Object {$_ -like 'worktree *'}|ForEach-Object {[IO.Path]::GetFullPath($_.Substring(9)).TrimEnd('\','/')})
    foreach($property in $State.PSObject.Properties){
        if($property.Name -notmatch '^(eventLog.*Path|branchSeedBaselinePath|lastEnterpriseAutoUpdateResultPath)$|^(pendingMerge|pendingRefresh).*Path$'){continue}
        $path=[string]$property.Value
        if(-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)){continue}
        $full=[IO.Path]::GetFullPath($path);$role='';$relative=''
        foreach($pair in @(@{role='branch';root=$BranchRoot},@{role='master';root=$ProjectRoot})){
            $prefix=$pair.root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$role=$pair.role;$relative=$full.Substring($prefix.Length).Replace('\','/');break}
        }
        $sha=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        if(-not $role -and $property.Name -ceq 'lastEnterpriseAutoUpdateResultPath'){
            foreach($root in $registered){
                $prefix=$root+[IO.Path]::DirectorySeparatorChar
                if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){continue}
                $receiptRelative=$full.Substring($prefix.Length).Replace('\','/')
                if($receiptRelative -cnotmatch '^\.agent-1c/runs/auto-update/[^/]+\.result\.json$'){continue}
                $null=Resolve-QualificationFixtureChild -Root $root -RelativePath $receiptRelative
                $role='branch';$relative='.agent-1c/runs/qualification-context/'+$sha+'.json';break
            }
        }
        if(-not $role){throw "FIXTURE_CONTEXT_OUTSIDE_SEED: $($property.Name); retain the seed and receipt; use its lifecycle owner to establish a registered context before capture"}
        $null=Resolve-QualificationFixtureChild -Root $(if($role -eq 'master'){$ProjectRoot}else{$BranchRoot}) -RelativePath $relative
        if($seen.Add($full)){$records.Add([pscustomobject]@{role=$role;relativePath=$relative;artifact=('context/'+$role+'/'+$relative);sourcePath=$full;sourceSha256=$sha})}
    }
    return $records.ToArray()
}

function Export-SourceE2EFixtureCapsule {
    param([string]$ProjectRoot, [ValidateSet('Develop','Release')][string]$Phase, [string]$AgentTarget='')
    $root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
    $configPath=Join-Path $root '.agent-1c/release-e2e.json'
    $config=Read-QualificationFixtureJson -Path $configPath
    $name=if($Phase -eq 'Develop'){[string]$config.developDevBranchName}else{[string]$config.devBranchName}
    $branch=if($Phase -eq 'Develop'){[IO.Path]::GetFullPath([string]$config.developWorktreePath)}else{[IO.Path]::GetFullPath([string]$config.worktreePath)}
    Assert-SourceFixtureGitClean -Root $root; Assert-SourceFixtureGitClean -Root $branch
    if((Get-RepositoryCommonGitDirectory -RepositoryRoot $root) -ine (Get-RepositoryCommonGitDirectory -RepositoryRoot $branch)){throw 'FIXTURE_SEED_NOT_REGISTERED'}
    if((Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('branch','--show-current')).stdout.Trim() -cne 'master' -or
        (Invoke-RepositoryGit -RepositoryRoot $branch -Arguments @('branch','--show-current')).stdout.Trim() -cne ('itldev/'+$name)){throw 'FIXTURE_SEED_BRANCH_MISMATCH'}
    $statePath=Join-Path $branch ('.agent-1c/dev-branches/'+$name+'.json')
    $before=Read-QualificationFixtureJson -Path $statePath
    if([string]$before.infoBaseKind -cne 'file'){throw 'FIXTURE_SEED_FILE_REQUIRED: server qualification retains its separate declared stand and unverified evidence contract'}
    $semanticBefore=Get-SourceFixtureSemanticState -State $before
    # Resolve every declared context before the expensive database snapshot.
    # A historical normalization receipt may live in another registered worktree;
    # import only that exact SHA-bound leaf, never its worktree/state or database.
    $context=@(Get-SourceFixtureContextFiles -State $before -ProjectRoot $root -BranchRoot $branch)
    $requiredCommits=@($before.PSObject.Properties|Where-Object {$_.Name -match '^(pendingMerge|pendingRefresh|lifecycleMerge).*(Commit|Head)$' -and [string]$_.Value -cmatch '^[a-f0-9]{40}$'}|ForEach-Object {[string]$_.Value}|Sort-Object -Unique)
    foreach($required in $requiredCommits){
        if((Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('cat-file','-t',$required)).stdout.Trim() -cne 'commit'){throw 'FIXTURE_PENDING_COMMIT_INVALID'}
    }
    $masterCommit=(Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('rev-parse','HEAD')).stdout.Trim()
    $branchCommit=(Invoke-RepositoryGit -RepositoryRoot $branch -Arguments @('rev-parse','HEAD')).stdout.Trim()
    $lock=Read-QualificationFixtureJson -Path (Join-Path $root '.agent-1c/dependency-lock.json')
    $branchLock=Read-QualificationFixtureJson -Path (Join-Path $branch '.agent-1c/dependency-lock.json')
    $workflow=[string]$lock.dependencies.workflowPackage.commit
    if($workflow -cne [string]$branchLock.dependencies.workflowPackage.commit){throw 'FIXTURE_UPGRADE_BASELINE_VERSION_MISMATCH: seed master and branch must declare the same published baseline'}
    $workflowRepository=Split-Path -Parent $PSScriptRoot
    if($workflow -cnotmatch '^[a-f0-9]{40}$' -or (Invoke-RepositoryGit -RepositoryRoot $workflowRepository -Arguments @('merge-base','--is-ancestor',$workflow,'refs/remotes/origin/develop') -AllowFailure).exitCode -ne 0){throw 'FIXTURE_BASELINE_NOT_PUBLISHED: capture from a published workflow baseline before qualification'}
    $id=[guid]::NewGuid().ToString('N')
    $capsule=Resolve-QualificationFixtureChild -Root (Get-RepositoryCommonGitDirectory -RepositoryRoot $root) -RelativePath ('itl/qualification-fixtures/'+$Phase.ToLowerInvariant()+'-'+$id)
    [void][IO.Directory]::CreateDirectory($capsule)
    $snapshotRelative='.agent-1c/snapshots/qualification-fixtures/'+$id+'/infobase.dt'
    $snapshot=Resolve-QualificationFixtureChild -Root $branch -RelativePath $snapshotRelative
    Write-Host "Capturing $Phase fixture once: $capsule"
    $snapshotRun=Invoke-SourceFixtureInstalledAction -Root $branch -Action 'release-e2e-snapshot' -Arguments @('-DevBranchName',$name,'-ReleaseSnapshotPath',$snapshotRelative) -AgentTarget $AgentTarget -LogRoot (Join-Path $capsule 'logs')
    $after=Read-QualificationFixtureJson -Path $statePath
    if((Get-SourceFixtureSemanticState -State $after) -cne $semanticBefore){throw 'FIXTURE_SNAPSHOT_STATE_MOVED: keep the snapshot and repeat capture from a stable seed'}
    Copy-Item -LiteralPath $snapshot -Destination (Join-Path $capsule 'infobase.dt')
    Copy-Item -LiteralPath $statePath -Destination (Join-Path $capsule 'state.json')
    Copy-Item -LiteralPath (Join-Path $root '.dev.env') -Destination (Join-Path $capsule 'master.env')
    Copy-Item -LiteralPath (Join-Path $branch '.dev.env') -Destination (Join-Path $capsule 'branch.env')
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $capsule 'release-e2e.json')
    Invoke-RepositoryGit -RepositoryRoot $root -Arguments (@('bundle','create',(Join-Path $capsule 'source.bundle'),'refs/heads/master',('refs/heads/itldev/'+$name))+$requiredCommits)|Out-Null
    if((Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('rev-parse','HEAD')).stdout.Trim() -cne $masterCommit -or
        (Invoke-RepositoryGit -RepositoryRoot $branch -Arguments @('rev-parse','HEAD')).stdout.Trim() -cne $branchCommit){throw 'FIXTURE_GIT_MOVED_DURING_CAPTURE'}
    Assert-SourceFixtureGitClean -Root $root;Assert-SourceFixtureGitClean -Root $branch
    foreach($reference in $context){
        $destination=Resolve-QualificationFixtureChild -Root $capsule -RelativePath $reference.artifact
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $reference.sourcePath -Destination $destination
        if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $reference.sourceSha256){throw 'FIXTURE_CONTEXT_MOVED_DURING_CAPTURE: retain the capsule and repeat capture from a stable seed'}
    }
    $files=@(Get-ChildItem -LiteralPath $capsule -Recurse -File|Where-Object {$_.FullName -notlike (Join-Path $capsule 'logs/*')}|ForEach-Object{[ordered]@{path=$_.FullName.Substring($capsule.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
    $databasePath=Join-Path ([string]$after.devBranchInfoBasePath) '1Cv8.1CD'
    $databaseSha=(Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest=[ordered]@{schemaVersion=1;kind='itl-qualification-fixture';status='sealed';phase=$Phase;infoBaseKind='file';sourceProjectRoot=$root;sourceBranchRoot=$branch;branchName=$name;masterCommit=$masterCommit;branchCommit=$branchCommit;requiredCommits=$requiredCommits;workflowCommit=$workflow;semanticState=$semanticBefore;sourceDatabase=[ordered]@{path=$databasePath;sha256=$databaseSha};files=$files;contextFiles=$context;snapshotDurationMs=$snapshotRun.durationMs;createdAt=[DateTime]::UtcNow.ToString('o')}
    $manifestPath=Join-Path $capsule 'capsule.json'
    Write-QualificationFixtureJson -Path $manifestPath -Value $manifest
    $sha=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $null=Read-QualificationFixtureCapsule -ManifestPath $manifestPath -Sha256 $sha
    return [pscustomobject]@{path=$manifestPath;sha256=$sha;workflowCommit=$workflow;phase=$Phase}
}

function Get-SourceFixtureWorkflowUpdateProof {
    param([string]$Root,[string]$OriginalCommit,[string]$OriginalEnvPath,[string]$ExpectedBranchRef)
    $previousRoot=Get-Variable -Name ProjectRoot -Scope Script -ErrorAction SilentlyContinue
    $hadRoot=$null -ne $previousRoot;$previousRootValue=if($hadRoot){$previousRoot.Value}else{$null}
    try {
        $script:ProjectRoot=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
        Assert-SourceFixtureGitClean -Root $Root
        $head=(Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('rev-parse','HEAD')).stdout.Trim()
        $branchRef=(Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('symbolic-ref','--quiet','HEAD')).stdout.Trim()
        if($branchRef -cne $ExpectedBranchRef){throw 'FIXTURE_SEED_BRANCH_MISMATCH'}
        $saved=@();$parent=Join-Path $Root '.agent-1c/snapshots/workflow-update'
        if(Test-Path -LiteralPath $parent){
            $saved=@(foreach($directory in @(Get-ChildItem -LiteralPath $parent -Directory -Filter 'itl-workflow-update-completed-*')){
                try{$projection=Read-QualificationFixtureJson -Path (Join-Path $directory.FullName 'transaction.json')}catch{continue}
                [pscustomobject]@{id=$directory.Name.Substring('itl-workflow-update-completed-'.Length);receipt=$projection}
            })
        }
        $cursor=$head;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $expected=@{};$proof=New-Object Collections.Generic.List[object];$originalEnv=Join-Path $Root '.dev.env'
        while($cursor -cne $OriginalCommit){
            if(-not $seen.Add($cursor)){throw 'FIXTURE_WORKFLOW_UPDATE_CHAIN_INVALID: cyclic history'}
            $selected=@($saved|Where-Object {[string]$_.receipt.completedHead -ceq $cursor -and [string]$_.receipt.preUpdateHead -cne $cursor})
            if($selected.Count -ne 1){throw 'FIXTURE_WORKFLOW_UPDATE_CHAIN_UNPROVEN: expected one terminal update for every Git hop; retain the capsule and reconcile through update-workflow'}
            # The update owner validates identity, terminal phase and every backup byte.
            $completed=Get-WorkflowUpdateCompletedSnapshot -SnapshotId $selected[0].id
            $receipt=$completed.receipt;$before=ConvertTo-Agent1cHashtable -Object $receipt.beforePathState
            $after=ConvertTo-Agent1cHashtable -Object $receipt.pathState
            $old=[string]$receipt.preUpdateHead
            $parents=(Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('rev-list','--parents','-n','1',$cursor)).stdout.Trim()
            if($old -cnotmatch '^[a-f0-9]{40}$' -or [string]$receipt.branchRef -cne $branchRef -or $parents -cne ($cursor+' '+$old)){
                throw 'FIXTURE_WORKFLOW_UPDATE_CHAIN_INVALID: branch or exact single-parent transition mismatch'
            }
            $oldOwned=@(Get-WorkflowUpdateManagedPathSpecs -AtCommit $old)
            $owned=$oldOwned+@(Get-WorkflowUpdateManagedPathSpecs -AtCommit $cursor)+@(Get-AiRulesOpenSpecScaffoldPaths)
            $matcher=New-WorkflowUpdatePathMatcher -ManagedPathSpecs $owned
            $oldMatcher=New-WorkflowUpdatePathMatcher -ManagedPathSpecs $oldOwned
            $static=New-WorkflowUpdatePathMatcher -ManagedPathSpecs @(Get-WorkflowUpdateManagedPathSpecs -StaticOnly)
            $changedPaths=@(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @('diff','--name-only','-z',$old,$cursor))
            $existing=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if($changedPaths.Count){foreach($path in @(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments (@('ls-tree','-r','--name-only','-z',$old,'--')+@($changedPaths|ForEach-Object {':(literal)'+$_})))){[void]$existing.Add($path)}}
            foreach($path in $changedPaths){
                if($path -cmatch '^src/' -or ($path -cmatch '^tests/' -and -not (Test-WorkflowUpdatePathAllowed -Path $path -Matcher $static)) -or
                    ($existing.Contains($path) -and -not (Test-WorkflowUpdatePathAllowed -Path $path -Matcher $oldMatcher)) -or
                    -not (Test-WorkflowUpdatePathAllowed -Path $path -Matcher $matcher)){
                    throw "FIXTURE_WORKFLOW_UPDATE_BUSINESS_CHANGE: '$path' is outside the workflow transition"
                }
            }
            if($before.Count -ne $after.Count -or $after.Count -ne @($completed.snapshot.records).Count){throw 'FIXTURE_WORKFLOW_UPDATE_INVENTORY_INVALID'}
            foreach($record in @($completed.snapshot.records)){
                $path=[string]$record.relativePath
                if(-not $before.Contains($path) -or -not $after.Contains($path)){throw 'FIXTURE_WORKFLOW_UPDATE_INVENTORY_INVALID'}
                if(-not $expected.ContainsKey($path)){$expected[$path]=Get-WorkflowUpdatePathState -RelativePath $path}
                if([string]$expected[$path] -cne [string]$after[$path]){throw "FIXTURE_WORKFLOW_UPDATE_PATH_CHANGED: '$path'; retain the capsule and reconcile through update-workflow"}
                $expected[$path]=[string]$before[$path]
            }
            $envRecord=@($completed.snapshot.records|Where-Object relativePath -CEQ '.dev.env')
            if($envRecord.Count -ne 1 -or -not $envRecord[0].existed){throw 'FIXTURE_WORKFLOW_UPDATE_ENV_UNPROVEN'}
            $originalEnv=[string]$envRecord[0].backupPath
            $proof.Add([ordered]@{id=$selected[0].id;sha256=(Get-FileHash -LiteralPath $completed.receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()})
            $cursor=$old
        }
        if((Get-DeliveryStableDotEnvSha256 -Path $originalEnv) -cne (Get-DeliveryStableDotEnvSha256 -Path $OriginalEnvPath)){throw 'FIXTURE_WORKFLOW_UPDATE_ENV_UNPROVEN: first backup differs from the immutable seed'}
        return [ordered]@{root=$Root;head=$head;branchRef=$branchRef;receipts=$proof.ToArray();stableEnvSha256=(Get-DeliveryStableDotEnvSha256 -Path (Join-Path $Root '.dev.env'))}
    } finally {
        if($hadRoot){$script:ProjectRoot=$previousRootValue}else{Remove-Variable -Name ProjectRoot -Scope Script -ErrorAction SilentlyContinue}
    }
}

function Get-SourceE2EFixtureCapsule {
    param([string]$ProjectRoot, [ValidateSet('Develop','Release')][string]$Phase, [string]$AgentTarget='', [switch]$Recapture,[switch]$AcknowledgeWorkflowUpdate)
    if($Recapture -and $AcknowledgeWorkflowUpdate){throw 'FIXTURE_CAPTURE_OPTIONS_CONFLICT: acknowledge preserves the capsule; recapture replaces it'}
    $configPath=Join-Path $ProjectRoot '.agent-1c/release-e2e.json'
    $original=Read-Utf8Text -Path $configPath
    $config=ConvertFrom-DeliveryProofJson -Json $original
    $property=$config.PSObject.Properties['qualificationFixtures']
    if(-not $Recapture -and $property -and $property.Value.PSObject.Properties[$Phase]){
        $descriptor=$property.Value.$Phase
        $manifest=Read-QualificationFixtureCapsule -ManifestPath ([string]$descriptor.path) -Sha256 ([string]$descriptor.sha256)
        $capsule=Split-Path -Parent ([string]$descriptor.path)
        $admission=$descriptor.PSObject.Properties['workflowUpdateAdmission']
        $workflowContinued=$AcknowledgeWorkflowUpdate -or $null -ne $admission
        $proof=$null
        if($workflowContinued){
            if((Get-RepositoryCommonGitDirectory -RepositoryRoot $ProjectRoot) -ine (Get-RepositoryCommonGitDirectory -RepositoryRoot ([string]$manifest.sourceBranchRoot))){throw 'FIXTURE_SEED_NOT_REGISTERED'}
            $workflowRepository=Split-Path -Parent $PSScriptRoot
            if((Invoke-RepositoryGit -RepositoryRoot $workflowRepository -Arguments @('merge-base','--is-ancestor',[string]$manifest.workflowCommit,'refs/remotes/origin/develop') -AllowFailure).exitCode -ne 0){throw 'FIXTURE_BASELINE_NOT_PUBLISHED'}
            $proof=[ordered]@{capsuleSha256=[string]$descriptor.sha256;master=(Get-SourceFixtureWorkflowUpdateProof -Root $ProjectRoot -OriginalCommit ([string]$manifest.masterCommit) -OriginalEnvPath (Join-Path $capsule 'master.env') -ExpectedBranchRef 'refs/heads/master');branch=(Get-SourceFixtureWorkflowUpdateProof -Root ([string]$manifest.sourceBranchRoot) -OriginalCommit ([string]$manifest.branchCommit) -OriginalEnvPath (Join-Path $capsule 'branch.env') -ExpectedBranchRef ('refs/heads/itldev/'+[string]$manifest.branchName))}
            if(-not $AcknowledgeWorkflowUpdate -and (ConvertTo-DeliveryProofJson -InputObject $proof -Depth 32 -Compress) -cne (ConvertTo-DeliveryProofJson -InputObject $admission.Value -Depth 32 -Compress)){throw 'FIXTURE_SEED_CHANGED: a new workflow transition needs explicit Capture -AcknowledgeWorkflowUpdate'}
        }
        $seedState=Read-QualificationFixtureJson -Path (Join-Path ([string]$manifest.sourceBranchRoot) ('.agent-1c/dev-branches/'+[string]$manifest.branchName+'.json'))
        $savedConfig=Read-QualificationFixtureJson -Path (Join-Path $capsule 'release-e2e.json')
        foreach($value in @($config,$savedConfig)){if($value.PSObject.Properties['qualificationFixtures']){$value.PSObject.Properties.Remove('qualificationFixtures')}}
        $changed=([string]$manifest.sourceProjectRoot -ine [IO.Path]::GetFullPath($ProjectRoot)) -or
            (-not $workflowContinued -and ((Invoke-RepositoryGit -RepositoryRoot $ProjectRoot -Arguments @('rev-parse','HEAD')).stdout.Trim() -cne [string]$manifest.masterCommit)) -or
            (-not $workflowContinued -and ((Invoke-RepositoryGit -RepositoryRoot ([string]$manifest.sourceBranchRoot) -Arguments @('rev-parse','HEAD')).stdout.Trim() -cne [string]$manifest.branchCommit)) -or
            ((Get-SourceFixtureSemanticState -State $seedState) -cne [string]$manifest.semanticState) -or
            ((ConvertTo-DeliveryProofJson -InputObject $config -Compress -Depth 32) -cne (ConvertTo-DeliveryProofJson -InputObject $savedConfig -Compress -Depth 32)) -or
            ((Get-FileHash -LiteralPath ([string]$manifest.sourceDatabase.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.sourceDatabase.sha256) -or
            (-not $workflowContinued -and ((Get-DeliveryStableDotEnvSha256 -Path (Join-Path $ProjectRoot '.dev.env')) -cne (Get-DeliveryStableDotEnvSha256 -Path (Join-Path $capsule 'master.env')))) -or
            (-not $workflowContinued -and ((Get-DeliveryStableDotEnvSha256 -Path (Join-Path ([string]$manifest.sourceBranchRoot) '.dev.env')) -cne (Get-DeliveryStableDotEnvSha256 -Path (Join-Path $capsule 'branch.env'))))
        foreach($reference in @($manifest.contextFiles)){
            if(-not $reference.PSObject.Properties['sourcePath'] -or -not $reference.PSObject.Properties['sourceSha256'] -or
                -not (Test-Path -LiteralPath $reference.sourcePath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $reference.sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$reference.sourceSha256){$changed=$true}
        }
        if($changed){throw "FIXTURE_SEED_CHANGED: retain the old capsule/checkpoints; diagnose seed isolation or use Capture -AcknowledgeWorkflowUpdate for exact completed workflow-only updates. Recapture requires a reviewed published baseline and replaces the capsule."}
        Assert-SourceFixtureGitClean -Root $ProjectRoot;Assert-SourceFixtureGitClean -Root ([string]$manifest.sourceBranchRoot)
        if($AcknowledgeWorkflowUpdate){
            if((Read-Utf8Text -Path $configPath) -cne $original){throw 'FIXTURE_CONFIG_MOVED'}
            $descriptor|Add-Member -NotePropertyName workflowUpdateAdmission -NotePropertyValue $proof -Force
            $saved=ConvertFrom-DeliveryProofJson -Json $original
            $saved.qualificationFixtures.$Phase=$descriptor
            Write-QualificationFixtureJson -Path $configPath -Value $saved
        }
        return $descriptor
    }
    if($AcknowledgeWorkflowUpdate){throw 'FIXTURE_EXISTING_CAPSULE_REQUIRED: capture a published baseline first'}
    $descriptor=Export-SourceE2EFixtureCapsule -ProjectRoot $ProjectRoot -Phase $Phase -AgentTarget $AgentTarget
    if((Read-Utf8Text -Path $configPath) -cne $original){throw 'FIXTURE_CONFIG_MOVED: sealed capsule retained; repeat qualification without overwriting the changed stand configuration'}
    if(-not $property){$config|Add-Member -NotePropertyName qualificationFixtures -NotePropertyValue ([pscustomobject]@{})}
    if($config.qualificationFixtures.PSObject.Properties[$Phase]){$config.qualificationFixtures.$Phase=$descriptor}
    else{$config.qualificationFixtures|Add-Member -NotePropertyName $Phase -NotePropertyValue $descriptor}
    Write-QualificationFixtureJson -Path $configPath -Value $config
    return $descriptor
}

function Invoke-SourceFixtureInitialRestore {
    param([string]$Root,[string[]]$Arguments,[string]$AgentTarget,[string]$LogRoot)
    $claim=Read-QualificationFixtureJson -Path (Join-Path (Split-Path -Parent $Root) 'qualification-fixture.json')
    if([string]$claim.kind -cne 'itl-qualification-fixture-target' -or [string]$claim.status -cne 'materializing' -or [string]$claim.branchRoot -ine $Root){throw 'FIXTURE_INITIAL_RESTORE_OWNERSHIP_INVALID'}
    $envPath=Resolve-QualificationFixtureChild -Root $Root -RelativePath '.dev.env'
    $original=[IO.File]::ReadAllBytes($envPath)
    $text=Read-Utf8Text -Path $envPath
    $initial=[regex]::Replace($text,'(?m)^[\t ]*IB_(?:USER|PASSWORD)[\t ]*=.*(?:\r?\n|$)','')
    $user=[Environment]::GetEnvironmentVariable('IB_USER','Process')
    $password=[Environment]::GetEnvironmentVariable('IB_PASSWORD','Process')
    Write-Utf8Text -Path $envPath -Value $initial
    try {
        [Environment]::SetEnvironmentVariable('IB_USER',$null,'Process')
        [Environment]::SetEnvironmentVariable('IB_PASSWORD',$null,'Process')
        Invoke-SourceFixtureInstalledAction -Root $Root -Action 'release-e2e-restore' -Arguments $Arguments -AgentTarget $AgentTarget -LogRoot $LogRoot
    } finally {
        [Environment]::SetEnvironmentVariable('IB_USER',$user,'Process')
        [Environment]::SetEnvironmentVariable('IB_PASSWORD',$password,'Process')
        $current=Remove-QualificationFixtureRuntimeEnvironmentAssignments -Text (Read-Utf8Text -Path $envPath)
        $expected=Remove-QualificationFixtureRuntimeEnvironmentAssignments -Text $initial
        if($current -cne $expected){throw 'FIXTURE_INITIAL_ENV_CHANGED: retain owned target for diagnosis; repeat qualification with a new target'}
        [IO.File]::WriteAllBytes($envPath,$original)
    }
}

function New-SourceE2EFixtureProject {
    param([string]$ProjectRoot, [ValidateSet('Develop','Release')][string]$Phase, [string]$CandidateRoot, [string]$ProjectsRoot='C:\itlj', [string]$AgentTarget='', [string]$AiRulesSource='', [string]$ReceiptPath='')
    if($Phase -eq 'Develop'){
        $retentionRoot=if($ReceiptPath){Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($ReceiptPath))) 'fixture-retention'}else{Join-Path $CandidateRoot 'build/test-results/fixture-retention'}
        [void](Remove-CompletedSourceE2ECopies -ProjectsRoot $ProjectsRoot -CandidateRoot $CandidateRoot -DiagnosticRoot $retentionRoot)
    }
    $descriptor=Get-SourceE2EFixtureCapsule -ProjectRoot $ProjectRoot -Phase $Phase -AgentTarget $AgentTarget
    $manifest=Read-QualificationFixtureCapsule -ManifestPath ([string]$descriptor.path) -Sha256 ([string]$descriptor.sha256)
    if((Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('merge-base','--is-ancestor',[string]$manifest.workflowCommit,'refs/remotes/origin/develop') -AllowFailure).exitCode -ne 0){throw 'FIXTURE_BASELINE_NOT_PUBLISHED: use the capsule captured from a published workflow baseline; preserve the rejected capsule'}
    $capsule=Split-Path -Parent ([string]$descriptor.path)
    $databaseBytes=0L
    if($Phase -eq 'Develop'){
        $databaseBytes=[int64](Get-Item -LiteralPath ([string]$manifest.sourceDatabase.path)).Length
        Assert-SourceE2ESpace -Operation 'prepare qualification copy' -Allocations @(
            @{path=$ProjectsRoot;bytes=($databaseBytes+(Get-Item -LiteralPath (Join-Path $capsule 'infobase.dt')).Length)},
            @{path=[IO.Path]::GetTempPath();bytes=$databaseBytes})
    }
    $commit=(Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
    # Develop repeats from the seed; Release resumes its existing checkpoint.
    $segment='q '+([string][char]0x041F)+([string][char]0x0440)+([string][char]0x043E)+([string][char]0x0435)+([string][char]0x043A)+([string][char]0x0442)
    $attempt=if($Phase -eq 'Develop'){'-'+[guid]::NewGuid().ToString('N').Substring(0,8)}else{''}
    $parent=Resolve-QualificationFixtureChild -Root $ProjectsRoot -RelativePath ($segment+'/'+$Phase.ToLowerInvariant()+'-'+([string]$descriptor.sha256).Substring(0,12)+'-'+$commit.Substring(0,12)+$attempt)
    if($Phase -eq 'Release' -and $ReceiptPath -and (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)){
        $previous=Read-QualificationFixtureJson -Path $ReceiptPath
        if([string]$previous.capsule.sha256 -ceq [string]$descriptor.sha256 -and [string]$previous.claim.candidateCommit -ceq $commit){
            $previousParent=Split-Path -Parent ([IO.Path]::GetFullPath([string]$previous.projectRoot))
            $prefix=[IO.Path]::GetFullPath($ProjectsRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $previousParent.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_RECEIPT_TARGET_FOREIGN'}
            $parent=Resolve-QualificationFixtureChild -Root $ProjectsRoot -RelativePath $previousParent.Substring($prefix.Length)
        }
    }
    $target=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'project'
    $branch=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'branch'
    $claimPath=Get-QualificationFixtureClaimPath -ProjectRoot $target
    if(Test-Path -LiteralPath $claimPath){
        $claim=Read-QualificationFixtureJson -Path $claimPath
        if([string]$claim.capsuleSha256 -cne [string]$descriptor.sha256 -or [string]$claim.candidateCommit -cne $commit -or
            [string]$claim.projectRoot -ine $target -or [string]$claim.branchRoot -ine $branch){throw 'FIXTURE_TARGET_IDENTITY_MISMATCH'}
        if([string]$claim.status -ceq 'ready'){return [pscustomobject]@{projectRoot=$target;branchRoot=$branch;capsule=$descriptor;claim=$claim;execution='continued'}}
        Write-Host "Retaining incomplete fixture for diagnosis: $parent; preparing another owned target from the same capsule."
        $parent=$parent+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
        $target=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'project';$branch=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'branch'
        $claimPath=Get-QualificationFixtureClaimPath -ProjectRoot $target
    }
    if(Test-Path -LiteralPath $parent){
        Write-Host "Retaining unfinished factory files: $parent"
        $parent=$parent+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
        $target=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'project';$branch=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'branch'
        $claimPath=Get-QualificationFixtureClaimPath -ProjectRoot $target
    }
    [void][IO.Directory]::CreateDirectory($parent)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $claim=[ordered]@{schemaVersion=2;kind='itl-qualification-fixture-target';status='materializing';projectRoot=$target;branchRoot=$branch;capsuleSha256=[string]$descriptor.sha256;capsulePath=[string]$descriptor.path;candidateCommit=$commit;phase=$Phase;copyRoot=$parent;projectsRoot=[IO.Path]::GetFullPath($ProjectsRoot).TrimEnd('\','/');workflowCommonGit=(Get-RepositoryCommonGitDirectory -RepositoryRoot $CandidateRoot);databaseBytes=$databaseBytes}
    Write-QualificationFixtureJson -Path $claimPath -Value $claim
    if($ReceiptPath){Write-QualificationFixtureJson -Path $ReceiptPath -Value @{projectRoot=$target;branchRoot=$branch;capsule=$descriptor;claim=$claim;execution='materializing'}}
    $preparationLease=Open-SourceE2EFixtureUse -ProjectRoot $target
    try {
    Invoke-RepositoryGit -RepositoryRoot $parent -Arguments @('clone','--no-checkout','--no-hardlinks','--no-tags','--branch','master',(Join-Path $capsule 'source.bundle'),$target)|Out-Null
    # Only this new disposable repository owns the setting; inherited machine
    # defaults must not make a sealed Unicode/long-path workload uncheckoutable.
    Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('config','core.longpaths','true')|Out-Null
    Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('checkout','--detach',[string]$manifest.masterCommit)|Out-Null
    Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('checkout','-B','master',[string]$manifest.masterCommit)|Out-Null
    Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('worktree','add','-b',('itldev/'+[string]$manifest.branchName),$branch,[string]$manifest.branchCommit)|Out-Null
    foreach($required in @($manifest.requiredCommits)){
        if([string]$required -cnotmatch '^[a-f0-9]{40}$' -or (Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('cat-file','-t',[string]$required)).stdout.Trim() -cne 'commit'){throw 'FIXTURE_PENDING_OBJECT_MISSING'}
        Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('update-ref',('refs/itl/qualification-fixture/'+[string]$required),[string]$required)|Out-Null
    }
    # Origin is the immutable local bundle, never the seed or a publishing remote.
    foreach($item in @($target,$branch)){Invoke-RepositoryGit -RepositoryRoot $item -Arguments @('config','user.name','ITL qualification')|Out-Null;Invoke-RepositoryGit -RepositoryRoot $item -Arguments @('config','user.email','qualification@example.invalid')|Out-Null}
    $context=Install-QualificationFixtureContext -ManifestPath ([string]$descriptor.path) -Sha256 ([string]$descriptor.sha256) -TargetProjectRoot $target -TargetBranchRoot $branch
    $snapshotRelative='.agent-1c/snapshots/qualification-fixtures/seed.dt'
    $snapshot=Resolve-QualificationFixtureChild -Root $branch -RelativePath $snapshotRelative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $snapshot));Copy-Item -LiteralPath (Join-Path $capsule 'infobase.dt') -Destination $snapshot
    $logs=Join-Path $parent 'preparation-logs'
    $null=Invoke-SourceFixtureInstalledAction -Root $branch -Action 'qualification-create-infobase' -Arguments @('-DevBranchName',$context.branchName) -AgentTarget $AgentTarget -LogRoot $logs -TimeoutSeconds 420
    $restore=Invoke-SourceFixtureInitialRestore -Root $branch -Arguments @('-DevBranchName',$context.branchName,'-ReleaseSnapshotPath',$snapshotRelative,'-PreserveReleaseSnapshotApplicationProof') -AgentTarget $AgentTarget -LogRoot $logs
    $config=Read-QualificationFixtureJson -Path (Join-Path $capsule 'release-e2e.json')
    $config.developDevBranchName=$context.branchName;$config.developWorktreePath=$branch
    $config.devBranchName=$context.branchName;$config.worktreePath=$branch
    # Each phase owns one branch; the unused other phase path remains explicitly distinct.
    if($Phase -eq 'Develop'){$config.worktreePath=Join-Path $parent 'unused-release'}else{$config.developWorktreePath=Join-Path $parent 'unused-develop'}
    if($config.PSObject.Properties['qualificationFixtures']){$config.PSObject.Properties.Remove('qualificationFixtures')}
    Write-QualificationFixtureJson -Path (Join-Path $target '.agent-1c/release-e2e.json') -Value $config
    if($Phase -eq 'Release'){
        if(-not $AiRulesSource){throw 'FIXTURE_RULES_SOURCE_REQUIRED: repeat Release with its exact -AiRulesSource'}
        $previousSource=$env:ITL_WORKFLOW_SOURCE_PATH;$previousRules=$env:ITL_AI_RULES_SOURCE_PATH
        try{
            $env:ITL_WORKFLOW_SOURCE_PATH=[IO.Path]::GetFullPath($CandidateRoot);$env:ITL_AI_RULES_SOURCE_PATH=[IO.Path]::GetFullPath($AiRulesSource)
            $null=Invoke-SourceFixtureInstalledAction -Root $target -Action 'update-workflow' -AgentTarget $AgentTarget -LogRoot $logs -TimeoutSeconds 3600
            $installed=Read-QualificationFixtureJson -Path (Join-Path $target '.agent-1c/dependency-lock.json')
            if([string]$installed.dependencies.workflowPackage.commit -cne $commit){throw 'FIXTURE_INSTALLED_CANDIDATE_MISMATCH'}
            $workloadChanges=@(Get-RepositoryGitPathList -RepositoryRoot $target -Arguments @('diff','--name-only','-z','HEAD','--','src/cf','src/cfe','tests/features'))
            if($workloadChanges.Count){throw 'FIXTURE_WORKLOAD_CHANGED_DURING_PREPARATION'}
            Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('add','--all')|Out-Null
            if((Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('diff','--cached','--quiet') -AllowFailure).exitCode -ne 0){Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('commit','-m','test: prepare exact release candidate')|Out-Null}
            $masterHead=(Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('rev-parse','HEAD')).stdout.Trim()
            # The capsule owns a frozen master tree and one restored branch DB,
            # not a live source/master DB. Merge that exact prepared master via
            # the ordinary lite owner, including its native branch load. A full
            # refresh would resynchronize the immutable workload from a missing
            # source DB instead of preparing this candidate.
            $null=Invoke-SourceFixtureInstalledAction -Root $branch -Action 'refresh-dev-branch-lite' -Arguments @('-DevBranchName',$context.branchName,'-ExpectedMasterCommit',$masterHead) -AgentTarget $AgentTarget -LogRoot $logs -TimeoutSeconds 5400
            $installed=Read-QualificationFixtureJson -Path (Join-Path $branch '.agent-1c/dependency-lock.json')
            if([string]$installed.dependencies.workflowPackage.commit -cne $commit){throw 'FIXTURE_REFRESHED_CANDIDATE_MISMATCH'}
        }finally{$env:ITL_WORKFLOW_SOURCE_PATH=$previousSource;$env:ITL_AI_RULES_SOURCE_PATH=$previousRules}
    }
    $claim.status='ready';$claim['restoreDurationMs']=$restore.durationMs;$claim['preparationDurationMs']=[int64]$watch.ElapsedMilliseconds
    Write-QualificationFixtureJson -Path $claimPath -Value $claim
    return [pscustomobject]@{projectRoot=$target;branchRoot=$branch;capsule=$descriptor;claim=$claim;execution='executed'}
    } catch {
        $originalError=$_
        $claim.status='preparation-failed'
        $claim['preparationFailure']=@{kind='itl-fixture-preparation-failure';error=$originalError.Exception.Message;finishedAt=[DateTime]::UtcNow.ToString('o')}
        try {
            Write-QualificationFixtureJson -Path $claimPath -Value $claim
            if($ReceiptPath){Write-QualificationFixtureJson -Path $ReceiptPath -Value @{projectRoot=$target;branchRoot=$branch;capsule=$descriptor;claim=$claim;execution='failed'}}
        } catch {Write-Warning "Fixture failure receipt could not be persisted: $($_.Exception.Message); original failure: $($originalError.Exception.Message)"}
        throw $originalError
    } finally {$preparationLease.Dispose()}
}

if($Action){
    $ErrorActionPreference='Stop'
    $utf8=[Text.UTF8Encoding]::new($false);[Console]::InputEncoding=$utf8;[Console]::OutputEncoding=$utf8;$OutputEncoding=$utf8
    if(-not $ProjectRoot -or -not $OutputPath){throw 'Fixture operation requires -ProjectRoot and -OutputPath'}
    if($Recapture -and $Action -ne 'Capture'){throw 'Recapture is an explicit Capture operation, not a target repair'}
    if($AcknowledgeWorkflowUpdate -and $Action -ne 'Capture'){throw 'AcknowledgeWorkflowUpdate is an explicit Capture operation'}
    if($Action -eq 'DisposeCopy'){
        $fixture=Read-QualificationFixtureJson -Path $FixtureReceiptPath
        if([IO.Path]::GetFullPath($ProjectRoot) -ine [IO.Path]::GetFullPath([string]$fixture.projectRoot)){throw 'FIXTURE_COPY_RECEIPT_TARGET_MISMATCH'}
        $copyPrefix=(Split-Path -Parent ([IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')))+[IO.Path]::DirectorySeparatorChar
        if([IO.Path]::GetFullPath($OutputPath).StartsWith($copyPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_COPY_EVIDENCE_INSIDE_TARGET'}
        $result=Remove-SourceE2EFixtureCopy -Fixture $fixture -CandidateRoot $CandidateRoot -ReportPath $TerminalReportPath -DiagnosticRoot $DiagnosticRoot
    }
    elseif($Action -eq 'Capture'){$result=Get-SourceE2EFixtureCapsule -ProjectRoot $ProjectRoot -Phase $Phase -AgentTarget $AgentTarget -Recapture:$Recapture -AcknowledgeWorkflowUpdate:$AcknowledgeWorkflowUpdate}
    else{$result=New-SourceE2EFixtureProject -ProjectRoot $ProjectRoot -Phase $Phase -CandidateRoot $CandidateRoot -ProjectsRoot $FreshProjectsRoot -AgentTarget $AgentTarget -AiRulesSource $AiRulesSource -ReceiptPath $OutputPath}
    Write-QualificationFixtureJson -Path $OutputPath -Value $result
}
