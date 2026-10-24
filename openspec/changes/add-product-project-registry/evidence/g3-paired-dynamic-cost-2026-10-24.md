# Парная стоимость динамических режимов G3, 2026-10-24

Выполнены **20 AB/BA пар на режим, 120 квалификационных samples** на текущем PM5. Измерительный пробел B5 для этой локальной области закрыт; **полная G3/registry AC-39 и приёмка всей стоимости остаются открытыми**. Добавочная задержка существенна. Это evidence, без изменений runtime. OpenCode SKIPPED по решению пользователя; Gate 6, G4, рабочая миграция и публикация не выполнялись.

## Результаты

Целая публичная CLI в новом Windows PowerShell 5.1, observer off. В таблице секунды; delta — медиана/nearest-rank p95 **20 разностей внутри пар**, не разность медиан. Все выбросы сохранены; точные значения и 60 пар — в [JSON](g3-paired-dynamic-cost-2026-10-24.json).

| Режим | Legacy median | Catalog median | Парная delta median | Парная delta p95 |
|---|---:|---:|---:|---:|
| publisher-only | 10.595329 | 15.901206 | 6.205673 | 8.407693 |
| endpoint | 8.819839 | 19.699951 | 10.543994 | 14.823044 |
| offline | 8.580273 | 12.646131 | 3.801003 | 5.700731 |

A bound / B штатный legacy unbound на одном физическом root, одном установленном package, той же базе и исходных endpoint settings; это feature baseline текущего пакета, не исторический pre-G3 build. Preparation/restore вне clocks; 1 unprofiled warmup на вариант и отдельная diagnostic call на вариант. Порядок нечётных блоков A→B, чётных B→A; пересечений calls нет. Основная мера включает legacy fetch внутри main ровно один раз. Детальный наблюдатель и Git TRACE2 в первичных samples выключены; его стоимость не вычиталась.

## Точный срез и работа вариантов

Root `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, PM5 КОРП `pm5-core-development` / `pm5-corp`; sibling branch unbound. Installed `dfae2ff3353cd0784867eb8eac5d115a2d3d741a`; source `2caf6caf0686570b763ff9788161ebe831f982d1`; ai_rules r43 `987320be139b4ac0d28f1f5b0f2515f63c7f140f`. Десять relevant runtime paths совпали до/после и source/installed; entrypoint/JSONC hashes проверены дополнительно после серий. Windows11 Home build26300, без elevation; это не Win10/Server/terminal proof. База `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`, 3295928320 bytes, без запуска1С.

Команда `sync-client-mcp -Client kilocode -AgentTarget kilocode` через существующий native capture helper, прежний timeout120с. Девять root inputs и весь private cache (bytes, mtime, directory set) восстановлены перед каждым call. Legacy подготовлен только на тестовом root удалением binding/operation trigger, остальные параметры сохранены; стандартный выбор remote Code/Graph задан обоим вариантам. Kilo+Cursor membership, local overrides, disabled aliases и pending prepared request сохранены.

- Publisher-only: diff JSON к seed — только `publishedAt`; оба клиента сохранили SHA+mtime. Обновление private `catalogRevision` разрешено существующим owner-контрактом; остальные preferences семантически неизменны.
- Endpoint: diff — только Graph URL. G3 обновляет **Kilo+Cursor** до main, legacy — только запрошенный Kilo. Это штатная разница объёма работы, не чистая стоимость идентичного writer. В Kilo меняются canonical Graph и принадлежащий workflow disabled legacy alias; alias остаётся disabled. Проверка штатным JSONC parser маскирует только owned value spans, подтверждает URL-only semantic change и точное сохранение всех остальных bytes/trivia. Общий/живой registry не менялся, loopback URL не опрашивался MCP-клиентом.
- Offline: один и тот же valid seed cache, remote `127.0.0.1:1` с connection-refused. G3 продолжает полную managed sync из applied с WARN; legacy выполняет свою ветку **preserved provider connections** с WARN/exit0, без полного remote sync. Поэтому delta включает continuity-поведение G3; это не сравнение одинаковой full-sync readiness. Provider files сохранены; допустимая identical-byte запись legacy client-managed receipt учтена отдельно. Это не cold start, зависший transport или удалённый SLA.

## Исправление подготовки, без фильтрации результата

Первые 80 online samples (`paired` publisher-only / `endpoint2` endpoint) **исследовательские, не включены в таблицу**: одновременно менялся путь private Git origin в env, входящий в invocationHash (`agent-1c.product-project-context.ps1`, Get-ItlProductProjectNoOpInputs). Они и исходный `analysis.json` сохранены. Это исключение другого workload целиком, не выбросов по времени.

Обе online серии повторены полностью (`fixed`) с неизменным origin URI/env и точным seed cache; только private `refs/heads/main` переключён вне clocks. Каждый bound sample подтвердил исходный invocationHash `bb2cefb29d64558b441683ca0e9d40348d02e539b8a4d9913208166b77e5d304`. Offline `offline2` этого лишнего фактора не имел, его исходные20 пар сохранены. Семантические diffs fixture commits отдельно проверены к тому же seed. Всего 230 public calls: 120 квалификационных +80 исследовательских индексированных samples; остальные — preparation, warmups, diagnostics и failed harness preflights.

Шесть failed harness preflights сохранены: два неверных требования неизменности private catalogRevision; два ошибочных требования single-string replacement для owned JSONC; один parser/DTO `.Contains` interop; один неверный full-sync marker для legacy offline. Каждый public helper exit0; исправлены проверки harness по существующему контракту, runtime/guards не изменены. Первичных квалификационных samples из-за assertion или времени не выбрасывали. Временные lease markers и immediate-reopen evidence сохранены; исправленный online прогон выполнен под отдельной fixture lease, затем она штатно освобождена. Между leases менялась только подготовка harness.

## Диагностика и расходы контекста

Это отдельные **одиночные инструментированные** наблюдения, не ещё один benchmark. Import→main у legacy не вызывается, его registry work находится внутри main: startupCalls catalog1 / legacy0, fetch1/PowerShell HTTP0 у каждого. Первоначальный post-analysis assert ошибочно требовал startup1 у unbound; он исправлен по штатному binding guard, первичные данные не менялись. Повторный nested fetch и memory probes не добавлены.

| Режим / вариант | Import→main, с | Whole CLI, с | fetch / HTTP |
|---|---:|---:|---:|
| endpoint / catalog | 17.618 | 23.304 | 1 / 0 |
| endpoint / legacy | не вызывается | 10.186 | 1 / 0 |
| publisher-only / catalog | 18.994 | 27.457 | 1 / 0 |
| publisher-only / legacy | не вызывается | 14.842 | 1 / 0 |
| offline / catalog | 6.876 | 16.274 | 1 / 0 |
| offline / legacy | не вызывается | 8.860 | 1 / 0 |

Путь новой revision содержит snapshot validation, resolve и preview; диагностические события указывают эти стадии, но не доказывают точную причинную долю каждой функции: breakpoints/TRACE2 влияют на время. Чистого attribution или runtime repair этот прогон не выполняет. Publisher-only client no-write не равен отсутствию обработки новой ревизии. Существенная paired delta требует отдельного owner-local разбора перед общей cost-приёмкой; новый SLA/барьер, второй cache/updater и исключения из целей не вводились.

- publisher-only: catalog [1562], legacy [1973] UTF-8 bytes; stderr0.
- endpoint: catalog [1630], legacy [1956] UTF-8 bytes; stderr0.
- offline: catalog [1189], legacy [1214] UTF-8 bytes; stderr0.

Это bytes вывода команды, не оплаченные tokens. Model turns0, реальные Code/Graph reads0; always-on rules, tool schemas и объём обязательного контекста не менялись. Прежний [warm unchanged benchmark](g3-cost-baseline-2026-10-24.md) и цели1000/2000мс сохранены отдельно; ни его узкий pass, ни эти динамические числа не являются SLA всего workflow.

## Сохранность и остаток

Final guard46/46: исходные SHA+mtime/absence совпали после снятия тестовой подготовки. Main/branch clean и HEAD прежние; база,21 historical artifacts,4 старых roots и11 capsule hashes сохранены. Четыре прежних manifest и2640 referenced files перепроверены. Capsule остаётся явным snapshot admission, не доказательством currentness отсутствующего live seed. Никакого рабочего enrollment/migration не было.

| Блок | Текущий остаток |
|---|---|
| B1 | Win10/Server2019+, terminal и независимые пользователи; стендов нет |
| B2 | Реальный изолированный installed PM4; стенда нет |
| B3 | Full fresh init/new branch/refresh/managed downgrade/оставшиеся first legacy choices; Gate6 исключён, missing live seed не заменён capsule currentness |
| B4 | Codex Desktop/model UI,8 других native clients/full platform-lifecycle; прежние Kilo/Cursor и Codex core/API pass сохранены; OpenCode SKIPPED |
| B5 | **Локальные dynamic paired measurements выполнены.** Добавочная задержка требует разбора; cold/stalled remote/platform/client область и вся cost-приёмка не закрыты |

Предвыпускное наполнение реестра AC-36–38 / memory AC-44 обязательно и этим не выполнено. Memory consumer/G4/G5 не реализовывались. Никакого runtime performance fix без отдельной постановки здесь нет; thresholds/assertions прежних gates не ослаблялись.

Raw root `C:\Users\xment\.codex\worktrees\product-project-registry-g3\1c-agent-workflow\build\test-results\g3\paired-modes-20261024`; [машинный результат](g3-paired-dynamic-cost-2026-10-24.json). Manifest `7cc2561cd9a1e3b6234c41259436a7f46f244a94d5ab40651fbc54eea80ce522`, 2952 files; поздние delivery/validation/registration records отдельно. Broad unchanged gates не запускались; штатный RegisterChange выполняет свой Targeted для документации. Регистрация не является публикацией или полной G3-приёмкой.
