# SPPR host integration. Only the selected component's files, runtime and task are owned here.
function Get-SpprServerDefinition {
    return [pscustomobject][ordered]@{
        id = 'sppr'; title = 'SPPR project knowledge'; scope = 'global'
        image = 'itl/sppr-knowledge-mcp:local'; internalPort = 8000
        mcpNameTemplate = 'sppr-knowledge'; containerNameTemplate = 'itl-sppr-knowledge'
        env = @(
            @{ name = 'SPPR_CONFIG'; value = '/config/reader.json'; required = $true },
            @{ name = 'SPPR_EMBEDDING_KEY'; from = 'SPPR_EMBEDDING_KEY'; default = ''; required = $false }
        )
    }
}

function Get-SpprHostSettings {
    param([object]$Config)
    $raw = Get-ObjectValue -Object $Config -Name 'spprServer' -Default $null
    $configFile = [string](Get-ObjectValue -Object $raw -Name 'configPath' -Default '')
    if (-not $configFile -or -not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw 'Configure spprServer.configPath using sppr-mcp/config.example.json, then repeat the SPPR action.'
    }
    $settings = Read-JsonFile -Path $configFile
    $allowedFields = @('state','policy','odata_url','native_base','web_base','api_base','model','dimension','query_instruction','cache_size','page_size','timeout','max_response_bytes','max_objects','chunk_chars','night_start','night_end','time_zone','generations_to_keep','embedding_workers','embedding_batch_size','embedding_run_seconds','embedding_interval_minutes')
    if (@($settings.PSObject.Properties.Name | Where-Object { $_ -notin $allowedFields }).Count -gt 0) {
        throw 'SPPR component config contains unknown fields. Keep credentials in the separate credentialPath file, then retry.'
    }
    $statePath = [string](Get-ObjectValue -Object $settings -Name 'state' -Default '')
    $policyPath = [string](Get-ObjectValue -Object $settings -Name 'policy' -Default '')
    foreach ($path in @($statePath, $policyPath, $configFile)) {
        if (-not [IO.Path]::IsPathRooted($path)) { throw 'SPPR config, state and policy paths must be absolute.' }
    }
    $publicRoot = Join-Path (Split-Path -Parent $statePath) 'public'
    if ([IO.Path]::GetFullPath($policyPath) -ine [IO.Path]::GetFullPath((Join-Path $publicRoot 'policy.json'))) {
        throw "SPPR policy must be at '$publicRoot\policy.json' so both readers see atomic policy updates. Move the policy and update configPath, then retry."
    }
    $credentials = [string](Get-ObjectValue -Object $raw -Name 'credentialPath' -Default '')
    if ($credentials) {
        $resolvedSecret = [IO.Path]::GetFullPath($credentials)
        foreach ($readerRoot in @($publicRoot, $statePath)) {
            $prefix = [IO.Path]::GetFullPath($readerRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if ($resolvedSecret.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Keep the collector credential file outside the SPPR state/public reader mounts, then retry.'
            }
        }
    }
    $runtimeRoot = Join-Path (Split-Path -Parent $statePath) 'runtime'
    return [pscustomobject]@{
        configPath = [IO.Path]::GetFullPath($configFile); settings = $settings
        statePath = [IO.Path]::GetFullPath($statePath); publicRoot = $publicRoot
        credentialPath = $credentials; runtimeRoot = $runtimeRoot
        pythonPath = (Join-Path $runtimeRoot 'Scripts\python.exe')
        taskName = 'ITL SPPR Collector'; embeddingTaskName = 'ITL SPPR Embeddings'; taskPath = '\ITL\'
        description = 'ITL SPPR collector; InteractiveToken; owner-local nightly reconciliation'
        embeddingDescription = 'ITL SPPR embeddings; InteractiveToken; owner-local bounded worker'
    }
}

function Get-SpprVolumes {
    param([object]$Config)
    $sppr = Get-SpprHostSettings -Config $Config
    foreach ($path in @($sppr.statePath, $sppr.publicRoot)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw 'SPPR reader files are not prepared; run -Action sppr-prepare, then start -ServerId sppr.'
        }
    }
    return @(
        [pscustomobject]@{ host = $sppr.statePath; container = '/data/sppr'; readOnly = $true },
        [pscustomobject]@{ host = $sppr.publicRoot; container = '/config'; readOnly = $true }
    )
}

function Initialize-SpprRuntime {
    param([object]$Config)
    $sppr = Get-SpprHostSettings -Config $Config
    $source = Join-Path $PSScriptRoot 'sppr-mcp'
    if ($DryRun) { Write-Host 'Would prepare only the SPPR collector runtime and reader configuration.'; return }
    foreach ($path in @($sppr.publicRoot, $sppr.statePath)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    if (-not (Test-Path -LiteralPath (Join-Path $sppr.publicRoot 'policy.json') -PathType Leaf)) {
        throw 'Create public/policy.json from the reviewed project allowlist, then repeat sppr-prepare. No default corpus is enabled automatically.'
    }
    if (-not (Test-Path -LiteralPath $sppr.pythonPath -PathType Leaf)) {
        $python = Ensure-PythonRuntime -Config $Config
        $result = Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-m', 'venv', $sppr.runtimeRoot) -TimeoutSec 180
        if ($result.exitCode -ne 0) { throw 'SPPR venv creation failed; verify the configured Python has venv support, then retry sppr-prepare.' }
    }
    $result = Invoke-ProcessWithTimeout -FilePath $sppr.pythonPath -Arguments @('-m', 'pip', 'install', '-r', (Join-Path $source 'requirements-collector.txt')) -TimeoutSec 600
    if ($result.exitCode -ne 0) { throw 'SPPR collector dependencies could not be installed; restore package connectivity and retry sppr-prepare.' }
    $validateCode = 'import sys; sys.path.insert(0,sys.argv[1]); from sppr_core import Settings; Settings.load(sys.argv[2]); print("valid")'
    $validation = Invoke-ProcessWithTimeout -FilePath $sppr.pythonPath -Arguments @('-X','utf8','-B','-c',$validateCode,$source,$sppr.configPath) -TimeoutSec 30
    if ($validation.exitCode -ne 0) { throw 'SPPR component configuration is invalid. Check config.example.json and correct URLs, limits, paths or night window, then retry.' }
    $reader = Convert-ToHash -Object $sppr.settings
    $reader['state'] = '/data/sppr'
    $reader['policy'] = '/config/policy.json'
    $readerPath = Join-Path $sppr.publicRoot 'reader.json'
    Write-JsonFile -Path ($readerPath + '.tmp') -Value $reader
    Move-Item -LiteralPath ($readerPath + '.tmp') -Destination $readerPath -Force
    Write-Host 'SPPR runtime prepared. No source scan was started.'
}

function Assert-SpprTaskOwned {
    param([object]$Task, [object]$Settings)
    if ($Task -and [string](Get-ObjectValue -Object $Task -Name 'Description' -Default '') -ne $Settings.description) {
        throw 'A task with the SPPR collector name has another owner. Choose a separate host context; the task was not changed.'
    }
}

function Install-SpprCollector {
    param([object]$Config)
    $sppr = Get-SpprHostSettings -Config $Config
    if (-not $sppr.credentialPath -or -not (Test-Path -LiteralPath $sppr.credentialPath -PathType Leaf)) {
        throw 'Set spprServer.credentialPath to an external protected collector credential file, then retry sppr-collector-install.'
    }
    $existing = Get-ScheduledTask -TaskName $sppr.taskName -TaskPath $sppr.taskPath -ErrorAction SilentlyContinue
    Assert-SpprTaskOwned -Task $existing -Settings $sppr
    $existingEmbeddings = Get-ScheduledTask -TaskName $sppr.embeddingTaskName -TaskPath $sppr.taskPath -ErrorAction SilentlyContinue
    if ($existingEmbeddings -and [string](Get-ObjectValue -Object $existingEmbeddings -Name 'Description' -Default '') -ne $sppr.embeddingDescription) {
        throw 'A task with the SPPR embeddings name has another owner. No task was changed.'
    }
    if ($DryRun) { Write-Host 'Would install Limited InteractiveToken SPPR collection and embedding tasks.'; return }
    Initialize-SpprRuntime -Config $Config
    $collector = Join-Path $PSScriptRoot 'sppr-mcp\collector.py'
    $arguments = Join-HostProcessArguments -Arguments @('-X', 'utf8', '-B', $collector, 'collect', '--config', $sppr.configPath, '--credentials', $sppr.credentialPath)
    $scheduleCode = 'import json,sys; from datetime import datetime; from zoneinfo import ZoneInfo; s=json.load(open(sys.argv[1],encoding="utf-8-sig")); h,m=map(int,s.get("night_start","01:00").split(":")); print(datetime.now(ZoneInfo(s.get("time_zone","Europe/Moscow"))).replace(hour=h,minute=m,second=0,microsecond=0).astimezone().strftime("%H:%M"))'
    $schedule = Invoke-ProcessWithTimeout -FilePath $sppr.pythonPath -Arguments @('-X', 'utf8', '-c', $scheduleCode, $sppr.configPath) -TimeoutSec 30
    if ($schedule.exitCode -ne 0) { throw 'SPPR time zone/window could not be resolved. Correct the component config, then retry.' }
    $runAt = [datetime]::ParseExact(($schedule.lines -join '').Trim(), 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $action = New-ScheduledTaskAction -Execute $sppr.pythonPath -Argument $arguments -WorkingDirectory (Split-Path -Parent $collector)
    $trigger = New-ScheduledTaskTrigger -Daily -At $runAt
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 12) -Hidden
    $embedArguments = Join-HostProcessArguments -Arguments @('-X', 'utf8', '-B', $collector, 'embed-pending', '--config', $sppr.configPath, '--credentials', $sppr.credentialPath)
    $embedAction = New-ScheduledTaskAction -Execute $sppr.pythonPath -Argument $embedArguments -WorkingDirectory (Split-Path -Parent $collector)
    $embedIntervalMinutes = [int](Get-ObjectValue -Object $sppr.settings -Name 'embedding_interval_minutes' -Default 5)
    $embedTriggers = @(
        (New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $embedIntervalMinutes))
    )
    $embedRunSeconds = [int](Get-ObjectValue -Object $sppr.settings -Name 'embedding_run_seconds' -Default 240)
    $httpTimeoutSeconds = [int](Get-ObjectValue -Object $sppr.settings -Name 'timeout' -Default 30)
    $embedTaskLimit = [Math]::Max(900, $embedRunSeconds + 3 * $httpTimeoutSeconds + 300)
    $embedSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds $embedTaskLimit) -Hidden
    Register-ScheduledTask -TaskName $sppr.embeddingTaskName -TaskPath $sppr.taskPath -Action $embedAction -Trigger $embedTriggers -Settings $embedSettings -Principal $principal -Description $sppr.embeddingDescription -Force | Out-Null
    Register-ScheduledTask -TaskName $sppr.taskName -TaskPath $sppr.taskPath -Action $action -Trigger $trigger -Settings $taskSettings -Principal $principal -Description $sppr.description -Force | Out-Null
    Write-Host 'SPPR collection and embedding tasks installed; both require an open user session, and collection uses the night window.'
}

function Uninstall-SpprCollector {
    param([object]$Config)
    $sppr = Get-SpprHostSettings -Config $Config
    $existing = Get-ScheduledTask -TaskName $sppr.taskName -TaskPath $sppr.taskPath -ErrorAction SilentlyContinue
    Assert-SpprTaskOwned -Task $existing -Settings $sppr
    $existingEmbeddings = Get-ScheduledTask -TaskName $sppr.embeddingTaskName -TaskPath $sppr.taskPath -ErrorAction SilentlyContinue
    if ($existingEmbeddings -and [string](Get-ObjectValue -Object $existingEmbeddings -Name 'Description' -Default '') -ne $sppr.embeddingDescription) {
        throw 'A task with the SPPR embeddings name has another owner. No task was changed.'
    }
    if (-not $existing -and -not $existingEmbeddings) { return }
    if ($DryRun) { Write-Host 'Would remove only the managed SPPR collection and embedding tasks.'; return }
    if ($existing) { Unregister-ScheduledTask -TaskName $sppr.taskName -TaskPath $sppr.taskPath -Confirm:$false }
    if ($existingEmbeddings) { Unregister-ScheduledTask -TaskName $sppr.embeddingTaskName -TaskPath $sppr.taskPath -Confirm:$false }
}
