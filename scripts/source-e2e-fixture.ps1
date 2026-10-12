[CmdletBinding()]
param(
    [ValidateSet('','Capture','Prepare')][string]$Action='',
    [string]$ProjectRoot='',
    [ValidateSet('Develop','Release')][string]$Phase='Develop',
    [string]$CandidateRoot='',
    [string]$AiRulesSource='',
    [string]$FreshProjectsRoot='C:\itlj',
    [string]$AgentTarget='',
    [switch]$Recapture,
    [string]$OutputPath=''
)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'git-path-list.ps1')
. (Join-Path $PSScriptRoot 'source-proof-json.ps1')
. (Join-Path $PSScriptRoot 'source-delivery-process.ps1')
. (Join-Path $PSScriptRoot 'stand-env-identity.ps1')
$fixtureLib = Join-Path (Split-Path -Parent $PSScriptRoot) '.agents/skills/1c-workflow/scripts/lib'
. (Join-Path $fixtureLib 'agent-1c.core.ps1')
. (Join-Path $fixtureLib 'agent-1c.lifecycle.ps1')
. (Join-Path $PSScriptRoot 'lifecycle-qualification-fixture.ps1')

function Invoke-SourceFixtureInstalledAction {
    param([string]$Root, [string]$Action, [string[]]$Arguments=@(), [string]$AgentTarget='', [string]$LogRoot, [int]$TimeoutSeconds=7200)
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
            if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds -or ([DateTime]::UtcNow-$lastProgress).TotalMinutes -ge 15){throw "FIXTURE_ACTION_TIMEOUT: $Action; retained logs=$LogRoot; repeat the same qualification after diagnosis"}
            if(([DateTime]::UtcNow-$lastNotice).TotalSeconds -ge 30){Write-Host "Fixture ${Action}: $([int]$watch.Elapsed.TotalSeconds)s; logs=$LogRoot";$lastNotice=[DateTime]::UtcNow}
        }
        $process.WaitForExit();$process.Refresh()
        if([int]$process.ExitCode -ne 0){throw "FIXTURE_ACTION_FAILED: $Action exit=$($process.ExitCode); see $stdout and $stderr; repeat the same qualification after diagnosis"}
        return [pscustomobject]@{stdout=$stdout;stderr=$stderr;durationMs=[int64]$watch.ElapsedMilliseconds}
    } catch {$errorText=$_.Exception.Message;throw}
    finally {
        try { Close-DeliveryProcessJob -JobHandle $job.jobHandle -Process $process -PriorErrorMessage $errorText }
        finally { $process.Dispose(); $watch.Stop() }
    }
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

function Get-SourceE2EFixtureCapsule {
    param([string]$ProjectRoot, [ValidateSet('Develop','Release')][string]$Phase, [string]$AgentTarget='', [switch]$Recapture)
    $configPath=Join-Path $ProjectRoot '.agent-1c/release-e2e.json'
    $original=Read-Utf8Text -Path $configPath
    $config=ConvertFrom-DeliveryProofJson -Json $original
    $property=$config.PSObject.Properties['qualificationFixtures']
    if(-not $Recapture -and $property -and $property.Value.PSObject.Properties[$Phase]){
        $descriptor=$property.Value.$Phase
        $manifest=Read-QualificationFixtureCapsule -ManifestPath ([string]$descriptor.path) -Sha256 ([string]$descriptor.sha256)
        $capsule=Split-Path -Parent ([string]$descriptor.path)
        $seedState=Read-QualificationFixtureJson -Path (Join-Path ([string]$manifest.sourceBranchRoot) ('.agent-1c/dev-branches/'+[string]$manifest.branchName+'.json'))
        $savedConfig=Read-QualificationFixtureJson -Path (Join-Path $capsule 'release-e2e.json')
        foreach($value in @($config,$savedConfig)){if($value.PSObject.Properties['qualificationFixtures']){$value.PSObject.Properties.Remove('qualificationFixtures')}}
        $changed=([string]$manifest.sourceProjectRoot -ine [IO.Path]::GetFullPath($ProjectRoot)) -or
            ((Invoke-RepositoryGit -RepositoryRoot $ProjectRoot -Arguments @('rev-parse','HEAD')).stdout.Trim() -cne [string]$manifest.masterCommit) -or
            ((Invoke-RepositoryGit -RepositoryRoot ([string]$manifest.sourceBranchRoot) -Arguments @('rev-parse','HEAD')).stdout.Trim() -cne [string]$manifest.branchCommit) -or
            ((Get-SourceFixtureSemanticState -State $seedState) -cne [string]$manifest.semanticState) -or
            ((ConvertTo-DeliveryProofJson -InputObject $config -Compress -Depth 32) -cne (ConvertTo-DeliveryProofJson -InputObject $savedConfig -Compress -Depth 32)) -or
            ((Get-FileHash -LiteralPath ([string]$manifest.sourceDatabase.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.sourceDatabase.sha256) -or
            ((Get-DeliveryStableDotEnvSha256 -Path (Join-Path $ProjectRoot '.dev.env')) -cne (Get-DeliveryStableDotEnvSha256 -Path (Join-Path $capsule 'master.env'))) -or
            ((Get-DeliveryStableDotEnvSha256 -Path (Join-Path ([string]$manifest.sourceBranchRoot) '.dev.env')) -cne (Get-DeliveryStableDotEnvSha256 -Path (Join-Path $capsule 'branch.env')))
        foreach($reference in @($manifest.contextFiles)){
            if(-not $reference.PSObject.Properties['sourcePath'] -or -not $reference.PSObject.Properties['sourceSha256'] -or
                -not (Test-Path -LiteralPath $reference.sourcePath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $reference.sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$reference.sourceSha256){$changed=$true}
        }
        if($changed){throw "FIXTURE_SEED_CHANGED: retain the old capsule/checkpoints; review the declared seed, then run scripts/source-e2e-fixture.ps1 -Action Capture -Phase $Phase -ProjectRoot '$ProjectRoot' -Recapture -OutputPath <receipt.json>, and repeat qualification"}
        Assert-SourceFixtureGitClean -Root $ProjectRoot;Assert-SourceFixtureGitClean -Root ([string]$manifest.sourceBranchRoot)
        return $descriptor
    }
    $descriptor=Export-SourceE2EFixtureCapsule -ProjectRoot $ProjectRoot -Phase $Phase -AgentTarget $AgentTarget
    if((Read-Utf8Text -Path $configPath) -cne $original){throw 'FIXTURE_CONFIG_MOVED: sealed capsule retained; repeat qualification without overwriting the changed stand configuration'}
    if(-not $property){$config|Add-Member -NotePropertyName qualificationFixtures -NotePropertyValue ([pscustomobject]@{})}
    if($config.qualificationFixtures.PSObject.Properties[$Phase]){$config.qualificationFixtures.$Phase=$descriptor}
    else{$config.qualificationFixtures|Add-Member -NotePropertyName $Phase -NotePropertyValue $descriptor}
    Write-QualificationFixtureJson -Path $configPath -Value $config
    return $descriptor
}

function New-SourceE2EFixtureProject {
    param([string]$ProjectRoot, [ValidateSet('Develop','Release')][string]$Phase, [string]$CandidateRoot, [string]$ProjectsRoot='C:\itlj', [string]$AgentTarget='', [string]$AiRulesSource='', [string]$ReceiptPath='')
    $descriptor=Get-SourceE2EFixtureCapsule -ProjectRoot $ProjectRoot -Phase $Phase -AgentTarget $AgentTarget
    $manifest=Read-QualificationFixtureCapsule -ManifestPath ([string]$descriptor.path) -Sha256 ([string]$descriptor.sha256)
    if((Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('merge-base','--is-ancestor',[string]$manifest.workflowCommit,'refs/remotes/origin/develop') -AllowFailure).exitCode -ne 0){throw 'FIXTURE_BASELINE_NOT_PUBLISHED: use the capsule captured from a published workflow baseline; preserve the rejected capsule'}
    $capsule=Split-Path -Parent ([string]$descriptor.path)
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
    Invoke-RepositoryGit -RepositoryRoot $parent -Arguments @('clone','--no-checkout','--no-hardlinks','--no-tags','--branch','master',(Join-Path $capsule 'source.bundle'),$target)|Out-Null
    Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('checkout','--detach',[string]$manifest.masterCommit)|Out-Null
    Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('checkout','-B','master',[string]$manifest.masterCommit)|Out-Null
    Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('worktree','add','-b',('itldev/'+[string]$manifest.branchName),$branch,[string]$manifest.branchCommit)|Out-Null
    foreach($required in @($manifest.requiredCommits)){
        if([string]$required -cnotmatch '^[a-f0-9]{40}$' -or (Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('cat-file','-t',[string]$required)).stdout.Trim() -cne 'commit'){throw 'FIXTURE_PENDING_OBJECT_MISSING'}
        Invoke-RepositoryGit -RepositoryRoot $target -Arguments @('update-ref',('refs/itl/qualification-fixture/'+[string]$required),[string]$required)|Out-Null
    }
    # Origin is the immutable local bundle, never the seed or a publishing remote.
    foreach($item in @($target,$branch)){Invoke-RepositoryGit -RepositoryRoot $item -Arguments @('config','user.name','ITL qualification')|Out-Null;Invoke-RepositoryGit -RepositoryRoot $item -Arguments @('config','user.email','qualification@example.invalid')|Out-Null}
    $claim=[ordered]@{schemaVersion=1;kind='itl-qualification-fixture-target';status='materializing';projectRoot=$target;branchRoot=$branch;capsuleSha256=[string]$descriptor.sha256;candidateCommit=$commit;phase=$Phase}
    Write-QualificationFixtureJson -Path $claimPath -Value $claim
    if($ReceiptPath){Write-QualificationFixtureJson -Path $ReceiptPath -Value @{projectRoot=$target;branchRoot=$branch;capsule=$descriptor;claim=$claim;execution='materializing'}}
    $context=Install-QualificationFixtureContext -ManifestPath ([string]$descriptor.path) -Sha256 ([string]$descriptor.sha256) -TargetProjectRoot $target -TargetBranchRoot $branch
    $snapshotRelative='.agent-1c/snapshots/qualification-fixtures/seed.dt'
    $snapshot=Resolve-QualificationFixtureChild -Root $branch -RelativePath $snapshotRelative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $snapshot));Copy-Item -LiteralPath (Join-Path $capsule 'infobase.dt') -Destination $snapshot
    $logs=Join-Path $parent 'preparation-logs'
    $null=Invoke-SourceFixtureInstalledAction -Root $branch -Action 'qualification-create-infobase' -Arguments @('-DevBranchName',$context.branchName) -AgentTarget $AgentTarget -LogRoot $logs -TimeoutSeconds 420
    $restore=Invoke-SourceFixtureInstalledAction -Root $branch -Action 'release-e2e-restore' -Arguments @('-DevBranchName',$context.branchName,'-ReleaseSnapshotPath',$snapshotRelative,'-PreserveReleaseSnapshotApplicationProof') -AgentTarget $AgentTarget -LogRoot $logs
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
            $null=Invoke-SourceFixtureInstalledAction -Root $branch -Action 'refresh-dev-branch' -Arguments @('-DevBranchName',$context.branchName,'-ExpectedMasterCommit',$masterHead) -AgentTarget $AgentTarget -LogRoot $logs -TimeoutSeconds 5400
            $installed=Read-QualificationFixtureJson -Path (Join-Path $branch '.agent-1c/dependency-lock.json')
            if([string]$installed.dependencies.workflowPackage.commit -cne $commit){throw 'FIXTURE_REFRESHED_CANDIDATE_MISMATCH'}
        }finally{$env:ITL_WORKFLOW_SOURCE_PATH=$previousSource;$env:ITL_AI_RULES_SOURCE_PATH=$previousRules}
    }
    $claim.status='ready';$claim['restoreDurationMs']=$restore.durationMs;$claim['preparationDurationMs']=[int64]$watch.ElapsedMilliseconds
    Write-QualificationFixtureJson -Path $claimPath -Value $claim
    return [pscustomobject]@{projectRoot=$target;branchRoot=$branch;capsule=$descriptor;claim=$claim;execution='executed'}
}

if($Action){
    $ErrorActionPreference='Stop'
    $utf8=[Text.UTF8Encoding]::new($false);[Console]::InputEncoding=$utf8;[Console]::OutputEncoding=$utf8;$OutputEncoding=$utf8
    if(-not $ProjectRoot -or -not $OutputPath){throw 'Fixture operation requires -ProjectRoot and -OutputPath'}
    if($Recapture -and $Action -ne 'Capture'){throw 'Recapture is an explicit Capture operation, not a target repair'}
    if($Action -eq 'Capture'){$result=Get-SourceE2EFixtureCapsule -ProjectRoot $ProjectRoot -Phase $Phase -AgentTarget $AgentTarget -Recapture:$Recapture}
    else{$result=New-SourceE2EFixtureProject -ProjectRoot $ProjectRoot -Phase $Phase -CandidateRoot $CandidateRoot -ProjectsRoot $FreshProjectsRoot -AgentTarget $AgentTarget -AiRulesSource $AiRulesSource -ReceiptPath $OutputPath}
    Write-QualificationFixtureJson -Path $OutputPath -Value $result
}
