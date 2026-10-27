# MO: реализация и отдельная квалификация

## Текущий статус

Checkpoint/реализация MO0–MO4 согласованы пользователем 2026-10-27.
MO0–MO3 source и ограниченный MO4 N5/B01–B12 завершены. Регистрация
следует после фиксации этого локального коммита; её фактический результат
принадлежит общему source-delivery ledger, не объявляется заранее.
Исторический G5 закрыт в прежнем контуре; его proof не объявляется proof r50.
Gate6/G6, рабочая миграция, публикация, push/PR и native OpenCode не запускались.

## Владельцы и поведение

- Common connection — прежний memory owner, user-local memory/provider.json.
  First ready association / binding-only → configured init вызывает auto setup.
  Startup/обычный package update не enroll старые рабочие проекты. Нет второго
  memory prompt, нового каталога, coordinator, endpoint роли или rights service.
- Default-on preference отделена от configured/unavailable/native activation.
  Явный disable сохраняется даже без прежнего binding. TOOL off/invalid не делает
  provider calls; общий policy check один. IDs/cycle/pending/data сохраняются.
  settingsHash в том же private binding сравнивает вход common settings;
  lazy private IDs не делают неизменный input новым. Старый automatic
  memoryOptIn=false не выдаётся за подтверждённый отказ.
- HTTP owner держит до двух независимых raw GET, dedupe до dispatch, прежний
  round-robin/порядок, 24 candidates/8 cards/1600 tokens и общий deadline20s.
  Ошибка остаётся partial; при остановке чистятся только свои HTTP resources.
  До одного speculative запроса учитывается в sourceLookups; originals
  не кэшируются между операциями, writers/semantic queries не распараллелены.
- Exact ID использует прежний memory_status. CHUNKS_LEXICAL добавлен после
  native capability proof того же profile; CHUNKS сохраняется по умолчанию.
  Один маршрут, прежние standing/task/reformulation/TOOL budgets.
- Удалена повторяемая reformulation фраза из каждого payload: её policy остаётся
  у fork. Sufficient checked cards можно использовать без повторного открытия
  того же original; missing details/changed context/critical-action freshness
  требуют точного чтения. Факты/status/applicability/evidence не сокращены.

## Источники и immutable inputs

Baseline workflow: 5f7620e2d734b04e55aeb33f264c1def87709aa1.
Candidate fork r50: a2cbdcef52316db426acedc852f495564189f1ca на отдельной
upgrade/r50-memory-optimization, от r49 df91727. Upstream unchanged:
2f640143756ecd01fed42100e412632aa9082385. Рабочий r49 сохранён.
Pin/asset согласованы, compatibilityStatus публичного шаблона остаётся pending.

Опубликованный registry R6 SHA0274a8ffb5a03ba7b856736c2b4a637ccbe98b73,
данные, homes и native mappings не опубликованы заново и не менялись.
Cognee source/image/container/data/model profile не менялись:
image sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820,
2CPU/5GiB, прежний common ordinary API-key principal. Открыт только свой
локальный SSH forwarding к существующему тестовому экземпляру.
Q/initial native probe: два current raw original и CHUNKS_LEXICAL HTTP200;
31 hit в разрешённом B01 union, без расширения dataset scope. Это capability,
не доказательство качества всех задач.

Ignored evidence owner: build/test-results/memory-mo-20261027.
runtime-inputs.json фиксирует byte hashes baseline/candidate; snapshot не является
установленным пакетом. instrumented-entrypoints.json доказывает единственное
добавление общего test-only wire observer в frontend snapshots, весь reader code
неизменён. Нет telemetry сервиса или instrumentation в shipped runtime.
source-snapshot-equivalence.json доказывает byte identity всех frozen runtime
inputs с clean source aa825615, установленным на N5. Последующее уточнение
отчёта меняет только документы; native identity не переименовывается.
Нативный before/after использует настоящий long-lived PS5 stdio frontend
и read-only fixture proxy; это не installed/client-GUI acceptance. В prompt
подаётся selected controlled policy clause, как в исходном N7, а не полный
производственный набор правил. Actual usage относится ко всему этому agent run;
его нельзя выдавать за расход полного installed workflow. Последний проверяется
отдельным N5 без нового парного score.

## Уже полученная проверка

| Граница | Фактический результат |
|---|---|
| Source memory + catalog setup | 64/64 на PS5. После уточнения settings input/off — 24/24 memory; catalog 40/40 inputs unchanged |
| Memory owner на Core | Окончательные24/24 с settingsHash/off, memory-core-release-inputs.xml |
| Catalog setup на Core | Прежний Get-ItlProductProjectSettingPlans дефект воспроизведён одним тем же case на неизменённом baseline; не исправлялся и не объявлен новой поддержкой |
| Fork source | 182/182 Pester + Full source stages passed на exact a2cbdce; это source qualification, не публикация и не workflow Gate6 |
| Overlay | Все297 exact normalized result hashes passed, включая изменённые два прежних test files |
| Установочный контракт fork | Все12 прежних client formats: init/update/doctor, byte-idempotence и сохранение user files passed; compatibility-r50.log. Native GUI activation этим не заявлена |
| MCP schema | Те же4 tools, production schema1920 →1932 UTF-8 bytes (+12), schema-bytes.json; экспериментальный proxy — отдельный transport |
| Context | Always-on AGENTS12800 bytes unchanged. Full-cycle load144351 bytes против r49 143908 (+443), ceiling144384 unchanged; bytes/4 proxy ≈111 tokens, не measured model usage |
| Native original / lexical | Тот же image/principal/profile, два concurrent reads и lexical read в исходном B01 scope passed; качество/экономия оцениваются отдельно ниже |
| RegisterChange | Обязательный отдельный шаг после этого coherent local commit, queue product-project-registry-g2; Targeted выполняет только helper. Фактическая граница — queue Status |

## MO4 — один конечный проход существующих задач

B01–B12, тот же frozen corpus, исправленный по прежнему решению B11 customer
context и прежний эталон; новая модель/корпус/кейсы не добавлены.
Before/after: baseline Cognee → optimized Cognee, не новый files-vs-Cognee score.
Одна модель gpt-6.1-sol/high, один текущий Codex CLI0.164.0-alpha.11.1 в обеих
arms, AB/BA order. Cursor не используется; auth/global client config не копируются.
Tool timeout40s/startup20s/task600s и прежний query/source budget сохранены.

Первые B01/B02 model attempts не приняты: proxy унаследовал cp1251 stdin/stdout
при UTF-8 MCP wire, хотя сам reader завершал recall за3–16s; клиент не получал
карточки и ждал40s. Отдельно fixture не задавал technical knowledgeAreas для
local status. Проход остановлен до B03, четыре исходных ответа/ошибки сохранены.
Исправлены только UTF-8 и техническое дополнение исходного context, без изменения
task_input/expected/scope/topology класса. campaign-r1 сохраняется отдельно;
transport.json фиксирует cp1251 до и utf-8 после. Неполные первых четыре ответа
не объявляются качеством поиска или before/after ускорением.

campaign-r1 завершён:24 arms/12 pairs, инфраструктурных ошибок0. В baseline
B04/B05 агент запросил пятое exact чтение: guard отказал, лишнего raw запроса
не было. Эти два policy violations сохранены; budget не расширялся. Первые
сохранённые arms не повторялись при продолжении campaign. Baseline и candidate
получили по24 recall, включая12 standing; candidate выбрал lexical в3 task queries.

Whole-answer review —12/12 в каждой arm по прежней rubric N7-evaluation.json
и exact37 recovered notes. Прежнее ограничение сохранено: исходные bytes
evaluator недоступны, как уже записано в followup-manifest, и не восстановлены
из новых ответов. B11 содержит только ранее согласованное customer context
уточнение. Stale/out-of-scope applications0, свежих runtime claims без proof0.
Это не новый files-vs-Cognee score и не перенос прежних Cursor/Grok результатов.

| Метрика, сумма12 задач если не указано иначе | Baseline Cognee | MO candidate |
|---|---:|---:|
| Whole-agent wall, s |591.749|512.638|
| Median whole-agent wall, s |48.066|42.046|
| Измеренные tool durations, s |207.373|127.739|
| Recall / exact requests / local status |24 /25 /12|24 /18 /12|
| HTTP principal / recall / raw / dataset status |47 /24 /257 /23|42 /24 /287 /18|
| Agent-visible tool response UTF-8 bytes |153952|147368|
| Native recall payload bytes |105728|103705|
| Native recall cl100k / o200k tokens |24739 /24931|24628 /24821|
| Actual agent input tokens |1268114|1256936|
| Cached input, включён в input |1094016|1062656|
| Input вне cached subset |174098|194280|
| Actual agent output tokens |8484|8541|
| Reasoning, включён в output |877|1300|

Время задачи -13.4%, tool duration -38.4%, agent input -0.9%; output +0.7%,
uncached input +11.6%, raw attempts +11.7%. Из25 baseline exact requests2
отказаны до HTTP; candidate18 успешны. Candidate21 deferred raw attempts не
были consumed: cleanup отменял свои упреждающие запросы при bounded early exit.
Это учтённые attempts, не21 доказанных server successes. Остальные различия
в raw числе включают allowed query/candidate selection и deadline coverage;
вся разница не приписывается одному speculative reader. Completion/request
строки группируются по одному ID, parent/child не суммируются. Два refused
proxy calls не имеют отдельного duration: сумма tool timings их не включает,
whole-agent wall включает весь ход. Docker access log не используется как
счётчик: он не содержит HTTP access строк.

Все48 native recall payloads удержали прежние8 cards/1600 tokens, cap24 и20s
deadline. Test proxy reserializes JSON с whitespace: agent-visible bytes
считаются отдельно, не подменяют native limit. Source policy+schema delta
малый; full-cycle bytes и always-on выше. Timings instrumented, один finite
AB/BA проход, не SLA и не причинная оценка отдельного MO1 от cache/model variance.
Получено ускорение, но денежная экономия не доказана: uncached input вырос.
Сохранён согласованный bounded trade-off: ≤2 raw reads, до1 speculative GET на ранний выход,
без увеличения semantic query budget, новых моделей или backend изменений.

Артефакты: paired-summary.json, whole-answer-review.json, campaign-r1/*-terminal,
*-events, *-tool-events, *-wire и transport.json. Сохранены failed root campaign,
первые counter/parser ошибки анализа и все прежние G5/sealed artifacts.
MO4 N5/B01–B12 закрыт в описанном контуре; доставка отделена ниже.
Internal embeddings/LLM/graph usage без native counters — unknown, не ноль;
сокращение одного payload не объявляется денежной экономией всей задачи.


## Установленный N5 — завершён

На тех же projectRoot/branchRoot из прежнего pm5-copy-receipt штатный
update-installed-workflow установил source aa825615/r50 за515.729s. Первый
вызов остановился до копирования: локальный clone унаследовал origin как путь
исходников. Его metadata исправлена на проверенный origin исходного fork,
content/commit unchanged; исходные failure/log/result сохранены. Использован
unique qualification-only local ref в отдельном E:/.../fork-r50-mo, прежний r49
и official refs сохранены. Hotfix прошедший только для этой PM5-копии; публичный
template compatibilityStatus по-прежнему pending, публикация не выполнялась.

- Disable32.541s; native Codex required21.032s честно сообщил unavailable /
  dependent incomplete, не empty success, без обхода выключенного binding.
- На прежней границе между client receipts и settings writer остановлен
  штатным cancel2.410s, status partial и exit1. Pinned resume4.992s завершил
  ту же operation; owned restore5.790s вернул applied/settings.
- Исходный pre-startup hash assertion остановился: первый startup после update
  нормализовал ровно owned Cursor script argument5 из source checkout в
  установленную branch. Тот же прежний finish-recovery reconstruction вернул
  точный исходный SHA, доказывая сохранение всех остальных bytes. Cursor
  не запускался, config вручную не правился. Disabled → restored bytes точны;
  failed assertion сохранён, cancel/resume/restore не повторялись ради pass.
- Штатный explicit enable34.497s сохранил identity/cycle/dataset IDs/other MCP.
  Fresh Codex43.142s прочитал g5-n1-workspace с прежним data ID
  e6cf67d5-db9f-4149-9cf5-a041579b1c2c: durable/verified/applicable; один
  scoped recall вернул тот же fact, partial coverage названа. Runtime proof1C
  не придуман, backend note writes0, receipt/runtime edits0.

Native consumer — Codex CLI; descriptor фактический installed Kilo-owned
с installed r50 policy. Это не automatic Codex GUI membership/attachment и не
новая полная client matrix. End-to-end first-ever init/production rollout этим
не объявляется. Последующее doc-only уточнение коммита не переименовывает
native aa825615 в exact-tree proof нового SHA: executable runtime inputs
byte-identical, их hashes в source-snapshot-equivalence/evidence-manifest.

## Конечная матрица MO и стык реестра

| Критерий | Доказанная граница |
|---|---|
| MO-AC1 / MO-R1 | Existing source owner scenarios64/64: ready auto setup без второго prompt, off/ambiguous legacy/unavailable, initial cycle/repeat и association/init handoff. Installed N5 отдельно доказывает off, preservation и fresh call. Полный новый init/client GUI не запускался |
| MO-AC2 / MO-R3 | Reader PS5/Core24/24, два deferred reads и порядок/cleanup, исходные semantic assertions;24 whole answers, current scope/status/applicability, stale/foreign applications0. R6/home/project–MCP differences unchanged, IDs/auth private |
| MO-AC3 | Native lexical capability плюс3 lexical task queries; exact18 вместо25 attempted, standing/task budget24 recall unchanged, candidate refusals0. Нет нового classifier/graph/hidden fallback |
| MO-AC4 | Все48 recall native limits прежние,4 schemas +12bytes, AGENTS unchanged, full-cycle +443bytes внутри прежнего ceiling. Межоперационного original cache нет |
| MO-AC5 | Полные сопоставимые agent usage/wall/calls/bytes выше; cached/reasoning subsets не сложены дважды. Ускорение подтверждено в finite run; monetary saving не установлена |
| MO-AC6 / MO-R4 | Existing N5/B01–B12 и все failures/sealed proof сохранены; новые cases/платформы/клиенты/Gate6 не добавлены. Code/native/registration разделены |
| MO-R2 | Source association later/no answer/нет connection оставляет каталог доступным; auto не вызывается Startup/обычным package update; готовность памяти не выдумывается |

Реализация MO завершена в согласованной границе. Денежная эффективность остаётся
неподтверждённой характеристикой, а не поводом повторять корпус до удобной цифры.
Это локальный source candidate, не новый production SLA или files-search win.

Остаток до первого выпуска не расширяется этим изменением: выполнить отдельно
разрешённый выпускной Gate6 на installable candidate, закрепить production
connection/homes/mappings через прежнего owner и выполнить предусмотренную
выпускную проверку default-on на установке. Миграция рабочих проектов и
публикация требуют отдельного разрешения. Публичный r50 tag/compatibility
promotion остаются у установленного fork/release процесса. Непроверенные
платформы/GUI-клиенты не стали passed; прежние G3/G5 accepted bounds сохранены.

После этого коммита обязателен RegisterChange -QueueId product-project-registry-g2;
он один выполняет Targeted. До успешного atomic queue update source не считается
зарегистрированным. Финальный пользовательский статус подтверждается helper и
свежим Status; этот текст не заменяет ledger и не требует self-referential
коммита после регистрации. Gate6/G6, working migration, push/PR/publication
в текущей задаче не выполняются.

### Регистрация: разрешение параллельного изменения

Первый RegisterChange остановился до Targeted при интеграции с принятым
779ae33d (r49 compatibility promotion). Исходный failed candidate и ledger
сохранены, queue head остался5f7620e2. В source task интегрированы published
develop f9785223 и принятая очередь через779ae33d, их изменения сохранены.
Единственный конфликт — версия/status в dependency lock: r49/passed относится
к прежнему r49 proof и не переносится автоматически на r50. Итог r50/a2cbdce
остаётся pending с пустой датой до штатного workflow qualification/promotion;
r49 promotion сохранён в ancestry и собственном evidence. Full/Gate6 ради
разрешения конфликта не запускались.

Собственные frozen MO runtime inputs остаются byte-identical. В ancestry также
сохранены чужие shared-core/init/artifact-retention исправления; их объединённое
native installed acceptance не приписывается N5 aa825615. Интегрированную source
границу проверяет следующий штатный RegisterChange/Targeted, выпускной installed
candidate остаётся отдельным Gate6. Полные старые native/failed proof сохранены.

Вторая регистрация выполнила Targeted, но не прошла: inherited PSModulePath
содержал Modules bundled PowerShell Core у вызывающего процесса. Windows
PowerShell5.1 не смог загрузить Get-FileHash (36 failures), ещё один test упал
на TypeData ObjectSecurity и один — downstream от отсутствующей fixture;
оставшиеся files не объявлены passed. Это ошибка среды моего запуска, а не
принятый source proof. Native/PS5 owner tests ранее запускались с исправленным
окружением. Исходные candidate/log/XML сохранены, accepted queue не заменена.

Парный диагностический запуск той же команды Get-Command Get-FileHash/Get-Acl
на том же PS5 host воспроизвёл CommandNotFound в inherited env и PASS после
существующего Get-ItlWindowsPowerShellModulePath owner. Owner удалил только
Modules текущего Core PSHOME. Русский текст exception сохранён в UTF-8;
714 stderr bytes исправленного запуска — native progress CLIXML, не ошибки.
registration-environment.json/module-probe-* фиксируют причину и результат.
Тесты, их inventory, assertions и deadlines не изменялись. Продолжение — тот же
RegisterChange с нормализованным окружением caller; ни отдельного Targeted,
ни дополнительного gate или native сценария ради этой ошибки не запускается.

После нормализации окружения третий Targeted завершил84 прежних shards:
1965 passed/1 failed. Единственный failure — DependencyLocks.Tests.ps1 ожидал
r49 вместо разрешённого r50; проверка выявила также оставшийся r49 default
в templates/project.json. Это моя неполная синхронизация версии при MO:
project.json приведён к r50, в том же существующем test обновлены точные
ref/commit/revision на r50/a2cbdce/50. Строгие repo/upstream/status/date,
все остальные assertions, inventory и deadlines сохранены. Новых cases нет.
Остальные1965 результатов не выдаются за полный gate pass; старый failed
candidate и XML сохранены. Сами reader/adapter/policy inputs native AA/N7
не изменились; новый project-template default проверяет штатная регистрация,
не объявляется новым полным native init. Продолжение — RegisterChange в том же
исправленном окружении, без повторного N5/корпуса/отдельного Targeted.
Повтор ровно упавшего existing test на исправленном source:1 passed,0 failed,
остальные36 в этом focused запуске не выполнялись (dependency-lock-r50.xml/log).
Это не результат всей suite/Targeted; общую границу устанавливает helper.
