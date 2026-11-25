# Proposal

## Why

Актуальный develop уже обновляет registry и запускает MCP reconcile при update-workflow
(`Invoke-WorkflowPackagePostCopy` в lifecycle). Но полнота выбора зависит от health,
а ownership доказывает владельца записи, не отсутствие пользовательской правки транспорта.
Поэтому недоступный codechecker блокирует init, а reconcile может заменить ручной URL.
Объединены поручения о сохранении настроек, optional tool failure и свежести registry.

## What Changes

- Обновлять штатные MCP в существующей транзакции workflow, добавлять СППР.
- Сохранять overrides, сторонние записи, auth/policy, отключения и выбор host/config/provider.
- Разделить полноту выбора, identity, capability health и attachment клиента.
- Сохранять подключение при временном отказе; неправильная identity не становится ready.
- Перед fallback после transport/discovery failure обновлять registry и конфигурацию;
  повторять только при потребности, не чаще раза в 60 секунд.
- Ограничить MCP HTTP чтение абсолютным бюджетом, включая SSE heartbeat.

## Capabilities

### New Capabilities

- `managed-mcp-continuity`: безопасное обновление, выбор и восстановление MCP.

### Modified Capabilities

Нет основных specs в текущем репозитории.

## Impact

Существующие владельцы: client-adapters/client-managed.json, vibecoding1c registry/
selection, lifecycle post-copy, endpoint_identity и host publication, MCP recovery
references. Без нового сервиса, coordinator, elevation, SSH, рестартов или установки
на хосты. Локальная реализация и RegisterChange не означают публикацию/live acceptance.
