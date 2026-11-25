# Однократная подготовка путей fingerprint и приоритет дорогих наборов

Исходная принятая единица `3e589904`: Targeted 150/0/0, 12 executed, 0 reused,
check438640ms/raw448524ms. Цель300s не достигнута. Каноническая raw-запись:
`itl/runs/20261011-050122-512-targeted-a3d36e2901284f3da3dfa388cd7d2964.json`.
Штатный Status подтвердил прежний basefa0/head3e589904/activeOperationnull;
tracked state обоих owned checkout чист. Это не публикация.

Scheduler показал fingerprintPlan41696ms, workerSpan376029ms. Первые четыре
группы перекрывались144.57s. LocalTargetedSelection222973ms,
LocalShardCache160943ms, Fresh182792ms, Long144639ms. SourceQualityCatalog
получил default weight1 и стартовал поздно: фактически152290ms. ReleaseGate
serial tail17537ms шёл после parallel. Время файлов не складывается в wall time.

## Исправление у существующего владельца

`Get-ShardInputDigest` повторял обход контрактов и tracked path patterns для
одного теста при построении текущего и legacy runtime/environment вариантов.
Теперь один local reference на item удерживает только разрешённые пути одного
неизменяемого catalog/tracked-inventory snapshot. Следующий item получает новый
reference. Ключ выбора различает selected tests и additional inputs; изменение
любого из них заново разрешает набор. Unknown owner/nonreusable admission
сохранены. Runtime/environment строки, file identities, digest encoding,
проверки результата и правила legacy admission не изменены.

Это временное значение в существующем planner, без нового durable cache,
координатора, lock, recovery или authority. Оно не переносится между запусками.
Catalog/inventory snapshot не меняется во время построения плана, как и
существующий tracked file identity snapshot. Произвольному внешнему caller
не обещана повторная проверка деклараций после их мутации с тем же reference.

[Сравнение](prepared-inputs-benchmark.json) использует настоящий текущий
repository input set для тех же12 файлов и96 вариантов: old definition44087ms,
prepared4793ms, все96 digests совпадают. Обе реализации видят одинаковые
текущие bytes; runtime identity закреплена на недавнем наблюдённом receipt.
Это определение fingerprints без Pester/gate dispatch, а не свежая runtime
квалификация или замер полного Targeted. Повтор возможен через явный
`measure-prepared-inputs.ps1 -RepositoryRoot ... -AcceptedSummary ... -OutputPath ...`.

Новая регрессия сравнивает current/legacy/global/override варианты, сохраняет
owner-byte invalidation, переподготавливает selected test/additional inputs
и отклоняет unknown/excluded tests. Она вместе с прежней unknown-runtime
регрессией прошла на PS5:2/0. Изменённый scheduler должен пройти штатную одну
RegisterChange всей связной единицы с настоящими cache/shard/process tests.

## Стоимость и зависимости

Ordering weights привязаны к именованным JUnit3e589904: сумма case seconds+5,
округлённая вверх. SourceQualityCatalog153, LocalTargetedSelection224,
LocalShardCache162, Fresh183, Long145. Исторические capacity comparisons
не переписаны. Эти оценки помогают порядку запуска и не доказывают новый budget.

Все шесть static cache tests разобраны в [ledger](static-cache-review.csv).
Их исходник полностью совпадает с frozen inventory. Пять проверяют разные Git,
путь, cache integrity и trust boundaries; последняя проверяет wiring по source
offsets и сохраняет behavior-proof follow-up. Симулированный retry75 не является
реальным Develop/E2E. Предыдущий native результат3e589904:6/0,19351ms.

Новый owner `develop-static-qualification-cache-tests` включает actual
check/static-qualification/release-qualification/runtime/git-path inputs.
Fixture не читает реальный quality catalog и не выполняет scheduler, worker,
resolver, timings или Develop E2E; эти связи убраны. Catalog-only остаётся
быстрым selection proof, а static cache file не ослаблен и остаётся в Full.
Положительные/отрицательные routes и mutation canary проверяют эту границу.

Единица зарегистрирована как `fccd40483b059ba2757aae4b1470017bae5cf53a`, tree
`fe5265dd3a519bbba1ff8a98538710be60c13bf1`: Targeted 156/0/0, 13 executed / 0 reused,
check 388505 ms, raw 394135 ms. Raw:
`itl/runs/20261011-052633-556-targeted-37e2946d99e0490297efba493c163728.json`.
Fingerprint preparation заняла 11545 ms. Cohort отличается от прежнего запуска;
это не сравнение скорости полного gate на одинаковой нагрузке. Цель пяти минут
остаётся недостигнутой. Продолжаются полный necessity audit, подготовка
компонентных сред и реализация подтверждённого пользователем checkpoint C.
