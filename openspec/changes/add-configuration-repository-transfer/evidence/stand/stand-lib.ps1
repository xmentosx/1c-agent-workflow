Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$script:RepoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
$script:Platform = if ($env:ITL_REPOSITORY_TRANSFER_PLATFORM) { $env:ITL_REPOSITORY_TRANSFER_PLATFORM } else { 'C:\Program Files\1cv8\8.3.27.2130\bin\1cv8.exe' }
$script:Root = if ($env:ITL_REPOSITORY_TRANSFER_STAND) { $env:ITL_REPOSITORY_TRANSFER_STAND } else { Join-Path $script:RepoRoot 'build\agent-artifacts\configuration-repository-transfer\стенд с хранилищем' }
$script:Logs = Join-Path $script:Root 'logs'
New-Item -ItemType Directory -Force -Path $script:Logs | Out-Null

function Quote([string]$v) { '"' + $v.Replace('"', '""') + '"' }

function Invoke-1C {
    param([string]$Mode = 'DESIGNER', [string]$Ib, [string[]]$Arguments, [string]$Label, [int]$TimeoutSec = 900)
    $log = Join-Path $script:Logs ("{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), $Label)
    $parts = @($Mode)
    if ($Mode -eq 'CREATEINFOBASE') { $parts += ('File="' + $Ib + '";'); $Ib = '' }
    if ($Ib) { $parts += '/F'; $parts += (Quote $Ib) }
    if ($Mode -ne 'CREATEINFOBASE') { $parts += '/DisableStartupMessages' }; $parts += '/DisableStartupDialogs'
    $parts += '/Out'; $parts += (Quote $log)
    foreach ($a in $Arguments) { if ($a.StartsWith('RAW:')) { $parts += $a.Substring(4) } elseif ($a -match '[\s"]' -or $a -eq '') { $parts += (Quote $a) } else { $parts += $a } }
    $line = $parts -join ' '
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $script:Platform -ArgumentList $line -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); throw "TIMEOUT $Label" }
    $sw.Stop()
    $text = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' }
    [pscustomobject]@{ label = $Label; exit = $p.ExitCode; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); log = $text.Trim(); logPath = $log }
}

function Show-1C($r) { "[{0}] exit={1} t={2}s`n{3}" -f $r.label, $r.exit, $r.seconds, $r.log }

function Repo-Args([string]$User) { @('/ConfigurationRepositoryF', (Join-Path $script:Root 'Хранилище конфигурации'), '/ConfigurationRepositoryN', $User, '/ConfigurationRepositoryP', '') }

function Write-ObjectList([string]$Path, [string[]]$Names, [bool]$Children = $false) {
    $ns = 'http://v8.1c.ru/8.3/config/objects'
    $x = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<Objects xmlns=`"$ns`" version=`"1.0`">`r`n"
    foreach ($n in $Names) { $x += "  <Object fullName=`"$n`" includeChildObjects=`"$($Children.ToString().ToLower())`"/>`r`n" }
    $x += "</Objects>`r`n"
    [IO.File]::WriteAllText($Path, $x, $utf8)
    $Path
}
