# Приоритеты по стоимости и повторным отказам

Объём уточнён пользователем 2026-10-12: полный inventory и маршруты сохраняются,
сплошной индивидуальный разбор оставшихся определений не требуется. Число
прочитанных тестов не принимается как показатель ускорения или сокращения.

## Наблюдения из существующих регистраций

| Источник | Полное время | Исполнено / reused | Наблюдение |
| --- | ---: | ---: | --- |
| rejected-8d344c50 | 474188 ms | 38 / 86 | Новый consumer guard отсутствовал в ожидании selection; SPPR six-request overlap отказал |
| rejected-8777640e | 148439 ms | 14 / 112 | Selection исправлен; SPPR four-request overlap отказал |

Во втором прогоне fingerprintPlanMs=30557, workerSpanMs=107563. Самый долгий
исполненный shard — HostSourceRuntime (106918 ms), затем HostMantis (53165 ms),
HostSppr (26185 ms, failed), ParserDocsBudgets (22927 ms), OnDemandGo (21559 ms).
Cached duration старых reused workers не суммируется как время этого прогона.
Это два разных дерева и состава: сравнение не доказывает ускорение изменения.

HostSourceRuntime намеренно создаёт частную среду, удаляет tzdata и принимает
восстановление через исходный SPPR corpus. Это отдельный риск от обычного SPPR
прогона; удаление corpus acceptance или уменьшение workload не обоснованы.
Повторяется из-за cumulative legacy registration и неизвестной внешней runtime
identity. Приоритет после live — доказать безопасный owner input/runtime reuse
и измерить warm регистрацию; просто включать reuse по имени suite нельзя.
31 s fingerprinting также требует отдельного сравнения при одинаковых входах.

## Диагностика SPPR

После двух отказов общий Targeted вслепую не повторялся. Тем же isolated Python
и штатными native Pester wrappers выполнены ограниченные диагностические наборы:

- HostSppr + HostSourceRuntime, два workers: 5/0, span92643 ms.
- Дополнены HostMantis + OnDemandGo, четыре workers: 8/0, span103755 ms.
- Все14 реально исполнявшихся shards отказавшего прогона, четыре workers:
  75/0, span108743 ms. Raw `sppr-failed-selection.log` и exception trace сохранены.
- Исходные four/six overlap cases, 20 пар: 40/0 за15.012 s.

Диагностика через ignored sitecustomize сохраняла исключения Future.result;
барьер, timeout5, workload, assertions и production scheduling не менялись.
Последние два набора не логировали вход в barrier. Отказ не воспроизвёлся;
BrokenBarrierError и влияние нагрузки остаются гипотезами, не причиной.

Подтверждён отдельный дефект: worker заменял неожиданное исключение общим
SpprError и терял traceback причины из Future. Теперь причина сохранена через
exception chaining, публичный текст и persisted message остаются редактированными.
Регрессия проверяет cause identity, скрытие деталей, сохранность двух committed
vectors и продолжение без повторной отправки. Она и три исходных failure/overlap
cases passed:4/0 за1.258 s. Это улучшение диагностики, не доказанное устранение
исходного intermittent отказа. Новая регистрация проверит исходный native путь
без sitecustomize; при повторе исходная причина станет доступна в traceback.

## Условие результата

Принимать оптимизации по сравнимому cold/warm/retry времени и сохранённым
рискам. Не расширять аудит на сотни новых описаний до завершения текущей live
приёмки. Отдельно подтвердить малую изолированную доработку и параллельную
регистрацию после активации нового опубликованного supervisor.
# Измеренный hotspot DevBranchLifecycle

Protected cache accepted `39b59aa9` содержит 305 passed expanded outcomes:
793036ms shard, 786.123s сумма cases. Manifest/JUnit SHA проверены; mutable
worker XML не используется как историческое доказательство.

Набор разделён на четыре process-isolated файла: load/runtime (152.142s
прежних cases), worktree/provenance (217.334s), fork continuation (153.309s),
merge/recovery (263.338s). Эти суммы задают округлённые scheduling weights,
а не обещают новые длительности. Применяется существующий runner без новой
параллельной authority или увеличения workers.

Все 236 исходных It commands перенесены побайтно по AST extent, включая
TestCases, bodies и assertions; nested Describe/tags сохранены. Общий BeforeAll
вынесен в DevBranchLifecycleSupport.ps1 без изменения statements. Исходные
305 expanded cases должны сохраниться; дополнительный selector regression
проверяет включение всех четырёх shards при изменении shared fixture/core.
Каждый прежний production route исходного набора теперь включает все четыре;
новый fixture route участвует также в вычислении reuse inputs.

Изоляция: TestDrive и GUID repositories принадлежат case; environment/script
state разделены worker-процессами; launcher, port registry и facade fixtures
используют собственные roots. Console Ctrl+C workload в этом наборе отсутствует;
существующий serial tail не изменён. Реальное ускорение и сохранение всех
305 исходных outcomes принимаются только по единственной RegisterChange этой
единицы. Raw proof: ignored build/redesign-source-delivery/candidate-protocol/
lifecycle-split-integrity.json и штатный registration/shards summary.

Фактическая приёмка split: c0b48c89 зарегистрирован446/0/0 за86530ms
после исправления обоих счётчиков количества выбранных файлов. Все305 исходных
cases passed: merge67, worktrees30, fork32, load/runtime176. В исходном запуске
split интервал четырёх групп10:21:27.450–10:26:32.096UTC составил304.646s
против793.036s прежнего single-file shard. Сумма elapsed durations групп
не уменьшилась:283.362+259.572+165.705+178.203s. Выигрыш относится к wall time
за счёт overlap; фоновая нагрузка двух запусков различалась. Общий выпуск этим
измерением не квалифицирован. Raw accepted-c0b48c89 и исходные worker results
сохранены; unchanged группы при исправлении счётчика повторно не исполнялись.

## Runtime identity E2E и layout изолированных тестов

Обнаружена лишняя связь: прежняя journey identity включала целые quality
contracts, включая tests/primaryTest/owner/budgetSeconds, и Pester test paths из
owner paths. Split изолированных тестов поэтому инвалидировал реальный1C
journey, хотя его execution inputs не менялись. Native E2E entrypoints не
исполняют tests/pester/*.Tests.ps1; полный static proof принимается отдельно.

Проекция owner теперь связывает id, paths и reuseInputPaths; неизвестное поле
отключает reuse до классификации. Из file inventory исключены только
tests/pester/*.Tests.ps1. Production scripts, native fixtures/features,
templates/agents, owner routing/budgets самого journey и complete external
binding продолжают участвовать. Schema проекции повышена до2: старый cache
не переинтерпретируется, первая квалификация нового контракта обязательна.

Регрессия изменяет реальный Pester file, tests/primaryTest и статическое описание
owner, записывает exact Targeted proof и подтверждает reuse ancestor journey.
Unknown owner field возвращает unknown identity. Исходные regressions изменения
runtime/external binding, route budget, порчи cache и нового отказа сохранены.
Это исправление разделяет доказательства static и runtime; конечный Develop
по-прежнему требует обе части. Приёмка всей единицы принадлежит RegisterChange.

618186a1 принят штатной регистрацией161/0/0,250166ms, включая все22 journey
regressions. Дополнен оставшийся путь ancestor reuse: после совпадения complete
schema2 journey identity и проверки cache/report SHA, дерева и исходного passed
report допустим exact Targeted descendant с известными quality owners либо уже
разрешёнными continuation scopes. Неизвестный path блокирует reuse. Это локально
для Develop route; Release continuation и его границы не расширяются.
Новая regression требует actual exact Targeted receipt, принимает независимый
known component, отвергает unowned path и прекращает reuse, когда component
добавлен в runtime route. Исходные newer-failure/corruption checks сохранены.
Это доказывает правило continuation на native Git fixture; его применимость
на настоящем стенде ещё требует live-приёмки. Focused1/0; `d7a4dc52` принят штатной
регистрацией149/0/0 за130488ms (raw132797ms),9 executed/0 reused.
Общая live-квалификация выполняется отдельно; этот Targeted не выдаётся за неё.

## Разрыв между parent identity и артефактами настоящего запуска

`d7a4dc52` успешно прошёл upgrade за2324386ms, но manifest сохранился как
schema1 с inputIdentity=null. Повтор на `1c8add7f` начал cold prepare вместо
ancestor reuse и был остановлен до повторения тяжёлого сценария. Прежний proof
сохранён; он не мигрируется в schema2 и не дополняется задним числом.

Родитель check формировал identity только из process env для трёх артефактов.
В обычном запуске exe собирался и устанавливался в env лишь внутри child,
а client CFE выбирался из lock без ручной переменной. Отсутствие этих parent
переменных возвращало unknown identity. Физический default-path regression
также обнаружил потерю пустого списка UI policy при pipeline ConvertTo-Json:
UTF8.GetBytes получал null. Synthetic ExternalBinding fixtures этих границ
не исполняли; успешные прежние unit proofs не доказывали live reuse.

Исправление использует существующих source check/build/download owners:
до journey разрешаются SHA-проверенные archive/CFE/exe и передаются как обычный
artifact binding в identity и в child. Positive child получает тот же binding.
Go source build выполняется один раз до journey; child проверяет его exact
locked bytes вместо повторной сборки. Standalone invocation сохраняет прежнюю
самостоятельную сборку. Client override остаётся внутри actual E2E child и не
загрязняет Full Pester host. JSON canonicalization сохраняет empty/singleton
collection через InputObject. Не добавляются coordinator, cache или новый
qualification barrier: прежние проверки наличия и SHA выполняются раньше,
с продолжением тем же вызовом после исправления названного артефакта.

Новый один regression воспроизводит отсутствие всех optional env, сериализацию
binding через файл с Unicode path, physical SHA verification, default empty UI
policy, отсутствие host env pollution и отказ после подмены CFE. Focused1/0.
Полный набор24 cases первоначально23/1: AST fixture реального qualification
reader не инициализировал новую script variable. После восстановления той же
инициализации, что в check, исходный roundtrip снова прошёл1/0; все его
provenance/corruption assertions сохранены. Общая приёмка принадлежит RegisterChange.

Проверка на настоящем sealed stand и positive stand, без1С и без optional env:
402 tracked inputs, три exact locked SHA, positiveStandBound=true;
artifactPreparation6627ms, total17611ms. Ignored receipt:
candidate-protocol/live-input-binding-probe.json. Это доказательство подготовки
identity, не квалификация journey. Изменённые native input collectors требуют
первой настоящей schema2 квалификации; последующий warm/retry проверяется
отдельно. До неё V.4–V.7 и CA.4 не закрываются.

`ec4074bb` принят штатной регистрацией:598/0/0, check569249ms,
26 executed/0 reused; все24 qualification cases прошли. Это изменение общего
collector/checker, не измерение небольшой независимой доработки. Цель300s
превышена; результат не объявляется within-target. Live Develop выполняется
в отдельном чистом checkout того же commit; его результат ещё не получен.

## Сохранение результата при последующих изменениях

По уточнению пользователя постоянные правила приёмки теперь явно рассматривают
selection, actual cost и reuse applicability вместе с функциональным результатом.
Авторитетный контракт находится в docs/local-quality-gate.md, раздел
`Maintaining selection, cost and reuse`; корневой AGENTS.md содержит короткий
указатель для изменений тестов, выбора и зависимостей. Рост always-on текста:
1398→1415 whitespace words, +17; детали загружаются по этому trigger.
Первая регистрация94e9e925 отклонена только budget assertion:39 passed/1 failed,
check30279ms, owner documentation. Прежний предел1400 оставлял два слова;
обязательный pointer сохраняется, maxWords явно повышен до1420 с rationale.
Review2500 и hard2800 approximate-token limits, все safety contracts и исходный
budget test сохранены. Новый тест не добавляется; меняется явный размер контекста
по действующей documentation-budget policy.
Исправленная единицаa3e2705c зарегистрирована:40/0/0, check27859ms,
1 executed/0 reused, fingerprint925ms/span21086ms. Выбран только ParserDocsBudgets;
Python/1С не запускались. Правила сохранены в Git, но механизм нового supervisor
по-прежнему активируется только после публикации.

Это процедурное требование к существующей приёмке, а не новый runtime barrier,
автоматический порог производительности, формат отчёта или общий gate. Прежние
blocking authority, hard/target limits и dirty/SHA/rollback границы сохранены.
Обычной функциональности не добавляется отдельная live-квалификация; для этого
изменения механизма delivery остаются ранее согласованные warm/retry/live cases.
Применяются существующие regression/plan/shard summaries без теста на каждый
helper. Новое правило не доказывает автоматическое обнаружение смысловых дублей,
любого смешанного монолита или неоправданно широкого owner: это остаётся предметом
review. Неверное утверждение о live reuse предотвращается требованием actual
default parent/child proof и незакрытыми V.4–V.7/CA.4 до его получения.

## Live ec4074bb: native pass, общий JUnit и статический writer

Develop завершился failed за2840462ms при чистом checkout. Upgrade raw passed:
12:14:47.436→12:51:58.742 UTC, отрицательный отказ и rollback, положительная
проверка Vanessa и export сохранены. Native cache впервые содержит schema2
manifest с полным input fingerprint2805a9dd0cedac6a0be678071d01ed2d87a2e0c858728dff95577b7d9129ae65;
route-report SHA54dbad54066364b7009bff5f67c85d7db8e6d2ac579cc94665656316c3ebb2c7.
Schema1 d7 evidence не мигрировалось. Общий Pester passed2900/0/1,
44 executed/132 reused, fingerprint51070ms, workerSpan480075ms.
Один skipped не превращается в passed; standalone fresh до отказа не начался.

Причина отказа — Write-WorkflowQualification копировал pester.xml в себя,
когда OutputDirectory совпадал с каталогом QualificationPath. Исправление
сохраняет этот исходный layout: равные абсолютные Windows paths используют
существующий файл; различные пути по-прежнему копируются. Наличие JUnit,
реальные bytes/SHA, Full input manifest и читатель qualification не ослаблены.
В существующий known FullInputProof case добавлен shared-directory шаг без
дополнительного scheduler запуска или нового It. До исправления исходный
сценарий2/1 с точным IOException на Unicode-path; после guard3/0 за40.98s.

Writer находился в check.ps1, чей полный hash является native input: любое
изменение статического сохранения сбрасывало native proof. Его исправленное
определение точно перенесено в существующий develop-static-qualification.ps1,
уже владеющий Full cache и исключённый из native routes обоих journey.
Checker сохраняет прежний вызов; Full inventory продолжает учитывать модуль.
AST relocation equality сохранена в ignored candidate-protocol/full-writer-relocation.json.
FullInputProof использует теперь реального producer через тот же модуль.
Все три исходных Full input сценария после переноса прошли3/0 за43.12s,
включая shared-JUnit boundary, unknown runtime/external и cache transport.
В существующем known-owner ancestor case добавлено изменение actual static
module path: exact Targeted допускает reuse, unknown path и последующее включение
owner в native route по-прежнему отвергают его; focused1/0 за5.86s.
Это owner-local перенос без нового coordinator, схемы или runtime barrier.
Первый перенос меняет check orchestration и требует новой live-квалификации;
неподходящий старый fingerprint не переиспользуется ради ускорения.
Первая регистрацияc691eb67 завершилась failed за129483ms на одном старом
source-location assertion LocalQualityGate: kind Full искался в check.ps1.
Фактический producer теперь в прежнем static module, его exact relocation
и реальные producer/reader/cache сценарии уже подтверждены. Assertion перенесён
к владельцу с дополнительной проверкой import и function; остальные исходные
Release/develop/reuse/SHA assertions сохранены. Недоисполненные файлы после
fail-fast не объявляются отдельной inventory ошибкой или общим case count.

## Live b801a023: оба native сценария passed, итоговый writer failed

Upgrade2250911ms, fresh2710787ms и Full2905/0/1 passed. Общий Develop failed
за5966552ms: Write-DevelopQualification копировал develop-e2e-summary.json в
себя при совпадении OutputDirectory и qualification root. Исправление Full JUnit
не охватило второго владельца записи; это пробел предыдущего анализа дефекта.
Исходный layout сохранён. Проверены остальные Copy-Item в checker и двух
qualification-модулях: cache операции используют отдельные временные файлы,
ancestor report читается из common Git, Full JUnit уже защищён сравнением paths.

Develop writer перенесён в существующий develop-e2e-qualification.ps1, где уже
находится запись route proof. Он сохраняет байты при равных абсолютных Windows
paths и прежнее копирование при разных. SHA, reader, schema и dirty guards не
меняются. Существующий roundtrip case сохраняет distinct-source шаг, добавляет
same-path запись/readback и прежний отказ повреждённого continuation. До fix:
0 passed/1 failed с тем же IOException; после:1/0,2.77s. Новый It не добавлен.

check.ps1 входит в консервативный native input inventory. Его перенос функции
меняет этот вход, поэтому старые native результаты не объявляются qualification
нового head. Нужен один новый полный Develop; затем неизменные входы и отдельная
Markdown continuation должны подтвердить реальное reuse. Для будущих изменений
writer физически принадлежит уже выделенному qualification owner, а не checker.
Операторские capacity continuations и ограничения описаны в fixture-disposal.md;
этот запуск не является unattended или чистым performance benchmark.
Первая регистрация1b2efa54 отклонена существующим ReleaseGate assertion,
который искал schema4 literal в прежнем check.ps1. Он теперь извлекает именно
Write-DevelopQualification AST из фактического модуля; schema4 и прежние
routing/identity/continuation assertions сохранены. Focused1/0,925ms. Это
исправление source-extraction boundary, не изменение runtime expectation.
## Publication planning runtime and duplicate fingerprints (2026-10-12)

The real Plan for accepted 4b200efb failed before publication: the published
fa0e3c91 supervisor spent 50 seconds against the existing 30-second planning
bound. A read-only producer profile retained its exact code and authority:
Desktop 5.1 took 43.907 seconds and reproduced the bound failure; Core took
14.372 seconds (planning 14.299 seconds) and passed. The actual ordinary Plan
then passed under Core in 19.805 seconds, retaining fa0e3c91 develop authority,
with no required Release capabilities. Its immutable plan is
5e18c4fbc9732f855b4bcf99f8478fda5a75afbbf6b774783009d51de3837433.
No push, timeout increase, fake qualification or authority switch occurred.

The current producer's Desktop profile took 32.447 seconds with the legacy
fallback: both complete input identities were unavailable without source-build
artifact bindings. This remains an explicit limit of that measurement; Core
execution does not prove Desktop meets the bound for this accumulated range.
The profile also exposed duplicate work on the complete-identity path: the
planner first calculated a legacy fingerprint and then replaced it. That
calculation now runs only when the complete identity is unavailable. Existing
legacy exact-tree reuse and unknown-input behavior remain. The existing complete
binding case failed before the change with LEGACY_JOURNEY_FINGERPRINT_DUPLICATED,
then passed 1/0 in 2.623 seconds, including both reusable and missing-ancestor
branches. No new It, shard or barrier was added. This structural proof is not
a measured reduction in full planning time. A native input pattern check proves
source-delivery-plan.ps1 is outside both native journeys; static qualification
still owns it, so this owner-local change need not rerun 1C on matching inputs.
The running cold Develop remains on clean 4b200efb; final warm continuation must
prove actual reuse for the eventual registered descendant.

Ignored profiles and logs are candidate-protocol/plan-profile/{old,current,
old-core}.{json,log}; the real command report is plan-4b200efb-core.log. Temporary
profiling initialization omits dispatch and never changes accepted source,
queue, remote or authority. The real native acceptance remains running.
The first registration caa9e110 rejected two existing checker-extraction cases:
their isolated context omitted sourceE2EArtifactBinding and its path, which the
real checker initializes before route dispatch. BeforeEach now mirrors those
existing null/empty defaults. No production behavior or assertions changed.
Both original cases pass 2/0 in 3.17 seconds, preserving historical report SHA,
no-child reuse and equal planner/checker journey-budget assertions. Accepted
queue head remained 4b200efb; rejected receipts are retained for diagnosis.

## Missing checker input in the planner consumer (2026-10-12)

The prior b801 Full reused SourceDeliveryPlan's 27/0 result with digest
6e63b3fdfc71f789f4d4bebd37d110f8d75e5b9b425775a1f05fb81a866ad061,
created at 07:21 UTC. Its four owning contracts and shared inputs omitted
scripts/check.ps1, although BeforeAll extracts Ensure-DevelopE2ERoute and
Get-DevelopE2EIdentitySha256 from that file. The later actual execution exposed
the missing fixture defaults above. This is a dependency omission; the old
reused result does not prove the current checker extraction passed.

A narrow source-delivery-plan-checker catalog edge now binds only the existing
planner suite to the actual checker and its directly imported qualification,
quality, Git path and stand-env collaborators. It selects that consumer when
one of these executable dependencies changes and also includes their bytes in
reuse identity. It does not attach unrelated planner/publication suites to every
checker change. No new It or runtime barrier was added. The existing consumer
mutation regression now includes this suite: checker mutation must invalidate it,
while scheduler/timing mutations must preserve its fingerprint. Before metadata
repair it failed with an unchanged digest; afterward it passed 1/0 in 29.56s.
Existing catalog/readiness/ROCTUP assertions remain. Both native contract
projections are byte-identical before/after this metadata edge (receipt
candidate-protocol/planner-checker-native-projection.json), so the final descendant
must requalify static inputs but may retain genuinely matching native evidence.
The current 4b200efb run's old static result is not final acceptance of this repair;
final Full on the registered descendant must execute the corrected consumer.
Initial registration32bc9a9f stopped97/1: the historical E cohort's explicit
owner list omitted the newly declared checker-consumer edge. The same observed
test-file set and budget model remain exact; only this intentional owner id was
added. Its original case now passes1/0,1.13s. This does not broaden that cohort's
test selection. Rejected receipts remain under rejected-32bc9a9f.

## Cold continuation and bounded failure diagnosis (2026-10-12)

Accepted registrations:4b200efb passed475/0/0 in346170ms (10 executed,
0 reused);6ead2142 passed92/0/0 in54187ms (5 executed,6 reused);
1ed52283 passed98/0/0 in85523ms (2 executed,1 reused). Their original
check, JUnit, selection and shard summaries are retained under ignored
candidate-protocol/accepted-<commit8>. These are registrations, not publication.

Cold Develop4b200efb stopped after2878353ms. Its actual negative rollback and
positive native upgrade passed and were saved before Full. Full stopped with
2558 passed,1 failed,1 skipped (13 executed,123 reused): the existing compact
fresh nonzero continuation case expected7 but observed-2146234327 (0x80131029).
The failed fixture had no retained inner receipts; the failing process boundary
and cause cannot be established from that exit code alone. There is no confirmed
out-of-memory diagnosis and no assertion or production change for this failure.

The unchanged original failing case passed1/0 in12.35s. The entire original
CompactRunnerFreshContinuation suite then passed10/0 in129.23s using its
existing optional receipt retention, original Unicode paths, actual parent and
child processes, deadlines, workload and assertions. Ten console/status/lifecycle
receipts remain under candidate-protocol/fresh-continuation-suite-diagnostic;
JUnit is fresh-continuation-suite-diagnostic.xml. This bounds the diagnosis:
the earlier failure was not reproduced, rather than repaired or explained.

The clean registered descendant1ed52283 continues through Develop, with the
same diagnostic retention enabled. It must reuse only a genuinely matching
upgrade input identity, execute the corrected planner consumer and complete
the still-unverified fresh seed isolation, terminal cleanup and combined writer.
A second identical failure requires diagnosis before another broad retry.

The published fa0e3c91 baseline's retained run
20261010-183300-709-develop-0d627a092b2e4e9280012f2a0414112b.json records
6489926ms overall, upgrade2920953ms and fresh3315488ms, all passed. Cold4b's
actual upgrade stage took2386082ms, but its failed overall47.97-minute run
cannot be compared to a complete release as a successful end-to-end speedup.
The next continuation is mixed (warm upgrade, cold fresh); it must be reported
as such. Do not repeat a valid cold1C journey solely to manufacture a timing
comparison. Final warm/retry and remote-publication observations remain open.

Within the actual1ed Develop Full, CompactRunnerFreshContinuation executed
again and passed10/0 (worker22,136356ms). SourceDeliveryPlan also executed
instead of reusing the obsolete checker-free digest:27/0 (worker35,22407ms).
Their receipts are runtime-proof/develop-1ed52283/pester-shards/worker-22 and
worker-35 result/console/JUnit artifacts. These are actual consumer outcomes;
they do not yet assert the overall Full/Develop result.

The1ed Full subsequently passed2908/0/1:47 executed workers,129 reused,
workerSpan780748ms and fingerprintPlan49681ms. The qualification worktree's
tracked state remained clean. Full/static proof is saved as
runtime-proof/develop-1ed52283/full.json; no separate Full is required for this
tree. Upgrade was reused from4b; cold fresh and overall Develop are still pending.

## Accepted combined native qualification (2026-10-12)

Develop1ed52283 subsequently passed, exit0, overall3890712ms (64.85min).
Upgrade reused the SHA-verified matching ancestor input proof; Full passed
2908/0/1. Fresh actually executed2955607ms (49.26min) and passed the original
bootstrap, branch, missing-suite recovery, golden check, stale-export recovery,
export/SHA, refresh, repeated verification and close workload. This is a mixed
continuation, not a new all-cold benchmark. The largest fresh operation was
verify-golden-change1774054ms; provisioning128788ms, bootstrap305928ms,
export57066ms and close-and-cleanup258381ms. The target1500s was exceeded;
the result does not claim that cold1C qualification is a short ordinary edit.

The actual new project's SOURCE_INFOBASE_PATH referenced the separately claimed
q-project branch database. After close, the original seed was validated through
Capture, with no Recapture: capsule66ca0a9597f5965c9dd5b21f58286d8e0bbccb68ea40a5cb8cf7ac0425f73815
remained unchanged. fresh-source-seed-confirmation.json and the passed
fresh-source-seed-unchanged step retain that proof. Existing terminal disposal
removed the owned source database3295797248 bytes. C had21.93GiB free afterward.
No manual database cleanup or original seed editing occurred during this run.

Both combined full.json and develop.json were produced in the same output
directory; the previously failing same-path writer boundary therefore passed
in the actual workflow. The qualification checkout remained tracked-clean.
Artifacts: runtime-proof/develop-1ed52283/{check-summary.json,full.json,
develop.json,develop-e2e-fresh-raw.json,fresh-source-fixture-disposal.json}.
Final evidence registration, warm descendant qualification, live delivery retry
and published-supervisor parallel registrations remain separate observations.

### Publication checkout identity defect, 2026-10-13

The first authorized c2f18147 publication did not reach push. Pre-operation
cleanup took about 5.5 minutes and reported recurring legacy Release-resource
ownership warnings. The temporary publication worktree then missed the warm
journey proof: scripts/source-e2e-fixture.ps1 was LF in the qualification worktree
and CRLF after Git checkout, with identical normalized UTF-8 content and Git tree.
Its physical SHA changed from d1f2f5e0789b993a5aad91097a1d2c7fc996b4c3995c0470bf4ba928589a9836
to a5ec196fb89f061ff3d777cb77bb3d0270721e46d8b95804a61bcd7ca6450e39.
All three executable artifact hashes matched. The redundant native child was
stopped through Stop-DeliveryProcessTree; the publication owner retained its
failed checkpoint and queue. No push rejection was exercised by this attempt.

Journey input schema 2 normalizes CRLF to LF only in workflow-owned PowerShell
source, retaining BOM and other content. 1C transport, third-party source and
binary artifacts remain byte-exact. A regression covers the equivalent source
identity and rejection of BOM/1C-byte differences. Legacy raw-byte fingerprints
are not rewritten; one fresh qualification is required before warm publication
and push-retry acceptance can be claimed. The legacy cleanup warnings remain a
separate unresolved cost until their owning cleanup contract is repaired.

### Registration deadline fixture, 2026-10-13

Candidate 46b8c309 passed the actual upgrade journey, including the original
negative rollback and positive check/export. Static qualification then rejected
SourceDeliveryCandidateRegistration's deadline fixture: a 550 ms real-time
budget admitted only one iteration under load. The other three real-process
registration cases passed. No push was attempted.

The registration owner now exposes its UTC clock through a private getter.
The same regression advances that clock by 100 ms per gate: it requires six
gate attempts, five failed CAS attempts, one unchanged deadline and one budget
read, then retained checkpoint and the original continuation. This removes
sleep and host-speed dependence without extending the production budget or
changing real-process concurrency assertions. Live publication and parallel
acceptance remain pending until their actual receipts exist.
