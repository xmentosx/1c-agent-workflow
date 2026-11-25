. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$r = @()
foreach ($n in @('stale', 'fresh')) { $r += Invoke-1C -Mode 'CREATEINFOBASE' -Ib (Join-Path $Root "ИБ сборки $n") -Arguments @() -Label "create-build-$n" }
foreach ($pair in @(@('ветка устаревшая', 'ветка-устаревшая.cf', 'stale'), @('ветка после refresh', 'ветка-после-refresh.cf', 'fresh'))) {
    $ib = Join-Path $Root ("ИБ сборки " + $pair[2])
    $r += Invoke-1C -Ib $ib -Arguments @('/LoadConfigFromFiles', (Join-Path $Root $pair[0]), '/UpdateDBCfg') -Label "load-$($pair[2])"
    $r += Invoke-1C -Ib $ib -Arguments @('/DumpCfg', (Join-Path $Root $pair[1])) -Label "dumpcfg-$($pair[2])"
}
$r | ForEach-Object { Show-1C $_ }
Get-ChildItem -LiteralPath $Root -Filter *.cf | ForEach-Object { '{0} {1} {2}' -f $_.Name, $_.Length, (Get-FileHash -LiteralPath $_.FullName).Hash.Substring(0,12) }
