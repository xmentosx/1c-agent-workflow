# Startup и квитанции G3: исправление и повтор, 2026-10-20

**Причины исправлены; source и исходный synthetic native subset passed. Полный G3/AC-39 открыт.** [JSON proof](g3-startup-repair-2026-10-20.json) связывает шесть runtime/test inputs с Git blob ID и SHA-256, 187 raw references, исходные failures и все повторные наблюдения. Source base — `4faae104a8242f92fa69a112721c7038d41e357e`; квалифицированные изменения идентифицируются содержимым, а не одним прежним HEAD dirty worktree. Итоговая [матрица G3](g3-final-qualification-2026-10-20.md) остаётся единственным списком остатка; source-delivery ledger владеет регистрацией/Targeted.

## Причины и изменение у прежнего владельца

1. Startup сначала полностью читал/валидировал три Git JSON и разрешал контекст, затем проверял существующий no-op fingerprint. Проверка перенесена перед blob reads: успешный прежний refresh, тот же неизменяемый SHA и неизменные inputs допускают reuse уже проверенной root-bound applied projection. В fingerprint добавлены две используемые схемы. Изменённый/нечитаемый вход, иной SHA, явное решение, несовместимая привязка/семейство возвращают прежний полный путь. Нового постоянного кэша, процесса, блокировки или runtime FAIL нет. Вложенное полное чтение сохраняет зафиксированный SHA без второго refresh.
2. Полный reader запускал семь Git-команд: pin, три определения blob ID, три чтения. Три фиксированных object names разрешаются вместе: **пять команд**, все по прежнему pinned commit. Валидация схем/связей и точная диагностика отсутствующего файла сохранены. Native regression сохраняет whitespace/non-ASCII path и blob identities.
3. Первый sync `-Client codex` сравнивал hash списка из одного клиента с project-wide hash 12 клиентов. Физические настройки совпадали, но создавались новые applied/operation receipts. Общая stateless проверка no-op теперь учитывает resolved context, overrides, preferences и proof каждого запрошенного client/owner. Совпадающий subset сохраняет полную квитанцию и proofs остальных клиентов. Новый клиент или ручная правка продолжают обычный preview/apply. Изменение действительного входа может обновить fingerprint; это отличается от повторного unchanged sync.

Исторические median 1.771/1.644 s не объявляются исключительно ошибкой source: окно 16:30–16:34 UTC перекрывалось с двумя другими Targeted runs. Прямые интервалы сохранены; величина влияния нагрузки не измерена. После одного batching промежуточный PM5 median **1.016 s** оставался over-target; он также сохранён. Это послужило основанием переноса проверки раньше, без ослабления целей.

## Повторные проверки

PS 5.1.26100.9711, Windows 11, обычный пользователь без elevation. Четыре owner suites Registry/Setup/Context/Apply: **133 passed, 0 failed/skipped/not-run, 124.347 s**. Новые regression проверяют пять Git calls, неизменные обе квитанции при первом subset sync, новый клиент/ручную правку, ранний reuse, changed schema, lazy pinned read после продвижения HEAD и полный разбор в следующей операции. Первоначальные red source cases и failures тестовых обёрток не удалены; overlapping batches не суммируются в число уникальных тестов.

Парный контроль сохраняет точно те же root, cache, author и catalog SHA; по 20 warm samples каждой версии. Pester batches во время финальных замеров не запускались этой задачей; host остаётся общим.

| Family | До: median / p95, s | После: median / p95, s | Результат |
|---|---:|---:|---|
| PM4 | 0.711 / 0.808 | 0.664 / 0.985 | Цели median ≤1 / p95 ≤2 соблюдены |
| PM5 | 0.665 / 0.786 | 0.646 / 1.057 | Те же цели соблюдены |

Median уменьшилась умеренно, p95 в этом повторе выше baseline. Ни величина постоянного ускорения, ни устранение всей вариативности общей машины не заявляются. Убраны конкретные лишние процессы/декодирование; unchanged profile подтвердил reuse checked projection. Protected hashes прежние, ровно один fetch/top-level и ни одного дополнительного nested fetch.

Исходная полная synthetic матрица отдельно повторена на свежих roots с тем же workload/топологией: 20 unchanged + publisher-only/change/offline на family, 12 adapters, Unicode и custom entries. PM4 warm median/p95 **0.646/1.040 s**, PM5 **0.710/0.992 s**. Publisher-only/change/offline: PM4 **3.016/7.393/3.273 s**, PM5 **3.600/7.688/3.286 s**. No-op/publisher/offline не записывают client files; реальная смена endpoint меняет 11 физических файлов 12 adapters. Эти три сценария не сравниваются с целью unchanged; это hook, не вся 1С-команда.

| Native control | Результат и предел |
|---|---|
| Первый unchanged CLI, stalled origin | exit 0, actual main phase + offline WARN, один fetch, protected hashes неизменны. Fetch → первый pinned read **9.979 s**, whole CLI **24.645 s**; deadline 10 s относится к metadata refresh, не whole command |
| Две одновременные команды одного root | Обе exit 0/main reached; вторая ожидает existing lifecycle lock; отдельный status exit 0 за **2.774 s**. Один fetch/вызов, hashes прежние; independent terminal users этим не проверены |
| Квитанции | applied и operation сохранили bytes; их LastWriteTimeUtc после cold/concurrent всё ещё раньше CLI preparation. Это проверяет также отсутствие rewrite с теми же bytes |
| Client formats | **48/48** parsed file/role controls passed; actual tools/reload не проверялись |
| Сохранность | **13 files, 4 old roots, 68 capsule raw refs, 2 restored PM5 roots** подтверждены; семь Gate 6 artifacts сохранены. Source local Git settings прежние. Original raw seed всё ещё отсутствует; новая currentness/DB qualification не заявляется |

Начальный private Git fixture наткнулся на Windows long paths; исправлен только его local `core.longpaths` после проверки exact Git root. Путь, workload и assertions не сокращены, source/global Git config не менялись. Первый новый pinned-reuse test wrapper не передал обязательные параметры reader; исправлена обёртка, исходный 132/1 result сохранён, тот же полный batch повторён. Ранние batching/encoding/instrumentation failures перечислены в JSON, их не выдают за успешный продуктовый proof.

Always-on rules, tool schemas и LLM/Cognee calls: прирост **0**. Изменение относится к существующим on-demand helpers и ignored input hashes; новый memory updater, второй каталог/журнал приёмки или managed migration не добавлены. Controlled fork/ai_rules_1c не менялся; шесть областей, canonical home и optional OpenViking прежние.

## Оставшаяся граница

Закрыты именно owner-local причины лишней работы и first-CLI no-write control в этой области. Полный installed paired cost/context proof, selected source binding/namespace/version, actual client tools/reload, остальные init/branch/recovery/downgrade journeys, PM4/Win10/Server/terminal stands, raw-seed currentness, component availability и обязательное release population остаются открытыми. Registry AC-39 и memory AC-43/G5/AC-44 не закрываются. Gate 6 не исправлялся и не запускался; G4, миграция рабочих проектов, публикация workflow/каталога/компонента не выполнялись.
