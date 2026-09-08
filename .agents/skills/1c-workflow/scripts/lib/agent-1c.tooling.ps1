function Reset-DevBranchToolingProof {
    param([object]$State, [string]$Reason)

    # Persist before replacing any database bytes: interrupted restore cannot
    # leave an installation receipt for the old database valid.
    $updates = @{
        toolingInfoBaseGeneration = [guid]::NewGuid().ToString("N")
        toolingInvalidatedAt = (Get-Date).ToString("o")
        toolingInvalidationReason = $Reason
        vanessaMcpSafeModeProof = $null
        yaxunitInstallationProof = $null
    }
    Update-DevBranchState -State $State -Updates $updates
    foreach ($key in $updates.Keys) { $State | Add-Member -NotePropertyName $key -NotePropertyValue $updates[$key] -Force }
}

function Ensure-DevBranchToolingGeneration {
    param([object]$State)
    if (-not [string](Get-StateValue -State $State -Name "toolingInfoBaseGeneration" -Default "")) {
        Reset-DevBranchToolingProof -State $State -Reason "legacy-tooling-state"
        return Read-DevBranchState -Name ([string]$State.devBranchName)
    }
    return $State
}

function Ensure-ToolingProbeEpf {
    param([object]$State, [string]$User, [string]$Password)
    $source = Resolve-ProjectPath ".agents/skills/1c-workflow/tools/tooling-probe/ToolingProbe.xml"
    $sourceDirectory = Split-Path -Parent $source
    $hashInput = foreach ($file in Get-ChildItem -LiteralPath $sourceDirectory -Recurse -File | Sort-Object FullName) {
        $file.FullName.Substring($sourceDirectory.Length) + ":" + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($hashInput -join "`n"))))).Replace("-", "").ToLowerInvariant() } finally { $sha.Dispose() }
    # Use a long-standing runtime root: rollback can restore an older .gitignore.
    $root = Resolve-ProjectPath ".agent-1c/tmp/tooling-probe/$key"
    $epf = Join-Path $root "ToolingProbe.epf"
    if (-not (Test-Path -LiteralPath $epf -PathType Leaf)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $temporary = Join-Path $root (([guid]::NewGuid().ToString("N")) + ".epf")
        try {
            Invoke-Designer -InfoBaseKind $State.infoBaseKind -InfoBasePath $State.devBranchInfoBasePath -User $User -Password $Password `
                -DesignerArgs @("/LoadExternalDataProcessorOrReportFromFiles", $source, $temporary) | Out-Null
            if (-not (Test-Path -LiteralPath $temporary -PathType Leaf)) { throw "ITL_TOOLING_PROBE_BUILD_FAILED: $temporary" }
            Move-Item -LiteralPath $temporary -Destination $epf -Force
        } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    return $epf
}

function Get-ToolingRuntimeExtensions {
    param(
        [object]$State, [string[]]$Names,
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )
    $epf = Ensure-ToolingProbeEpf -State $State -User $User -Password $Password
    $run = Resolve-ProjectPath ("build/test-results/tooling-probe/" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $run -Force | Out-Null
    $request = Join-Path $run "request.json"
    $output = Join-Path $run "result.json"
    $nonce = [guid]::NewGuid().ToString("N")
    Write-Utf8Text -Path $request -Value (@{ names = @($Names); nonce = $nonce; outputPath = $output } | ConvertTo-Json -Depth 5)
    try {
        Invoke-Enterprise -InfoBaseKind $State.infoBaseKind -InfoBasePath $State.devBranchInfoBasePath -User $User -Password $Password `
            -EnterpriseArgs @("/Execute", $epf, "/CToolingProbe;Params=$request") -TimeoutSeconds 120 | Out-Null
        if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
            $tail = Read-VanessaDesignerAgentSafeLogTail -Path $script:LastLogPath
            throw "No runtime report: $output; log='$script:LastLogPath'; detail='$tail'"
        }
        $result = Read-Utf8Text -Path $output | ConvertFrom-Json
        if ($result.nonce -cne $nonce -or $result.status -cne "passed") {
            $detail = Protect-VanessaVerificationDiagnosticText -Text ([string](Get-StateValue $result "error" "")) -MaxLength 1500
            throw "Invalid runtime report: $output; detail='$detail'"
        }
        foreach ($name in $Names) {
            if (@($result.extensions | Where-Object { $_.name -ceq $name }).Count -ne 1) { throw "Incomplete or ambiguous extension report: $name" }
        }
        return @($result.extensions)
    } catch {
        Set-RunFailureContext -Category "runner" -RequiredAction "repair-dev-branch-tooling"
        throw "ITL_TOOLING_PROBE_FAILED: report='$output'; $($_.Exception.Message)"
    }
}

function Test-ToolingRuntimeExtensionReady {
    param([object]$Runtime, [string]$Name, [string]$ExpectedHash = "", [switch]$RequireUnsafeMode, [switch]$RequireUnsafeActionProtectionDisabled)
    if ($null -eq $Runtime -or [string]$Runtime.name -cne $Name -or -not $Runtime.present -or -not $Runtime.active) { return $false }
    if ($RequireUnsafeMode -and $Runtime.safeMode) { return $false }
    if ($RequireUnsafeActionProtectionDisabled -and $Runtime.unsafeActionProtection) { return $false }
    if ($Name -ceq "VAExtension" -and -not $Runtime.serverCodeObject) { return $false }
    if (-not [string]$Runtime.contentHash -or ($ExpectedHash -and [string]$Runtime.contentHash -cne $ExpectedHash)) { return $false }
    return $true
}

function Assert-ToolingRuntimeExtensionReady {
    param([object]$Runtime, [string]$Name, [switch]$RequireUnsafeMode, [switch]$RequireUnsafeActionProtectionDisabled)
    if (-not (Test-ToolingRuntimeExtensionReady @PSBoundParameters)) {
        Set-RunFailureContext -Category "runner" -RequiredAction "repair-dev-branch-tooling"
        throw "ITL_TOOLING_EXTENSION_NOT_READY: extension='$Name'; present/active/content/security or required metadata was not proven in a fresh session."
    }
}

function Repair-DevBranchTooling {
    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "repair-dev-branch-tooling"
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "repair-dev-branch-tooling"
    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "tooling recovery"
    $state = Ensure-VanessaMcpInstalled -State $state
    if (Test-YAxUnitSuitePresent) { Ensure-YAxUnitExtensions -State $state | Out-Null }
    # A new recovery receipt permits a new bounded repair invocation only after
    # the previously exhausted session's environment has actually been repaired.
    $latest = Read-DevBranchState -Name ([string]$state.devBranchName)
    $mutation = [string](Get-StateValue $latest "toolingMutationId" "")
    $mutationAt = [string](Get-StateValue $latest "toolingMutationAt" "")
    if ($mutation -and $mutationAt -and $mutation -cne [string](Get-StateValue $latest "toolingRecoveredMutationId" "")) {
        Update-DevBranchState -State $latest -Updates @{
            toolingRecoveryId = [guid]::NewGuid().ToString("N")
            toolingRecoveredMutationId = $mutation
            toolingRecoveredMutationAt = $mutationAt
            toolingRecoveredAt = (Get-Date).ToString("o")
        }
    } else {
        Write-Host "Tooling is already ready; no recovery mutation was needed."
    }
    Set-RunUserReport -Report "Tooling readiness proved for $($state.devBranchName). Run the canonical unfiltered check; this recovery is not verification acceptance."
}
