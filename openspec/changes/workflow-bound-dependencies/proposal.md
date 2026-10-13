# Proposal

## Why

Версии инструментов должны соответствовать установленному workflow. Сейчас `fresh`/`locked`, отдельная миграция fork правил и независимое обновление локального vibecoding1c задают разные правила выбора версий; пользователь хочет единый комплект и только явное временное исключение для хотфикса.

## What Changes

- **BREAKING**: заменить `fresh`/`locked` единой политикой «набор установленного workflow + явные хотфиксы», с миграцией существующих настроек.
- Свести выбор версий всех доставляемых ITL компонентов к одному контракту; project lock фиксирует результат и происхождение.
- Добавить применение/снятие точного хотфикса через существующий helper и автоматическое снятие при успешном обновлении на равную или более новую полную сборку.
- Сохранить немедленное обновление workflow, правил и зависимостей во всех доступных рабочих ветках, отдельно от refresh конфигурации.
- Локальный vibecoding1c вынесен пользователем в отдельную задачу: [изоляция версий runtime и данных](follow-up-local-vibecoding.md).

## Capabilities

### New Capabilities

- `workflow-dependency-contract`: единый набор зависимостей, временные хотфиксы, миграция и согласованное обновление worktree.

### Modified Capabilities

Нет опубликованных main specs. Новый контракт намеренно заменяет сохранение `locked` из текущего change `upgrade-ai-rules-upstream-20a083e5`; его обновление всех worktree и recovery сохраняются.

## Impact

Владельцы: общий resolver зависимостей, установщики компонентов и существующая транзакция `update-workflow`. Меняются lock/templates, dependency-mode настройки, диагностика и непосредственно затронутые тесты/документация. Fork правил остаётся отдельным репозиторием; обновление общих удалённых MCP и транзитивная заморозка всей машины вне границ.

Наблюдаемые основания: `templates/dependency-lock.json`; `Sync-WorkflowManagedDependencyLockEntries` в `agent-1c.core.ps1`; точные версии каталогов в `assets/ondemand-mcp/compatibility.json`; `Invoke-WorkflowDevelopmentBranchRollout` в `agent-1c.lifecycle.ps1`; независимые fetch/fast-forward и image tags в `agent-1c.vibecoding1c-mcp.ps1`. Текущий контракт rollout и сохранения locked описан в `openspec/changes/upgrade-ai-rules-upstream-20a083e5/design.md:523–627`.

Реализация ведётся по tasks.md; свидетельства функциональной приёмки записываются отдельно от проверки документов.
