. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$bom = New-Object Text.UTF8Encoding $true
$rel = 'DataProcessors\ITLОбработкаПроверкиОбработчиковФормы\Forms\ФормаПроверкиОбработчиковСДлиннымИменем\Ext'
function Apply-Task([string]$Dir) {
    $formXml = Join-Path $Dir "$rel\Form.xml"; $module = Join-Path $Dir "$rel\Form\Module.bsl"
    $t = [IO.File]::ReadAllText($formXml)
    $t2 = [regex]::Replace($t, '\t\t<Attribute name="РеквизитДляУдаления" id="2">.*?</Attribute>\r\n', '', 'Singleline')
    if ($t2 -eq $t) { throw 'attribute not removed' }
    [IO.File]::WriteAllText($formXml, $t2, $bom)
    $m = [IO.File]::ReadAllText($module)
    $m2 = $m.Replace("`tСообщить(`"Исходная строка`");", "`tСообщить(`"Строка задачи`");`r`n`tСообщить(`"Вторая строка задачи`");")
    if ($m2 -eq $m) { throw 'module not changed' }
    [IO.File]::WriteAllText($module, $m2, $bom)
}
$stale = Join-Path $Root 'ветка устаревшая'
$fresh = Join-Path $Root 'ветка после refresh'
Copy-Item -LiteralPath (Join-Path $Root 'исходники базы') -Destination $stale -Recurse
Copy-Item -LiteralPath (Join-Path $Root 'исходники коллеги') -Destination $fresh -Recurse
Apply-Task $stale; Apply-Task $fresh
