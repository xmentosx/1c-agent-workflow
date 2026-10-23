# G3: сохранность чужих MCP bytes при resume/restore, 2026-10-23

**G3-MCP-FOREIGN-BYTE-PRESERVATION закрыт в исходном PM5 Kilo+Cursor subset.** Прежние воспроизводитель и strict assertions прошли после исправления существующего JSON writer. Full G3/AC-39 целиком не принят. [JSON, receipts и SHA raw evidence](g3-mcp-foreign-byte-repair-2026-10-23.json); [прежний failed result](g3-pm5-external-edit-race-2026-10-23.md) сохранён без переоценки.

## Причина и исправление

`Write-ItlClientMcpEndpoints` сортировал весь MCP object и сериализовал весь JSON, переставляя чужие keys и меняя unrelated formatting. Теперь сортировка остаётся только в semantic projection. Physical document правится существующим `agent-1c.jsonc.ps1` editor: только разрешённые owned properties; семантически равные значения сохраняют исходный text. Strict UTF-8 чтение сохраняет BOM, порядок, whitespace, числовые и escaped Unicode представления вне owned изменений. Новый/пустой документ создаётся прежним serializer.

Один projected text определяет PlanOnly `afterFiles`, atomic write и receipt. Semantic no-op не вызывает generic editor/initializer и не перезаписывает client file. Ownership, collisions, explicit consent, actual input checks, partial receipts, marker-last и pinned recovery не менялись. Новых coordinator/cache/state/locks/probes и always-on instructions/tool schemas нет.

Source base `5da27380c52c3580b03b17503939e4dd0b7481d7`; проверенная implementation candidate **`6642b1f9777d4cb7caff89d12ef28e6c08f49a1e`**. После доказательств candidate дополнен OpenSpec/results и усилением legacy test ниже; executable и ProductProjectApply blobs прежние, их идентичность проверяется перед финальным RegisterChange. Registration/Targeted принадлежат отдельному atomic source-delivery ledger, не являются публикацией или full G3 acceptance.

## Проверки source и исходный стенд

Пять новых regressions: Cursor/Kilo/ZCode с literal BOM/mixed newline/Unicode JSON, PlanOnly→actual receipt, repeat no-op SHA/actual mtime; оба partial recovery пути с настоящей внешней append-правкой. На прежнем owner **0 passed / 5 failed**, на исправленном **5/0**. Шесть профильных suites без фильтра: **228 passed / 0 failed / 0 skipped / 0 notRun**, wall 310.688 s. Assertions и пороги не ослаблялись. Остальные обязательные проверки определяет финальный RegisterChange.

Тот же main `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project` и sibling `branch`, PM5 КОРП/`pm5-core-development`, WinPS5, физические Kilo+Cursor. Оба штатно обновлены с `44ce6eba` до candidate6642b1f9 и clean перед/после replay. Пять критических runtime files совпадают source/main/sibling. Descriptor hashes прежние, ai_rules_1c r43 **`987320be139b4ac0d28f1f5b0f2515f63c7f140f`**. HEAD/lock изменены только normal updater; в самом replay их изменение запрещено и не обнаружено.

Private origin/author/cache/home независимы, прежние origins не менялись. Один existing fixture lease. Native race controller использует только timing breakpoints и отдельный CAS editor process. **`external-edit.ps1` и `paused-command.ps1` побайтно равны прежним; оба strict verifiers отличаются только evidence-root.** Никаких runtime mocks/подмены implementations в native replay, ручных operation/ownership/applied/transaction edits или перестановки append-правки под writer.

## Native результат

| Исходная проверка | Результат |
|---|---|
| True three-way conflict → explicit registry consent → отдельная внешняя owned URL edit | `CLIENT_MCP_PREVIEW_CHANGED`, exit1, main не запущен; все девять protected SHA/actual mtime после edit прежние. Preview/повтор без нового решения read-only; fresh keep-local и следующий original command passed |
| Actual A/Kilo receipt + durable B/Cursor intent → append чужого Kilo key | `CLIENT_MCP_FINAL_SET_CHANGED`, truthful partial, B и marker не записаны, main не запущен; status read-only |
| Pinned resume после нового publisher tip | Прежние operation ID/revision, оба исходных endpoint применены, чужое подключение не присвоено owner. Следующая original command завершилась и увидела новый tip |
| Независимый late edit → pinned restore → original command | Прежние ID/revision, before applied context восстановлен целиком по JSON-семантике; owned endpoints возвращены, чужое подключение сохранено. Original command passed |
| Неизменённый strict foreign verifier | **6/6 passed**: refusal/recovered/original-passed для resume и restore; прежняя маска исключает только четыре owned Code/Graph value spans, все остальные bytes/order/whitespace сравниваются точно |
| Неизменённый final client verifier | **2/2 passed**: JSON semantics и все bytes вне owned values равны исходным. Kilo целиком byte-equal; Cursor отличается только внутри owned value spans. Whole-file equality измерена отдельно и не выдаётся за pass для Cursor |

**20 native public calls: 16 success и четыре ожидаемых safety refusals; 7 independent editor calls.** У всех race observers нет instrumentation errors, main suppression и pause→external write→release подтверждены по разным PID/timestamps. Использован поддерживаемый `-CatalogDecision registry`; actual Read-Host/GUI/independent terminal-user journey этим не закрывается. После проверки тестовые внешние keys удалены только своим CAS editor, original commands завершены; ручного возврата client files из backup ради pass не было.

## Отдельное ограничение updater

**G3-PM5-UPDATE-COPY-STATUS-STALE открыт.** Подготовка пакета дала два отказа normal compact updater: `LIFECYCLE_OPERATION_STATUS_STALE`, `workflow-update.copy`, прежний watchdog **120 s**, при action budget3600 s. Первый retained receipt был `copying`; штатный повтор восстановил exact before snapshot и заново начал update. Второй retained receipt успел перейти в `copy-complete`; следующий normal updater продолжил pinned post-copy и обновил main+sibling до clean candidate, exit0, 457.983 s.

Оба failed status/console/transaction/preparation и wrapper logs сохранены до штатного потребления snapshots. Не увеличивались timeout/watchdog, не отключался compact runner, не запускалась вручную post-copy, не менялись runtime/receipts вне normal updater. Исчезновение status freshness относится к подготовке, до native race replay. Точная внутренняя причина длительности этой стадии не локализована; это **не first-pass/uninterrupted upgrade acceptance**. Следующая задача — диагностика existing updater/status owner и повтор исходного workload с прежними guards; новый recovery manager не нужен.

## Стоимость и сохранность

Первый RegisterChange candidate `f887fb5f` не зарегистрирован: Targeted остановлен с **349 passed / 1 failed**, выборка неполная. Отказ в `ClientAdaptersAndModes.Tests.ps1` требовал глобальный порядок `alpha, custom, zulu` вместо фактического `custom, alpha, zulu`. Это старое ожидание physical sorting, не детерминизма owned output: оно разрешало перемещать/нормализовать уже существующий foreign fragment и противоречило исходным failed native byte assertions и согласованному AC-16. Failed candidate, JUnit, stdout/stderr и summary сохранены; этот gate не переоценён в pass.

Сохранены тот же fixture, исходный inline JSON, оба вызова с обратным порядком endpoints и все client-layout/URL/permission проверки. Вместо требования сортировать foreign key теперь проверяются точный состав всех keys, порядок owned additions, прежний repeat SHA и дополнительно actual mtime no-op и точные foreign prefix/suffix, включая исходный BOM/formatting/root permissions. Это коррекция доказанно неверного order contract с более строгой сохранностью, не удаление проверки детерминизма. Runtime и оба native byte verifiers не менялись. Один изменённый case прошёл **1/0**, остальные40 не запускались в этом focused run; полный unfiltered Targeted остаётся отдельным обязательным условием регистрации. Новые evidence/manifest этой коррекции добавлены к исходному frozen manifest416 файлов через JSON report; первая failure сохранена отдельно.

По одному warmup и три unprofiled no-op исходной whole CLI команды на version: before **7120/6852/6890 ms**, after **8999/8646/8515 ms**; median **6890→8646 ms**, +1756 ms/+25.49%. Protected SHA/actual mtime неизменны. Отдельный functional observer: generic editor calls **0**, generic initializer calls **0**. Это короткое shared-host before/after наблюдение, не 20-sample Startup или exact feature delta, и latency equality не заявляется.

Для attribution отдельно выполнено read-only сравнение точных archived/installed function definitions в одном измерительном процессе с теми же current dependencies/PM5 Kilo file. Только transient выбор definition, `RestoreEntries` semantic no-op/PlanOnly; installed files/state не патчились. Один warmup/version и **20 alternating pairs**: owner median **34.69255→37.26060 ms** (+2.56805 ms), p95 **42.6374→48.9347 ms**. Parse/import функций вне этого окна; весь protected набор не изменился. Это диагностический micro-measurement, не подмена original native acceptance и не объяснение всей разницы whole CLI. Остальная разница 1.756 s не атрибутирована; точный feature/cumulative cost критерий остаётся открытым. Прежний Startup report и его 20-pair series сохранены.

On-demand context **2157 UTF8 bytes**, ≈540 tokens только bytes/4 proxy; actual tokens/billing неизвестны. Новых token-bearing surfaces **0 bytes**. Initiated 1C launches/direct MCP tools/LLM/Cognee calls —0; server/client upgrades не выполнялись.

DB SHA **`c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`**, 3,295,928,320 bytes, прежний. **21 protected files / 4 old roots / 7 Gate6 artifacts / 11 capsule artifact hashes / 1916 prior raw files** проверены; capsule, исходные failed copies, предыдущие failures и missing original raw seed сохранены. Оба текущих roots clean, owned race processes завершены. Fresh audits относятся к отдельным scopes: replay identity сравнивается после normal package update, старые protected roots — с before этого запроса.

Обе OpenSpec используют один canonical report/JSON и прежние AC-16/24/26/39, а не semantic-only замену byte contract. Full registry4.2/5.2/G3/AC-39, другие client/platform/PM4/terminal/interactive journeys, полный feature cost и mandatory release population AC-36–38 открыты. Memory consumer4.2/G4/AC-43/G5/44 не реализованы/не приняты. Реестр, различия project/MCP source, canonical product home, шесть областей/grants/optional OpenViking и ai_rules_1c compatibility прежние. **Gate6, G4, рабочая миграция и публикация не выполнялись.**
