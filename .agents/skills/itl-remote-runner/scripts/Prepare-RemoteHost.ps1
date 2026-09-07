[CmdletBinding()]
param([string]$Spool, [string]$Profile, [switch]$EnableSsh, [string]$RemoteAddress='LocalSubnet')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if ($EnableSsh) {
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'SSH_SETUP_REQUIRES_ADMINISTRATOR' }
    $cap=Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
    if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    if (-not (Get-NetFirewallRule -Name 'ITL-SSH-In' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'ITL-SSH-In' -DisplayName 'ITL SSH access' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -RemoteAddress $RemoteAddress | Out-Null
    }
}
$python=(Get-Command python -ErrorAction Stop).Source
$env:PYTHONUTF8='1'
if ($Profile) {
    if (-not $Spool) { throw 'SPOOL_REQUIRED' }
    & $python (Join-Path $PSScriptRoot 'remote_work.py') prepare --spool $Spool --profile $Profile
    if ($LASTEXITCODE) { throw 'WORKER_PREPARATION_FAILED' }
} else {
    [ordered]@{ computer=$env:COMPUTERNAME; python=$python; sshServer=(Get-Service sshd -ErrorAction SilentlyContinue | Select-Object Name,Status); worker='manual-start'; sshChanged=[bool]$EnableSsh } | ConvertTo-Json -Depth 5
}
