# Acceptance evidence

Локальная постановка и реализация: 2026-10-13, base 81e8f1f3.

| Проверка | Результат |
|---|---|
| MCP config + shared ownership, Windows PowerShell 5.1 shard runner | 88 passed; build/test-results/mcp-continuity-acceptance/junit.xml |
| Последующее уточнение fallback: нет локальных изменений / восстановление локального facade при отказе registry | 2 passed focused Pester |
| Legacy TOML без ownership receipt с inline comment | focused regression сохраняет URL и комментарий при добавлении SPPR |
| Host direct health budget/publication | 7 passed (DirectHealthBudget) |
| Python identity / foreign route / safe health / SSE heartbeat / Unicode child | 14 passed |
| Client adapters / workflow snapshot and ready checkpoint | 41 + 52 passed в build/test-results/mcp-continuity; соседний MCP shard имел исправленную затем ошибку duplicate filtering, весь тот run не считается passed |
| OpenSpec validate --strict | passed |

Основные сценарии: default URL обновлён, override сохранён после двух sync,
SPPR добавлен, legacy/External/auth/disablement не утрачены; свежий Git registry
заменяет старый URL с сохранённым host; вывод не обещает attachment текущему чату.
Уникальный недоступный endpoint проходит Prepare...ForInit без повторного выбора,
но New...RemoteRuntime не сообщает его ready. Foreign identity и timeout внутренней
health при foreign public route не разрешают restart. SSE heartbeat не продлевает
0.3s бюджет до конца двухсекундного потока.

Старое ожидание «health failure делает selection incomplete» намеренно заменено:
полнота настройки и доступность инструмента имеют разных владельцев. Регрессия
небезопасной runtime connection сохранена. Для matched identity safe-call timeout
перенесён в health_error; проверка foreign endpoint сохраняет unverified и отсутствие
safe calls на чужой public endpoint.

Product-docs source SKILL: 7046 → 7523 bytes (приблизительно +477 bytes, сравнение
старого текста с LF и текущего файла). Добавлена маршрутизация bounded recovery,
обязательные запреты на loops/ложный pass не удалялись. Периодичность 60 секунд
реализуется инструкцией текущего агента, без нового runtime state/coordinator.

Граница доказательства: настоящие init ERPPM5/PM5 на Уфе, live fetch_its,
публикация, установка и attachment/reconnect реального клиента не выполнялись.
Нет нового RPC канала к owning App Server; при его отсутствии результат требует
reload/discovery. Серверы и контейнеры не менялись.

Финальная регистрация и её exact-head Targeted проверяются через source-delivery
Status, а не отдельной копией delivery ledger в этом документе.
