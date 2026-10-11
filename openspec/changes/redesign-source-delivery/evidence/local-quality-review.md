# LocalQualityGate: необходимость, границы и независимый выбор

В [ledger](local-quality-review.csv) рассмотрены все 56 исходных определений
`fa0e3c91`, включая десять ранее перенесённых в SourceQualityCatalog. Это 73
развёрнутых случая исходной группы: 56 process/mixed cases и 17 catalog cases.
47 определений оставлены без follow-up, у девяти явно записаны ограничения
scope, недостаточное поведенческое доказательство либо историческая модель.
Целые тесты не удалены: эквивалентной безопасной замены пока не доказано.

Повторные запуски внутри cache tests проверяют разные переходы: cold → reuse,
изменение конкретного input, чужой result с корректными SHA, локальный result,
повреждение proof, исчезнувшую dependency и продолжение после отказа. Сведение
всех изменений к одному запуску потеряло бы проверку каждого перехода.
Пять progress cases различают владельца журнала, относительный/абсолютный путь,
idle deadline и hard deadline. Реальные временные границы сохранены.

## Перенос и владельцы

Из оставшихся 46 определений / 56 случаев выделены:

| Набор | Определения / случаи | Production selection |
|---|---:|---|
| PesterCacheCompatibility | 1 / 2 | Scheduler, worker/runtime, quality, Git paths, immutable download |
| PesterShardIdentity | 5 / 10 | Те же владельцы плюс исполняемая функция списка client build inputs |
| ReleaseProgressObservation | 1 / 5 | Check child/progress functions и stand environment identity |
| E2EArtifactCleanup | 7 / 7 | Develop E2E cleanup и Git paths |
| ForkQualificationInventory | 8 / 8 | Check fork receipt consumer |
| LocalQualityGate, остаток | 24 / 24 | Существующие transport, semantic selection, continuation и source wiring |

Четыре Describe перенесены целиком со scoped setup, семь cleanup It — целиком
из Describe без scoped setup. Верхний BeforeAll каждого файла совпадает с
исходным. [Transfer ledger](local-quality-suite-transfers.csv) и
[proof](local-quality-suite-proof.json) подтверждают точный multiset всех It
после переноса; Pester 5.8.0 discovery под Windows PowerShell 5.1 подтвердил
те же 56 expanded names. Assertions, workloads, topology, waits и cleanup
сохранены. Это доказательство переноса, не runtime acceptance.

Исходный LocalQualityGate был parallel file. Новые файлы используют существующий
ограниченный scheduler; новые locks, runtime authority и process coordinator
не введены. Fixture caches принадлежат отдельным Git roots; остальные ресурсы —
TestDrive либо GUID temp roots, launcher files — приватные. Изменения environment
остаются внутри worker process. Реальный Ctrl+C соседней операции и две
конкурентные регистрации по-прежнему требуют отдельной приёмки T05/T06.

У native-input case реальные build/helper/guard файлы представлены synthetic
input bodies. Изменение их содержимого не исполняет production поведение этого
теста, но полный набор остаётся reuse dependency. Список Get-ClientMcpBuildInputPaths
исполняется, поэтому его helper — production selection. Прежний client-mcp-build
contract больше не выбирает остаток LocalQualityGate; эквивалентное доказательство
инвалидации ROCTUP/helper теперь принадлежит PesterShardIdentity. Другие прежние
владельцы остатка не сужены без отдельного анализа.

Catalog/timing edits не выбирают пять выделенных групп. Identity case реально
читает исходный catalog, поэтому сохраняет его в reuse inputs. Cache compatibility,
progress, cleanup и fork fixtures не читают этот catalog как собственные данные.
Full продолжает включать все файлы. Smoke также сохраняет весь прежний набор
56 cases через явные пять дополнительных файлов; ускорение и scope самого Smoke
этой единицей не объявляются завершёнными.

## Измерения и проверка

Названный неизменённый worker-1 регистрации `012a1225` прошёл 56/0/0 за 615.16 s
Pester (worker duration 616654 ms). Его JUnit case times суммарно 613.391 s.
[Cost receipt](local-quality-costs.json) содержит SHA источника и суммы по новым
группам. Ordering weights округлены вверх от case sums + 5 s на setup: 67, 159,
122, 17, 6 и 275 s. Это переиспользованные измерения до разделения плюс явная
оценка setup, а не измерение ускорения нового Full или публикации.

Focused SourceQualityCatalog: 36/1 за 45.73 s. Единственное падение — точный
owner set Develop cleanup после добавления выделенного contract. Сценарий,
путь и пустой live journey set сохранены; expected owners расширены двумя
реальными владельцами. Повторён только этот исходный случай: 1/0, 15.57 s.
Новый selection test прошёл: прямые routes каждого файла, обязательные shared
inputs, отрицательные catalog/timing/build-fixture/ROCTUP routes. Существующая
digest regression сохраняет catalog-byte и helper-byte canaries с новым owner.
Уточнённые selection/cache cases повторены вместе: 2/0, 8.52 s; четыре новые
группы сохраняют digest при изменении неиспользуемых catalog bytes, identity
group инвалидируется; все пять явно сохраняются в прежнем Smoke coverage.
Дорогие process suites отдельно повторно не запускались: их исполняет одна
RegisterChange связной единицы после commit.

## Что осталось

Остаток LocalQualityGate всё ещё смешивает transport, semantic selection,
qualification/continuation и source wiring. Девять follow-ups не закрыты переносом.
Source presence не доказывает реальную последовательность вызовов; проверка
fixture runner-v1/v2 не меняет настоящий scheduler; положительный export cleanup
не доказывает отказ по invalid SHA. Эти границы указаны в индивидуальных строках.
Аудит всего inventory, внешние runtimes, общий кандидат и конечная публикация
остаются незавершёнными; число разобранных строк не является release gate.

Явное воспроизведение ledger — `evidence/build-local-quality-review.ps1` с
`-RepositoryRoot` и optional `-HistoricalJunit`; без последнего cost/history
не объявляются известными. Скрипт не запускает тесты и не является routine check.

## Принятая регистрация и оставшаяся стоимость

`2a8c205296b3fc3379d205be4c82b2a5243992f5`, tree
`7da66f15565b4cb12b18e21385ddd015c0bba5a1`, зарегистрирован в прежнюю очередь
base `fa0e3c91`: 206/0/0, 14 executed / 0 reused; check 390564 ms, raw 392909 ms.
Исходная запись:
`itl/runs/20261011-010515-268-targeted-99daae6192dd43a58f9d898aa804073b.json`.
Штатный Status подтвердил head `2a8c2052`, activeOperation отсутствует;
tracked state основного рабочего дерева чист. Это не публикация.

Целевой бюджет 300 s превышен. Канонический scheduler summary связывает
LocalQualityGate 24 cases с 311827 ms, ReleaseReadiness 19 cases с 229278 ms,
DevelopE2EQualification 20 cases с 201653 ms. Эти суммы нельзя складывать в
wall time: группы выполнялись параллельно. Source-quality-gate всё ещё выбирает
смешанную группу потребителей для checker/timing изменений. Следующая работа
должна уточнить их реальные production dependencies и остаток LocalQualityGate,
сохраняя исходные native scenarios. Нельзя объявлять пяти минут достигнутыми,
поднимать целевой бюджет или заменять process boundary арифметикой.
