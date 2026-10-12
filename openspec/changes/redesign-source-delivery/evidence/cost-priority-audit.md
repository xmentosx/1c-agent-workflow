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
Так независимая component-правка не заставляет повторять незатронутый1C journey;
затронутый journey всё равно исполняется. Focused1/0; `d7a4dc52` принят штатной
регистрацией149/0/0 за130488ms (raw132797ms),9 executed/0 reused.
Общая live-квалификация выполняется отдельно; этот Targeted не выдаётся за неё.
