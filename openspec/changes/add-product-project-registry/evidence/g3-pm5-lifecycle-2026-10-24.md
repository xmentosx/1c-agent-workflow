# G3: lifecycle PM5 и managed downgrade, 2026-10-24

**Первое unattended-обновление legacy-копии, поздняя ассоциация, отказ несовместимому пакету и compatibility restore проверены. Фактический downgrade выявил `G3-MANAGED-DOWNGRADE-DEPENDENCY-MODE`; полная G3/AC-39 не принята.** Код workflow не исправлялся. Gate 6, G4, рабочая миграция и публикация не выполнялись; OpenCode SKIPPED. Принятое отклонение warm Startup не блокирует работу, новых замеров нет.

## Изолированный стенд

Чтобы не менять прежний current PM5, existing fixture factory восстановила новую копию из ранее согласованной sealed capsule `c2c570fe1ec57619f1a516b9752c48159da7b703eb8c8bb275977abde19cd8b6`:

- Main: `C:\itlj\g3-lifecycle-20261024\q Проект\develop-c2c570fe1ec5-34c623e6e9cc-c1ed2864\project`.
- Sibling: та же директория, `branch`.
- Начальный workflow: `fa0e3c91694112c1da3ecda7209a8a81ea828264`; выбранный новый пакет/source: `34c623e6e9cc6f33737f3c3cd4642f1a26e3f35b`.
- Seed membership **Kilo**, optional `.cursor/mcp.json` отсутствует. Прежний current PM5 с Kilo+Cursor не превращён в этот canary и не обновлялся.

Это approved capsule snapshot route, **не fresh init и не доказательство currentness отсутствующего original live seed**. Подготовка использовала guard-owned CREATEINFOBASE/RestoreIB; `/CheckConfig`/Gate 6 не запускались. Каталог — новый отдельный local bare origin/cache; fixture pushes только туда, не публикация общего каталога. Точный clean старый source подготовлен отдельно в `C:\itlj\g3-lifecycle-20261024\old-source`; исходники старого helper не патчились. Native команды выполнялись existing source-fixture launcher/capture owners под Windows PowerShell 5.1, с fixture lease и штатными watchdog/budget.

## Наблюдаемые результаты

| Сценарий | Факт | Приёмка |
|---|---|---|
| Первый old-caller unattended update | **322555мс**, exit0; main+sibling получили `34c623e6`, оба clean. Ни `productProject`, ни согласие `associationOffer=later` не записаны | PASS для PM5 unattended AC-33; не foreground choose/new/later matrix |
| Поздняя ассоциация | Публичные list → preview → select выбрали `pm5-core-development`/`pm5-corp`; memory opt-in false | PASS для этого installed PM5 пути; active IDE tools/reload отдельно |
| Старый пакет при активном binding | Публичный update завершился ожидаемым exit1 / `CATALOG_PACKAGE_INCOMPATIBLE` до копирования | PASS защитного сценария: descriptor/lock/MCP и три relevant helper files на main+sibling SHA+mtime неизменны |
| `restore-compatible` | Привязка снята, descriptor byte-exact исходному before-select; прежние Kilo values восстановлены, Cursor остался отсутствующим | PASS в этой границе; весь Kilo файл **не byte-equal** из-за форматирования, точное совпадение его bytes не заявлено |
| Реальный update на старый пакет после compatibility restore | **70843мс**, exit1; файлы скопированы, старый post-copy child остановился с `Invalid dependency mode: workflow. Use fresh or locked.` | **FAIL**, новый blocker ниже; успешный compatibility restore не означает успешный downgrade |
| Fork из sibling | `ITL_INFOBASE_APPLICATION_NOT_READY`: `configLoadStatus=pending`, fingerprint/load proof отсутствует; worktree не создан, tracked changes не появились | BLOCKED положительный fork; отрицательный admission работает. Предложенный helper `update-dev-branch-base` затрагивает исключённый Gate 6, не запускался |
| Source-side recovery status | Current source launcher с explicit `-SourceRoot` и 32-hex SnapshotId вернул exit0, report `changedPathCount=0`; transaction SHA до/после одинаков | PASS диагностики; **не resume, repair, rollback или завершение downgrade** |

Полный refresh/lite-refresh после merge вызывает `Load-ConfigFromFiles -ContentKind configuration`, то есть обязательный Gate 6. Новый branch runtime также требует полноценной загрузки/готовности конфигурации; положительный new/fork/refresh этим прогоном не принят. Для fresh init здесь отдельного прогона нет: подготовка capsule не подменяет init, и утверждение, что всякий init обязательно заблокирован именно Gate 6, не делается.

## G3-MANAGED-DOWNGRADE-DEPENDENCY-MODE

Владелец — **общий `update-workflow` / dependency handoff между новым producer и старым post-copy helper**, не Cognee и не Code/Graph. В current `agent-1c.dependencies.ps1` `New-WorkflowDependencyPlan` формирует schemaVersion2 с `mode=workflow`. У старого `fa0e3c9` `ConvertTo-DependencyMode` в `agent-1c.core.ps1` принимает только fresh/latest и locked/pinned. Сохранённый transaction содержит `dependencyPlan.manifest.mode=workflow`; исходный отдельный fresh-child status содержит точный errorMessage и `stage=workflow-update.post-copy`.

Outer result — `WORKFLOW_UPDATE_POST_COPY_INCOMPLETE`. Main находится в **незавершённом смешанном состоянии**, sibling ещё на новом пакете; clean/успешный downgrade не заявляются. Snapshot `3ad27342dd144f5487c218e946340715` остаётся `post-copy-failed`, исходный кандидат чист и закреплён. Diagnostics status создал только report и не изменил transaction. Успешный terminal статус этой диагностической команды не заменяет failed terminal downgrade и pending receipt.

Для закрытия требуется исправление/квалификация поддерживаемого dependency handoff у существующего владельца и повтор **того же native downgrade** на сохранённом canary, с successful post-copy, commit и rollout. Режим в `.dev.env`/lock/receipt вручную не менялся; неподдерживаемый старый helper не патчился, guards не обходились. Исправление в этом задании не начиналось; повтор неизменного failed update не выполнялся. Snapshot и исходные неуспехи сохранены для последующего воспроизведения.

## Диагностические и harness ограничения

Первый private old-source checkout не использован; его частичные файлы сохранены без force/delete, отдельный короткий clone checkout exact commit прошёл. Wrapper catalog первоначально пытался использовать `$Action`, которому dot-sourced fixture entrypoint уже назначил ValidateSet; имя изменено до native catalog invocation. Первоначальная shell-проверка optional Cursor не остановилась на отсутствующем файле; её JSON сохранён с `invalid-absence` в имени и не используется как proof. Исправленная проверка сверяет recorded existence, сравнивает значения только существующего Kilo и прямо фиксирует отсутствие Cursor и неравенство Kilo bytes.

Source-side launcher без explicit `-SourceRoot` завершился до owner: default expression `Split-Path -Parent $PSScriptRoot` получил пустую строку. Диагностика qualified только с explicit source. Первый SnapshotId ошибочно содержал весь directory prefix и штатно отвергнут; правильный ID — `3ad27342dd144f5487c218e946340715`. Эти исходные errors сохранены; они не отменяют отдельно воспроизведённый dependency-mode blocker. В этом прогоне не квалифицирован default-source вариант launcher.

## Сохранность и оставшиеся проверки

Прежний current PM5 main/sibling, его DB SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`, 21 historical file, четыре старых roots и 11 capsule objects повторно проверены и сохранены. Десять relevant source/installed runtime hashes прежнего стенда совпали. База нового canary сохранила SHA и размер между состоянием после первого update и завершением остальных проверок; её новый RestoreIB не объявляется byte-identity старой базы. В обоих roots нового canary Gate 6 artifacts отсутствуют. Runtime процессы этого прогона завершены, fixture lease освобождена; failed copy/checkpoint оставлены.

Открыты: исправление нового downgrade blocker; положительные new branch/fork/refresh и full init; остальные foreground first-legacy варианты; прежние PM4/platform/native-client клетки. Обязательное предвыпускное products/projects/settings/functionality population AC-36–38 / memory AC-44 не выполнялось. AC-18/21/22/31–33/39 закрыты только в явно указанном subset; память/G5 и полная G3 не принимаются этим proof. Шесть областей, optional OpenViking, canonical knowledge home, ai_rules ownership и независимость registry от G4 прежние.

## Артефакты

[JSON результатов](g3-pm5-lifecycle-2026-10-24.json) содержит exact identities, grouped outcomes и blocker. Ignored raw root: `build/test-results/g3/lifecycle-pm5-20261024`; manifest SHA **`5693e939a725381145a99d701467f72ccf18c61ba3038b42e0f5e68c6b84a20e`**, 957 files. Полный failed snapshot дополнительно сохранён в `failed-downgrade-snapshot.zip`, SHA **`88b317d3d2740311d9d9a6e2bd2f278efc8606c9e8aab610fec9b780e0058a38`**, 3381258 bytes. Fresh-child terminal proof скопирован отдельно от последующей lifecycle diagnostic записи. Поздние OpenSpec/registration logs хранятся вне sealed raw root. Registration не является публикацией или положительной lifecycle квалификацией.
