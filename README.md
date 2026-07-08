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
- `.agents/skills/1c-workflow/kilo-command-templates` - шаблоны коротких slash-команд Kilo Code.
- `.kilo/commands/itl*.md` - локально сгенерированная командная поверхность для текущей папки/worktree; игнорируется Git.
- `AGENT-INSTALL.md` - bootstrap-инструкция для агента.
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

Текущая папка агента считается папкой проекта. Основной путь инициализации - PowerShell script wizard: он показывает абсолютный путь, спрашивает подтверждение, собирает параметры и запускает весь lifecycle.

При инициализации script wizard:

1. Проверит Git, платформу 1С, Vanessa Automation и, если нужно, готовый web-контур публикации.
2. Создаст локальный Git-репозиторий, если его еще нет.
3. Если исходная база подключена к хранилищу, обновит ее из хранилища 1С; иначе использует текущее состояние исходной базы.
4. Выгрузит конфигурацию в `src/cf`.
5. Закоммитит выгрузку в `master`.
6. Установит правила проекта и команды для текущего агента.

Новые ветки разработки по умолчанию создаются в соседней папке worktree: `<папка-проекта>-worktrees/<ветка>`. Основная папка проекта остается на `master`, а worktree-папку нужно открыть отдельным окном Codex/Kilo/IDE для работы с этой линией разработки.

Копии баз веток разработки по умолчанию создаются внутри worktree в `.agent-1c/infobases/dev-branches`. Каталог `.agent-1c/infobases/` игнорируется Git. Локальное состояние веток хранится в `.agent-1c/dev-branches/*.json` и тоже не коммитится: там есть локальные пути, регистрация в launcher, статусы проверок, worktree-путь и результаты. При создании ветки копия базы автоматически добавляется в список баз 1С в папку `/ITL/<имя-папки-проекта>`, а запись внутри этой папки называется именем ветки.

При создании базы ветки helper по умолчанию запускает русскоязычное подтверждение отключения защиты от опасных действий: сначала спрашивает, отключена ли защита для пользователя ИБ, а при ответе не `ДА` открывает Конфигуратор, ждет его закрытия и повторяет вопрос. Это поведение управляется `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm`; для неинтерактивной автоматизации можно указать `skip`, если настройка выполнена отдельно.

Результаты веток (`CF` или `CFE`) складываются в `build/result`. Рядом с каждым результатом создается `<artifact>.manifest.json` с commit-ами, SHA256, статусом проверки, логами и пометкой unverified override. Этот каталог игнорируется Git, поэтому большие артефакты не попадают в репозиторий.

Зависимости при инициализации по умолчанию берутся свежими (`DEPENDENCY_MODE=fresh`) и записываются в `.agent-1c/dependency-lock.json`: commit ITL workflow-пакета, commit `ai_rules_1c`, URL/версия/SHA256 Vanessa Automation и ROCTUP MCP Toolkit, а также SHA256 скачиваемых архивов. Если нужен воспроизводимый bootstrap, выберите `DEPENDENCY_MODE=locked`: helper будет использовать только значения из lock manifest и остановится, если pin или hash отсутствует или не совпадает.

Свежие upstream-правила `ai_rules_1c` после установки обновляются по обычному запросу агенту или helper-действием `update-ai-rules`. Обновление запускает upstream installer, безопасно заменяет дефолтные upstream MCP-записи готовыми vibecoding1c-managed записями в локальных Codex/Kilo конфигах, повторно применяет ITL overlay в `USER-RULES.md` и записывает новый commit `ai_rules_1c` в `.agent-1c/dependency-lock.json`. Если vibecoding1c selection/state отсутствует или неполный, upstream MCP-записи сохраняются как рабочий fallback, а helper печатает команду `vibecoding1c-mcp-setup`.

Уже установленный ITL workflow-пакет обновляется из `master` через `/itl-update-workflow`, по обычному запросу агенту или helper-действием `update-workflow`. Команду запускают только из `master` worktree: она обновляет управляемые файлы workflow, не трогает `.dev.env`, `.agent-1c/dev-branches/`, `.agent-1c/mcp/`, `.codex/config.toml`, `.kilo/kilo.json*`, существующие `.agent-1c/project.json` и `.agent-1c/tools.json`, регенерирует локальные `.kilo/commands/itl*.md`, обновляет кэш ROCTUP MCP Toolkit, по умолчанию запускает `update-ai-rules`, автоматически сверяет MCP client config при готовой vibecoding1c-замене и оставляет tracked-изменения для review/commit. Активные `itldev/*` ветки обновляются отдельно через merge свежего `master` или `/itl-refresh`; уже запущенные branch-local ROCTUP и Vanessa MCP перезапускаются lifecycle-командами после реальной загрузки базы.

Проверка перед `/itl-result` по умолчанию работает в режиме `VERIFICATION_POLICY=warn`: без fresh passed `/itl-check` нужен явный unverified override, который попадет в manifest. Для более строгого промышленного режима задайте `VERIFICATION_POLICY=block`: выгрузка результата будет запрещена до свежей успешной Vanessa-проверки.

Vanessa Automation устанавливается локально в `.agent-1c/tools/vanessa-automation`. Тесты хранятся в `tests/features`, отчеты - в `build/test-results/vanessa`; отчеты и скачанная EPF не коммитятся.

vibecoding1c MCP подключаются по обычному запросу агенту или helper-действием `vibecoding1c-mcp-setup`. По умолчанию setup применяет сохраненный выбор серверов, а если выбор отсутствует или неполный - сначала запускает выбор; для явного повторного выбора используйте `vibecoding1c-mcp-select` или `vibecoding1c-mcp-setup -Force`. Затем helper берет опубликованные LAN HTTP endpoints из registry-репозитория `http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git`; для config-specific vibecoding1c MCP разработчик явно выбирает `configId`, даже если опубликована только одна конфигурация. Выбор `hostId` хранится отдельно для каждого remote-сервера, включая global `docs`/`templates`/`syntax`/`codechecker`/`ssl`; `configId` хранится отдельно для `code` и `graph`, поэтому они не наследуют выбор друг друга. По каждому серверу можно выбрать remote или local. Локальный режим по-прежнему клонирует приватный GitLab-дистрибутив `http://gitlabserv01.itland.local/root/MCP-vibecoding1c.git` в `%LOCALAPPDATA%\ITL\MCP\vibecoding1c\distribution`, ротирует ключи в локальный `%LOCALAPPDATA%\ITL\MCP\vibecoding1c`, выбирает embedding-модель, выделяет host-порты и пишет ignored Codex/Kilo config только для текущего scope. Для ручного registry checkout задайте `VIBECODING1C_MCP_REGISTRY_PATH`; для ручного distribution checkout - `VIBECODING1C_MCP_DISTRIBUTION_PATH`. Выбор remote/local хранится в ignored `.agent-1c/mcp/vibecoding1c-selection.json`.

Для выделенной машины без агента используйте standalone tooling в `vibecoding1c-mcp-host/`: `install-vibecoding1c-mcp-host.ps1` поднимает общие vibecoding1c MCP, config-specific `code`/`graph` vibecoding1c MCP, читает XML-выгрузки из Git `sourceRepo` или локального `sourcePath`, автоматически генерирует `Report.txt` через `norkins/metadata` и публикует `registry.json` без секретов. Для локального `sourcePath` ручная команда `-Action dump-config` обновляет базу из 1C-хранилища и выгружает конфигурацию в файлы.

ROCTUP MCP Toolkit кэшируется в ignored `.agent-1c/tools/roctup-mcp-toolkit` при init/update. В новых `itldev/*` ветках helper по умолчанию запускает `MCP_Toolkit.epf` в embedded mode внутри копии базы, назначает branch-local порт и пишет endpoint в state, `.dev.env`, Codex и Kilo config. ROCTUP - предпочтительный канал исследования данных без web-публикации; старый web-based Data MCP остается fallback для опубликованных баз.

Vanessa MCP автоматически устанавливается и запускается отдельно для каждой новой ветки разработки. Helper устанавливает MCP-расширения в копию базы этой ветки, назначает отдельный порт и сохраняет PID/URL в `.agent-1c/dev-branches/*.json`; manual actions `install-vanessa-mcp`, `start-vanessa-mcp`, `stop-vanessa-mcp` остаются для восстановления. Финальный `/itl-check` по-прежнему запускает пакетный `StartFeaturePlayer` через реальный `TESTMANAGER -> TESTCLIENT` контур с branch-local `VANESSA_TEST_PORT`. Успех подтверждается JUnit-отчетом с выполненными тестами без failures/errors.

External MCP - это отдельные MCP-серверы вне helper-managed vibecoding1c, ROCTUP и Vanessa MCP. Текущий helper их не настраивает и не удаляет из Codex/Kilo config; managed rewrite трогает только записи с ITL-managed markers.

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

- Не коммитьте `.dev.env`, пароли, `*.cf`, `*.dt`, логи и локальные базы.
- Не коммитьте `.agent-1c/dev-branches/*.json`: это локальное runtime-состояние веток.
- Не коммитьте `.agent-1c/mcp/`, `.codex/config.toml`, `.kilo/commands/itl*.md`, `.kilo/kilo.json` и `.kilo/kilo.jsonc`: это локальные generated/runtime state.
- Remote vibecoding1c MCP registry не является источником правды по текущей ветке разработки. Проверяйте `/itl-status` или MCP freshness по запросу агенту: `fresh`, `stale`, `remote-shared`, `unknown`, `indexing`.
- Не загружайте изменения ветки разработки напрямую в исходную базу.
- Все изменения загружаются только в базу текущей ветки разработки.
- Не используйте один Vanessa MCP или ROCTUP MCP на несколько веток разработки: у каждой `itldev/*` worktree свой порт, PID, URL и копия базы. Vanessa MCP нужен для авторинга, исследования форм, записи и точечной отладки; ROCTUP MCP нужен для данных; финальный `/itl-check` не запускается через MCP.
- Перед командами `ai_rules_1c`, которые работают с базой (`/update1cbase`, `/loadfrom1cbase`, `/getconfigfiles`), в ветке `itldev/*` должен быть активирован контекст ветки. Команды жизненного цикла делают это автоматически.
- Для обычной проверки в ITL-ветке не используйте `/deploy-and-test`: он повторно загружает все файлы. Используйте `/itl-check`; если нужно только обновить базу без тестов, попросите агента выполнить update-base. Чужой Vanessa-run в другой worktree по умолчанию выводится как диагностика и не блокирует запуск, пока нет реального конфликта порта или базы; helper никогда не завершает `TESTMANAGER`/`TESTCLIENT` другой worktree.
- Для изменения бизнес-поведения агент создает или обновляет 2-4 Vanessa Automation проверки: основной успешный сценарий и минимум один значимый граничный или негативный сценарий; integration/UI используются только по сути изменения.
- `/itl-result` предупреждает, если нет свежей успешной проверки Vanessa. Продолжить без нее можно только после явного подтверждения.
- Перед созданием worktree, обновлением ветки, выгрузкой результата и legacy-переключением Git-дерево должно быть чистым.
- Если нужно убрать завершенную ветку из активного списка, попросите агента выполнить advanced helper-действие `close-dev-branch`. Worktree, база и локальный state не удаляются автоматически.
- Установка софта выполняется только после явного подтверждения разработчика.
- Для `/itl-result` используйте `VERIFICATION_POLICY`: `warn` оставляет предупреждение и явное подтверждение, `block` запрещает продолжение без свежей успешной Vanessa. Для зависимостей используйте `DEPENDENCY_MODE`: `fresh` берет свежие версии и обновляет lock manifest, `locked` требует заранее зафиксированные pin/hash значения.
