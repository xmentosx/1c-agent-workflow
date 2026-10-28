# Acceptance and Evidence Plan

## Блокер регистрации QP: клиентский контекст, 2026-10-28

Failed candidate1691fbe7491290ff0ec10f3f2af7563b82a4fc63 и прежний39pass/1fail
сохранены. Original failure: master/Codex34174bytes при ceiling33942.
Чужой client-membership-rollout7d707cef добавил452байта в единственный
itl-update-workflow template1478→1930; старый source33722 имел220байт запаса.
Измерены все24 master/dev surfaces через настоящий existing renderer:
каждая+452, file counts/остальные файлы неизменны. Это on-demand command footprint,
не новый всегда загружаемый root context. Native tokenizers: cl100k341→405,
o200k333→400; привязка к tokenizer модели не заявляется.

Семантическая сверка сохранила trigger master/dev update, package rollout с
additive branch clients/locks/local paths, чужие settings/dirty files, только
owned commits, no-push/no-refresh, named failure continuation, frozen pending
client set/no manual receipts/snapshots, no detach propagation и отдельный refresh.
Runtime/template не редактировались. Existing budget test проверяет эти required
clauses и cap1930 при наличии rollout, затем добавляет ровно452 к прежним ceilings.
До появления rollout старые ceilings неизменны; aggregate assertions, file counts
и все прочие budgets сохранены. Для original combined case ceiling34394,
фактический34174, запас остаётся220 — blanket slack не добавлен.

Только штатный RegisterChange/Targeted повторяет исходную проверку общей
комбинации; новые сценарии/Gate6/native memory calls не добавляются. Источник
доставки — общий queue ledger; этот текст не объявляет регистрацию passed.
Measured proof: build/agent-artifacts/memory-registration-context-budget-20261028/.
На момент той регистрации planning commit QP0–QP6, смена Cognee, рабочая
миграция и публикация не запускались; actual QP0–QP4 ниже.

## QP: приёмка подготовки рабочего профиля, 2026-10-28

Выполнение QP0–QP4 согласовано; [фактические результаты](evidence/qp-preparation-2026-10-28.md).
Выбор Qwen согласован, [план/checkpoint](design.md#qp-рабочий-профиль-qwen-и-новый-индекс-2026-10-28) подготовлен. Следующая
таблица определяет полный контур QP0–QP6. Native QP0–QP4 proof и его
ограничения перечислены ниже; source registration не заменяет native или release.

| Критерий | Доказательство готовности в существующем контуре |
|---|---|
| QP-AC1 / профиль | Exact image/schema/SDK route, model4096/cache6/rate off/pool256MiB,2CPU/5GiB, native ordinary principal, реальные private credential/endpoint; admission qualified hash получен из фактического результата, BGE return admission сохранён. |
| QP-AC2 / восстановимость | Согласованный полный T, manifests/hashes и отдельный restore с exact raw originals; relational/auth/graph/vector/original/mapping комплект и Q5 currentness, без правки SQL. |
| QP-AC3 / данные | По каждой из6логических областей current scope+noteId+payload/status/provenance/applicability множества равны source; late corrections/deletions учтены; native dataId/UUID изменения имеют exact map. Old source/failed proof сохранены. |
| QP-AC4 / новый индекс | Новые datasets/4096 namespaces, native completed и actual scoped CHUNKS/raw; old384 не переиспользованы, dedup/старый completed не принят как reindex proof. Учебный корпус не выдан за рабочие данные. |
| QP-AC5 / совместимость | Native principal и task/workspace/workplace/cycle сохраняются; новые instance/dataset/data IDs приняты existing owner, pinned old pending не переназначены, old cache не используется как proof. Default-on и explicit off/reload/unavailable проверяются existing N5/N6. |
| QP-AC6 / эффективность | Query20s/write60s и прежние caps/assertions, максимум2original reads in flight; existing RU21/72/6 evidence reuse только при совпавших влияющих inputs, без новых вопросов. Ingestion peak/disk/whole cost измерены либо честно unknown; прежние read peaks не заменяют ingestion. |
| QP-AC7 / cutover | Отдельное разрешение, выпускной admission exact candidate, финальный Tf/diff, current original equality и fresh reader, один normal target; никакого dual write/automatic fallback. Все допущенные enabled bindings обновлены, off/независимый workflow сохранены. |
| QP-AC8 / возврат | Existing Q5/N6 continuation: отдельно подтверждены комплект до новых writes и сохранение поздних confirmed originals/corrections/deletions через Tr→BGE. Старый snapshot один не объявляется current; unsafely stale scopes unavailable, source/pending сохранены. |

Это ограниченное продолжение существующих Q1–Q7/N1–N7/N5/N6/MO scenarios,
не новая клиентская/платформенная матрица и не повод переоткрывать G3/R6/G5.
Gate6, рабочая миграция и публикация остаются отдельными неразрешёнными этапами.
Текущая выполненная граница — QP0–QP4 на пустом рабочем старте и его отдельной
qualification-копии; реальные working records не переносились. QP5/QP6 не начаты.

## QP0–QP4: actual acceptance boundary

[Отчёт и retained failures](evidence/qp-preparation-2026-10-28.md),
[actual result](evidence/qp-preparation-2026-10-28.json),
[native profile/index hash input](evidence/qp-qwen-profile-2026-10-28.json).

| Критерий | Фактическая граница |
|---|---|
| QP-AC1 | Native image/SDK route/settings/common ordinary account подтверждены; статическая Qwen пара допущена в source, BGE admission прежний. Main target stopped, normal-client endpoint не активирован; releaseAdmission=false |
| QP-AC2 | Full BGE snapshot3196entries/2.622GB; separate native restore84/84 exact. Qwen empty/N6 snapshots сохранены, old currentness не объявлен по одному snapshot |
| QP-AC3 | Empty production0originals/17shared scopes; qualification50payloads равны до/после restore по тем же IDs, correction/precise retirement reapplied. Все84source originals и5local files/2pending byte-preserved |
| QP-AC4 | Native completed50/50, full CHUNKS50exact hashes, read-only native Lance72tables/895rows с только4096; старые384 datasets не подмешаны |
| QP-AC5 | На source fixture actual AUTO/off/fresh process, same ordinary UUID и stable six scopes. Existing setup/default-on source contract переиспользован; normal-client setup/reload/applied admission остаётся QP5 |
| QP-AC6 | RU21 13.312s и original RU01 lexical3.873s. Native frontend writes25/19/43/32s, limits20/60 и context caps прежние. Bulk median26.403s/max271.259s/13из49>60, unknown monetary cost; extra semantic probe20.122s timeout сохранён, всеобщая SLA не заявлена |
| QP-AC7 | NOT RUN: QP5/cutover/normal writers не разрешены |
| QP-AC8 | Qwen old-restore/current repair подтверждён в qualification; actual late-write Tr→BGE и production rollback NOT RUN, относятся к QP6 |

Это не повтор72запросов/6полных ответов и не native UI/install proof. Source
профиль/hash/private-path/unknown-mixed-pair assertions расширены в прежнем
It, без новой тестовой матрицы. Точные ошибки nested-array/Python PSMODULEPATH/
read-only SDK helper сохранены и разобраны у владельца. Лимиты, assertions и
исходные inputs не ослаблены; дополнительный semantic query не воспроизводил
исходный lexical tool call, но остался валидным отрицательным наблюдением;
original lexical tool call восстановлен
по прежней sealed trace. Ошибка ingestion ru-n26 продолжена штатным cognify
только после terminal failed, без remember replay или модификации данных.

Штатный RegisterChange после коммита владеет Targeted; результат — в common
queue ledger exact candidate. Gate6/G6/working migration/publication не запускались.

## Qwen cache6: граница полной CLI/MCP квалификации, 2026-10-28

[Native evidence](evidence/qwen-lru6-codex-answers-2026-10-28.md):6/6 прежних полных Codex-ответов соответствуют
неизменённому эталону;5положительных заданий получили применимые verified/durable
оригиналы, RU24 корректно отказался от неподтверждённого сертификата/даты.
Проверены точные prompts и source parity, same binary/model, returned opaque IDs,
лимиты3recall/4exact/1status,8карточек/1600токенов и отсутствие записи/других tools.
Frontend20s и CLI watchdog600s сохранены; max recall RPC20.114s включает overhead,
первый cold recall partial не исключён. Median полного ответа44.552s/max51.443s.
Все MCP/answers декодированы строго;8повреждённых Docker debug-фрагментов
сохранены побайтно, не используются как текстовое доказательство. Native code,
корпус и задания ради результата не менялись. Рабочий Cognee не затронут.
Результат72/72 относится к предыдущему фиксированному search-набору; в этом
продолжении повторены ровно6Qwenответов. BGE и ingestion с cache6 не повторялись.
Сохраняются шесть областей/общая связь, published registry и ai_rules_1c;
production switch, Desktop/installed proof и release acceptance не следуют
из этой квалификации. Source validation и регистрация учитываются отдельно.

## Qwen native profile6: actual acceptance boundary, 2026-10-28

[Native repeat](evidence/qwen-lru6-recheck-2026-10-28.md) подтверждает exact50chunk hash sets, RU21 и72/72
responses при прежнем whole20s; каждый query и список dataset IDs равен
прежнему case/replicate.2cold/1warm blocks и3отдельных warmups сохранены;
scope/hash violations, lock иOOM=0. Read peak1.584GiB при5GiB.
Native shutdown warnings не скрыты. Ingestion и12Codexanswers не повторялись,
BGE с новым config не измерялся. Рабочий provider/registry/ai_rules_1c не менялись.
Исторические40failures и5/6Qwenfull answers остаются historical proof, а
не подменяются результатами этого read-only по назначению native набора.
Source validation/registration учитываются отдельно; нового release gate нет.



## Исторический итог профиля cache4/pacing1s

Итог28октября: полный identical index допущен;144/144 attempts и12/12 answers
завершены. BGE72/72 и6/6 выполненных задач; Qwen32/72 и5/6. Нужные знания
Qwen ранжирует лучше на успешных ответах, но20s availability недостаточна.
Рабочая модель прежняя; конечное исследование закрыто, новый release gate не вводится.

## RU-EMB: повтор технического допуска, 2026-10-27

[Repair result](evidence/ru-embedding-repair-2026-10-27.md) — текущая сверка;
предыдущий preflight ниже сохранён как история. Успешные component requests не
подменяют идентичные50 native chunks,144 timed attempts и12 полных ответов.
HTTP wait timeout и последующий native completion фиксируются как разные
исходы одного intent. Запись не повторяется, pending не считается completed,
gold/ranks/корпус не меняются;20s deadline и остальные frontend caps прежние.

## RU-EMB: допуск не равен сравнению качества, 2026-10-27

[Единый native preflight result](evidence/ru-embedding-preflight-2026-10-27.md):
BGE имеет 50/50 одинаковых с корпусом text hashes; два Qwen profiles неполные
(OOM / 403). Измеряемые 144 поисковых trials и 12 Codex answers не начаты.
Quality/latency/token advantage остаются unverified; native control и один
host embedding probe не подменяют парный эксперимент. Условия продолжения,
failed originals, currentness, resources и cost unknown сохранены в отчёте.
Это исследовательский остаток, не новый release gate.

## Фактическое продолжение G5, 2026-10-26

[Единый memory follow-up](evidence/g5-common-continuation-2026-10-26.md) — текущий результат; прежний sealed
first-run report сохранён. Update/reset blockers исправлены и повторены на
исходной PM5 topology; шесть областей, product homes/applicability, actual
Kilo/Cursor operations и backup/restore подтверждены в указанных границах.
Frozen N7 завершён: files11/11, Cognee5/11 на однозначных задачах; B11
противоречив. N5 policy continuation подтверждён; broader writer matrix
остаётся открытой. Shared native API-key auth квалифицируется отдельно
от качества retrieval; G5 не принят.
Фразы о незапущенном G5 ниже относятся к прежнему плановому этапу и не являются
текущим запретом разрешённого продолжения. R6/G3 не переоткрываются; Gate6,
рабочая миграция и публикация workflow/fork/homes по-прежнему не выполняются.

## API-key acceptance в существующем G5 connection, 2026-10-26

Existing wire fixture проверяет UTF-8, Bearer compatibility и API key reread
в том же процессе; при обоих полях отправляется только `X-Api-Key`, transport
deadline прежний. Native key создаётся под тем же ordinary principal, exact
original/data/dataset IDs прежние. Fresh PM5 stdio должен прочитать original,
записать harmless auth marker, прочитать его из нового процесса и точно retire
без login/refresh или write replay. Server model/lookup не имеют TTL: это source
evidence, не live ожидание истечения часа. Ключ/пароль не входят в evidence.
Эта transport-проверка не добавляет новые paired случаи и не закрывает N7.

## Актуальная приёмка: common connection, 2026-10-26

[Обновлённый конечный G5](g5-qualification-plan.md) и
[сверка actual G4](g4-common-connection-alignment.md) имеют приоритет:
одно техническое подключение, шесть областей, без персональных grants/ACL,
outsider и административного writer. Scope/currentness/collision/restore pause,
секреты подключения и bounded whole-task cost сохраняются. Перед G5
никакой новый source gate не нужен; сейчас код/стенд не менялись и G5 не запущен.

Таблица Q ниже пересмотрена как критерии общего подключения. Датированные этапы
A–C и immutable evidence описывают **старую** ACL модель фактически выполненного
G1, не новые требования и не PASS пересмотренного G5. Они не переписываются.

## Конечный план G5, 2026-10-26

Существующие AC и задачи 6.2–6.4/6.6b сведены в
[G5 qualification plan](g5-qualification-plan.md): подготовка стенда/homes/прав,
N1–N7 и одна пара на каждую frozen B01–B12 (24 whole-task выполнения), actual
client calls/reload и explicit ready/block/stop criteria. Это будущая квалификация,
не новые результаты: G5, подготовка стенда и импорт корпуса не запускались.
Точный контрольный корпус сохранён; synthetic/home fixtures не объявляются
native semantic ranking или опубликованным registry mapping. Непроверенные
platform/client клетки и выпускной остаток отделены от конечного PM5-контура.

## G4: исходная реализация, 2026-10-26

Пользователь согласовал план и разрешил G4. Реализован scoped Cognee consumer:
шесть областей, exact-ID REST/stdio, cycle/continuation/pending/source, existing
registry/client/lifecycle owners и отдельный qualified fork candidate.
[Общая source-матрица и границы](evidence/g4-source-implementation-2026-10-26.md)
отделяют fixtures, native proof и регистрацию. G5, Gate 6, рабочая миграция и
публикация workflow не запускались и не разрешены. R6/закрытый G3 прежние;
отсутствие homes не обходится. Исторические запреты G4 ниже относятся к прежним
поручениям. Source checkbox разделов 2–5 не закрывают native/installed часть:
она остаётся в 6.2–6.4/6.6b. Регистрация определяется только RegisterChange/Status.


## Граница проверки плана G4, 2026-10-25

[План G4](g4-implementation-plan.md) использует прежние AC и frozen B01–B12;
новые native сценарии не добавлены. Q1–Q7 reused только для совпавшего exact
profile, source/owner fixtures относятся к G4, native frontend/installed/paired
proof 6.2–6.4/6.6b — к отдельно разрешённому G5. Контекст R6 опубликован,
но homes не назначены: shared-product canary ждёт подтверждённых home/IDs/grants.
При подготовке плана провайдер, стенды, tests и lifecycle не запускались;
документальная регистрация отдельно принадлежит штатному RegisterChange.

## R6: фактическая приёмка наполнения, 2026-10-25

Memory AC-44: registry population dependency CLOSED; native shared-product/G5 часть остаётся непроверенной, память не принята.
**Published SHA `0274a8ffb5a03ba7b856736c2b4a637ccbe98b73`**, восемь типовых проектов, 22+22 области,
owner approval, сохранённый publisher registry и 8/8 immutable contexts —
[единая квитанция](../add-product-project-registry/evidence/r6-publication-2026-10-25.md). Критерии ниже не ослаблены; это статус их
registry-only исполнения. R1–R5, G4/G5 и запрет Gate6/рабочей миграции/публикации
workflow сохранены. Новые native G3 сценарии не запускались.

## Актуальная граница G3 — согласована 2026-10-25

**G3 закрыт в принятом PM5 / Windows 11 / Kilo и Cursor контуре; Codex — только core/API.** [Единая итоговая матрица и остаток до выпуска](../add-product-project-registry/g3-acceptance.md) определяет текущий статус, приоритетный перед историческими записями ниже. Непроверенные клетки не стали PASS; заявленная поддержка сохранена. Полная выпускная квалификация отделена от закрытого G3. G4, Gate 6, рабочая миграция и публикация не разрешены.

[G3-LD1 / integrated native PASS, 2026-10-25](../add-product-project-registry/evidence/g3-legacy-executor-integrated-2026-10-25.md): после сохранения обеих сторон конфликта повторён исходный single PM5 downgrade source7ba9→oldfa0, exit0/381883мс; main+sibling clean, old helper/pins0.4.15/schema1/locked, pending0 и CF/DB/history unchanged. Два downgrade blocker закрыты. Новых cases нет; регистрация отдельно подтверждается source-delivery Status. Full G3/AC18/39 и memory AC43/G5 открыты; OpenCode SKIPPED, Gate6/G4/рабочая миграция/публикация вне допуска.

[Промежуточный mode repair до migration handoff, 2026-10-24](../add-product-project-registry/evidence/g3-managed-downgrade-mode-partial-2026-10-24.md): legacy wire/environment/argument исправлены, 97/0/0/0 owner tests. На той же PM5-копии direct downgrade прошёл прежнюю mode error, но exit1/87125мс на **G3-MANAGED-DOWNGRADE-AI-RULES-NOT-NEWER**; snapshot 400b27db91cc4fdb80a81e70a998ad29 сохранён. Named downgrade/G3/AC-39/memory AC-43/G5 ещё не приняты. Текущие процессы завершены; новые проверки/регистрация/lifecycle отложены на согласованное пользователем окно холодного A/B. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[Исходный lifecycle PM5 до mode repair, 2026-10-24](../add-product-project-registry/evidence/g3-pm5-lifecycle-2026-10-24.md): новая отдельная capsule-копия прошла first unattended old-caller update (322555мс), поздний list/preview/select, отказ несовместимому пакету и restore-compatible. Actual downgrade FAIL: **G3-MANAGED-DOWNGRADE-DEPENDENCY-MODE**, старый post-copy не принимает mode=workflow. Snapshot/copy сохранены, recovery status работает только как диагностика. Fork остановлен до Gate6/создания worktree; full G3/AC-39 не принят. Исходный current PM5 сохранён. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[Функциональные изменения каталога на current PM5, 2026-10-24](../add-product-project-registry/evidence/g3-project-metadata-functional-2026-10-24.md): 10/10 public commands в итоговом наборе; rename, typical/custom, СППР/Mantis links и functionality/home add/change/remove применены без client writes. Exact teardown 46/46, DB/старые roots/capsule сохранены. Новых workflow defects не найдено; полная G3/AC-39 и memory consumer/G5 не приняты. Warm excess принят пользователем; OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[G3 publisher-only/offline repair и повтор стоимости, 2026-10-24](../add-product-project-registry/evidence/g3-publisher-cost-repair-2026-10-24.md): две причины исправлены в existing context/journal owner, 101/0/0 tests и exact installed PM5 repeat; 20 пар/режим, paired delta median **1.170 / 4.002 / 1.494 с**. До/после не является чистой оценкой ускорения на общем занятом ПК. Дополнительные 20 full-window no-op дали **1049.731/1240.7921мс**: median goal1000мс превышена на 49.731мс, p95 goal2000мс выполнена; По решению пользователя от 2026-10-24 G3-PM5-WARM-STARTUP-MEDIAN закрыт как ACCEPTED DEVIATION: добавочные 49.731мс допустимы и не блокируют завершение G3; диагностика/оптимизация и повтор ради этого порога не требуются. Фактический результат относительно цели остаётся неизменным. Полная G3/AC-39 не принята. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[Парная стоимость динамических режимов PM5, 2026-10-24](../add-product-project-registry/evidence/g3-paired-dynamic-cost-2026-10-24.md): 20 AB/BA пар на режим, 120 observer-off samples; paired delta median publisher-only / endpoint / offline **6.206 / 10.544 / 3.801 с**.80 online samples с дополнительной сменой origin URI сохранены отдельно и заменены полным fixed-URI повтором; offline 20 пар retained. Endpoint G3 обновляет два клиента против одного legacy; offline legacy сохраняет подключения без full sync. Измерительный пробел B5 этого subset закрыт, существенная задержка и полная cost/G3/AC-39 приёмка остаются открытыми. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[Остаток G3 на текущем PM5, 2026-10-24](../add-product-project-registry/evidence/g3-remaining-qualification-2026-10-24.md): Codex core/API прошёл 11 реальных вызовов Code/Graph, включая полезные чтения, отказ для чужого проекта, reload и новую сессию без запуска модели. Три режима Startup прошли функционально; диагностические окна 5,426 / 6,896 / 3,532 с не являются парным замером добавочной стоимости. Матрица 39 AC и 12 клиентов обновлена: Kilo/Cursor сохраняют прежний pass, OpenCode — SKIPPED. Полная registry G3/AC-39 остаётся непринятой; точный остаток B1–B5 указан в отчёте. Сохранность стенда и истории подтверждена. Gate 6, G4, рабочая миграция и публикация не выполнялись.

[Нативные клиенты на текущем PM5, 2026-10-24](../add-product-project-registry/evidence/g3-pm5-native-clients-2026-10-24.md): Kilo 7.8.15 / VS Code 1.142.0 и Cursor 3.27.12 выполнили по четыре реальных чтения Code/Graph до и после Reload Window. OpenCode 1.19.3 сохранил PM5-контекст и подключения после renderer reload, но квота модели заблокировала вызовы инструментов: **G3-OPENCODE-PROVIDER-QUOTA** [пропущен по решению пользователя](../add-product-project-registry/evidence/g3-opencode-skip-2026-10-24.md) в текущем прогоне; это не PASS и не устранение квоты. Смена версии первого Cursor и автоматические записи клиентов учтены отдельно; окончательная сохранность 46 путей, базы и истории подтверждена. Полная registry G3/AC-39 остаётся непринятой. Gate 6, G4, рабочая миграция и публикация не выполнялись.

[Стоимость G3 и baseline, 2026-10-24](../add-product-project-registry/evidence/g3-cost-baseline-2026-10-24.md): сопоставимый current-package legacy unbound baseline подготовлен; 20 AB/BA блоков, 100 retained samples + 4 warmups. Полный Startup median/p95 **0.995591 / 1.168819 с**, цель 1/2 с выполнена; paired whole CLI без профилировщика **0.548018 / 1.428991 с**. Запас median всего 4.408850 мс, устойчивый SLA <1 с не доказан. Прежнее превышение6.314 мс не округлено в pass, подробные phase probes отделены от benchmark. G3-B5 закрыт для сопоставимого warm no-op PM5 subset; полная G3/AC-39 остаётся BLOCKED по остальным клеткам. Ниже сохранены исторические результаты; новую стоимость определяет этот отчёт. Gate6/G4/рабочая миграция/публикация не выполнялись.

[Итоговый прогон G3](../add-product-project-registry/evidence/g3-completion-2026-10-23.md): доступный current PM5 subset завершён; **полная G3/AC-39 BLOCKED** по G3-B1–B5. Два owner-local repairs прошли 132+12 source tests и installed repeat `dfae2ff3`; 90 config calls + update. Настоящие conflict answers/Ctrl+C, pending stable ID, damaged-applied owned recovery и transport 7,933/7,836 с подтверждены. Warm full median/p95 1,006314/1,353585 с: median goal остаётся недостигнутым, без округления/повтора ради pass. Gate 6, G4, рабочая миграция и публикация не выполнялись.

Актуальная установленная зависимость реестра — [единая итоговая матрица G3](../add-product-project-registry/evidence/g3-final-qualification-2026-10-20.md). Registry AC-39 и memory installed AC-43/G5 открыты; native G1/Q1–Q7/D9/G2 не переоткрываются. Release population AC-44 использует один результат registry AC-36–38. Эта консолидация не запускает G4, Cognee или миграцию рабочих проектов.

## Статус и область

Это план будущей managed приёмки и результаты native этапов A–C 2026-10-19. По поручению «иди по плану» этап C подтвердил пересмотренные Q5/Q7 на isolated Cognee/dev-karimov; G1 пройден для точного local profile с явным reuse неизменных Q1–Q4/Q6. Исходный Q5 failed/старый Q7 partial-unverified и их evidence сохранены. Files-only baseline подготовлен; paired G5 не запускался. Этапы A–C не меняли managed память/реестр/controlled fork/рабочие базы и production MCP. D9 отдельно одобрен пользователем; G2 interface реализован и прошёл pure consumer qualification по registry test-plan. Последующие source G3 и отдельно разрешённое обновление трёх MCP 2026-10-20 принадлежат registry owner; текущая зависимость описана в последнем разделе. Память G4 явно запрещена; native server proof не заменяет installed AC.

Архитектура — [design.md](design.md), требования — четыре delta specs, основание dependency и версий — [context-sources.md](context-sources.md). Ни один тест не требует рабочего customer corpus или записи в production SPPR/Mantis. Live Cognee canary выполняется только в отдельно разрешённом экземпляре с harmless уникальными фактами и точечной очисткой разрешённых test artifacts.

## Проверки Cognee до разработки памяти

Это обязательный native допуск G1 перед зависимым G4, а не написание ITL adapter. Отдельный запрос native проверки разрешён 2026-10-19; actual execution и blockers приведены ниже. Использовать выбранный harmless instance/corpus и штатные MCP/SDK/REST. Зафиксировать version/image digest, API mode/live schema, models/embedding, пользователей/grants/dataset IDs, expected/actual bounded output и passed/failed/unverified каждого Q. Config/tools-list/fixtures не являются native proof.

| ID | Что выполнить до зависимой разработки | Достаточное native доказательство |
|---|---|---|
| Q1. Shared IDs/connection | Под общим техническим подключением подготовить один dataset; два процесса читают/пишут exact ID | Один original/dataset ID, без label collision/дублей; exact-ID native путь. Отдельные accounts/grants/outsider не требуются |
| Q2. Контекстный отбор | Одинаковые имена/связи в разных datasets; запросить текущий context, затем явно посторонний context ID | Dataset subset ограничен до retrieval/graph; нет нерелевантных фактов из соседнего контекста. Это маршрутизация, не backend секретность/ACL |
| Q3. Durable/status | Записать уникальный факт, проверить data/dataset ID, durable/indexing; прочитать fresh session; воспроизвести потерю ответа/timeout | Original/receipt можно адресовать, durable отделён от pending indexing/unknown; точный status lookup предшествует retry, нет слепого дубля или fallback write |
| Q4. Original/current revision | Сохранить факт и исправить/retire; получить старый fragment без header и без correction в semantic hits | По стабильному ID штатно читаются original/envelope и authoritative current status/correction независимо от top_k. Нет ID/API/proof — failed/unverified, не собственная versioning БД и не текстовая supersedes гарантия |
| Q5. Retirement/restore | Точное correction/delete; приостановить common connection, native restore к T, проверить originals/известные поздние изменения → допустить проверенные scopes и fresh context | Чужие записи/dataset не удалены; T/интервал потери явны. Нет обязательного grants/revoke/outsider/ACL rollback proof, нового backup/versioning сервиса или hidden rollback detection. Старая ACL qualification историческая |
| Q6. Bounded retrieval | Получить ограниченные CHUNKS с исходными IDs, проверить raw cap отдельно от final selection; корпус с применимым фактом ниже первых восьми | Native отдаёт достаточный bounded набор кандидатов для чистого отсева до agent context, без генерации сводки. Начальный профиль 24 candidates/8 cards/1600 tokens проверяется далее в adapter; нет выдуманного metadata filter или необходимости неограниченного поиска |
| Q7. Ingestion/cost profile | Подтвердить live self_improvement=false и native ingestion/graph, модели/параметры/ограничения и воспроизводимые измерения всего контрольного прогона | Calls/errors/retries/context/latency и доступный native/provider usage сохранены без повторного счёта; для локальных моделей есть CPU time/peak RAM/wall time прогона. Estimates/unknown явны, счётчик каждой внутренней операции не обязателен. Существенные расходы/ограничения платного профиля подтверждены либо требуют отдельного решения. Полный paired эксперимент и заявления об экономии — G5, не критерий native Q7 |

### Предварительное обследование 2026-10-19

Run `cognee-q1-q7-20261019-a8bd3718`. **Этап A, до выбора host:** пользователь подтвердил отсутствие тестового экземпляра. Выполнены только read-only local preflight и чтение опубликованного wheel как ZIP/AST, без импорта/исполнения Cognee; native операций на этом этапе — 0. Таблица ниже сохраняет историческое состояние этапа A; актуальный результат этапа B приведён далее. Отсутствие первоначального стенда не было failed проверкой Cognee.

| Проверка | Фактический результат | Статус |
|---|---|---|
| Q1 | Нет live instance, тестовых users/grants и shared dataset ID; функциональный read/write не выполнялся | unverified — B01 |
| Q2 | Нет экземпляра/datasets для collision и scope proof; native retrieval не выполнялся | unverified — B01 |
| Q3 | Нет native write/data ID/status/fresh-session read или timeout reproduction | unverified — B01 |
| Q4 | В candidate wheel найден REST маршрут точного original read `/{dataset_id}/data/{data_id}/raw`; authoritative current revision/retirement и live operation не проверены | unverified — B01; source finding не acceptance |
| Q5 | Тестовый backup/revoke/restore не выполнялся, native consistency не установлена | unverified — B01 |
| Q6 | CHUNKS/source IDs/candidate cap не проверялись на backend | unverified — B01 |
| Q7 | Профиль ingestion/models/embedding и usage/latency не выбран/не измерен; неизвестные costs не ноль | unverified — B01/B03 |

Исторические blockers этапа A:

- **B01 — отсутствовал target instance; закрыт этапом B.** Пользователь отдельно поручил Docker deployment на dev-ermakov или dev-karimov; выбран dev-karimov, выделены native test identities/данные.
- **B02 — локальный Docker-вариант сейчас не готов.** Найден Docker CLI `29.5.3`, context `desktop-linux`, endpoint `npipe:////./pipe/dockerDesktopLinuxEngine`; `docker version` завершился exit 1: named pipe отсутствует. Docker daemon не запускался. Это не обязательный blocker Python/другого host и не ошибка Cognee.
- **B03 — provider/profile был pending; setup закрыт этапом B.** На клиентском ПК не обнаружены отдельные provider variables/Ollama; это не было обследованием иных hosts. Выбран native CPU GLiNER/fastembed без платных API keys. Его функциональный профиль проверен; исходный пробел accounting — исторический B05, текущая достаточность Q7 требует нового proof ниже.

Кандидат для временного Python-стенда: Python `3.13.13` доступен; `cognee` в нём не установлен. По [PyPI metadata 1.6.5](https://pypi.org/pypi/cognee/1.6.5/json) загружен только wheel `cognee-1.6.5-py3-none-any.whl`, SHA-256 `aaef9fdc02f542b1d125cde21759dde2fac56355d8928e39c734e7b5c6705eca` совпал. Это **candidate version**, не live profile. Source inspection также нашла shared permission/precise deletion routes; их существование не доказывает права/изолированность/исправления на работающем экземпляре.

Локальные evidence этапа A: [preflight-evidence.json](C:/Users/xment/AppData/Local/Temp/cognee-q1-q7-20261019-a8bd3718/preflight-evidence.json), SHA-256 `a1427cc4e3c99dce8153a96ad8556ceadd3b6673413a3712ba971f2069fd938a`; рядом `preflight-profile.json` и проверенный wheel. Они не подменяют последующее native proof.

#### Этап B — Docker deployment и фактические native Q1–Q7

Пользователь разрешил выбрать один из двух dev hosts. Выбран Linux Docker host `itl-mcp-karimov` через существующий SSH profile `dev-karimov-mcp`: при обследовании около 8.2 GiB available RAM и низкая CPU load, без необходимости запуска Docker Desktop на dev-ermakov. Существующие семь MCP containers, их IDs/images/StartedAt сохранены; общий registry/watchdog/client config не менялся. Стенд не зарегистрирован как managed MCP и не объявлен installed integration.

| Параметр | Фактическое значение |
|---|---|
| Stand / data | `itl-cognee-qual-20261019-a8bd3718`; `/home/mcp/itl-qual/cognee-q1-q7-20261019-a8bd3718/data` |
| Доступ / isolation | Native REST `http://127.0.0.1:18190` только на remote loopback, доступ через SSH; user uid 1000, cap-drop ALL, no-new-privileges, 2 CPUs/5 GiB, restart=no. Credentials/env mode 600, не в Git/evidence export |
| Package / image | Cognee `1.6.5`, Python `3.12.15`, image `sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`; wheel SHA выше. Собственный deployment image использует неизменённый wheel и native extras, provider source patches — 0 |
| API / storage | Live OpenAPI SHA-256 `b863f72d912c07ceb4bb914d790152659427c0ad33863d553d38b5fa64e24171`; REST API info version `1.0.0` отличается от package version. SQLite relational + Ladybug `0.19.0` graph + LanceDB `0.39.0` vector |
| Extraction / embedding | Native `GRAPH_EXTRACTOR=gliner_demo`, GLiNER2 `2.1.0`, torch `2.14.1+cpu`, model `fastino/gliner2.5-base-v1` revision `54785d51df8d86a0d8f2eb212fec15871aad2c4d`; fastembed `0.8.0`, `BAAI/bge-small-en-v1.5`, 384 dimensions, ONNX revision `aa8f8b060edb00e03bfdd08813a2949946c8ba55`. Это профиль qualification, качество русского/BSL и production модель не приняты |
| Auth / users | `REQUIRE_AUTHENTICATION=true`, `ENABLE_BACKEND_ACCESS_CONTROL=true`; owner `fb61b1da-b315-49e3-8088-c37c01b94881` superuser только для provisioning; A `900a1b77-b229-48e8-9953-d75d1fc8edf2`, B `95d63faf-2dcb-4caa-9805-cd83b9e82282`, outsider `810fd9da-1acf-42e5-9e90-03b3fe6d34ad` имеют native `is_superuser=false`. Запись/чтение выполнялись их собственными токенами |
| Dataset IDs / corpus | Shared `6fc46971-b3bc-5a69-9fe2-d50406be5bee`; private A `a5b8c8b0-7b89-5b2f-b335-7b01279e6e7e`, private B `41a2c0f0-931b-5952-a4c4-9cc53925a208`; bounded `f90fa634-d3be-51f2-9465-4565ccd030c0`. Только уникальные harmless robot/marble/ProjectAtlas facts: 3 shared + 2 private + 26 bounded originals до retirement |

Следующая таблица и исходный qualification-result фиксируют **первоначальную редакцию Q5/Q7**. Согласование новых требований не меняет эти результаты; актуальный протокол и непроверенный допуск — в отдельном уточнении ниже.

| Q | Expected → actual native evidence исходного прогона | Исторический итог |
|---|---|---|
| Q1 | A/B с read+write сделали `remember(datasetId=<один shared UUID>)` → completed/200, B прочитал обе заметки. Native `/users/me` подтверждает ordinary principals; inventories не содержат private одноимённых shared дублей. Outsider read/write → 403 | **passed**, `bootstrap.json`, `shared-write-read.json`, `native-users-rest-audit.json`, `denied-writes.json` |
| Q2 | Private datasets с одинаковыми именами и SharedRobot/HarbourLab entities → своё CHUNKS/graph 200, чужие recall/graph/write 403. В каждом графе 15 nodes, ноль противоположных sentinel facts; trace отказа идёт через native permission check до graph access | **passed**, `private-collision.json`, `native-graph-isolation.json`, `graph-isolation-summary.json`, native log |
| Q3 | Accepted request: headers 200 получены, body с receipt намеренно потерян. Немедленный listing ещё без записи, aggregate status отражает предыдущий completed run — это не доказательство исхода новой операции. Без replay после сверки найден ровно один original `fe9a241f-9f37-4dac-a31a-cd84d6487156`, processing completed, fresh client после container restart читает факт. При OOM отдельно сохранены 26 durable rows и `cognify STARTED`, возобновлён только native cognify | **passed в этом корпусе**, `lost-accepted-first.json`, `lost-accepted-reconciled.json`, `*-after-restart.json`. Aggregate dataset status не является operation receipt; отрицательный/неполный lookup остаётся unknown, не повод replay |
| Q4 | Write-only shared update дал 401: native update требует **write+delete**. После native grant delete обычному A точный PATCH → 200/incremental, тот же data ID `4601ca86-64a2-4b65-92c2-dd109f553f71`. Raw по ID вернул silver revision вместо amber, hashes различны. Проверка использовала сохранённый excerpt старого chunk без header и его source IDs; correction в semantic hits не запрашивалась | **passed для current original при данном состоянии store**, `correction.json`, `late-native-changes.json`. Это не full historical version API и не защита от rollback всего store (Q5) |
| Q5 | Stopped filesystem backup → поздние PATCH/forget/revoke. Удалён один data ID, raw 404; другой original 200; B data/recall/raw 403. Restore старого backup → B data/recall **200**, удалённый original **200**, исправленный original снова **amber**. Native source lookup тоже откатился и не обнаружил поздние изменения | **failed — B04**, `native-backup.json`, `late-native-changes.json`, `native-restore.json`, `after-native-restore.json` |
| Q6 | На 26 originals CHUNKS `top_k=24` → 24 results с `metadata.data_id/chunk_id`; top 8 → 8. ПРОФ-факт находится на позиции **17**, попадает в cap 24 и отсутствует в первых 8. `only_context=false` сохраняет IDs; true склеивает текст без provenance. CHUNKS остаётся non-generative, false здесь не включает LLM summary | **passed для native feasibility**, `bounded-retrieval.json`. Adapter selection 8 cards/1600 tokens и exact ninth fixture AC-36 ещё не реализованы/не приняты |
| Q7 | Live schema принимает `self_improvement=false`; native add/cognify и GLiNER graph работают, в сохранённом логе нет improve task starts. Есть native pipeline usage, calls/latency и model identity. Однако incremental-update usage остаётся null; полнота per-operation extraction/retrieval/update accounting не доказана | **unverified — B05**, положительный functional proof flag/graph отдельно от полноты cost |

**Исторический B04 — конфликт исходной гарантии restore с native профилем.** Обычный stopped backup откатывает ACL/content вместе. Backup SHA-256 `d7e7f28f5861ff3177e4d1cf6266afc6108e4293896e7fff1203d8324eff4217`, 1,652,366 bytes; исключён только derivative model cache, relational/raw/graph/vector state включён. Это корректно выполненный тест старой копии, а не ошибка восстановления или доказанный дефект Cognee. Исходная гарантия D5/AC-27/34 не выполнена, failed результат сохранён. Текущим запросом согласован иной контракт: административный допуск после восстановления с явным интервалом потери. На момент уточнения его native proof отсутствовал; последующий этап C подтвердил административный допуск без versioning/IAM/backup service или post-filter. Отсутствие иных native recovery методов исходным тестом не доказано.

После отрицательного теста вручную возвращено ранее сохранённое quiescent post-change состояние. Fresh REST: B read 403, удалённый original 404, current original silver/200. Это завершение тестовой операции и сохранение позднего состояния, **не автоматическая защита от старого restore**. Старое восстановленное состояние сохранено отдельно для evidence; native backup не содержит рабочих данных.

**Исторический B05 — неполная детализация native accounting.** Сохранены actual calls/elapsed и terminal pipeline records: cold remember 43.808 s, warm remember 3.511 s; native resume 26 originals с batch 1 — 103.766 s, reported `embedding_tokens=8919`, LLM in/out=0; incremental update 38.925 s, его usage null. Parent/child и started/completed одного run не складываются. Ноль reported LLM tokens не означает бесплатную CPU extraction/embedding; отсутствующие usage/monetary категории остаются unknown. В уточнённом Q7 null конкретной внутренней операции сам не blocker: нужен воспроизводимый прогон с ограничениями и достаточными calls/context/latency/CPU/RAM измерениями всего профиля. На момент уточнения повторный прогон ещё не выполнялся; его отдельный результат — этап C. Agent inputs/cached/repeated context и files-only comparison остаются G5; исторический unverified не переименован в passed.

Технические условия теста сохранены отдельно. Первое wheel staging было неполным и исправлено SHA-verified повторной загрузкой до успешной сборки. Profile revision 1 с `ACCEPT_LOCAL_FILE_PATH=false` дал 415 при чтении внутреннего сохранённого файла; rows не создал, профиль изменён на true только внутри isolated loopback container, telemetry отключена штатной переменной. При совместных batch indexing и дополнительном SDK diagnostic process контейнер достиг cgroup 5 GiB: OOMKilled/137. После restart сверены 26 durable rows, native cognify повторён с batch 1 без повторного add; он completed. Это инфраструктурный interruption данного запуска, не failed isolation или доказательство production sizing. Первые status calls с ошибочным `datasets=` не засчитаны: live schema требует `dataset=`, corrected exact-scope calls сохранены. Первый закрытый до headers запрос остался unconfirmed и не replayed; Q3 засчитан по отдельному accepted-request/body-loss сценарию.

Существенные результаты находятся в этой OpenSpec; полные sanitized evidence скопированы в [qualification-result.json](C:/Users/xment/AppData/Local/Temp/cognee-q1-q7-20261019-a8bd3718/evidence/qualification-result.json), SHA-256 `ad2b8796e52fcef98e503f4775dd45277c35e63b03fc16f4d71744025d73971b`, и соседние native responses/logs/profile/probes. [evidence-manifest.json](C:/Users/xment/AppData/Local/Temp/cognee-q1-q7-20261019-a8bd3718/evidence/evidence-manifest.json), SHA-256 `c4c95e623bf580a46b84c2ba161aeaa633cd4a5eb8a9179a3a035e4ba5f7c903`, фиксирует hashes 52 evidence/source файлов; private credentials/env/backup в export не включены. Primary remote evidence — `<stand root>/evidence/`. Временное расположение не заменяет сохранённые здесь expected/actual и blockers.

На завершении исторического этапа B были выполнены только 1.3/1.5; новые Q5/Q7 ещё не квалифицировались. Их последующий proof и текущая граница G1/G4 приведены в этапе C ниже. Исходный qualification-result не переписан; native протокол не реализует managed runtime/lifecycle/registry/fork.

#### Согласованная редакция Q5/Q7 — протокол этапа C

Q5 повторяется на harmless stand со старой копией и теми же типами поздних изменений. **До restore** клиентский доступ к памяти закрыт. После восстановления к T администратор фиксирует дату/интервал потери, заново подтверждает актуальные grants независимо от ACL копии, повторяет известные поздние correction/delete/revoke через native API и получает current original/404/deny. Восстановление старых значений внутри закрытого stand допустимо; допуск клиента до сверки — failure. Отдельный случай с неподтверждаемыми поздними изменениями оставляет затронутую область недопущенной, не отключая независимый workflow. Native административная процедура проверяется в G1; исключение недопущенных областей binding, cache reset/new context и невозможность использовать старый кеш/fallback — owner fixtures и installed G5. Полный журнал всех ревизий, собственный restore-реестр/epoch и обнаружение скрытого rollback не требуются. Исходный Q5 failed не меняется; **новый Q5 прошёл native административную проверку этапа C**, client enforcement остаётся G5.

Q7 повторяется на фиксированном version/model/settings profile с native `self_improvement=false` и прежними ограничениями вызовов/контекста/сроков/ресурсов. Сохраняются calls/errors/retries/context/latency, доступный native/provider usage с источником и без parent/child/events double count. Для локального профиля дополнительно фиксируются CPU time, peak RAM и wall time **всего прогона**, включая ingestion/update/retrieval/source-status этапы. Детализация расходов каждого внутреннего вызова необязательна; `measured`, `estimated` и `unknown` разделены. Непроверяемые существенные расходы/ограничения платного профиля требуют отдельного решения. Новый tracing service, provider patches и постоянный per-call мониторинг не нужны. Достаточный accounting подтверждён **Q7 passed на этапе C** для этого local profile; G5 отдельно проверяет paired пользу и каждое количественное заявление об экономии.

G4 допускается после passed Q1–Q7 действующей редакции и qualified G2 interface; изменение expected не является proof. Неизвестная внутренняя детализация при достаточном Q7 учёте сама не блокирует G4, но непройденные Q5/Q7 и нарушения безопасности блокируют. Смена instance/version/auth/retrieval semantics требует сверки затронутого proof, не probe каждого startup. Реестр независим; installed canary/paired comparison остаются G5. Само документальное согласование не разрешает apply или новый native прогон; этап C выполнен по последующему отдельному поручению «иди по плану».

#### Этап C — повторная квалификация и frozen baseline

По следующему поручению пользователя «иди по плану» выполнен run `cognee-q5-q7-r2-20261019T094637Z-b4127852`. Образ `sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`, OpenAPI hash этапа B, auth settings и три model revisions совпали до/после; provider code не менялся. Native Q1–Q3/Q6 reuse опирается на их прежний exact proof при этих identities, Q4 дополнен точным update/raw обычного A. Это не запуск уже зелёных неизменных проверок повторно и не установленный MCP canary.

| Проверка | Expected → actual этапа C | Статус/граница |
|---|---|---|
| Q5, проверенная область | Перед restore normal client port `18190` закрыт; admin API только на remote loopback `18191`. Старый snapshot действительно вернул прежние права/факты внутри закрытого stand. Актуальные grants заданы по synthetic admin approval, известные correction/delete/revoke повторены native API; до допуска и свежим клиентом после него: current raw200, deleted raw404, untouched raw200, B read/recall403 | **passed native admin admission**; dataset `c59847ce-8c95-5a64-a789-dcfae9ecd80b`, `q5-verified-before-admission.json`, `q5-after-admission-fresh-client.json` |
| Q5, неизвестная область | Поздняя актуальность другой области не подтверждается: read A/B/outsider403, recall A403, write A403. Она остаётся недопущенной после возврата normal port; независимый private raw200 и read-only `source-openspec status` завершились | **passed native quarantine case**; dataset `90046386-baf0-5bae-90ab-45a0be26ac2b`. Client scope exclusion/cache reset/new chat и успешность установленной исходной задачи — G5, здесь не приняты |
| Q7, весь ограниченный local profile | Свежий контейнер того же образа: startup → 3 harmless originals/remember → precise update → один structured CHUNKS → raw/status/graph/usage. `self_improvement=false`, native GLiNER graph; initiated improve task starts — 0. Измерены calls/content bytes/latency, cgroup CPU/RAM/wall; counters не сложены parent/child/events | **passed revised Q7**; `q7-whole-run-resources.json`, `q7-client-metrics.jsonl`, `q7-all-http-accounting.json`, native graph/activity |

Q5 backup: quiescent native state, только derivative model cache исключён; SHA `75eac9a71ff71c157dabd1afa89819f53e039d9807de2d36186ef8e495b26748`, 1,912,859 bytes. Явный консервативный интервал возможной потери: **2026-10-19 09:52:38.519884 → 09:55:20.548694 UTC**; известные поздние события и восстановленные значения сохранены отдельно. Synthetic approval/state файлы — входы одноразового canary, не новый runtime журнал/реестр. Дополнительный native ACL-list endpoint в tenantless profile вернул `TenantNotFoundError/404`: это не скрыто, tenant не создан; proof опирается на ACK grants/revokes и actual-principal allow/deny. Один переход отложен занятым host maintenance lock до изменения контейнера и продолжен после освобождения; guard не обходился. Все технические отклонения сохранены в evidence.

Q7 whole-run: **CPU time 46.486933 s; peak 3,368,210,432 bytes (3.137 GiB); wall time 37.443 s** при 2 CPU/5 GiB. Peak взят из `memory.peak` свежего cgroup и вырос внутри измеренного окна; включает память/page cache контейнера, не только RSS процесса. CPU — delta `cpu.stat`; startup и все data операции вошли в окно. Сохранены 12 основных API calls + 1 login, отдельно 7 readiness attempts (6 ожидаемых отказов до startup), ноль failed data calls/слепых write retries. Native terminal cognify сообщает `embedding_tokens=754`, LLM in/out=0 этого local profile; incremental update usage по-прежнему null. Его детали, GLiNER internal tokens, monetary allocation и будущие agent/cached/repeated-context costs не объявлены нулём. Full paid-profile qualification, русский/BSL quality и экономия не доказаны этим canary; paired сравнение — G5.

Files-only baseline **подготовлен, не исполнен**: 37 synthetic notes в шести типах scopes, 12 tasks B01–B12, отдельные evaluator-only expected results, одинаковые deterministic checkpoint/private pending inputs, frozen protocol. 43 payload hashes проверены локально и на сервере; baseline manifest SHA `b0cc2bcf94e06e7f6c504c0243c41af6e5f8e280d88a4ec2dade523d1f66ec3b`. Expected results не передаются оцениваемому агенту, full master corpus не даёт доступ к foreign scope. Ordered B09 fixture проверяет отбор девятого кандидата, не выдается за native semantic ranking. Это corpus/protocol для обоих будущих вариантов до managed retrieval tuning; в Cognee этот corpus ещё не импортирован, retrieval engine/adapter/evaluator runtime не написаны.

Результаты: [qualification-result-r2.json](C:/Users/xment/AppData/Local/Temp/cognee-q5-q7-r2-20261019T094637Z-b4127852/evidence/qualification-result-r2.json), SHA `be8219d1d090343f2d7deebace513b77d5aa7a322e353f10b9f3324d7048582d`; [evidence-manifest.json](C:/Users/xment/AppData/Local/Temp/cognee-q5-q7-r2-20261019T094637Z-b4127852/evidence/evidence-manifest.json), SHA `cf970f120cf8a01b1a212bd2bcf05a88cf3e77ec49e73c0e207ad0c7e8cd364d` (38 evidence/probe files). [Baseline protocol](C:/Users/xment/AppData/Local/Temp/cognee-q5-q7-r2-20261019T094637Z-b4127852/files-only-baseline/protocol.json) и manifest рядом. Primary durable copies — `/home/mcp/itl-qual/cognee-q1-q7-20261019-a8bd3718/runs/cognee-q5-q7-r2-20261019T094637Z-b4127852/{evidence,files-only-baseline}/`; credentials/env/native backups в export не входят.

**Текущая граница:** native G1/AC-38 для этого exact local profile подтверждён, подготовка 1.4 и native 1.6/1.7 закрыты. Это не принятие всего AC-27/37 или G5: managed client/cache/context/исходная установленная задача/paired gain ещё не проверены. G4 не начинается без qualified G2 interface и checkpoint D9 (1.1/1.2 остаются открытыми). Семь прежних MCP containers сохранили ID/image/StartedAt; normal loopback `18190` работает, admin `18191` закрыт. Изменялись только изолированный test stand, evidence и planning docs; implementation/controlled fork/production config/1C базы не менялись.

## Критерии

| ID | Проверка | Наблюдаемый результат / evidence |
|---|---|---|
| AC-01 | По одному harmless факту каждой из шести областей | Native datasets/IDs и read scope подтверждены; fresh session возвращает правильный факт, без обязательных копий/предсоздания пустых private datasets; shared области подготовлены через то же common connection. |
| AC-02 | Две задачи/workspace одного проекта, одноимённые объекты | Один common account; текущая задача не запрашивает соседний context. Проверяются native request dataset set и graph выдача, а не только итоговый response filter; пользовательская конфиденциальность не заявляется. |
| AC-03 | Пропущенный и явно чужой dataset | Пропуск получает bound allowlist; чужой dataset отклонён до backend. Ни одного unscoped запроса. |
| AC-04 | Shared exact ID и owner collision | Два процесса общего подключения используют один подготовленный native ID/owner; label другого owner не подменяет его. Нет поиска по всем datasets, отдельных grants/аккаунтов или personal дубля. |
| AC-05 | Рабочее место и перенос workspace | Новая RDP session не создаёт новую identity; другой ПК — иной workplace, тот же developer. Rename/явный перенос не меняет workspace; независимая копия получает новый ID. |
| AC-06 | Неизменность провайдера и доступы | Exact Cognee version/image digest и schema записаны; штатный API и явный common ordinary account, без personal ACL/custom source/SQL/graph pipeline. |
| AC-07 | Реальная запись → статус → новый сеанс | Различены durable, pending indexing и failed; fresh reader находит уникальную заметку только после готовности. Конфигурация/tools list не считаются proof. |
| AC-08 | Timeout после принятия/до ответа и restart клиента | Receipt сохраняется; штатная сверка предшествует retry/fallback. Один логический факт не получает слепую вторую копию; неизвестный исход явно unconfirmed. |
| AC-09 | Исправление и точечное удаление | Поддерживаемый native original/current-status lookup доказывает актуальность независимо от semantic hits; один supersedes в тексте недостаточен. Precise retirement не удаляет dataset/другие заметки. |
| AC-10 | Новый чат продолжает задачу при недоступном search | Прямое чтение даёт цель/ограничения/следующий шаг; проверка и runtime state читаются у прежних владельцев. |
| AC-11 | Reset базы без изменения HEAD | Новый cycleId, прежний task dataset отсутствует в обычном backend scope, общие знания остаются; исходный пользовательский reset успешно завершён. |
| AC-12 | Interrupt/resume reset в разных фазах | Один выделенный pending ID, один activation; нет дополнительного контроллера, ручной правки lock/state или обязательного Cognee roundtrip. |
| AC-13 | Поздний old-chat remember после reset | Old-bound запись остаётся исторической либо получает stale-context continuation; новый цикл не загрязнён. |
| AC-14 | Pending заметка и reset | Локальная запись вне reset tree сохраняет старую область и status; возобновление backend не переносит её в новую задачу. Dirty-state guards не ослаблены. |
| AC-15 | Переименование project/endpoint и выбранный profile | Стабильные business IDs и память сохраняются; optional profile не требуется для каждой версии; один applied SHA/hash. | Проекция различает current project/base product/customizations и source origin/назначение/registry version; переименование не заменяет stable IDs сведениями источника.
| AC-16 | Startup автообновление/override/conflict/defer/offline | Existing owner применяет изменения один раз, сохраняет override и решает конфликт. При defer остаётся валидный current local с ручной правкой на прежней catalog revision, без отката к applied baseline/записи нового mixed плана. Диагностика/recovery доступны. |
| AC-17 | Обновлённые client settings, ещё старый tool catalog | Новый binding не объявляется активным до штатного reload; зависимый вызов имеет продолжение, прежние External MCP сохранены. |
| AC-18 | Области КОРП/ПРОФ и ERP-зависимость | Только подтверждённая knowledgeArea допускает повторное использование; вырезанная функция/отсутствующий компонент исключены. Версия неизвестна → нужна проверка. |
| AC-19 | Вывод из внешнего проекта | Без evidence независимости от customer customization он остаётся локальным/project candidate; новый general mapping требует подтверждения. Известное правило не требует ручной разметки каждого факта. |
| AC-20 | Изменение availableIn/home и доступов | Новая ревизия видна, old evidence не становится новой проверкой. Смена/удаление home не переносит/копирует/удаляет заметки или расширяет read set; историческая привязка сохранена, полнота поиска после смены home остаётся непроверенной до отдельной проверки. | При custom → typical и ПРОФ → КОРП source metadata не расширяет applicability/home; отсутствие server hash не является самостоятельной причиной отклонить достаточный по смыслу факт.
| AC-21 | Cognee-only, optional отсутствует/off | Все шесть областей работают, нет запроса установки OpenViking/дубликатов и обязательных шести agent recall calls. |
| AC-22 | Auto/required, квалифицированный optional reader | Triage/read/write порядок соответствует fork, один durable save. Required gap виден и не обходится прямым URL; auto fallback остаётся в допустимой области. Live OpenViking не prerequisite этой приёмки: policy проверяется fixture без его установки. |
| AC-23 | Исправление пользователя и отказ writer | В qualified route в том же ходе — факт либо датированный scoped pending с intended provider; новый сеанс читает его без Cognee. Fork clause и source host overlay выбирают один route: legacy root fallback не переписывается, qualified private факты не уходят в global root/templates. Сохраняется rule-friction/evolve граница. |
| AC-24 | Полный каталог и многословная выдача | Агент получает только selected context и максимум настроенного суммарного бюджета, исходно 8 карточек/1600 токенов. Источники/статусы не потеряны, подробности доступны отдельно; обязательные правила не обрезаны. |
| AC-25 | Повтор unchanged запроса/standing conditions | Один task query/reader, отдельный standing на первом reader, одна reformulation после пустого relevant answer; reuse без добора восьми карточек или повторной проверки реестра. Native source/status calls посчитаны отдельно. |
| AC-26 | Стоимость всего контура | В G5 сопоставлены write/extraction/embedding/graph/index, optional improve, retrieval, source/status, agent input/output/cached input при метрике, schemas/rules, повторные context inputs и ресурсы/latency/rework. Measured/estimated/unknown и покрытие явны; локальные CPU time/peak RAM/wall time измеряются за весь прогон. Нет double count parent/child/events или объявления unknown нулём; детализация каждого внутреннего вызова не обязательна. Количественные claims ограничены подтверждёнными сопоставимыми измерениями. |
| AC-27 | Контролируемый native restore | Общее подключение приостановлено до exact current originals/известных поздних correction/delete и допуска проверенных scopes; fresh context/cache. Указана потеря после T. Ни пользовательские ACL/revoke checks, ни hidden rollback detection не требуются. |
| AC-28 | Disable/rollback/legacy | Existing owner выключает только managed memory, сохраняет данные/receipts/External MCP. Старый проект без opt-in продолжает прежний путь; поддержка Windows/terminal не сокращается. |
| AC-29 | Сравнение с files-only на одинаковых задачах | Правильность не ниже baseline, ноль чужих/устаревших runtime facts. Есть измеренная польза хотя бы в одной целевой метрике без скрытой существенной регрессии, покрытие/unknown раскрыты по AC-26; иначе rollout не расширяется без согласованного trade-off. Полная monetary экономия не объявляется по неполным данным. |
| AC-30 | Установленный исходный путь | После нового чата/registry update/reset агент завершает согласованную рабочую задачу с прежними gates. Helper fixtures, passed OpenSpec или одна удачная запись этого не заменяют. |
| AC-31 | Явное назначение и постоянное исправление после reset | Агент в том же ходе выбирает project/workspace через `dataset_name`, reset меняет только task scope, новый чат учитывает постоянное условие. Без назначения backend task write не выполняется, local pending виден новому сеансу; нет отдельного classifier/вопроса на каждую запись. |
| AC-32 | ERP+PM → canonical PM home → КОРП/ПРОФ | После runtime квалификации согласованного registry contract общий PM факт записан один раз в dataset PM КОРП с origin ERP+PM. КОРП и допустимый ПРОФ находят его; вырезанная функция/ERP-зависимость исключены, missing/ambiguous home остаётся project/task candidate. Нет всех ancestors/descendants в read set; registry fixtures не заменяют native proof. |
| AC-33 | Common connection и shared dataset | Один technical account, два процесса/разработчика используют один exact ID; scope/workspace/workplace различаются по назначению. Нет обязательного admin principal, grants, membership или outsider. Label collision и отсутствие дубликатов проверены. |
| AC-34 | Старый fragment без header и без correction в top_k | В текущем допущенном состоянии store precise original/current-status lookup под тем же scope обнаруживает correction/retirement независимо от semantic выдачи. Нет source ID/envelope/native proof → не действующий факт. Это не доказательство сохранения изменений после T или hidden rollback detection; после restore сначала AC-27. Свой versioning service и выдуманный get_document отсутствуют. |
| AC-35 | Стык с реестром и общий Cognee | Contract согласован с registry AC-27–29: один product reference из availableIn/того же SHA, missing field валиден, invalid/ambiguous назначение не угадано. Нет четвёртой роли/URL inheritance; native IDs остаются deployment map. Off/overrides и defer current local сохранены. Документальное согласование не закрывает schema/resolver/installed qualification; home change не объявляет миграцию или полноту поиска. |
| AC-36 | Функциональный отбор и строгий query budget | Первые восемь кандидатов не подходят ПРОФ, девятый подходит: в начальном raw cap 24 он проверен и может попасть в final 8/1600. Нет дополнительных поисков для добора; после полностью пустого relevant answer — максимум одна reformulation. Cap/deadline даёт partial/bounded coverage, не «знаний нет». |
| AC-37 | Минимальный ingestion и достаточный учёт reuse | Q7 подтверждает live `self_improvement=false`, native add/cognify/graph, отсутствие инициированных improve jobs, ограниченный model/settings profile и измерения всего прогона. Unsupported flag не выдуман, существенные расходы/ограничения платного профиля подтверждены либо требуют решения. Null детализация сохраняется как unknown без провала только по этому признаку. G5 paired evidence отдельно учитывает ingestion/lookups/повторные context inputs и проверяет claims; компактная карточка сохраняет ограничения/ссылки без повторных GUID. |
| AC-38 | Применимый native G1 перед зависимым runtime | Version/schema/models/connection и применимые Q1–Q7 evidence сохранены. Текущие Q1/Q2/Q5 используют common connection/context/currentness; прежние multi-user ACL результаты остаются historical, не запускаются обязательным повтором. Документы не native requalification, paired/client proof — G5. |
| AC-39 | Общий порядок и два opt-in старой установки | G0–G6 согласованы с registry AC-30–34: package update, association и memory readiness отдельны; memory G5 требует installed registry context, каталог выпускается самостоятельно. Unattended/нет ответа/«позже» не активируют память, qualified отдельный выбор не обходит TOOL/disabled/personal settings или client reload |
| AC-40 | Первое включение существующей ветки без reset | Existing owner сохраняет local IDs и один initial cycle без init/reset/изменения HEAD/базы. Повтор/resume/два сеанса/disable-enable используют те же IDs, old chat до verified reload не пишет новый task scope. Нет массовой миграции других worktrees или объявления старого runtime проверенным |
| AC-41 | Ошибка включения, disable и downgrade | Qualified opt-in/отмена/partial имеют honest state и existing pinned recovery; независимые package update/каталог не превращаются в memory failure/success. Disable сохраняет data/IDs/pending/External MCP; несовместимая helper/fork пара имеет совместимый restore, удаление одного ID не считается откатом |
| AC-42 | Legacy заметки сохраняются без bulk migration | После первого opt-in hashes прежних memory.md/локальных заметок сохранены; нет импорта чатов/всего файла, очистки, общей переклассификации или пересылки private фактов. Strict rules остаются в memory.md; отдельно выбранный перенос имеет scope/evidence/durable proof, global templates не объявлены историей проекта |

### Прослеживаемость семи уточнений

Дополнение 2026-10-19 к общей приёмке:

| ID | Проверяемое поведение | Достаточное доказательство |
|---|---|---|
| AC-43 | D9 и G2 имеют раздельные границы допуска и владельцев | Перед G4 зафиксированы применимый G1, actual code/consumer proof интерфейса G2 по registry AC-35 и отдельное явное одобрение описанной D9 границы/разрешение кода. Pure G2 независим; documents/mock/native stand не заменяют эти условия. В последующем owner/installed proof: native scoped adapter без provider patches/персональных ACL/новых services, single lifecycle cycle allocation/resume при unchanged HEAD, existing client apply/cancel/partial recovery, read20s/write-status60s, ambiguous receipt перед retry, private pending сохранён, disable/owned restore сохраняют IDs/data/чужие settings. Сохранены platform/client matrix, fork-owned policy/query budgets; G5 отдельно доказывает исходную задачу, restore admission/cache/new context и paired расходы. Сейчас проверена только согласованность документов, AC целиком не принят; [registry PM5 cost](../add-product-project-registry/evidence/g3-cost-baseline-2026-10-24.md) отдельно квалифицирован для warm no-op, не закрывает G4 consumer/G5 или этот AC целиком; [latest registry repair](../add-product-project-registry/evidence/g3-publisher-cost-repair-2026-10-24.md) фиксирует принятое пользователем допустимое отклонение warm median; consumer/G5 остаются отдельными непроверенными областями. Исторический failed downgrade закрыт исходным [G3-LD1 повтором](../add-product-project-registry/evidence/g3-legacy-executor-integrated-2026-10-25.md). Registry G3 принят в [согласованном контуре](../add-product-project-registry/g3-acceptance.md); R1–R6 остаются выпускным остатком, memory consumer/G4/G5/AC-43 целиком открыты |

G2.1–5 и authoritative handoff определены в registry design: schemas → pinned reader → единый roles/applicability resolver, publisher preservation → подготовленный минимальный seed/consumer qualification. Реальные общие homes требуют подтверждённой карты и native grants; полный installed G3 не требуется для начала кода G4, но обязателен соответствующий применённый контекст для G5. Подготовленный D9 — не approval file, его статус не меняется успешным OpenSpec validate.

### Обязательное наполнение перед первым выпуском

Согласованность с checkpoint G3: registry AC-39 и design G3.0–7 требуют отдельного approval до кода, source/owner proof и отдельно разрешённого installed canary. G2/D9/native G1 не заменяют их. Для memory AC-39/43/44 сохраняются один applied context, отдельный opt-in/qualification и обязательное выпускное наполнение; 10 s registry startup network deadline не меняет memory read/write/native Q бюджеты. Checkpoint G3 одобрен и source реализация разрешена; это не memory approval и не installed приёмка.

| ID | Проверяемое поведение | Достаточное доказательство |
|---|---|---|
| AC-44 | Первый выпуск использует наполненный подтверждённый реестр | До первого выпуска каталога и первого выпуска памяти выполнены registry AC-36–38 и задачи 1.9–1.11/5.7. В memory acceptance указан тот же опубликованный SHA согласованных catalog/relations/endpoint files, подтверждённый выпускной перечень продуктов/проектов, их resolved MCP/СППР/Mantis и карта основных областей с availableIn/ограничениями/первичными ссылками. Для объявленных shared-product сценариев проверены home/applicability и отдельно native IDs/currentness; отсутствие optional home не разрешает общий remember и не блокирует registry-only выпуск. Pilot-only/необъяснённые пробелы не принимаются; изменение затронутых правил/настроек требует сверить proof. Нет второго наполнения, автоматического импорта документов/чата, новых runtime barriers или always-on full-catalog context. G2 остаётся завершённым, G3/G4 могут разрабатываться независимо от этой выпускной задачи после отдельного разрешения | В том же выпускном реестре явно заполнены source origin/назначение и собственные отличия проектов; они не извлекаются автоматически из MCP.

AC-44 пока не проверен: сейчас уточнены только документы. Он дополняет G5/G6 и не заменяет native квалификацию, installed приёмку, отдельный memory opt-in или разрешение публикации. Проверка роста каталога сохраняет прежние бюджеты selected context/query, полный контент продукта остаётся у BookStack/первичного источника.

| Уточнение | Контракт / дизайн | Основная приёмка |
|---|---|---|
| 1. Явное назначение вместо task default | scope-storage; task-cycle; D2/D3/D6 | AC-31, AC-23 |
| 2. Одно каноническое место продуктового знания | registry-memory-context; D2/D4 | AC-32, AC-18–20 |
| 3. Подготовка общих datasets и точные IDs | scope-storage; D2/D3 | AC-33, AC-04/06 |
| 4. Актуальность correction и provenance chunk | scope-storage; D5 | AC-34, AC-09/27 |
| 5. Граница реестра и общего MCP | registry-memory-context; D4 | AC-35, AC-15–17 |
| 6. Candidate cap отдельно от final budget | memory-policy-and-budget; D8 | AC-36, AC-24/25 |
| 7. Ingestion profile и стоимость всей задачи | memory-policy-and-budget; D8 | AC-37, AC-26/29 |

## Сравнительный набор и измерения

Сравниваются два варианта: файлы с метаданными и один Cognee с той же информацией. OpenViking/комбинация не входят в обязательный эксперимент. Двенадцать контрольных задач: точная ошибка; переформулировка; восстановление причины решения; подтверждённый удачный подход; конфликт одинаковых объектов; новый чат; unchanged-HEAD reset; correction; КОРП/ПРОФ; ERP-зависимость; customer-specific вывод; вопрос только о среде ПК.

В корпус включаются условия AC-31–37: постоянная correction и reset, общий PM факт из ERP+PM, два пользователя shared dataset, chunk без header/correction, девятый применимый кандидат. Это варианты названных задач, не отдельная обязательная батарея двух движков. В обоих вариантах совпадают user prompt, исходные заметки/evidence, модель основного агента, права, source revision и ожидаемое действие. Записываются Cognee version/schema, self_improvement flag/default, модели/embedding, cache warm/cold, объём записей/datasets, raw/final caps и scope. Порядок пар контролируется; дополнительные повторы только при конкретной нестабильности измерения.

Метрики G5: task success/пропущенные знания, stale/foreign recall, точность карточек; доступные agent/backend tokens, semantic и source/status calls отдельно, CPU time/peak RAM/wall time всего прогона, latency/rework/обслуживание. Ingestion включён в сравнение, число reuse указано; повторные agent inputs карточек/cached inputs при метрике не бесплатны. Для каждой категории фиксируются источник, measured/estimated/unknown; детализация каждой внутренней операции необязательна. Не складываются parent/child и started/completed одного run. Tokenizer фактической модели проверяет русский/BSL; bytes при его отсутствии — proxy, не фактические токены. Claims ограничены подтверждёнными сопоставимыми данными; существенные unknown исключают заявление полностью измеренной денежной экономии. Без доказанной пользы расширение rollout требует явно принятого trade-off. Q7/G1 доказывает достаточность ограниченного профиля/измерений, не выполнение этого paired эксперимента.

## Проверки по владельцам

| Владелец | Доказательство |
|---|---|
| Pure context/dataset resolver | Fixtures шести scopes, explicit destination, canonical home/read set, отсутствующие IDs и subset/applicability. Чистый выбор потребляет registry policy без сети/LLM/дублирования resolver. |
| MCP adapter/client writer | Focused native-shaped API, exact-ID shared read/write, original/current-status translation, candidate/final caps, TOOL/deadlines/receipts; дополнить `McpConfig.Tests.ps1`, не заменяя safety cases. |
| Lifecycle | `DevBranchLifecycle.Tests.ps1`, `DevBranchWorktrees.Tests.ps1` и смежный existing owner suite: unchanged HEAD, прерывание, offline, old context и исходная успешность reset. |
| Registry consumer | Контракты зависимой спеки; тот же applied/current/new и pinned context, без собственной реализации updater. Fixtures не закрывают установленную зависимость. |
| Controlled fork | Owner-local policy tests/semantic diff, coverage вызовов разных агентских маршрутов; host `AiRulesOverlay.Tests.ps1`/`AiRulesMigration.Tests.ps1` подтверждают согласованную managed boundary. |
| Native Cognee/admin | На разрешённой версии: shared provisioning → два ordinary users/один ID, original/current-status/correction в допущенном store, Q5 admin restore admission с closed access/unknown-area case и Q7 whole-run metrics/ограничениями. Native REST/SDK evidence отделён от MCP initialize → initialized → tools/list и будущего client cache/reload canary. Production datasets не трогать. |
| Установленный canary | Разрешённый Windows/terminal стенд, baseline/native scenario proof AC-30. Отсутствующий стенд означает unverified, не снятие поддержки. |

## Порядок, зависимости и доказательства

1. Перед G4 подтвердить одновременно actual G2 interface по registry AC-35, отдельно одобренный D9/разрешение кода и применимость native G1 profile. Exact-ID shared access, original/current status и correction/retirement уже имеют proof этапа C с reuse; изменение профиля требует соответствующей повторной квалификации. Отсутствие native пути возвращает постановку на checkpoint. Документальная сверка не разрешает установку/рабочие данные и не заменяет runtime квалификацию.
2. После разрешённой native квалификации — pure/owner fixtures и adapter integration, затем lifecycle/registry canary; последним paired cost и исходный установленный путь. Это порядок зависимостей, не разрешение выполнять этапы сейчас.
3. По каждому этапу сохранить exact source/version/scope и passed/failed/unverified. Непройденный AC-02/03/09/11/27/31–35 запрещает scoped readiness независимо от экономии; unsupported native сценарий остаётся unverified/failed, а не положительным результатом fallback.
4. При двух repair cycles без acceptance/owner-narrowing прогресса сравнить rollback, owner-local решение и redesign по правилам пакета; не наращивать adapters для сокрытия дефекта.
5. Общий порядок G0–G6 — design обоих changes. В G3 подтвердить независимый legacy package update/association. В memory G5 пройти existing branch opt-in/initial IDs → fresh chat → unchanged-HEAD reset → update/conflict/offline/reload → disable/restore с административным допуском областей/cache reset/new context, сохранив старые заметки и успех исходной задачи; затем paired сравнение всей задачи по measured/estimated/unknown и подтверждение claims. Registry-only canary не требует memory Q/native прогонов.

## Доставка и текущая проверка документов

Исходная planning-only фаза использует `source-openspec.ps1 validate add-scoped-cognee-memory --strict --no-interactive`, status и структурную сверку. Отдельный запрос 2026-10-19 разрешает native Q на выбранном тестовом стенде; evidence/actual scope фиксируются выше. Ни source implementation, ни Targeted/Smoke/Full/Develop/Release, production deployment или изменения рабочих баз этим не разрешаются.

После отдельно разрешённой реализации обычная source delivery — coherent commit → RegisterChange с owner Targeted; результат проверяется Status. Fork policy меняется только у controlled-fork owner на upgrade/release branch. Это не разрешает push/tag, provider deployment или публикацию workflow. Task checkbox не закрывается одной регистрацией или наличием файлов; в нём нужна относящаяся evidence.

Текущее решение после этапа C: D9 одобрен пользователем; G2 handoff квалифицирован actual кодом и 42/42 PS5.1 focused tests в registry worktree. Это закрывает документальную сверку/интерфейс задач 1.1/1.2, но не installed часть AC-43 и не разрешает G4: пользователь отдельно оставил память/миграцию отложенными. Shared home scenario synthetic; реальный пилот PM5 КОРП не содержит неподтверждённых areas/homes. Native профиль и прежние failed proofs не менялись.

## Зависимость от квалификации G3, 2026-10-19

Registry owner выполнил ограниченный read-only прогон на существующих MCP `dev-ermakov`, source `f0a818b1e3b438e1bbf53401a822b3ea78edf394`. [Основной результат и продолжение](../add-product-project-registry/test-plan.md#квалификация-g3-на-существующих-mcp-2026-10-19), [bounded native evidence](../add-product-project-registry/evidence/g3-qualification-2026-10-19.json) остаются у него, без второго provider/capability ledger в памяти.

Пять transport handshakes прошли; Graph project scope, СППР UUID/exact Mantis link и native Unicode/deadline имеют subset proof. BookStack negative scope и Mantis multi-project failed, СППР metadata отсутствует. App build/full selected binding, actual client activation, original PM4/PM5 installed canary и полная Windows/terminal matrix не приняты. Поэтому registry AC-39 и installed dependency memory AC-43 остаются открытыми; источник со старым global scope не подменяет выбранный. Существующие MCP можно переиспользовать после квалификации нужного build; отдельный экземпляр каждого не обязателен. Deployment и изменения рабочих установок не выполнялись.

Этот прогон не обращался к Cognee, не менял G1 profile/Q proofs/D9, budgets или шесть областей, не проверял native memory IDs/grants/restore и не включал memory opt-in. G4 и installed migration по-прежнему запрещены; G5 ждёт применённого квалифицированного registry context и отдельной реализации памяти. Независимая готовность pure G2 сохранена; AC-44 потребляет тот же будущий наполненный snapshot AC-36–38 реестра. Source/client receipts и результаты server probes не загружаются в Cognee. Критерии ai_rules_1c, TOOL/off и ownership fork не изменялись.

## Актуализация зависимости G3, 2026-10-20

После отдельного разрешения пользователя BookStack/Mantis/СППР на dev-ermakov обновлены до attested source `893ed31fe25bf8b55ac17551812751370e669036`; существующие URLs/volumes/settings сохранены, старые контейнеры удержаны остановленными. [Registry test-plan](../add-product-project-registry/test-plan.md#обновление-трёх-mcp-и-повторная-квалификация-2026-10-20) и [единый bounded evidence](../add-product-project-registry/evidence/g3-mcp-update-2026-10-20.json) владеют deployment receipts, 29 passed live scope/compatibility controls, десятью passed исходными Python suites и native Zvec resource/surface subset. Прежние failed scope/metadata блокеры устранены, исторические результаты сохранены. BookStack qualification view не становится продуктовой областью/home и не означает наполнение реестра.

Full code/graph catalog binding, original isolated PM4/PM5 installed canary, actual client activation, поддерживаемая platform/terminal matrix и полное startup/surface сравнение всё ещё не приняты. Поэтому registry G3.7/AC-39, общий registry 5.3 в области AC-08/21 и memory installed AC-43 остаются открытыми. Наполнение AC-44 использует тот же будущий результат registry 5.7/AC-36–38, без второго каталога или нового условия начала G4. Ни эти server results, ни source registration не закрывают paired G5.

Cognee/profile/G1/Q1–Q7/D9, шесть областей, ai_rules_1c и budgets не менялись; новых Cognee/LLM calls, memory opt-in, G4, рабочих migration или публикации workflow нет. Memory change не получает отдельного capability ledger/updater и не компенсирует оставшиеся проверки расширенным контекстом.

## Продолжение зависимости G3, 2026-10-20

[Registry test-plan](../add-product-project-registry/test-plan.md#продолжение-g3-codegraph-pm5-клиенты-и-startup-2026-10-20) и [единый bounded evidence](../add-product-project-registry/evidence/g3-continuation-2026-10-20.json) владеют новым прогоном на runtime `d17f29da…`: четыре PM4/PM5 Code/Graph provider proofs, 48 client-file role checks, обе four-scenario startup matrices и warm original CLI offline continuation. Они имеют явную subset область: Graph inherited data не даёт indexed version stamp, полная expected-binding admission и active client catalogs не приняты.

Native PM5 factory copy создана/восстановлена из прежней sealed capsule. Source-only path normalization устранила false `FIXTURE_SEED_CHANGED` без recapture/нового acknowledgement; full factory regression 59/59. На копии потреблён неизменённый `ai_rules_1c itl-main-5700f54-r43` / `987320be139b4ac0d28f1f5b0f2515f63c7f140f`. Package master/branch commits clean, однако **whole unattended update failed**: optional catalog prompt ожидал ввод в скрытой console, после операторского продолжения outer terminal `WORKFLOW_UPDATE_POST_COPY_TERMINAL_UNCONFIRMED`. Association отсутствует, исходный seed полностью прошёл readonly validation, копия сохранена для диагностики, owned helper processes 0. Это registry runner/offer blocker, а не Cognee, grant/dataset или memory adapter defect.

Registry 4.8/5.2/AC-31 требует owner fix и повтор исходного native canary; actual selected-project activation, PM4/Windows/terminal stands и полные installed/cost критерии остаются открытыми. Пользователь подтвердил отсутствие готовых дополнительных stands. Registry AC-39 / memory AC-43/G5 не закрываются file/transport/hook proof. G1/Q/D9/G2, шесть областей, TOOL/off, budgets и fork ownership прежние; своего updater, capability ledger, prompt bridge или memory workaround не добавляется. G4, рабочая миграция и публикация не начинались; обязательный наполненный registry snapshot для AC-44 остаётся тем же будущим 5.7/AC-36–38 result.

## Повтор PM5 после исправления input owner, 2026-10-20

[Registry test-plan](../add-product-project-registry/test-plan.md#исправление-скрытой-консоли-и-повтор-pm5-2026-10-20) и [единый evidence](../add-product-project-registry/evidence/g3-hidden-console-fix-2026-10-20.json) фиксируют закрытие **G3-PROMPT**. Runtime `2f996692108d60d39d32801bfaef4e60e3338a8d`: общий input helper учитывает existing compact channel, включая старый runner → свежий post-copy процесс. Native regression red → green и две полные owner suites 33/33; нового memory prompt/state или изменения foreground stdin contract нет.

На новой owned PM5 copy из той же sealed capsule/frozen legacy baseline original `update-workflow` прошёл целиком: native process/terminal/signed lifecycle exit 0/succeeded, без вмешательства в console, association/consent/defer. Master/branch clean, workload сохранён, seed полностью validated, standalone status passed. Fork остаётся точным `ai_rules_1c itl-main-5700f54-r43` / `987320be139b4ac0d28f1f5b0f2515f63c7f140f`; исходный failed result/copy удержан. Whole native time 278.814 s относится к package update, не memory/startup/token budget.

Первая регистрация остановилась на отдельном watchdog fixture fault (concurrent read / `SetLastWriteTimeUtc` sharing violation до terminal 7). Existing controlled-handoff case сохранён; исправлена только атомарная подготовка его stale sidecar, focused case passed 1/1. Failed Targeted 622.046 s / 59 selected files и over-target cost observation сохранены в том же registry evidence; итог регистрации проверяется по source-delivery Status. Это не memory blocker, не изменение runtime и не повтор passed native PM5 journey.

Полные registry 4.8/5.2/AC-39 и memory AC-43/G5 остаются открытыми: native foreground selection и остальные installed/client/platform сценарии не заменяются unattended proof. AC-44 ждёт обязательного registry 5.7/AC-36–38 наполнения. G1/Q/D9/G2, шесть областей, TOOL/off, budgets и ownership прежние. G4, миграция рабочих проектов, server deploy и публикация не начинались.

## PM5: выбор, ассоциация и восстановление, 2026-10-20

[Registry test-plan](../add-product-project-registry/test-plan.md#pm5-выбор-ассоциация-и-восстановление-2026-10-20) и [единый evidence](../add-product-project-registry/evidence/g3-pm5-journey-2026-10-20.json) владеют продолжением на той же isolated PM5 copy/capsule. Native list/preview/unknown ID, настоящий foreground select и local-pending new, реальный отказ atomic selection write, main-phase guard и штатные status/resume/restore имеют bounded proof. Resume сохраняет ID/SHA; `memoryOptIn=false` в проверенных ассоциациях. Локальная заявка не публиковалась и не считается наполнением реестра.

Следующий whole foreground package update **failed до offer/later**: catalog-only preferences создают selection file, который legacy reconcile ошибочно принимает за настройку legacy набора MCP. **G3-CATALOG-LEGACY-ENROLLMENT** воспроизведён и read-only `PlanOnly` с полным существующим endpoint registry; правки Cognee/ai_rules_1c или memory workaround не требуются. Failed post-copy snapshot удержан; source-side recovery status passed и сохранил byte report (`changedPathCount=0`), но rollback/resume package не принят. Branch controls, их preconditions/continuation и remaining limits принадлежат тому же registry evidence.

Полный registry AC-39 / memory AC-43/G5 открыт: успешный catalog restore не равен восстановлению legacy MCP enrollment, whole update, branch или active client proof. Реестр исправляет boundary у прежних owners и повторяет исходный canary, без новых memory flags/updater, навязанного legacy setup, изменения guard или второго capability ledger. AC-44 по-прежнему требует registry 5.7/AC-36–38 до первого выпуска. G1/Q1–Q7/D9/G2, шесть областей, TOOL/off и budgets прежние; G4, рабочая миграция и публикация не начаты.

Branch continuation завершён с отдельным stand/source blocker: fork не стартует из factory-restored базы с pending application proof; предусмотренный `update-dev-branch-base` failed на исходном native Gate 6 finding (`/CheckConfig`, exit/result 101, свойство `упоОшибкиОтраженияДокументовВПроектномБюджетировании` в форме помощника PM4→PM5). Gate 6 owner подтвердил snapshot/cursor restore, `applyStarted=false` и native release; исходный seed и business trees сохранены, explicit test-copy processes 0. Existing branch catalog context rematerialized в свой root и opt-in off, однако new-fork inheritance/ready не приняты. Это не Cognee/model/dataset проблема и не причина разрешать G4; подробные identities, native duration и SHA находятся только в registry evidence.

## Owner fix enrollment и разбор Gate 6, 2026-10-20

[Registry qualification](../add-product-project-registry/test-plan.md#owner-fix-enrollment-и-разбор-gate-6-2026-10-20) владеет source fix `8ee68833…`, focused 158/158 + дополненный Setup 26/26 и native повтором на прежней capsule. Private property больше не создаёт legacy defaults; existing native body/guards сохранены. Первый whole legacy update, явные select/restore/new/restore и full-registry `PlanOnly` passed с memory off; на этом промежуточном checkpoint actual next-version foreground post-copy ещё не был принят; итог ниже, same-version branch-resume не заменяет его.

[Отдельный Gate 6 analysis](../add-product-project-registry/evidence/g3-gate6-analysis-2026-10-20.json) показал отсутствие регистра без `_` в метаданных и ссылку на него в Module.bsl:9325 процедуры подготовки чистой PM5. Тот же module blob есть в frozen baseline; finding не связан с catalog IDs, MCP enrollment, Cognee/model/datasets. Правка PM5, adjudication warning, изменение gate или повторная загрузка базы не выполнялись. AC-43/G5 и обязательное наполнение AC-44 остаются открытыми; G1/Q1–Q7/D9/G2, шесть областей и budgets прежние, G4 не начинается.

В registry ledger отдельно сохранена непринятая foreground попытка после успешного legacy reconcile: captured post-copy child не получал input caller. Owner-local перенос offer к caller и запрет вопросов в continuation прошли **96/96** owner regressions; whole установка исправленного caller на той же capsule — exit 0 / succeeded, **240.761 s**. На этом промежуточном checkpoint проверка следующего настоящего foreground перехода ещё была открыта; итог ниже. Память использует этот же результат и не получает собственный input bridge, consent/state или updater.

## Итог dependency enrollment, 2026-10-20

[Registry итог](../add-product-project-registry/test-plan.md#итог-повтора-enrollment-2026-10-20) и его [единый evidence](../add-product-project-registry/evidence/g3-catalog-enrollment-fix-2026-10-20.json) подтверждают исправление G3-CATALOG-LEGACY-ENROLLMENT: прежний PM5 workload/seed, настоящий foreground upgrade с новым caller, видимый later и поздний select/restore. Raw catalog-only preferences не включают legacy MCP или память. Сохранены целые native results, непринятая попытка с hidden input и same-version controls; они не подменяют друг друга.

G3-LEGACY-CALLER-OFFER остаётся ограничением первого upgrade старой установки; требование первого interactive offer не ослабляется. Gate 6 только разобран, native client context unverified/UI tools degraded, полный G3/AC-39 и branch/source/stand journeys открыты. AC-43/G5 и AC-44 не закрыты. Ни G4, ни рабочая миграция/публикация не начаты; Q1–Q7/D9/G2, шесть областей, budgets и совместимость с ai_rules_1c сохранены. Source Targeted и его reuse/cost принадлежат общему delivery ledger, повторного memory gate нет.

## Dependency first legacy caller, 2026-10-20

[Registry native proof](../add-product-project-registry/test-plan.md#первое-обновление-legacy-caller-2026-10-20) и [единый evidence](../add-product-project-registry/evidence/g3-legacy-caller-offer-2026-10-20.json) фиксируют первый foreground upgrade неизменённой PM5 capsule fa0e3c → c264cbe5: whole exit 0, видимое предложение в исходной консоли, фактический later, clean roots сразу после update. Новый caller заранее не устанавливался; manual select и same-source retry не использованы как замена first-upgrade proof. Runtime/ai_rules_1c r43 и шесть областей не меняют своих границ; Cognee/provider/memory calls отсутствуют, G4 не реализуется.

Повтор команды без вопроса и поздний select с memoryOptIn=false подтверждены отдельно. Поздний restore восстановил binding/private semantics, но изменил JSON key order descriptor: **G3-CATALOG-RESTORE-FORMAT open**, semantic equality не является byte/clean restore. Dirty копия/diff сохранены у registry owner. Полный installed G3/AC-39 и memory AC-43/G5 не закрыты; Gate 6, остальные source/client/platform controls и обязательное наполнение AC-44 остаются прежними. Gate 6 не исправлялся/не перезапускался. Память не получает своего input bridge, state или updater; always-on instructions/tool schema delta 0. G4, рабочая миграция и публикация не начинались.

Первый registry RegisterChange/Targeted failed из-за отсутствующей явной классификации нового CallerInput suite в SourceQualityCatalog (историческая cohort 57 → фактические 58). После добавления отдельного registry consumer/owner/budget исходный focused case passed 1/1; исторические counts/watchdogs и Gate 6 guards сохраняются. Это metadata owner fix без нового memory/runtime кода; первый native PM5 proof c264cbe5 остаётся прежним. Исходный failed candidate и cost сохранены в общем evidence; полный результат повторной регистрации — в delivery ledger.
Второй Targeted passed: 1396/0/0, 62 groups (54 executed / 8 reused), 1082.089 s, over-target. CallerInput 6/6 за 43.937 s укладывается в его 90 s. После gate общая очередь перешла на готовый 5d68733d; регистрация не состоялась из-за конфликта только SourceQualityCatalog с новым consumer другой задачи. Исходная квалифицированная история сохранена в refs/heads/codex/g3-legacy-caller-qualified-20261020. Свои три commits перенесены на готовую базу; в конфликте сохранены оба явных consumer и прежние watchdogs/числовые cohorts/budgets. Gate 6 runtime другой очереди сохранён без правок этой задачей. Focused тот же case после разрешения passed 1/1 за 3.02 s. Первоначальный diagnostic selection-owner.json оказался перезаписан этим повтором; его прежние данные/неизменённый log сохранены, новый JSON имеет отдельное имя; evidence явно отмечает замену и не выдаёт старый SHA за актуальный файл. Последующий RegisterChange обязан квалифицировать изменившиеся combined inputs; старый passed gate не объявляется регистрацией или новым native PM5 proof.
Третий Targeted на новой combined базе failed: 897.540 s; 17/63 groups завершены, 691 passed / 2 failed. Оба отказа — прежний CompactRunnerWatchdog: wall time 7.1045555 s при <7 и 16.2848136 s при <15. Test/runner/timeout policy/PowerShell environment файлы побайтно совпадают по Git blobs с предыдущим passed gate; input leaf здесь не вызывается. После завершения gate те же исходные кейсы, пути, budgets и fixtures прошли focused 2/2 за 16.612 s; это диагностика, не замена полного gate. Причина превышений не установлена: snapshot 2.7 GB free RAM/24% CPU сам не доказывает environment cause. Failed artifacts сохранены; thresholds/watchdogs/concurrency/assertions не менялись. Требуется штатный RegisterChange с исходной topology; наблюдение не объявляется исправленным одним focused pass. Gate 6/G4/рабочая миграция/публикация не запускаются.

## Dependency точный restore descriptor, 2026-10-20

[Registry evidence](../add-product-project-registry/evidence/g3-catalog-restore-format-2026-10-20.json) и [test-plan](../add-product-project-registry/test-plan.md#точный-restore-descriptor-2026-10-20) разделяют source repair и native acceptance. Owner-local receipt возвращает исходные bytes только при неизменённом whole-file hash; чужие несвязанные значения, binding conflicts, private later и historical recovery сохраняются. Focused 89/89 за 98.284 s, source a2e6931e. Новый native PM5 replay заблокирован отсутствующим source 1Cv8.1CD: factory exit 1 до materialization; first upgrade/select/restore не выполнялись. Нужен прежний файл с manifest SHA, затем тот же исходный сценарий без canonicalization/cleanup/admission bypass. Прежний failed proof не заменён успешным.

Эти изменения не закрывают native G3-CATALOG-RESTORE-FORMAT, full G3, AC-43/G5 или обязательное наполнение AC-44. Memory route не включён и G4 не реализуется; ai_rules_1c/шесть областей/Q1–Q7/D9 сохранены. Gate 6 не исправлялся/не запускался, рабочая миграция и публикация не выполнялись. Source registration/Targeted и его actual selection/cost/reuse учитываются прежним delivery ledger; focused proof не подменяет native replay.

## Dependency согласованный capsule recovery, 2026-10-20

Пользователь согласовал у registry/source fixture owner отдельный Prepare Develop из path/SHA-bound исходной capsule и положительного capacity budget. Сохраняются прежние DT/source.bundle/state/context, published N-1 caller, existing native restore/guards/claim и исходная последовательность first update → later → select → restore; no automatic fallback, Recapture или Release/publication route. Новый owned target отделён от старого seed и failed copy; receipt явно помечает sealed-capsule admission, currentness пропавшего raw seed остаётся unavailable. Память не получает recovery state, updater или нового разрешения; native G3-CATALOG-RESTORE-FORMAT до результата открыт, как и full G3/AC-43/G5/AC-44. Шесть областей, ai_rules_1c, Q1–Q7/D9 неизменны. Gate 6, G4, рабочая миграция и публикация не начинаются. Подробный контракт и приёмка — registry design/test-plan, без второго каталога или механизма recovery.

## Dependency результат capsule recovery, 2026-10-20

Registry/source owner закрыл bounded native G3-CATALOG-RESTORE-FORMAT: [результаты](../add-product-project-registry/test-plan.md#результат-recovery-pm5-из-capsule-2026-10-20), [evidence](../add-product-project-registry/evidence/g3-capsule-recovery-2026-10-20.json). Exact capsule восстановлена в новый owned PM5 target; old caller fa0e3c начал первое обновление, два dependency failures сохранены, official pinned resume с local artifact exact locked SHA завершил upgrade. Фактический later → late select → restore вернул исходные bytes/clean roots, private later/legacy=false/memory off; descriptor Git blob и restored DB совпадают с original reproducer/failed copy. Это не uninterrupted first-command success или новая single-command legacy-caller qualification. Старый seed/failed copy, 13 protected files/4 roots, семь Gate 6 artifacts и все 11 capsule artifacts сохранены. Original raw seed currentness unavailable; automatic fallback/Recapture/Release route не добавлены.

Focused 101/0/0 за 292.577 s плюс перекрывающийся ownership 3/0/0 за 17.862 s. Storage 113.310 s при budget 60 — over-target; новый suite, serial restriction, always-on context, memory/provider/LLM calls не добавлены. Locked on-demand asset URL дал HEAD 404; source-build SHA совпал, публикация/Release компонента не доказана. Client context unverified и nonblocking uvx/UI warning сохранены. Final Targeted/registration — existing delivery ledger. Full G3, G5/AC-43/AC-44 и остальные release conditions остаются открытыми; native G1/Q1–Q7 не переоткрываются, текущая provider readiness перед будущим opt-in проверяется отдельно. Шесть областей/ai_rules_1c/Q1–Q7/D9 без изменений; Gate 6, G4, рабочая миграция и публикация не начинались.

## Dependency итоговая матрица G3.7, 2026-10-20

Registry owner свёл все AC/остаток в [одну итоговую матрицу](../add-product-project-registry/evidence/g3-final-qualification-2026-10-20.md) с [canonical evidence](../add-product-project-registry/evidence/g3-final-qualification-2026-10-20.json). Свежие bounded live/file/startup/concurrency controls не заменяют full installed AC-39/AC-43/G5. В частности, обе family over-target startup, cold receipt writes и actual client activation остаются открытыми; private Codex trust inspection не native tool proof. Матрица содержит source/client/stand blockers и existing-owner продолжения без второго memory механизма или журнала.

Native G1/Q1–Q7/D9/G2 не переоткрываются; перед будущим opt-in нужна обычная актуальная provider admission, а не автоматический перенос native proof на установленный adapter. AC-44 использует одно будущее наполнение реестра AC-36–38. Шесть областей, canonical home, ai_rules_1c и optional OpenViking не меняются. Новых Cognee/LLM calls в локальных startup/client сценариях нет; usage native Code search unknown. G4, Gate 6 fix/run, рабочая миграция и публикация не начинались.

## Dependency повтор Startup и квитанций, 2026-10-20

[Единый registry result](../add-product-project-registry/evidence/g3-startup-repair-2026-10-20.md) и [exact proof](../add-product-project-registry/evidence/g3-startup-repair-2026-10-20.json) уточняют исторический открытый startup/cold срез выше. Owner-local причины исправлены и повторены исходные source/synthetic controls: 133/0/0/0, обе PM4/PM5 warm серии в целях, cold main/offline/no-write bytes+mtime, nested pinned SHA, новые/изменённые inputs, same-user concurrency/status и 48 parsed role checks passed. Median улучшилась умеренно; более высокий paired p95 и промежуточный PM5 over-target сохранены. Full installed cost/context proof этим не закрывается.

AC-43/G5 потребляет тот же pinned registry context без собственной startup сети/кэша/квитанции. Cognee/LLM calls и always-on/tool schema delta 0; native Q1–Q7/D9/G2 не переоткрываются. Шесть областей, canonical home, ai_rules_1c и optional OpenViking прежние. Full G3/AC-39, G5/AC-43 и release AC-44/registry AC-36–38 открыты вместе с остатком общей матрицы. Gate 6 не исправлялся/не запускался; G4, рабочая миграция и публикация не начинались. Source-delivery ledger владеет обязательным Targeted/регистрацией.

## Dependency Code/Graph и native client activation, 2026-10-20

[Один registry result](../add-product-project-registry/evidence/g3-source-client-qualification-2026-10-20.md) и [exact proof](../add-product-project-registry/evidence/g3-source-client-qualification-2026-10-20.json) уточняют прежнее отсутствие actual tool call: установленный Codex app-server вызвал Code/Graph tools в новых PM4/PM5 контекстах, foreign negative/reload/byte restore прошли, turn/start 0. File-only 48/48 — отдельный subset. Это не desktop/IDE frontend proof; остальные 11 adapters, live business-source admission и точная версия unverified.

AC-43/G5/AC-44 и full registry AC-39/AC-36–38 открыты. Source readiness не выводится из tools; memory не добавляет probe/cache/ledger. Failed harness сохранены, требования/бюджеты/поддержка прежние. G1/Q1–Q7/D9/G2, шесть областей/canonical home/ai_rules_1c/optional OpenViking не меняются; Cognee calls 0. Gate 6, G4, рабочая миграция и публикация не выполнялись.

## План приёмки зависимости Code/Graph source identity

Действующий [registry checkpoint](../add-product-project-registry/design.md#checkpoint-g3-привязка-codegraph-и-версия-источника) и [AC-08-a–h](../add-product-project-registry/test-plan.md#план-проверки-привязки-codegraph-и-версии-источника) используют существующие registry сведения и явные различия проекта/source. Прежние native revision/image/Graph source gaps исключены из обязательной зависимости. Это не memory runtime acceptance: следующие проверки выполняются только в отдельно разрешённом consumer/G5, без начала G4 сейчас.

| Existing AC | Проверка в будущем consumer/G5 | Ожидаемый результат |
|---|---|---|
| AC-15/17/35/43 | One applied context с проектом/base product/доработками, source origin/назначением и опубликованной configurationName/version/index info | Память потребляет тот же selected projection и registry provenance; не создаёт своего resolver, server metadata protocol или требования source stamp |
| AC-18/19/20/43 | Custom PM5 КОРП использует типовой PM5 КОРП | Типовой MCP не доказывает наличие/отсутствие custom функции; project/local evidence сохраняет project scope. Общий независимый факт допускается по прежней карте/home без обязательного native revision hash |
| AC-18/19/20/32 | PM5 ПРОФ использует MCP PM5 КОРП; прочитаны разрешённая и исключённая области | Явная настройка допустима; исключённая функция не предлагается как доступная в ПРОФ. Разрешённая область следует прежнему canonical home/read set, без копии dataset и автоматического расширения context scope |
| AC-15/20/35 | Registry version/endpoint меняется при прежних business IDs | Current source version видна, старое evidence не объявлено новой проверкой; project/dataset/home и local project version не подменены сведениями типового MCP |
| AC-35/43 | Existing Code/Graph не сообщает sourceIdentity/generation/stamp либо недоступен; инструментирован remember/recall/startup | Отсутствие дополнительных source fields/исходников Graph не является отказом памяти и не делает все факты непроверенными. Code/Graph probes/fetch/новые manifests/cache/services = 0; собственные Cognee currentness/revision и correction/recall/query/card budgets сохранены |

Один [registry source result](../add-product-project-registry/evidence/g3-registry-source-model-2026-10-21.md) с [raw references](../add-product-project-registry/evidence/g3-registry-source-model-2026-10-21.json) покрывает source alignment и owner-сценарии custom → typical / ПРОФ → КОРП; второй memory ledger/probe не создаётся. Native custom Codex read подтверждён, последующий [fresh ПРОФ/reload proof](../add-product-project-registry/evidence/g3-prof-native-reload-2026-10-21.md) снял прежний transport gap в Codex core/API subset. Full client/frontend/installed proof не подменяется этим результатом. Исторические [source proof](../add-product-project-registry/evidence/g3-source-binding-implementation-2026-10-21.md) и [матрица](../add-product-project-registry/evidence/g3-final-qualification-2026-10-20.md) сохраняются без переписывания фактов; прежний exact-index criterion не возвращается через их ссылки. Consumer/G4 не реализован; registry AC-08/39, memory AC-43/G5/44 и наполнение registry AC-36–38 открыты. G1/Q1–Q7/D9/G2 не переоткрыты. Cognee/OpenViking и controlled ai_rules_1c не меняются. Gate 6, G4, рабочая миграция, server deploy/reindex и публикация не запускаются.

## Dependency native ПРОФ → КОРП/reload, 2026-10-21

[Registry result](../add-product-project-registry/evidence/g3-prof-native-reload-2026-10-21.md) и [exact proof](../add-product-project-registry/evidence/g3-prof-native-reload-2026-10-21.json) подтверждают свежие actual Code/Graph calls из проекта ПРОФ к явно выбранному КОРП, old connection до reload, controlled wrong-source mismatch/foreign deny, новую thread и byte+mtime restore/reload → исходное чтение. Project/product/source IDs и limitation context не изменились; это read-only qualification existing G3, не запуск G4 или consumer/G5 acceptance. Старые connect failures сохранены, точная историческая первопричина не установлена. Status `httpOrigin` может показывать новый config при старом соединении; проверка activation по одному этому полю недостаточна.

25 safe native calls в принятых runs, 4 в сохранённом failed harness, LLM turns 0, pair <20 s, summary 668–682 bytes. 20 local protected paths и global client config сохранены. Второго memory probe/состояния/реестра нет, ai_rules_1c и шесть областей/home/grants/Q1–Q7/D9 неизменны; AC-43/G5/44, full registry AC-39 и release AC-36–38 остаются открытыми. Gate 6, G4, working migration, server changes и публикация не выполнялись.

## Dependency клиенты и установленный PM5, 2026-10-21

[Один registry report](../add-product-project-registry/evidence/g3-clients-installed-2026-10-21.md) / [JSON evidence](../add-product-project-registry/evidence/g3-clients-installed-2026-10-21.json) уточняют существующие AC-15/20/25/35/43, не закрывая consumer 4.2 или G5. Source runtime f53b9247 unchanged; 48/48 file checks, Kilo connection/reconnect и legacy installed b4338057 selection/discovery/owned failure recovery имеют раздельный proof. Последний не latest source install и не uninterrupted full journey. DB/HEAD/branch сохранены, common MCP/native client metadata edit не удалены ради pass.

Открытый G3-CONTEXT-CLI-OUTPUT требует readable bounded default child stdout у registry owner: DTO значения origin/usage/version/limitations есть, console formatting их скрывает. Same-helper JSON pipeline 7725 bytes — проверенное diagnostic продолжение, не новый consumer/prompt. G3-KILO-MULTICLIENT-ALIASES сохраняет исходный multi-client workload; aliases/`$schema` не меняют business IDs/home/grants, и memory не вводит второй mapping. G3-KILO-TOOLS-API-404 оставляет functional client tools unverified; direct transport или native connection их не заменяют. Перед будущим G5 потребляются исправленный registry context и соответствующая native client qualification, а не новая memory проверка Code/Graph.

Новые actual SHA+mtime guards 20 context paths/4 post-restore files passed; прежний all-20 hash-only guard не доказывал timestamps, отдельные Codex config/Startup receipt timestamp controls действительны. Diagnostic CLI 3.676 s не Startup benchmark; полный installed cost, client-schema duplication/token impact не измерены. Другие frontend/client/PM4/Win10/Server terminal клетки открыты. Lookup/query/card budgets ai_rules_1c, шесть областей, canonical home, Q1–Q7/D9/G2 и обязательное наполнение registry прежние. G4/AC-43/G5/44 не приняты; Gate 6, Cognee/G4, рабочая миграция, server deploy и публикация не выполнялись. Отдельного memory ledger/probe нет.

## Dependency G3-CONTEXT-CLI-OUTPUT repair

[Один registry report](../add-product-project-registry/evidence/g3-context-cli-output-2026-10-21.md) / [exact proof](../add-product-project-registry/evidence/g3-context-cli-output-2026-10-21.json): 6/6 public context repeats на прежних custom/PROF roots и 60/60 PS5.1/Pester owner regressions passed. Source origin/назначение/registry version/ограничения/доработки видимы в compact JSON status/select; in-process DTO прежний. Unbound не создаёт association; external-probe fixture остаётся binding matched/clientActivation unverified. Это presentation pass, не fresh native source read и не реализация memory consumer/G5.

Future consumer 4.2 получает прежнюю applied projection, не добавляет собственного formatter/resolver/probes и не сериализует public JSON ещё раз. On-demand stdout 2332–3071 bytes; рост от скрывавшего данные default вывода обоснован, always-on/query/card budgets не менялись. Actual SHA+mtime_ns 19 paths/root, всего 38, совпали; прежний raw guard также содержит 19 unique keys вместо заявленных summary 20, JSON сохранён. Kilo aliases/API/остальные frontend/installed/platform/cost gaps не закрыты. Шесть областей/canonical home/grants/ai_rules_1c/G1/Q1–Q7/D9/G2 прежние, AC-43/G5/44 и registry AC-39/36–38 открыты. Gate 6, G4, рабочая миграция и публикация не выполнялись.

## Registry Kilo aliases/API repeat, 2026-10-21

[Один registry report](../add-product-project-registry/evidence/g3-kilo-native-fix-2026-10-21.md) / [JSON](../add-product-project-registry/evidence/g3-kilo-native-fix-2026-10-21.json) заменяет открытые Kilo findings предыдущего среза, сохраняя historical records. G3-KILO-MULTICLIENT-ALIASES и G3-KILO-TOOLS-API-404 закрыты для bundled 7.8.15 CLI/core: existing writer overlays, 2 connected/2 disabled, два исходных CUSTOM/ПРОФ workloads, real tools/semantic negatives/reconnect/instance reload; 145/0/0 owner regressions. Диагностический API требует флаг только в isolated native process; обычные defaults/клиенты/серверы не изменены.

Final runs: 16 backend calls, вместе с mechanism probes 24; 26 local API attempts, LLM turns 0. First pair 10.073/12.437 s <20 s, точные tokens/Startup cost не измерялись. Source writer OpenCode не менял; две native CUSTOM schema/format exceptions сохранены, новый discovery подтвердил SHA/mtime всех 38 paths. Это уточняет registry client/ownership acceptance и зависимые AC-15/20/25/35/43, не проверяет remember/recall/datasets или consumer 4.2. Memory не добавляет собственных probes/alias state, flag и имена не меняют home/grants/business IDs. Full registry AC-39/36–38, IDE/latest installed/platform и memory AC-43/G5/44 открыты. G1/Q1–Q7/D9/G2/шесть областей/ai_rules_1c прежние; Gate 6/G4/рабочая миграция/публикация не выполнялись.

## Native desktop dependency result, 2026-10-21

[Canonical registry report](../add-product-project-registry/evidence/g3-desktop-native-2026-10-21.md) / [JSON](../add-product-project-registry/evidence/g3-desktop-native-2026-10-21.json) сохраняют единственную границу новых AC-15/20/25/35/43 observations. В ПРОФ → КОРП Kilo VS Code сделал actual stats/list_graph_projects reads с полезным pm5corp/default; failed get_graph_project_status со строкой generation="null" не стал pass по completed/тексту модели. Scope/result, native schema и полезные данные проверяются отдельно; inherited graph без generation stamp допустим по согласованной модели.

Cursor подтвердил native worker/discovery (28/54 tools, common9 сохранены) после полного Reload Window, однако login overlay виден, обычный signed-in frontend и агентские calls unverified. Первоначальные OpenCode Default Project/403 сохранены; [vendor/provider follow-up](../add-product-project-registry/evidence/g3-opencode-provider-repair-2026-10-21.md) прошёл два actual native payloads и scoped reload на отдельной 1.19.3/original PROF root. Selected-context/provider blockers закрыты в этой scope, основная 1.18.11/full installed/client/model matrix не переквалифицированы. Memory не получает обходов, credential копий, собственного probe или UI state. Kilo GUI/model flag-off вариант отдельно не проверялся: source report явно ограничивает proof приватным процессом с MCP Apps flag=1 и обычным Ask tool path; этот флаг не становится memory/installed default.

В canary есть 2 user turns/4 provider requests/3 tools; input 50 327, отдельно cache read 145 728, output 432/reasoning697, reported cost0 Auto Free. Это не G3/memory added-context attribution без paired baseline; нулевые LLM calls не заявляются. Workflow runtime/always-on/schema/startup probe delta0, Cognee calls0. Fresh12 SHA/mtime и отдельный historical19 compare passed, owned processes закрыты; private updater download не установлен, EXE SHA прежние. Full registry AC-39/36–38 и memory 4.2/AC-43/G5/44, остальные client/platform/installed/cost критерии открыты. G1/Q1–Q7/D9/G2/шесть областей/home/ai_rules_1c прежние; Gate 6/G4/рабочая миграция/публикация не выполнялись.

## OpenCode follow-up: existing AC-15/20/25/35/43

Принимать registry-owned proof: completed native picker + exact selected root + frontend scoped /path и /mcp после reload; не считать неизменный Electron screenshot отказом, пока не проверены отдельные owned Windows dialogs. Connected не заменяет payloads. First 1.18.11 canary 403/tools0 сохранён; [owner release repair 1.19.3](../add-product-project-registry/evidence/g3-opencode-provider-repair-2026-10-21.md) добавил actual stats({})/list_graph_projects({}) на том же root/provider/model/prompt. Этот read subset passed; future memory consumer не повторяет qualification calls при startup/remember/recall.

Fresh 19-path SHA/bytes/actual mtime guard и EXE passed, owned процессы закрыты. Новых memory calls/always-on/schema/probes 0; native usage/cost 0 после отказа не является token-delta/billing proof. Полные memory 4.2/AC-43/G5/44, registry G3/AC-39 и обязательное release population AC-36–38 открыты. Gate 6/G4/рабочая миграция/публикация не выполнялись.

## Provider follow-up: actual registry native reads

[Report](../add-product-project-registry/evidence/g3-opencode-provider-repair-2026-10-21.md) / [JSON](../add-product-project-registry/evidence/g3-opencode-provider-repair-2026-10-21.json): official vendor 1.19.3/bundled version1.19.3, отдельный private profile, original PROF root, два actual native parts. Code success/КОРП source, Graph accessible pm5corp/default/ready и scoped reload приняты по payloads, без server patches/новых probes. Failed 1.18.11/versionlocal/403 и установленный EXE сохранены; её green installed proof не заявляется. Fresh19 =16 existing+3 absent; 12 client formats=11 physical config files, hashes/actual mtime/absence прежние.

Новый canary 1 turn/3 streams/2 tools, native input56619/cache56887/output458/reasoning507/reported cost0 — existing client costs, без paired memory delta/billing proof. Consumer4.2/G4, full G3/AC-39/installed/CUSTOM/model/platform/cost и обязательное release population AC-36–38/AC-44 открыты; Gate 6/рабочая миграция/публикация не выполнялись.

## Cursor native follow-up: existing AC-15/20/25/35/43

[Registry report](../add-product-project-registry/evidence/g3-cursor-native-reads-2026-10-22.md) / [JSON](../add-product-project-registry/evidence/g3-cursor-native-reads-2026-10-22.json): закрыт G3-CURSOR-NATIVE-AGENT-AUTH в user-authorized signed-in профиле/installed3.26.16, exact original PROF root. Через normal UI включены Code28/Graph54; actual transcript доказывает ровно stats({})/list_graph_projects({}), две completed native cards дают CORP identity/accessible pm5corp/default. Normal Reload Window сохранил account/root/toolset и exact tool results без второго qualification turn. Failed private3.25.9/handoff не переписаны и не объявлены accepted.

Source switches восстановлены через UI, common9/31 прежние; fresh19 paths=16 existing+3 absent (11 physical configs/12 formats) unchanged, EXE3.26.16 stable from launch; 30 owned processes штатно завершились. Canary1 user turn/2 tools/UI12 s, tokens/provider requests/billing/paired memory delta не измерены; budgets не ослаблены. Account/profile не становятся business scope/home/grants/registry credential, новые memory schemas/probes/always-on rules не добавлены. Full registry G3/AC-39, remaining installed/CUSTOM/platform/cost и release population AC-36–38, consumer4.2/AC-43/G5/44 открыты. Gate 6/G4/рабочая миграция/публикация не выполнялись.

[Единственный registry watchdog repair report](../add-product-project-registry/evidence/g3-watchdog-registration-repair-2026-10-22.md) различает native Cursor acceptance, owner-test proof и source-delivery registration. Phase reservation вычитает publication age, не меняя исходный `<7 s`, положительные phase budgets, watchdog120 s/terminal cleanup60 s. Полные owner tests, красный delayed-read reproducer и before/after cost остаются registry evidence; новых memory runtime checks/state/context нет. G4, рабочая миграция, Gate 6 и публикация не входят в этот repair.

## Dependency текущего installed PM5, 2026-10-22

[Один registry report](../add-product-project-registry/evidence/g3-pm5-current-package-2026-10-22.md) / [JSON](../add-product-project-registry/evidence/g3-pm5-current-package-2026-10-22.json): новая snapshot-only copy с installed d109a95d, first legacy update/later без external resume, current late association/context, direct/compatible restore, real settings partial/main guard/pinned resume и private custom draft/explicit select. DB/workload/old stands и exact restored roots сохранены. Memory opt-in false, Cognee calls0; нового consumer/updater/state нет.

Warm20+20 измеряют whole public CLI с local private registry: median delta +0.312 s, bound пять файлов SHA+mtime unchanged. Baseline explicit sync переписывает receipt mtime при прежнем SHA; driver failures сохранены. Это не G5 paired memory/isolated Startup/token/billing acceptance. Full registry G3/AC-39/source DB/new branch/refresh/downgrade/multi-client/platform/remote cost и memory4.2/AC-43/G5/44 открыты, mandatory registry AC-36–38 population прежняя. Gate 6/G4/рабочая миграция/публикация не выполнялись.


## Registry dependency: current PM5 multi-client/conflict/offline, 2026-10-22

Existing AC-15/20/25/35/43 согласованы с [единственным registry report/JSON](../add-product-project-registry/evidence/g3-pm5-multiclient-offline-2026-10-22.md). Unattended conflict без записи, keep-local/registry ordinary no-op и applied-cache/no-cache offline safety подтверждены в указанном installed PM5 subset. Full G3/AC-39 открыт: G3-CATALOG-OWNED-MCP-REENABLE (Code/Graph не восстанавливаются, marker не materialization) и G3-DEFER-MCP-WRITER-PREFERENCE-LOSS (ordinary writer удаляет defer) требуют owner repair и original-path replay. Настоящий multi-client partial/foreign-write/pinned resume/restore заблокирован первым дефектом; memory consumer не обходит этот blocker своим mapper/state/probe.

Metadata deadline, поздний Git child exit и whole captured CLI ~25 s разделены; нет proof strict cleanup/isolated Startup/paired memory tokens. Это dependency evidence, не consumer4.2/G4, AC-43/G5/44 или разрешение выпуска; existing release population AC-36–38 сохраняется. DB/capsule/старые copies и Gate 6 evidence прежние, memory off/Cognee calls0; G1/Q1–Q7/D9/G2/six scopes/home/grants/optional OpenViking/ai_rules_1c не меняются. Gate 6, рабочая миграция и публикация не выполнялись.


## Registry dependency: named blockers repaired, 2026-10-22

[Registry-owned original PM5 replay](../add-product-project-registry/evidence/g3-owned-mcp-defer-repair-2026-10-22.md) закрывает G3-CATALOG-OWNED-MCP-REENABLE и G3-DEFER-MCP-WRITER-PREFERENCE-LOSS в bounded native области existing AC-15/20/25/35/43. Absent/unowned re-add не снимает защиту still-owned deletion/present collisions; ordinary pinned consumer не снимает defer без нового решения. Actual two-client partial/foreign-edit/same-revision recovery, unrelated restore preservation и два subsequent ordinary calls подтверждены; full 98/0/0 owner batch не заменяет native frontend/memory provider proof.

New runtime I/O/always-on rules/tool schemas0; memory off/Cognee calls0. Первое package update потребовало штатного exact-source continuation после сохранённой guard failure, поэтому full first-pass installed acceptance не объявлена. Warm whole CLI/offline preservation, metadata deadline, transport child lifetime и paired memory costs разделены; full G3/AC-39/platform/cost/release population и consumer4.2/G4/AC-43/G5/44 открыты. Gate 6/рабочая миграция/публикация не выполнялись; шесть областей/canonical home/grants/ai_rules_1c прежние.


## Registry dependency: first-pass update on original PM5, 2026-10-22

[Canonical registry report/JSON](../add-product-project-registry/evidence/g3-post-copy-startup-repair-2026-10-22.md) заменяет прежнее open состояние G3-UPDATE-POST-COPY-STARTUP только в проверенном subset: исходный bound old-runtime PM5 Kilo→Cursor и absent/unowned endpoints + stale baseline, один update без recovery/retry, outer/fresh child/main/sibling green, физические endpoints/foreign settings/fork/DB/старые snapshots/capsule сохранены. Guard refusal настоящих поздних изменений остаётся обязательным. финальный owner batch 159/0/0 пройден; initial artifact failure/retry и rejected incomplete candidate сохранены; frontend/provider/token acceptance здесь не заявляется. Full G3/AC-39, AC-36–38, consumer4.2/G4/AC-43/G5/44 открыты. Cognee calls0/memory off; Gate 6/рабочая миграция/публикация не выполнялись.

## Registry dependency: PM5 cache/record controls, 2026-10-22

[Один registry report/JSON](../add-product-project-registry/evidence/g3-pm5-cache-record-qualification-2026-10-22.md) обновляет AC-16/17/26 dependency: на runtime176bd2fa 8 native controls подтвердили bound offline fallback при corrupt cache/недоступных Git objects, unbound no-guess refusal и invalid-applied main block с доступным status. Public healthy continuation/idle cancel и preservation passed; injected hash был возвращён самим harness, это не owned recovery и не interactive cancel. Report сохраняет failed matcher attempt и итоговый остаток G3, второго memory ledger/cache/probe/recovery нет.

Full registry G3/AC-39, remaining original installed/client/platform/paired cost/strict transport cleanup, release AC-36–38 и consumer4.2/G4/AC-43/G5/44 открыты. DB/capsule/старые failed roots сохранены, Cognee/LLM/native Code/Graph calls0; ai_rules_1c/шесть областей/canonical home/G1/Q1–Q7/D9/G2/optional OpenViking прежние. Gate 6, G4, рабочая миграция и публикация не выполнялись.

## Registry dependency: native отмена и owned restore, 2026-10-23

[Один registry report/JSON](../add-product-project-registry/evidence/g3-pm5-interactive-recovery-2026-10-23.md) подтверждает actual PTY Ctrl+C/пустой ответ до записи и public restore повреждённого applied из существующего плана, затем original command exit0. Это обновляет AC-16/24/26 dependency subset, но **G3-CATALOG-COMPLETED-RESUME-INVALID-APPLIED открыт**: completed resume ложно отвечает configured при corrupt marker. Memory не ремонтирует/обходит его и не создаёт собственный cache/recovery/probe. Полный registry G3/AC-39 и consumer4.2/AC-43/G5/44 остаются открытыми.

Foreign bytes/семантика клиентских файлов сохранены; owned field order изменён, прежний strict whole-file SHA failure сохранён без объявления byte pass. DB/старые failed roots/capsule прежние, LLM/Code/Graph/Cognee calls0. Остальной installed/client/platform/cost остаток и release AC-36–38/AC-44 не закрыты; ai_rules_1c/шесть областей/home/Q1–Q7/D9/G2/optional OpenViking прежние. Gate6/G4/рабочая миграция/публикация не выполнялись.

## Dependency: completed resume repair и original PM5, 2026-10-23

[Один registry report/JSON](../add-product-project-registry/evidence/g3-completed-resume-repair-2026-10-23.md) закрывает named completed-resume blocker в original PM5 subset: actual marker validation, truthful no-write refusal, existing pinned restore → successful original command. Focused8/full122 owner cases и 9 native calls не становятся consumer4.2/G4 или full memory acceptance. Whole client bytes/current DB/immutable failed/capsule evidence сохранены; strict old-root movement failure из-за более раннего обновления другого seed отражён отдельным ограничением. Второго memory updater/cache/recovery/probe нет.

Full registry G3/AC-39/remaining installed/client/platform/cost, AC-36–38 population и consumer4.2/AC-43/G5/44 открыты. Шесть областей/canonical home/grants/Q1–Q7/D9/G2/optional OpenViking/ai_rules_1c прежние; Gate6/G4/рабочая миграция/публикация из этой задачи не выполнялись.

## Dependency: PM5 partial cancel и recovery, 2026-10-23

[Один registry report/JSON](../add-product-project-registry/evidence/g3-pm5-partial-cancel-2026-10-23.md) подтверждает cancel на двух настоящих faulted partial планах, pinned resume при новом tip, direct owned restore, read-only status и обе original commands. Registry context остаётся единственным источником consumer; memory не восстанавливает marker/план самостоятельно. Restore возвращает before-состояние, но следующий startup вправе применить неизменившийся desired catalog.

Отмена ещё работающего writer между A/B **не доказана**: failed timing harness сохранён как evidence gap, не product defect и не pass. 17 public calls не закрывают full registry AC-16/24/26/39 или memory consumer4.2/G4/AC-43/G5/44. Foreign bytes/семантика сохранены, full client byte equality=false; DB/старые roots/capsule/prior raw proof подтверждены в текущем before/after. Шесть областей/home/grants/Q1–Q7/D9/G2/optional OpenViking/ai_rules_1c прежние. Остальные installed/client/platform/cost/population критерии открыты; Gate6/G4/рабочая миграция/публикация не выполнялись.

## Dependency: active-writer cancellation gap qualified, 2026-10-23

[Один registry report/JSON](../add-product-project-registry/evidence/g3-pm5-active-cancel-2026-10-23.md) закрывает прежний named PM5 active-writer cancellation gap: public cancel после настоящей A receipt при живом writer, apply exit1 до B/marker; pinned resume при новом tip и отдельный direct owned restore → original commands passed. 15 native calls и timing-only command breakpoint без runtime patch/mock подтверждают existing registry/client owner; memory не создаёт свой resolver/cache/recovery/probe. Failed harness и прежние исторические границы сохранены.

Это AC-16/26 dependency subset, не full registry G3/AC-39 или consumer4.2/G4/AC-43/G5/44 acceptance. Полные race/terminal/installed/client/platform/cost/population критерии открыты; шесть областей/home/grants/Q1–Q7/D9/G2/optional OpenViking/ai_rules_1c прежние. Gate6/G4/рабочая миграция/публикация не выполнялись.

## Dependency: current PM5 concurrency/Startup cost, 2026-10-23

[Единый registry report/JSON](../add-product-project-registry/evidence/g3-pm5-concurrency-startup-2026-10-23.md) подтверждает same-user A/B serialization и read-only status при active writer, pinned main обоих original commands, 40 native no-op checks и publisher-only/change/offline. Приёмка времени остаётся открытой: **G3-PM5-STARTUP-WINDOW-COST**, full window2.045/2.570 s при цели1/2; внутренний hook и calibration не подменяют полный scope.

Memory не вводит свой cache/probe/updater и не закрывает cost gap за registry owner. No-op output/context bytes не являются model token/billing proof; эта серия не G5 memory comparison. Consumer4.2/G4/AC-43/G5/44, full registry G3/AC-39 и прочие journeys/population открыты. Шесть областей/home/grants/Q1–Q7/D9/G2/optional OpenViking/ai_rules_1c прежние; Gate6/G4/рабочая миграция/публикация не выполнялись.

## Startup cost repair/repeat, 2026-10-23

[Canonical report/JSON](../add-product-project-registry/evidence/g3-startup-window-repair-2026-10-23.md). Finding закрыт в проверенном current PM5 subset; original window median/p95 0.932/1.238 s. 123 owner tests, 60 protected no-op SHA+mtime guards и publisher-only/change/offline → original command passed. Для повторной cost-приёмки сохранять полное окно Import → main, original 20 full-profiler/on-off pairs, отдельный observer control и неизменные цели; module-only/preloaded/inner numbers не заменяют этот scope. Это measured subset, не полный G3/G4 acceptance.

## External edit race после CLI decision, 2026-10-23

[Canonical report/JSON](../add-product-project-registry/evidence/g3-pm5-external-edit-race-2026-10-23.md): три исходных race calls, 20 public calls/7 independent editors, no main после refusal, fresh keep-local и pinned resume/restore functional paths passed. Strict foreign/final byte assertions **failed без изменения ожиданий**; **G3-MCP-FOREIGN-BYTE-PRESERVATION** остаётся блокером AC-16/24/26/39. Диагностика ownership/raw value spans отделена от общей byte приёмки. Повтор после owner repair обязан сохранить реальную внешнюю append-правку и оба recovery пути. Ввод Read-Host/GUI/terminal не подменяется explicit CLI proof; full G3/G4 и population открыты.

## Последующий owner repair foreign bytes, 2026-10-23

[Canonical report/JSON](../add-product-project-registry/evidence/g3-mcp-foreign-byte-repair-2026-10-23.md): исходные early-consent/late-resume/late-restore journeys повторены на прежнем PM5 root после штатного обновления обоих roots до6642b1f9. Внешний editor/observer совпадают побайтно; strict verifiers изменены только в evidence-root. 20 native calls (16 success/4 ожидаемых safety refusals), 7 independent editors, pinned ID/SHA/main suppression и обе original commands passed. **G3-MCP-FOREIGN-BYTE-PRESERVATION закрыт только в этом subset**: строгие foreign bytes/order6/6 и final client semantics/outside-owned bytes2/2 passed. Kilo целиком byte-equal; Cursor отличается внутри owned values, что отдельно измерено и не маскируется semantic-only результатом. Пять новых regressions red5→green5; шесть профильных suites228 passed/0 failed/0 skipped.

Критерий приёмки остаётся прежним: сохраняются реальные внешние append-правки, все байты/порядок вне исходной owned-value маски, actual SHA/mtime no-op, прежние collision/consent/partial/marker-last/pinned recovery guards. Не менять reproducer path, topology, workload или assertions. Full4.2/5.2/AC-16/24/26/39 и consumer memory4.2/AC-43/G5/44 остаются открытыми для прочих критериев.

**Исторический блокер G3-PM5-UPDATE-COPY-STATUS-STALE (закрыт последующим repair/replay ниже):** два normal compact update остановлены watchdog120 s на workflow-update.copy. Сохранённые phases copying→copy-complete и тот же exact-source normal continuation довели оба roots до clean candidate. Нет manual receipt/runtime patch, увеличения watchdog или first-pass upgrade acceptance. Требуется owner-local диагностика свежести status и uninterrupted original update с прежними условиями.

Короткое whole CLI наблюдение (warmup + три no-op/version): median 6.890→8.646 s (+1.756 s), рост не атрибутирован. Separate functional observer: generic editor/initializer calls0. Read-only owner-only PlanOnly diagnostic, 20 alternating pairs: median34.693→37.261 ms (+2.568 ms), protected inputs прежние; это не объясняет whole CLI рост и не заменяет native acceptance. Полный feature cost открыт; новая20-sample Startup приёмка не заявляется. Сохраняются прежние release population AC-36–38/AC-44, шесть областей/canonical home/grants/optional OpenViking/ai_rules_1c. Gate6/G4/рабочая миграция/публикация не выполнялись.

Первый registration Targeted failed349/1 (неполная выборка): legacy ClientAdaptersAndModes требовал physical global-sort alpha/custom/zulu. Это противоречит сохранению исходного foreign fragment. Тот же fixture/два вызова/client-layout assertions сохранены; order contract уточнён до exact key membership + owned order + прежний repeat SHA и новых foreign prefix/suffix/actual mtime checks. Изменённый case focused1/0, прочие40 не запускались; complete Targeted обязателен отдельно. Runtime и исходные native strict assertions не менялись; failed candidate/логи сохранены в canonical report, без замены failure на focused pass.


## PM5 uninterrupted update acceptance, 2026-10-23

[PM5 update copy-status repair](../add-product-project-registry/evidence/g3-pm5-update-copy-status-repair-2026-10-23.md): **G3-PM5-UPDATE-COPY-STATUS-STALE закрыт в исходном PM5 subset**. Existing snapshot/receipt owner использует прежний PID-owned heartbeat; watchdog120 s и assertions неизменны. Source compact перенос449705 ms и original installed update443186 ms завершились без retry/recovery, оба roots clean, snapshots680/359. 84/0/0 complete owner tests; Kilo+Cursor/DB/старые доказательства сохранены. Full G3/AC-39, остальные journeys/cost/population и memory dependencies открыты; Gate6/G4/рабочая миграция/публикация не выполнялись.

Критерии named subset выполнены: actual capture/receipt sidecar принадлежит текущему PID и исчезает после owner, status/stage/error semantics прежние; старые watchdog/foreign-PID/terminal-error regressions проходят без ослабления порогов. Native runner SHA/timeout-policy прежние, overrides отсутствуют, action-default3600 s. Исходный installed Invoke-SourceFixtureInstalledAction реально обновил main и sibling (не skipped/no-op), по одной completed snapshot post-copy-complete на root, records680/359. Оба roots clean/exact, descriptors/r43/DB неизменны, client semantics/order/foreign и whole-file bytes2/2 passed. Сверены12864 retained snapshot files/2349 previous raw artifacts/21 files/4 roots/11 capsule hashes/7 Gate6 artifacts. Старые failures сохранены.

Selection/cost/reuse: existing lifecycle/rollback contract, два дополнительных cases без новой suite/serial policy; focused complete84/0/0 wall478729 ms и owner times в canonical JSON. Неизменённые suites ради времени не повторяются. Existing input closure/reuse policy сохранены; окончательный Targeted/actual selection/executed/reused/slowest/cost — только RegisterChange ledger. Native source449705/installed443186 ms не сравниваются с recovery baseline457983 ms как ускорение. Added always-on/schema bytes0 и provider/LLM/memory calls0; full feature cost/прежний CLI delta и whole G3/AC-39 остаются открытыми. Gate6/G4/рабочая миграция/публикация не выполнялись.

Focused file times: rollback316.576 s и watchdog155.011 s против existing scheduling hints207/80 s — over-target observation; reliability5.843 s против10 s. Это не доказательство причинного замедления: comparable same-input baseline отсутствует, selection/order/reuse policy не менялись, повторов ради времени нет. Стоимость итогового Targeted оценивается отдельно по его ledger.

Первый RegisterChange отказал до Targeted: обе очереди добавили независимые Describe в конец WorkflowUpdateRollback.Tests.ps1. Только новая heartbeat-группа перенесена перед existing Workflow update receipt detail recovery; её содержание/assertions/порог и runtime неизменны. Чужая группа и принятые queue refs сохранены. Native candidates сохраняют прежние test blobs; окончательный test file отличается расположением группы, поэтому его принятие принадлежит последующему полному Targeted, не предыдущим focused84. Failed candidate сохранён; placement JSON/SHA приложены отдельно от замороженного native manifest.

## Квалификация cache/schema/record на текущем PM5, 2026-10-23

[Квалификация cache/schema/applied на текущем PM5](../add-product-project-registry/evidence/g3-pm5-cache-integrity-2026-10-23.md): пакет `fac4bc51` установлен штатным update за 376,761 с. **Подтверждены 8 групп сценариев, 11 CLI-вызовов в итоговом наборе.** Проверены сохранение validated applied при offline/неподдерживаемой схеме, безопасный отказ без привязки, отказ для неизвестного проекта и повреждённого applied, доступность status и продолжение после удаления внесённого тестом повреждения. SHA и mtime защищённых путей, база, бизнес-исходники и прежние доказательства сохранены. Полная G3/AC-39, остальные платформы/клиенты/сценарии, стоимость и наполнение реестра остаются открытыми. Gate 6, G4, рабочая миграция и публикация не выполнялись.

Проверены точный пакет и roots до/после, исход основной фазы installed CLI, отсутствие угаданных ID, сохранность applied SHA/context при offline/schema fault, типизированный отказ для неизвестного ID и неверного hash, доступность status и SHA/actual mtime для 18 состояний путей (по 9 на root, включая отсутствие файла). Две ветки предупреждений и публичная/внутренняя ошибки unknown ID различены по коду владельца. Первые ошибки ожиданий harness сохранены. BOM и агрегация отчёта исправлены только в harness; пути, топология, данные и runtime thresholds не подменялись. Всего сохранены 13 CLI-наблюдений, включая 2 ранних; единый непрерывный проход всего harness не заявляется.

CLI занимал 1,188–4,101 с на локальных fixtures: это не проверка stalled fetch deadline/cleanup, paired Startup или полной стоимости функции. Сверены 12 864 прежних snapshot files, 2 349 raw artifacts, 21 защищённый файл, 4 старых roots, 11 capsule hashes и 7 Gate 6 artifacts. Штатное recovery именно этого повреждённого applied не проверено. Полные AC-39, release population 5.7/AC-36–38 и memory consumer 4.2/AC-43/G5/44 не приняты. Этот source change документационный; фактические выбор, исполнение, reuse и стоимость Targeted определяет RegisterChange. Дополнительный always-on context/schema: 0 байт; новые provider/LLM/memory calls: 0.

## Завершающая квалификация G3, 2026-10-23

[Единый отчёт и матрица](../add-product-project-registry/evidence/g3-completion-2026-10-23.md). Source: defer/restore red 2/4 и green 132/132 в трёх полных owner suites; Git cleanup проверяет реальный зависший HTTP, закрытие дочернего соединения и исходный deadline, затем весь Git-save owner 12/12. Сохранены ранний harness bootstrap failure, failed reserve=2 и прежние native 21–22,5 с transport tail; assertions/deadline не ослаблены. Замер времени вызова отделён от Pester assertion overhead, время закрытия сокета проверяется независимо.

Native acceptance исправлений, полный остаток AC и сохранность зафиксированы в итоговом installed отчёте; исходная source-assisted recovery остаётся отдельным этапом, затем прежняя цепочка повторена installed. Test-actor reset после штатного restore — отдельная уборка fixtures, не доказательство recovery. Полная G3/AC-39 пока не принята; Gate 6, G4, рабочая миграция и публикация не выполняются.

[Итоговый прогон G3](../add-product-project-registry/evidence/g3-completion-2026-10-23.md): доступный current PM5 subset завершён; **полная G3/AC-39 BLOCKED** по G3-B1–B5. Два owner-local repairs прошли 132+12 source tests и installed repeat `dfae2ff3`; 90 config calls + update. Настоящие conflict answers/Ctrl+C, pending stable ID, damaged-applied owned recovery и transport 7,933/7,836 с подтверждены. Warm full median/p95 1,006314/1,353585 с: median goal остаётся недостигнутым, без округления/повтора ради pass. Gate 6, G4, рабочая миграция и публикация не выполнялись.

Полная матрица AC-01–39 и конкретные blockers — в едином отчёте. Старые остатки по точному indexed revision/server patch, live Mantis create и выпускному наполнению не становятся дополнительными G3 prerequisites. Проверенные server/native срезы сохраняют свои версии; непроверенные platform/frontend/whole lifecycle не отмечаются выполненными.

## Уточнение cost acceptance, 2026-10-24

Сопоставление выполняется на одном физическом root, package/runtime, данных, clients и эквивалентных endpoint settings: A bound, B штатный legacy unbound. Подготовка/восстановление вне clocks; profiler off не является feature off. Минимум20 AB/BA blocks; сохранять полное Import→main окно с прежними целями1000/2000 мс, одинаковый общий anchor, все unprofiled whole CLI samples и парные разности. Legacy registry refresh внутри main учитывается ровно один раз. Фактические baseline writes фиксируются; catalog no-op SHA+mtime guards не ослабляются. Подробная phase диагностика отдельно, observer стоимость не вычитается ради pass, неудачные harness/preparation и все outliers сохраняются. Current-package feature baseline не объявляется исторической pre-G3 версией.

[Стоимость G3 и baseline, 2026-10-24](../add-product-project-registry/evidence/g3-cost-baseline-2026-10-24.md): сопоставимый current-package legacy unbound baseline подготовлен; 20 AB/BA блоков, 100 retained samples + 4 warmups. Полный Startup median/p95 **0.995591 / 1.168819 с**, цель 1/2 с выполнена; paired whole CLI без профилировщика **0.548018 / 1.428991 с**. Запас median всего 4.408850 мс, устойчивый SLA <1 с не доказан. Прежнее превышение6.314 мс не округлено в pass, подробные phase probes отделены от benchmark. G3-B5 закрыт для сопоставимого warm no-op PM5 subset; полная G3/AC-39 остаётся BLOCKED по остальным клеткам. Ниже сохранены исторические результаты; новую стоимость определяет этот отчёт. Gate6/G4/рабочая миграция/публикация не выполнялись.


## Приёмка нативных клиентов PM5, 2026-10-24

По [единому evidence](../add-product-project-registry/evidence/g3-pm5-native-clients-2026-10-24.md) закрыт только Kilo/Cursor subset: exact PM5 root и installed package, actual completed stats/list_graph_projects до и после полного IDE Reload Window, ровно4 вызова на клиент, stable executable, source switches/чужие settings сохранены. Для OpenCode renderer reload/path/MCP connected принят отдельно; 0 tool calls и quota failure оставляют agent-read критерий открытым. Для закрытия нужны по2 actual calls до/после reload с доступным authorized provider на том же root, полные payloads/transcript и сохранность. Смена Cursor binary потребовала нового полного прогона; failed первоначальные executable/whole-byte checks не удалены и не ослаблены. Native schema/formatting changes явно учтены, teardown не является product restore proof. Full G3/AC-39, registry version currentness, другие клиенты/платформы/PM4/lifecycle, memory readiness и release population этим не принимаются.

Решение пользователя от 2026-10-24: [OpenCode пропущен в текущем прогоне](../add-product-project-registry/evidence/g3-opencode-skip-2026-10-24.md). Нативные агентские чтения имеют статус SKIPPED, подтверждение провайдера больше не требуется для этого прогона. Это не PASS, устранение квоты или снятие поддержки/общего выпускного критерия; остальные разрешённые проверки G3 могут продолжаться.


## Актуальная матрица доступного остатка, 2026-10-24

[Единая fresh/historical матрица 39 AC и 12 clients](../add-product-project-registry/evidence/g3-remaining-qualification-2026-10-24.md) дополняет прежние доказательства: current native Codex core/API metadata/content/deny/reload/new-thread и три Startup режима приняты только в указанной PM5 области. Полная Desktop/model-agent/native platform матрица не следует из API/files. Publisher-only/offline сохраняют client bytes+mtime, changed endpoint и applied SHA должны быть видны до main, каждый запуск имеет fetch1/probes0. Одиночные full-observer5.426/6.896/3.532с и bytes не являются incremental A/B/median/p95/SLA; прежняя warm no-op цель и benchmark сохранены. OpenCode SKIPPED, B1–B5 остаток и release population явно отделены от выполненного; registry AC-39/G4 consumer/G5 этим не приняты.


## Приёмка парных dynamic measurements, 2026-10-24

[Единый report/JSON](../add-product-project-registry/evidence/g3-paired-dynamic-cost-2026-10-24.md) закрывает только доступную измерительную часть B5: минимум 20 AB/BA пар/режим, точный root/package/seed, неизменный registry URI и invocationHash для online, весь private cache восстановлен вне clocks, observer-off whole CLI и парные delta/nearest-rank p95, все выбросы/первичные failures сохранены. 80 URI-confounded samples не квалификационные, без фильтрации по времени; offline 20 пар не повторялись. Endpoint actual work двух клиентов против одного и legacy offline preserved-connections вместо full sync явно входят в трактовку результата. Guards clients/preferences/foreign bytes/базы/истории, fetch1/HTTP0 в отдельных diagnostics подтверждены; bytes вывода не tokens. Существенная delta не объявляется pass/устойчивым SLA. Прежние warm no-op цели1000/2000мс и остальная B1–B5/AC-39 матрица сохранены; G4 consumer/G5 cost этим не проверены.


## Приёмка publisher-only/offline repair, 2026-10-24

[Report/JSON](../add-product-project-registry/evidence/g3-publisher-cost-repair-2026-10-24.md) подтверждает только current PM5 subset: новая immutable revision плюс прежние catalog/relation blobs и registry diff только publishedAt допускают reuse только с проверенными локальными inputs; source version/endpoint/catalog/relations/missing proof/input change требуют полного пути. Journal adoption должен сохранить client bytes+mtime, обновить context/hash/private revision и пройти resume/restore; external-file race остаётся CLIENT_MCP_PREVIEW_CHANGED, не freshness-success. Offline при том же validated SHA не вызывает повторный resolve/Git decode, другой SHA читается обычно; applied hash/WARN/pinned revision сохранены. Минимум20 observer-off AB/BA пар/режим, постоянный origin URI, все samples и разница работы endpoint/offline явно сохранены; процессный CPU не total-tree CPU/не вычет из wall. Дополнительные 20 full-window samples проверяют прежние цели1000/2000мс: current1049.731/1240.7921мс сохраняются как измеренный результат. Пользователь принял превышение median49.731мс как допустимое: G3-PM5-WARM-STARTUP-MEDIAN закрыт как ACCEPTED DEVIATION, не threshold PASS, без дальнейшей диагностики/оптимизации или повтора ради порога.8 module-only controls не заменяют полный Startup. Нельзя выдавать исторический borderline pass за current pass, shared-host before/after за code-only speedup или registry subset за G4/G5/full AC-39.

## G3: native metadata transitions, 2026-10-24

[Точный набор и границы](../add-product-project-registry/evidence/g3-project-metadata-functional-2026-10-24.md): public installed sync на прежней PM5-копии принимает каждый новый immutable SHA. Для rename проверены стабильные IDs и semantic hashes; для custom/typical/area/home — обновлённый knowledge hash при прежнем settings hash; для СППР/Mantis — актуальные ссылки/list/search/create routes, замена списка целиком и отсутствие удалённой связи. На каждом sync descriptor/lock и Kilo/Cursor bytes+mtime прежние, sibling неизменён. Public context stdout валиден как JSON. Итог10/10, first8 CLI и исходные harness failures сохранены. AC-02/11/23/29 подтверждены только для этого PM5 subset; native services/IDE reload, G4/G5, остальные B1–B4 и полная AC-39 не принимаются этим proof. Принятое warm отклонение не требует повторных измерений; OpenCode SKIPPED.

## G3: installed lifecycle subset и failed downgrade, 2026-10-24

[Результаты и точные границы](../add-product-project-registry/evidence/g3-pm5-lifecycle-2026-10-24.md): first unattended old-caller update exit0/322555мс, оба roots clean и без принятого ID/позже; native late list/preview/select; expected CATALOG_PACKAGE_INCOMPATIBLE без замены helper/settings; restore-compatible возвращает exact descriptor и native Kilo values (его whole bytes не equal), отсутствующий Cursor остаётся отсутствующим. Actual downgrade exit1/70843мс с исходным child error Invalid dependency mode: workflow. Use fresh or locked. — прежняя mode error подтверждена в исходном прогоне; mode repair и следующий not-newer refusal отражены выше. Полный downgrade/AC-18/39 ещё не пройдены. Snapshot phase post-copy-failed и payload pinned; current-source status с explicit SourceRoot/GUID валиден и не меняет transaction, но не завершает операцию. Fork admission blocked до worktree/Gate6; full init/new/fork/refresh и все foreground choices не принимаются. Прежний current PM5/DB/history/capsule сохранён, failed canary retained. Scope AC-18/21/22/31–33/39 и memory AC-43/G5 сохраняет эти различия; G4 не выполнялся.

## G3: историческая partial qualification до migration handoff

[Результат и исходный child error](../add-product-project-registry/evidence/g3-managed-downgrade-mode-partial-2026-10-24.md): legacy/current wire format, pins/provenance/foreign entries, exact failed rollback, inherited environment/finally restore и single explicit argument проверены в 97/0/0/0 owner tests. Direct current→old на прежнем PM5 не завершил post-copy/commit/rollout: после mode fix получен ai_rules not-newer. Success recovery/no-op не заменяют прямой proof; AC-18/39 и memory AC-43/G5 остаются открыты. После A/B нужны existing-owner diagnosis/repeat, final preservation и sealing/validation/registration. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация вне допуска.

## G3: final direct downgrade boundary / G3-LD1

[Итог и исходный error](../add-product-project-registry/evidence/g3-managed-downgrade-repair-2026-10-24.md): 99/0/0/0 owner tests + 2/0 filtered rules-policy tests (29 unselected). Main actual old post-copy/commit и schema1/locked/ondemand0.4.15 passed; sibling old coordinator оставил schema2/workflow/0.4.24, получил strict mismatch и pending399. Whole update exit1/258955мс, не PASS; final CF/DB/current/history/capsule/raw957 unchanged. AC-18/39 и memory AC-43/G5 открыты. Для согласованного G3-LD1 требуется original single native downgrade через existing current executor с exact old payload, все roots clean/old pins/locked, foreign data preserved, negative unavailable-executor и partial/resume/restore tests. Старый helper не патчить, guards/assertions/reproducer не ослаблять. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация вне допуска.

Original emitted LifecyclePhase completeness test сохраняется: post-copy должен оставаться литералом в fresh-process call и входить в entrypoint ValidateSet. Registration выявил потерю статической видимости после переноса argv в переменную; исправлена запись вызова, не assertion. После native15b proof этот source-only correction прошёл original phase1/0 и handoff4/0 с прежним argv; exact final candidate проверяет source-delivery Targeted. Это историческая граница до LD1: исходный downgrade закрыт native PASS 2026-10-25; full G3 остаётся по общей матрице.

Legacy master-commit-ready/master-committed checkpoints продолжают только commit/rollout: не повторяют dependency/rules writers и не переписываются в post-copy-running. Existing migration handoff ограничен pre-commit фазами; две red regressions исправлены guard существующего owner, итог focused handoff/commit6/0 (58 unselected). Это сохранение прежней recovery границы, не G3-LD1 implementation. Native15b и exact final Targeted proof разделены.

## G3-LD1: разрешённый объём 2026-10-25

[Текущий отчёт LD1](../add-product-project-registry/evidence/g3-legacy-executor-2026-10-25.md). Путь и commit текущего исполнителя фиксируются до copy в существующих recoveryExecutorRoot/recoveryExecutorCommit; target source/pins остаются прежними. Main post-copy и branch rollout принадлежат одному текущему owner, порядок master commit → branches прежний. Используются уже имеющиеся source checkout, transaction, per-root lease и continuation, без нового cache manager/service/state machine. Если exact current checkout недоступен, до copy требуется запуск текущего source-side `scripts/update-installed-workflow.ps1 -ProjectRoot <root> -SourceRoot <old-source>`; записанная identity повторно проверяется перед child.

Пользователь ограничил этот прогон: новые проверки и тестовые случаи не добавлять. Повторяются исходный saved-PM5 сценарий и уже имеющиеся owner-проверки; прежние assertions, workload, watchdog и recovery контракты сохраняются. Непокрытые отдельным fault run свойства не отмечаются PASS. Регистрация — один штатный RegisterChange после снятия A/B-паузы; код/нативный результат/регистрация учитываются отдельно. OpenCode SKIPPED; Gate6/G4, рабочая миграция и публикация запрещены. Полная приёмка G3 не следует из закрытия только LD1.

## G3-LD1: результат исходного PM5 повтора

[Native PASS](../add-product-project-registry/evidence/g3-legacy-executor-2026-10-25.md), implementation `3645c8e46184284b50573a6164709252533a986c`, single update oldfa0 exit0/331540мс. Current executor довёл master и sibling через прежний owner; новый branch dependency plan и exact pins0.4.15/schema1/locked, clean roots и pending0 подтверждены. Original protected-state rejection, restore-compatible, CF/DB, capsule/history сохранены. Два исправления existing harness (глобальный single-EXE override и чтение optional полей исторических receipts) документированы с failed attempts; mandatory assertions и исходная topology не изменены. Новые проверки/тестовые случаи не добавлялись. Регистрация — штатный RegisterChange после снятой A/B-паузы, authoritative результат этого же head читается из source-delivery Status, без правки tracked приёмки после регистрации. Общая G3 матрица/AC18/39 и memory AC43/G5 не закрываются одним LD1; OpenCode/Gate6/G4/рабочая миграция/публикация остаются в прежних границах.

## G3-LD1: интеграция без потери соседних изменений

[Исходный PM5 повтор на объединённом коде — PASS](../add-product-project-registry/evidence/g3-legacy-executor-integrated-2026-10-25.md), `7ba9f0a3ce6ebd08b227b4b35b65e43fe5b2f99c` → oldfa0, exit0/381883мс. Три конфликта lifecycle.ps1 разрешены rebase на принятый candidate8f7aaee4: сохранены foreign legacy master-only recovery, temporary-patch retirement Bind и наши exact executor/branch dependency plan; старый760 остаётся ancestor, ручных merge/queue правок нет. Первый native proof и конфликт регистрации сохранены отдельно. Та же topology, workload и assertions повторены; новые проверки не добавлялись. Full G3 не закрыт. Факт регистрации финального doc-only head читается из source-delivery Status для product-project-registry-g2; это отдельное доказательство доставки.
