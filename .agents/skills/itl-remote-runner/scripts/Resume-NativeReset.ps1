param([Parameter(Mandatory = $true)][string]$ContextPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$resume = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$proof = [Console]::In.ReadLine() | ConvertFrom-Json
if ($resume.schemaVersion -ne 1 -or $resume.resumeId -cnotmatch '^[a-f0-9]{32}$' -or
    $proof.purpose -cne 'recovery' -or $proof.ticket -cne $resume.checkpoint.ticket) { throw 'NATIVE_RESET_WORKER_CONTEXT_INVALID' }
foreach ($file in $resume.helperFiles) {
    if ((Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) {
        throw 'NATIVE_RESET_WORKER_HELPER_CHANGED'
    }
}
$resetContext = $resume.checkpoint.context
. $resume.helperPath -ProjectRoot $resetContext.project -Action help -DevBranchName $resetContext.branchName *> $null
$Action = 'reset-dev-branch'
$RunStatusPath = Join-Path $resume.output ($resume.resumeId + '.status.json')
$RunLogPath = Join-Path $resume.output ($resume.resumeId + '.log')
$script:Agent1cReexecArguments = Get-Agent1cReexecArguments
$script:DevBranchMutationDatabaseAdmission = $null
$succeeded = $false
$entered = $false
try {
    [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', ($proof | ConvertTo-Json -Compress), 'Process')
    $proof = $null
    $state = Read-DevBranchState -Name $DevBranchName
    Get-DevBranchResetRecoveryState -State $state -Context $resetContext | Out-Null
    $preparation = Get-ItlDevBranchMutationAdmissionPreparation -Operation reset-dev-branch
    $plan = $preparation.plan
    $inherited = $resume.plan
    if ($plan.target.kind -cne $inherited.target.kind -or
        -not (Test-ItlOnDemandInfoBaseMatch -First $plan.target.path -Second $inherited.target.path)) { throw 'NATIVE_RESET_WORKER_TARGET_CHANGED' }
    # Replan using the admitted reserve, not a newly generated service address.
    $plan = Get-ItlDevBranchMutationDatabasePlan -State $state -Operation reset-dev-branch `
        -ServiceGeneration $inherited.serviceReserveGeneration -ServiceReserveGeneration $inherited.serviceReserveGeneration
    foreach ($base in $plan.bases) {
        if (@($inherited.bases | Where-Object { $_.kind -ceq $base.kind -and (Test-ItlOnDemandInfoBaseMatch -First $_.path -Second $base.path) }).Count -eq 0) {
            throw 'NATIVE_RESET_WORKER_RESOURCE_CHANGED'
        }
    }
    $plan.bases = @($inherited.bases)
    $preparation.plan = $plan
    $preparation.continuationParent = $resume.checkpoint.continuation
    $preparation.settings.coordinator = $resume.coordinator
    $preparation.settings.python = $resume.python
    $preparation.settings.waitTimeoutSeconds = 0
    $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation reset-dev-branch -Preparation $preparation
    Enter-Agent1cLifecycleOperation -RequestedAction reset-dev-branch
    $entered = $true
    Read-ProjectConfig
    Assert-ItlDevBranchMutationDatabaseAdmission -Admission $script:DevBranchMutationDatabaseAdmission -State (Read-DevBranchState -Name $DevBranchName)
    Write-RunStatus -Status running
    Reset-DevBranch -RecoveryContext $resetContext
    Publish-ItlDevBranchLifecycleCompletion -Admission $script:DevBranchMutationDatabaseAdmission
    Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
    Write-RunStatus -Status succeeded -ExitCode 0
    $succeeded = $true
} catch {
    if ($entered) {
        Complete-Agent1cLifecycleOperation -Status failed -ExitCode 1 -ErrorMessage $_.Exception.Message
        Write-RunStatus -Status failed -ExitCode 1 -ErrorMessage $_.Exception.Message
    }
    throw
} finally {
    if ($script:LifecycleOperationTerminalWrittenByContinuation) {
        $terminal = Read-Agent1cLifecycleOperationRecord -Path $script:LifecycleOperationStatePath
        $succeeded = $null -ne $terminal -and $terminal['status'] -eq 'succeeded'
    }
    $admission = $script:DevBranchMutationDatabaseAdmission
    try {
        if ($null -ne $admission) {
            try { Complete-ItlDevBranchMutationDatabaseAdmission $admission }
            catch {
                if ($succeeded) { throw }
                [Console]::Error.WriteLine('Reset recovery retained admission: ' + $_.Exception.Message)
                if (-not $admission.owner.closed) { Close-ItlDatabaseAccessHost -Owner $admission.owner }
            }
            if ($succeeded) {
                $result = [ordered]@{schemaVersion=1;resumeId=$resume.resumeId;ticket=$resume.checkpoint.ticket
                    producerId=$admission.continuation.reference.producerId;fromCheckpoint=$resume.checkpoint.reference
                    operation='reset-dev-branch';originalOutcome='interrupted';resumed=$true}
                [IO.File]::WriteAllText((Join-Path $resume.output ($resume.resumeId + '.result.json')), ($result | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            }
        }
    } finally { if ($entered) { Exit-Agent1cLifecycleOperation } }
}
