# 1C Agent Workflow

Пакет правил и команд для доработки 1С-конфигураций с помощью агентов в Codex и Kilo Code.

Он стандартизирует рабочий процесс:

- инициализация локального проекта из исходной базы 1С, которая может быть подключена к хранилищу конфигурации или обновляться вручную;
- выгрузка конфигурации в `src/cf` и хранение ее в Git в ветке `master`;
- разработка расширений в отдельных ветках с файлами расширений в `src/cfe/<имя-расширения>`;
- параллельная разработка в отдельных ветках разработки `itldev/<name>` и отдельных Git worktree;
- работа в отдельной копии базы, отвязанной от хранилища только когда исходная база была подключена к нему;
- частичное обновление базы ветки разработки измененными файлами конфигурации;
- обновление ветки разработки свежим `master` из хранилища или из текущего состояния исходной базы;
- выгрузка промежуточного или финального `CF` или `CFE`;
- переход между `master` и ветками разработки через отдельные рабочие папки.

Ветка разработки - это изолированная линия разработки, а не обязательно одна бизнес-фича. В одной ветке можно последовательно выполнять несколько задач, периодически обновлять ее свежим `master` и выгружать `CF`/`CFE` для ручного переноса изменений в исходную базу.

Для одновременной работы по нескольким независимым линиям создавайте отдельные `itldev/*` ветки/worktree. Одна ветка при этом может оставаться долгоживущей и последовательно вести несколько задач, если разработчик осознанно контролирует перенос результатов.

## Документация

Основная инструкция для разработчика:

```text
DEVELOPER-GUIDE.ru.md
```

Процесс разработки внутри уже созданной ветки:

```text
DEV-BRANCH-DEVELOPMENT.ru.md
```

Краткие агентские правила написания Vanessa-проверок для текущей фичи:

```text
VANESSA-TESTS-GUIDE.md
```

Низкоуровневые helper-actions для диагностики описаны отдельно и не являются основным интерфейсом разработчика:

```text
.agents/skills/1c-workflow/references/advanced-actions.md
```

## Состав пакета

- `.agents/skills/1c-workflow` - общий Agent Skill для Codex и Kilo Code.
- `.agents/skills/1c-workflow-fast` - быстрый Skill для регулярных операций через PowerShell-helper без чтения полного workflow.
- `.agents/skills/product-docs` - skill для PM5 product documentation MCP.
- `.agents/skills/itl-roctup-1c-data` - skill для branch-local ROCTUP data exploration.
- `.agents/skills/1c-workflow/kilo-command-templates` - шаблоны коротких slash-команд Kilo Code.
- `.kilo/commands/itl*.md` - локально сгенерированная командная поверхность для текущей папки/worktree; игнорируется Git.
- `aiRules.tools` в `.agent-1c/project.json` - набор upstream-клиентов; по умолчанию `codex` и `kilocode`. OpenSpec-команды для каждого клиента устанавливает `ai_rules_1c`, а ITL создаёт только `/itl*`.
- `scripts/test-ai-rules-compatibility.ps1` - отдельная network compatibility-проверка актуальной `ai_rules_1c` для Codex и Kilo; она не входит в быстрый Pester-прогон.
- `AGENT-INSTALL.md` - bootstrap-инструкция для агента.
- `install-agent-1c-workflow.ps1` - one-step bootstrap script: копирует managed workflow-файлы в целевой проект и запускает monitored init wizard.
- `VANESSA-TESTS-GUIDE.md` - compact agent rules for writing Russian Vanessa feature checks for the current change.
- `templates/project.json` - шаблон настроек проекта без секретов.
- `templates/dependency-lock.json` - фиксируемые версии, URL и SHA256 для воспроизводимого bootstrap.
- `templates/dev.env.example` - пример локальных настроек и секретов.
- `templates/tools.json` - проверки необходимого софта.
- `templates/AGENTS.append.md` и `templates/USER-RULES.append.md` - bridge для загрузки правил агентами и подробные project rules.
- PowerShell-helper для Git, 1С Designer, копий баз, web-публикации, Vanessa Automation и выгрузки `CF`/`CFE`.

## Первый запуск

Откройте папку будущего проекта в Codex или Kilo Code и попросите агента:

```text
Инициализируй 1С-проект по файлу https://raw.githubusercontent.com/xmentosx/1c-agent-workflow/master/AGENT-INSTALL.md
```

Текущая папка агента считается папкой проекта. Основной путь инициализации - one-step PowerShell bootstrap:

```powershell
powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
```

Bootstrap копирует managed workflow-файлы и запускает monitored script wizard. Канонический install/update contract описан в `AGENT-INSTALL.md` и `.agents/skills/1c-workflow/references/init-setup.md`; README оставляет только обзор.

Новые ветки разработки по умолчанию создаются в соседней папке worktree: `<папка-проекта>-worktrees/<ветка>`. Основная папка проекта остается на `master`, а worktree-папку нужно открыть отдельным окном Codex/Kilo/IDE для работы с этой линией разработки.

Канонические правила lifecycle, unsafe confirmation, branch-local баз, result export, dependency mode, `update-ai-rules`, `update-workflow`, Vanessa, ROCTUP MCP и vibecoding1c MCP находятся в `.agents/skills/1c-workflow/references/`. Для быстрого подключения vibecoding1c MCP используйте helper-action `vibecoding1c-mcp-setup`; README намеренно не дублирует подробные процедуры.

При инициализации helper сохраняет базовую конфигурацию проекта (`PM4` или `PM5`) в `.agent-1c/project.json`. Для `PM5` доступны product documentation capabilities; для `PM4` они не подключаются автоматически.

## Команды Kilo Code

Slash-команды генерируются локально для каждой открытой папки. В `master` Kilo показывает:

```text
/itl
/itl-status
/itl-new-config-branch <name>
/itl-new-extension-branch <name>
/itl-update-workflow
```

В worktree ветки `itldev/*` Kilo показывает:

```text
/itl
/itl-status
/itl-check
/itl-refresh
/itl-result
```

`/itl` показывает карту lifecycle, текущий контекст, доступные действия и пути соседних worktree. Редкие/helper-действия вызываются обычным текстом через агента или напрямую через PowerShell helper, но не засоряют slash-палитру. `/itl-update-workflow` виден в `master`, потому что обновление workflow-пакета - регулярное обслуживание проекта.

## Важные правила

Этот раздел намеренно краткий. Канонические agent-critical правила находятся в `templates/USER-RULES.append.md` и установленном `USER-RULES.md`, а lifecycle details - в `.agents/skills/1c-workflow/references/`.

- Не коммитьте `.dev.env`, пароли, локальные базы, downloaded tools, логи, `.agent-1c/dev-branches/*.json`, `.agent-1c/mcp/`, `.codex/config.toml`, `.kilo/commands/itl*.md` и `.kilo/kilo.json*`.
- Не загружайте изменения ветки разработки напрямую в исходную базу; helper работает только с копией базы текущей `itldev/*` ветки.
- Для agent-made 1С-изменений готовность подтверждается релевантными Vanessa-сценариями и fresh passed `/itl-check`.
- `/itl-result` подчиняется `VERIFICATION_POLICY`, а зависимости - `DEPENDENCY_MODE`.
