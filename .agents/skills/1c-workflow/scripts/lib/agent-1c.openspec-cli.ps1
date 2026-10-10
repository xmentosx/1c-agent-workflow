function Get-ItlOpenSpecCliPin {
    $entry = Get-DependencyLockEntry -Name 'openSpecCli'
    $version = [string](Get-ConfigValueFromObject -Object $entry -Path 'version' -Default '')
    $expectedLockHash = [string](Get-ConfigValueFromObject -Object $entry -Path 'packageLockSha256' -Default '')
    $expectedIntegrity = [string](Get-ConfigValueFromObject -Object $entry -Path 'integrity' -Default '')
    if ($version -notmatch '^\d+\.\d+\.\d+$' -or $expectedLockHash -notmatch '^[0-9a-fA-F]{64}$' -or -not $expectedIntegrity) {
        throw 'OPEN_SPEC_CLI_PIN_MISSING: restore the exact openSpecCli dependency-lock entry through update-workflow.'
    }
    $resourceRoot = Join-Path (Split-Path -Parent $script:Agent1cScriptRoot) 'resources\openspec-cli'
    $packagePath = Join-Path $resourceRoot 'package.json'
    $lockPath = Join-Path $resourceRoot 'package-lock.json'
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf) -or -not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw 'OPEN_SPEC_CLI_PACKAGE_MISSING: restore the managed OpenSpec package files through update-workflow.'
    }
    $actualLockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualLockHash -ne $expectedLockHash.ToLowerInvariant()) {
        throw 'OPEN_SPEC_CLI_LOCK_DRIFT: the installed package-lock does not match the project dependency pin.'
    }
    $package = Read-Utf8Text -Path $packagePath | ConvertFrom-Json
    # npm lock v3 uses an empty property name for the package root. Windows
    # PowerShell 5.1 cannot deserialize it, so rename only that parser key
    # after the complete lock bytes have passed the SHA-256 check above.
    $lockText = (Read-Utf8Text -Path $lockPath) -replace '"":\s*\{', '"__packageRoot__": {'
    $lock = $lockText | ConvertFrom-Json
    $lockedPackage = $lock.packages.PSObject.Properties['node_modules/@fission-ai/openspec'].Value
    if ([string]$package.dependencies.'@fission-ai/openspec' -ne $version -or
        [string]$lockedPackage.version -ne $version -or
        [string]$lockedPackage.integrity -cne $expectedIntegrity) {
        throw 'OPEN_SPEC_CLI_PIN_CONFLICT: package, transitive lock, and project pin disagree.'
    }
    return [pscustomobject]@{ version = $version; packageRoot = $resourceRoot; packageLockSha256 = $actualLockHash }
}

function Get-ItlOpenSpecCliRuntimeRoot {
    param([Parameter(Mandatory = $true)][string]$Version)
    return (Join-Path $script:ProjectRoot ".agent-1c\tools\openspec-cli\$Version")
}

function Resolve-ItlOpenSpecCli {
    try { $pin = Get-ItlOpenSpecCliPin } catch {
        return [pscustomobject]@{ available = $false; reason = $_.Exception.Message; path = ''; nodePath = ''; version = '' }
    }
    $root = Get-ItlOpenSpecCliRuntimeRoot -Version $pin.version
    $receiptPath = Join-Path $root 'itl-runtime.json'
    $entryPath = Join-Path $root 'node_modules\@fission-ai\openspec\bin\openspec.js'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        return [pscustomobject]@{ available = $false; reason = "OPEN_SPEC_CLI_NOT_PROVISIONED: run -Action provision-openspec-cli for pin $($pin.version)."; path = ''; nodePath = ''; version = $pin.version }
    }
    try {
        $receipt = Read-Utf8Text -Path $receiptPath | ConvertFrom-Json
        $nodePath = [string]$receipt.nodePath
        if (-not [IO.Path]::IsPathRooted($nodePath) -or -not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
            throw 'recorded Node executable is missing'
        }
        if ([string]$receipt.version -ne $pin.version -or
            [string]$receipt.packageLockSha256 -ne $pin.packageLockSha256 -or
            (Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash -ine [string]$receipt.nodeSha256 -or
            (Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash -ine [string]$receipt.entrySha256) {
            throw 'the recorded Node/CLI pair or package lock changed'
        }
        return [pscustomobject]@{ available = $true; reason = ''; path = $entryPath; nodePath = $nodePath; version = $pin.version }
    } catch {
        return [pscustomobject]@{ available = $false; reason = "OPEN_SPEC_CLI_RUNTIME_DRIFT: $($_.Exception.Message). Preserve this runtime and provision a repaired versioned generation."; path = ''; nodePath = ''; version = $pin.version }
    }
}

function Provision-ItlOpenSpecCli {
    $pin = Get-ItlOpenSpecCliPin
    $existing = Resolve-ItlOpenSpecCli
    if ($existing.available) { return $existing }
    $target = Get-ItlOpenSpecCliRuntimeRoot -Version $pin.version
    if (Test-Path -LiteralPath $target) {
        throw "OPEN_SPEC_CLI_RUNTIME_CONFLICT: '$target' already exists but cannot be verified ($($existing.reason)). Preserve it for diagnosis; do not overwrite it."
    }
    $nodeCommand = @(Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($nodeCommand.Count -eq 0) { throw 'OPEN_SPEC_CLI_NODE_MISSING: install a supported Node runtime, then repeat provision-openspec-cli.' }
    $nodePath = [IO.Path]::GetFullPath([string]$nodeCommand[0].Source)
    $npmCli = Join-Path (Split-Path -Parent $nodePath) 'node_modules\npm\bin\npm-cli.js'
    if (-not (Test-Path -LiteralPath $npmCli -PathType Leaf)) {
        throw "OPEN_SPEC_CLI_NPM_MISSING: npm-cli.js is not paired with '$nodePath'."
    }
    $nodeVersionText = (& $nodePath --version).TrimStart('v')
    if ($LASTEXITCODE -ne 0 -or [version]$nodeVersionText -lt [version]'20.19.0') {
        throw "OPEN_SPEC_CLI_NODE_UNSUPPORTED: '$nodePath' reports $nodeVersionText; 20.19.0 or newer is required."
    }
    $parent = Split-Path -Parent $target
    Assert-WorkflowManagedTargetPath -Path $parent
    $cursor = $parent
    while ($cursor -and (Test-Path -LiteralPath $cursor) -and $cursor -ne $script:ProjectRoot) {
        if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "OPEN_SPEC_CLI_RUNTIME_REPARSE_POINT: refusing to provision through '$cursor'."
        }
        $cursor = Split-Path -Parent $cursor
    }
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $staging = Join-Path $parent ('.staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        Copy-Item -LiteralPath (Join-Path $pin.packageRoot 'package.json') -Destination $staging
        Copy-Item -LiteralPath (Join-Path $pin.packageRoot 'package-lock.json') -Destination $staging
        $npmOutput = @(& $nodePath $npmCli ci --prefix $staging --ignore-scripts --no-audit --no-fund 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "OPEN_SPEC_CLI_NPM_CI_FAILED: $($npmOutput -join ' ')" }
        $entryPath = Join-Path $staging 'node_modules\@fission-ai\openspec\bin\openspec.js'
        if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) { throw 'OPEN_SPEC_CLI_ENTRY_MISSING: npm ci did not install the pinned CLI entrypoint.' }
        $installedVersion = (& $nodePath $entryPath --version).Trim()
        if ($LASTEXITCODE -ne 0 -or $installedVersion -ne $pin.version) {
            throw "OPEN_SPEC_CLI_VERSION_MISMATCH: expected $($pin.version), installed '$installedVersion'."
        }
        $receipt = [ordered]@{
            schemaVersion = 1
            version = $pin.version
            packageLockSha256 = $pin.packageLockSha256
            nodePath = $nodePath
            nodeVersion = $nodeVersionText
            nodeSha256 = (Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash.ToLowerInvariant()
            entrySha256 = (Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        Write-Utf8TextAtomic -Path (Join-Path $staging 'itl-runtime.json') -Value (($receipt | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
        if (Test-Path -LiteralPath $target) { throw "OPEN_SPEC_CLI_RUNTIME_CONFLICT: '$target' appeared during provisioning." }
        Move-Item -LiteralPath $staging -Destination $target
    } finally {
        if (Test-Path -LiteralPath $staging) {
            $stagingFull = [IO.Path]::GetFullPath($staging)
            $parentFull = [IO.Path]::GetFullPath($parent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $stagingFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove a staging path outside '$parent': $stagingFull" }
            Remove-Item -LiteralPath $stagingFull -Recurse -Force
        }
    }
    $resolved = Resolve-ItlOpenSpecCli
    if (-not $resolved.available) { throw "OPEN_SPEC_CLI_PROVISION_VERIFY_FAILED: $($resolved.reason)" }
    return $resolved
}

function Invoke-ItlPinnedOpenSpecJson {
    param(
        [Parameter(Mandatory = $true)][object]$Cli,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = $script:ProjectRoot
    )
    if (-not [bool]$Cli.available -or -not $Cli.nodePath -or -not $Cli.path) {
        throw 'OPEN_SPEC_CLI_UNAVAILABLE: provision the exact project-pinned OpenSpec runtime first.'
    }
    $result = Invoke-ItlNativeProcessCapture -FilePath ([string]$Cli.nodePath) -Arguments (@([string]$Cli.path) + $Arguments) -WorkingDirectory $WorkingDirectory
    if ($result.exitCode -ne 0) {
        $detail = [string]$result.stderr
        if (-not $detail) { $detail = [string]$result.stdout }
        if ($detail.Length -gt 4000) { $detail = $detail.Substring(0, 4000) }
        throw "OPEN_SPEC_CLI_COMMAND_FAILED: $($Arguments -join ' ') exited $($result.exitCode): $detail"
    }
    try {
        return ($result.stdout | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "OPEN_SPEC_CLI_JSON_INVALID: $($Arguments -join ' ') did not return valid JSON: $($_.Exception.Message)"
    }
}

function Assert-ItlOpenSpecStorePhysicalRoot {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $cursor = [IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "OPEN_SPEC_STORE_REPARSE_PATH: '$cursor' is a junction or symlink. Select the physical store path before writing."
            }
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or [string]::Equals($parent, $cursor, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = $parent
    }
}

function Resolve-ItlOpenSpecStore {
    param(
        [AllowNull()][object]$Cli = $null,
        [string]$StoreId = ''
    )
    if ($null -eq $Cli) { $Cli = Resolve-ItlOpenSpecCli }
    if (-not [bool]$Cli.available) { throw [string]$Cli.reason }
    if (-not $StoreId) {
        $StoreId = [string](Get-ConfigValueFromObject -Object $script:Config -Path 'openSpec.storeId' -Default '')
    }
    if ($StoreId -and $StoreId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') {
        throw "OPEN_SPEC_STORE_ID_INVALID: '$StoreId' is not a valid registered store id."
    }
    $arguments = @('context', '--json')
    if ($StoreId) { $arguments += @('--store', $StoreId) }
    $context = Invoke-ItlPinnedOpenSpecJson -Cli $Cli -Arguments $arguments -WorkingDirectory $script:ProjectRoot
    $rootPath = [string](Get-ConfigValueFromObject -Object $context -Path 'root.path' -Default '')
    $source = [string](Get-ConfigValueFromObject -Object $context -Path 'root.source' -Default '')
    if (-not [IO.Path]::IsPathRooted($rootPath) -or -not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "OPEN_SPEC_STORE_ROOT_INVALID: CLI returned a missing or non-absolute root '$rootPath'."
    }
    $rootPath = [IO.Path]::GetFullPath($rootPath).TrimEnd('\', '/')
    Assert-ItlOpenSpecStorePhysicalRoot -RootPath $rootPath
    $checkout = [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\', '/')
    if ($StoreId -or $source -in @('store', 'declared', 'global_default')) {
        throw "OPEN_SPEC_EXTERNAL_STORE_DEFERRED: pinned CLI selected source '$source', id '$StoreId', root '$rootPath'. This ITL release supports local OpenSpec only. Preserve the existing store selection and documents; use an explicitly chosen local workspace for this project or wait for add-external-openspec-store."
    }
    if ($source -eq 'nearest') {
        if (-not [string]::Equals($rootPath, $checkout, [StringComparison]::OrdinalIgnoreCase)) {
            throw "OPEN_SPEC_LOCAL_ROOT_MISMATCH: nearest root '$rootPath' differs from checkout '$checkout'."
        }
    } else {
        throw "OPEN_SPEC_LOCAL_DEFAULT_MISSING: CLI resolved '$source' at '$rootPath'; restore or initialize this checkout's local OpenSpec workspace before retrying."
    }
    return [pscustomobject]@{
        checkoutPath = $checkout
        rootPath = $rootPath
        source = $source
        storeId = $(if ($StoreId) { $StoreId } else { [string](Get-ConfigValueFromObject -Object $context -Path 'root.id' -Default '') })
        cliVersion = [string]$Cli.version
        cliPath = [string]$Cli.path
        cliNodePath = [string]$Cli.nodePath
    }
}

function Assert-ItlOpenSpecStoreBinding {
    param(
        [Parameter(Mandatory = $true)][object]$Store,
        [AllowNull()][object]$Cli = $null
    )

    if ($null -eq $Cli) { $Cli = Resolve-ItlOpenSpecCli }
    if (-not [bool]$Cli.available) { throw [string]$Cli.reason }
    $current = Resolve-ItlOpenSpecStore -Cli $Cli
    $pathEqual = [string]::Equals([string]$current.rootPath, [string]$Store.rootPath, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$current.checkoutPath, [string]$Store.checkoutPath, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$current.cliPath, [string]$Store.cliPath, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$current.cliNodePath, [string]$Store.cliNodePath, [StringComparison]::OrdinalIgnoreCase)
    if (-not $pathEqual -or [string]$current.source -cne [string]$Store.source -or
        [string]$current.storeId -cne [string]$Store.storeId -or
        [string]$current.cliVersion -cne [string]$Store.cliVersion) {
        throw "OPEN_SPEC_STORE_BINDING_CHANGED: the selected store or CLI for '$($Store.checkoutPath)' changed after planning. Preserve the candidate, resolve the current store through the pinned CLI, then retry against its actual revisions."
    }
    return $current
}

function Invoke-ItlLocalOpenSpecNewChange {
    param([Parameter(Mandatory = $true)][string]$ChangeId)

    if ($ChangeId -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "OPEN_SPEC_CHANGE_ID_INVALID: '$ChangeId' must be a lowercase kebab-case change id."
    }
    $cli = Resolve-ItlOpenSpecCli
    $store = Resolve-ItlOpenSpecStore -Cli $cli
    Invoke-ItlPinnedOpenSpecJson -Cli $cli -Arguments @('new', 'change', $ChangeId, '--json') `
        -WorkingDirectory $script:ProjectRoot | Out-Null
    $changeRoot = Join-Path ([string]$store.rootPath) ("openspec\changes\$ChangeId")
    if (-not (Test-Path -LiteralPath (Join-Path $changeRoot '.openspec.yaml') -PathType Leaf)) {
        throw "OPEN_SPEC_LOCAL_SCAFFOLD_INCOMPLETE: pinned CLI did not create metadata for '$ChangeId'; inspect '$changeRoot' before retrying."
    }
    return [pscustomobject]@{status='created';changeId=$ChangeId;changeRoot=$changeRoot;rootPath=[string]$store.rootPath}
}

function Invoke-ItlLocalOpenSpecArchiveChange {
    param(
        [Parameter(Mandatory = $true)][string]$ChangeId,
        [switch]$SkipSpecs
    )

    $cli = Resolve-ItlOpenSpecCli
    $store = Resolve-ItlOpenSpecStore -Cli $cli
    $null = Resolve-ItlOpenSpecChangeContext -Store $store -ChangeId $ChangeId -Cli $cli
    $arguments = @('archive', $ChangeId, '--yes', '--json')
    if ($SkipSpecs) { $arguments += '--skip-specs' }
    $result = Invoke-ItlPinnedOpenSpecJson -Cli $cli -Arguments $arguments -WorkingDirectory $script:ProjectRoot
    $activeRoot = Join-Path ([string]$store.rootPath) ("openspec\changes\$ChangeId")
    if (Test-Path -LiteralPath $activeRoot) {
        throw "OPEN_SPEC_LOCAL_ARCHIVE_INCOMPLETE: pinned CLI left '$activeRoot' active; inspect its output before retrying."
    }
    return [pscustomobject]@{status='archived';changeId=$ChangeId;rootPath=[string]$store.rootPath;cliResult=$result}
}

function Resolve-ItlOpenSpecChangeContext {
    param(
        [Parameter(Mandatory = $true)][object]$Store,
        [Parameter(Mandatory = $true)][string]$ChangeId,
        [AllowNull()][object]$Cli = $null
    )
    if ($ChangeId -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "OPEN_SPEC_CHANGE_ID_INVALID: '$ChangeId' must be a lowercase kebab-case change id."
    }
    if ($null -eq $Cli) { $Cli = Resolve-ItlOpenSpecCli }
    if (-not [bool]$Cli.available) { throw [string]$Cli.reason }
    Assert-ItlOpenSpecStoreBinding -Store $Store -Cli $Cli | Out-Null
    $arguments = @('status', '--change', $ChangeId, '--json')
    if ($Store.source -eq 'store' -and $Store.storeId) { $arguments += @('--store', [string]$Store.storeId) }
    $status = Invoke-ItlPinnedOpenSpecJson -Cli $Cli -Arguments $arguments -WorkingDirectory $script:ProjectRoot
    $reportedId = [string](Get-ConfigValueFromObject -Object $status -Path 'changeName' -Default '')
    if ($reportedId -cne $ChangeId) {
        throw "OPEN_SPEC_CHANGE_ID_MISMATCH: CLI reported '$reportedId' for requested '$ChangeId'."
    }
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path ([string]$Store.rootPath) ("openspec\changes\$ChangeId"))).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $expectedRoot -PathType Container)) {
        throw "OPEN_SPEC_CHANGE_ROOT_MISSING: '$expectedRoot' is not present in the selected store."
    }
    $reportedRoot = [string](Get-ConfigValueFromObject -Object $status -Path 'changeRoot' -Default '')
    if ($reportedRoot -and -not [string]::Equals(([IO.Path]::GetFullPath($reportedRoot).TrimEnd('\', '/')), $expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "OPEN_SPEC_CHANGE_ROOT_MISMATCH: CLI reported '$reportedRoot', expected '$expectedRoot'."
    }
    $metadataPath = Join-Path $expectedRoot '.openspec.yaml'
    $metadataHash = if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } else { '' }
    $branch = ''
    if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.git')) {
        try { $branch = Get-CurrentBranch } catch { $branch = '' }
    }
    return [pscustomobject]@{
        changeId = $ChangeId
        changeRoot = $expectedRoot
        metadataSha256 = $metadataHash
        checkoutPath = [string]$Store.checkoutPath
        checkoutBranch = [string]$branch
        storeRoot = [string]$Store.rootPath
        storeSource = [string]$Store.source
        storeId = [string]$Store.storeId
        cliVersion = [string]$Cli.version
        cliPath = [string]$Cli.path
        cliNodePath = [string]$Cli.nodePath
    }
}

function Show-ItlOpenSpecContext {
    param([string]$ChangeId = '')
    $cli = Resolve-ItlOpenSpecCli
    if (-not $cli.available) { throw [string]$cli.reason }
    $store = Resolve-ItlOpenSpecStore -Cli $cli
    $result = [ordered]@{
        schemaVersion = 1
        checkoutPath = $store.checkoutPath
        rootPath = $store.rootPath
        source = $store.source
        storeId = $store.storeId
        cliVersion = $store.cliVersion
        cliPath = $store.cliPath
        cliNodePath = $store.cliNodePath
    }
    if ($ChangeId) {
        $result.change = Resolve-ItlOpenSpecChangeContext -Store $store -ChangeId $ChangeId -Cli $cli
    }
    Write-Output ($result | ConvertTo-Json -Depth 4 -Compress)
}
