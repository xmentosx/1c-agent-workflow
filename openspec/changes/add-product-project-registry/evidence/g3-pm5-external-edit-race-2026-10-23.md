# G3: внешняя правка MCP после согласия, PM5, 2026-10-23

**Защита от устаревшего согласия и остановка partial writer подтверждены; точная сохранность чужих байтов при recovery не принята.** Новый blocker **G3-MCP-FOREIGN-BYTE-PRESERVATION**, AC-16/24/26/39. Ни semantic success, ни source registration не снимают byte failure. [JSON, receipts и SHA raw evidence](g3-pm5-external-edit-race-2026-10-23.json).

## Неизменный стенд и метод

Тот же main `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, sibling `branch`, PM5 КОРП/pm5-core-development, физические Kilo+Cursor. Source base **`8b6265689071cedcf39f8bff51b05357ea4cc574`**, installed **`44ce6ebad18b635c582ca26e96d6e9d4ce96c081`**. Update/package/server/client/runtime/tests не менялись. Четыре критических runtime файла совпадают source/main/sibling. Проверены native WinPS5 public helpers, не подменённые функции/записи.

Один контроллер удерживает existing qualification-fixture lease. Command breakpoints только приостанавливают настоящий helper после принятого решения или durable B intent. Отдельный процесс внешнего редактора с собственным PID делает CAS-правку разрешённого client JSON и архивирует before/after bytes. Operation/ownership/applied records вручную не редактировались. Согласие передано через поддерживаемый **`-CatalogDecision registry`**; ввод Read-Host/GUI и independent terminal users здесь не повторялись. Private origin/author/cache/home отдельны, исходные origins не менялись; harmless loopback URLs не использованы для initiated MCP tool calls.

## Три исходных сценария

| Проверка | Фактический результат | Граница приёмки |
|---|---|---|
| Настоящий three-way conflict: Cursor Graph уже вручную изменён, catalog содержит третье значение; после registry decision редактор ещё раз меняет Graph | `CLIENT_MCP_PREVIEW_CHANGED`, exit1, main не достигнут; все девять protected SHA/actual mtime после edit неизменны, включая operation/ownership/applied | Stale consent не используется повторно. Read-only preview и следующий запуск без нового решения сохраняют файлы/возвращают needs-user-action |
| Свежий keep-local после отказа | Ровно новая внешняя URL сохранена, override записан, следующий original command exit0/main без повторного вопроса | Explicit registry после контролируемого withdrawal своей правки и baseline cleanup идут через public owner |
| После настоящей A/Kilo receipt и сохранённого B/Cursor intent внешний процесс добавляет чужой Kilo MCP key; затем resume | `CLIENT_MCP_FINAL_SET_CHANGED`, exit1, main не достигнут; B и marker не записаны. Новый status partial, actual A receipt и B intent сохранены; read-only status ничего не меняет | При новом publisher tip resume сохраняет operation ID/pinned SHA, доводит исходные endpoints до обоих клиентов, foreign entry не присваивается owner. Следующий original main/exit0 passed; strict byte preservation failed ниже |
| Независимый повтор того же late edit с restore | Такой же честный partial stop; pinned restore возвращает прежний applied context целиком по JSON-семантике и оба owned endpoints, чужое подключение остаётся | При новом tip ID/SHA плана прежние. После возврата desired baseline отдельный original command exit0; strict byte preservation failed ниже |

В принятом функциональном replay **20 public calls**: 16 exit0 и четыре ожидаемых exit1; **7 external-editor calls** с разными PID writer/editor. У всех трёх paused race calls instrumentation errors пусты, main не запущен; порядок pause → external write → release проверен. Это функциональная race qualification, не новый Startup benchmark. У source helper используется обычное `$?` outcome, stale native Git LASTEXITCODE не выдаётся за ошибку helper.

## Открытый blocker точной сохранности байтов

Оба прежних strict byte verifiers запущены без изменения assertions и завершились exit1; исходные scripts/logs сохранены. После resume и после restore порядок unowned entries отличается от внешнего edit. Финальные client files семантически совпадают с исходными, но **оба не byte-equal**; вручную переписывать их из backup ради pass не стали.

Владелец подтверждённого изменения порядка — existing **`Write-ItlClientMcpEndpoints`**, `agent-1c.client-adapters.ps1`: он сортирует **весь** MCP container через `Array.Sort`/Ordinal и заново сериализует JSON. Внешний `g3-race-foreign-*`, добавленный после согласия в конец object, перемещается относительно существующих **unowned** entries. Это воспроизведено обоими recovery путями. Дополнительные перестановки полей common ITL-owned entries при restore не называются потерей чужих значений: их scope проверен по фактической ownership map.

Отдельная диагностика всех Kilo owner keys показывает: **6/6** comparisons сохраняют семантику и raw value spans настоящих чужих entries; перед recovery порядок сохранён **2/2**, после recovery/original command порядок изменён **4/4**. Это уточняет причину и масштаб, **не заменяет** failed outside-owned byte assertion семантическим pass. Новый runtime FAIL/barrier не добавлен; полная приёмка AC-16/24/26/39/4.2 остаётся открытой.

Продолжение у существующего JSON writer: сохранить foreign sections/order/bytes при изменении owned entries, затем повторить **исходное добавление в конец object** и оба recovery пути. Не менять порядок внешней правки под сортировку, не расширять маску/не ослаблять assertions. Любое предложение изменить контракт сериализации требует отдельного явного решения с сохранением equivalent original regression. Реализация исправления в этом квалификационном запросе не выполнялась.

## Failed observer и сохранность

Первый attempt ошибся в observer при чтении `activeWrite=null` completed operation; pause file не был опубликован, внешний edit после согласия не состоялся, original command выполнился. Исходная failure assertion, script, observer, stdout/stderr и physical snapshots сохранены в `external-edit-race-20261023`. Это **failed harness**, не pass и не доказательство runtime race. Public explicit-registry cleanup вернул исходный desired endpoint без ручных records; nullable guard/момент публикации pause исправлены только в новом replay harness, затем вся серия повторена на том же root/package. Failed byte assertions итогового replay относятся к реальному writer и отдельно не переоценены в pass.

21 protected files/4 old roots/7 Gate6 artifacts/11 capsule hashes и **1553 prior raw files** подтверждены. DB SHA **`c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`**, 3,295,928,320 bytes; main/sibling HEAD/descriptor/locks/ai_rules прежние, оба roots clean, owned processes завершены. Предыдущие failed copies, raw evidence, startup series, historical seed movement и missing original raw seed сохранены. Byte failure относится к текущим ignored client files, не к исходным архивам; ни их, ни records не переписали для зелёного результата. Оригинальные значения endpoints/чужих settings восстановлены штатными действиями; тестовый external key удалён только своим CAS editor.

On-demand context **2157 UTF8 bytes**, ≈540 tokens только bytes/4 proxy; actual tokens/billing неизвестны. Initiated 1C/MCP tool/LLM/Cognee calls — 0; новых always-on instructions/tool schemas — 0 bytes. Source/runtime/tests не менялись; unchanged owner suites повторно не запускались. Обе OpenSpec strict validate CLI1.13.1; RegisterChange/Targeted — отдельный source ledger и не acceptance byte blocker.

Full G3/AC-39, точный legacy feature baseline, interactive/terminal/прочие installed-client-platform/PM4 критерии и release population AC-36–38 открыты. [Startup cost subset](g3-startup-window-repair-2026-10-23.md) остаётся пройденным, новой серии времени нет. Memory consumer4.2/G4/AC-43/G5/44 не реализованы/не приняты; шесть областей/canonical home/grants/Q1–Q7/D9/G2/optional OpenViking/ai_rules_1c прежние. **Gate6, G4, рабочая миграция и публикация не выполнялись.**
