# Приёмка фазы B: селекция, стоимость, переиспользование

База сравнения: каталог `origin/develop` 07100006, сравнивается с рабочим деревом фазы B (2026-11-12).

## Селекция (`Resolve-QualityContractsForPaths`, по одному пути)

| Путь | До | После | Изменение |
|---|---|---|---|
| `agent-1c.lifecycle.ps1` | 76 | 76 | — |
| `tests/quality-contracts.json` | 12 | 12 | — |
| `scripts/quality-contracts.ps1` | 22 | 22 | — |
| `scripts/develop-e2e-scenarios.ps1` | 23 | 23 | — |
| `scripts/develop-journey-inputs.ps1` | 20 | 20 | — |
| `scripts/check.ps1` | 22 | 22 | — |
| `tools/itl-ondemand-mcp/main.go` | 7 | 7 | — |
| `references/advanced-actions.md` | 2 | 2 | — |
| `templates/dependency-lock.json` | 3 | 3 | — |
| `tests/pester/FunctionClosure.TestSupport.ps1` | 2 | 3 | + `SourceDeliveryProcessLifetime` (новый потребитель хелпера) |
| `scripts/ondemand-mcp-lock.ps1` | — | 1 | + `OnDemandMcpLock` (новый владелец) |

Существующие пути выбирают те же тесты. `source-quality-catalog` получил только `reuseInputPaths`
(`agent-1c.ps1`, `advanced-actions.md`, `compatibility.json`, `dependency-lock.json`, `main.go`): правка этих файлов
инвалидирует доказательство теста, но тест не выбирает. Регрессии валидатора намеренно перенесены из тяжёлых
`BootstrapUpdate` и `OnDemandMcp` в `SourceQualityCatalog`, который `quality-contracts.ps1` и так выбирает.

## Стоимость

- `ondemand-mcp-lock` (Targeted, до Pester): без изменения входов сборки — пропуск без сборки. С изменённым Go-кодом —
  сборка с кэшем Go и сравнение SHA-256 за 1,9 с (`-BaseRef` перед последней правкой `main.go`).
- Валидатор каталога (реестры действий, версии on-demand): входит в существующую загрузку каталога, около секунды.
- Проверка вызывающих в `Get-DevelopRetainedRuntimeReaderViolations`: `git grep` и разбор ≤2 файлов; на
  реальном репозитории 2,3 с на два вызова (рабочее дерево и коммит); результат по коммиту кэшируется.
- Оценка ёмкости Targeted для исторической lifecycle-выборки (4 полосы, запасной вес 48 с для 56 файлов без
  тайминга): историческая выборка — 2360 с, текущая — 2643 с при лимите 3600 с; запас ≥ 120 с сохранён.

## Переиспользование и безопасный отказ

- `Get-DevelopRetainedRuntimeReaderViolations` числится в списке контроллеров `develop-e2e-scenarios.ps1`, поэтому
  её добавление не меняет идентичность входов сценариев. Проверенный набор лежит внутри функции, кода верхнего
  уровня нет.
- `develop-journey-inputs.ps1` и `check.ps1` изменились (вынос таблицы `Get-DevelopGoInputConsumerAudit`, новая
  стадия). Это законный однократный холодный прогон затронутых Develop-сценариев: правила привязки не сужались.
- Непроверенный вызывающий (фикстура `DevelopBrokerInputScope`) → проекция `$null`, `ProbeOnly` = false, причина
  называет вызывающего. На проверенном коммите → проекция применима.
- Непроверенная правка живого `develop-configuration-rejection.ps1`: `DeliveryGoInputScope` 4/4 зелёный, а
  `Test-DevelopGoBuildOnlyPath` для README в продукте = False, то есть исключение закрыто и вход привязан.
  До изменения этот случай (08ab5644, 2026-11-10) ронял Targeted.

## Исходные дефекты, которые по-прежнему ловятся

- Новое действие без регистрации → `ACTION_REGISTRY_MISMATCH` при загрузке каталога, одним сообщением по всем реестрам.
- Версии 0.4.29/0.4.28 (536c571a) → `ONDEMAND_VERSION_MISMATCH` с обеими версиями.
- Go-код без перепиновки (60fd9956) → `ONDEMAND_LOCK_STALE` до Pester с командой Repin.
- Рост выборки сверх лимита → оценка ёмкости падает и называет крупнейшие вклады.
- ProcessLifetime по-прежнему не зависит от `source-delivery-queue.ps1` и инвалидируется при изменении
  `source-delivery-process.ps1` и `FunctionClosure.TestSupport.ps1` (ProofOwnership 2/2).
