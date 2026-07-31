function Get-BranchSeedRoot {
    $configured = Get-Setting -EnvName "BRANCH_SEED_ROOT" -ConfigName "branchSeedRoot" -Default ".agent-1c/branch-seed"
    if ([System.IO.Path]::IsPathRooted([string]$configured)) {
        return (Resolve-Agent1cFullPath -Path ([string]$configured))
    }
    $mainRoot = Get-MainWorktreePath
    return (Resolve-Agent1cFullPath -Path (Join-Path $mainRoot ([string]$configured)))
}

function Get-BranchSeedSourceKey {
    $kind = Get-InfoBaseKind
    $source = Get-SourceInfoBasePath
    $identity = if ($kind -eq "file") {
        "$kind|$((Resolve-Agent1cFullPath -Path $source).ToLowerInvariant())"
    } else {
        "$kind|$($source.Trim().ToLowerInvariant())"
    }
    return (Get-StringSha256 -Value $identity)
}

function Get-BranchSeedPaths {
    $sourceKey = Get-BranchSeedSourceKey
    $root = Join-Path (Get-BranchSeedRoot) $sourceKey
    $kind = Get-InfoBaseKind
    $artifactKind = if ($kind -eq "file") { "file-1cd" } else { "server-dt" }
    $artifactPath = if ($kind -eq "file") {
        Join-Path $root "infobase\1Cv8.1CD"
    } else {
        Join-Path $root "source.dt"
    }
    return [pscustomobject]@{
        root = $root
        sourceKey = $sourceKey
        artifactKind = $artifactKind
        artifactPath = $artifactPath
        manifestPath = Join-Path $root "manifest.json"
        baselinePath = Join-Path $root "event-log-baseline.json"
        rebuildMarkerPath = Join-Path $root "rebuild.marker.json"
        leasePath = Join-Path $root "seed.lease"
        writerIntentPath = Join-Path $root "seed.writer.lock"
    }
}

function Read-BranchSeedManifest {
    param([switch]$AllowMissing)

    $paths = Get-BranchSeedPaths
    if (-not (Test-Path -LiteralPath $paths.manifestPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        if ($AllowMissing) { return $null }
        throw "BRANCH_SEED_MISSING: run /itl-sync-master to create the latest branch seed. Manifest: $($paths.manifestPath)"
    }
    try {
        return (Read-Utf8Text -Path $paths.manifestPath | ConvertFrom-Json)
    } catch {
        throw "BRANCH_SEED_MANIFEST_INVALID: $($paths.manifestPath). $($_.Exception.Message)"
    }
}

function Remove-BranchSeedFileRuntimeSidecars {
    param([Parameter(Mandatory)][string]$ArtifactPath)

    $infoBaseRoot = Split-Path -Parent $ArtifactPath
    $eventLogPath = Join-Path $infoBaseRoot "1Cv8Log"
    if (Test-Path -LiteralPath $eventLogPath -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath $eventLogPath -Recurse -Force -ErrorAction Stop
    }
}

function Disconnect-BranchSeedFileFromRepository {
    param([Parameter(Mandatory)][string]$ArtifactPath)

    if (-not (Get-SourceUsesRepository)) {
        return
    }

    $infoBaseRoot = Split-Path -Parent $ArtifactPath
    Invoke-Designer `
        -InfoBasePath $infoBaseRoot `
        -InfoBaseKind "file" `
        -DesignerArgs @("/ConfigurationRepositoryUnbindCfg", "-force") | Out-Null
}

function Write-BranchSeedManifest {
    param([System.Collections.IDictionary]$Manifest)

    $paths = Get-BranchSeedPaths
    New-Item -ItemType Directory -Force -Path $paths.root | Out-Null
    Write-Utf8Text -Path $paths.manifestPath -Value (($Manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
}

function Open-BranchSeedLease {
    param(
        [ValidateSet("read", "write")]
        [string]$Mode,
        [int]$TimeoutSeconds = 600
    )

    $paths = Get-BranchSeedPaths
    New-Item -ItemType Directory -Force -Path $paths.root | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if ($Mode -eq "write") {
                return [System.IO.File]::Open(
                    $paths.leasePath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::None
                )
            }
            if (Test-Path -LiteralPath $paths.rebuildMarkerPath -PathType Leaf -ErrorAction SilentlyContinue) {
                Start-Sleep -Milliseconds 200
                continue
            }
            $reader = [System.IO.File]::Open(
                $paths.leasePath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::ReadWrite
            )
            if (Test-Path -LiteralPath $paths.rebuildMarkerPath -PathType Leaf -ErrorAction SilentlyContinue) {
                $reader.Dispose()
                Start-Sleep -Milliseconds 200
                continue
            }
            return $reader
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 200
        }
    }
    throw "BRANCH_SEED_LEASE_TIMEOUT: mode=$Mode; path=$($paths.leasePath); timeoutSeconds=$TimeoutSeconds"
}

function Open-BranchSeedWriterIntent {
    param([int]$TimeoutSeconds = 600)

    $paths = Get-BranchSeedPaths
    New-Item -ItemType Directory -Force -Path $paths.root | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            return [System.IO.File]::Open(
                $paths.writerIntentPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 200
        }
    }
    throw "BRANCH_SEED_WRITER_TIMEOUT: path=$($paths.writerIntentPath); timeoutSeconds=$TimeoutSeconds"
}

function Get-BranchSeedServerProviderCapabilities {
    $provider = Get-ConfigValue -Path "serverBaseCopyScript" -Default ""
    if (-not $provider) {
        throw "SERVER_SEED_PROVIDER_UPGRADE_REQUIRED: serverBaseCopyScript is required and must implement schema v2."
    }
    $providerPath = Resolve-ProjectPath $provider
    if (-not (Test-Path -LiteralPath $providerPath -PathType Leaf)) {
        throw "SERVER_SEED_PROVIDER_UPGRADE_REQUIRED: provider was not found: $providerPath"
    }

    $output = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $providerPath `
        -Operation "capabilities" `
        -ProjectRoot $script:ProjectRoot 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "SERVER_SEED_PROVIDER_UPGRADE_REQUIRED: capabilities probe failed with exit code $LASTEXITCODE. $($output -join ' ')"
    }
    try {
        $contract = (($output -join [Environment]::NewLine) | ConvertFrom-Json)
    } catch {
        throw "SERVER_SEED_PROVIDER_UPGRADE_REQUIRED: capabilities output is not schema v2 JSON. $($_.Exception.Message)"
    }
    $capabilities = @($contract.capabilities | ForEach-Object { [string]$_ })
    if ([int]$contract.schemaVersion -ne 2 -or
        $capabilities -notcontains "restore-seed" -or
        $capabilities -notcontains "event-log-baseline") {
        throw "SERVER_SEED_PROVIDER_UPGRADE_REQUIRED: schemaVersion=2 and capabilities 'restore-seed' plus 'event-log-baseline' are required."
    }
    return [pscustomobject]@{
        path = $providerPath
        schemaVersion = 2
        capabilities = $capabilities
    }
}

function Get-SourceEventLogSeedBaseline {
    $kind = Get-InfoBaseKind
    if ($kind -ne "file") {
        $provider = Get-BranchSeedServerProviderCapabilities
        $output = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $provider.path `
            -Operation "event-log-baseline" `
            -ProjectRoot $script:ProjectRoot `
            -SourceInfoBasePath (Get-SourceInfoBasePath) 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "SERVER_SEED_BASELINE_FAILED: provider exited with code $LASTEXITCODE. $($output -join ' ')"
        }
        try {
            $providerBaseline = (($output -join [Environment]::NewLine) | ConvertFrom-Json)
        } catch {
            throw "SERVER_SEED_BASELINE_INVALID: provider output is not JSON. $($_.Exception.Message)"
        }
        if ([int]$providerBaseline.schemaVersion -ne 2 -or $null -eq $providerBaseline.PSObject.Properties["signatures"]) {
            throw "SERVER_SEED_BASELINE_INVALID: schemaVersion=2 and signatures are required."
        }
        $signatures = @($providerBaseline.signatures | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
        return [ordered]@{
            schemaVersion = 2
            createdAt = (Get-Date).ToString("o")
            reason = "source-seed"
            reader = "server-provider"
            logDirectory = ""
            errorCount = [int](Get-StateValue -State $providerBaseline -Name "errorCount" -Default $signatures.Count)
            signatureCount = $signatures.Count
            signatures = $signatures
            durationMs = [int64](Get-StateValue -State $providerBaseline -Name "durationMs" -Default 0)
            cache = [ordered]@{
                status = [string](Get-StateValue -State $providerBaseline -Name "cacheStatus" -Default "provider")
                path = [string](Get-StateValue -State $providerBaseline -Name "cachePath" -Default "")
                sourceKey = [string](Get-StateValue -State $providerBaseline -Name "sourceKey" -Default "")
                segmentCount = [int](Get-StateValue -State $providerBaseline -Name "segmentCount" -Default 0)
            }
            failureEvidence = ""
        }
    }

    $sourceState = [pscustomobject]@{
        infoBaseKind = "file"
        devBranchInfoBasePath = Get-SourceInfoBasePath
        mainWorktreePath = Get-MainWorktreePath
        stateProjectRoot = Get-MainWorktreePath
    }
    try {
        $readResult = Read-DevBranchEventLogBaselineWithCache -State $sourceState
    } catch {
        if ($_.Exception.Message -notmatch "1Cv8\.lgf was not found") {
            throw
        }
        return [ordered]@{
            schemaVersion = 2
            createdAt = (Get-Date).ToString("o")
            reason = "source-seed"
            reader = "direct-stream"
            logDirectory = Join-Path (Resolve-InfoBasePath (Get-SourceInfoBasePath)) "1Cv8Log"
            errorCount = 0
            signatureCount = 0
            signatures = @()
            durationMs = 0
            cache = [ordered]@{
                status = "empty-source-log"
                path = ""
                sourceKey = ""
                segmentCount = 0
            }
            failureEvidence = ""
        }
    }
    $signatures = @($readResult.signatures)
    return [ordered]@{
        schemaVersion = 2
        createdAt = (Get-Date).ToString("o")
        reason = "source-seed"
        reader = $readResult.reader
        logDirectory = $readResult.logDirectory
        errorCount = $readResult.errorCount
        signatureCount = $signatures.Count
        signatures = $signatures
        durationMs = $readResult.durationMs
        cache = [ordered]@{
            status = $readResult.cacheStatus
            path = $readResult.cachePath
            sourceKey = $readResult.sourceKey
            segmentCount = $readResult.segmentCount
        }
        failureEvidence = ""
    }
}

function Test-BranchSeedArtifactReady {
    param([object]$Manifest)

    if ($null -eq $Manifest -or [string]$Manifest.status -ne "ready") { return $false }
    $paths = Get-BranchSeedPaths
    if ([string]$Manifest.sourceKey -cne $paths.sourceKey) { return $false }
    if ([string]$Manifest.artifactKind -cne $paths.artifactKind) { return $false }
    if (Test-Path -LiteralPath $paths.rebuildMarkerPath -PathType Leaf -ErrorAction SilentlyContinue) { return $false }
    if ((Resolve-Agent1cFullPath -Path ([string]$Manifest.artifactPath)) -cne (Resolve-Agent1cFullPath -Path $paths.artifactPath)) { return $false }
    if (-not (Test-Path -LiteralPath $paths.artifactPath -PathType Leaf -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Test-Path -LiteralPath $paths.baselinePath -PathType Leaf -ErrorAction SilentlyContinue)) { return $false }
    return (Get-Item -LiteralPath $paths.artifactPath).Length -gt 0
}

function Assert-BranchSeedReady {
    param([string]$ExpectedConfigurationFingerprint = "")

    $manifest = Read-BranchSeedManifest
    if ([string]$manifest.status -eq "failed") {
        throw "BRANCH_SEED_FAILED: repeat /itl-sync-master after addressing the recorded failure. Manifest: $((Get-BranchSeedPaths).manifestPath). Error: $($manifest.failureEvidence)"
    }
    if (-not (Test-BranchSeedArtifactReady -Manifest $manifest)) {
        throw "BRANCH_SEED_NOT_READY: run /itl-sync-master. Manifest: $((Get-BranchSeedPaths).manifestPath)"
    }
    if ($ExpectedConfigurationFingerprint -and [string]$manifest.configurationFingerprint -cne $ExpectedConfigurationFingerprint) {
        throw "BRANCH_SEED_INCOMPATIBLE: expected configuration fingerprint $ExpectedConfigurationFingerprint, seed has $($manifest.configurationFingerprint)."
    }
    return $manifest
}

function New-BranchSeed {
    param(
        [string]$ConfigurationFingerprint,
        [int]$ConfigurationFileCount = 0,
        [switch]$DumpConfigurationFromSeed
    )

    $paths = Get-BranchSeedPaths
    $writerIntent = Open-BranchSeedWriterIntent
    $lease = $null
    $syncId = [guid]::NewGuid().ToString("N")
    $startedAt = (Get-Date).ToString("o")
    $kind = Get-InfoBaseKind
    $provider = $null
    try {
        New-Item -ItemType Directory -Force -Path $paths.root | Out-Null
        Write-Utf8Text -Path $paths.rebuildMarkerPath -Value (([ordered]@{
            schemaVersion = 1
            status = "rebuilding"
            syncId = $syncId
            sourceKey = $paths.sourceKey
            startedAt = $startedAt
        } | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
        $lease = Open-BranchSeedLease -Mode write
        Write-BranchSeedManifest -Manifest ([ordered]@{
            schemaVersion = 1
            status = "rebuilding"
            sourceKey = $paths.sourceKey
            syncId = $syncId
            artifactKind = $paths.artifactKind
            artifactPath = $paths.artifactPath
            configurationFingerprint = $ConfigurationFingerprint
            configurationFileCount = $ConfigurationFileCount
            baselinePath = $paths.baselinePath
            baselineHash = ""
            baselineCount = 0
            startedAt = $startedAt
            completedAt = ""
            failedAt = ""
            failureEvidence = ""
        })

        if (Test-Path -LiteralPath $paths.artifactPath -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $paths.artifactPath -Force
        }
        if ($kind -eq "file") {
            Remove-BranchSeedFileRuntimeSidecars -ArtifactPath $paths.artifactPath
        }
        $artifactParent = Split-Path -Parent $paths.artifactPath
        New-Item -ItemType Directory -Force -Path $artifactParent | Out-Null

        $baseline = Get-SourceEventLogSeedBaseline
        Write-Utf8Text -Path $paths.baselinePath -Value (($baseline | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

        if ($kind -eq "file") {
            $sourceArtifact = Join-Path (Resolve-InfoBasePath (Get-SourceInfoBasePath)) "1Cv8.1CD"
            if (-not (Test-Path -LiteralPath $sourceArtifact -PathType Leaf)) {
                throw "BRANCH_SEED_SOURCE_ARTIFACT_MISSING: $sourceArtifact"
            }
            Copy-Item -LiteralPath $sourceArtifact -Destination $paths.artifactPath
        } else {
            $provider = Get-BranchSeedServerProviderCapabilities
            Invoke-Designer `
                -InfoBasePath (Get-SourceInfoBasePath) `
                -InfoBaseKind "server" `
                -DesignerArgs @("/DumpIB", $paths.artifactPath) | Out-Null
        }
        if (-not (Test-Path -LiteralPath $paths.artifactPath -PathType Leaf) -or (Get-Item -LiteralPath $paths.artifactPath).Length -le 0) {
            throw "BRANCH_SEED_ARTIFACT_EMPTY: $($paths.artifactPath)"
        }

        if ($kind -eq "file") {
            Disconnect-BranchSeedFileFromRepository -ArtifactPath $paths.artifactPath
        }

        if ($DumpConfigurationFromSeed -and $kind -eq "file") {
            $seedInfoBasePath = Split-Path -Parent $paths.artifactPath
            $dumpResult = Dump-ConfigToFilesFromInfoBase -InfoBasePath $seedInfoBasePath -InfoBaseKind "file"
            $configSource = Get-ConfigSourceFingerprint -ExportPath $dumpResult.exportPath
            $ConfigurationFingerprint = $configSource.fingerprint
            $ConfigurationFileCount = $configSource.fileCount
            Remove-BranchSeedFileRuntimeSidecars -ArtifactPath $paths.artifactPath
        }

        $baselineHash = Get-StringSha256 -Value ((@($baseline.signatures) -join "`n"))
        $completedAt = (Get-Date).ToString("o")
        Write-BranchSeedManifest -Manifest ([ordered]@{
            schemaVersion = 1
            status = "ready"
            sourceKey = $paths.sourceKey
            syncId = $syncId
            artifactKind = $paths.artifactKind
            artifactPath = $paths.artifactPath
            artifactSha256 = (Get-FileHash -LiteralPath $paths.artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
            artifactBytes = (Get-Item -LiteralPath $paths.artifactPath).Length
            configurationFingerprint = $ConfigurationFingerprint
            configurationFileCount = $ConfigurationFileCount
            baselinePath = $paths.baselinePath
            baselineHash = $baselineHash
            baselineCount = @($baseline.signatures).Count
            baselineErrorCount = [int]$baseline.errorCount
            baselineReader = [string]$baseline.reader
            baselineFailureEvidence = [string]$baseline.failureEvidence
            providerSchemaVersion = $(if ($provider) { 2 } else { 0 })
            providerCapabilities = $(if ($provider) { @($provider.capabilities) } else { @() })
            startedAt = $startedAt
            completedAt = $completedAt
            failedAt = ""
            failureEvidence = ""
        })
        Remove-Item -LiteralPath $paths.rebuildMarkerPath -Force -ErrorAction SilentlyContinue
        return (Read-BranchSeedManifest)
    } catch {
        $failure = $_.Exception.Message
        if ($null -ne $lease -and (Test-Path -LiteralPath $paths.artifactPath -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $paths.artifactPath -Force -ErrorAction SilentlyContinue
        }
        if ($kind -eq "file") {
            try {
                Remove-BranchSeedFileRuntimeSidecars -ArtifactPath $paths.artifactPath
            } catch {}
        }
        Write-BranchSeedManifest -Manifest ([ordered]@{
            schemaVersion = 1
            status = "failed"
            sourceKey = $paths.sourceKey
            syncId = $syncId
            artifactKind = $paths.artifactKind
            artifactPath = $paths.artifactPath
            configurationFingerprint = $ConfigurationFingerprint
            configurationFileCount = $ConfigurationFileCount
            baselinePath = $paths.baselinePath
            baselineHash = ""
            baselineCount = 0
            startedAt = $startedAt
            completedAt = ""
            failedAt = (Get-Date).ToString("o")
            failureEvidence = $failure
        })
        Remove-Item -LiteralPath $paths.rebuildMarkerPath -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
        $writerIntent.Dispose()
    }
}

function Ensure-BranchSeed {
    param(
        [ValidateSet("EnsureCompatible", "Rebuild")]
        [string]$Policy,
        [string]$ConfigurationFingerprint,
        [int]$ConfigurationFileCount = 0
    )

    if ($Policy -eq "EnsureCompatible") {
        $existing = Read-BranchSeedManifest -AllowMissing
        if ($null -ne $existing -and [string]$existing.status -eq "failed") {
            throw "BRANCH_SEED_FAILED: explicit /itl-sync-master is required to recover the seed. Error: $($existing.failureEvidence)"
        }
        if ((Test-BranchSeedArtifactReady -Manifest $existing) -and [string]$existing.configurationFingerprint -ceq $ConfigurationFingerprint) {
            Write-Host "Compatible branch seed reused: $($existing.artifactPath)"
            return $existing
        }
    }
    return (New-BranchSeed `
        -ConfigurationFingerprint $ConfigurationFingerprint `
        -ConfigurationFileCount $ConfigurationFileCount `
        -DumpConfigurationFromSeed:((Get-InfoBaseKind) -eq "file"))
}

function Restore-DevBranchFromSeed {
    param(
        [string]$DevBranchName,
        [string]$DevBranchInfoBasePath,
        [object]$ExistingLease = $null
    )

    $lease = if ($null -ne $ExistingLease) { $ExistingLease } else { Open-BranchSeedLease -Mode read }
    $ownsLease = $null -eq $ExistingLease
    try {
        $manifest = Assert-BranchSeedReady
        if ((Get-InfoBaseKind) -eq "file") {
            if (Test-Path -LiteralPath $DevBranchInfoBasePath -ErrorAction SilentlyContinue) {
                throw "Development branch infobase path already exists: $DevBranchInfoBasePath"
            }
            New-Item -ItemType Directory -Force -Path $DevBranchInfoBasePath | Out-Null
            Copy-Item -LiteralPath ([string]$manifest.artifactPath) -Destination (Join-Path $DevBranchInfoBasePath "1Cv8.1CD")
        } else {
            $provider = Get-BranchSeedServerProviderCapabilities
            & powershell -NoProfile -ExecutionPolicy Bypass -File $provider.path `
                -Operation "restore-seed" `
                -ProjectRoot $script:ProjectRoot `
                -DevBranchName $DevBranchName `
                -SeedArtifactPath ([string]$manifest.artifactPath) `
                -DevBranchInfoBasePath $DevBranchInfoBasePath
            if ($LASTEXITCODE -ne 0) {
                throw "Server seed restore provider failed with exit code $LASTEXITCODE."
            }
        }
        return $manifest
    } finally {
        if ($ownsLease) { $lease.Dispose() }
    }
}
