# G3: текущий PM5 — multi-client, конфликты и offline, 2026-10-22

**G3 / AC-39 открыт.** Выполнены доступные native проверки на прежнем изолированном PM5-стенде; обнаружены два блокера existing registry/client owner. Runtime не менялся. Канонические результаты, 20 captured public CLI results и SHA 134 raw files — [JSON](g3-pm5-multiclient-offline-2026-10-22.json). Предыдущий [single-client срез](g3-pm5-current-package-2026-10-22.md) сохранён и не подменён этим результатом.

## Точная область

Source до записи отчёта `97ded24499fea546ca86f94402c4d5ad6c208ca8`; installed runtime **`d109a95dc1db95199bb3b2d4114b6cafddd05adb`**, ai_rules_1c r43 / `987320be139b4ac0d28f1f5b0f2515f63c7f140f`. Обычный Windows 11 / PowerShell 5.1, без elevation.

- Main: `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`.
- Sibling: тот же parent, `branch`; HEAD `b17b380ff17e64a49063eb6f77407a32ea2ac922`, unbound, clean.
- Existing PM5 DB SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`, 3,295,928,320 bytes, до/после прежний; 1C lifecycle/запуск базы в этом срезе не выполнялся.
- Public `itl-switch-client -Mode attach -Client cursor` добавил project-local Cursor к существующему Kilo. Штатная генерация surfaces дала 449 setup paths без business tree changes. Они закреплены только в disposable PM5 repo: `5c0665bc…` → `fd9a31f734b4eac86a603dc989dac70d8df74b6c`. Это fixture commit, не source delivery или публикация workflow.
- Отдельный bare Git origin/author clone в `build/test-results/g3/multi-client-offline-20261022/`; предыдущий private catalog `96ae1e8d…` не менялся. Только private test origin получал тестовые commits/push. Реестр production, пользовательские global profiles и рабочие проекты не менялись.

## Результаты

| Проверка | Наблюдение | Приёмка |
|---|---|---|
| Два клиента / late select | Public select exit 0, stage `configured`. Cursor получил Code/Graph; Kilo сохранил отсутствие обоих как local difference. Persisted Kilo request содержит `endpoints=[]`, Cursor request — оба endpoint | **Failed**, `G3-CATALOG-OWNED-MCP-REENABLE`; config marker не доказывает materialization или native activation |
| Продолжение, предложенное helper | `vibecoding1c-mcp-write-client-config -Client kilocode`, затем explicit catalog sync/registry: оба exit 0, Code/Graph в Kilo по-прежнему отсутствуют | **Failed semantic continuation**, исходный результат и warning сохранены; receipts/config вручную не удалялись |
| Конфликт / unattended без решения | Ручной Cursor Graph URL `http://127.0.0.1:9/g3-foreign-*` против registry Graph own→disabled. Во всех трёх случаях exit 1 `CATALOG_CONFLICT_NEEDS_USER_ACTION`, SHA и actual mtime семи protected paths неизменны | Passed subset AC-24; пользовательское решение не выдумано |
| `keep-local` → обычный writer | Ручной Graph сохранён, override persisted, новый catalog SHA применён; следующая команда без вопроса/записи семи protected files, exit 0 | Passed subset AC-15/24/25; чужой synthetic disabled server сохранён |
| `defer` | Решение exit 0, ручной Graph и прежний catalog SHA сохранены | Passed только само решение; последующая команда — следующий пункт |
| `defer` → исходный обычный MCP writer | Startup сообщает сохранение deferred context. Main writer возвращает 0, но удаляет `productProject.defer`; revision остаётся прежней. Exact selection сразу после решения и после writer сохранены | **Failed**, `G3-DEFER-MCP-WRITER-PREFERENCE-LOSS`; full AC-24/no-op не принят |
| `registry` → обычный writer | Managed Graph удалён согласно реестру, unrelated server сохранён; обычный повтор без вопроса и без изменения семи protected files | Passed subset AC-15/24/25 |
| Graph disabled→own, explicit registry sync | Context включает Graph endpoint intent новой ревизии, exit 0 / «client MCP settings unchanged», но Graph в Cursor не появился | **Failed**, то же семейство `G3-CATALOG-OWNED-MCP-REENABLE`; точная причина owner baseline/preview ещё не доказана |
| Offline, bound + valid applied/cache | Реальный stalled loopback origin принял fetch, ровно один fetch. Main writer достигнут, exit 0, freshness warning; SHA и mtime восьми protected paths неизменны | Passed continuation/preservation subset AC-17/25, без подтверждения native tool readiness |
| Offline, unbound без cache | Новый отдельный local home, реальная clone attempt/stall. Exit 1 `CATALOG_REFRESH_UNAVAILABLE`, восьми protected paths не изменены; binding/IDs не записаны. Затем public status/help exit 0 | Passed safe failure/diagnostics subset AC-17; это initial select, не повреждённый applied snapshot |

`keep-local` и `registry` проверены явными public decision arguments. В этом срезе не проверены интерактивные cancel/invalid answer, corrupted cache и invalid-applied variants. Полный multi-client fault → чужая правка B → pinned resume/restore **заблокирован**: первый клиент Kilo не материализовал исходные Code/Graph. No-op receipt первого клиента не заменяет физическую запись A.

## Offline timing и расходы

Fetch→первый fallback Git read **10.152632 s**, clone→fallback read **10.279105 s**, при прежнем owner deadline 10 s. Это trace spans с запуском/переходом к чтению, не доказательство всего CLI ≤10 s. Whole native capture **24.942/24.985 s**; stalled Git transport children завершаются позже fallback, наблюдаемый lifespan **22.17209/21.24117 s** до собственного exit. Исходный listener ограничен 25 s, завершён кооперативно; normal origin восстановлен. Точная attribution хвоста transport/capture и строгая latency/cleanup приёмка остаются открытыми. Не смешивать lifespan дочернего Git с длительностью metadata hook и не расширять бюджет для получения green.

Новых always-on инструкций, startup probes, token-heavy schemas или runtime checks нет. LLM turns **0**, native Code/Graph tool calls **0**, Cognee calls **0**. Token/billing delta и paired isolated Startup overhead этим config-only прогоном не измерены; полная cost-приёмка не закрыта.

## Блокеры и следующий шаг

1. **G3-CATALOG-OWNED-MCP-REENABLE** — существующие catalog preview/managed MCP baseline-retirement/apply. Разобрать различение owner removal и пользовательского override, а также безрезультатное предложенное continuation. Повторить на **том же Kilo+Cursor root/order/history** late select и own→disabled→own, сохранив unrelated entries. Затем выполнить реальную запись A → fault B → внешнюю owned/unrelated правку → blocked main/status → same-operation/same-revision resume/restore. Не удалять receipts, не чинить конфиги вручную, не подменять A no-op и не дорабатывать Code/Graph servers.
2. **G3-DEFER-MCP-WRITER-PREFERENCE-LOSS** — существующий pinned-context/public MCP writer decision path. Повторить исходный manual Graph edit → registry removal → defer → ordinary writer; сохранить defer, revision, local override и no-op proof до явного нового решения, проверить следующий обычный запуск. Начальный harness не сохранил каждый receipt hash непосредственно перед повтором; потеря именно `defer` независимо доказана двумя exact selection files, а не предположением о всех receipt changes.

Runtime-исправления этих блокеров в данном qualification-only срезе не сделаны. Assertions обоих failed scripts не ослаблялись. `conflicts.ps1` остановился на defer repeat; независимый `conflict-registry.ps1` выполнил решение registry и no-op, затем остановился на настоящем Graph re-enable failure. Failures, stdout/stderr и snapshots сохранены. Native exit 0 нигде не приравнен к полной приёмке.

## Сохранность и граница этапа

21 protected file и четыре старых roots сохранили SHA/HEAD/dirty state, включая failed copy и семь Gate 6 artifacts. Sealed capsule SHA `c2c570fe1ec57619f1a516b9752c48159da7b703eb8c8bb275977abde19cd8b6`, все 11 artifact hashes проверены. Missing original raw seed не восстановлен молча; текущесть live seed не заявляется.

Нынешний main намеренно сохранён как reproducer: tools Kilo+Cursor, bound `pm5-core-development`, descriptor отличается от fixture setup commit, Graph отсутствует после failed re-enable, synthetic unrelated disabled entries и owner records сохранены. Sibling unbound/clean. Это disposable stand, не миграция рабочей установки; автоматическое restore/cleanup для сокрытия дефекта не выполнялось. Memory off, прежний prepared custom draft не опубликован.

Открыты full G3/AC-39, оставшиеся fresh init/branch/refresh/downgrade/live seed/client/platform/terminal/cost criteria и обязательное выпускное наполнение AC-36–38/5.7. В memory это только dependency для 4.2/AC-43/G5/44. Шесть областей, home/grants, Q1–Q7/D9/G2, optional OpenViking и совместимость ai_rules_1c прежние. **Gate 6, G4, рабочая миграция и публикация не начинались.**
