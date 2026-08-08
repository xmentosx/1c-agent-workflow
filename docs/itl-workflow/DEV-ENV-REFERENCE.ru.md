# Справочник `.dev.env`

`.dev.env` содержит локальные настройки и секреты, не коммитится и может отличаться между worktree. В обычной работе этот файл не нужно просматривать целиком: используйте `/itl`, `/itl-status` и команды режимов, а сюда обращайтесь для конкретного параметра.

```text
нужно изменить поведение
  ├─ режим проверки или агента ─► «Режимы агента и зависимостей»
  ├─ путь к базе/платформе ─────► «Платформа, исходная база и хранилище»
  ├─ Vanessa/ROCTUP/MCP ────────► соответствующий раздел
  └─ неизвестный параметр ──────► поиск по точному имени ключа
```

В таблицах `user` означает настройку пользователя, `helper` — встроенные скрипты workflow, а `runtime` — автоматически запущенные процессы. Значения с владельцем `helper` или `runtime` не редактируйте вручную без задачи по восстановлению. Пустое значение означает указанное значение по умолчанию либо отсутствие настройки.

Для защиты от `MAX_PATH=260` абсолютный путь начального корня проекта ограничен 35 символами, а путь нового worktree `<родитель>\<проект>-<ветка>` — 50 символами. Допустимая длина имени ветки вычисляется только как остаток от 50 после родительского пути, имени папки проекта, разделителя и дефиса; содержимое исходников не анализируется. Временные транзакции выгрузки конфигурации, расширения и установки Vanessa используют игнорируемую папку `.tx` внутри проекта.

## Платформа, исходная база и хранилище

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `PLATFORM_PATH` | Путь к `1cv8.exe` | определяется init или задается вручную | init/user |
| `PLATFORM_ARGS` | Дополнительные аргументы запуска платформы для upstream-инструментов метаданных | пусто; строка аргументов | user |
| `IBCMD_ARGS` | Дополнительные аргументы `ibcmd` для upstream-инструментов метаданных | пусто; строка аргументов | user |
| `ONEC_MAX_CONCURRENT_SESSIONS` | Максимум одновременно запущенных процессов 1С на одну точную информационную базу; учитываются также внешние процессы, а TestManager заранее резервирует заявленные TestClient | целое `0..1024`, default `3`; `0` отключает ограничение | user |
| `DESIGNER_MAX_WORKING_SET_MB` | Лимит памяти автоматического Designer | default `10240`; `0` отключает guard | user |
| `DESIGNER_OPERATION_TIMEOUT_SECONDS` | Максимальное ожидание подтвержденного завершения автоматической операции Designer | default `3600`; `1..86400` | user |
| `DESIGNER_STALL_WARNING_SECONDS` | Порог предупреждения без роста CPU/log и изменений owned-процессов; не останавливает Designer и не заменяет hard timeout | default `300`; `30..86400` | user |
| `DESIGNER_STALL_TIMEOUT_SECONDS` | Fail-closed порог без роста CPU/log и изменений owned-процессов; helper останавливает только exact owned Designer | default `600`; `60..86400`, больше warning | user |
| `DESIGNER_DUMP_STABILITY_SECONDS` | Интервал стабильности файлов результата или `/Out` перед приемкой операции Designer | default `5`; `0..300` | user |
| `INFOBASE_KIND` | Тип исходной базы | `file`/`server`, default `file` | user |
| `SOURCE_USES_REPOSITORY` | Используется ли хранилище 1С | `true`/`false` | init/user |
| `SOURCE_INFOBASE_PATH` | Путь к файловой исходной базе | путь | init/user |
| `SOURCE_SERVER_NAME` | Сервер исходной базы | строка | init/user |
| `SOURCE_INFOBASE_NAME` | Имя серверной исходной базы | строка | init/user |
| `BASE_CONFIGURATION_VERSION` | Локальный override семейства конфигурации | `PM4`/`PM5`; пусто = project.json | user |
| `IB_USER` | Пользователь копии базы | пусто = без имени | user/secret |
| `IB_PASSWORD` | Пароль копии базы | пусто = без пароля | user/secret |
| `SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE` | Защита исходной базы при init | `manual-confirm`/`defer`/`confirmed`; обязателен для JSON/configured, wizard сохраняет `manual-confirm` | init/user |
| `REPOSITORY_PATH` | Путь к хранилищу 1С | путь/URL | user |
| `REPOSITORY_USER` | Пользователь хранилища | строка | user/secret |
| `REPOSITORY_PASSWORD` | Пароль хранилища | строка | user/secret |

## Активный контекст ветки

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `INFOBASE_PATH` | Активная копия базы | путь/connection string | helper |
| `EXPORT_PATH` | Активный корень исходников | путь | helper |
| `EXTENSION_NAME` | Активное расширение | имя или пусто | helper |
| `INFOBASE_PUBLISH_URL` | URL публикации активной базы | URL или пусто | helper/user |
| `ITL_ACTIVE_DEV_BRANCH` | Имя активной `itldev/*` ветки | branch name | helper |
| `ITL_ACTIVE_DEV_BRANCH_KIND` | Тип ветки | configuration/extension | helper |
| `ITL_ACTIVE_CONTEXT_UPDATED_AT` | Время активации | ISO timestamp | helper |

## Режимы агента и зависимостей

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `DEPENDENCY_MODE` | Разрешение зависимостей | `fresh`/`locked`, default `fresh` | user |
| `QUICKFIX_MAX_LINES` | Лимит BSL-строк quick-fix | default `40` | user |
| `DEBUG_FAST_PATH` | Сокращенный цикл отладки | `standard`/`extended`/`off`, default `standard` | user |
| `VERIFICATION_DEPTH` | Глубина статических проверок `ai_rules_1c` | `full`/`standard`/`lite`, default `standard` | user/`/litemode` |
| `UI_TESTING` | Проверка веб-интерфейса по правилам `ai_rules_1c` | `auto`/`manual`/`off`, default `manual` | user/`/litemode` |
| `ORCHESTRATION` | Режим оркестрации | `standard`/`economy`, default `standard` | user/`/economymode` |
| `AGENT_MODEL` | Профиль правил для точной модели головного агента | `opus5`/`sonnet5`/`fable5`/`gpt56`; пусто = `auto`, управление через `/rulesmodel` | bootstrap/user |
| `SUPPORT_GUARD` | Реакция upstream-инструментов на изменение заблокированного объекта типовой конфигурации на поддержке | `deny`/`warn`/`off`, default `deny` | user/`support-edit` |
| `SUBAGENT_MODEL_CODING` | Модель coding tier | model id; пусто = модель клиента | user/installer |
| `SUBAGENT_MODEL_ANALYSIS` | Модель analysis tier | model id; пусто = модель клиента | user/installer |
| `SUBAGENT_MODEL_LIGHT` | Модель light tier | model id; пусто = модель клиента | user/installer |
| `ITL_ROUTINE_MODE` | Делегирование `/itl*` в Kilo/OpenCode routine | `off`/`auto`/`on`, default `off`; `auto` и `on` требуют явный `SUBAGENT_MODEL_LIGHT` для делегирования | user |
| `OPENCODE_EXPERIMENTAL_WORKSPACES` | Native worktree workspace API OpenCode | workflow идемпотентно задаёт `true` на уровне пользователя после успешного init/update/switch на OpenCode; требуется перезапуск OpenCode | user |
| `CAVEMAN` | Автоактивация краткого стиля | `on`/`auto`/`off`, default `on` | user/`/caveman` |
| `CAVEMAN_LEVEL` | Постоянный уровень краткого стиля | `lite`/`full`/`ultra`, default/invalid `full`; session override имеет приоритет | user/`/caveman persist` |

Для native workspace OpenCode workflow также готовит игнорируемый project-local runtime `.opencode/node_modules` из записи `opencodePlugin` в `.agent-1c/dependency-lock.json`. Требуются Node.js 22+ и npm; после init/update/switch OpenCode Desktop нужно полностью перезапустить, чтобы зарегистрировать ITL workspace tools.

`SUPPORT_GUARD` не заменяет lifecycle-защиту ITL. `deny` отказывает при заблокированном объекте, нечитаемом состоянии поддержки и удалении объекта на поддержке; `warn` продолжает с предупреждением, `off` отключает только этот upstream-гейт. Нормальный путь — изменение через расширение. `support-edit` применяют только для осознанного изменения `Ext/ParentConfigurations.bin`; ручной обход редактированием XML не предлагается.

## UI-инструменты

Workflow фиксирует версии `agent-browser` и Windows-MCP в `.agent-1c/dependency-lock.json`, best-effort готовит их при init/update и регистрирует напрямую как `stdio`. Они не используют on-demand facade, port registry или desktop lock. `agent-browser` получает отдельный `AGENT_BROWSER_SESSION` для каждого worktree и core skill profile; Windows-MCP запускается клиентом через `uvx ... serve` со штатным набором tools, без autostart и без изменения telemetry.

Проверка и восстановление: `agent-1c.ps1 -Action ui-tools-status`, `-Action install-agent-browser`, `-Action install-windows-mcp` или `-Action install-ui-tools`. Статус `configured` означает только наличие MCP-записи, а не доказательство живого процесса. Пользовательская запись с тем же ключом сохраняется и показывается как `external`; отсутствие инструмента даёт WARN и точную команду установки.

## Проверка ITL

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `ITL_VANESSA_TESTING` | Запуск Vanessa Automation | `auto`/`manual`/`off`, default `auto` | user/`/itl-litemode` |
| `ITL_CHECK_EVENT_LOG` | Проверка журнала регистрации | `auto`/`manual`/`off`, default `auto` | user/`/itl-litemode` |
| `VERIFICATION_POLICY` | Политика result/close | `warn`/`block`, default `warn` | user |
| `GITHUB_TOKEN` | GitHub API token | строка или пусто; имеет приоритет | user/secret |
| `GH_TOKEN` | Fallback GitHub token | строка или пусто | user/secret |

## Worktree, порты и защита

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `ITL_PORT_REGISTRY_SCOPE` | Область реестра портов | `machine`/`user`, default `machine` | user |
| `ITL_PORT_REGISTRY_HOME` | Общий writable-каталог реестра | путь или пусто | user |
| `DEV_BRANCH_INFOBASE_ROOT` | Корень копий баз | пусто = `.agent-1c/infobases/dev-branches` | user |
| `BRANCH_SEED_ROOT` | Корень единственного latest-only seed; внутри данные разделяются по hash identity source | пусто = `.agent-1c/branch-seed` | user |
| `DEV_BRANCH_WORKTREE_ROOT` | Родительский каталог worktree | пусто = рядом с проектом; папка `<project>-<safe-branch>` | user |
| `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP` | Fallback-подтверждение для копии при отсутствии master-маркера | `manual-confirm`/`skip`, default `manual-confirm` | user/init |

## Веб-публикация

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `WEB_PUBLISH_BY_DEFAULT` | Публиковать новые ветки | `true`/`false`, default `false` | user |
| `WEB_PUBLISH_AUTO` | Автоматическая публикация | `true`/`false`, default `false` | user |
| `WEBINST_PATH` | Путь к `webinst.exe` | пусто = рядом с платформой | user/init |
| `APACHE_KIND` | Вариант Apache | default `apache24` | user |
| `APACHE_HTTPD_CONF_PATH` | Путь к `httpd.conf` | путь или пусто | user |
| `WEB_PUBLICATION_ROOT` | Каталог публикаций | путь или пусто | user |
| `WEB_PUBLICATION_URL_BASE` | Базовый URL | default `http://localhost` | user |

## Vanessa Automation

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `VANESSA_AUTOMATION_ROOT` | Каталог установки VA | default `.agent-1c/tools/va`; прежний managed-путь `.agent-1c/tools/vanessa-automation` автоматически заменяется коротким | helper/user |
| `ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE` | Локальный exact ZIP для maintainer-квалификации до публикации pinned artifact | пусто; путь к квалифицированному ZIP, SHA-256 всегда проверяется по lock | maintainer |
| `VANESSA_AUTOMATION_EPF` | Путь к EPF | определяется helper | helper |
| `VANESSA_AUTOMATION_VERSION` | Установленная версия | определяется helper | helper |
| `VANESSA_FEATURES_PATH` | Каталог feature-файлов | default `tests/features` | user |
| `VANESSA_REPORTS_PATH` | Каталог отчетов | default `build/test-results/vanessa` | user |
| `VANESSA_TESTCLIENT_MANIFEST` | Project-defined manifest профилей/топологии TestClient; override для `vanessaAutomation.testClientManifestPath` | JSON schema 1; tracked-файл не содержит паролей, только `passwordEnv` | user |
| `VANESSA_TEST_PORT_RANGE` | Диапазон TestClient | default `48051..48150` | user |
| `VANESSA_TEST_PORT` | Порт текущей ветки | назначается helper | helper |
| `VANESSA_TEST_FOREIGN_WAIT_MODE` | Реакция на чужие процессы | `warn`/`wait`, default `warn` | user |
| `VANESSA_TEST_FOREIGN_QUIET_SECONDS` | Quiet period в `wait` | default `60` | user |
| `VANESSA_TEST_FOREIGN_WAIT_TIMEOUT_SECONDS` | Timeout ожидания | default `600` | user |
| `VANESSA_TEST_TIMEOUT_SECONDS` | Timeout прогона | default `1800` | user |
| `VANESSA_TEST_CLIENT_STARTUP_TIMEOUT_SECONDS` | Timeout TestClient | default `300` | user |
| `VANESSA_TEST_WINDOW_SEARCH_TIMEOUT_SECONDS` | Timeout поиска окна | default `60` | user |
| `VANESSA_TESTCLIENT_LICENSE_CAPACITY` | Общая доступная capacity TestClient для verification и Vanessa UI MCP | положительное число, default `2`; должно соответствовать фактическим лицензиям | user |
| `VANESSA_EVENT_LOG_LEVELS` | Уровни журнала | default `Error` | user |
| `VANESSA_EVENT_LOG_CLOCK_SKEW_SECONDS` | Допуск времени | default `5` | user |
| `VANESSA_EVENT_LOG_READER` | Reader журнала | `auto` или поддержанный reader | user |

## Vanessa UI MCP

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `VANESSA_MCP_AUTO_START` | Автозапуск | default `false` | user |
| `VANESSA_MCP_INSTALL_ROOT` | Каталог установки | default `.agent-1c/tools/vanessa-mcp` | helper/user |
| `VANESSA_MCP_CLIENT_CFE_PATH` | Путь к client CFE | определяется helper | helper |
| `VANESSA_MCP_CLIENT_CFE_VERSION` | Версия client CFE | определяется helper | helper |
| `VANESSA_MCP_CLIENT_CFE_SHA256` | SHA256 client CFE | определяется helper | helper |
| `VANESSA_MCP_VA_EXTENSION_CFE_PATH` | Путь к VA extension CFE | определяется helper | helper |
| `VANESSA_MCP_VA_EXTENSION_CFE_VERSION` | Версия VA extension | определяется helper | helper |
| `VANESSA_MCP_VA_EXTENSION_CFE_SHA256` | SHA256 VA extension | определяется helper | helper |
| `VANESSA_MCP_PORT_RANGE` | Диапазон портов | default `9874..9973` | user |
| `VANESSA_MCP_TESTCLIENT_PORT_RANGE` | Отдельный диапазон TestClient экземпляров on-demand MCP | default `48151..48250` | user |
| `VANESSA_MCP_PORT` | Legacy branch-wide порт; stdio-фасада его не использует | пусто | helper |
| `VANESSA_MCP_URL` | Legacy branch-wide URL; stdio-фасада его не использует | пусто | helper |

## ROCTUP MCP

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `ROCTUP_MCP_ENABLED` | Доступность integration | default `true` | user |
| `ROCTUP_MCP_AUTO_START` | Автозапуск | default `false` | user |
| `ROCTUP_MCP_REQUIRED` | Блокировать без MCP | default `false` | user |
| `ROCTUP_MCP_INSTALL_ROOT` | Каталог установки | default `.agent-1c/tools/roctup-mcp-toolkit` | helper/user |
| `ROCTUP_MCP_PORT_RANGE` | Диапазон портов | default `6003..6102` | user |
| `ROCTUP_MCP_TOOLKIT_EPF` | Путь к toolkit EPF | определяется helper | helper |
| `ROCTUP_MCP_VERSION` | Установленная версия | определяется helper | helper |
| `ROCTUP_MCP_SHA256` | SHA256 toolkit | определяется helper | helper |
| `ROCTUP_MCP_PORT` | Порт текущей ветки | назначается helper | helper |
| `ROCTUP_MCP_URL` | URL текущей ветки | назначается helper | helper |
| `ROCTUP_MCP_HEALTH_URL` | Health endpoint | назначается helper | helper |

## vibecoding1c MCP

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `VIBECODING1C_MCP_DISTRIBUTION_REPO` | Репозиторий distribution | configured ITL URL | init/user |
| `VIBECODING1C_MCP_DISTRIBUTION_PATH` | Локальный checkout override | путь или пусто | user |
| `VIBECODING1C_MCP_REGISTRY_REPO` | Репозиторий registry | configured ITL URL | init/user |
| `VIBECODING1C_MCP_REGISTRY_PATH` | Локальный registry override | путь или пусто | user |
| `PATH_METADATA` | Local metadata endpoint path | путь или пусто | helper/user |
| `PATH_CODE` | Local code endpoint path | путь или пусто | helper/user |
| `PATH_BASES` | Local bases endpoint path | путь или пусто | helper/user |
| `USE_GPU` | Использование GPU local provider | `true`/`false`, default `false` | user |
