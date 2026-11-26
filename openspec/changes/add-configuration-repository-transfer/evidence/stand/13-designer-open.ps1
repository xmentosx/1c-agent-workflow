. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$dev = Join-Path $Root 'ИБ разработчика'
$rep = Join-Path $Root 'отчёты'
$cf = Join-Path $Root 'ветка-2.cf'
$p = Start-Process -FilePath $Platform -ArgumentList ('DESIGNER /F ' + (Quote $dev) + ' /DisableStartupMessages /DisableStartupDialogs') -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 8
try {
  $r = Invoke-1C -Ib $dev -Arguments @('/CompareCfg', '-FirstConfigurationType', 'MainConfiguration', '-SecondConfigurationType', 'File', '-SecondFile', $cf, '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'при открытом конфигураторе.txt')) -Label 'batch-while-designer-open' -TimeoutSec 120
  Show-1C $r
  $r2 = Invoke-1C -Ib $dev -Arguments @('/UpdateDBCfg') -Label 'updatedb-while-designer-open' -TimeoutSec 120
  Show-1C $r2
} finally { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }; "interactive designer stopped" }
