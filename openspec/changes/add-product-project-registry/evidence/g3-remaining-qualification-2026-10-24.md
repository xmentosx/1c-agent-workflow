# G3: оставшиеся доступные проверки PM5, 2026-10-24

> Уточнение текущего остатка: после последующего cost repair пользователь принял превышение warm median49.731мс как допустимое; G3-PM5-WARM-STARTUP-MEDIAN закрыт как ACCEPTED DEVIATION и не блокирует G3. См. [актуальный cost report](g3-publisher-cost-repair-2026-10-24.md). Остальная матрица этим решением не закрыта.

**Пройдены: current PM5 native Codex core/API (11 tools, 0 model turns) и три функциональных режима Startup. Полная G3/registry AC-39 не принята.** OpenCode сохраняет [SKIPPED по решению пользователя](g3-opencode-skip-2026-10-24.md), не блокирует этот прогон и не объявляется PASS. Код workflow не менялся. Gate 6, G4, рабочая миграция и публикация не выполнялись.

## Точный срез

Существующий root `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, sibling branch без binding, PM5 КОРП `pm5-core-development`/`pm5-corp`; штатный membership Kilo+Cursor сохранён. Installed `dfae2ff3353cd0784867eb8eac5d115a2d3d741a`, source `24ff6160401f7057939d1965f672c1a543c10ea2`, ai_rules r43 `987320be139b4ac0d28f1f5b0f2515f63c7f140f`. Проверены 10 relevant source/installed runtime hashes; база SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`, 3295928320 bytes, unchanged. ОС из CIM: Windows11 Home, build26300; это не подтверждение Win10/Server/terminal. 1С не запускалась.

Для Codex публичный установленный `sync-client-mcp -Client codex` подготовил конфиг только на этом тестовом root без enrollment/изменения membership. Native Codex `codex-cli 0.163.0-alpha.11`, executable SHA `00c0f1e4099246fddcd67ec620ca8ed50827c7d70e113b7224f7a2933cf2d67c`, private qualification homes, ephemeral read-only threads, approval=never. Повторно использован retained RPC helper; project config прочитан настоящим app-server, endpoints не подставлялись в native harness. Runtime/server patches и source stamps не добавлялись.

## Codex и клиентская матрица

`stats({})` и `list_graph_projects({})` прошли до reload, после `config/mcpServer/reload` в прежней thread и в новой thread: 6 фактических native calls. Code подтвердил `УправлениеПроектамиКОРП`, Graph — accessible/valid `pm5corp/default`; native origins22100/22101 совпали с выбранным source. Это клиентский core/API, не запуск агента в Desktop UI.

Ещё 5 native calls: Code `get_module_structure` для `CommonModules/ОбщегоНазначения/Ext/Module.bsl` и Graph fulltext `search_code` до/после reload, затем foreign project `pm4corp`. Полезные чтения вернули непустой результат; чужой проект — `project_not_accessible` без чужих items/results. Чтения ограничены max_chars2048/max_items1, Graph top_k1. Два owned app-server завершились штатным EOF/exit0, force termination не применялось. В RPC journal 11 `mcpServer/tool/call`, `turn/start=0`; это не model-token/billing benchmark. Global config не копировался/не изменялся harness; metadata run отдельно подтвердил его SHA unchanged.

| Клиенты | Актуальное доказательство | Остаток |
|---|---|---|
| Codex | Current PM5 native core/API reads, useful content, deny, reload и new thread PASS | Desktop/model-agent UI и full installed journey не приняты этим proof |
| Kilo / Cursor | Сохранён [current PM5 IDE reads/reload pass](g3-pm5-native-clients-2026-10-24.md), версии/границы прежние | Другие платформы/семейства/full lifecycle |
| OpenCode | SKIPPED по решению пользователя; предыдущие0 agent calls сохранены | Поддержка/общая матрица не удалены |
| Cline, Claude Code, Kimi, Qwen, Command Code, ZCode, MimoCode, Pi | Native UNVERIFIED | CLI не найдены в PATH; Cline/Claude Code не найдены в `.vscode/extensions` и `.cursor/extensions`. Это bounded discovery, не глобальный вывод об отсутствии |

Присутствие VS Code/Cursor и Kilo7.8.12/7.8.15 подтверждено inventory, без установки клиентов, чтения credentials или изменения пользовательских профилей. Новый пользовательский Desktop-чат не создавался; core/API proof не заменяет проверку его tools.

## Дополнительные режимы Startup

Через existing public `sync-client-mcp -Client kilocode` на том же root, с retained full diagnostic observer выполнены prime и три режима. Создан новый ignored local bare origin и private author/cache, исходный каталог/прежние sealed evidence не изменялись. Два синтетических fixture-коммита отправлены только в этот локальный bare repo; workflow и общий/рабочий реестр не публиковались.

| Режим | Полное окно Import→main, с | Whole CLI, с | stdout/stderr, UTF-8 bytes |
|---|---:|---:|---:|
| publisher-only | 5.426 | 8.120 | 1562 / 0 |
| changed | 6.896 | 9.894 | 1630 / 0 |
| offline | 3.532 | 7.750 | 1189 / 0 |

Publisher-only изменил лишь publishedAt: оба client files сохранили bytes/mtime. Реальная смена выбранного Graph endpoint на loopback test URL материализовалась в Kilo и Cursor до main; applied revision совпала с новым fixture SHA. Этот URL не опрашивался живыми MCP-клиентами. Offline: private cache origin временно указывал на недоступный loopback; команда достигла main с valid applied и freshness WARN, client bytes/mtime сохранены; cache remote восстановлен. В каждом режиме startupCalls1, fetch1, PowerShell HTTP probes0; повторного nested refresh и новых LLM/memory probes нет.

Это одиночные профилированные наблюдения, **не paired legacy/catalog incremental benchmark и не median/p95**. Значения5.426/6.896/3.532с не подменяют [прежние20 AB/BA warm no-op blocks](g3-cost-baseline-2026-10-24.md) и не доказывают SLA динамических режимов. Стоимость полного наблюдателя не вычиталась. Цели1/2с warm unchanged не перенесены на другие workloads и не ослаблены. Для количественного приёма всей стоимости ещё нужны сопоставимые dynamic/control и прочие platform/client scopes; точная причина разницы с warm no-op не устанавливалась этим тестом. Новых always-on rules/tool schemas/startup probes не добавлено; output bytes — фактические bytes, не заявленные billed tokens.

## Обновлённый остаток G3

| Блок | Что уже подтверждено | Что остаётся |
|---|---|---|
| B1 | Локальный Windows11 subset | Win10/Server2019+, terminal и независимые пользователи: подготовленных стендов нет |
| B2 | Сохранены PM4 source/file fixtures | Реальный изолированный PM4 installed stand отсутствует |
| B3 | Прежний разрешённый capsule update/later/select/restore и current PM5 ordinary/update/recovery subsets сохранены | Full fresh init/new branch/refresh/managed downgrade и оставшиеся first legacy choices; Gate6 исключён, missing live seed не заменён capsule currentness |
| B4 | Current Codex core/API добавлен к Kilo/Cursor native IDE pass; OpenCode skipped | Codex Desktop/model UI,8 остальных native clients и full platform/lifecycle matrix |
| B5 | Сопоставимый warm no-op A/B pass сохранён; current publisher/change/offline functional/count/bytes subset выполнен | Paired incremental dynamic cost и полная platform/client/cold/remote область; одиночные samples не закрывают этот общий блок |

На имеющемся PM5 ещё технически возможен отдельный сопоставимый dynamic A/B cost batch; он не выдан за выполненный. Desktop/native проверки требуют подходящих выделенных профилей/клиентов; поддержку не сокращаем и другие клиенты автоматически не устанавливаем. Выпускное наполнение products/projects/settings/functionality map AC-36–38 / memory AC-44 остаётся обязательным отдельным поручением до первого выпуска. Регистрация документов не является полной G3, выпуском или разрешением G4.

## Сохранность и evidence

Строгий final guard46/46 SHA и mtime совпал с исходным. Ровно7 изменённых fixture files/отсутствий сняты test-actor CAS teardown из первоначального архива после native EOF и завершения public commands; final native bytes сохранены. Это снятие тестовой подготовки, не новая приёмка product restore. Membership, descriptor/lock, main/branch Git state, база,21 historical artifacts,4 seed/failed roots и11 capsule hashes сохранены. Fixture lease освобождена. Проверены 1847 files трёх прежних sealed manifests. Старые failures/results не переписывались.

[JSON result/matrix](g3-remaining-qualification-2026-10-24.json) содержит отдельные historical/fresh области 39 AC,12 clients, blocker list, native request/thread IDs, timing/bytes и hashed primary artifacts. Raw root `C:\Users\xment\.codex\worktrees\product-project-registry-g3\1c-agent-workflow\build\test-results\g3\remaining-20261024`; manifest `44d09f51696c0817e38ac2aaeee732ded2595d9e99dab1631117675135ca84f3`, 793 files. Последующие OpenSpec/registration records идут отдельно в delivery. Broad unchanged tests, Gate6, G4, рабочая миграция, source/public-registry publication не запускались; штатный RegisterChange выполняет свой Targeted.
