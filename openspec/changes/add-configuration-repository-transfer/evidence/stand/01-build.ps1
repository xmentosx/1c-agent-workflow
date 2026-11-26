. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$fixture = Join-Path $RepoRoot 'tests\fixtures\gate-stand\cf'
if (Test-Path -LiteralPath (Join-Path $Root 'ИБ разработчика')) { throw 'stand exists' }
$base = Join-Path $Root 'исходники базы'
Copy-Item -LiteralPath $fixture -Destination $base -Recurse
$formDir = Join-Path $base 'DataProcessors\ITLОбработкаПроверкиОбработчиковФормы\Forms\ФормаПроверкиОбработчиковСДлиннымИменем\Ext'
$formXml = Join-Path $formDir 'Form.xml'
$t = [IO.File]::ReadAllText($formXml)
$attr = "`t`t<Attribute name=`"РеквизитДляУдаления`" id=`"2`">`r`n`t`t`t<Type>`r`n`t`t`t`t<v8:Type>xs:string</v8:Type>`r`n`t`t`t`t<v8:StringQualifiers>`r`n`t`t`t`t`t<v8:Length>10</v8:Length>`r`n`t`t`t`t`t<v8:AllowedLength>Variable</v8:AllowedLength>`r`n`t`t`t`t</v8:StringQualifiers>`r`n`t`t`t</Type>`r`n`t`t</Attribute>`r`n`t</Attributes>"
$t = $t.Replace("`t</Attributes>", $attr)
[IO.File]::WriteAllText($formXml, $t, (New-Object Text.UTF8Encoding $true))
$module = Join-Path $formDir 'Form\Module.bsl'
$m = [IO.File]::ReadAllText($module)
$m = $m.TrimEnd() + "`r`n`r`n&НаСервере`r`nПроцедура ОбработчикЗадачи()`r`n`r`n`tСообщить(`"Исходная строка`");`r`n`r`nКонецПроцедуры`r`n`r`n&НаСервере`r`nПроцедура ПроцедураКоллеги()`r`n`r`n`tСообщить(`"Коллега: исходно`");`r`n`r`nКонецПроцедуры`r`n"
[IO.File]::WriteAllText($module, $m, (New-Object Text.UTF8Encoding $true))

$dev = Join-Path $Root 'ИБ разработчика'
$col = Join-Path $Root 'ИБ коллеги'
$r = @()
$r += Invoke-1C -Mode 'CREATEINFOBASE' -Ib $dev -Arguments @() -Label 'create-dev'
$r += Invoke-1C -Ib $dev -Arguments @('/LoadConfigFromFiles', $base, '/UpdateDBCfg') -Label 'load-base'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryCreate', '-AllowConfigurationChanges', '-ChangesAllowedRule', 'ObjectIsEditableSupportEnabled', '-ChangesNotRecommendedRule', 'ObjectIsEditableSupportEnabled')) -Label 'repo-create'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryAddUser', '-User', 'Коллега', '-Pwd', '', '-Rights', 'LockObjects')) -Label 'repo-add-user'
$r += Invoke-1C -Mode 'CREATEINFOBASE' -Ib $col -Arguments @() -Label 'create-col'
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryBindCfg', '-forceBindAlreadyBindedUser', '-forceReplaceCfg', '/UpdateDBCfg')) -Label 'col-bind'
$r | ForEach-Object { Show-1C $_ }
