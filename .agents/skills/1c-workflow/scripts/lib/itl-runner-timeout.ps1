# Shared, stateless timeout policy for the compact and windowed launchers.
# Project-local .dev.env takes precedence over the process environment.
function Get-ItlRunnerTimeoutSetting {
    param([string]$ProjectRoot, [string]$Name)

    $envPath = Join-Path $ProjectRoot ".dev.env"
    if (Test-Path -LiteralPath $envPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $envPath -Encoding UTF8)) {
            if ($line -notmatch ("^\s*" + [regex]::Escape($Name) + "\s*=\s*(.*?)\s*$")) { continue }
            $value = [string]$Matches[1]
            if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return [pscustomobject]@{ value = $value; source = ".dev.env" }
        }
    }
    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
        return [pscustomobject]@{ value = [string]$value; source = "process-env" }
    }
    return $null
}

function Resolve-ItlRunnerTimeout {
    param(
        [string]$ProjectRoot,
        [string]$Action,
        [Nullable[int]]$ExplicitSeconds = $null
    )

    if ($null -ne $ExplicitSeconds) {
        if ($ExplicitSeconds -lt 1 -or $ExplicitSeconds -gt 86400) {
            throw "Explicit ITL operation timeout must be between 1 and 86400 seconds."
        }
        return [pscustomobject]@{ seconds = [int]$ExplicitSeconds; source = "explicit"; setting = "MaxWaitSeconds" }
    }

    $actionSetting = "ITL_RUNNER_{0}_TIMEOUT_SECONDS" -f $Action.ToUpperInvariant().Replace("-", "_")
    $selected = Get-ItlRunnerTimeoutSetting -ProjectRoot $ProjectRoot -Name $actionSetting
    $setting = $actionSetting
    if ($null -eq $selected) {
        $setting = "ITL_RUNNER_OPERATION_TIMEOUT_SECONDS"
        $selected = Get-ItlRunnerTimeoutSetting -ProjectRoot $ProjectRoot -Name $setting
    }
    if ($null -eq $selected) {
        $seconds = if ($Action -in @("init-project", "sync-master")) { 14400 } else { 3600 }
        return [pscustomobject]@{ seconds = $seconds; source = "action-default"; setting = $Action }
    }
    [int]$seconds = 0
    if (-not [int]::TryParse([string]$selected.value, [ref]$seconds) -or $seconds -lt 1 -or $seconds -gt 86400) {
        throw "$setting must be an integer between 1 and 86400 seconds; actual='$($selected.value)'."
    }
    return [pscustomobject]@{ seconds = $seconds; source = [string]$selected.source; setting = $setting }
}
