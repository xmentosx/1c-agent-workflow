# Loaded on demand by the existing registry/MCP owner. Native memory is not used.

function Invoke-ItlCatalogGit {
    param([string]$Root, [string[]]$Arguments, [DateTime]$DeadlineUtc, [switch]$AllowFailure)
    if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw 'CATALOG_GIT_DEADLINE: repeat the same catalog operation; prepared data is preserved.' }
    $previousPrompt = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT', 'Process')
    $previousGcm = [Environment]::GetEnvironmentVariable('GCM_INTERACTIVE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Process')
        [Environment]::SetEnvironmentVariable('GCM_INTERACTIVE', 'Never', 'Process')
        # The native Git HTTP/SSH children own the same transport. Reserve
        # cleanup inside the caller's absolute budget instead of stopping only
        # their parent and leaving its output pipes/network active afterwards.
        # Include process inventory, PID identity checks and confirmed exit in
        # the caller's budget. Three seconds was shorter than observed cleanup.
        $transportDeadline=$DeadlineUtc.AddSeconds(-10)
        if([DateTime]::UtcNow -ge $transportDeadline){throw 'CATALOG_GIT_DEADLINE: no transport cleanup budget remains; restart the same catalog operation with a fresh metadata budget; prepared data is preserved.'}
        $result = Invoke-ItlNativeProcessCapture -FilePath 'git.exe' -Arguments (@('-c','core.quotepath=false','--no-pager','-C',([IO.Path]::GetFullPath($Root))) + $Arguments) -WorkingDirectory $Root -DeadlineUtc $transportDeadline -OnWait { } -OnTimeout {
            param($process)
            . (Join-Path $PSScriptRoot 'agent-1c.ui-tools.ps1')
            Stop-ItlUiToolProcessTree -Process $process
        }
    } finally {
        [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', $previousPrompt, 'Process')
        [Environment]::SetEnvironmentVariable('GCM_INTERACTIVE', $previousGcm, 'Process')
    }
    if ($result.exitCode -ne 0 -and -not $AllowFailure) { throw "CATALOG_GIT_FAILED: git operation failed (exit $($result.exitCode)); verify access/branch and repeat the same operation." }
    return $result
}

function Get-ItlCatalogRecordKey {
    param([ValidateSet('products','projects','profiles','sources','instances')][string]$Collection)
    return @{products='productId';projects='projectId';profiles='profileId';sources='sourceId';instances='instanceId'}[$Collection]
}

function Get-ItlCatalogRecord {
    param([object]$Catalog, [string]$Collection, [string]$Id)
    $idKey = Get-ItlCatalogRecordKey $Collection
    foreach ($item in @((Get-ItlCatalogField $Catalog $Collection @()))) {
        if ([string](Get-ItlCatalogField $item $idKey '') -ceq $Id) { return $item }
    }
    return $null
}

function Set-ItlCatalogRecord {
    param([object]$Catalog, [string]$Collection, [object]$Record)
    $copy = ConvertTo-Vibecoding1cMcpHashtable $Catalog
    $key = Get-ItlCatalogRecordKey $Collection
    $id = [string](Get-ItlCatalogField $Record $key '')
    if (-not $id) { throw "CATALOG_INVALID: $Collection record requires $key" }
    $items = @((Get-ItlCatalogField $Catalog $Collection @()))
    $copy[$Collection] = @($items | Where-Object { [string](Get-ItlCatalogField $_ $key '') -cne $id }) + @($Record)
    return $copy
}

function Save-ItlCatalogRecord {
    param(
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [Parameter(Mandatory=$true)][string]$BaseCommit,
        [ValidateSet('products','projects','profiles','sources','instances')][string]$Collection = 'projects',
        [Parameter(Mandatory=$true)][object]$Record,
        [string]$Branch = '',
        [string]$RemoteUrl = '',
        [DateTime]$DeadlineUtc = ([DateTime]::UtcNow.AddSeconds(60))
    )
    # Validate the complete prospective model before creating a checkout or pushing.
    $base = Read-ItlProductCatalogSnapshot -RepositoryRoot $RepositoryRoot -Commit $BaseCommit
    $prospective = Set-ItlCatalogRecord $base.catalog $Collection $Record
    $null = Assert-ItlProductCatalog $prospective $base.relations $base.registry
    $id = [string](Get-ItlCatalogField $Record (Get-ItlCatalogRecordKey $Collection))
    $expectedHash = Get-ItlCatalogHash $Record
    $baseHash = Get-ItlCatalogHash (Get-ItlCatalogRecord $base.catalog $Collection $id)
    $request = [ordered]@{schemaVersion=1; status='prepared-request'; outcome='not-saved'; collection=$Collection; recordId=$id; baseRevision=$base.catalogRevision; record=$Record; reason=''; continuation='Repeat catalog save with the same record ID and base; no request has been sent.'}
    $workRoot = ''
    $pushAttempted = $false
    $cleanupSafe = $true
    try {
        if (-not $RemoteUrl) {
            $RemoteUrl = (Invoke-ItlCatalogGit $RepositoryRoot @('remote','get-url','origin') $DeadlineUtc).stdout.Trim()
        }
        if (-not $Branch) {
            $branchRef = (Invoke-ItlCatalogGit $RepositoryRoot @('symbolic-ref','--quiet','refs/remotes/origin/HEAD') $DeadlineUtc -AllowFailure).stdout.Trim()
            if (-not $branchRef.StartsWith('refs/remotes/origin/')) { throw 'CATALOG_BRANCH_REQUIRED: specify the registry branch; it is not inferred from a product name.' }
            $Branch = $branchRef.Substring('refs/remotes/origin/'.Length)
        }
        $null = Invoke-ItlCatalogGit $RepositoryRoot @('check-ref-format',"refs/heads/$Branch") $DeadlineUtc
        $workRoot = Join-Path ([IO.Path]::GetTempPath()) ('itl-catalog-save-' + [guid]::NewGuid().ToString('N'))
        $parent = Split-Path -Parent $workRoot
        $null = Invoke-ItlCatalogGit $parent @('clone','--no-hardlinks','--no-checkout','--',$RepositoryRoot,$workRoot) $DeadlineUtc
        $null = Invoke-ItlCatalogGit $workRoot @('remote','set-url','origin',$RemoteUrl) $DeadlineUtc
        foreach ($setting in @('user.name','user.email')) {
            $identity = (Invoke-ItlCatalogGit $RepositoryRoot @('config','--get',$setting) $DeadlineUtc -AllowFailure).stdout.Trim()
            if ($identity) { $null = Invoke-ItlCatalogGit $workRoot @('config',$setting,$identity) $DeadlineUtc }
        }
        for ($attempt=1; $attempt -le 2; $attempt++) {
            $null = Invoke-ItlCatalogGit $workRoot @('fetch','--no-tags','origin',$Branch) $DeadlineUtc
            $tip = (Invoke-ItlCatalogGit $workRoot @('rev-parse','FETCH_HEAD') $DeadlineUtc).stdout.Trim()
            $snapshot = Read-ItlProductCatalogSnapshot $workRoot $tip
            $current = Get-ItlCatalogRecord $snapshot.catalog $Collection $id
            $currentHash = Get-ItlCatalogHash $current
            if ($currentHash -ceq $expectedHash) {
                $request.status='saved'; $request.outcome='confirmed'; $request['catalogRevision']=$tip; $request['verifiedSnapshot']=$snapshot; $request.reason='remote-record-confirmed'; $request.continuation=''; return [pscustomobject]$request
            }
            if ($currentHash -cne $baseHash) {
                $request.status='conflict'; $request.reason='same-record-changed'; $request['comparison']=@{applied=(Get-ItlCatalogRecord $base.catalog $Collection $id);current=$current;proposed=$Record}; return [pscustomobject]$request
            }
            $candidate = Set-ItlCatalogRecord $snapshot.catalog $Collection $Record
            $null = Assert-ItlProductCatalog $candidate $snapshot.relations $snapshot.registry
            $null = Invoke-ItlCatalogGit $workRoot @('checkout','--detach',$tip) $DeadlineUtc
            $catalogPath = Join-Path $workRoot 'catalog/catalog.json'
            [IO.File]::WriteAllText($catalogPath,((ConvertTo-Json -InputObject $candidate -Depth 100)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
            $null = Invoke-ItlCatalogGit $workRoot @('add','--','catalog/catalog.json') $DeadlineUtc
            $null = Invoke-ItlCatalogGit $workRoot @('commit','--only','-m',"Update catalog $Collection/$id",'--','catalog/catalog.json') $DeadlineUtc
            $pushAttempted=$true
            $push = Invoke-ItlCatalogGit $workRoot @('push','origin',"HEAD:refs/heads/$Branch") $DeadlineUtc -AllowFailure
            # A failed/lost reply never permits a blind second write. Read remote first.
            $readBack = Invoke-ItlCatalogGit $workRoot @('fetch','--no-tags','origin',$Branch) $DeadlineUtc -AllowFailure
            if ($readBack.exitCode -ne 0) { throw 'CATALOG_SAVE_UNCONFIRMED: remote outcome must be checked before retry.' }
            $remoteTip = (Invoke-ItlCatalogGit $workRoot @('rev-parse','FETCH_HEAD') $DeadlineUtc).stdout.Trim()
            $remoteSnapshot = Read-ItlProductCatalogSnapshot $workRoot $remoteTip
            if ((Get-ItlCatalogHash (Get-ItlCatalogRecord $remoteSnapshot.catalog $Collection $id)) -ceq $expectedHash) {
                $request.status='saved'; $request.outcome='confirmed'; $request['catalogRevision']=$remoteTip; $request['verifiedSnapshot']=$remoteSnapshot; $request.reason='remote-record-confirmed'; $request.continuation=''; return [pscustomobject]$request
            }
            if ($push.exitCode -ne 0 -and $remoteTip -ceq $tip) { $request.reason='write-denied-or-unavailable'; return [pscustomobject]$request }
        }
        $request.reason='concurrent-update-budget-exhausted'
    } catch {
        $request.reason = if ($pushAttempted) { 'remote-outcome-unconfirmed' } else { 'access-identity-or-deadline' }
        if ($pushAttempted) { $request.outcome='unknown' }
        # The capture owner reports an unconfirmed child cleanup explicitly.
        if ($_.Exception.Message -match 'cleanup (?:confirmed=False|was not confirmed)') { $cleanupSafe=$false }
    } finally {
        if ($workRoot -and (Test-Path -LiteralPath $workRoot)) {
            $absolute = [IO.Path]::GetFullPath($workRoot)
            $allowedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
            if ($cleanupSafe -and $absolute.StartsWith($allowedParent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $absolute) -match '^itl-catalog-save-[a-f0-9]{32}$') {
                Remove-Item -LiteralPath $absolute -Recurse -Force
            } else { $request['retainedWorkDirectory']=$workRoot }
        }
    }
    return [pscustomobject]$request
}
