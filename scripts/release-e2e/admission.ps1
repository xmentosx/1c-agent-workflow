# Read-only Release admission. Context is transient; callers publish only decisions,
# never connection strings, environment values, or the complete context.
function Get-E2EAdmissionValue {
    param([object]$Record, [string]$Name, [object]$Default = $null)
    if ($null -eq $Record) { return $Default }
    if ($Record -is [Collections.IDictionary]) {
        if ($Record.Contains($Name)) { return $Record[$Name] }
        return $Default
    }
    $property = $Record.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Get-E2EAdmissionFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-E2EAdmissionCanonicalTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text.Replace("`r`n", "`n").Replace("`r", "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-E2EAdmissionStageDefinitions {
    param([Parameter(Mandatory = $true)][string]$WorkflowRoot)
    # Stage files declare definitions and functions only. Their registry stays in
    # a disposable module; importing it does not dispatch the executable runner.
    $owner = New-Module -ScriptBlock {
        param($Root)
        . (Join-Path $Root 'scripts/release-e2e/common.ps1')
        foreach ($name in @('seed-parallel', 'server-reset', 'config-cadence', 'config-roundtrip', 'extension-smoke', 'ondemand-mcp', 'result-cleanup')) {
            . (Join-Path $Root "scripts/release-e2e/$name.ps1")
        }
        Export-ModuleMember -Function @()
    } -ArgumentList $WorkflowRoot
    try { return & $owner { return ,$script:ReleaseE2EStageDefinitions } }
    finally { Remove-Module -ModuleInfo $owner -ErrorAction SilentlyContinue }
}

function Get-E2EAdmissionStageInputFiles {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$Name)
    $definition = $Context.stageDefinitions[$Name]
    if (-not $definition) { throw "Unknown Release E2E stage definition: $Name" }
    $root = [string]$Context.workflowRoot
    $allFiles = @(Get-E2EAdmissionValue $Context 'trackedInputFiles' @())
    if (-not (Get-E2EAdmissionValue $Context 'trackedInputFilesProvided' $false)) {
        $allFiles = @(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @('ls-files', '-z', '--') | ForEach-Object {
            $path = Join-Path $root ([string]$_).Replace('/', '\')
            if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Item -LiteralPath $path }
        })
    }
    $resolved = New-Object 'Collections.Generic.List[string]'
    foreach ($patternText in @($definition.paths)) {
        $normalizedPattern = ([string]$patternText).Replace('\', '/')
        if ($normalizedPattern.IndexOfAny([char[]]'*?') -ge 0) {
            $pattern = New-Object Management.Automation.WildcardPattern($normalizedPattern, [Management.Automation.WildcardOptions]::IgnoreCase)
            $matches = @($allFiles | Where-Object {
                $relative = $_.FullName.Substring($root.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
                $pattern.IsMatch($relative)
            })
            if ($matches.Count -eq 0) { throw "Release E2E stage '$Name' input pattern matched no files: $patternText" }
            foreach ($match in $matches) { $resolved.Add($match.FullName) | Out-Null }
        } else {
            $path = Join-Path $root $normalizedPattern.Replace('/', '\')
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release E2E stage '$Name' input is missing: $patternText" }
            $resolved.Add([IO.Path]::GetFullPath($path)) | Out-Null
        }
    }
    $resolved.Add((Join-Path $root 'scripts/stand-env-identity.ps1')) | Out-Null
    $resolved.Add((Join-Path ([string]$Context.stageModuleRoot) ([string]$definition.moduleFile))) | Out-Null
    return @($resolved | Sort-Object -Unique)
}

function Get-E2EAdmissionStageFingerprint {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$Name)
    $definition = $Context.stageDefinitions[$Name]
    $inputs = @()
    foreach ($path in @(Get-E2EAdmissionStageInputFiles -Context $Context -Name $Name)) {
        $inputs += [ordered]@{ path = $path.Substring($Context.workflowRoot.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/'); sha256 = Get-E2EAdmissionCanonicalTextSha256 -Path $path }
    }
    $dependencies = @()
    foreach ($dependency in @($definition.dependsOn)) { $dependencies += [ordered]@{ name = $dependency; fingerprint = Get-E2EAdmissionStageFingerprint -Context $Context -Name $dependency } }
    $stageConfiguration = if ($Name -eq 'server-reset') { $Context.serverConfiguration } else { $null }
    # Preserve the existing schema, field order and canonical JSON/hash recipe.
    # Budgets and whole-runner identity are intentionally not workload inputs.
    $payload = [ordered]@{
        schemaVersion = 2; name = $Name; version = [int]$definition.version
        aiRulesCommit = $Context.aiRulesCommit; aiRulesTree = $Context.aiRulesTree; projectConfigSha256 = $Context.projectConfigSha256
        inputs = $inputs; dependencies = $dependencies; stageConfiguration = $stageConfiguration
        clientSelection = $Context.clientSelection
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($payload | ConvertTo-Json -Depth 12 -Compress))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Test-E2EAdmissionStageInputsUnchanged {
    param([Parameter(Mandatory = $true)][object]$Context, [string]$Name, [string]$QualifiedCommit)
    $definition = $Context.stageDefinitions[$Name]
    if (-not $definition) { return $false }
    $patterns = @($definition.paths) + @("scripts/release-e2e/$([string]$definition.moduleFile)", 'scripts/release-e2e/common.ps1', 'scripts/stand-env-identity.ps1')
    foreach ($dependency in @($definition.dependsOn)) {
        if (-not (Test-E2EAdmissionStageInputsUnchanged -Context $Context -Name ([string]$dependency) -QualifiedCommit $QualifiedCommit)) { return $false }
    }
    foreach ($path in @(Get-RepositoryGitPathList -RepositoryRoot $Context.workflowRoot -Arguments @('diff', '--name-only', '-z', $QualifiedCommit, $Context.workflowCommit, '--'))) {
        foreach ($pattern in $patterns) {
            if (Test-WorkflowContinuationPattern -Path ([string]$path) -Pattern ([string]$pattern)) { return $false }
        }
    }
    return $true
}

function Get-E2EAdmissionStageDecision {
    param([string]$Name, [object]$Record, [string]$CurrentFingerprint, [string]$LegacyFingerprint = '', [bool]$CrossReleaseReuse = $false, [object]$ContinuationProof = $null, [string]$ContinuationBoundaryStage = '')
    $decision = [ordered]@{ stage = $Name; action = 'rerun'; reason = 'stage has no passed proof'; previousFingerprint = [string](Get-E2EAdmissionValue $Record 'fingerprint' ''); currentFingerprint = $CurrentFingerprint }
    if ([string](Get-E2EAdmissionValue $Record 'status' '') -ne 'passed') { return [pscustomobject]$decision }
    if ($CrossReleaseReuse -and -not $ContinuationProof) { $decision.reason = 'source continuation has no exact Targeted proof'; return [pscustomobject]$decision }
    if ($decision.previousFingerprint -eq $CurrentFingerprint) { $decision.action = 'reuse'; $decision.reason = 'exact stage fingerprint'; return [pscustomobject]$decision }
    $order = @('seed-parallel', 'server-reset', 'config-cadence', 'config-roundtrip', 'extension-smoke', 'ondemand-mcp', 'verification-refresh', 'result-cleanup')
    $stageIndex = [Array]::IndexOf($order, $Name)
    $boundaryIndex = [Array]::IndexOf($order, $ContinuationBoundaryStage)
    $completed = $CrossReleaseReuse -and $ContinuationProof -and -not $ContinuationBoundaryStage
    $beforeFailed = $boundaryIndex -ge 0 -and $stageIndex -ge 0 -and $stageIndex -lt $boundaryIndex
    if ($CrossReleaseReuse -and $ContinuationProof -and ($completed -or $beforeFailed) -and $decision.previousFingerprint -eq $LegacyFingerprint) {
        $decision.action = 'rebind'
        $decision.reason = if ($completed) { 'exact Targeted continuation after completed release' } else { "exact Targeted continuation before failed stage '$ContinuationBoundaryStage'" }
    } else { $decision.reason = 'stage fingerprint changed' }
    return [pscustomobject]$decision
}

function Assert-E2EAdmissionFile {
    param([string]$Path, [string]$Sha256, [string]$Label)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or $Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-E2EAdmissionFileSha256 $Path) -cne $Sha256.ToLowerInvariant()) {
        throw "RELEASE_E2E_CACHE_CORRUPT: $Label is missing or differs from its recorded SHA256."
    }
}

function Assert-E2EAdmissionCheckpointSupport {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Checkpoint)
    $snapshots = Get-E2EAdmissionValue $Checkpoint 'snapshots'
    $states = Get-E2EAdmissionValue $Checkpoint 'stateFiles'
    $stages = Get-E2EAdmissionValue $Checkpoint 'stages'
    $baseline = Get-E2EAdmissionValue $snapshots 'baseline'
    $stageCount = if ($stages -is [Collections.IDictionary]) { $stages.Count } elseif ($stages) { @($stages.PSObject.Properties).Count } else { 0 }
    if (-not $baseline -and $stageCount -gt 0) {
        throw 'RELEASE_E2E_RESUME_STATE_MISMATCH: baseline snapshot was not checkpointed before stage execution.'
    }
    $required = @('baseline')
    if ([string](Get-E2EAdmissionValue (Get-E2EAdmissionValue $stages 'config-cadence') 'status' '') -eq 'passed') { $required += 'postConfig' }
    foreach ($name in $required) {
        $snapshot = Get-E2EAdmissionValue $snapshots $name
        if ($snapshot) {
            Assert-E2EAdmissionFile -Path ([string](Get-E2EAdmissionValue $snapshot 'path' '')) -Sha256 ([string](Get-E2EAdmissionValue $snapshot 'sha256' '')) -Label "$name infobase snapshot"
        } elseif ($name -eq 'postConfig') { throw 'RELEASE_E2E_RESUME_STATE_MISMATCH: passed config-cadence has no post-config snapshot/state.' }
        $state = Get-E2EAdmissionValue $states $name
        Assert-E2EAdmissionFile -Path ([string](Get-E2EAdmissionValue $state 'stateCopyPath' '')) -Sha256 ([string](Get-E2EAdmissionValue $state 'stateSha256' '')) -Label "$name branch state"
        $envPath = [string](Get-E2EAdmissionValue $state 'envCopyPath' '')
        if ($envPath) { Assert-E2EAdmissionFile -Path $envPath -Sha256 ([string](Get-E2EAdmissionValue $state 'envSha256' '')) -Label "$name .dev.env" }
    }
}

function Get-E2EAdmissionCheckpointStageDecisions {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Checkpoint, [Parameter(Mandatory = $true)][object]$Admission)
    $stages = Get-E2EAdmissionValue $Checkpoint 'stages'
    $boundary = ''
    $order = @('seed-parallel', 'server-reset', 'config-cadence', 'config-roundtrip', 'extension-smoke', 'ondemand-mcp', 'verification-refresh', 'result-cleanup')
    if ($Admission.continuationProof) {
        foreach ($name in $order) {
            $record = Get-E2EAdmissionValue $stages $name
            if ($record -and [string](Get-E2EAdmissionValue $record 'status' '') -ne 'passed') { $boundary = $name; break }
        }
    }
    foreach ($name in $order) {
        $record = Get-E2EAdmissionValue $stages $name
        if (-not $record) { continue }
        $fingerprint = if ([string](Get-E2EAdmissionValue $record 'status' '') -eq 'passed') { Get-E2EAdmissionStageFingerprint -Context $Context -Name $name } else { '' }
        $decision = Get-E2EAdmissionStageDecision -Name $name -Record $record -CurrentFingerprint $fingerprint -LegacyFingerprint $fingerprint -CrossReleaseReuse $Admission.crossReleaseReuse -ContinuationProof $Admission.continuationProof -ContinuationBoundaryStage $boundary
        if ($decision.action -in @('reuse', 'rebind')) {
            $evidencePath = [string](Get-E2EAdmissionValue $record 'evidencePath' '')
            if ($evidencePath) { Assert-E2EAdmissionFile -Path $evidencePath -Sha256 ([string](Get-E2EAdmissionValue $record 'evidenceSha256' '')) -Label "$name evidence" }
        }
        $decision
    }
}

function Get-E2EReleaseCheckpointAdmission {
    param([Parameter(Mandatory = $true)][object]$Context, [object]$Checkpoint)
    $result = [ordered]@{ allowed = $true; code = ''; reason = ''; scopeMatches = $true; exactIdentity = $false; crossReleaseReuse = $false; continuationProof = $null; stages = @() }
    if (-not $Checkpoint) { return [pscustomobject]$result }
    $identity = Get-E2EAdmissionValue $Checkpoint 'identity'
    $schema = 0
    [void][int]::TryParse([string](Get-E2EAdmissionValue $Checkpoint 'schemaVersion' 0), [ref]$schema)
    $result.scopeMatches = $schema -in @(1, 2, 3) -and [string](Get-E2EAdmissionValue $identity 'projectRoot' '') -eq $Context.projectRoot -and
        [string](Get-E2EAdmissionValue $identity 'worktreePath' '') -eq $Context.worktreePath -and [string](Get-E2EAdmissionValue $identity 'branch' '') -eq $Context.branch
    if (-not $result.scopeMatches) { $result.allowed = $false; $result.code = 'RELEASE_E2E_RESUME_STATE_MISMATCH'; $result.reason = 'checkpoint schema/project/worktree/branch does not match'; return [pscustomobject]$result }
    if ($schema -lt 3 -and $Context.resumeMode -eq 'Auto') { $result.allowed = $false; $result.code = 'RELEASE_E2E_CHECKPOINT_UPGRADE_REQUIRED'; $result.reason = "checkpoint schema v$schema requires scripted Restart"; return [pscustomobject]$result }
    $result.exactIdentity = $true
    foreach ($name in @('workflowCommit', 'workflowTree', 'runnerSha256', 'aiRulesCommit', 'helperSha256', 'clientSelection', 'projectConfigSha256')) {
        $previous = [string](Get-E2EAdmissionValue $identity $name '')
        $current = [string](Get-E2EAdmissionValue $Context $name '')
        $matches = if ($name -eq 'clientSelection') { $previous -ceq $current } else { $previous -eq $current }
        if (-not $matches) { $result.exactIdentity = $false }
    }
    $result.crossReleaseReuse = $Context.resumeMode -eq 'Auto' -and -not $result.exactIdentity
    if ($result.crossReleaseReuse -and [string](Get-E2EAdmissionValue $identity 'clientSelection' '') -ceq [string]$Context.clientSelection) {
        $result.continuationProof = Get-WorkflowContinuationProof -RepositoryRoot $Context.workflowRoot -QualifiedCommit ([string](Get-E2EAdmissionValue $identity 'workflowCommit' '')) -CurrentCommit $Context.workflowCommit -CurrentTree $Context.workflowTree
    }
    $expectedHead = [string](Get-E2EAdmissionValue $Checkpoint 'expectedHead' '')
    if ($Context.resumeMode -eq 'Auto' -and $Context.currentHead -cne $expectedHead) {
        $headAllowed = $result.crossReleaseReuse -and $Context.worktreeClean -and
            (Test-E2EAdmissionManagedRefreshHead -RepositoryRoot $Context.worktreePath -CurrentHead $Context.currentHead -ExpectedHead $expectedHead -MasterHead $Context.masterHead -ExportPath $Context.exportPath -WorkflowRoot $Context.workflowRoot)
        if (-not $headAllowed) { $result.allowed = $false; $result.code = 'RELEASE_E2E_RESUME_STATE_MISMATCH'; $result.reason = 'current HEAD has no supported completed workflow-update or refresh transition from checkpoint HEAD'; return [pscustomobject]$result }
    }
    return [pscustomobject]$result
}
