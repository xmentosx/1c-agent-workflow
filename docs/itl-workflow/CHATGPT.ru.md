# ChatGPT Project + ITL Workflow

Эта инструкция позволяет привязать ChatGPT Project к локальному ITL-проекту через Remote Desktop Commander и работать в его чатах почти как в локальном агентном клиенте.

Для обычной работы ChatGPT не нужен checkout исходного `1c-agent-workflow`: sidecar входит в установленный workflow самого проекта и находится в `.agents/skills/1c-workflow/chatgpt`.

## Какой ChatGPT Project создавать

Используйте отдельный ChatGPT Project для каждого контекста, который должен оставаться постоянным между чатами.

- **master-project** привязан к основной worktree проекта на `master`. Он удобен для `itl-update-workflow`, `itl-refresh-all`, создания веток, `itl-repository-mode`, переключения клиента и других master/lifecycle-задач.
- **dev-project** привязан к одной конкретной `itldev/*` worktree. Он используется для разработки, `itl-check`, `itl-refresh`, `itl-refresh-lite`, `itl-reset-branch`, `itl-result`, MCP, `itl-remote-runner` и остальных задач этой рабочей ветки.

Не привязывайте один ChatGPT Project одновременно к master и к нескольким dev-worktree. Если нужны оба контекста, создайте отдельные ChatGPT Projects.

## Требования

1. В проекте установлен актуальный ITL workflow.
2. В ChatGPT доступен Remote Desktop Commander.
3. В выбранной worktree существует `.agents/skills/1c-workflow/chatgpt/mcp_bridge.py`.
4. В Project Instructions указан точный `PROJECT_ROOT` именно этой worktree.

## Project Instructions для master

Скопируйте этот блок в Project Instructions ChatGPT Project и замените только `PROJECT_ROOT`:

```text
Это ChatGPT Project для основной master-worktree ITL-проекта.

PROJECT_KIND=master
PROJECT_ROOT=<ПОЛНЫЙ_ПУТЬ_К_MASTER_WORKTREE>

Для любой задачи, связанной с проектом:
1. Используй Remote Desktop Commander для доступа к локальному компьютеру.
2. Считай PROJECT_ROOT основной master-worktree этого проекта и выполняй прямые файловые, Git, тестовые, 1С и диагностические операции из неё.
3. ChatGPT-sidecar находится в <PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt.
4. При первом обращении к локальному проекту в новом чате самостоятельно выполни:
   python "<PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py" --project-root "<PROJECT_ROOT>" project-info
5. Прочитай указанные project-info файлы правил в их порядке приоритета и применяй их ко всей дальнейшей работе.
6. Используй локальные skills из <PROJECT_ROOT>\.agents\skills.
7. При любой команде itl-* сначала прочитай соответствующий локальный SKILL.md и исполняй его контракт, не воспроизводя его логику самостоятельно.
8. Для MCP используй локальный mcp_bridge.py и существующий <PROJECT_ROOT>\.codex\config.toml.
9. Для lifecycle-команд, которые по своему локальному контракту управляют зарегистрированными dev-worktree (например itl-refresh-all), разрешай самому workflow/helper находить и обслуживать эти worktree. Не подменяй их пути вручную и не меняй PROJECT_ROOT.
10. Не обращайся к исходному репозиторию 1c-agent-workflow как к runtime-зависимости проекта.
11. Сохраняй посторонние незакоммиченные изменения и соблюдай project safety gates.
12. Если пользователь поручил конечную задачу, самостоятельно мониторь и продолжай работу до её завершения. Обращайся к пользователю только если действительно требуется его решение, разрешение или внешнее действие.
```

## Project Instructions для dev-worktree

Скопируйте этот блок в отдельный ChatGPT Project для конкретной рабочей ветки и замените только `PROJECT_ROOT`:

```text
Это ChatGPT Project для конкретной рабочей itldev/* worktree ITL-проекта.

PROJECT_KIND=dev
PROJECT_ROOT=<ПОЛНЫЙ_ПУТЬ_К_DEV_WORKTREE>

Для любой задачи, связанной с проектом:
1. Используй Remote Desktop Commander для доступа к локальному компьютеру.
2. Работай напрямую только с PROJECT_ROOT и не привязывай чат к соседней master-worktree или другой dev-worktree.
3. Если локальный itl-* skill запускает lifecycle, который сам по своему контракту разрешает/использует master или другие зарегистрированные worktree, исполняй этот skill штатно через PROJECT_ROOT; не выполняй такие действия вручную в обход lifecycle и не меняй PROJECT_ROOT.
4. ChatGPT-sidecar находится в <PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt.
5. При первом обращении к локальному проекту в новом чате самостоятельно выполни:
   python "<PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py" --project-root "<PROJECT_ROOT>" project-info
6. Прочитай указанные project-info файлы правил в их порядке приоритета и применяй их ко всей дальнейшей работе.
7. Используй локальные skills из <PROJECT_ROOT>\.agents\skills.
8. При любой команде itl-* сначала прочитай соответствующий локальный SKILL.md и исполняй его контракт, не воспроизводя его логику самостоятельно.
9. Для MCP используй локальный mcp_bridge.py и существующий <PROJECT_ROOT>\.codex\config.toml.
10. Все прямые Git, файлы, тесты, 1С, MCP и прочие локальные операции выполняй через Remote Desktop Commander именно в PROJECT_ROOT.
11. Не обращайся к исходному репозиторию 1c-agent-workflow как к runtime-зависимости проекта.
12. Сохраняй посторонние незакоммиченные изменения и соблюдай project safety gates.
13. Если пользователь поручил конечную задачу, самостоятельно мониторь и продолжай работу до её завершения. Обращайся к пользователю только если действительно требуется его решение, разрешение или внешнее действие.
```

## Что происходит в новом чате

Project Instructions применяются ко всем чатам внутри ChatGPT Project. Поэтому новый чат не требует ручного bootstrap-сообщения: при первой локальной задаче агент сам запускает `project-info`, читает правила проекта и дальше использует skills и MCP из той же worktree.

Для dev-project это означает, что пользователь может сразу написать, например: `сделай itl-refresh`, `исправь тест`, `проверь и опубликуй результат`.

Для master-project можно сразу вызывать задачи вроде: `сделай itl-update-workflow`, `сделай itl-refresh-all`, `создай новую ветку`, `покажи статус проекта`.

## Удалённые базы и itl-remote

ChatGPT работает с удалёнными стендами через локальный проект:

```text
ChatGPT -> Remote Desktop Commander -> PROJECT_ROOT
        -> itl-remote-runner / itl-remote-agent -> удалённый Windows-хост -> 1С
```

Агент сначала читает локальный skill и его контракт. Доступ к удалённому хосту не означает разрешение на любую базу или изменение: target и разрешённые операции остаются явными по контракту remote runner.

## После обновления workflow

`itl-update-workflow` обновляет managed workflow в master. Существующие dev-worktree получают новую версию штатным `itl-refresh`, `itl-refresh-lite` или `itl-refresh-all`. Путь ChatGPT Project при этом не меняется: sidecar обновляется внутри той же worktree вместе с `.agents/skills/1c-workflow`.

Не храните в Project Instructions пароли, ключи, токены и другие секреты. Они остаются в предусмотренном локальном runtime/credential storage проекта.
