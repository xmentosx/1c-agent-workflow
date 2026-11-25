# G3: сопоставимый baseline и стоимость Startup, 2026-10-24

**Проверка стоимости завершена. G3-B5 закрыт для сопоставимого warm no-op PM5 subset; полная G3/AC-39 остаётся BLOCKED по остальным клеткам.** Прежние цели median ≤1000 мс / p95 ≤2000 мс сохранены; engineering цель полного Startup **выполнена**. [Канонический JSON](g3-cost-baseline-2026-10-24.json) содержит все samples, идентичность, фазы и SHA raw evidence. Это актуализация стоимости [итоговой матрицы](g3-completion-2026-10-23.md), не повтор остальных G3 критериев.

## Сопоставимый baseline

Один и тот же физический `project` и неизменяемая файловая PM5 база sibling `branch` под `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed`. Installed **`dfae2ff3`**, source **`0f97af70`**, WinPS 5.1.26100.9711, Windows build 26300; ai_rules_1c `987320be`. Runtime hashes source/installed сверены; пакет не обновлялся. Command: настоящий установленный `sync-client-mcp -Client kilocode -AgentTarget kilocode`, fresh Windows PowerShell process. Запуска 1С нет. DB SHA **`c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`**/размер 3295928320 до/после совпали.

* A: обычный привязанный `pm5-core-development` / `pm5-corp`, прежние applied/operation receipts и реальный registry refresh.
* B: штатный legacy unbound путь **того же пакета**, без tracked `productProject` и trigger-файла operation. Нулевые imports/initialize подтверждены observer. На обеих сторонах одинаковый явный private selection Code/Graph `dev-ermakov`/`pm5corp`; MCP endpoints, client files, ownership bytes, runtime, cache/origin, команда и физические пути одинаковы. Catalog/applied data не подменены mock.
* Подготовка/переключение вариантов выполнялись вне часов, под existing exclusive fixture lease. После каждой серии восстановлены точные исходные bytes/mtime всех 9 protected paths; HEAD/lock/branch и старые seed/failed/capsule/Gate6 artifacts сохранены. Это тестовая вариация, не миграция рабочих установок.

B — feature baseline «каталог выключен обычной конфигурацией», **не историческая до-G3 версия workflow**. Остальные обновления workflow исключены из A/B различия; сравнение старых разных пакетов этим не заявляется. Сохранённый applied без binding не используется legacy route. Нового production bypass/флага/кэша/worker нет.

Legacy writer (`agent-1c.client-adapters.ps1`, существующий `Write-ItlClientMcpEndpoints`) безусловно пересохраняет client-managed receipt с теми же bytes. Подтверждены SHA equality и изменение только mtime; это включено в legacy CLI duration. На A строгие SHA+mtime assertions всех 9 paths сохранены. На B проверены все SHA и остальные mtime; legacy owner mtime записан отдельно, не объявлен no-write. Подготовительные неудачи измерителя сохранены: отсутствие `$PSDebugContext`, null legacy context и неверное первоначальное предположение о неизменном legacy mtime. Product calls не объявлены failed из-за harness; эти попытки не входят в timing sample.

## Метод и результаты

Фиксированный заранее в `run.ps1` inventory: 2 warmup/variant, затем **20 AB/BA блоков**, внутри full/off и off/full; отдельный catalog boundary control каждого блока. **100 retained samples + 4 warmups**, exit0, instrumentation errors0. Оригинальные endpoints и guards подтверждены; все выбросы сохранены. p95 — nearest-rank 19-й из20. Whole CLI timer включает запуск дочернего процесса и полный public action; Startup clock останавливается до сбора evidence. Подробные phase probes выполнялись **отдельно после серии**.

| Метрика | Median / p95, с |
|---|---|
| A, прежнее полное окно: первый Import → Sync entry | **0.995591 / 1.168819** |
| A, независимый boundary observer, без счётчиков Git/HTTP | 0.993772 / 1.269987 |
| A, общий anchor перед веткой startup → Sync entry | 1.003582 / 1.176895 |
| B, тот же общий anchor → Sync entry | 0.024902 / 0.028004 |
| A, whole CLI, **без** профилировщика | 5.164985 / 6.142299 |
| B, whole CLI, **без** профилировщика | 4.567816 / 5.065733 |
| Парная разность A−B whole CLI без профилировщика | **0.548018 / 1.428991** |
| Парная разность A−B whole CLI с полным observer | 0.746911 / 1.407741 |

Из полного окна ничего не вычитается ради цели 1/2 с; initialize-only/boundary не подменяют его. Отдельная реальная разность CLI нужна потому, что B выполняет registry refresh **в main**, а A — до main; прибавлять весь Startup к старому CLI было бы двойным счётом общей работы. Парная разность отличается от разности двух медиан. Bootstrap interval в JSON — только описательная неопределённость этого локального sample, не разрешение округлить threshold или доказательство для других ОС.

## Что означает прежнее превышение median

Прежняя серия дала **1006.314 /1353.585 мс**: median выше 1000 на **6.314 мс (0.6314%)**; её `costPassed=false` сохранён. В её20 значениях диапазон 774.473–1375.614 мс, bootstrap95% для median 812.854–1116.291 мс. Предыдущий успешный 0.932/1.238 с имел другие package/revision/fixture-state; причинный regression между ними не доказан. Нельзя приписать 6.314 мс ни коду, ни самому количеству проектов по двум независимым сериям.

Текущая серия содержит 9 из20 full samples выше1000 мс; actual median/p95 показаны без округления. Запас median **4.408850 мс**; bootstrap95% median 961.194–1079.225 мс. Результат пограничный: это выполнение цели в данной фиксированной серии, **не доказательство устойчивого SLA <1 с**. Новый общий anchor1003.5823 мс не подменяет прежнее Import→main окно и показан полностью; его engineering outcome отдельно не переопределяется. У каждого полного no-op один fetch, merge и upstream rev-parse, HTTP probes0; полноценный catalog reader/resolver по diagnostic не вызывается — используется проверенный applied context. Это счётчики известных owners, не исчерпывающий сетевой/процессный trace.

Один отдельный подробный проход (не статистический benchmark) разделяет полное общее окно **1363.574 мс** на неперекрывающиеся участки:

| Участок | Мс |
|---|---:|
| Начало общего окна → завершено чтение operation | 273.243 |
| Проверка binding | 16.093 |
| Чтение/проверка applied | 201.824 |
| Preferences → перед snapshot | 25.338 |
| Snapshot: один refresh + fingerprints + reuse | 794.772 |
| Reuse → основная команда | 52.305 |

Первый участок включает lazy import, разбор/canonical conversion operation и observer overhead. Размеры сохранённых квитанций: operation134071 bytes, applied43252 bytes; проверка schema/root/context hash и fingerprints обязательна. Фазы не смешиваются с основной серией и не вычитаются из неё. Причина порядка1 с — выполняемая проверка прежних receipts + один реальный Git refresh, а не новый MCP handshake/LLM/Cognee/полный catalog load. Детального причинного разложения последних6.314 мс прошлой серии нет; evidence не оправдывает новый runtime patch, ослабление checks или повтор до pass.

## Применимость к OpenSpec

Registry 5.5/AC-25 получает сопоставимый current legacy baseline, полные окна, paired whole CLI, write/call inventory и phase diagnosis. G3-B5 закрыт для сопоставимого warm no-op PM5 subset; полная G3/AC-39 остаётся BLOCKED по остальным клеткам. Остальные режимы publisher-only/change/offline, full lifecycle, PM4, platform/terminal/client matrix сохраняют собственную ранее записанную границу; эта серия их не переименовывает в новый pass. Engineering превышение не становится runtime FAIL. При устойчивом материальном превышении отдельный следующий шаг — owner-local уменьшение повторной обработки receipt с сохранением schema/root/hash/proof guards либо согласованный checkpoint; этот прогон реализацию не меняет.

Memory использует ровно этот registry result, не вводит второй benchmark updater/cache/ledger. G1/D9/G2, шесть областей, canonical knowledge home, optional OpenViking, ai_rules_1c и обязательное выпускное наполнение registry AC-36–38 / memory AC-44 прежние. Actual LLM tokens/billing не измерялись; новых always-on bytes/schemas/provider/LLM/memory calls **0**. Старый on-demand context1980 UTF-8 bytes/495 bytes÷4 остаётся прежним scoped evidence, не новой token measurement.

**Gate6, G4, миграция рабочих проектов и публикация не выполнялись.** Source change документационный; OpenSpec validate и source-delivery registration описывают отдельно, не заменяют full G3/AC-39 или release proof.

## Все20 измерений

| Блок | A Startup full, мс | A CLI off, мс | B CLI off, мс | Парная A−B, мс |
|---:|---:|---:|---:|---:|
| 01 | 1060.058 | 5045.353 | 4849.976 | 195.377 |
| 02 | 962.600 | 5179.840 | 5151.901 | 27.940 |
| 03 | 868.198 | 4809.176 | 4531.209 | 277.967 |
| 04 | 932.477 | 4708.847 | 4198.248 | 510.599 |
| 05 | 981.005 | 4839.908 | 4036.805 | 803.104 |
| 06 | 941.554 | 4656.146 | 4100.170 | 555.976 |
| 07 | 977.535 | 5332.440 | 4277.274 | 1055.166 |
| 08 | 992.762 | 5170.298 | 4203.840 | 966.458 |
| 09 | 1038.282 | 5371.602 | 4883.761 | 487.841 |
| 10 | 1189.078 | 5134.288 | 4761.980 | 372.307 |
| 11 | 1168.819 | 5318.421 | 4701.989 | 616.432 |
| 12 | 904.797 | 5026.283 | 4604.422 | 421.861 |
| 13 | 998.421 | 5275.167 | 4167.983 | 1107.185 |
| 14 | 1098.392 | 5681.073 | 4252.082 | 1428.991 |
| 15 | 1026.100 | 5159.673 | 4619.612 | 540.060 |
| 16 | 1109.032 | 5147.249 | 4003.841 | 1143.408 |
| 17 | 920.918 | 5159.648 | 5065.733 | 93.914 |
| 18 | 959.789 | 6697.234 | 4505.985 | 2191.249 |
| 19 | 1099.460 | 5231.020 | 4789.108 | 441.912 |
| 20 | 1129.048 | 6142.299 | 4946.572 | 1195.727 |
