# Tasks

## 1. Контракт и миграция

- [x] 1.1 Подтвердить Architecture Checkpoint из design.md: installed-state migration; результат — явное решение пользователя «реализуй» 2026-10-13. Локальный vibecoding1c затем явно вынесен пользователем в отдельную задачу.
- [x] 1.2 Ввести единый baseline/exception resolver для всех managed dependencies, включая fork правил; проверить штатный набор, sparse lock и чужие записи в `DependencyLocks.Tests.ps1`.
- [x] 1.3 Перевести legacy CLI/JSON/env fresh/locked на новую политику с отчётом custom pins и продолжением той же команды; проверить оба режима, явные решения и сохранение Unicode/whitespace путей.

## 2. Хотфиксы и consumers

- [x] 2.1 Реализовать применение/снятие исключения существующим helper; проверить older/equal/newer, downstream revision, разные SHA и несравнимые fork, видимость в status и сохранение при неудаче.
- [x] 2.2 Подключить установщики, MCP facade и compatibility catalogs к одному решению; проверить согласованный Vanessa-комплект, ROCTUP tools/list и SHA source-build overrides в непосредственно затронутых `OnDemandMcp`, `VanessaPatchedArtifact` и `AiRulesMigration` тестах.
Локальный vibecoding1c исключён из реализации явным решением пользователя; отдельная задача описана в [follow-up-local-vibecoding.md](follow-up-local-vibecoding.md).

## 3. Обновление, recovery и приёмка

- [x] 3.1 Встроить миграцию и снятие исключений в существующие per-root update/rollout/snapshot; в `WorkflowUpdateRollback.Tests.ps1` проверить сбои после замены lock, после commit, busy/deferred, повтор и поздние пользовательские edits.
- [x] 3.2 На изолированной копии согласованного стенда проверить реальные файловые update fresh/locked, scoped hotfix, его сохранение/снятие, busy/deferred и повтор без refresh, rollback с точным возвратом lock и сохранением позднего постороннего файла. Результаты и identities — в `test-evidence.md`. Нативные init/CFE/MCP/client reload явно перенесены пользователем на отдельный прогон после отказа лицензии; они остаются неподтверждёнными, см. `follow-up-native-acceptance.md`.
- [x] 3.3 Обновить templates и инструкции, согласовав замену старого locked-контракта из `upgrade-ai-rules-upstream-20a083e5`; проверить отсутствие самостоятельного выбора latest и описанное продолжение каждого отказа.

Доставка: один итоговый локальный commit/RegisterChange по `docs/local-quality-gate.md`.
Регистрацию того же head подтверждает source-delivery Status; checkbox после неё
не изменяется. Публикация остаётся отдельной операцией.
