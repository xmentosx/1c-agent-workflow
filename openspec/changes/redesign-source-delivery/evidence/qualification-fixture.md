# Checkpoint B: повторяемые qualification fixtures

Пользователь подтвердил описанную в design.md границу 2026-10-12.
`scripts/source-e2e-fixture.ps1` сохраняет immutable capsule через действующий
installed `release-e2e-snapshot`, проверяет SHA и создаёт отдельный Git project.
Source-only lifecycle adapter переносит branch context, затем действующий
guarded `release-e2e-restore` восстанавливает его базу. Нового координатора нет.

Capsule связывает Git endpoints и необходимые pending commits, database dump,
state/environment/config bytes. Чужие branch refs и runtime ownership не
переносятся. Исходные pending/cursor и отсутствие trusted Designer baseline
сохраняются; старый verification green не становится proof нового проекта.
Обычный installed fork сохраняет прежнюю transient-state cleanup policy.

Develop каждый раз начинает из того же capsule в новом owned target. Release
продолжает ready target того же кандидата; незаконченный target сохраняется,
повтор штатной команды создаёт следующий из прежнего capsule. Изменение seed
требует явного Capture -Recapture после проверки причины; прежние artifacts
не перезаписываются. Update/refresh выполняют ожидаемый переход baseline к
exact candidate. Capsule создаётся один раз для фазы, вне обычного Targeted.

Адресные проверки используют настоящий Git bundle/clone/worktree, включая
detached pending endpoint, и реальный PowerShell 5.1 child на пути с пробелом
и кириллицей. Они проверяют отказ с exit23, stdout/stderr/argument round trip,
SHA corruption, ownership escape, повтор Develop, продолжение Release и
сохранность seed. Dump/Restore в этих fixtures подменены; это не live proof.
Интеграционный focused proof: 88/0/0, 119.11s; suites factory, catalog,
host selection и Develop qualification. Ignored artifact:
`build/redesign-source-delivery/candidate-protocol/fixture-integration.xml`.
Неверный published baseline отклоняется до вызова snapshot owner. Изменение
reuse-only child dependency меняет реальный journey fingerprint. Delivery
process owner сохраняет отсутствие live journey route и выбирает адресный
factory consumer test; factory/adapter выбирают upgrade. Два прежних размерных
ожидания catalog выросли ровно на новый suite, прежние множества сохранены.

Регистрация этой единицы, реальные PM5 negative/positive, два кандидата,
fresh passed/export SHA и измерения подготовки ещё должны быть выполнены.
Исходный negative source SHA:
`67cd5e318d5b2c40d3cb513a435b7c2b07fac24572915d314c80b7cce3289782`.
Публикация этой записью не заявляется.

Первая регистрация 6f9bd195 остановилась за154710ms: пять исходных вариантов
ReleaseProgressObservation извлекали production assignment с новым
`releaseFixtureRoot`, но fixture задавал только прежний `E2EProjectRoot`.
Контекст fixture связывает эти переменные с тем же исходным root; пути,
native progress workload, idle/hard limits и assertions сохранены.
Failed proof сохранён в ignored `candidate-protocol/rejected-6f9bd195`.

Следующий Targeted обнаружил два прежних AST fixtures SourceDeliveryPlan без
новых аргументов FreshProjectsRoot/releaseFixtureRoot. Исходные проверки
передачи client и бюджета сохранены; fixtures задают declared inputs.
DevBranchLifecycle прошёл305 expanded cases за619.43s; это отдельный измеренный
дорогой consumer для последующего аудита маршрута. Failed gate635632ms сохранён
в ignored `candidate-protocol/rejected-2bffcfd4`.

Первый live Capture выявил ошибку выбора endpoint: internal snapshot/restore
отсутствуют в публичном compact runner. Factory использует штатный agent-1c.ps1
для этих двух internal actions, как существующий Release runner; update/refresh
сохраняют compact route. Исходный отказ сохранён в Release seed capsule logs
`release-ba8920bf648649f4b13e0db7230e699a`. Native regression исполняет оба endpoint
через настоящий child с exit23 и исходным Unicode round trip.

После этих исправлений SourceDeliveryPlan прошёл27 случаев; восемь context
fixtures factory прошли. Native endpoint matrix имеет отдельные owned roots
для двух параметров и прошёл2/0/0 за1.78s. Focused artifacts:
`candidate-protocol/fixture-repair.xml` и `candidate-protocol/fixture-native.xml`.
Финальный exact-tree Targeted остаётся владельцем приёмки всей единицы.

Live snapshot завершился с DT SHA
`a40fefd5c8c6daeda8dd029cec3e1256444c94723fa960263040db132ecd11b1`,
но seal остановил strict dirty guard: опубликованный baseline не игнорирует
`.agent-1c/qualification-fixtures`. Это ошибка factory/fixture, не повод
ослаблять guard или править installed .gitignore. Capsule теперь находится
в common Git `itl/qualification-fixtures`, claim — рядом с owned project,
DT — в существующем ignored snapshots. Test seed использует настоящий
`templates/gitignore.append` опубликованного baseline и проверяет clean всех
четырёх seed/target roots. Два созданных failed cache каталога сохранены
в `D:/Git/itl-workflow-e2e-pm5/.git/itl/qualification-failed-20261012`;
main seed снова имеет0 dirty paths. State/cursor/versions вручную не менялись.

Targeted7ee7208b закончился за616199ms; 304/305 lifecycle cases прошли.
Исходная normalization regression упала на sharing violation stdout после
завершения native child. Owner `Invoke-NativeProcessAndWaitResult` теперь
подтверждает освобождение двух файлов вывода с ограничением10s перед возвратом.
Это завершение existing redirected IO; отдельного координатора нет. Только
sharing/lock violations ожидаются; прочие IO errors сразу выходят. Timeout
сохраняет captures и даёт повтор исходной операции после диагностики writer.
Причина согласуется с [контрактом .NET timed WaitForExit](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.waitforexit?view=netframework-4.8.1):
завершение процесса не гарантирует завершения асинхронного вывода.

Focused proof после исправлений:13/0/0 за28.01s, включая неизменённую
исходную normalization regression, bounded locked-output continuation,
реальный shared native helper с exit23 и полными Unicode stdout/stderr,
capsule/clone на настоящем baseline ignore. Artifact `fixture-output.xml`.
Повторный широкий route factory через release-runtime удалён: его собственный
contract уже выбирает адресные tests и upgrade; production lifecycle routes
сохранены. Обязательный Targeted для изменённого shared core остаётся широким.

Единица39b59aa9 зарегистрирована:1408 passed/0 failed/0 skipped,
65 executed/13 reused, check1210343ms; tracked tree clean. Полный raw proof
сохранён в ignored `candidate-protocol/accepted-39b59aa9`.

Следующий live Capture Release сохранил snapshot, но остановился до sealing:
`lastEnterpriseAutoUpdateResultPath` у rel-e2e-r8 указывал на исторический
`itl-workflow-e2e-pm5-release-fixture-r4`, зарегистрированный в том же common Git.
Factory теперь разрешает до DumpIB только этот конкретный вид receipt из
зарегистрированного worktree; переносит один файл с SHA в owned branch и
переписывает его точную ссылку. Исторические branches, state и базы не импортируются.
Изменение receipt инвалидирует capsule. Остальные ссылки вне seed остаются отказом
с owner continuation до snapshot. Исходные state/receipt не редактируются.
Адресный Windows PowerShell5.1 proof:14/0/0 за29.16s, включая обе новые границы.
Тестовый PS1 с новыми буквальными Unicode fixtures сохранён с UTF-8 BOM.
Live negative/positive и два кандидата ещё не подтверждены.
