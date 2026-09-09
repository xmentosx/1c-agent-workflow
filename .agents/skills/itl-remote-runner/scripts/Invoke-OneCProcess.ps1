[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SpecPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$lib = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\1c-workflow\scripts\lib'))
foreach ($name in @('core', 'runtime-values', 'ports', 'sessions')) {
    . (Join-Path $lib ('agent-1c.' + $name + '.ps1'))
}
$context = Read-Utf8Text -Path $env:ITL_RUN_CONTEXT | ConvertFrom-Json
$spec = Read-Utf8Text -Path $SpecPath | ConvertFrom-Json
$script:ProjectRoot = [string]$context.target.workspace
Import-DotEnv -Path (Join-Path $script:ProjectRoot '.dev.env')
$targetBase = $context.target.infoBase
if ((Get-StateValue -State $spec -Name 'role' -Default 'client') -eq 'manager') {
    $targetBase = $context.target.vanessa.managerBase
}
if ($null -eq $targetBase -or $targetBase.kind -notin @('file','server') -or -not $targetBase.path) {
    throw 'ITL_TARGET_INFOBASE_REQUIRED'
}
if ([IO.Path]::GetFileName([string]$spec.executable) -notin @('1cv8.exe','1cv8c.exe')) { throw 'ITL_ONEC_EXECUTABLE_REQUIRED' }
if ([IO.Path]::GetFullPath([string]$spec.executable) -ne [IO.Path]::GetFullPath([string]$context.target.platform)) { throw 'ITL_ONEC_PLATFORM_OVERRIDE_FORBIDDEN' }
if ($spec.mode -notin @('ENTERPRISE','DESIGNER')) { throw 'ITL_ONEC_MODE_REQUIRED' }
if ($spec.mode -eq 'DESIGNER' -and 'update' -notin @($context.operations)) { throw 'ITL_ONEC_UPDATE_NOT_AUTHORIZED' }
$argsList = [Collections.Generic.List[string]]::new()
$argsList.Add([string]$spec.mode)
$argsList.Add($(if ($targetBase.kind -eq 'file') { '/F' } else { '/S' }))
$argsList.Add([string]$targetBase.path)
foreach ($argument in @($spec.arguments)) {
    if ([string]$argument -match '^/IBConnectionString') { throw 'ITL_ONEC_CONNECTION_OVERRIDE_FORBIDDEN' }
    if ([string]$argument -match '^/[FS]' -and [string]$argument -notmatch '^/SuppressStartup(Dialogs|Messages)$') { throw 'ITL_ONEC_CONNECTION_OVERRIDE_FORBIDDEN' }
    $argsList.Add([string]$argument)
}
if (Get-StateValue -State $spec -Name 'debug' -Default $false) {
    if (-not $context.rdbg.url) { throw 'ITL_RDBG_ENDPOINT_REQUIRED' }
    foreach($argument in @('/DEBUG','-http','/DEBUGGERURL',[string]$context.rdbg.url)) { $argsList.Add($argument) }
}
$sessionWait = Get-OneCSessionWaitParameters -ContextPath $env:ITL_RUN_CONTEXT
$process = Start-OneCProcessBackground -FilePath ([string]$spec.executable) -Arguments $argsList.ToArray() `
    -InfoBaseKind $targetBase.kind -InfoBasePath $targetBase.path -Purpose 'remote-work-owned-1c' @sessionWait
$record = [ordered]@{ jobId=$context.jobId; pid=$process.Id; startedAt=$process.StartTime.ToUniversalTime().ToString('o'); infoBase=$targetBase }
$recordPath = Join-Path (Split-Path -Parent $env:ITL_RUN_CONTEXT) ('onec-process-' + $process.Id + '.json')
Write-Utf8TextAtomic -Path $recordPath -Value ($record | ConvertTo-Json -Depth 8)
$record | ConvertTo-Json -Depth 8 -Compress
