# Source qualification-copy ownership recovery. No age/prefix-only adoption.
function Test-SourceE2ECopyProducerCommand {
    param([string]$CommandLine,[string]$ProjectsRoot)
    if($CommandLine -notmatch 'source-e2e-fixture\.ps1' -or $CommandLine -notmatch '-Action\s+"?Prepare(?:"|\s|$)'){return $false}
    $root='C:\itlj'
    if($CommandLine -match '-FreshProjectsRoot\s+(?:"(?<quoted>[^"]+)"|(?<plain>\S+))'){$root=if($matches.ContainsKey('quoted')){$matches['quoted']}else{$matches['plain']}}
    try {return [IO.Path]::GetFullPath($root).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($ProjectsRoot).TrimEnd('\','/')}
    catch {return $true} # An unreadable older producer command cannot authorize deletion.
}

function Get-SourceE2ECopyReportBinding {
    param([string]$CandidateRoot,[string]$Commit,[string]$Parent)
    $tree=(Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('rev-parse',($Commit+'^{tree}'))).stdout.Trim()
    $root=Join-Path (Get-RepositoryCommonGitDirectory -RepositoryRoot $CandidateRoot) ('itl/develop-e2e-qualifications/'+$tree)
    if(-not (Test-Path -LiteralPath $root)){return $null}
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter manifest.json -File -Recurse)){
        $manifest=Read-QualificationFixtureJson -Path $file.FullName
        $path=Resolve-QualificationFixtureChild -Root $file.DirectoryName -RelativePath 'route-report.json'
        if([int]$manifest.schemaVersion -notin @(1,2) -or [string]$manifest.kind -cne 'itl-develop-e2e-qualification-cache' -or [string]$manifest.identity.tree -cne $tree -or
            (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne [string]$manifest.identity.reportSha256){continue}
        $report=Read-QualificationFixtureJson -Path $path
        if([int]$report.schemaVersion -ne 1 -or [string]$report.kind -cne 'itl-develop-e2e-route-report' -or [string]$report.status -cne 'passed' -or
            [string]$report.repository.commit -cne $Commit -or [string]$report.repository.tree -cne $tree){continue}
        $negative=$report.result.PSObject.Properties['configurationRejection']
        if($negative -and $negative.Value -and [string]$negative.Value.status -ceq 'passed'){
            $proof=$negative.Value.proof
            if([string]$proof.projectRoot -ieq (Join-Path $Parent 'branch') -and
                $proof.snapshotRestored -eq $true -and $proof.cursorRestored -eq $true -and $proof.nativeOperationsReleased -eq $true){
                return @{kind='passed-negative';path=$path;sha256=[string]$manifest.identity.reportSha256;capsule=$null}
            }
        }
        $positive=$report.result.PSObject.Properties['positiveJourney']
        if($positive -and $positive.Value -and [string]$positive.Value.summary.status -ceq 'passed'){
            $fixture=$positive.Value.summary.qualificationFixture
            if([string]$fixture.projectRoot -ieq (Join-Path $Parent 'project') -and [string]$fixture.branchRoot -ieq (Join-Path $Parent 'branch')){
                return @{kind='passed-positive';path=$path;sha256=[string]$manifest.identity.reportSha256;capsule=$fixture.capsule}
            }
        }
    }
    return $null
}

function Get-SourceE2ECopyRecoveryContext {
    param([string]$Parent,[string]$ProjectsRoot,[string]$CandidateRoot,[string]$DiagnosticRoot,[switch]$ArchiveInactive)
    $segment='q '+(-join (@(0x041F,0x0440,0x043E,0x0435,0x043A,0x0442)|ForEach-Object {[char]$_}))
    $leaf=Split-Path -Leaf $Parent
    if($leaf -cnotmatch '^(?<phase>develop|release)-(?<capsule>[a-f0-9]{12})-(?<candidate>[a-f0-9]{12})(?<attempt>(?:-[a-f0-9]{8}){0,2})$'){throw 'FIXTURE_RECOVERY_PATH_INVALID'}
    $phase=if($matches.phase -ceq 'release'){'Release'}else{'Develop'}
    if(($phase -ceq 'Release' -and -not $ArchiveInactive) -or ($phase -ceq 'Develop' -and -not $matches.attempt)){throw 'FIXTURE_RECOVERY_PATH_INVALID'}
    $capsulePrefix=$matches.capsule;$candidatePrefix=$matches.candidate
    if((Resolve-QualificationFixtureChild -Root $ProjectsRoot -RelativePath ($segment+'/'+$leaf)) -ine $Parent){throw 'FIXTURE_RECOVERY_PATH_INVALID'}
    $commit=(Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('rev-parse','--verify',($candidatePrefix+'^{commit}'))).stdout.Trim()
    $project=Join-Path $Parent 'project';$branch=Join-Path $Parent 'branch'
    $claimPath=Resolve-QualificationFixtureChild -Root $Parent -RelativePath 'qualification-fixture.json'
    $claim=if(Test-Path -LiteralPath $claimPath){Read-QualificationFixtureJson -Path $claimPath}else{$null}
    if($claim){
        if([int]$claim.schemaVersion -notin @(1,2) -or [string]$claim.kind -cne 'itl-qualification-fixture-target' -or
            [string]$claim.phase -cne $phase -or [string]$claim.projectRoot -ine $project -or [string]$claim.branchRoot -ine $branch -or
            [string]$claim.candidateCommit -cne $commit -or [string]$claim.status -notin @('materializing','preparation-failed','ready','disposed')){throw 'FIXTURE_RECOVERY_CLAIM_INVALID'}
        if([int]$claim.schemaVersion -eq 2 -and ([string]$claim.copyRoot -ine $Parent -or
            [string]$claim.workflowCommonGit -ine (Get-RepositoryCommonGitDirectory -RepositoryRoot $CandidateRoot))){throw 'FIXTURE_RECOVERY_FOREIGN_OWNER'}
    }
    $binding=$null
    if($claim -and [string]$claim.status -eq 'disposed' -and
        ([string]$claim.disposal.status -cne 'disposed' -or [string]$claim.disposal.candidateCommit -cne $commit)){throw 'FIXTURE_RECOVERY_DISPOSAL_PROOF_MISSING'}
    if(-not $ArchiveInactive -and (-not $claim -or [string]$claim.status -eq 'ready')){$binding=Get-SourceE2ECopyReportBinding -CandidateRoot $CandidateRoot -Commit $commit -Parent $Parent}
    if(-not $ArchiveInactive -and $claim -and [string]$claim.status -eq 'ready' -and -not $binding){throw 'FIXTURE_RECOVERY_TERMINAL_PROOF_MISSING'}
    $origin=Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('remote','get-url','origin') -AllowFailure
    $descriptor=$null
    if($origin.exitCode -eq 0){
        $bundle=[IO.Path]::GetFullPath($origin.stdout.Trim())
        if((Split-Path -Leaf $bundle) -cne 'source.bundle'){throw 'FIXTURE_RECOVERY_ORIGIN_INVALID'}
        $path=Resolve-QualificationFixtureChild -Root (Split-Path -Parent $bundle) -RelativePath 'capsule.json'
        $descriptor=@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
    }elseif($binding -and $binding.capsule){$descriptor=$binding.capsule}
    elseif($claim -and [int]$claim.schemaVersion -eq 2 -and $claim.PSObject.Properties['capsulePath']){$descriptor=@{path=[string]$claim.capsulePath;sha256=[string]$claim.capsuleSha256}}
    if(-not $descriptor){
        $priorPath=Resolve-QualificationFixtureChild -Root $DiagnosticRoot -RelativePath 'cleanup-proof.json'
        if(Test-Path -LiteralPath $priorPath){
            $prior=Read-QualificationFixtureJson -Path $priorPath
            if([string]$prior.kind -ceq 'itl-fixture-copy-cleanup-proof' -and [string]$prior.copyRoot -ieq $Parent -and
                [string]$prior.workflowCommonGit -ieq (Get-RepositoryCommonGitDirectory -RepositoryRoot $CandidateRoot) -and [string]$prior.candidateCommit -ceq $commit){$descriptor=$prior.capsule}
        }
    }
    if(-not $descriptor -or -not ([string]$descriptor.sha256).StartsWith($capsulePrefix,[StringComparison]::Ordinal)){throw 'FIXTURE_RECOVERY_CAPSULE_MISSING'}
    $capsule=Read-QualificationFixtureCapsule -ManifestPath $descriptor.path -Sha256 $descriptor.sha256
    if([string]$capsule.phase -cne $phase -or ($claim -and [string]$claim.capsuleSha256 -cne [string]$descriptor.sha256) -or
        (Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('merge-base','--is-ancestor',[string]$capsule.workflowCommit,$commit) -AllowFailure).exitCode -ne 0){throw 'FIXTURE_RECOVERY_SOURCE_MISMATCH'}
    $git=Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('rev-parse','--git-common-dir') -AllowFailure
    $gitValid=$git.exitCode -eq 0
    $branchGit=Join-Path $branch '.git'
    if(Test-Path -LiteralPath $branchGit){
        if(-not (Test-Path -LiteralPath $branchGit -PathType Leaf)){throw 'FIXTURE_COPY_FOREIGN_WORKTREE'}
        $pointer=[IO.File]::ReadAllText($branchGit,[Text.Encoding]::UTF8).Trim()
        if($pointer -notmatch '^gitdir: (.+)$'){throw 'FIXTURE_COPY_FOREIGN_WORKTREE'}
        $gitDirectory=$matches[1];if(-not [IO.Path]::IsPathRooted($gitDirectory)){$gitDirectory=Join-Path $branch $gitDirectory}
        $expected=[IO.Path]::GetFullPath((Join-Path $project '.git/worktrees')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not [IO.Path]::GetFullPath($gitDirectory).StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_COPY_FOREIGN_WORKTREE'}
    }
    if(-not $claim){$claim=[pscustomobject]@{schemaVersion=0;status='unclaimed';phase=$phase;projectRoot=$project;branchRoot=$branch;candidateCommit=$commit;capsuleSha256=$descriptor.sha256}}
    $snapshotRecord=@($capsule.files|Where-Object path -eq 'infobase.dt')[0]
    $proof=@{kind='itl-fixture-copy-cleanup-proof';reason=$(if($ArchiveInactive){'archive-inactive-qualification'}elseif($binding){$binding.kind}else{'incomplete-develop-factory'});phase=$phase;copyRoot=$Parent;workflowCommonGit=(Get-RepositoryCommonGitDirectory -RepositoryRoot $CandidateRoot);candidateCommit=$commit;capsule=$descriptor;terminalReport=$binding}
    return @{parent=$Parent;prefix=($Parent+[IO.Path]::DirectorySeparatorChar);claim=$claim;claimPath=$claimPath;
        archivedClaim=(Join-Path $DiagnosticRoot $(if([int]$claim.schemaVersion -eq 0){'recovered-ownership.json'}else{'qualification-fixture.json'}));
        report=$proof;legacy=$true;recovered=$true;archiveInactive=[bool]$ArchiveInactive;gitValid=$gitValid;seedSnapshot=(Join-Path (Split-Path -Parent $descriptor.path) 'infobase.dt');seedSnapshotSha256=[string]$snapshotRecord.sha256}
}

function Save-SourceE2ECopyRecoveryArchive {
    param([object]$Context,[object[]]$Files,[string]$DiagnosticRoot)
    Add-Type -AssemblyName System.IO.Compression
    [void][IO.Directory]::CreateDirectory($DiagnosticRoot)
    $path=Resolve-QualificationFixtureChild -Root $DiagnosticRoot -RelativePath 'recovery.zip'
    $indexPath=Resolve-QualificationFixtureChild -Root $DiagnosticRoot -RelativePath 'recovery-index.json'
    if(Test-Path -LiteralPath $path){
        # A failed recursive removal can leave only a subset of the copy.
        # Keep the first complete archive rather than overwriting it with that subset.
        $prior=Read-QualificationFixtureJson -Path (Join-Path $DiagnosticRoot 'cleanup-proof.json')
        if([string]$prior.copyRoot -ine $Context.parent -or [string]$prior.candidateCommit -cne [string]$Context.claim.candidateCommit){throw 'FIXTURE_RECOVERY_ARCHIVE_FOREIGN'}
        $saved=Read-QualificationFixtureJson -Path $indexPath;$records=@{}
        $stream=[IO.File]::OpenRead($path);$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read)
        try {
            foreach($record in $saved){
                $records[[string]$record.path]=$record
                $input=if($record.retainedSource){[IO.File]::OpenRead($record.retainedSource)}else{$zip.GetEntry($record.path).Open()}
                $hash=[Security.Cryptography.SHA256]::Create()
                try {$actual=[BitConverter]::ToString($hash.ComputeHash($input)).Replace('-','').ToLowerInvariant()}finally{$input.Dispose();$hash.Dispose()}
                if($actual -cne $record.sha256){throw "FIXTURE_RECOVERY_ARCHIVE_CHANGED: $($record.path); expected=$($record.sha256); actual=$actual"}
            }
            foreach($file in $Files){
                $relative=$file.FullName.Substring($Context.prefix.Length).Replace('\','/')
                # The immutable archive keeps the original claim. The current
                # owner may only add its disposal receipt; copy it separately.
                if($Context.archiveInactive -and $relative -ceq 'qualification-fixture.json'){continue}
                if(-not $Context.archiveInactive -and $relative -match '^(project|branch)/\.git(?:/|$)' -and (Test-Path -LiteralPath (Join-Path $DiagnosticRoot 'source.bundle'))){continue}
                if(-not $records.ContainsKey($relative) -or (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant() -cne $records[$relative].sha256){throw 'FIXTURE_RECOVERY_COPY_CHANGED: preserve both the original archive and the remaining copy'}
            }
        }finally{$zip.Dispose();$stream.Dispose()}
        return
    }
    $temporary=Resolve-QualificationFixtureChild -Root $DiagnosticRoot -RelativePath ('recovery-'+[guid]::NewGuid().ToString('N')+'.tmp.zip')
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    $index=[Collections.Generic.List[object]]::new()
    try {
        foreach($file in $Files){
            $relative=$file.FullName.Substring($Context.prefix.Length).Replace('\','/')
            if($Context.gitValid -and -not $Context.archiveInactive -and $relative -match '^(project|branch)/\.git(?:/|$)'){continue}
            $sha=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
            if($relative -eq 'branch/.agent-1c/snapshots/qualification-fixtures/seed.dt' -and $sha -ceq $Context.seedSnapshotSha256){
                $index.Add(@{path=$relative;sha256=$sha;retainedSource=$Context.seedSnapshot});continue
            }
            $entry=$zip.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
            $output=$entry.Open();$input=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {$input.CopyTo($output)}finally{$input.Dispose();$output.Dispose()}
            $index.Add(@{path=$relative;sha256=$sha;retainedSource=$null})
        }
    }finally{$zip.Dispose();$stream.Dispose()}
    $stream=[IO.File]::OpenRead($temporary);$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach($record in $index){
            if($record.retainedSource){continue}
            $input=$zip.GetEntry($record.path).Open();$hash=[Security.Cryptography.SHA256]::Create()
            try {$actual=[BitConverter]::ToString($hash.ComputeHash($input)).Replace('-','').ToLowerInvariant()}finally{$input.Dispose();$hash.Dispose()}
            if($actual -cne $record.sha256){throw 'FIXTURE_RECOVERY_ARCHIVE_CHANGED'}
        }
    }finally{$zip.Dispose();$stream.Dispose()}
    Write-QualificationFixtureJson -Path $indexPath -Value @($index)
    Write-QualificationFixtureJson -Path (Join-Path $DiagnosticRoot 'cleanup-proof.json') -Value $Context.report
    Move-Item -LiteralPath $temporary -Destination $path -ErrorAction Stop
}
