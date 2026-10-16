[CmdletBinding()]
param([string]$ProjectRoot='', [string]$DevBranchName='', [ValidateSet('Create','Dispose')][string]$Operation='Create', [string]$ExpectedCandidate='', [string]$OutputPath='')
# Source-only preparation. The installed baseline still owns RestoreIB.
$lib=Join-Path (Split-Path -Parent $PSScriptRoot) '.agents/skills/1c-workflow/scripts/lib'
. (Join-Path $lib 'agent-1c.core.ps1')
. (Join-Path $lib 'agent-1c.lifecycle.ps1')
. (Join-Path $lib 'agent-1c.ports.ps1')
. (Join-Path $lib 'agent-1c.sessions.ps1')
. (Join-Path $lib 'agent-1c.seed.ps1')
. (Join-Path $PSScriptRoot 'source-proof-json.ps1')
. (Join-Path $PSScriptRoot 'git-path-list.ps1')
. (Join-Path $PSScriptRoot 'lifecycle-qualification-fixture.ps1')
function Initialize-SourceQualificationNativeContext {
    param([string]$Root)
    # Reuse the owner's non-operating entrypoint instead of copying its context.
    . (Join-Path $lib '../agent-1c.ps1') -ProjectRoot $Root -Action help *> $null
    $script:RunStatusPath=$RunStatusPath
}

function New-SourceQualificationInfoBase {
    param([string]$BranchRoot, [string]$BranchName, [string]$PlatformPath)
    $branch=[IO.Path]::GetFullPath($BranchRoot).TrimEnd('\','/')
    $parent=Split-Path -Parent $branch
    $claim=Read-QualificationFixtureJson -Path (Join-Path $parent 'qualification-fixture.json')
    if([string]$claim.kind -cne 'itl-qualification-fixture-target' -or [string]$claim.status -cne 'materializing' -or
        [string]$claim.branchRoot -ine $branch -or [string]$claim.projectRoot -ine (Join-Path $parent 'project') -or
        $branch -ine (Join-Path $parent 'branch') -or [string]::IsNullOrWhiteSpace($BranchName) -or
        $BranchName -match '[/\\]' -or $BranchName -in @('.','..')) {throw 'FIXTURE_CREATE_OWNERSHIP_INVALID'}
    $common=Get-RepositoryCommonGitDirectory -RepositoryRoot $branch
    if($common -ine (Get-RepositoryCommonGitDirectory -RepositoryRoot ([string]$claim.projectRoot))){throw 'FIXTURE_CREATE_GIT_OWNERSHIP_INVALID'}
    $statePath=Resolve-QualificationFixtureChild -Root $branch -RelativePath ('.agent-1c/dev-branches/'+$BranchName+'.json')
    $state=Read-QualificationFixtureJson -Path $statePath
    $prefix=$branch+[IO.Path]::DirectorySeparatorChar
    $base=[IO.Path]::GetFullPath([string]$state.devBranchInfoBasePath)
    if([string]$state.infoBaseKind -cne 'file' -or [string]$state.devBranchName -cne $BranchName -or -not $base.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_CREATE_TARGET_INVALID'}
    $base=Resolve-QualificationFixtureChild -Root $branch -RelativePath $base.Substring($prefix.Length)
    if(Test-Path -LiteralPath $base){throw 'FIXTURE_CREATE_TARGET_EXISTS: preserve this attempt; repeat qualification to create a new owned target'}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $base))
    $logs=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'preparation-logs'
    [void][IO.Directory]::CreateDirectory($logs)
    $log=Join-Path $logs ('create-infobase-'+[guid]::NewGuid().ToString('N')+'.log')
    $arguments=@('CREATEINFOBASE',(New-FileInfoBaseConnectionString -Path $base),'/DisableStartupDialogs','/Out',$log)
    $script:OneCNativeOperationJournal=New-OneCNativeOperationJournal -Resources @([pscustomobject]@{kind='file';path=$base})
    $result=Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $base -RequiredSessions 1 -Purpose 'qualification-infobase-create' -ScriptBlock {
        Invoke-NativeProcessAndWaitResult -FilePath $PlatformPath -Arguments $arguments -OneCCreateInfoBaseSyntax -TimeoutSeconds 300
    }
    if($result.timedOut -or $result.exitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $base '1Cv8.1CD') -PathType Leaf)){
        throw "FIXTURE_CREATE_FAILED: exit=$($result.exitCode) timedOut=$($result.timedOut); retain attempt/logs=$logs and repeat qualification after diagnosis"
    }
    return [pscustomobject]@{infoBasePath=$base;logPath=$log}
}

function Remove-SourceQualificationDatabases {
    param([string]$BranchRoot, [string]$CandidateCommit)
    . (Join-Path $lib 'agent-1c.seed.ps1')
    $branch=[IO.Path]::GetFullPath($BranchRoot).TrimEnd('\','/')
    $parent=Split-Path -Parent $branch
    $claimPath=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'qualification-fixture.json'
    $claim=Read-QualificationFixtureJson -Path $claimPath
    if($CandidateCommit -notmatch '^[0-9a-f]{40}$' -or
        [string]$claim.kind -cne 'itl-qualification-fixture-target' -or [string]$claim.phase -cne 'Develop' -or
        [string]$claim.status -notin @('materializing','preparation-failed','ready','disposed') -or [string]$claim.candidateCommit -cne $CandidateCommit -or
        [string]$claim.branchRoot -ine $branch -or [string]$claim.projectRoot -ine (Join-Path $parent 'project') -or
        $branch -ine (Join-Path $parent 'branch')) {throw 'FIXTURE_DISPOSE_OWNERSHIP_INVALID'}
    $common=Get-RepositoryCommonGitDirectory -RepositoryRoot $branch
    if($common -ine (Get-RepositoryCommonGitDirectory -RepositoryRoot ([string]$claim.projectRoot))){throw 'FIXTURE_DISPOSE_GIT_OWNERSHIP_INVALID'}
    $root=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'branch/.agent-1c/infobases'
    $directories=[Collections.Generic.Stack[string]]::new()
    if(Test-Path -LiteralPath $root -PathType Container){$directories.Push($root)}
    $files=@()
    while($directories.Count){
        $directory=$directories.Pop()
        foreach($item in @(Get-ChildItem -LiteralPath $directory -Force)){
            # Validate before descending: a reparse directory must never be traversed.
            $relative=$item.FullName.Substring($parent.Length+1)
            $safe=Resolve-QualificationFixtureChild -Root $parent -RelativePath $relative
            if($item.PSIsContainer){$directories.Push($safe)}
            elseif($item.Name -ieq '1Cv8.1CD'){$files+=$safe}
        }
    }
    $seedCaches=@()
    $seedRoot=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'project/.agent-1c/branch-seed'
    if(Test-Path -LiteralPath $seedRoot -PathType Container){
        foreach($item in @(Get-ChildItem -LiteralPath $seedRoot -Directory -Force)){
            $cache=Resolve-QualificationFixtureChild -Root $parent -RelativePath $item.FullName.Substring($parent.Length+1)
            if($item.Name -cnotmatch '^[0-9a-f]{64}$'){continue}
            $manifestPath=Resolve-QualificationFixtureChild -Root $cache -RelativePath 'manifest.json'
            $artifactPath=Resolve-QualificationFixtureChild -Root $cache -RelativePath 'infobase/1Cv8.1CD'
            if(-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)){continue}
            $manifest=Read-QualificationFixtureJson -Path $manifestPath
            if([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -cne 'ready' -or
                [string]$manifest.sourceKey -cne $item.Name -or [string]$manifest.artifactKind -cne 'file-1cd' -or
                [string]$manifest.artifactPath -ine $artifactPath){throw 'FIXTURE_SEED_CACHE_OWNERSHIP_INVALID: retain the cache and inspect its manifest'}
            $seedCaches+=@{root=$cache;leasePath=(Resolve-QualificationFixtureChild -Root $cache -RelativePath 'seed.lease');writerIntentPath=(Resolve-QualificationFixtureChild -Root $cache -RelativePath 'seed.writer.lock');rebuildMarkerPath=(Resolve-QualificationFixtureChild -Root $cache -RelativePath 'rebuild.marker.json')}
            $files+=$artifactPath
        }
    }
    if([string]$claim.status -ceq 'disposed' -and $files.Count -eq 0){return $claim.disposal}
    $removed=@()
    $seedLocks=New-Object Collections.Generic.List[object]
    try {
    # Reuse the installed cache's lock order before deleting any fixture bytes.
    foreach($paths in $seedCaches){
        $seedLocks.Add((Open-BranchSeedWriterIntent -Paths $paths -TimeoutSeconds 1))
        $seedLocks.Add((Open-BranchSeedLease -Paths $paths -Mode write -TimeoutSeconds 1))
    }
    foreach($file in $files){
        $settings=Get-OneCExecutionGuardSettings
        . (Join-Path $lib '../../../itl-remote-runner/scripts/ExecutionGuard.ps1')
        $owner=$null
        try {
            $owner=Start-ItlExecutionGuardHost -Python $settings.python -Request @{
                schemaVersion=1;root=$settings.root;bases=@(@{kind='file';path=(Split-Path -Parent $file)})
                operation='source-fixture-database-cleanup';executionId=[guid]::NewGuid().ToString('N');timeout=([math]::Min(30,$settings.waitTimeoutSeconds))
            }
            [void](Assert-ItlExecutionGuardHost -Owner $owner)
            [void](Resolve-QualificationFixtureChild -Root $parent -RelativePath $file.Substring($parent.Length+1))
            # The guard excludes workflow writers; the exclusive handle also excludes native clients.
            $stream=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose)
            try {$bytes=$stream.Length} finally {$stream.Dispose()}
            $removed+=@{path=$file;bytes=$bytes}
            Write-Host "Disposed derived fixture database: $file; bytes=$bytes"
            [void](Complete-ItlExecutionGuardHost -Owner $owner -Result succeeded -Artifacts @($claimPath))
            $owner=$null
        } finally {if($owner){Close-ItlExecutionGuardHost -Owner $owner}}
    }
    $result=@{status='disposed';removedDatabases=$removed;candidateCommit=$CandidateCommit;finishedAt=[DateTime]::UtcNow.ToString('o')}
    $claim.status='disposed'
    $claim|Add-Member -NotePropertyName disposal -NotePropertyValue $result -Force
    Write-QualificationFixtureJson -Path $claimPath -Value $claim
    return $result
    } finally {for($i=$seedLocks.Count-1;$i -ge 0;$i--){$seedLocks[$i].Dispose()}}
}

if($ProjectRoot){
    $ErrorActionPreference='Stop'
    $utf8=[Text.UTF8Encoding]::new($false);[Console]::InputEncoding=$utf8;[Console]::OutputEncoding=$utf8;$OutputEncoding=$utf8
    $script:ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot)
    Initialize-SourceQualificationNativeContext -Root $script:ProjectRoot
    $script:ConfigPath=Join-Path $script:ProjectRoot '.agent-1c/project.json'
    Import-DotEnv -Path (Join-Path $script:ProjectRoot '.dev.env')
    Read-ProjectConfig
    if($Operation -eq 'Dispose'){
        $result=Remove-SourceQualificationDatabases -BranchRoot $script:ProjectRoot -CandidateCommit $ExpectedCandidate
        if($OutputPath){Write-QualificationFixtureJson -Path $OutputPath -Value $result}
    } else {$null=New-SourceQualificationInfoBase -BranchRoot $script:ProjectRoot -BranchName $DevBranchName -PlatformPath (Get-PlatformPath)}
}
