# G3: owned MCP re-enable и сохранение defer, 2026-10-22

**Два названных блокера закрыты в исходном installed PM5 subset; full G3 / AC-39 открыт.** Канонические результаты, 41 captured public CLI result и SHA 273 raw files — [JSON evidence](g3-owned-mcp-defer-repair-2026-10-22.json). Исходные [failed scenarios](g3-pm5-multiclient-offline-2026-10-22.md) и их assertions сохранены.

## Причины и owner-local исправления

1. **G3-CATALOG-OWNED-MCP-REENABLE.** Existing `Write-ItlClientMcpEndpointSet` сравнивал `lastWritten` с текущим отсутствием ключа, даже когда предыдущая штатная запись уже сняла владение им. Historical baseline ошибочно превращался в пользовательский override; план терял endpoint до классификации addition. Теперь отсутствующий **и больше не принадлежащий владельцу** ключ допускается к обычному добавлению. Физически существующий ключ и ручное удаление всё ещё принадлежащего владельцу ключа сохраняют прежнюю защиту. Collision/preflight/proof/accepted-owned guards не ослаблены; baselines/receipts не удаляются и не мигрируются.
2. **G3-DEFER-MCP-WRITER-PREFERENCE-LOSS.** Startup правильно выбирал applied context, но последующий catalog-aware writer вызывал общий resolver без нового решения, а resolver удалял saved defer. Теперь повторное использование той же закреплённой applied revision без явного решения сохраняет исходный defer. Explicit registry/keep-local/defer и другой desired context проходят прежний resolution path. Исправление находится в существующем decision owner; второго updater/cache/state или early-return обхода проверок в writer нет.

Изменены только runtime leaves `agent-1c.client-adapters.ps1` и `agent-1c.product-project-context.ps1`, два existing owner test files и OpenSpec. Dispatcher, controlled fork, Code/Graph servers, настройки прав/сеть/службы не менялись. Новых runtime I/O, probes, schema, locks, durable records и always-on instructions нет.

## Source и установка на прежний стенд

База source `72d335642caf59e9e825d842c68802c9a08c335e`, implementation commit **`d8eacc4ef8d0dae73063b72a025f48cca3c2ac93`**. Финальный source-коммит дополняет эту реализацию документацией; JSON хранит SHA двух runtime-файлов, проверенные на source и установленном main. Установленные main/sibling перешли с `d109a95d…` на этот implementation commit; ai_rules_1c r43 / `987320be139b4ac0d28f1f5b0f2515f63c7f140f` прежний.

Root **тот же**: `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, sibling `branch` в том же parent. Старое имя каталога не означает старый runtime. Kilo → Cursor, прежние client paths, private records, foreign entries и история сохранены. Существующая tracked binding закреплена только в disposable fixture commit `dce7d423…` без изменения её bytes: штатный update требует clean tracked stand. Отдельный test origin/author продолжает прежний private catalog; старые catalog/failed evidence не переписывались. Production registry не публиковался.

Первый normal `update-workflow` сохранил snapshot `647dc78ad13e4589bea409101a8b00fe` и завершился ошибкой: новый startup восстановил подключения в `.kilo/kilo.json` до post-copy consistency check. Этот первый проход **не принят как green**. Source-side `-Recovery status` сохранил report с `changedPathCount=0`; reconcile/decision file и ручное редактирование receipt не потребовались. Повтор **той же exact-source команды** штатно завершил post-copy/main/eligible sibling, exit 0, **314.822 s**. Snapshot, fresh-child status, before/current и журналы обоих попыток сохранены. Это успешное owner continuation, не доказательство всех first-pass upgrade scenarios и не исправление lifecycle guard.

## Проверки

| Сценарий | Фактический результат |
|---|---|
| Existing owner regressions | Полные `MultiClientMcpOwnership` + `ProductProjectApply`: **98 passed / 0 failed / 0 skipped**, wall **106.678 s**. Включены 12 форматов re-add, manual deletion, aliases, disabled/auth/foreign policy, shared ownership, races, JSONC, physical receipt gaps и pinned recovery |
| Новые causal tests | 14/0/0 focused после воспроизведения дефектов; defer включает два ordinary calls и последующее explicit registry acceptance. Начальные harness errors с positional parameters, shallow PSObject, newline и Qwen/Codex native field assertions исправлены отдельно; raw red/partial-green attempts сохранены, runtime assertions не ослаблены |
| Исходный late select | Public `restore-compatible` вернул unbound root с **обоими** clients и прежним Kilo owner `[]`/historical lastWritten четырёх names. Последующий public select создал Code/Graph физически в Kilo и Cursor; Kilo primary enabled и imported aliases disabled, unrelated entries прежние |
| Исходное предложенное continuation | `vibecoding1c-mcp-write-client-config -Client kilocode` → catalog sync/registry: exit 0, реальные endpoints остаются на месте; ручного ремонта configs/receipts нет |
| Original Graph own→disabled→own | Три исходных conflict iterations с теми же actors/actions/roots. Explicit registry remove и re-enable проходят; actual Graph восстанавливается, unrelated entries сохраняются |
| No answer / keep-local / registry | Все три unattended conflicts: needs-user-action, семь SHA+actual mtime прежние. Keep-local и registry сохраняют foreign entries; обычный repeat exit 0 без повторного вопроса/записи |
| Original defer → ordinary writer | Ручной Graph, прежняя revision и defer сохранены; семь protected paths неизменны по SHA и mtime. Дополнительный отдельный original Graph/defer replay с **двумя последовательными public ordinary commands** также passed; explicit registry затем снимает defer и применяет новое решение |
| Настоящий multi-client partial | Desired Graph URL изменён в private registry. Kilo **физически записал** новый URL и дал receipt; настоящий read-sharing lock Cursor запретил atomic replace. Exit 1, operation partial/activeWrite=cursor, applied marker прежний; no-op A не использовался |
| Чужая owned-правка после A | Тестовый actor изменил только Cursor Graph URL. Main blocked, status доступен. Resume и restore отказывают recovery/client conflict, сохраняют чужие bytes и marker |
| Pinned resume / owned restore | После явного отменённого actor’ом собственного URL edit resume завершил **тот же operation ID и SHA**, хотя private tip продвинут. Оба actual Graph получили pinned URL. Последующий restore вернул обе прежние настройки и сохранил добавленный unrelated server |
| Warm ordinary no-op | 10 native commands, семь файлов SHA+mtime stable; whole CLI median **4.0405 s**, p95 **4.283 s** |
| Offline repeat | Bound valid applied: один реальный stalled fetch, warning, main exit 0, восемь protected files stable. Unbound/no-cache sibling: один clone, `CATALOG_REFRESH_UNAVAILABLE`, exit 1 без записи/guessed association; восемь paths stable |

Partial operation ID `c607370e563f447db1cdc8b5cd42db9a`, pinned revision `a825e58f4e000d40e6b2d90c4f0b432d81bdf86f`; более новый tip приведён полностью в JSON. Fault устранялся закрытием собственного read handle. Чужая owned-правка отменена **только обратной заменой собственного URL**, с exact comparison исходного Cursor text; полный файл/ownership/operation не перезаписывались из backup для получения green. Unrelated later edit сохранился через настоящее owner restore.

Offline transport→первый fallback Git read **10.024505/10.011880 s**, whole native capture **24.900/24.983 s**; поздние transport child exits и исходный 25 s listener отражены отдельно. Прежний metadata deadline 10 s не расширялся. Continuation/preservation passed не означает CLI≤10 s, strict child cleanup или изолированную Startup latency. Warm значения сопоставимы по порядку с предыдущими whole-CLI observations, но не являются парным измерением прежнего single-client состояния. Полная cost/cleanup приёмка остаётся открытой.

Новых always-on instructions/tool schemas — **0 bytes**; дополнительно не вызываются provider/Code/Graph/Cognee probes. Client LLM canary turns **0**, native Code/Graph tool calls **0**, Cognee calls **0**. Это physical client-config qualification, не UI reload/discovery/tools readiness или измерение agent tokens/billing. Existing controlled-fork/runtime version и требования ai_rules_1c сохраняются.

## Сохранность и остаток

PM5 DB SHA **`c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`**, 3,295,928,320 bytes, прежний. Business/scenario trees не менялись. 21 protected file и четыре старых roots сохранили SHA/HEAD/dirty state, включая failed copy и семь Gate 6 artifacts. Sealed capsule `c2c570fe…` и все 11 hashes проверены; отсутствующий raw seed не подменён утверждением о live currentness. Нынешний stand/его private catalog и все failed attempts сохранены; memory off, подготовленный custom draft не опубликован.

Полные G3/AC-39, другие first-pass/fresh init/branch/refresh/downgrade/live-source/PM4/platform/terminal/frontend сценарии, installed interactive cancel/corrupt-cache/invalid-applied и paired Startup/token/cost/cleanup остаются открытыми. Обязательное release population **AC-36–38/5.7** сохраняется. Memory потребляет только эти registry dependency results: **4.2/G4/AC-43/G5/44 не выполнены**. Шесть областей/home/grants/Q1–Q7/D9/G2/optional OpenViking прежние.

**Gate 6, G4, рабочая миграция и публикация из этой задачи не выполнялись.** Source delivery — один локальный coherent commit и `RegisterChange`/Targeted, итог проверяется через общий Status; регистрация не равна публикации.
