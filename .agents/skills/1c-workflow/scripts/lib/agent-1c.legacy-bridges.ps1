function Get-ItlLegacyBridgeState {
    param([string]$Operation)

    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation $Operation
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation $Operation
    Assert-DevBranchExtensionInitialized -State $state -Operation $Operation
    $branchBase = [string](Get-StateValue -State $state -Name "devBranchInfoBasePath" -Default "")
    if (-not $branchBase) { throw "$Operation cannot prove the branch infobase from ITL state." }
    $sourceBase = [string](Get-SourceInfoBasePath)
    $sameAsSource = if ([string](Get-StateValue -State $state -Name "infoBaseKind" -Default "file") -eq "server") {
        [string]::Equals($sourceBase, $branchBase, [System.StringComparison]::OrdinalIgnoreCase)
    } else {
        $sourceBase -and [string]::Equals((Resolve-Agent1cFullPath -Path $sourceBase), (Resolve-Agent1cFullPath -Path $branchBase), [System.StringComparison]::OrdinalIgnoreCase)
    }
    if ($sameAsSource) {
        throw "$Operation refused to target the source infobase."
    }
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    $activePath = [string](Get-EnvValue -Name "INFOBASE_PATH" -Default "")
    $contextMatches = if ([string](Get-StateValue -State $state -Name "infoBaseKind" -Default "file") -eq "server") {
        [string]::Equals($activePath, $branchBase, [System.StringComparison]::OrdinalIgnoreCase)
    } else {
        [string]::Equals((Resolve-Agent1cFullPath -Path $activePath), (Resolve-Agent1cFullPath -Path $branchBase), [System.StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $contextMatches) {
        throw "$Operation could not reconcile INFOBASE_PATH to the branch infobase."
    }
    return $state
}

function Invoke-ItlTransactionalBranchDump {
    param(
        [object]$State,
        [string[]]$ObjectPaths = @()
    )

    Assert-CleanGit
    Assert-SingleManagedExtensionArtifact -State $State
    $kind = Get-DevBranchKind -State $State
    $extensionName = ""
    $relativeTarget = if ($kind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $State
        Get-DevBranchExtensionExportPath -State $State
    } else { Get-ExportPath }
    $target = Assert-ExportPathInsideProject -ExportPath $relativeTarget
    $transactionRoot = Assert-ExportPathInsideProject -ExportPath (".agent-1c/branch-dumps/" + (Get-Date -Format "yyyyMMdd-HHmmss-fff") + "-" + [guid]::NewGuid().ToString("N"))
    $staged = Join-Path $transactionRoot "staged"
    $backup = Join-Path $transactionRoot "backup"
    $evidencePath = Join-Path $transactionRoot "evidence.json"
    $targetMoved = $false
    $stageInstalled = $false
    New-Item -ItemType Directory -Force -Path $transactionRoot | Out-Null
    try {
        if ($ObjectPaths.Count -gt 0) {
            if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "Partial dump requires an existing normalized source tree: $target" }
            Copy-Item -LiteralPath $target -Destination $staged -Recurse -Force
        } else {
            New-Item -ItemType Directory -Force -Path $staged | Out-Null
        }
        $args = @("/DumpConfigToFiles", $staged, "-Format", "Hierarchical")
        if ($extensionName) { $args += @("-Extension", $extensionName) }
        $listPath = ""
        if ($ObjectPaths.Count -gt 0) {
            $normalizedObjects = @($ObjectPaths | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
            if ($normalizedObjects.Count -eq 0) { throw "getconfigfiles requires at least one explicit object path." }
            $listPath = Join-Path $transactionRoot "selected-objects.txt"
            Write-Utf8Text -Path $listPath -Value (($normalizedObjects -join [Environment]::NewLine) + [Environment]::NewLine)
            $args += @("-update", "-force", "-listFile", $listPath)
        }
        Invoke-Designer -InfoBasePath $State.devBranchInfoBasePath -InfoBaseKind $State.infoBaseKind -DesignerArgs $args | Out-Null
        if (-not (Test-Path -LiteralPath (Join-Path $staged "ConfigDumpInfo.xml") -PathType Leaf)) { throw "Branch dump did not produce ConfigDumpInfo.xml." }
        if (@(Get-ChildItem -LiteralPath $staged -Force).Count -eq 0) { throw "Branch dump produced no files." }
        if (Test-Path -LiteralPath $target) {
            Move-Item -LiteralPath $target -Destination $backup
            $targetMoved = $true
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Move-Item -LiteralPath $staged -Destination $target
        $stageInstalled = $true
        $fingerprint = Get-ConfigSourceFingerprint -ExportPath $relativeTarget
        $now = (Get-Date).ToString("o")
        $updates = @{
            sourceFingerprint = $fingerprint.fingerprint
            lastTransactionalDumpAt = $now
            lastTransactionalDumpPath = $relativeTarget
            lastTransactionalDumpKind = $(if ($ObjectPaths.Count -gt 0) { "partial" } else { "full" })
            lastTransactionalDumpRollbackPath = $(if ($targetMoved) { $backup } else { "" })
            lastTransactionalDumpEvidencePath = $evidencePath
            lastLogPath = $script:LastLogPath
        }
        Add-VerificationStaleIfNeeded -State $State -Updates $updates -Reason "Branch infobase was dumped to source files." -Force
        Update-DevBranchState -State $State -Updates $updates
        $evidence = [ordered]@{
            schemaVersion = 1
            status = "passed"
            operation = $updates.lastTransactionalDumpKind
            recordedAt = $now
            branch = [string]$State.devBranch
            infobase = [string]$State.devBranchInfoBasePath
            target = $relativeTarget
            selectedObjects = @($ObjectPaths)
            rollbackPath = $updates.lastTransactionalDumpRollbackPath
            fingerprint = $fingerprint.fingerprint
            logPath = $script:LastLogPath
        }
        Write-Utf8Text -Path $evidencePath -Value (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        Sync-DevBranchContextToDotEnv -State (Read-DevBranchState -Name $DevBranchName) -AllowIncompleteExtension
        Write-Host "Transactional branch dump completed: $relativeTarget"
        Write-Host "Rollback evidence: $evidencePath"
    } catch {
        $failure = $_.Exception.Message
        if ($stageInstalled -and (Test-Path -LiteralPath $target)) { Remove-Item -LiteralPath $target -Recurse -Force }
        if ($targetMoved -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $target }
        Write-Utf8Text -Path $evidencePath -Value (([ordered]@{ schemaVersion = 1; status = "failed-rolled-back"; recordedAt = (Get-Date).ToString("o"); error = $failure } | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
        throw "Transactional branch dump failed and source files were restored: $failure. Evidence: $evidencePath"
    }
}

function Invoke-ItlUpdate1cBaseBridge {
    Get-ItlLegacyBridgeState -Operation "update1cbase" | Out-Null
    Update-DevBranchBase
}

function Invoke-ItlLoadFrom1cBaseBridge {
    $state = Get-ItlLegacyBridgeState -Operation "loadfrom1cbase"
    Invoke-ItlTransactionalBranchDump -State $state
}

function Invoke-ItlGetConfigFilesBridge {
    $state = Get-ItlLegacyBridgeState -Operation "getconfigfiles"
    $objects = @($ConfigObjectPaths | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($objects.Count -eq 0) { throw "getconfigfiles requires -ConfigObjectPaths with an explicit selected-object set." }
    Invoke-ItlTransactionalBranchDump -State $state -ObjectPaths $objects
}

function Invoke-ItlDeployAndTestBridge {
    Get-ItlLegacyBridgeState -Operation "deploy-and-test" | Out-Null
    $script:VerificationTrigger = "command"
    Check-DevBranch
}
