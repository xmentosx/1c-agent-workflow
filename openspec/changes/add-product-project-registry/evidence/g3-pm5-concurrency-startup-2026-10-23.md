# G3: два сеанса и расходы Startup на текущем PM5, 2026-10-23

**Конкурентность в проверенном same-user PM5 subset passed; полная приёмка расходов Startup открыта.** [JSON: результаты, измерения и SHA raw evidence](g3-pm5-concurrency-startup-2026-10-23.json). Новое наблюдение **G3-PM5-STARTUP-WINDOW-COST**: полное измеренное окно имеет median/p95 **2.045/2.570 s** при инженерной цели **1/2 s**. Это открытый пункт приёмки/атрибуции стоимости, не новый runtime FAIL. Source/runtime/tests/пороги не менялись; full G3/AC-39 открыт.

## Стенд и единый итоговый batch

Тот же main **`C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`**, sibling `branch`, PM5 КОРП / `pm5-core-development`, Kilo + Cursor. Source base **`06843cd0dd2087324824eb77291436b6bb37e966`**; installed implementation **`909d1e229351d0b0cdca2db6c3fa81ff92b31503`**. Runtime SHA **`c204c13a55f2bd504c6ae3c2e70087e46305179fab1c6f015bf3b84daea93da4`** совпадает у source/main/sibling; ai_rules_1c/descriptor/locks/HEAD прежние. Новый package update/запуск 1С не выполнялся.

Private Git origin/author/cache/home независимы от normal registry и прежних qualification origins. Harmless Graph URL меняет реальные client settings, без инициированных qualification native MCP tool calls. В итоговый batch входят **49 public calls**: A/B + read-only status, prime, **одна серия 20 чередующихся пар** profiler-on/off, publisher-only/change/offline, final original и on-demand context. Подготовительные failed harness попытки не включены в статистику; серия из 20 пар не перезапускалась. Бизнес-данные, path/topology, два клиента и package pin прежние.

## Конкурентность двух процессов

Первый public `sync-client-mcp -Client kilocode` остановлен timing-only command breakpoint после настоящей Kilo receipt / до второй записи. Подтверждены A=new / Cursor=old, partial plan и прежний applied marker. Второй public `sync-client-mcp -Client cursor` запущен в том же root и **ждал existing lifecycle lock**; до release A не дошёл до main и не изменил SHA/mtime девяти protected paths.

Пока оба процесса живы, canonical **`vibecoding1c-mcp-status -CatalogAction status`** завершился exit0 за **2.496 s**, сохранив все девять paths. После release оба original commands завершились **exit0**, A/main → B/main последовательно. Оба видели согласованные Code/Graph settings и свой pinned context:

| Процесс | Pinned revision при main | Результат |
|---|---|---|
| A, PID 59188 | `3ca5f193ad97a6ed4b63aff0f50baa2ed0162b29` | Реально записал оба клиента до main; applied совпадает с revision A |
| B, PID 64600 | `3612463b27041516feb322dfa5c213c51ee723c9` | Получил новый tip после ожидания; applied совпадает с revision B |

Второй tip создан harmless изменением имени в private catalog во время паузы A. Он не подменил snapshot работающего A. У каждого процесса зарегистрирован один fetch через existing registry Git owner; snapshot/main settings не смешаны. Новый lock/coordinator/guard bypass не добавлялся. Это actual native helpers одного обычного Windows-пользователя, не independent terminal users, не race внешнего редактора после ответа и не новая IDE/frontend activation qualification. **Same-user serialization и доступность read-only status при active writer приняты в этом subset.**

## Расходы Startup

20 profiled и 20 control вызовов одной и той же команды на том же пакете/каталоге, порядок on/off чередуется. Во всех **40 no-op** SHA+mtime девяти protected paths неизменны. Profiled Startup начинается на первом `Import-ItlProductProject`, заканчивается на входе `Sync-ItlClientMcpConfig`: включает lazy import, initialize и pre-main повторное чтение config. Дополнительно измерен прежний более узкий интервал initialize → main. Command breakpoints только наблюдают время/счётчики; функции не подменены.

| Метрика | Median | p95 |
|---|---:|---:|
| Полное измеренное окно Startup | **2.045 s** | **2.570 s** |
| Initialize → main | 0.993 s | 1.461 s |
| До Initialize внутри полного окна | 1.034 s | 1.424 s |
| Whole CLI, profiler on | 5.495 s | 7.533 s |
| Whole CLI, profiler off | 5.596 s | 6.961 s |
| Попарная разница whole CLI on − off | +0.091 s | +1.331 s |

p95 — nearest-rank для 20 samples; максимум полного окна **3.409 s**. У каждого profiled вызова один observed registry-owner fetch, один initialize, PowerShell HTTP calls в измеренном окне **0**. Это не полный сетевой trace всех возможных native subprocesses. CPU/peak working set самого PowerShell закреплены в JSON; CPU/RAM дочернего Git отдельно не измерялись.

**G3-PM5-STARTUP-WINDOW-COST открыт (task5.5 / AC-25/39).** Узкий initialize interval укладывается в цель, полное окно — нет. Примерно 1.034 s median приходится на часть до Initialize; это измеренная граница lazy import/disposition, не доказательство причины регрессии конкретного исходного изменения. Profiler-on/off сравнивает инструментирование на одном пакете; это **не** before/after feature baseline. Host noise виден по знакопеременным paired differences. Нельзя вычитать предполагаемую стоимость debugger или объявлять старые preloaded synthetic hook numbers сопоставимым полным Startup.

Продолжение у existing owner: отделить lazy-load/pre-main стоимость и измерительную погрешность на сопоставимой базе, затем при необходимости отдельно согласовать/исправить причину и повторить исходную серию с прежними целями. Никаких новых barriers, расширения budget или скрытого исключения из acceptance не вводится. Общая стоимость model context/billing и точный incremental before/after feature delta остаются непроверенными.

## Три дополнительных сценария

| Сценарий, один sample | Startup / whole CLI | Client writes | Результат |
|---|---:|---:|---|
| Publisher-only | 5.077 / 7.960 s | 0 | Catalog context обновлён, физические клиентские SHA/mtime прежние |
| Изменение выбранного Graph endpoint | 7.012 / 10.242 s | 2 | Оба реальных client files обновлены до main; project/context остаются согласованными |
| Offline, immediate connection refusal | 4.999 / 8.487 s | 0 | WARN offline, прежний validated applied SHA, original main/exit0 |

Здесь нет p95 distributions. Offline не заменяет отдельный stalled-transport/deadline/cleanup proof. Control commands и samples не выполняют actual клиентские MCP tool reads. Final context — валидный compact UTF-8 JSON **2157 bytes**, **≈540 tokens только по bytes/4 proxy**; actual tokenizer/model billing не измерялись. Это on-demand output, не always-on/tools catalog. Новых always-on instructions/tool schemas **0 bytes**, квалификационные client LLM turns / direct MCP tools / Cognee calls **0**. «Нет новых provider calls» не означает нулевой model-context cost при будущем использовании.

## Failed harness и сохранность

Первый observer читал redirected stderr без `FileShare.ReadWrite`; OnWait отказал, owner capture прервался, B получил pending plan. Исходные script/partial snapshot сохранены, public restore → baseline sync прошли, ручных квитанций не было. Наблюдение live logs исправлено у harness, не runtime.

Две следующие попытки показали правильные snapshots/main, но wrapper возвращал внутренний stale Git `LASTEXITCODE=1` после успешного script return. Source lifecycle receipt имел succeeded/exit0; отрицательная финальная assertion сохранена. Harmless probe доказал различие: normal script return с native exit1 имеет invocation success=true; настоящий script exit1 — false. Исправлен только сбор script invocation outcome в wrapper, failure не маскируется. Итоговый A/B повторён полностью с прежними assertions и настоящими process exit0; старые попытки не переоценены в pass. Последний reset receipt имеет повторно использованное имя; отдельная длительность первого reset не заявляется. Все критические failed reproducer snapshots/observer scripts/predicate failure и финальные 40 samples сохранены.

После batch возвращены original desired endpoint/display name/publisher metadata через private Git и штатную команду. Оба client JSON целиком byte-equal исходным, foreign bytes и семантика сохранены. Main/sibling clean, HEAD/descriptor/lock/pins прежние; DB **3,295,928,320 bytes**, SHA **`c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`**. Strict before/after **21 protected files и четырёх old roots** passed; семь Gate6 artifacts, 11 capsule hashes и **760 уникальных raw files предыдущих reports** совпали. Normal registry `c29e72af…` и предыдущий private origin `587ec7cf…` прежние; native test processes завершены. Исторический old-seed movement и отсутствие original raw seed не переписаны.

Открыты cost finding выше, external-edit race после решения, terminal multi-user, прочие installed/client/PM4/Windows10/Server/full-cost критерии и **full G3/AC-39**, обязательное наполнение AC-36–38. Memory consumer4.2/G4/AC-43/G5/44 не реализован/не принят; canonical home/шесть областей/grants/Q1–Q7/D9/G2/optional OpenViking/ai_rules_1c прежние. **Gate6, G4, рабочая миграция и публикация не выполнялись.** Документальная регистрация/Targeted имеет отдельный ledger, не закрывает performance gap или G3 acceptance.
