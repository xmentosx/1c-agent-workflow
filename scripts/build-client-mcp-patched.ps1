[CmdletBinding()]
param(
    [string]$OutputDirectory = '',
    [string]$UpstreamArtifactPath = '',
    [string]$PlatformBin = 'C:\Program Files\1cv8\8.3.27.2130\bin'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$assetRoot = Join-Path $repositoryRoot 'third-party/client-mcp/v0.6.5-itl-r1'
$manifestPath = Join-Path $assetRoot 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repositoryRoot 'build/third-party/client-mcp/v0.6.5-itl-r1/candidate' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw 'CLIENT_MCP_BUILD_OUTPUT_ALREADY_EXISTS: choose a new candidate directory; immutable outputs are not overwritten.' }
$platformExe = Join-Path $PlatformBin '1cv8.exe'
if ((Get-Item -LiteralPath $platformExe).VersionInfo.FileVersion -cne [string]$manifest.build.platformVersion) { throw 'CLIENT_MCP_BUILD_PLATFORM_MISMATCH' }
if ((Get-FileHash -LiteralPath $platformExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.build.platformSha256) { throw 'CLIENT_MCP_BUILD_PLATFORM_SHA_MISMATCH' }
foreach ($notice in @('LICENSE.upstream', 'LICENSE.GPL3', 'ITL-NOTICE.txt')) {
    if ((Get-FileHash -LiteralPath (Join-Path $assetRoot $notice) -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.notices.$notice) { throw "CLIENT_MCP_BUILD_NOTICE_MISMATCH: $notice" }
}
$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'CLIENT_MCP_BUILD_SOURCE_IDENTITY_INVALID' }
. (Join-Path $repositoryRoot 'scripts/git-path-list.ps1')
if (@(Get-RepositoryGitPathList -RepositoryRoot $repositoryRoot -Arguments @('status', '--porcelain=v1', '-z')).Count -gt 0) { throw 'CLIENT_MCP_BUILD_SOURCE_DIRTY: commit the controlled build inputs before native qualification.' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$workRoot = Join-Path $OutputDirectory 'work'
[void][IO.Directory]::CreateDirectory($workRoot)
. (Join-Path $repositoryRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ProjectRoot $workRoot -Action help *> $null
. (Join-Path $repositoryRoot 'scripts/vanessa-build-runtime.ps1')
. (Join-Path $repositoryRoot 'scripts/client-mcp-build.ps1')
$savedPlatform = [Environment]::GetEnvironmentVariable('PLATFORM_PATH', 'Process')
$previousJournal = $script:OneCNativeOperationJournal
$script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
$basePath = Join-Path $workRoot 'service-base'
$xmlRoot = Join-Path $workRoot 'source'
$baselinePath = Join-Path $workRoot 'upstream-client_mcp.cfe'
$cfePath = Join-Path $OutputDirectory $manifest.artifact.fileName
$archivePath = Join-Path $OutputDirectory $manifest.correspondingSource.fileName
$provenancePath = Join-Path $OutputDirectory 'candidate.provenance.json'
$snapshot = $null
$failure = $null
$receipt = [ordered]@{
    schemaVersion = 1; component = 'clientMcp'; status = 'pending'; sourceCommit = $sourceCommit
    manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    buildInputs = [ordered]@{}; upstream = $manifest.upstream; compatibilityVersion = $manifest.compatibilityVersion
    downstreamRevision = $manifest.downstreamRevision; platformVersion = $manifest.build.platformVersion; platformSha256 = $manifest.build.platformSha256
    artifactPath = $cfePath; artifactSha256 = ''; sourceArchivePath = $archivePath; sourceArchiveSha256 = ''
    sourceIdentity = $null; changedPaths = @(); gate6 = $null; restored = $false; released = $false; error = ''
}
foreach ($relative in @(Get-ClientMcpBuildInputPaths -RepositoryRoot $repositoryRoot)) {
    $receipt.buildInputs[$relative] = (Get-FileHash -LiteralPath (Join-Path $repositoryRoot $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
}
try {
    [Environment]::SetEnvironmentVariable('PLATFORM_PATH', $PlatformBin, 'Process')
    $template = Get-VanessaServiceInfoBaseTemplate
    if ($template.sha256 -cne [string]$manifest.build.serviceTemplateSha256) { throw 'CLIENT_MCP_BUILD_SERVICE_TEMPLATE_MISMATCH' }
    $baselineSource = if ($UpstreamArtifactPath) { [IO.Path]::GetFullPath($UpstreamArtifactPath) } else { [string]$manifest.upstream.url }
    [void](Invoke-ItlImmutableFileAcquire -Source $baselineSource -DestinationPath $baselinePath -ExpectedSha256 $manifest.upstream.sha256 -Label 'client_mcp upstream baseline')
    [void](Invoke-VanessaBuildOwnedNative -FilePath $platformExe -Arguments @('CREATEINFOBASE', (New-FileInfoBaseConnectionString -Path $basePath), '/DisableStartupDialogs', '/Out', (Join-Path $workRoot 'create-base.log')) -Bases @([pscustomobject]@{kind='file';path=$basePath}) -Purpose 'client-mcp-build-create' -CreateInfoBase -TimeoutSeconds 300)
    Invoke-Designer -InfoBaseKind file -InfoBasePath $basePath -User '' -Password '' -DesignerArgs @('/RestoreIB', $template.path) | Out-Null
    $snapshot = New-DesignerGate6Snapshot -InfoBaseKind file -InfoBasePath $basePath -User $template.user -Password ''
    Invoke-Designer -InfoBaseKind file -InfoBasePath $basePath -User $template.user -Password '' -DesignerArgs @('/LoadCfg', $baselinePath, '-Extension', 'client_mcp') | Out-Null
    [void][IO.Directory]::CreateDirectory($xmlRoot)
    Invoke-Designer -InfoBaseKind file -InfoBasePath $basePath -User $template.user -Password '' -DesignerArgs @('/DumpConfigToFiles', $xmlRoot, '-Extension', 'client_mcp', '-Format', 'Hierarchical') | Out-Null
    $before = Get-ClientMcpBuildSourceIdentity -SourceRoot $xmlRoot
    $repair = Add-ClientMcpBorrowedLanguage -SourceRoot $xmlRoot -LanguagePath (Join-Path $assetRoot 'Language.xml') -Specification $manifest.patch
    $after = Get-ClientMcpBuildSourceIdentity -SourceRoot $xmlRoot
    foreach ($file in $before.files) {
        if ($file.path -ceq 'Configuration.xml') { continue }
        $same = @($after.files | Where-Object path -CEQ $file.path)
        if ($same.Count -ne 1 -or $same[0].sha256 -cne $file.sha256) { throw "CLIENT_MCP_BUILD_UNRELATED_SOURCE_CHANGED: $($file.path)" }
    }
    if ($after.files.Count -ne $before.files.Count + 1) { throw 'CLIENT_MCP_BUILD_SOURCE_INVENTORY_CHANGED' }
    $receipt.changedPaths = $repair.changedPaths
    if (($receipt.changedPaths -join [char]0) -cne (@($manifest.patch.expectedChangedPaths) -join [char]0)) { throw 'CLIENT_MCP_BUILD_PATCH_INVENTORY_MISMATCH' }
    $receipt.sourceIdentity = $after
    Invoke-Designer -InfoBaseKind file -InfoBasePath $basePath -User $template.user -Password '' -DesignerArgs @('/LoadConfigFromFiles', $xmlRoot, '-Extension', 'client_mcp', '-Format', 'Hierarchical') | Out-Null
    $receipt.gate6 = Invoke-DesignerGate6CheckLadder -InfoBaseKind file -InfoBasePath $basePath -User $template.user -Password '' -ExtensionName client_mcp -SourceFingerprint $after.fingerprint
    Invoke-Designer -InfoBaseKind file -InfoBasePath $basePath -User $template.user -Password '' -DesignerArgs @('/DumpCfg', $cfePath, '-Extension', 'client_mcp') | Out-Null
    $receipt.artifactSha256 = (Get-FileHash -LiteralPath $cfePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $stage = Join-Path $workRoot 'corresponding-source'
    [void][IO.Directory]::CreateDirectory($stage)
    Copy-Item -LiteralPath $xmlRoot -Destination (Join-Path $stage 'src') -Recurse
    foreach ($name in @('manifest.json', 'Language.xml', 'LICENSE.upstream', 'LICENSE.GPL3', 'ITL-NOTICE.txt', 'REBUILD.md')) { Copy-Item -LiteralPath (Join-Path $assetRoot $name) -Destination (Join-Path $stage $name) }
    Write-Utf8Text -Path (Join-Path $stage 'SOURCE-IDENTITY.json') -Value ($after | ConvertTo-Json -Depth 5)
    New-ClientMcpSourceArchive -SourceDirectory $stage -DestinationPath $archivePath
    $receipt.sourceArchiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $receipt.status = 'built'
} catch { $failure = $_; $receipt.status = 'failed'; $receipt.error = $_.Exception.Message } finally {
    try {
        if ($null -ne $snapshot) {
            if ((Get-FileHash -LiteralPath $snapshot.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $snapshot.sha256) { throw 'CLIENT_MCP_BUILD_ROLLBACK_SHA_MISMATCH' }
            Invoke-Designer -InfoBaseKind file -InfoBasePath $basePath -User $template.user -Password '' -RestorationDuty $snapshot.duty -DesignerArgs @('/RestoreIB', $snapshot.path) | Out-Null
            Complete-OneCDatabaseRestorationDuty -Duty $snapshot.duty -Resolution restored
            $receipt.restored = $true
        }
        $receipt.released = Test-OneCNativeOperationJournalReleased -Journal $script:OneCNativeOperationJournal
        if (-not $receipt.released) { throw 'CLIENT_MCP_BUILD_RELEASE_UNVERIFIED' }
    } catch { if ($null -eq $failure) { $failure = $_ }; $receipt.status = 'failed'; $receipt.error = $_.Exception.Message }
    $script:OneCNativeOperationJournal = $previousJournal
    [Environment]::SetEnvironmentVariable('PLATFORM_PATH', $savedPlatform, 'Process')
    Write-Utf8Text -Path $provenancePath -Value (($receipt | ConvertTo-Json -Depth 9) + [Environment]::NewLine)
}
if ($null -ne $failure) { throw $failure }
[pscustomobject]@{ status=$receipt.status; artifactPath=$cfePath; artifactSha256=$receipt.artifactSha256; sourceArchivePath=$archivePath; sourceArchiveSha256=$receipt.sourceArchiveSha256; provenancePath=$provenancePath; restored=$receipt.restored; released=$receipt.released } | ConvertTo-Json
