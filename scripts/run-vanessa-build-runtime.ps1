[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$buildRequest = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$buildWorkRoot = [IO.Path]::GetFullPath([string]$buildRequest.workRoot)
$buildSourceRoot = Join-Path $buildWorkRoot 'src'
$buildRuntimeRoot = Join-Path $buildWorkRoot 'runtime'
[void][IO.Directory]::CreateDirectory($buildRuntimeRoot)
$buildRuntimeResultPath = Join-Path $buildWorkRoot 'native-runtime-result.json'
$buildRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildHelperPath = Join-Path $buildRepositoryRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
. $buildHelperPath -ProjectRoot $buildSourceRoot -Action help *> $null
. (Join-Path $buildRepositoryRoot 'scripts/vanessa-build-runtime.ps1')
. (Join-Path $buildRepositoryRoot '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')

$buildBases = @(Get-VanessaBuildDatabasePlan -WorkRoot $buildWorkRoot)
$buildManifest = Get-Content -LiteralPath $buildRequest.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$buildSavedProof = [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process')
$buildSavedScratch = [Environment]::GetEnvironmentVariable('ITL_VANESSA_BUILD_SCRATCH_BASE', 'Process')
$buildSavedUser = [Environment]::GetEnvironmentVariable('ITL_VANESSA_BUILD_USER', 'Process')
$buildSavedPlatform = [Environment]::GetEnvironmentVariable('PLATFORM_PATH', 'Process')
$buildPreviousJournal = $script:OneCNativeOperationJournal
$buildOwner = $null
$buildJournal = $null
$buildFailure = $null
$buildRuntimeResult = [ordered]@{ schemaVersion = 1; succeeded = $false; released = $false; bases = $buildBases; adapters = @(); stages = @(); nativeOperations = @(); templateSha256 = '' }
Write-Utf8Text -Path $buildRuntimeResultPath -Value ($buildRuntimeResult | ConvertTo-Json -Depth 10)
try {
    $buildTemplate = Get-VanessaServiceInfoBaseTemplate
    if ($buildTemplate.user -cnotmatch '^[A-Za-z0-9_]+$') { throw 'VANESSA_BUILD_SERVICE_USER_INVALID' }
    $buildRuntimeResult.templateSha256 = $buildTemplate.sha256
    foreach ($flow in @(
        @{ path = 'tools/onescript/Compile.os'; single = $false },
        @{ path = 'tools/onescript/MakeVASingle.os'; single = $true }
    )) {
        $pin = @($buildManifest.build.upstreamFlow | Where-Object path -eq $flow.path)
        if ($pin.Count -ne 1) { throw "VANESSA_BUILD_FLOW_PIN_MISSING: $($flow.path)" }
        $buildRuntimeResult.adapters += New-VanessaBuildExecutionCopy `
            -SourcePath (Join-Path $buildSourceRoot $flow.path) `
            -DestinationPath (Join-Path $buildRuntimeRoot ([IO.Path]::GetFileName($flow.path))) `
            -ExpectedSha256 $pin[0].sha256 -SingleBuild:$flow.single
    }
    $buildSettings = Get-ItlDatabaseAccessSettings
    $buildAccessRequest = [ordered]@{
        schemaVersion = 1; coordinator = $buildSettings.coordinator; bases = $buildBases; timeout = $buildSettings.waitTimeoutSeconds
        owner = @{ project = $buildWorkRoot; operation = 'build-vanessa-automation'; requestId = [guid]::NewGuid().ToString('N') }
    }
    if ($buildSavedProof) { $buildAccessRequest.inherited = $buildSavedProof | ConvertFrom-Json -ErrorAction Stop }
    $buildJournal = New-OneCNativeOperationJournal -Resources $buildBases
    $buildOwner = Start-ItlDatabaseAccessHost -Python $buildSettings.python -Request $buildAccessRequest
    $buildJournal.owner = $buildOwner
    $script:OneCNativeOperationJournal = $buildJournal
    [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', ($buildOwner.proof | ConvertTo-Json -Depth 40 -Compress), 'Process')
    [Environment]::SetEnvironmentVariable('ITL_VANESSA_BUILD_USER', $buildTemplate.user, 'Process')
    [Environment]::SetEnvironmentVariable('PLATFORM_PATH', [string]$buildRequest.platformExe, 'Process')

    [Environment]::SetEnvironmentVariable('ITL_VANESSA_BUILD_SCRATCH_BASE', $buildBases[0].path, 'Process')
    $buildRuntimeResult.stages += Invoke-VanessaBuildOwnedNative -FilePath $buildRequest.oscriptExe `
        -Arguments @($buildRuntimeResult.adapters[0].executionPath, ($buildSourceRoot + '\')) `
        -Bases @($buildBases[0]) -Purpose 'vanessa-build-compile'

    $createBaseArguments = @('CREATEINFOBASE', (New-FileInfoBaseConnectionString -Path $buildBases[2].path),
        '/DisableStartupDialogs', '/Out', (Join-Path $buildWorkRoot 'create-base.log'))
    $buildRuntimeResult.stages += Invoke-VanessaBuildOwnedNative -FilePath $buildRequest.platformExe `
        -Arguments $createBaseArguments -Bases @($buildBases[2]) -Purpose 'vanessa-build-qualification-create' -CreateInfoBase -TimeoutSeconds 300
    Invoke-Designer -InfoBaseKind file -InfoBasePath $buildBases[2].path -User '' -Password '' `
        -DesignerArgs @('/RestoreIB', $buildTemplate.path) | Out-Null

    [Environment]::SetEnvironmentVariable('ITL_VANESSA_BUILD_SCRATCH_BASE', $buildBases[1].path, 'Process')
    $buildRuntimeResult.stages += Invoke-VanessaBuildOwnedNative -FilePath $buildRequest.oscriptExe `
        -Arguments @($buildRuntimeResult.adapters[1].executionPath, $buildSourceRoot,
            (Join-Path $buildWorkRoot 'out'), (Join-Path $buildSourceRoot 'features/Libraries'),
            [IO.Path]::GetDirectoryName([string]$buildRequest.platformExe), $buildBases[2].path) `
        -Bases @($buildBases[1], $buildBases[2]) -Purpose 'vanessa-build-single'
    $buildRuntimeResult.succeeded = $true
} catch {
    $buildFailure = $_
} finally {
    try {
        if ($null -eq $buildOwner) { $buildRuntimeResult.released = $true }
        elseif (Test-OneCNativeOperationJournalReleased -Journal $buildJournal) {
            $buildRelease = Complete-ItlDatabaseAccessHost -Owner $buildOwner
            $buildRuntimeResult.released = $buildRelease.status -eq 'released'
        } else { Close-ItlDatabaseAccessHost -Owner $buildOwner }
    } catch {
        $buildRuntimeResult.released = $false
        if ($null -eq $buildFailure) { $buildFailure = $_ }
    }
    if ($null -ne $buildJournal) {
        $buildRuntimeResult.nativeOperations = @($buildJournal.entries | Select-Object id, purpose, admissions, startAttempted, processId, launcherExited, quiescenceConfirmed, releaseEvidence)
    }
    $script:OneCNativeOperationJournal = $buildPreviousJournal
    [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $buildSavedProof, 'Process')
    [Environment]::SetEnvironmentVariable('ITL_VANESSA_BUILD_SCRATCH_BASE', $buildSavedScratch, 'Process')
    [Environment]::SetEnvironmentVariable('ITL_VANESSA_BUILD_USER', $buildSavedUser, 'Process')
    [Environment]::SetEnvironmentVariable('PLATFORM_PATH', $buildSavedPlatform, 'Process')
    Write-Utf8Text -Path $buildRuntimeResultPath -Value ($buildRuntimeResult | ConvertTo-Json -Depth 10)
}
if ($null -ne $buildFailure) { throw $buildFailure }
if (-not $buildRuntimeResult.released) { throw "VANESSA_BUILD_NATIVE_CLEANUP_UNCONFIRMED: preserve $buildWorkRoot" }
