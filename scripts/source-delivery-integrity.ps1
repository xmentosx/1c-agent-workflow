function Assert-DevelopPublicationCandidateIntegrity {
    param([Parameter(Mandatory=$true)][string]$CandidateRoot, [Parameter(Mandatory=$true)][object]$Attempt)
    $head = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
    $tree = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @('rev-parse','HEAD^{tree}')).stdout.Trim()
    $dirtyPaths = @(Get-RepositoryGitPathList -RepositoryRoot $CandidateRoot -Arguments @('status','--porcelain=v1','--untracked-files=all','-z'))
    if ($head -ceq [string]$Attempt.candidate -and $tree -ceq [string]$Attempt.tree -and $dirtyPaths.Count -eq 0) { return }
    $message = "DELIVERY_CANDIDATE_INTEGRITY: expected commit $([string]$Attempt.candidate), tree $([string]$Attempt.tree); observed commit $head, tree $tree, dirty records $($dirtyPaths.Count). The queue and original plan were preserved. Diagnose the gate/finalizer callback in '$CandidateRoot', then repeat the same publication command to reconstruct the original candidate and validate its existing qualification. Component finalization must run again after this integrity failure."
    $Attempt.componentPublication = $null
    if ((Get-DevelopPublicationPhaseRank -Phase ([string]$Attempt.phase)) -ge 3) {
        Set-DevelopPublicationPhase -Attempt $Attempt -Phase $(if ($RequireRelease) { 'release-qualified' } else { 'develop-qualified' })
    }
    Register-DevelopPublicationStageFailure -Attempt $Attempt -Stage 'component-finalizer' -Message $message -FailureIdentity "candidate-integrity:$([string]$Attempt.candidate):$([string]$Attempt.tree)"
    throw $message
}
