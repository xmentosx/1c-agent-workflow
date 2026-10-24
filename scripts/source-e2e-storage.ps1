# Source-only storage owner for disposable Develop qualification copies.
# Uses the existing fixture claim, process owner and gate output retention.
function Get-SourceE2EVolumeSpace {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    while(-not (Test-Path -LiteralPath $full)){ $next=Split-Path -Parent $full; if(-not $next -or $next -eq $full){throw "Cannot resolve volume for $Path"}; $full=$next }
    if(Test-Path -LiteralPath $full -PathType Leaf){$full=Split-Path -Parent $full}
    if($env:OS -eq 'Windows_NT'){
        if(-not ('ItlSourceStorageNative' -as [type])){
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ItlSourceStorageNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool GetDiskFreeSpaceEx(string path, out ulong available, out ulong total, out ulong free);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool GetVolumePathName(string path, StringBuilder volume, uint length);
}
'@
        }
        $volume=[Text.StringBuilder]::new(1024);[uint64]$available=0;[uint64]$total=0;[uint64]$free=0
        if(-not [ItlSourceStorageNative]::GetVolumePathName($full,$volume,1024) -or
            -not [ItlSourceStorageNative]::GetDiskFreeSpaceEx($full,[ref]$available,[ref]$total,[ref]$free)){throw "Cannot read free space for $Path (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"}
        return [pscustomobject]@{volume=$volume.ToString();availableBytes=[int64]$available}
    }
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
    return [pscustomobject]@{volume=$drive.Name;availableBytes=[int64]$drive.AvailableFreeSpace}
}

function Assert-SourceE2ESpace {
    param([object[]]$Allocations, [string]$Operation, [string]$Continuation='Run scripts/source-delivery.ps1 -Action Cleanup; free the reported volume if still needed, then repeat the same PublishDevelop -ResumePlan command.')
    $volumes=@{}
    foreach($allocation in $Allocations){
        if([int64]$allocation.bytes -le 0){continue}
        try {$space=Get-SourceE2EVolumeSpace -Path $allocation.path}
        catch {Write-Warning "E2E space measurement unavailable: $($_.Exception.Message). Native disk diagnostics remain active.";continue}
        if(-not $volumes.ContainsKey($space.volume)){$volumes[$space.volume]=@{requiredBytes=0L;availableBytes=$space.availableBytes}}
        $volumes[$space.volume].requiredBytes += [int64]$allocation.bytes
    }
    foreach($volume in $volumes.Keys){
        $v=$volumes[$volume]
        if($v.availableBytes -lt $v.requiredBytes){
            throw "SOURCE_E2E_SPACE_INSUFFICIENT: $Operation; volume=$volume requiredBytes=$($v.requiredBytes) availableBytes=$($v.availableBytes). Queue/checkpoint and passed proof are preserved. $Continuation"
        }
    }
}

function Open-SourceE2EFixtureUse {
    param([string]$ProjectRoot)
    $parent=Split-Path -Parent ([IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/'))
    if(-not (Test-Path -LiteralPath $parent -PathType Container)){throw 'FIXTURE_COPY_MISSING'}
    $lease=Resolve-QualificationFixtureChild -Root (Split-Path -Parent $parent) -RelativePath ((Split-Path -Leaf $parent)+'.fixture-use.lease')
    try {return [IO.File]::Open($lease,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch {throw "FIXTURE_COPY_IN_USE: $parent; retain the copy and repeat after its current owner exits."}
}

. (Join-Path $PSScriptRoot 'source-e2e-copy-recovery.ps1')

function Get-SourceE2EFixtureCopyContext {
    param([object]$Fixture, [string]$CandidateRoot, [string]$ReportPath, [string]$DiagnosticRoot, [switch]$LegacyCleanup, [string]$ProjectsRoot, [switch]$RecoveryCleanup, [switch]$ArchiveInactive)
    $parent=Split-Path -Parent ([IO.Path]::GetFullPath([string]$Fixture.projectRoot).TrimEnd('\','/'))
    $prefix=$parent+[IO.Path]::DirectorySeparatorChar
    foreach($external in @($ReportPath,$DiagnosticRoot)){
        if([IO.Path]::GetFullPath($external) -ieq $parent -or [IO.Path]::GetFullPath($external).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_COPY_EVIDENCE_INSIDE_TARGET'}
    }
    if($ArchiveInactive -and -not $RecoveryCleanup){throw 'FIXTURE_ARCHIVE_REQUIRES_RECOVERY_CONTEXT'}
    if($RecoveryCleanup){return Get-SourceE2ECopyRecoveryContext -Parent $parent -ProjectsRoot $ProjectsRoot -CandidateRoot $CandidateRoot -DiagnosticRoot $DiagnosticRoot -ArchiveInactive:$ArchiveInactive}
    # Persisted terminal proof is a prerequisite. Failed Develop repeats from the
    # immutable seed; its diagnostic bundle stays with the existing gate logs.
    $report=if($LegacyCleanup){$null}else{Read-QualificationFixtureJson -Path $ReportPath}
    $claimPath=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'qualification-fixture.json'
    $archivedClaim=Join-Path $DiagnosticRoot 'qualification-fixture.json'
    $claim=Read-QualificationFixtureJson -Path $(if(Test-Path -LiteralPath $claimPath){$claimPath}else{$archivedClaim})
    if($LegacyCleanup){
        # Version 1 has no workflowCommonGit/terminal record. Its completed
        # database-disposal receipt is the terminal owner proof, not a test pass.
        # Validate the installed package against this source repository before
        # allowing the same copy remover to archive the remaining source data.
        $safe=Resolve-QualificationFixtureChild -Root $ProjectsRoot -RelativePath ('q Проект/'+(Split-Path -Leaf $parent))
        if($safe -ine $parent -or [int]$claim.schemaVersion -ne 1 -or
            [string]$claim.kind -cne 'itl-qualification-fixture-target' -or [string]$claim.phase -cne 'Develop' -or
            [string]$claim.status -cne 'disposed' -or [string]$claim.disposal.status -cne 'disposed' -or
            [string]$claim.disposal.candidateCommit -cne [string]$claim.candidateCommit -or
            [string]$claim.projectRoot -ine (Join-Path $parent 'project') -or [string]$claim.branchRoot -ine (Join-Path $parent 'branch') -or
            [string]$Fixture.branchRoot -ine [string]$claim.branchRoot -or [string]$Fixture.claim.candidateCommit -cne [string]$claim.candidateCommit -or
            [string]$claim.candidateCommit -cnotmatch '^[a-f0-9]{40}$' -or [string]$claim.capsuleSha256 -cnotmatch '^[a-f0-9]{64}$' -or
            (Split-Path -Leaf $parent) -cnotmatch ('^develop-'+([string]$claim.capsuleSha256).Substring(0,12)+'-'+([string]$claim.candidateCommit).Substring(0,12)+'-[a-f0-9]{8}(?:-[a-f0-9]{8})?$')){throw 'FIXTURE_LEGACY_OWNERSHIP_INVALID'}
        [void][DateTimeOffset]::Parse([string]$claim.disposal.finishedAt,[Globalization.CultureInfo]::InvariantCulture)
        if(@($claim.disposal.removedDatabases).Count -eq 0){throw 'FIXTURE_LEGACY_DISPOSAL_MISSING'}
        foreach($database in $claim.disposal.removedDatabases){
            $db=[IO.Path]::GetFullPath([string]$database.path)
            if(-not $db.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $db) -ine '1Cv8.1CD' -or (Test-Path -LiteralPath $db)){throw 'FIXTURE_LEGACY_DISPOSAL_INVALID'}
        }
        $lockPath=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'project/.agent-1c/dependency-lock.json'
        $package=(Read-QualificationFixtureJson -Path $lockPath).dependencies.workflowPackage
        $origin=(Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('remote','get-url','origin')).stdout.Trim()
        if([string]$package.repo -cne $origin -or [string]$package.commit -cnotmatch '^[a-f0-9]{40}$'){throw 'FIXTURE_LEGACY_SOURCE_MISMATCH'}
        $ancestry=Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('merge-base','--is-ancestor',[string]$package.commit,[string]$claim.candidateCommit) -AllowFailure
        if($ancestry.exitCode -ne 0){throw 'FIXTURE_LEGACY_SOURCE_MISMATCH'}
        return @{parent=$parent;prefix=$prefix;claim=$claim;claimPath=$claimPath;archivedClaim=$archivedClaim;report=$null;legacy=$true}
    }
    if(-not $claim.PSObject.Properties['schemaVersion'] -or [int]$claim.schemaVersion -ne 2 -or
        [string]$claim.kind -cne 'itl-qualification-fixture-target' -or [string]$claim.phase -cne 'Develop' -or
        [string]$claim.status -notin @('materializing','preparation-failed','ready','disposed') -or [string]$claim.copyRoot -ine $parent -or
        [string]$claim.projectRoot -ine (Join-Path $parent 'project') -or [string]$claim.branchRoot -ine (Join-Path $parent 'branch') -or
        [string]$Fixture.branchRoot -ine [string]$claim.branchRoot -or [string]$Fixture.claim.candidateCommit -cne [string]$claim.candidateCommit -or
        [string]$report.candidate.commit -cne [string]$claim.candidateCommit -or [string]$report.status -notin @('passed','failed') -or
        [string]$claim.workflowCommonGit -ine (Get-RepositoryCommonGitDirectory -RepositoryRoot $CandidateRoot)){
        throw 'FIXTURE_COPY_OWNERSHIP_INVALID: preserve legacy/foreign/resumable copies and inspect their original owner receipt.'
    }
    if([string]$claim.candidateCommit -cnotmatch '^[a-f0-9]{40}$' -or [string]$claim.capsuleSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        (Split-Path -Leaf $parent) -cnotmatch ('^develop-'+([string]$claim.capsuleSha256).Substring(0,12)+'-'+([string]$claim.candidateCommit).Substring(0,12)+'-[a-f0-9]{8}(?:-[a-f0-9]{8})?$')){throw 'FIXTURE_COPY_PATH_INVALID'}
    $safe=Resolve-QualificationFixtureChild -Root ([string]$claim.projectsRoot) -RelativePath $parent.Substring(([string]$claim.projectsRoot).TrimEnd('\','/').Length+1)
    if($safe -ine $parent){throw 'FIXTURE_COPY_PATH_INVALID'}
    return @{parent=$parent;prefix=$prefix;claim=$claim;claimPath=$claimPath;archivedClaim=$archivedClaim;report=$report;legacy=$false}
}

function Write-SourceE2EFixtureTerminal {
    param([object]$Fixture,[string]$CandidateRoot,[string]$ReportPath,[AllowNull()][object]$UseLease)
    $context=Get-SourceE2EFixtureCopyContext -Fixture $Fixture -CandidateRoot $CandidateRoot -ReportPath $ReportPath -DiagnosticRoot (Split-Path -Parent $ReportPath)
    $localLease=$null
    try {
        if($UseLease){
            $expected=$context.parent+'.fixture-use.lease'
            if(-not $UseLease.CanWrite -or $UseLease.Name -ine $expected){throw 'FIXTURE_TERMINAL_LEASE_MISMATCH'}
        }else{$localLease=Open-SourceE2EFixtureUse -ProjectRoot $Fixture.projectRoot}
        $terminal=$context.report
        $terminal|Add-Member -NotePropertyName originalReportPath -NotePropertyValue $ReportPath -Force
        $terminal|Add-Member -NotePropertyName originalReportSha256 -NotePropertyValue (Get-FileHash -LiteralPath $ReportPath).Hash.ToLowerInvariant() -Force
        $context.claim|Add-Member -NotePropertyName terminal -NotePropertyValue $terminal -Force
        Write-QualificationFixtureJson -Path $context.claimPath -Value $context.claim
    } finally {if($localLease){$localLease.Dispose()}}
}

function Get-SourceE2EFixtureReaderInventory {
    # Never treat a partial/failed query as an empty reader list. One fresh
    # retry tolerates transient WMI load; persistent failure retains the copy.
    for($attempt=1;$attempt -le 2;$attempt++) {
        try {
            $rows=@(Get-CimInstance -ClassName Win32_Process -Property ProcessId,CommandLine -OperationTimeoutSec 2 -ErrorAction Stop)
            return $rows
        } catch {
            if($attempt -eq 2) {throw "FIXTURE_COPY_PROCESS_INVENTORY_UNAVAILABLE: preserve the copy and repeat the same cleanup when CIM responds. $($_.Exception.Message)"}
        }
    }
}

function Remove-SourceE2EFixtureCopy {
    param([object]$Fixture,[string]$CandidateRoot,[string]$ReportPath,[string]$DiagnosticRoot,[switch]$LegacyCleanup,[string]$ProjectsRoot,[switch]$RecoveryCleanup,[switch]$ArchiveInactive)
    $context=Get-SourceE2EFixtureCopyContext @PSBoundParameters
    $parent=$context.parent;$prefix=$context.prefix;$claim=$context.claim;$claimPath=$context.claimPath;$archivedClaim=$context.archivedClaim;$report=$context.report
    if(-not $RecoveryCleanup -and [string]$claim.status -cne 'disposed'){throw 'FIXTURE_COPY_DATABASE_NOT_DISPOSED: complete the recorded database-owner disposal first'}
    if(-not (Test-Path -LiteralPath $parent)){return @{status='removed';root=$parent;diagnostics=$DiagnosticRoot;alreadyRemoved=$true}}
    $lease=Open-SourceE2EFixtureUse -ProjectRoot ([string]$claim.projectRoot)
    try {
        if($RecoveryCleanup){
            # Preparation may finish between discovery and admission. Rebind
            # under the same lease before deciding whether its base is disposable.
            $context=Get-SourceE2EFixtureCopyContext @PSBoundParameters
            $claim=$context.claim;$report=$context.report
        }
        if($ArchiveInactive){
            $ledgerPath=Join-Path (Get-RepositoryCommonGitDirectory -RepositoryRoot $CandidateRoot) 'itl/resources/v1/ledger.json'
            if(Test-Path -LiteralPath $ledgerPath){
                $ledger=Read-QualificationFixtureJson -Path $ledgerPath
                foreach($resource in @($ledger.resources|Where-Object {$_.state -in @('active','retained')})){
                    if(-not $resource.identity.PSObject.Properties['path'] -or -not [string]$resource.identity.path){continue}
                    $preserved=[IO.Path]::GetFullPath([string]$resource.identity.path).TrimEnd('\','/')
                    if($parent -ieq $preserved -or $parent.StartsWith($preserved+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $preserved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_COPY_PRESERVED: active or retained owner reference'}
                }
            }
        }
        if((Test-Path -LiteralPath (Join-Path $parent 'project/.git')) -and (-not $RecoveryCleanup -or $context.gitValid)){
            $common=Get-RepositoryCommonGitDirectory -RepositoryRoot $claim.projectRoot
            if($common -ine (Join-Path $parent 'project/.git')){throw 'FIXTURE_COPY_GIT_OUTSIDE_TARGET'}
            foreach($row in @(Get-RepositoryGitPathList -RepositoryRoot $claim.projectRoot -Arguments @('worktree','list','--porcelain','-z'))){
                if($row.StartsWith('worktree ') -and -not ([IO.Path]::GetFullPath($row.Substring(9))).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_COPY_FOREIGN_WORKTREE'}
            }
            if((Test-Path -LiteralPath (Join-Path $parent 'branch/.git')) -and (Get-RepositoryCommonGitDirectory -RepositoryRoot $claim.branchRoot) -ine $common){throw 'FIXTURE_COPY_FOREIGN_WORKTREE'}
        }
        if($env:OS -eq 'Windows_NT'){
            # Independent copies have independent roots. Never terminate a reader
            # to make cleanup possible, including an editor opened on this copy.
            $readers=@(Get-SourceE2EFixtureReaderInventory|Where-Object {
                $_.ProcessId -ne $PID -and [string]$_.CommandLine -and
                (([string]$_.CommandLine).IndexOf($parent,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                 ($RecoveryCleanup -and (Test-SourceE2ECopyProducerCommand -CommandLine $_.CommandLine -ProjectsRoot $ProjectsRoot)))
            })
            if($readers.Count){throw 'FIXTURE_COPY_IN_USE: a live process still references this exact copy'}
        }
        $directories=[Collections.Generic.Stack[string]]::new();$directories.Push($parent)
        $files=[Collections.Generic.List[object]]::new();[int64]$bytes=0
        while($directories.Count){
            foreach($item in @(Get-ChildItem -LiteralPath $directories.Pop() -Force)){
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FIXTURE_REPARSE_POINT'}
                if($item.PSIsContainer){$directories.Push($item.FullName)}else{
                    if($item.Name -ieq '1Cv8.1CD' -and -not $RecoveryCleanup){throw 'FIXTURE_COPY_DATABASE_NOT_DISPOSED'}
                    $relative=$item.FullName.Substring($prefix.Length).Replace('\','/')
                    if($relative -match '^(project|branch)/\.agent-1c/.*/checkpoint\.json$'){throw 'FIXTURE_COPY_RESUMABLE: producer checkpoint is still present'}
                    if($relative -match '^(project|branch)/\.agent-1c/execution-checkpoints/.*\.json$'){
                        $checkpoint=Read-QualificationFixtureJson -Path $item.FullName
                        if([string]$checkpoint.status -cne 'resumed'){throw 'FIXTURE_COPY_RESUMABLE: execution checkpoint is not resumed'}
                    }
                    $files.Add($item);$bytes += $item.Length
                }
            }
        }
        if($RecoveryCleanup){
            $databases=@($files|Where-Object Name -ieq '1Cv8.1CD')
            if($ArchiveInactive){Save-SourceE2ECopyRecoveryArchive -Context $context -Files @($files) -DiagnosticRoot $DiagnosticRoot}
            if($databases.Count){
                if(-not $ArchiveInactive -and [string]$claim.status -notin @('materializing','preparation-failed')){throw 'FIXTURE_RECOVERY_DATABASE_RETAINED'}
                # Only the existing exact-infobase owner can dispose a failed
                # factory database. Its admission and exclusive handle still bind.
                $disposalArguments=@('-Operation','Dispose','-ExpectedCandidate',[string]$claim.candidateCommit,'-OutputPath',(Join-Path $DiagnosticRoot 'database-disposal.json'))
                if($ArchiveInactive){$disposalArguments+=@('-ArchivedInactive','-RecoveryArchiveIndex',(Join-Path $DiagnosticRoot 'recovery-index.json'))}
                $null=Invoke-SourceFixtureInstalledAction -Root $claim.branchRoot -Action 'qualification-create-infobase' -Arguments $disposalArguments -LogRoot (Join-Path $DiagnosticRoot 'database-disposal-logs') -TimeoutSeconds 180
                if(@($databases|Where-Object {Test-Path -LiteralPath $_.FullName}).Count){throw 'FIXTURE_RECOVERY_DATABASE_RETAINED'}
                foreach($database in $databases){[void]$files.Remove($database)}
                $claim=Read-QualificationFixtureJson -Path $context.claimPath
            }
            if(-not $ArchiveInactive){Save-SourceE2ECopyRecoveryArchive -Context $context -Files @($files) -DiagnosticRoot $DiagnosticRoot}
            if($ArchiveInactive){
                # The full archive includes raw Git/index/merge state and every
                # database. Do not manufacture a terminal test result or duplicate
                # its trees as patches/untracked files beside that archive.
                Write-QualificationFixtureJson -Path $archivedClaim -Value $claim
                Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction Stop
                return @{status='archived-inactive';root=$parent;removedBytes=$bytes;diagnostics=$DiagnosticRoot}
            }
        }
        foreach($file in $files){
            $relative=$file.FullName.Substring($prefix.Length)
            if($relative -eq 'qualification-fixture.json' -or $relative.Replace('\','/') -match '^(preparation-logs/|(?:project|branch)/(?:\.dev\.env$|logs/|\.agent-1c/(?:[^/]+\.json$|(?:runs|dev-branches|execution-checkpoints)/)))'){
                $dest=Resolve-QualificationFixtureChild -Root $DiagnosticRoot -RelativePath $relative
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest));Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
                if((Get-FileHash -LiteralPath $dest).Hash -cne (Get-FileHash -LiteralPath $file.FullName).Hash){throw 'FIXTURE_COPY_DIAGNOSTICS_CHANGED'}
            }
        }
        # Keep the claim outside the removed tree, including partial-delete retry.
        Write-QualificationFixtureJson -Path $archivedClaim -Value $claim
        if(($context.legacy -or [string]$report.status -eq 'failed') -and (Test-Path -LiteralPath (Join-Path $parent 'project/.git')) -and (-not $RecoveryCleanup -or $context.gitValid)){
            # Preserve derived/reflog-only pending commits without retaining the
            # tools, database or a second copy of the original sealed snapshot.
            Invoke-RepositoryGit -RepositoryRoot $claim.projectRoot -Arguments @('bundle','create',(Join-Path $DiagnosticRoot 'source.bundle'),'--all','--reflog')|Out-Null
            foreach($role in @('project','branch')){
                $tree=Join-Path $parent $role
                if(Test-Path -LiteralPath (Join-Path $tree '.git')){
                    $patch=(Invoke-RepositoryGit -RepositoryRoot $tree -Arguments @('diff','--binary','--no-ext-diff','--no-textconv','HEAD')).stdout
                    Write-Utf8Text -Path (Join-Path $DiagnosticRoot ($role+'-working.patch')) -Value $patch
                    foreach($relative in @(Get-RepositoryGitPathList -RepositoryRoot $tree -Arguments @('ls-files','--others','--exclude-standard','-z'))){
                        $source=Resolve-QualificationFixtureChild -Root $tree -RelativePath $relative
                        $dest=Resolve-QualificationFixtureChild -Root $DiagnosticRoot -RelativePath ($role+'/untracked/'+$relative)
                        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest));Copy-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop
                        if((Get-FileHash -LiteralPath $dest).Hash -cne (Get-FileHash -LiteralPath $source).Hash){throw 'FIXTURE_COPY_DIAGNOSTICS_CHANGED'}
                    }
                }
            }
        }
        # Canonical root and every descendant were checked before recursive
        # removal; the sibling lease fences other callers through deletion.
        Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction Stop
        return @{status='removed';root=$parent;removedBytes=$bytes;diagnostics=$DiagnosticRoot}
    } finally {
        $leasePath=$lease.Name;$lease.Dispose()
        Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-CompletedSourceE2ECopies {
    param([string]$ProjectsRoot,[string]$CandidateRoot,[string]$DiagnosticRoot,[switch]$IncludeLegacy,[string[]]$PreservePaths=@())
    $container=Resolve-QualificationFixtureChild -Root $ProjectsRoot -RelativePath 'q Проект'
    $removed=0;$retained=0;[int64]$removedBytes=0;$entries=[Collections.Generic.List[object]]::new()
    if(-not (Test-Path -LiteralPath $container -PathType Container)){return @{removed=0;retained=0;removedBytes=0;entries=@()}}
    $common=Get-RepositoryCommonGitDirectory -RepositoryRoot $CandidateRoot
    foreach($directory in @(Get-ChildItem -LiteralPath $container -Directory -Force)){
        if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){$retained++;$entries.Add(@{root=$directory.FullName;status='retained';reason='FIXTURE_REPARSE_POINT'});continue}
        $claimPath=Join-Path $directory.FullName 'qualification-fixture.json'
        try {
            $claim=if(Test-Path -LiteralPath $claimPath -PathType Leaf){Read-QualificationFixtureJson -Path $claimPath}else{$null}
            foreach($preserved in $PreservePaths){
                $p=[IO.Path]::GetFullPath($preserved).TrimEnd('\','/')
                if($directory.FullName -ieq $p -or $p.StartsWith($directory.FullName+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $directory.FullName.StartsWith($p+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_COPY_PRESERVED: active or retained owner reference'}
            }
            $legacy=$IncludeLegacy -and $claim -and [int]$claim.schemaVersion -eq 1 -and [string]$claim.phase -eq 'Develop' -and [string]$claim.status -eq 'disposed'
            if($legacy){
                $diagnostics=Resolve-QualificationFixtureChild -Root $DiagnosticRoot -RelativePath $directory.Name
                $result=Remove-SourceE2EFixtureCopy -Fixture @{projectRoot=$claim.projectRoot;branchRoot=$claim.branchRoot;claim=$claim} -CandidateRoot $CandidateRoot -ReportPath (Join-Path $diagnostics 'disposal.json') -DiagnosticRoot $diagnostics -LegacyCleanup -ProjectsRoot $ProjectsRoot
                $removed++;$removedBytes += $result.removedBytes;$entries.Add($result);continue
            }
            $disposalRetry=$claim -and [int]$claim.schemaVersion -eq 2 -and [string]$claim.status -eq 'disposed' -and -not $claim.PSObject.Properties['terminal']
            if($IncludeLegacy -and (-not $claim -or ([string]$claim.phase -eq 'Develop' -and ([string]$claim.status -in @('materializing','preparation-failed','ready') -or $disposalRetry)))){
                $diagnostics=Resolve-QualificationFixtureChild -Root $DiagnosticRoot -RelativePath $directory.Name
                $result=Remove-SourceE2EFixtureCopy -Fixture @{projectRoot=(Join-Path $directory.FullName 'project')} -CandidateRoot $CandidateRoot -ReportPath (Join-Path $diagnostics 'cleanup-proof.json') -DiagnosticRoot $diagnostics -RecoveryCleanup -ProjectsRoot $ProjectsRoot
                $removed++;$removedBytes += $result.removedBytes;$entries.Add($result);continue
            }
            if(-not $claim){throw 'FIXTURE_COPY_CLAIM_MISSING'}
            if(-not $claim.PSObject.Properties['schemaVersion'] -or [int]$claim.schemaVersion -ne 2 -or
                [string]$claim.phase -ne 'Develop' -or [string]$claim.status -ne 'disposed' -or
                [string]$claim.workflowCommonGit -ine $common -or -not $claim.PSObject.Properties['terminal']){
                $retained++;$entries.Add(@{root=$directory.FullName;status='retained';reason='FIXTURE_COPY_NOT_TERMINAL_OR_NOT_OWNED'});continue
            }
            $diagnostics=Resolve-QualificationFixtureChild -Root $DiagnosticRoot -RelativePath $directory.Name
            $report=Join-Path $diagnostics 'terminal-report.json'
            Write-QualificationFixtureJson -Path $report -Value $claim.terminal
            $result=Remove-SourceE2EFixtureCopy -Fixture @{projectRoot=$claim.projectRoot;branchRoot=$claim.branchRoot;claim=$claim} -CandidateRoot $CandidateRoot -ReportPath $report -DiagnosticRoot $diagnostics
            $removed++;$removedBytes += $result.removedBytes;$entries.Add($result)
        } catch {$retained++;$entries.Add(@{root=$directory.FullName;status='retained';reason=$_.Exception.Message});Write-Warning "Completed fixture copy retained: $($directory.FullName); $($_.Exception.Message)"}
    }
    return @{removed=$removed;retained=$retained;removedBytes=$removedBytes;entries=@($entries)}
}

function Read-SourceE2EOutputTail {
    param([string]$Path, [switch]$Complete)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return ''}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        [void]$stream.Seek([math]::Max(0,$stream.Length-32768),[IO.SeekOrigin]::Begin)
        $data=New-Object byte[] ([int]($stream.Length-$stream.Position));$count=$stream.Read($data,0,$data.Length)
        # A tail may start inside a UTF-8 code point; skip only its continuation.
        $offset=0;while($offset -lt $count -and ($data[$offset] -band 0xC0) -eq 0x80){$offset++}
        $decoder=[Text.UTF8Encoding]::new($false,$true).GetDecoder()
        $chars=New-Object char[] $count;[int]$bytesUsed=0;[int]$charsUsed=0;[bool]$completed=$false
        $decoder.Convert($data,$offset,$count-$offset,$chars,0,$chars.Length,[bool]$Complete,[ref]$bytesUsed,[ref]$charsUsed,[ref]$completed)
        return [string]::new($chars,0,$charsUsed)
    } catch [Text.DecoderFallbackException] {
        throw "SOURCE_E2E_UTF8_TRANSPORT_INVALID: $Path; retain native output and diagnose the shared child-process encoding before retry."
    } finally {$stream.Dispose()}
}

function Get-SourceE2EDiskWindowText {
    param([object]$Process)
    if($env:OS -ne 'Windows_NT' -or $Process.HasExited){return ''}
    if(-not ('ItlSourceDiskWindows' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class ItlSourceDiskWindows {
    private delegate bool EnumProc(IntPtr window, IntPtr unused);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr unused);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr unused);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr size, StringBuilder text, uint flags, uint timeout, out IntPtr result);
    public static string Read(int pid, int budget) {
        var text=new StringBuilder();var watch=Stopwatch.StartNew();int count=0;
        EnumProc read=(window,unused)=>{
            uint owner;GetWindowThreadProcessId(window,out owner);
            if(owner!=(uint)pid)return true;
            if(watch.ElapsedMilliseconds>=budget || count++>=64)return false;
            var value=new StringBuilder(4096);IntPtr result;
            SendMessageTimeout(window,13,(IntPtr)4096,value,3,100,out result);
            text.AppendLine(value.ToString());return true;
        };
        EnumWindows((window,unused)=>{
            uint owner;GetWindowThreadProcessId(window,out owner);
            if(owner==(uint)pid){if(!read(window,unused))return false;EnumChildWindows(window,read,IntPtr.Zero);}
            return watch.ElapsedMilliseconds<budget && count<64;
        },IntPtr.Zero);
        return text.ToString();
    }
}
'@
    }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $created=$Process.StartTime.ToUniversalTime()
    $identities=@([pscustomobject]@{processId=$Process.Id;createdAt=$created})+@(Get-DeliveryDescendantProcessIdentities -RootProcessId $Process.Id -RootCreatedAt $created)
    $texts=[Collections.Generic.List[string]]::new()
    foreach($identity in @($identities|Select-Object -First 32)){
        if($watch.ElapsedMilliseconds -ge 3000){break}
        if(Test-DeliveryProcessCreationIdentity -ProcessId $identity.processId -CreatedAt $identity.createdAt){
            $value=[ItlSourceDiskWindows]::Read($identity.processId,[int][math]::Min(2000,3000-$watch.ElapsedMilliseconds))
            if(Test-DeliveryProcessCreationIdentity -ProcessId $identity.processId -CreatedAt $identity.createdAt){$texts.Add($value)}
        }
    }
    return $texts -join "`n"
}

function Assert-SourceE2ENativeDisk {
    param([object]$Process, [string[]]$LogPaths, [string]$EvidencePath, [string[]]$VolumePaths, [switch]$InspectWindows)
    $pattern='(?i)112\s*\(\s*0x0*70\)|\berror\s*(?:code)?\s*[=:]?\s*112\b|на устройстве нет свободного места|недостаточно места на диске|not enough space on (?:the )?disk|disk (?:is )?full|no space left on device'
    $evidence=[Collections.Generic.List[object]]::new()
    foreach($path in $LogPaths){$text=Read-SourceE2EOutputTail -Path $path -Complete:($Process -and $Process.HasExited);if($text -match $pattern){$evidence.Add(@{source=$path;text=$text})}}
    if($InspectWindows -and $Process -and -not $Process.HasExited){
        try {$text=Get-SourceE2EDiskWindowText -Process $Process}catch {Write-Verbose "Owned disk dialog probe unavailable: $($_.Exception.Message)";$text=''}
        if($text -match $pattern){$evidence.Add(@{source='owned-process-windows';text=$text})}
    }
    if(-not $evidence.Count){return}
    $volumes=@(foreach($path in $VolumePaths){try {Get-SourceE2EVolumeSpace -Path $path}catch {}})
    $writeFailure=''
    try {Write-QualificationFixtureJson -Path $EvidencePath -Value @{kind='itl-source-e2e-disk-full';code=112;recordedAt=[DateTime]::UtcNow.ToString('o');evidence=$evidence.ToArray();volumes=$volumes}}
    catch {$writeFailure=" Evidence write failed: $($_.Exception.Message); confirmed text=$(([string]$evidence[0].text).Substring(0,[math]::Min(2048,([string]$evidence[0].text).Length)))"}
    throw "SOURCE_E2E_DISK_FULL: Windows error112; evidence=$EvidencePath.$writeFailure Stop this owned child through its process owner; queue/checkpoint and passed proof remain valid. Free the reported volume using scripts/source-delivery.ps1 -Action Cleanup, then repeat the same PublishDevelop -ResumePlan command."
}
