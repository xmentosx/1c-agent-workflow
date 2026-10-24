# G3: publisher-only/offline cost repair, 2026-10-24

Два подтверждённых owner-local повтора исправлены; **101/0/0 unfiltered context/apply tests**, штатный update точного кандидата на текущем PM5 main+sibling и20 AB/BA пар на каждый динамический режим выполнены. Полная G3/registry AC-39 не принята: дополнительные20 warm no-op samples дали median **1049.731мс >1000мс**, p95 **1240.7921мс <2000мс**. Цель median не округлена и не ослаблена; повтор ради pass не выполнялся. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

## Причины и реализация

1. Новая revision с одним изменённым top-level `publishedAt` проходила повторный effective resolve и полный startup preview, хотя checked local inputs и настройки совпадали. TDD red завершился на обязательном повторном preview; green проверил adoption через прежний журнал, новый context/hash/revision, resume/restore точного beforeApplied и client SHA+mtime. Новый `Get-ItlProductProjectPublisherContext` разрешает сокращение **после полной валидации нового снимка**, только с совпадающими checkedNoOpInputs, валидными old/new Git object IDs, неизменными blobs catalog/product-relations и registry, равным прежнему после удаления только top-level `publishedAt`. Defer/explicit decision, missing proof, любые другие registry изменения (включая source version/endpoint) или catalog/relation/local input changes оставляют полный путь. Файловый CAS и proof выполняет существующий `Invoke-ItlProductProjectClientApply` с нулём client requests: тот же durable journal/private selection/marker-last/recovery, без нового writer/cache/barrier. Вызов writer оставлен **вне** catch свежести: race `CLIENT_MCP_PREVIEW_CHANGED` не превращается в успешный fallback.
2. Offline после уже проверенного cached snapshot выполнял effective resolve, затем `Set-ItlProductProjectAppliedContext` ещё раз декодировал тот же Git commit. Теперь применяется прежний validated applied context до повторного resolve; setter повторно использует уже validated snapshot **только при той же immutable revision**, иначе читает нужный old commit обычным путём. WARN, applied hash validation, pinned context и отсутствие client writes сохранены. Нативный Git TRACE2 подтверждает **show6→3**, rev-parse6→4, fetch1→1; то есть реально устранены три чтения blobs, не только profiler events.

Read-only module-stage наблюдение на старом package: snapshot≈811мс, preview≈998мс; без fetch/процессного bootstrap и полного public workload. Это не доли общей CLI и не acceptance benchmark. Фактическое сокращение пути дополнительно доказывают owner tests и native traces.

## Почему main preview сохранён

После сокращения publisher startup main остаётся единственным актуальным производителем UI/on-demand surface plans. `Write-ItlOnDemandMcpClientConfig` проверяет наличие executable; `Sync-ItlUiToolsMcp` — текущую готовность UI tools. Эти внешние inputs не полностью описаны прежним noOpInputs. Поэтому гипотеза «пропустить main целиком по старому receipt» отклонена: такой bypass мог бы пропустить изменения готовности. Runtime main не менялся, новый cache/request-hash/protocol не введён. Неисполненные writer-reuse test и каталог `final/` сохранены как исследовательский прототип; из них ни update, ни lease, ни замеры не запускались. Прежние проверки не ослаблялись.

## Новый сопоставимый замер

Тот же физический PM5 root `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, `pm5-core-development` / `pm5-corp`, Kilo+Cursor; sibling unbound. Exact implementation/installed package `78f11bd861543dfea89eab722d4f5b869dd64c25`, ai_rules r43 `987320be139b4ac0d28f1f5b0f2515f63c7f140f`. Main+sibling прошли обычный fixture updater, оба clean; managed-copy update изменил package pins/HEAD штатно. После него отдельный baseline46 paths фиксирует исходное состояние новой серии. Final source commit дополняет только документы; runtime blobs сверены отдельно.

Команда `sync-client-mcp -Client kilocode -AgentTarget kilocode`; A bound / B current-package legacy unbound, не исторический pre-G3 build. На режим20 пар, порядок нечётных A→B/чётных B→A; fresh WinPS5, observer off, original timeout120с. Все120 primary samples и выбросы сохранены; primary Git TRACE2/breakpoints выключены. По одному отдельному diagnostic и warmup на вариант/режим; preparation/cache restore вне clocks. Все9 root inputs и весь private cache (bytes/mtime/directories) восстанавливаются до call. Private origin URI/env постоянны от подготовки до измерений; online bound invocationHash совпал с seed. Проверены точные семантические diff двух безвредных fixture commits. Изоляция registry/cache локальная, живые Code/Graph endpoints не опрашивались.

Здесь секунды; delta median/p95 посчитаны **внутри20 пар**, p95 nearest-rank19/20; это не разность медиан. CPU — дополнительная парная мера только PowerShell process во время public call, **без native Git/других child CPU**; она не вычитается из wall и не заменяет её.

| Режим | Legacy median | Catalog median | Paired delta median | Paired delta p95 | Paired PS CPU delta median |
|---|---:|---:|---:|---:|---:|
| publisher-only | 4.047332 | 5.220286 | 1.170395 | 1.476211 | 1.179688 |
| endpoint | 4.217233 | 8.218040 | 4.002259 | 4.567227 | 4.039062 |
| offline | 5.685122 | 7.293916 | 1.494380 | 2.941826 | 1.625000 |

Объём работы сохранён: endpoint G3 обновляет Kilo+Cursor против только requested Kilo в legacy; canonical Graph/owned disabled alias меняют только URL, disabled остаётся disabled, остальные bytes/trivia проверены штатным JSONC parser. Offline — valid seed cache + connection-refused loopback: legacy WARN сохраняет provider connections без полного sync, G3 завершает managed sync из applied. Поэтому это цена соответствующих ветвей одной команды, не одинаковой full-sync работы. Publisher-only/offline сохраняют client bytes+mtime. Каждый separate diagnostic имеет fetch1/HTTP0; нового probe/fetch/LLM/memory consumer нет. Всего154 sync calls (120 primary, preparation/diagnostics/warmups и20 full-observer no-op), одна отдельная штатная установка и8 module-only child controls; native calls не фильтровались по результату/длительности.

## Историческое сравнение и нагрузка

| Режим | Прежняя paired delta median, с | Новая, с |
|---|---:|---:|
| publisher-only | 6.206 | 1.170 |
| endpoint | 10.544 | 4.002 |
| offline | 3.801 | 1.494 |

Это последовательные наблюдения, **не причинная оценка процента ускорения**. Время legacy тоже изменилось существенно (publisher10.595→4.047с). Общий ПК не изолирован: прежние sealed status records содержат параллельные Targeted, новые host-queue-before/after — чужой running PublishDevelop/Develop и другие Targeted. В этой задаче они не запускались/не останавливались. Новый within-pair PS CPU delta publisher≈1.180с показывает оставшуюся процессорную работу текущего пути, но не измеряет CPU всех Git children/всего ПК. Code-only эффект подтверждён устранёнными стадиями/тестами; wall before/after не выдан за чистый эффект кода или SLA.

## Warm no-op: цель median снова открыта

Отдельные20 fresh-process **full-observer** samples, прежнее полное окно Import→main: median1049.731/p951240.7921мс, min813.0698/max1473.1295мс. Все20×9 SHA+mtime guards прошли. Цели1000/2000мс прежние; median превышена на **49.731мс**, p95 выполнена. Эти20 samples не смешаны со120 observer-off dynamic timings; profiler cost не вычиталась. Новый результат не заменён старым borderline pass995.59115мс и не перезапускался ради зелёного числа.

8 AB/BA controls в свежих WinPS сравнили только dot-source старого/нового context file: old median13.435950, new13.820650, paired delta median0.559900мс. Это не полный Startup и не SLA. Контроль не подтверждает, что размер новых function definitions объясняет полные49.731мс; точная причина median всего окна не локализована. **G3-PM5-WARM-STARTUP-MEDIAN открыт**; требуется сопоставимый контроль полного окна/его стадий на контролируемой нагрузке, без отмены guards/целей и без повтора неизменного batch ради pass. Это диагностическая цель приёмки, не новый runtime barrier.

## Вывод/контекст и сохранность

| Режим | Catalog stdout UTF-8 bytes | Legacy stdout UTF-8 bytes |
|---|---:|---:|
| publisher-only | 1129 | 2009 |
| endpoint | 1630 | 1983 |
| offline | 1189 | 1232 |

Stderr0 у измеренных sync calls. Publisher catalog1129 bytes против прежних1562 (меньше433); actual billed tokens не оценивались. Model turns0, live MCP tools0; always-on rules/tool schemas/обязательный агентский контекст не увеличивались. Transient checkedNoOpInputs не вводит новый persistent store или memory backend.

Final guard46/46 SHA+mtime/absence совпал с post-update baseline; database `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`, 3295928320 bytes, unchanged. Main/sibling clean на новом package; tracked descriptors/membership и custom settings сохранены. Проверены21 historical files/4 old roots/11 capsule hashes, пять прежних manifests и5592 referenced files. Capsule остаётся explicit snapshot admission, не доказательством currentness отсутствующего live seed. Fixture lease освобождена. Все прежние failure/raw records сохранены. Один post-analysis verifier неверно ожидал старую fixture publishedAt string; ожидание исправлено на объявленную новую, primary data не менялись.

## Остаток G3

B1 Win10/Server2019+/terminal/independent users, B2 real isolated PM4, B3 оставшиеся fresh init/branch/refresh/downgrade/legacy paths и B4 native/platform matrix остаются по [общей матрице](g3-remaining-qualification-2026-10-24.md). OpenCode SKIPPED. B5: current dynamic pairs выполнены и две причины исправлены; warm median finding открыт, cold/stalled remote/другие platform/client области не приняты. Endpoint≈4с включает полноценный multi-client plan/journal/recovery; новых дефектов этого пути данный batch не локализовал. Полная G3/AC-39 не объявлена PASS. Предвыпускное population AC-36–38 / memory AC-44 обязательно и отдельно; G4 consumer/G5 не реализованы. Gate6, рабочая миграция, source/shared-registry publication не выполнялись.

[JSON результата](g3-publisher-cost-repair-2026-10-24.json). Raw `C:\Users\xment\.codex\worktrees\product-project-registry-g3\1c-agent-workflow\build\test-results\g3\publisher-cost-repair-20261024`; manifest `fab1cf123fc566cd8a4fb5ce9626cd970fd2fa2a69f5cbb73335f015b8b80f0b`, 2535 files. Поздние OpenSpec validation/registration records отдельно в delivery. Штатный RegisterChange владеет единственным Targeted; регистрация не является публикацией, исправлением warm goal или полной G3-приёмкой.
