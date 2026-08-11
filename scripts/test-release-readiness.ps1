[CmdletBinding()]
param(
    [ValidateSet("Full", "Develop", "Release")]
    [string]$Mode = "Full",
    [string]$RepositoryRoot = "",
    [string]$AiRulesSource = "",
    [string]$E2EProjectRoot = "",
    [string]$OutputPath = "",
    [switch]$Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
. (Join-Path $PSScriptRoot "git-path-list.ps1")
. (Join-Path $PSScriptRoot "release-qualification.ps1")
if (-not $OutputPath) { $OutputPath = Join-Path $RepositoryRoot "build\test-results\local\release-context.json" }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$startedAt = [DateTime]::UtcNow
$issues = New-Object System.Collections.Generic.List[object]

function Add-ReadinessIssue {
    param(
        [string]$Code,
        [ValidateSet("SOURCE_DEFECT", "CANDIDATE_INCOMPLETE", "DEPENDENCY_DRIFT", "STAND_STALE", "ENVIRONMENT", "RUNTIME_FAILURE")]
        [string]$Category,
        [string]$Message,
        [string]$Recovery
    )
    $script:issues.Add([ordered]@{ code = $Code; category = $Category; message = $Message; recovery = $Recovery }) | Out-Null
}

function Get-JsonFile {
    param([string]$Path, [string]$Code, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-ReadinessIssue -Code $Code -Category "CANDIDATE_INCOMPLETE" -Message "$Label is missing: $Path" -Recovery "Restore the managed file from the exact workflow candidate."
        return $null
    }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        Add-ReadinessIssue -Code $Code -Category "SOURCE_DEFECT" -Message "$Label is not valid UTF-8 JSON: $Path" -Recovery "Regenerate the file from its canonical source."
        return $null
    }
}

function Get-GitValue {
    param([string]$Root, [string[]]$Arguments)
    $value = & git -C $Root @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    return ([string]($value -join "`n")).Trim()
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ManagedTextOrBinarySha256 {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $normalizedBytes = $bytes
    if (-not ($bytes -contains [byte]0)) {
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $strictUtf8.GetString($bytes)
            $normalizedText = $text.Replace("`r`n", "`n").Replace("`r", "`n")
            $normalizedBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedText)
        } catch {
            $normalizedBytes = $bytes
        }
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($normalizedBytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-LockAgreement {
    param([object]$Expected, [object]$Actual, [string]$Label)
    if ($null -eq $Expected -or $null -eq $Actual) { return }
    foreach ($field in @("version", "compatibilityVersion", "downstreamRevision", "assetName", "url", "sha256", "epfSha256", "manifestSha256", "patchSha256", "upstreamCommit", "publicationStatus")) {
        $expectedProperty = $Expected.PSObject.Properties[$field]
        $actualProperty = $Actual.PSObject.Properties[$field]
        $expectedValue = if ($null -eq $expectedProperty) { "" } else { [string]$expectedProperty.Value }
        $actualValue = if ($null -eq $actualProperty) { "" } else { [string]$actualProperty.Value }
        if ($actualValue -cne $expectedValue) {
            Add-ReadinessIssue -Code "RELEASE_DEPENDENCY_LOCK_DRIFT" -Category "DEPENDENCY_DRIFT" `
                -Message "$Label vanessaAutomation.$field differs from the candidate lock. expected='$expectedValue'; actual='$actualValue'." `
                -Recovery "Run update-workflow from the exact candidate and commit the managed stand update before Release."
        }
    }
}

function Get-ManagedPackageInventory {
    param([string]$Root)
    $relativeRoots = @(
        ".agents\skills\1c-workflow",
        ".agents\skills\1c-workflow-fast",
        ".agents\skills\product-docs",
        ".agents\skills\itl-roctup-1c-data",
        ".agents\skills\itl-vanessa-ui-mcp",
        "docs\itl-workflow",
        "templates"
    )
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($relativeRoot in $relativeRoots) {
        $fullRoot = Join-Path $Root $relativeRoot
        if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $fullRoot -Recurse -File | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
            $entries.Add([ordered]@{ path = $relative; sha256 = Get-ManagedTextOrBinarySha256 -Path $file.FullName }) | Out-Null
        }
    }
    foreach ($relativeFile in @("AGENT-INSTALL.md", "install-agent-1c-workflow.ps1")) {
        $fullPath = Join-Path $Root $relativeFile
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $entries.Add([ordered]@{ path = $relativeFile.Replace('\', '/'); sha256 = Get-ManagedTextOrBinarySha256 -Path $fullPath }) | Out-Null
        }
    }
    return @($entries | Sort-Object path)
}

function Test-ManagedPackageAgreement {
    param([object[]]$ExpectedInventory, [string]$TargetRoot, [string]$Label)
    if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
        Add-ReadinessIssue -Code "RELEASE_STAND_PATH_MISSING" -Category "STAND_STALE" -Message "$Label root is missing: $TargetRoot" -Recovery "Provision a disposable Release stand from the exact candidate."
        return
    }
    $actualInventory = @(Get-ManagedPackageInventory -Root $TargetRoot)
    $expectedByPath = @{}
    foreach ($entry in $ExpectedInventory) { $expectedByPath[[string]$entry.path] = [string]$entry.sha256 }
    $actualByPath = @{}
    foreach ($entry in $actualInventory) { $actualByPath[[string]$entry.path] = [string]$entry.sha256 }
    $mismatches = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($expectedByPath.Keys | Sort-Object)) {
        if (-not $actualByPath.ContainsKey($path) -or $actualByPath[$path] -cne $expectedByPath[$path]) { $mismatches.Add($path) | Out-Null }
    }
    foreach ($path in @($actualByPath.Keys | Sort-Object)) {
        if (-not $expectedByPath.ContainsKey($path)) { $mismatches.Add($path) | Out-Null }
    }
    if ($mismatches.Count -gt 0) {
        $preview = @($mismatches | Select-Object -First 8) -join ", "
        Add-ReadinessIssue -Code "RELEASE_STAND_MANAGED_PACKAGE_DRIFT" -Category "STAND_STALE" `
            -Message "$Label managed workflow package differs from the candidate in $($mismatches.Count) path(s): $preview" `
            -Recovery "Run update-workflow with ITL_WORKFLOW_SOURCE_PATH set to the exact candidate, review, commit, and create or refresh the disposable Release branch."
    }
}

function Resolve-VanessaArchive {
    param([object]$Lock)
    if ($null -eq $Lock) { return $null }
    $expectedSha = [string]$Lock.sha256
    $folderName = ([string]$Lock.compatibilityVersion) + "-" + ([string]$Lock.downstreamRevision)
    $canonicalPath = Join-Path $RepositoryRoot ("build\third-party\vanessa-automation\" + $folderName + "\" + [string]$Lock.assetName)
    $configuredPath = [Environment]::GetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", "Process")
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        try { $candidates += [System.IO.Path]::GetFullPath($configuredPath) } catch {}
    }
    $candidates += $canonicalPath
    $invalidCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $actualSha = Get-FileSha256 -Path $candidate
            if ($actualSha -ceq $expectedSha.ToLowerInvariant()) {
                return [ordered]@{ path = $candidate; sha256 = $actualSha; source = $(if ($candidate -eq $configuredPath) { "environment" } else { "candidate-cache" }) }
            }
            $invalidCandidates.Add("$candidate (actual=$actualSha)") | Out-Null
        }
    }
    if ($Offline) {
        if ($invalidCandidates.Count -gt 0) {
            Add-ReadinessIssue -Code "RELEASE_VANESSA_ARCHIVE_HASH_MISMATCH" -Category "DEPENDENCY_DRIFT" `
                -Message "No Vanessa Automation candidate matched SHA256 '$expectedSha'. Invalid candidate(s): $($invalidCandidates -join '; ')." `
                -Recovery "Remove invalid candidates and provide the exact immutable asset."
        }
        Add-ReadinessIssue -Code "RELEASE_VANESSA_ARCHIVE_MISSING" -Category "CANDIDATE_INCOMPLETE" `
            -Message "Qualified Vanessa Automation archive is missing in offline mode: $canonicalPath" `
            -Recovery "Place the immutable locked asset at the canonical path or set ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE."
        return $null
    }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $canonicalPath) | Out-Null
        $partialPath = $canonicalPath + ".partial"
        Invoke-WebRequest -UseBasicParsing -Uri ([string]$Lock.url) -OutFile $partialPath
        $downloadedSha = Get-FileSha256 -Path $partialPath
        if ($downloadedSha -cne $expectedSha.ToLowerInvariant()) { throw "downloaded SHA256 '$downloadedSha' differs from '$expectedSha'" }
        Move-Item -LiteralPath $partialPath -Destination $canonicalPath -Force
        return [ordered]@{ path = $canonicalPath; sha256 = $downloadedSha; source = "locked-url" }
    } catch {
        if ($invalidCandidates.Count -gt 0) {
            Add-ReadinessIssue -Code "RELEASE_VANESSA_ARCHIVE_HASH_MISMATCH" -Category "DEPENDENCY_DRIFT" `
                -Message "No Vanessa Automation candidate matched SHA256 '$expectedSha'. Invalid candidate(s): $($invalidCandidates -join '; ')." `
                -Recovery "Remove invalid candidates and acquire the immutable asset from the locked URL."
        }
        Add-ReadinessIssue -Code "RELEASE_VANESSA_ARCHIVE_ACQUIRE_FAILED" -Category "ENVIRONMENT" `
            -Message "Unable to acquire the immutable Vanessa Automation archive: $($_.Exception.Message)" `
            -Recovery "Verify network access to the locked URL or provide the exact archive through ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE."
        return $null
    }
}

function Get-ZipEntrySha256 {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$EntryName
    )
    $entry = $Archive.Entries | Where-Object { $_.FullName -ceq $EntryName } | Select-Object -First 1
    if ($null -eq $entry) { return $null }
    $stream = $entry.Open()
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    return [ordered]@{ entry = $entry; sha256 = $hash }
}

function Test-VanessaArchiveContract {
    param([object]$ArchiveRecord, [object]$Lock)
    if ($null -eq $ArchiveRecord -or $null -eq $Lock) { return }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead([string]$ArchiveRecord.path)
        try {
            $epf = Get-ZipEntrySha256 -Archive $zip -EntryName "vanessa-automation-single.epf"
            $manifest = Get-ZipEntrySha256 -Archive $zip -EntryName "ITL-PROVENANCE.json"
            $notice = $zip.Entries | Where-Object { $_.FullName -ceq "ITL-NOTICE.txt" } | Select-Object -First 1
            if ($null -eq $epf -or $null -eq $manifest -or $null -eq $notice) {
                Add-ReadinessIssue -Code "RELEASE_VANESSA_ARCHIVE_STRUCTURE_INVALID" -Category "CANDIDATE_INCOMPLETE" `
                    -Message "Vanessa Automation archive must contain vanessa-automation-single.epf, ITL-PROVENANCE.json, and ITL-NOTICE.txt." `
                    -Recovery "Acquire the exact immutable workflow-pinned asset."
                return
            }
            if ([string]$epf.sha256 -cne ([string]$Lock.epfSha256).ToLowerInvariant()) {
                Add-ReadinessIssue -Code "RELEASE_VANESSA_EPF_HASH_MISMATCH" -Category "DEPENDENCY_DRIFT" `
                    -Message "Vanessa Automation EPF SHA256 differs from the lock. expected=$($Lock.epfSha256); actual=$($epf.sha256)." `
                    -Recovery "Use an archive built and published from the exact downstream revision."
            }
            if ([string]$manifest.sha256 -cne ([string]$Lock.manifestSha256).ToLowerInvariant()) {
                Add-ReadinessIssue -Code "RELEASE_VANESSA_MANIFEST_HASH_MISMATCH" -Category "DEPENDENCY_DRIFT" `
                    -Message "Vanessa Automation provenance manifest SHA256 differs from the lock. expected=$($Lock.manifestSha256); actual=$($manifest.sha256)." `
                    -Recovery "Regenerate the lock from the exact immutable artifact manifest."
            }
            $reader = [System.IO.StreamReader]::new($manifest.entry.Open(), [System.Text.Encoding]::UTF8, $true)
            try { $provenance = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            foreach ($pair in @(
                @("compatibilityVersion", [string]$provenance.compatibilityVersion, [string]$Lock.compatibilityVersion),
                @("downstreamRevision", [string]$provenance.downstreamRevision, [string]$Lock.downstreamRevision),
                @("upstreamCommit", [string]$provenance.upstream.commit, [string]$Lock.upstreamCommit),
                @("patchSha256", [string]$provenance.patch.sha256, [string]$Lock.patchSha256),
                @("artifactFileName", [string]$provenance.artifact.fileName, [string]$Lock.assetName),
                @("artifactEntryPoint", [string]$provenance.artifact.entryPoint, "vanessa-automation-single.epf")
            )) {
                if ([string]$pair[1] -cne [string]$pair[2]) {
                    Add-ReadinessIssue -Code "RELEASE_VANESSA_PROVENANCE_DRIFT" -Category "DEPENDENCY_DRIFT" `
                        -Message "Vanessa Automation provenance $($pair[0]) differs from the lock. expected='$($pair[2])'; actual='$($pair[1])'." `
                        -Recovery "Use one manifest as the source for the asset, compatibility metadata, and dependency lock."
                }
            }
        } finally {
            $zip.Dispose()
        }
    } catch {
        Add-ReadinessIssue -Code "RELEASE_VANESSA_ARCHIVE_UNREADABLE" -Category "CANDIDATE_INCOMPLETE" `
            -Message "Vanessa Automation archive is not a readable qualified ZIP: $($_.Exception.Message)" `
            -Recovery "Acquire the exact immutable workflow-pinned asset."
    }
}

function Test-PowerShellEncoding {
    $baseCommit = Get-GitValue -Root $RepositoryRoot -Arguments @("merge-base", "HEAD", "origin/master")
    $changed = @()
    if ($baseCommit) { $changed = @(& git -C $RepositoryRoot diff --name-only "$baseCommit...HEAD" -- "*.ps1") }
    foreach ($relativePath in @($changed)) {
        $path = Join-Path $RepositoryRoot ([string]$relativePath).Replace('/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $strictUtf8.GetString($bytes)
            if ($text.IndexOf([char]0xFFFD) -ge 0) { throw "replacement character U+FFFD is present" }
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            if (@($errors).Count -gt 0) { throw "PowerShell AST errors: $(@($errors | ForEach-Object { $_.Message }) -join '; ')" }
        } catch {
            Add-ReadinessIssue -Code "RELEASE_POWERSHELL_ENCODING_INVALID" -Category "SOURCE_DEFECT" `
                -Message "Changed PowerShell file is not strict UTF-8/AST-clean: $relativePath; $($_.Exception.Message)" `
                -Recovery "Store the script as valid UTF-8 and pass Cyrillic data through UTF-8 JSON/files or environment variables."
        }
    }
    return @($changed)
}

$commit = Get-GitValue -Root $RepositoryRoot -Arguments @("rev-parse", "HEAD")
$tree = Get-GitValue -Root $RepositoryRoot -Arguments @("rev-parse", "HEAD^{tree}")
$branch = Get-GitValue -Root $RepositoryRoot -Arguments @("branch", "--show-current")
$trackedStatus = @(& git -C $RepositoryRoot status --porcelain)
$worktreeClean = $trackedStatus.Count -eq 0
if (-not $commit -or -not $tree) {
    Add-ReadinessIssue -Code "RELEASE_SOURCE_NOT_GIT" -Category "CANDIDATE_INCOMPLETE" -Message "Workflow source is not a readable Git checkout: $RepositoryRoot" -Recovery "Create a clean worktree from the intended release commit."
}
if ($Mode -eq "Release" -and -not $worktreeClean) {
    Add-ReadinessIssue -Code "RELEASE_SOURCE_DIRTY" -Category "CANDIDATE_INCOMPLETE" -Message "Release candidate worktree has tracked changes." -Recovery "Commit the coherent candidate and rerun Release from the clean commit."
}

$templateLockPath = Join-Path $RepositoryRoot "templates\dependency-lock.json"
$templateLock = Get-JsonFile -Path $templateLockPath -Code "RELEASE_TEMPLATE_LOCK_INVALID" -Label "Workflow dependency lock template"
$vanessaLock = if ($null -eq $templateLock) { $null } else { $templateLock.dependencies.vanessaAutomation }
$compatibilityPath = Join-Path $RepositoryRoot ".agents\skills\1c-workflow\assets\ondemand-mcp\compatibility.json"
$compatibility = Get-JsonFile -Path $compatibilityPath -Code "RELEASE_COMPATIBILITY_INVALID" -Label "On-demand compatibility manifest"
if ($null -ne $vanessaLock -and $null -ne $compatibility) {
    $family = $compatibility.families.'vanessa-ui'
    $pairs = @(
        @("compatibilityVersion", [string]$family.backendVersions.vanessaAutomation),
        @("downstreamRevision", [string]$family.backendRevisions.vanessaAutomation),
        @("sha256", [string]$family.vanessaAutomationArtifact.archiveSha256),
        @("epfSha256", [string]$family.vanessaAutomationArtifact.epfSha256),
        @("manifestSha256", [string]$family.vanessaAutomationArtifact.manifestSha256),
        @("patchSha256", [string]$family.vanessaAutomationArtifact.patchSha256),
        @("upstreamCommit", [string]$family.vanessaAutomationArtifact.upstreamCommit)
    )
    foreach ($pair in $pairs) {
        $field = [string]$pair[0]
        $expected = [string]$vanessaLock.PSObject.Properties[$field].Value
        $actual = [string]$pair[1]
        if ($actual -cne $expected) {
            Add-ReadinessIssue -Code "RELEASE_COMPATIBILITY_LOCK_DRIFT" -Category "DEPENDENCY_DRIFT" `
                -Message "Compatibility manifest $field differs from templates/dependency-lock.json. expected='$expected'; actual='$actual'." `
                -Recovery "Regenerate compatibility metadata and lock expectations from one immutable artifact manifest."
        }
    }
}

$archive = Resolve-VanessaArchive -Lock $vanessaLock
Test-VanessaArchiveContract -ArchiveRecord $archive -Lock $vanessaLock
$changedPowerShell = @(Test-PowerShellEncoding)
$managedInventory = @(Get-ManagedPackageInventory -Root $RepositoryRoot)
$managedInventoryText = @($managedInventory | ForEach-Object { "$($_.path)`t$($_.sha256)" }) -join "`n"
$managedInventorySha = ""
if ($managedInventoryText) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $managedInventorySha = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($managedInventoryText)))).Replace("-", "").ToLowerInvariant() } finally { $sha.Dispose() }
}

$forkRecord = [ordered]@{ sourceRoot = ""; tag = ""; commit = ""; status = "not-local" }
if ($null -ne $templateLock) {
    $forkRecord.tag = [string]$templateLock.dependencies.aiRules1c.ref
    $forkRecord.commit = [string]$templateLock.dependencies.aiRules1c.commit
}
if ($AiRulesSource -and (Test-Path -LiteralPath $AiRulesSource -PathType Container)) {
    $forkRoot = [System.IO.Path]::GetFullPath($AiRulesSource)
    $forkHead = Get-GitValue -Root $forkRoot -Arguments @("rev-parse", "HEAD")
    $forkStatus = @(& git -C $forkRoot status --porcelain)
    $forkRecord.sourceRoot = $forkRoot
    $forkRecord.status = "validated"
    if ($forkHead -cne [string]$forkRecord.commit -or $forkStatus.Count -gt 0) {
        Add-ReadinessIssue -Code "RELEASE_FORK_IDENTITY_MISMATCH" -Category "DEPENDENCY_DRIFT" `
            -Message "Controlled fork checkout is not the clean locked commit. expected='$($forkRecord.commit)'; actual='$forkHead'." `
            -Recovery "Use a clean worktree checked out at the annotated pinned fork tag."
    }
    $tagType = Get-GitValue -Root $forkRoot -Arguments @("cat-file", "-t", "refs/tags/$($forkRecord.tag)")
    $tagCommit = Get-GitValue -Root $forkRoot -Arguments @("rev-parse", "refs/tags/$($forkRecord.tag)^{}")
    if ($tagType -cne "tag" -or $tagCommit -cne [string]$forkRecord.commit) {
        Add-ReadinessIssue -Code "RELEASE_FORK_TAG_INVALID" -Category "DEPENDENCY_DRIFT" `
            -Message "Pinned fork tag is missing, lightweight, or points at another commit: $($forkRecord.tag)." `
            -Recovery "Use the immutable annotated controlled-fork release tag."
    }
} elseif ($Mode -eq "Release") {
    Add-ReadinessIssue -Code "RELEASE_FORK_SOURCE_MISSING" -Category "CANDIDATE_INCOMPLETE" -Message "Release requires a local exact controlled-fork worktree." -Recovery "Pass -AiRulesSource pointing to the clean pinned tag worktree."
}

$standRecord = $null
if ($Mode -eq "Release") {
    if (-not $E2EProjectRoot) {
        Add-ReadinessIssue -Code "RELEASE_STAND_CONFIG_MISSING" -Category "STAND_STALE" -Message "Release has no E2E project root." -Recovery "Pass the dedicated E2E project root."
    } else {
        $E2EProjectRoot = [System.IO.Path]::GetFullPath($E2EProjectRoot)
        $standConfigPath = Join-Path $E2EProjectRoot ".agent-1c\release-e2e.json"
        $standConfig = Get-JsonFile -Path $standConfigPath -Code "RELEASE_STAND_CONFIG_INVALID" -Label "Release E2E configuration"
        if ($null -ne $standConfig) {
            $devBranchName = [string]$standConfig.devBranchName
            $standWorktree = [System.IO.Path]::GetFullPath([string]$standConfig.worktreePath)
            $standRecord = [ordered]@{ projectRoot = $E2EProjectRoot; devBranchName = $devBranchName; worktreePath = $standWorktree; commit = ""; managedPackageSha256 = ""; unsafeActionProtectionConfirmed = $false }
            if ($standWorktree -notmatch '\s' -or $standWorktree -notmatch '[^\x00-\x7F]') {
                Add-ReadinessIssue -Code "RELEASE_STAND_PATH_COVERAGE_MISSING" -Category "STAND_STALE" `
                    -Message "Configured E2E worktree path must contain both whitespace and non-ASCII text: '$standWorktree'." `
                    -Recovery "Move or recreate the disposable Release worktree under a path containing spaces and Cyrillic text so the exact runtime path contract is exercised."
            }
            Test-ManagedPackageAgreement -ExpectedInventory $managedInventory -TargetRoot $E2EProjectRoot -Label "E2E master"
            Test-ManagedPackageAgreement -ExpectedInventory $managedInventory -TargetRoot $standWorktree -Label "E2E branch"
            $standRecord.managedPackageSha256 = $managedInventorySha
            $standRecord.commit = Get-GitValue -Root $standWorktree -Arguments @("rev-parse", "HEAD")
            $standBranch = Get-GitValue -Root $standWorktree -Arguments @("branch", "--show-current")
            if ($standBranch -cne "itldev/$devBranchName") {
                Add-ReadinessIssue -Code "RELEASE_STAND_BRANCH_MISMATCH" -Category "STAND_STALE" -Message "Configured E2E worktree branch is '$standBranch'; expected='itldev/$devBranchName'." -Recovery "Point release-e2e.json at the exact disposable Release branch."
            }
            if (@(& git -C $standWorktree status --porcelain --untracked-files=no).Count -gt 0) {
                Add-ReadinessIssue -Code "RELEASE_STAND_DIRTY" -Category "STAND_STALE" -Message "Configured E2E worktree has tracked changes." -Recovery "Use a clean disposable Release branch."
            }
            foreach ($lockRoot in @($E2EProjectRoot, $standWorktree)) {
                $lockPath = Join-Path $lockRoot ".agent-1c\dependency-lock.json"
                $installedLock = Get-JsonFile -Path $lockPath -Code "RELEASE_STAND_LOCK_INVALID" -Label "Installed workflow dependency lock"
                if ($null -ne $installedLock) {
                    Test-LockAgreement -Expected $vanessaLock -Actual $installedLock.dependencies.vanessaAutomation -Label $lockRoot
                    $installedWorkflowCommit = [string]$installedLock.dependencies.workflowPackage.commit
                    if ($installedWorkflowCommit -cne $commit) {
                        $standContinuation = Get-WorkflowContinuationProof -RepositoryRoot $RepositoryRoot -QualifiedCommit $installedWorkflowCommit -CurrentCommit $commit -CurrentTree $tree
                        if (-not $standContinuation -or @($standContinuation.scopes) -contains "develop") {
                            Add-ReadinessIssue -Code "RELEASE_STAND_WORKFLOW_COMMIT_DRIFT" -Category "STAND_STALE" `
                                -Message "$lockRoot is installed from workflow commit '$installedWorkflowCommit'; candidate='$commit'." `
                                -Recovery "Run update-workflow from the exact candidate, commit the managed update, and create or refresh the disposable Release branch."
                        }
                    }
                }
            }
            $statePath = Join-Path $standWorktree (".agent-1c\dev-branches\" + $devBranchName + ".json")
            $state = Get-JsonFile -Path $statePath -Code "RELEASE_STAND_STATE_INVALID" -Label "Release branch state"
            if ($null -ne $state) {
                $confirmedProperty = $state.PSObject.Properties["unsafeActionProtectionConfirmed"]
                $confirmed = $null -ne $confirmedProperty -and $confirmedProperty.Value -is [bool] -and [bool]$confirmedProperty.Value
                $standRecord.unsafeActionProtectionConfirmed = $confirmed
                if (-not $confirmed) {
                    Add-ReadinessIssue -Code "RELEASE_STAND_UNSAFE_ACTION_PROTECTION_UNCONFIRMED" -Category "STAND_STALE" `
                        -Message "Release branch unsafe-action protection confirmation is absent." `
                        -Recovery "Run the monitored configure-dev-branch-unsafe-action-protection action in the configured E2E worktree."
                }
            }
        }
    }
}

$contextStatus = if ($issues.Count -eq 0) { "passed" } else { "failed" }
[object[]]$issueArray = @()
if ($issues.Count -gt 0) { $issueArray = $issues.ToArray() }
$context = [ordered]@{
    schemaVersion = 1
    kind = "itl-release-context"
    status = $contextStatus
    mode = $Mode
    startedAt = $startedAt.ToString("o")
    finishedAt = [DateTime]::UtcNow.ToString("o")
    repository = [ordered]@{ root = $RepositoryRoot; branch = $branch; commit = $commit; tree = $tree; worktreeClean = $worktreeClean }
    fork = $forkRecord
    artifacts = [ordered]@{ vanessaAutomation = $archive }
    managedPackage = [ordered]@{ sha256 = $managedInventorySha; fileCount = $managedInventory.Count }
    stand = $standRecord
    encoding = [ordered]@{
        powershellVersion = [string]$PSVersionTable.PSVersion
        powershellEdition = [string]$PSVersionTable.PSEdition
        consoleOutputEncoding = [Console]::OutputEncoding.WebName
        changedPowerShellFiles = $changedPowerShell
        contract = "strict-utf8-and-ast"
    }
    issues = $issueArray
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
[System.IO.File]::WriteAllText($OutputPath, (($context | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
if ($issues.Count -gt 0) {
    foreach ($issue in $issues) { [Console]::Error.WriteLine("$($issue.code) [$($issue.category)]: $($issue.message) Recovery: $($issue.recovery)") }
    exit 1
}
Write-Host "ITL release readiness passed. Context: $OutputPath"
