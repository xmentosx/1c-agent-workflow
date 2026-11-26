. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$col = Join-Path $Root 'ИБ коллеги'
$form = 'DataProcessor.ITLОбработкаПроверкиОбработчиковФормы.Form.ФормаПроверкиОбработчиковСДлиннымИменем'
$list = Write-ObjectList (Join-Path $Root 'объекты-формы.xml') @($form)
$r = @()
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryLock', '-Objects', $list)) -Label 'col-lock'
$dump = Join-Path $Root 'исходники коллеги'
$r += Invoke-1C -Ib $col -Arguments @('/DumpConfigToFiles', $dump) -Label 'col-dump'
$formDir = Join-Path $dump 'DataProcessors\ITLОбработкаПроверкиОбработчиковФормы\Forms\ФормаПроверкиОбработчиковСДлиннымИменем\Ext'
$formXml = Join-Path $formDir 'Form.xml'; $module = Join-Path $formDir 'Form\Module.bsl'
$t = [IO.File]::ReadAllText($formXml)
$attr = "`t`t<Attribute name=`"РеквизитКоллеги`" id=`"3`">`r`n`t`t`t<Type>`r`n`t`t`t`t<v8:Type>xs:boolean</v8:Type>`r`n`t`t`t</Type>`r`n`t`t</Attribute>`r`n`t</Attributes>"
[IO.File]::WriteAllText($formXml, $t.Replace("`t</Attributes>", $attr), (New-Object Text.UTF8Encoding $true))
$m = [IO.File]::ReadAllText($module)
[IO.File]::WriteAllText($module, $m.Replace('Сообщить("Коллега: исходно");', 'Сообщить("Коллега: изменено в хранилище");'), (New-Object Text.UTF8Encoding $true))
$files = Join-Path $Root 'файлы-коллеги.txt'
[IO.File]::WriteAllLines($files, @($formXml, $module), (New-Object Text.UTF8Encoding $true))
$r += Invoke-1C -Ib $col -Arguments @('/LoadConfigFromFiles', $dump, '-listFile', $files, '-Format', 'Hierarchical', '/UpdateDBCfg') -Label 'col-partial-load'
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryCommit', '-Objects', $list, '-comment', 'Правка коллеги в той же форме')) -Label 'col-commit'
$r | ForEach-Object { Show-1C $_ }
