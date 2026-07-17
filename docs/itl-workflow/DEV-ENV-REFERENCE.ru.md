# Справочник `.dev.env`

`.dev.env` содержит локальные настройки и секреты, не коммитится и может отличаться между worktree. Значения `helper`/`runtime` не редактируйте вручную без recovery-задачи. Пустое значение означает указанный default либо отсутствие настройки.

## Платформа, исходная база и хранилище

| Ключ | Назначение | Значения/default | Владелец |
|---|---|---|---|
| `PLATFORM_PATH` | Путь к `1cv8.exe` | определяется init или задается вручную | init/user |
| `DESIGNER_MAX_WORKING_SET_MB` | Лимит памяти автоматического Designer | default `10240`; `0` отключает guard | user |
| `INFOBASE_KIND` | Тип исходной базы | `file`/`server`, default `file` | user |
| `SOURCE_USES_REPOSITORY` | Используется ли хранилище 1С | `true`/`false` | init/user |
| `SOURCE_INFOBASE_PATH` | Путь к файловой исходной базе | путь | init/user |
| `SOURCE_SERVER_NAME` | Сервер исходной базы | строка | init/user |
| `SOURCE_INFOBASE_NAME` | Имя серверной исходной базы | строка | init/user |
| `BASE_CONFIGURATION_VERSION` | Локальный override семейства конфигурации | `PM4`/`PM5`; пусто = project.json | user |
| `IB_USER` | Пользователь копии базы | пусто = без имени | user/secret |
| `IB_PASSWORD` | Пароль копии базы | пусто = без пароля | user/secret |
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
| `VERIFICATION_DEPTH` | Глубина upstream static QA | `full`/`standard`/`lite`, default `full` | user/`/litemode` |
| `UI_TESTING` | Upstream browser UI testing | `auto`/`manual`/`off`, default `manual` | user/`/litemode` |
| `ORCHESTRATION` | Режим оркестрации | `standard`/`economy`, default `standard` | user/`/economymode` |
| `SUBAGENT_MODEL_CODING` | Модель coding tier | model id; пусто = модель клиента | user/installer |
| `SUBAGENT_MODEL_ANALYSIS` | Модель analysis tier | model id; пусто = модель клиента | user/installer |
| `SUBAGENT_MODEL_LIGHT` | Модель light tier | model id; пусто = модель клиента | user/installer |
| `CAVEMAN` | Автоактивация краткого стиля | `on`/`auto`/`off`, default `on` | user/`/caveman` |

## ITL verification

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
| `DEV_BRANCH_WORKTREE_ROOT` | Корень worktree | пусто = соседний `<project>-worktrees` | user |
| `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP` | Подтверждение настройки защиты | `manual-confirm`/`skip`, default `manual-confirm` | user/init |

## Web publication

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
| `VANESSA_AUTOMATION_ROOT` | Каталог установки VA | default `.agent-1c/tools/vanessa-automation` | helper/user |
| `VANESSA_AUTOMATION_EPF` | Путь к EPF | определяется helper | helper |
| `VANESSA_AUTOMATION_VERSION` | Установленная версия | определяется helper | helper |
| `VANESSA_FEATURES_PATH` | Каталог feature-файлов | default `tests/features` | user |
| `VANESSA_REPORTS_PATH` | Каталог отчетов | default `build/test-results/vanessa` | user |
| `VANESSA_TEST_PORT_RANGE` | Диапазон TestClient | default `48051..48150` | user |
| `VANESSA_TEST_PORT` | Порт текущей ветки | назначается helper | helper |
| `VANESSA_TEST_FOREIGN_WAIT_MODE` | Реакция на чужие процессы | `warn`/`wait`, default `warn` | user |
| `VANESSA_TEST_FOREIGN_QUIET_SECONDS` | Quiet period в `wait` | default `60` | user |
| `VANESSA_TEST_FOREIGN_WAIT_TIMEOUT_SECONDS` | Timeout ожидания | default `600` | user |
| `VANESSA_TEST_TIMEOUT_SECONDS` | Timeout прогона | default `1800` | user |
| `VANESSA_TEST_CLIENT_STARTUP_TIMEOUT_SECONDS` | Timeout TestClient | default `300` | user |
| `VANESSA_TEST_WINDOW_SEARCH_TIMEOUT_SECONDS` | Timeout поиска окна | default `60` | user |
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
| `VANESSA_MCP_PORT` | Порт текущей ветки | назначается helper | helper |
| `VANESSA_MCP_URL` | URL текущей ветки | назначается helper | helper |

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
