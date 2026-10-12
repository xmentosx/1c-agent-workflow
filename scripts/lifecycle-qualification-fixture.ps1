# Source-only opt-in lifecycle adapter. Not installed in user projects.
# Core, lifecycle and source-proof-json supply their existing stateless owners.
function Resolve-QualificationFixtureChild {
    param([string]$Root, [string]$RelativePath)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if (-not $RelativePath -or [IO.Path]::IsPathRooted($RelativePath)) { throw 'FIXTURE_RELATIVE_PATH_REQUIRED' }
    $path = [IO.Path]::GetFullPath((Join-Path $base $RelativePath))
    if (-not $path.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'FIXTURE_PATH_ESCAPE' }
    $cursor = $path
    while ($cursor -and $cursor.Length -ge $base.Length) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'FIXTURE_REPARSE_POINT' }
        }
        $cursor = Split-Path -Parent $cursor
    }
    return $path
}

function Read-QualificationFixtureJson {
    param([string]$Path)
    return ConvertFrom-DeliveryProofJson -Json (Read-Utf8Text -Path $Path)
}

function Remove-QualificationFixtureRuntimeEnvironmentAssignments {
    param([string]$Text)
    return [regex]::Replace($Text,'(?m)^(?:ITL_ACTIVE_|ROCTUP_MCP_|VANESSA_MCP_|VANESSA_TEST_PORT=)[^\r\n]*(?:\r?\n|$)','')
}

function Get-QualificationFixtureClaimPath {
    param([string]$ProjectRoot)
    $root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
    return Resolve-QualificationFixtureChild -Root (Split-Path -Parent $root) -RelativePath 'qualification-fixture.json'
}

function Write-QualificationFixtureJson {
    param([string]$Path, [object]$Value)
    Write-Utf8TextAtomic -Path $Path -Value ((ConvertTo-DeliveryProofJson -InputObject $Value -Depth 32) + [Environment]::NewLine)
}

function Read-QualificationFixtureCapsule {
    param([string]$ManifestPath, [string]$Sha256)
    if ($Sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Sha256) { throw 'FIXTURE_MANIFEST_SHA_MISMATCH' }
    $manifest = Read-QualificationFixtureJson -Path $ManifestPath
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.kind -cne 'itl-qualification-fixture' -or
        [string]$manifest.status -cne 'sealed' -or [string]$manifest.infoBaseKind -cne 'file' -or
        [string]$manifest.branchName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or
        [string]$manifest.masterCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$manifest.branchCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$manifest.workflowCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'FIXTURE_MANIFEST_INVALID' }
    $root = Split-Path -Parent ([IO.Path]::GetFullPath($ManifestPath))
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($manifest.files)) {
        $relative = [string]$record.path
        if (-not $seen.Add($relative.Replace('\','/'))) { throw 'FIXTURE_DUPLICATE_ARTIFACT' }
        $path = Resolve-QualificationFixtureChild -Root $root -RelativePath $relative
        if ([string]$record.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$record.sha256) { throw "FIXTURE_ARTIFACT_SHA_MISMATCH: $relative" }
    }
    foreach ($required in @('source.bundle','infobase.dt','state.json','master.env','branch.env','release-e2e.json')) {
        if (-not $seen.Contains($required)) { throw "FIXTURE_ARTIFACT_MISSING: $required" }
    }
    return $manifest
}

function ConvertTo-QualificationFixtureContextValue {
    param([AllowNull()]$Value, [object[]]$Mappings)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        foreach ($mapping in $Mappings) {
            $from = ([string]$mapping.from).TrimEnd('\','/')
            if ($Value.Equals($from, [StringComparison]::OrdinalIgnoreCase)) { return [string]$mapping.to }
            if ($Value.StartsWith($from+'\', [StringComparison]::OrdinalIgnoreCase) -or $Value.StartsWith($from+'/', [StringComparison]::OrdinalIgnoreCase)) {
                return ([string]$mapping.to).TrimEnd('\','/') + $Value.Substring($from.Length)
            }
        }
        return $Value
    }
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $result = [ordered]@{}
        $keys = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
        foreach ($key in $keys) { $result[$key] = ConvertTo-QualificationFixtureContextValue -Value $Value.$key -Mappings $Mappings }
        return $result
    }
    if ($Value -is [Array]) { return ,@($Value | ForEach-Object { ConvertTo-QualificationFixtureContextValue -Value $_ -Mappings $Mappings }) }
    return $Value
}

function Install-QualificationFixtureContext {
    param([string]$ManifestPath, [string]$Sha256, [string]$TargetProjectRoot, [string]$TargetBranchRoot)
    $manifest = Read-QualificationFixtureCapsule -ManifestPath $ManifestPath -Sha256 $Sha256
    $capsuleRoot = Split-Path -Parent $ManifestPath
    $target = [IO.Path]::GetFullPath($TargetProjectRoot).TrimEnd('\','/')
    $branch = [IO.Path]::GetFullPath($TargetBranchRoot).TrimEnd('\','/')
    # A factory-created, exact-root claim is required before the owner writes state.
    $claimPath = Get-QualificationFixtureClaimPath -ProjectRoot $target
    $claim = Read-QualificationFixtureJson -Path $claimPath
    if ([string]$claim.kind -cne 'itl-qualification-fixture-target' -or [string]$claim.capsuleSha256 -cne $Sha256 -or
        [string]$claim.projectRoot -ine $target -or [string]$claim.branchRoot -ine $branch -or
        [string]$claim.status -cne 'materializing' -or
        $target -ieq [string]$manifest.sourceProjectRoot -or $branch -ieq [string]$manifest.sourceBranchRoot) { throw 'FIXTURE_TARGET_NOT_OWNED' }
    if ($branch -ine (Join-Path (Split-Path -Parent $target) 'branch') -or
        (Get-RepositoryCommonGitDirectory -RepositoryRoot $target) -ine (Get-RepositoryCommonGitDirectory -RepositoryRoot $branch)) { throw 'FIXTURE_TARGET_CONTEXT_FOREIGN' }
    $stateRelative = '.agent-1c/dev-branches/' + [string]$manifest.branchName + '.json'
    $statePath = Resolve-QualificationFixtureChild -Root $branch -RelativePath $stateRelative
    if (Test-Path -LiteralPath $statePath) { throw 'FIXTURE_TARGET_STATE_ALREADY_EXISTS: preserve the target and repeat preparation through its owner' }
    $sourceState = Read-QualificationFixtureJson -Path (Join-Path $capsuleRoot 'state.json')
    if ([string]$sourceState.worktreePath -ine [string]$manifest.sourceBranchRoot -or
        [string]$sourceState.mainWorktreePath -ine [string]$manifest.sourceProjectRoot -or
        [string]$sourceState.devBranchName -cne [string]$manifest.branchName -or
        [string]$sourceState.infoBaseKind -cne 'file') { throw 'FIXTURE_SOURCE_CONTEXT_MISMATCH' }
    $state = ConvertTo-Agent1cHashtable -Object $sourceState
    Remove-DevBranchForkTransientState -State $state | Out-Null
    # Qualification, unlike a user fork, must retain the declared unfinished operation.
    foreach ($property in $sourceState.PSObject.Properties) {
        if ($property.Name -match '^(pendingMerge|pendingRefresh|lifecycleMerge|eventLogPendingCursor)') { $state[$property.Name] = $property.Value }
    }
    $mappings = @(@{from=[string]$manifest.sourceBranchRoot;to=$branch},@{from=[string]$manifest.sourceProjectRoot;to=$target})
    foreach($reference in @($manifest.contextFiles)){
        if($reference.PSObject.Properties['sourcePath']){
            $root=if([string]$reference.role -ceq 'master'){$target}elseif([string]$reference.role -ceq 'branch'){$branch}else{throw 'FIXTURE_CONTEXT_ROLE_INVALID'}
            $mappings+=@{from=[string]$reference.sourcePath;to=(Resolve-QualificationFixtureChild -Root $root -RelativePath ([string]$reference.relativePath))}
        }
    }
    $state = ConvertTo-QualificationFixtureContextValue -Value $state -Mappings $mappings
    $state['worktreePath']=$branch; $state['mainWorktreePath']=$target
    $state['devBranchInfoBasePath']=Resolve-QualificationFixtureChild -Root $branch -RelativePath ('.agent-1c/infobases/dev-branches/'+[string]$manifest.branchName)
    $state['toolingInfoBaseGeneration']=[guid]::NewGuid().ToString('N')
    foreach ($field in @('vanessaMcpSafeModeProof','yaxunitInstallationProof')) { $state[$field]=$null }
    foreach ($field in @('toolingRecoveryId','toolingMutationId','toolingMutationAt','toolingRecoveredMutationId','toolingRecoveredMutationAt','toolingRecoveredAt','lastVerifiedCommit','verifiedFingerprint')) { $state[$field]='' }
    $state['verificationStatus']='stale'
    $state['publicationStatus']='disabled'; $state['publicationMode']='none'; $state['publicationUrl']=''
    $state['launcherRegistered']=$false
    # Runtime paths not imported by the common fork policy must not point at the seed.
    foreach ($field in @($state.Keys)) {
        if ($field -match '^last(?:Vanessa|YAxUnit|Verif|DiagnosticVerification).*(?:Path|Fingerprint)$') { $state[$field]='' }
    }
    foreach ($role in @('master','branch')) {
        $root = if ($role -eq 'master') { $target } else { $branch }
        $lines = New-Object Collections.Generic.List[string]
        foreach ($line in @(Read-Utf8Lines -Path (Join-Path $capsuleRoot ($role+'.env')))) {
            if ($line -and (Remove-QualificationFixtureRuntimeEnvironmentAssignments -Text $line) -ceq '') { continue }
            if ($line -match '^INFOBASE_PATH=') {
                $base = if ($role -eq 'branch') { [string]$state.devBranchInfoBasePath } else { Resolve-QualificationFixtureChild -Root $target -RelativePath '.agent-1c/infobases/source' }
                $lines.Add('INFOBASE_PATH='+$base); continue
            }
            if ($line -match '^(?<key>[A-Za-z0-9_]+)=(?<value>.*)$') {
                $line = $Matches.key+'='+(ConvertTo-QualificationFixtureContextValue -Value $Matches.value -Mappings $mappings)
            }
            $lines.Add($line)
        }
        Write-Utf8TextAtomic -Path (Resolve-QualificationFixtureChild -Root $root -RelativePath '.dev.env') -Value (($lines -join [Environment]::NewLine)+[Environment]::NewLine)
    }
    foreach ($reference in @($manifest.contextFiles)) {
        $root = if ([string]$reference.role -ceq 'master') { $target } elseif ([string]$reference.role -ceq 'branch') { $branch } else { throw 'FIXTURE_CONTEXT_ROLE_INVALID' }
        $source = Resolve-QualificationFixtureChild -Root $capsuleRoot -RelativePath ([string]$reference.artifact)
        if (@($manifest.files | Where-Object path -CEQ ([string]$reference.artifact)).Count -ne 1) { throw 'FIXTURE_CONTEXT_ARTIFACT_UNBOUND' }
        $destination = Resolve-QualificationFixtureChild -Root $root -RelativePath ([string]$reference.relativePath)
        if ([IO.Path]::GetExtension($source) -ieq '.json') {
            Write-QualificationFixtureJson -Path $destination -Value (ConvertTo-QualificationFixtureContextValue -Value (Read-QualificationFixtureJson -Path $source) -Mappings $mappings)
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination
        }
    }
    Write-QualificationFixtureJson -Path $statePath -Value $state
    return [pscustomobject]@{statePath=$statePath;infoBasePath=[string]$state.devBranchInfoBasePath;branchName=[string]$manifest.branchName}
}
