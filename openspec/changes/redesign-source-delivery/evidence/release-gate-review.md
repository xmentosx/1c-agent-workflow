# ReleaseGate: предметный аудит и разделение suites

Разобраны все 33 оставшихся определения `It` исходного ReleaseGate: 46
исполняемых вариантов, 35 решений retain и 11 retain-with-scope-follow-up.
Для каждого в [ledger](release-gate-review.csv) записаны риск, входы, уровень,
ресурсы, историческая стоимость, ограничения и текущий путь. Каждый normalized
body SHA совпал с frozen baseline `fa0e3c91`. Это не завершение всего аудита
166 файлов / 2814 определений. Шесть budget definitions были перенесены ранее
в SourceQualityCatalog; они не удалены и не входят повторно в эти 33.

Ни один рассматриваемый case не удалён. Необходимость сохранения не означает,
что текущая гранулярность, имя или уровень доказательства оптимальны. История
flake каждого случая отдельно не исследована; неизвестная история не является
основанием удаления.

## Что действительно стоило времени

Исторический `runtime-proof/release-gate-case-costs.json` сверён с его существующим
sourceResult: старый shard 46/0, 644892 ms. Это исходное измерение, не свежая
квалификация новой ветки и не настоящий 1C E2E.

| Группа | Definitions / expanded | Исторические case seconds | Решение |
|---|---|---|---|
| Release gate scripts | 14 / 14 | 5.923 | Оставить в ReleaseGate |
| Release E2E orchestration | 1 / 1 | 280.647 | ReleaseOrchestration |
| Develop upgrade manifest continuation | 3 / 10 | 323.170 | DevelopManifestContinuation |
| Unattended E2E client selection | 6 / 7 | 5.446 | E2EClientSelection |
| Application snapshot continuation | 1 / 4 | 0.122 | ReleaseSnapshotContinuation |
| Shared Release admission decisions | 8 / 10 | 26.281 | ReleaseAdmission |

Orchestration содержит 14 native runner вызовов: отказ server reset, отказ
extension, восстановление, повтор, managed advance, pending refresh,
harness-only repair, LF/CRLF materialization, corruption, legacy checkpoint,
изменение helper, Restart, отсутствие server stand и повреждённый checkpoint.
Состояние между вызовами существенно. Все вызовы, topology, assertions, fixture
flags и workloads сохранены. Fake helper и synthetic infobases ограничивают
доказательство; оно не заменяет реальную Release квалификацию.

Manifest matrix проверяет положительное продолжение того же refresh, восемь
разных неподдерживаемых конфликтов и последующую пользовательскую правку.
Отказы сохраняют manifest/state/index/raw log/HEAD/MERGE_HEAD; они не являются
эквивалентными повторами. Client selection сохраняет одиночный выбор, два
публичных entrypoints, неоднозначность и identity/cache cases. Snapshot matrix
покрывает четыре сочетания источника snapshot и состояния подготовки.

## Границы выбора и переиспользования

Ранее source-quality-gate выбирал весь ReleaseGate для checker, selector,
timings и qualification. Теперь checker/selector/timings выбирают оставшиеся
14 быстрых случаев; native orchestration и manifest matrix имеют своих owners.
Прямое изменение каждого выделенного тестового файла выбирает именно его.
Release runner выбирает четыре своих группы, Develop runner — manifest/client.
Semantic release fallback сохраняет все шесть файлов.

Orchestration исполняет Release entrypoint и его imports: stage modules,
qualification, process/JSON, stand identity, Git paths и quality contracts.
Admission исполняет свои admission/transition owners. Для managed transition
построен консервативный статический call graph от Get-CurrentCommit и
Assert-DevBranchForkWorkflowTransition: восемь libraries — core, lifecycle,
runtime-values, ai-rules-migration, client-adapters, vanessa, vibecoding1c-mcp,
yaxunit. Они входят в production selection обоих owners. Dynamic definition
loading не объявляется полностью доказанным статическим графом: все helper
scripts дополнительно остаются в reuse inputs.

Go/build/assets/templates в orchestration являются копируемыми или fingerprint
inputs: fixture флаг исключает реальную сборку facade. Они сохраняются в reuse
inputs; их изменение не выбирает synthetic Release вместо собственного owner.
Fingerprint recipes stages дополнительно покрыты remote-runner scripts,
Vanessa/client build helpers и vendored client sources. Узкое ROCTUP изменение
сохраняет прежний собственный Targeted route; изменение загружаемого ROCTUP
helper всё равно инвалидирует Full reuse orchestration/admission. Регрессия
проверяет обе стороны, включая прежний LocalQualityGate consumer.

Все шесть Release файлов сохраняют прежний serial admission. Удаление этого
ограничения требует отдельного доказательства изоляции. Scheduler weights
10/285/328/10/5/31 seconds — оценки из исторических групп с allowance на setup,
не измеренное ускорение Full. Разделение добавляет setup отдельных файлов;
выигрыш ожидается от исключения ненужных групп из небольшого Targeted.

## Сохранённое доказательство и приёмка

[Transfer ledger](release-suite-transfers.csv) и [AST proof](release-suite-proof.json)
подтверждают точное сохранение всех шести Describe blocks, верхнего BeforeAll
каждого файла и всех 33 полных It commands, включая ForEach/tags. Pester discovery
подтвердил 46 вариантов. Это проверка переноса, не native исполнение.

В ignored `build/redesign-source-delivery/release-split/`:

- `isolated-fast.xml`: client/snapshot/admission suites отдельно прошли 21/0/0,
  17.12 s. Native manifest/orchestration оставлены одной RegisterChange этой
  связной единицы, без дублирующего дорогого focused прогона.
- `catalog-revised.xml`: 34/2; исходные scope assertions сохранены. Два новых
  expectations были неточны: порядок owners и забытый прежний LocalQualityGate
  consumer ROCTUP helper. `catalog-closure-repair.xml`: эти два случая 2/0,
  5.65 s после исправления ожиданий, без изменения production contracts.
- Selection, 57-file historical cohort и три дополнительных Release consumers,
  budgets, пустые live journeys и прежний ROCTUP route прошли. Новая selection
  regression проверяет реальные catalog projections, а digest regression меняет
  байты catalog и загружаемого helper в Unicode/whitespace fixture.

11 follow-ups сохраняют ограничения scope: source/AST wiring не доказывает
runtime; fake snapshot/helper не доказывает настоящую сохранность базы;
dotenv case не исполняет запрет произвольного target; overlap арифметика без
process handles не доказывает одновременность; прямой corrupt-SHA helper не
доказывает весь runner branch. Эти случаи пока оставлены с честной границей.
RegisterChange завершён для `012a122588fa78e674138760536101465b06db76`, tree
`4a30d30d5c8ca04cdcd23266c94e9443227f3999`: 246/0/0, 16 executed / 0 reused,
check 1308567 ms, raw 1310953 ms. Исходная запись:
`itl/runs/20261011-003147-933-targeted-cc873328578e4d38af0032cd06d81177.json`.
Штатный Status подтвердил ту же очередь base `fa0e3c91` / head `012a1225`,
activeOperation отсутствует; tracked state child чист. Общий аудит A/B/C ещё
не завершён; публикации здесь нет.
