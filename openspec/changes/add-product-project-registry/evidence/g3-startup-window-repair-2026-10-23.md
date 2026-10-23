# G3: причина стоимости Startup и повтор на PM5, 2026-10-23

**G3-PM5-STARTUP-WINDOW-COST: закрыт в проверенном current PM5 subset.** Missing `Get-Command` Function lookup выполнял PATH/module discovery; existing lazy importer теперь проверяет только видимые функции через Function provider. 18 fresh-process calibration calls отделяют presence lookup от загрузки файлов и debugger mode; это не замена public Startup. 123/0/0 unfiltered owner tests; original 20 full-profiler/on-off пар плюс 20 boundary-only наблюдений на том же PM5 root после штатного isolated update. Full window median/p95 **0.932/1.238 s**, boundary-only 0.998/1.310 s; до Initialize 0.038/0.045 s. Цель 1/2 s выполнена на полном окне с прежним profiler. Ничего не вычтено из измерений; thresholds прежние. 60 no-op SHA+mtime guards и publisher-only/change/offline → original command passed. Точный legacy/no-registry feature delta и actual tokens/billing не измерены; full G3/AC-39, race/terminal/прочие installed/client/platform критерии и population открыты. Gate6/G4/рабочая миграция/публикация не выполнялись.

[JSON, полные samples и SHA raw evidence](g3-startup-window-repair-2026-10-23.json). Предыдущие [20 пар и concurrency](g3-pm5-concurrency-startup-2026-10-23.md) сохранены; их failed cost не переименован в pass.

## Причина и ограниченное исправление

`Import-ItlProductProject` проверял четыре ещё не загруженные функции через `Get-Command -CommandType Function`. Native `CommandDiscovery` trace показывает поиск отсутствующего имени по PATH и последующий non-module-qualified search. Отдельный пилот с `-ListImported` также не устранял задержку; он не используется как исправление/приёмка. Владельцу нужны только собственные dot-sourced функции, поэтому пять presence checks (включая UI loader) переведены на `Test-Path -LiteralPath Function:\…`. Lazy load, видимость родительской scope, idempotence и отложенная загрузка UI сохранены. Нет нового cache/state/lock/manager, runtime observer или барьера. Source base `6346ba79…`, установленный implementation **`44ce6ebad18b635c582ca26e96d6e9d4ce96c081`**, loader SHA **`68f01db2beee1941ab58a57d366d861b9fc47c3d47b6e1d726f0f53befe95b3a`**; штатный updater применил его к main и sibling. Финальный source commit дополняет только документы; runtime/test blobs проверяются отдельно.

Calibration: три свежих WinPS5 процесса для каждой пары original/provider × none/boundary/full debugger registrations, итого 18. Те же installed файлы, PATH и окружение; фазы lookup/load измеряются в module-only harness, без запуска lifecycle/1С. Breakpoints зарегистрированы, но здесь нет совпадающих callback hits; стоимость настоящих callback отдельно сопоставлена ниже. Это не public Startup и не legacy feature baseline.

| Guard / observer | Total median, ms | Presence guards median, ms | Dot-source median, ms |
|---|---:|---:|---:|
| original / none | 893.7 | 854.1 | 72.4 |
| original / boundary | 887.7 | 846.8 | 36.1 |
| original / full | 892.8 | 842.4 | 44.9 |
| provider / none | 75.4 | 3.0 | 67.8 |
| provider / boundary | 71.5 | 3.2 | 63.9 |
| provider / full | 81.3 | 3.2 | 73.6 |

Задержка воспроизводится без debugger: original ~0.89 s против provider ~0.075 s. Собственно загрузка файлов занимает десятки ms. Медианы отдельных фаз не суммируются в медиану полного окна. Прежнее превышение нельзя списать на инструментирование; основной подтверждённый вклад здесь — поиск отсутствующей функции.

## Исходное окно и инструментирование

Тот же main `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, sibling `branch`, `pm5-core-development`/PM5 КОРП, физические Kilo+Cursor. Host: WinPS5 / Windows11, обычный пользователь, shared CPU. Source candidate установлен штатным fixture updater; paths/topology/DB/команда прежние. Новый private origin `--no-hardlinks`, author/cache/home не меняют прежние origins. Первоначальный [пакет909d1e…](g3-pm5-concurrency-startup-2026-10-23.md) сравнивается исторически на том же root/в тот же день; это не alternating source-version A/B.

Одна серия: prime, 20 чередующихся original full-profiler/on-off пар; к каждой паре добавлен boundary-only вызов (три прежние timing breakpoints, без Git/HTTP counters), его положение чередуется. Во всех 60 no-op SHA **и actual mtime** девяти protected paths неизменны. Full boundary — первый Import → Sync main, включая lazy import/disposition/initialize/pre-main config read. Source functions в public процессе не подменяются. После остановки часов observer читает context/client files; эти чтения входят в whole CLI, но не измеренное окно.

| Метрика | Median / p95, s |
|---|---:|
| Прежнее полное окно (исторические 20 samples) | 2.045 / 2.570 |
| Новое полное окно, прежний profiler | **0.932/1.238** |
| Initialize → main, full profiler | 0.896/1.200 |
| До Initialize, full profiler | 0.038/0.045 |
| То же полное окно, boundary-only observer | 0.998/1.310 |
| Whole CLI, full profiler | 4.764/5.583 |
| Whole CLI, boundary-only | 4.750/5.679 |
| Whole CLI, observer off | 4.691/5.171 |
| Попарно full − boundary, измеренное окно | -0.010/0.312 |
| Попарно whole CLI full − off | 0.155/1.231 |

Цель 1/2 s выполнена на полном окне с прежним profiler. p95 nearest-rank, все 20 samples каждого режима в raw. Boundary observer также не бесплатен; paired differences содержат host/process noise. Никакая предполагаемая стоимость debugger не вычитается. У каждого full-profiler no-op один owner fetch/initialize и ноль PowerShell HTTP calls; это не исчерпывающий network/process trace. CPU/peak RSS PowerShell закреплены отдельно от неизмеренных native Git children.

## Повтор дополнительных сценариев и сохранность

| Сценарий (один sample) | Startup / whole CLI, s | Изменённых client files |
|---|---:|---:|
| startup-publisher-only | 4.467 / 6.782 | 0 |
| startup-changed | 6.513 / 9.217 | 2 |
| startup-offline | 3.479 / 7.009 | 0 |

Publisher-only/offline не переписывают клиентские SHA/mtime; выбранный Graph change достигает обоих client files до main. Offline — immediate refusal + WARN, прежний validated applied SHA, exit0; stalled transport/deadline/cleanup отдельно не квалифицирован. После штатного возврата desired endpoint/metadata final original command и on-demand context exit0. Итого **66 public calls**, отдельный candidate update и 18 module-only calibration calls. Реальные MCP tool reads, LLM turns, Cognee и 1С не запускались.

Оба client JSON целиком byte-equal исходным post-update; foreign bytes/семантика сохранены. Post-update HEAD/descriptor/locks не менялись во время batch; update до серии закономерно изменил workflow pins/HEAD. ai_rules_1c `987320be…`, descriptors и DB прежние: DB SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`, 3,295,928,320 bytes. 21 protected files/4 old roots/7 Gate6 artifacts/11 capsule hashes и **1151** уникальных prior raw files проверены; historical failures и missing original raw seed не переписаны. Normal/prior catalogs сохранены. Compact on-demand context 2157 UTF8 bytes, ≈540 tokens только по bytes/4; actual tokens/billing неизвестны. Новых always-on instructions/tool schemas **0 bytes**; измерительный harness не поставляется в runtime.

Регрессия проверяет отсутствие command discovery, cold load и повторный import/ScriptBlock identity: red 1/1 на старом коде, green 1/1; unfiltered setup/context/apply **123 passed, 0 failed/skipped**. Обе OpenSpec strict validate CLI1.13.1; RegisterChange/Targeted имеет отдельный ledger. Полные task5.5/AC-25/39 остаются открытыми для feature baseline/полной матрицы; этот результат не открывает G4 или публикацию. Memory сохраняет единственного registry context owner, шесть областей/canonical home/grants/optional OpenViking/ai_rules_1c; consumer4.2/G4/AC-43/G5/44 не реализованы и не приняты.
