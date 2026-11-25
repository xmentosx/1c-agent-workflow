# Публикация homes и исходный PM5 update, 2026-10-29

По прямому поручению владельца данные опубликованы в существующем Git-реестре,
затем повторены существующие selection-сценарии на прежнем PM5/Windows11 стенде.

## Данные

Registry main: [`ac4fb7814ada211a4c0aa3d3dd0eeb6f00a8f9f3`](http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry/-/commit/ac4fb7814ada211a4c0aa3d3dd0eeb6f00a8f9f3),
parent `678e92e96065785ed285139125d396e8e3c0b72e`. FF push exit0 и fetch/read-back
подтвердили этот же SHA, 44 home, прежние schema/references и восемь контекстов.
21 область PM4 → pm4-corp, 21 PM5 → pm5-corp; зарплата → erppm4/erppm5.

Изменены только home/status, относящиеся к ним population metadata и пояснения
четырёх catalog-файлов. Применимость, ограничения, provenance, поколения,
products/projects, MCP/SPPR/Mantis и композиция сохранены. registry.json byte-exact
publisher parent, force push не применялся; native UUID/credentials не публиковались.
Первый ignored wrapper остановился до push на PSObject indexing; исправлена
только оснастка, затем подтверждён тот же единственный commit без blind write.

## Исходные native случаи

Source/installed payload: `f9aea99772e92da574dbdad0b655f20d849425d0`.
Штатный source-side updater запущен из тестового master `D:/Git/itl-workflow-e2e-pm5`;
roots manifest разрешал только прежний пилот
`D:/Git/itl-workflow-e2e-pm5-workflow-release-e2e-preflight`.
Master исходно unbound, пилот bound к pm5-core-development/pm5-corp. Поэтому
restore-compatible или ручная отвязка не понадобились. Release-корень не обновлялся.
Новая копия, topology, workload или сценарий не создавались: повторены критерии
ProductProjectSetup и BootstrapUpdate/RequiredCatalogTransition.

| Случай | Фактический итог |
|---|---|
| Unbound update без ID | exit1, CATALOG_PROJECT_REQUIRED, 2.867s, до copy; before/after HEAD/settings/MCP/env/package/DB/memory witnesses совпали |
| Та же команда с published pm5-core-development, keep-local | exit0, 215.787s; точный f9 установлен на двух разрешённых roots, binding выбран |
| Та же команда без ID на уже bound roots | exit0, 18.910s; повторного выбора нет, binding и оба HEAD неизменны, дерево чистое |

Installed UI owner bytes совпали с f9; полный файл memory guard прежний.
База пилота сохранила SHA `067ee2ac06b68459a75697e76cfca8785fa256c6444ebd8c56835120f854a534`.
Отсутствовавший source-snapshot path остался отсутствующим; его восстановление
или fresh initialization этим file/settings proof не объявляются.
Designer/Enterprise и проверки 1С не запускались.

Pilot memory enabled; cycle e4e9f2a727144ddab36e3204c1f51aa6,
workspace d6ea5e665b4947beb334fa53c3ccd3bf и workplace сохранены; provider/credentials
не менялись. Локальный registryContextHash равен полному applied contextHash.
В обоих applied contexts 21 применимая PM5 КОРП область имеет home. Pinned
revisions ed8ac958/8fc31b94 — потомки ac4; оба business blobs byte-exact
опубликованным данным. Publisher обновления сохранены.

## Граница

Это native CLI update/bound retention. Fresh init, интерактивный GUI choice/reload,
product remember/recall, новый backend IDs/currentness proof и corpus/reindex
не запускались. Прежние G3/G5/QP5 не подменяют эти непроверенные случаи.
Код, assertions, watchdog и guards не менялись; новой матрицы нет.
Workflow develop/master, Gate6, рабочая миграция и workflow push/PR не выполнялись.
Документальный source итог регистрируется отдельно: installed f9, registry ac4
и published workflow ac482 — разные версии и доказательства.
Полные квитанции/witnesses/logs retained в ignored
`build/agent-artifacts/registry-homes-native-selection-20261029/`.
