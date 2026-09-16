# ChatGPT + Remote Desktop Commander

Этот каталог — необязательный sidecar для работы с установленными ITL-проектами из ChatGPT.
Он не участвует в обычной работе Codex, не устанавливается в проекты и не изменяет их
`.codex/config.toml`, `.agents/skills`, client adapters или lifecycle helper.

## Архитектура

`ChatGPT -> Remote Desktop Commander -> локальный проект / mcp_bridge.py -> MCP`.
Канонические правила и команды всегда остаются внутри выбранного проекта. ChatGPT-wrapper
только читает локальный `SKILL.md` и выполняет его через Remote Desktop Commander.

## Быстрый старт без plugin import

Скопируйте `bootstrap-prompt.ru.md` в новый чат, замените `<PROJECT_ROOT>` и `<WORKFLOW_ROOT>`.
В сообщении явно подключите `@Remote Desktop Commander`. Этот режим не требует ChatGPT Skills.

## Отдельный ChatGPT plugin bundle

Для workspace, где доступен импорт plugin marketplace, укажите GitHub-репозиторий workflow
и `Path=chatgpt`. Манифест `chatgpt/.agents/plugins/marketplace.json` публикует только
`itl-workflow-chatgpt` и ограничивает его продуктом `CHATGPT`; корневой Codex marketplace
не создаётся и обычный локальный Codex этот sidecar автоматически не обнаруживает.

Plugin содержит `project-connect` и thin wrappers для `itl-*`. Remote Desktop Commander
должен быть отдельно доступен в чате; sidecar не регистрирует и не заменяет его app/MCP.

Bridge требует Python 3.11+ и только читает MCP из `<PROJECT_ROOT>/.codex/config.toml`.
Примеры:

```powershell
python <WORKFLOW_ROOT>\chatgpt\mcp_bridge.py --project-root <PROJECT_ROOT> project-info
python <WORKFLOW_ROOT>\chatgpt\mcp_bridge.py --project-root <PROJECT_ROOT> tools-list --server 1c-code-metadata-mcp
python <WORKFLOW_ROOT>\chatgpt\mcp_bridge.py --project-root <PROJECT_ROOT> tools-call --server 1c-code-metadata-mcp --tool metadatasearch --arguments '{"query":"Документ"}'
```
