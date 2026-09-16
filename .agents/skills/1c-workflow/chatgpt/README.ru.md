# ChatGPT + Remote Desktop Commander

Этот каталог — необязательный ChatGPT-sidecar, установленный **внутри конкретной worktree ITL-проекта**.
Он является частью `.agents/skills/1c-workflow`, поэтому версионируется и обновляется вместе
с workflow текущей worktree. Для работы чату нужен только её `PROJECT_ROOT`.

Sidecar не меняет обычную работу Codex, не переписывает `.codex/config.toml`, не подменяет
локальные `.agents/skills` и не требует отдельного checkout `1c-agent-workflow`.

## Архитектура

`ChatGPT -> Remote Desktop Commander -> PROJECT_ROOT -> локальные rules / skills / MCP`.

Bridge находится по пути:
`<PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py`.
Канонические правила, ITL-команды и MCP-конфигурация всегда берутся из того же `PROJECT_ROOT`.
Для lifecycle-команд workflow может сам разрешать другие зарегистрированные worktree; ChatGPT
не должен вручную подменять пути или использовать исходный workflow-source как runtime-зависимость.

## ChatGPT Project

Готовые Project Instructions для трёх режимов — основной `master`, конкретная `itldev/*` worktree
и разработка самого source repository — находятся в `docs/itl-workflow/CHATGPT.ru.md`. Этот файл устанавливается вместе
с workflow и предназначен для copy-paste в настройки ChatGPT Project. При нескольких RDC-хостах шаблоны фиксируют стабильный `RDC_DEVICE_ID`.

## Доставка в рабочие ветки

Sidecar входит в managed-каталог `.agents/skills/1c-workflow`. Поэтому bootstrap/update-workflow
устанавливает его в проект, новая dev-ветка получает его как tracked content, а обычные
`itl-refresh`, `itl-refresh-lite` и reset переносят/восстанавливают его существующим lifecycle.
