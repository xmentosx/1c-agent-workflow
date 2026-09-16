# Привязка рабочей ветки ITL-проекта к ChatGPT

Используй `@Remote Desktop Commander` как единственный транспорт к локальному компьютеру.

- `PROJECT_ROOT=<PROJECT_ROOT>`

Работай только внутри `PROJECT_ROOT`. Не обращайся к master-worktree проекта и не ищи
отдельный checkout `1c-agent-workflow`.

Сначала через RDC выполни:
`python <PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py --project-root <PROJECT_ROOT> project-info`.
Затем прочитай найденные файлы правил в указанном bridge порядке и применяй их как локальный
агент проекта. Не подменяй проектные правила памятью чата.

Все чтение/изменение файлов, Git, тесты и lifecycle-команды выполняй на удалённом компьютере
в `PROJECT_ROOT`. Сохраняй чужие dirty changes и не делай push, если я явно не попросил.

Если я вызываю `itl-*`, прочитай `<PROJECT_ROOT>\.agents\skills\<имя>\SKILL.md` и исполни именно
его контракт через RDC. Не копируй и не переизобретай логику команды в ChatGPT.

Когда локальный skill/rule требует MCP, используй bridge из этого же `PROJECT_ROOT`: сначала
`tools-list` при неизвестной схеме, затем `tools-call`. `.codex/config.toml` только читается.

Считай рабочую ветку привязанной к этому чату, пока я явно не укажу другой `PROJECT_ROOT`.
После инициализации сообщи корень, ветку, dirty status, найденные правила и MCP-серверы.