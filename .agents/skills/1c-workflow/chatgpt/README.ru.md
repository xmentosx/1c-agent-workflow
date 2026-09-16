# ChatGPT + Remote Desktop Commander

Этот каталог — необязательный ChatGPT-sidecar, установленный **внутри конкретного ITL-проекта**.
Он является частью `.agents/skills/1c-workflow`, поэтому версионируется и обновляется вместе
с workflow текущего worktree. Для работы чату нужен только `PROJECT_ROOT` рабочей ветки.

Sidecar не меняет обычную работу Codex, не переписывает `.codex/config.toml`, не подменяет
локальные `.agents/skills` и не требует отдельного checkout `1c-agent-workflow`.

## Архитектура

`ChatGPT -> Remote Desktop Commander -> PROJECT_ROOT -> локальные rules / skills / MCP`.

Bridge находится по пути:
`<PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py`.
Канонические правила, ITL-команды и MCP-конфигурация всегда берутся из того же `PROJECT_ROOT`.
Ни master-worktree, ни внешний workflow-source для работы чата не используются.

## Доставка в рабочие ветки

Sidecar входит в managed-каталог `.agents/skills/1c-workflow`. Поэтому bootstrap/update-workflow
устанавливает его в проект, новая dev-ветка получает его как tracked content, а обычные
`itl-refresh`, `itl-refresh-lite` и reset переносят/восстанавливают его существующим lifecycle.