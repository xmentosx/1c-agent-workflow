. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$dev = Join-Path $Root 'ИБ разработчика'
$rep = Join-Path $Root 'отчёты'; New-Item -ItemType Directory -Force -Path $rep | Out-Null
$fresh = Join-Path $Root 'ветка-после-refresh.cf'
$r = @()
$r += Invoke-1C -Ib $dev -Arguments @('/CompareCfg', '-FirstConfigurationType', 'MainConfiguration', '-SecondConfigurationType', 'File', '-SecondFile', $fresh, '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'ИБ-v1 против ветки.txt')) -Label 'cmp-main-vs-file'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/CompareCfg', '-FirstConfigurationType', 'ConfigurationRepository', '-SecondConfigurationType', 'File', '-SecondFile', $fresh, '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'хранилище против ветки.txt'))) -Label 'cmp-repo-vs-file'
$r | ForEach-Object { Show-1C $_ }
Get-ChildItem -LiteralPath $rep | Select-Object Name, Length
