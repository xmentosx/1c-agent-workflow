function Find-SourceE2EArtifactBinding {
    param([string]$RepositoryRoot,[string[]]$SearchRoot=@(),[ref]$MissingInput)
    $lockPath=Join-Path $RepositoryRoot 'templates/dependency-lock.json'
    if(-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return $null }
    $deps=(Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies
    $common=Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot
    $roots=@(@($RepositoryRoot)+@($SearchRoot)+@(Split-Path -Parent $common) | Select-Object -Unique)
    $specs=[ordered]@{
        ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE=@{sha=$deps.vanessaAutomation.sha256;relative=('build/third-party/vanessa-automation/'+$deps.vanessaAutomation.compatibilityVersion+'-'+$deps.vanessaAutomation.downstreamRevision+'/'+$deps.vanessaAutomation.assetName);shared=('itl/dependencies/vanessa-automation/'+$deps.vanessaAutomation.compatibilityVersion+'-'+$deps.vanessaAutomation.downstreamRevision+'/'+$deps.vanessaAutomation.assetName)}
        VANESSA_MCP_CLIENT_CFE_PATH=@{sha=$deps.vanessaMcp.clientMcp.sha256;relative=('build/third-party/client-mcp/'+$deps.vanessaMcp.clientMcp.assetName)}
        ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE=@{sha=$deps.itlOndemandMcp.sha256;relative=('tools/itl-ondemand-mcp/build/'+$deps.itlOndemandMcp.assetName)}
    }
    # Read the installed cache owner's layout without importing its lifecycle.
    # An override remains authoritative; no recursive scan, download or build.
    $artifactCache=[Environment]::GetEnvironmentVariable('ITL_ARTIFACT_CACHE_ROOT','Process')
    if($artifactCache) {$artifactCache=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($artifactCache.Trim()))}
    else {$artifactCache=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ITL/artifacts'}
    $ondemandCache=[Environment]::GetEnvironmentVariable('ITL_ONDEMAND_MCP_INSTALL_ROOT','Process')
    if($ondemandCache) {$ondemandCache=[IO.Path]::GetFullPath($ondemandCache)}
    else {$ondemandCache=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ITL/MCP/ondemand'}
    $specs.VANESSA_MCP_CLIENT_CFE_PATH['installed']=Join-Path $artifactCache ('vanessa-mcp-clientMcp/'+$deps.vanessaMcp.clientMcp.version+'/'+$deps.vanessaMcp.clientMcp.sha256+'/'+$deps.vanessaMcp.clientMcp.assetName)
    $specs.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE['installed']=Join-Path $ondemandCache ($deps.itlOndemandMcp.version+'/'+$deps.itlOndemandMcp.sha256+'/'+$deps.itlOndemandMcp.assetName)
    $paths=[ordered]@{}
    foreach($name in $specs.Keys) {
        $spec=$specs[$name]; $explicit=[Environment]::GetEnvironmentVariable($name,'Process')
        # Wrap the statement output, not its branches: PowerShell unwraps a
        # singleton branch array, so += would concatenate two physical paths.
        $candidates=@(if($explicit){$explicit}else{$roots | ForEach-Object {Join-Path $_ $spec.relative}})
        if(-not $explicit -and $spec.ContainsKey('shared')) {
            # The immutable download owner keys shared files by SHA and name.
            $sharedDirectory=Split-Path -Parent (Join-Path $common $spec.shared)
            $candidates+=Join-Path $sharedDirectory (([string]$spec.sha).ToLowerInvariant()+'-'+[IO.Path]::GetFileName($spec.shared))
            # Retain exact-hash compatibility with older unprefixed caches.
            $candidates+=Join-Path $common $spec.shared
        }
        if(-not $explicit -and $spec.ContainsKey('installed')) {$candidates+=$spec.installed}
        foreach($path in $candidates) {
            if(-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                if($explicit){throw "SOURCE_E2E_ARTIFACT_MISSING: '$name'"}; continue
            }
            if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne ([string]$spec.sha).ToLowerInvariant()) {
                if($explicit){throw "SOURCE_E2E_ARTIFACT_HASH_MISMATCH: '$name'"}; continue
            }
            $paths[$name]=[IO.Path]::GetFullPath($path); break
        }
        if(-not $paths.Contains($name)) {
            if($MissingInput) {$MissingInput.Value=[string]$name}
            return $null
        }
    }
    $binding=[pscustomobject]@{schemaVersion=1;kind='itl-source-e2e-artifact-binding';paths=[pscustomobject]$paths}
    [void](Get-SourceE2EArtifactBindingHashes -RepositoryRoot $RepositoryRoot -Binding $binding)
    return $binding
}
