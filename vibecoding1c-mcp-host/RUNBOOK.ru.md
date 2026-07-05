# Выделенная машина vibecoding1c MCP

Эта инструкция описывает установку и эксплуатацию общей LAN-машины, которая поднимает remote `vibecoding1c` MCP endpoints и публикует сведения о них в GitLab registry repo.

Машина не требует установленного Codex, Kilo Code, workflow agent или конкретного рабочего 1C-проекта. Она работает как отдельный хост Docker-контейнеров и registry publisher.

## Что получается

После `setup` на выделенной машине будут:

- склонирован или обновлен приватный GitLab-дистрибутив `MCP-vibecoding1c`;
- склонированы или обновлены XML-выгрузки конфигураций из `sourceRepo` или прочитаны локальные XML-выгрузки из `sourcePath`;
- сгенерирован `Report.txt` через `norkins/metadata` для каждой конфигурации;
- запущены общие `vibecoding1c` MCP servers;
- запущены config-specific `code` и `graph` MCP servers для указанных конфигураций;
- опубликован `registry.json` в GitLab registry repo.

В GitLab попадает только endpoint/freshness metadata. Лицензионные ключи, API tokens, пароли ИБ и локальные пути хоста в registry попадать не должны.

## Репозитории

Обычно используются три группы GitLab repositories:

```text
MCP-vibecoding1c
  Приватный дистрибутив vibecoding1c MCP. Читается выделенной машиной.

MCP-vibecoding1c-registry
  Registry repo. Выделенная машина пишет сюда registry.json.

<project>-config-dump
  XML-выгрузка конфигурации 1C. Читается выделенной машиной для code/graph indexes.
```

Если в организации используются другие URL, укажите их в `host.config.json`.

## Требования к машине

На выделенной машине должны быть доступны:

- Windows PowerShell;
- Git;
- Docker и доступ к `docker info` от пользователя, который запускает скрипт;
- Python;
- доступ в GitLab для чтения `distributionRepo` и `sourceRepo`, если конфигурация берется из Git;
- установленная платформа 1C на машине, если используется ручной `dump-config`;
- доступ к исходной ИБ и 1C-хранилищу, если используется ручной `dump-config`;
- доступ в GitLab для commit/push в `registryRepo`;
- DNS или статическое имя, доступное разработчикам по LAN;
- открытые входящие TCP-порты из `portRanges`.

Рекомендуется заранее настроить Git identity:

```powershell
git config --global user.name "ITL MCP Host"
git config --global user.email "mcp-host@itland.local"
```

## Установка

Склонируйте workflow repo на выделенную машину:

```powershell
git clone https://github.com/xmentosx/1c-agent-workflow.git D:\ITL\1c-agent-workflow
cd D:\ITL\1c-agent-workflow\vibecoding1c-mcp-host
```

Создайте рабочий конфиг:

```powershell
Copy-Item .\host.config.example.json .\host.config.json
notepad .\host.config.json
```

Настройте поля:

```json
{
  "hostId": "vibecoding1c-mcp-host-01",
  "baseUrl": "http://vibecoding1c-mcp-host-01.itland.local",
  "distributionRepo": "http://gitlabserv01.itland.local/root/MCP-vibecoding1c.git",
  "registryRepo": "http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git",
  "stateRoot": "D:/ITL/MCP/vibecoding1c",
  "pythonPath": "C:/Python312/python.exe",
  "secrets": {
    "ONEC_AI_TOKEN": "<local-1c-assistant-token>"
  },
  "helpSearchServer": {
    "platformVersion": "8.3.24.1548",
    "platformBinPath": "C:/Program Files/1cv8/8.3.24.1548/bin"
  },
  "sslSearchServer": {
    "bspVersion": "3.1.10"
  }
}
```

Ключевые поля:

- `hostId`: уникальное имя выделенной машины в registry.
- `baseUrl`: HTTP base URL, который видят рабочие станции разработчиков.
- `distributionRepo`: приватный repo с `vibecoding1c` MCP distribution.
- `registryRepo`: repo, куда будет записан `registry.json`.
- `stateRoot`: постоянный локальный каталог для checkout, runtime state и generated files.
- `pythonPath`: путь к реальному Python 3 executable для `norkins/metadata`; можно оставить `python`, если PATH точно указывает на рабочий Python.
- `secrets.ONEC_AI_TOKEN`: локальный ключ 1C Напарника для `1CCodeChecker`; рабочий `host.config.json` не коммитится.
- `helpSearchServer.platformVersion`: версия платформы 1C для `HelpSearchServer`.
- `helpSearchServer.platformBinPath`: локальный каталог `bin` платформы 1C для `HelpSearchServer`.
- `sslSearchServer.bspVersion`: версия БСП для `SSLSearchServer`.
- `embedding`: endpoint и модель embedding-сервиса, которые увидят Docker containers.
- `portRanges.globalStart`: первый порт для global MCP servers.
- `portRanges.projectStart`: первый порт для config-specific MCP servers.
- `enabledServers.global`: global servers, обычно `docs`, `templates`, `syntax`, `codechecker`, `ssl`.
- `enabledServers.project`: project/config servers, обычно `code`, `graph`.
- `configurations`: список конфигураций 1C, для которых нужно поднять `code`/`graph`.

Пример конфигурации из Git:

```json
{
  "configId": "trade",
  "title": "Trade configuration",
  "sourceRepo": "http://gitlabserv01.itland.local/team/trade-config-dump.git",
  "sourceBranch": "master",
  "mainConfigPath": "src/cf",
  "extensionPath": "",
  "reportFileName": "Report.txt"
}
```

Пример конфигурации из локальной XML-выгрузки:

```json
{
  "configId": "trade-local",
  "title": "Trade configuration from local dump",
  "sourcePath": "D:/ITL/MCP/vibecoding1c/sources/trade-local",
  "sourceLabel": "trade local dump",
  "mainConfigPath": "src/cf",
  "extensionPath": "",
  "reportFileName": "Report.txt"
}
```

Для `sourcePath` путь указывает на корень XML-выгрузки. Если файлы конфигурации лежат прямо в этой папке, задайте `"mainConfigPath": "."`; если в подпапке, например `src/cf`, укажите эту подпапку.

Для ручного обновления `sourcePath` из 1C-хранилища добавьте к конфигурации блок `dump`:

```json
"dump": {
  "platformPath": "C:/Program Files/1cv8/8.3.24.1548/bin/1cv8.exe",
  "infoBaseKind": "file",
  "sourceInfoBasePath": "D:/1C/Bases/trade-source",
  "sourceServerName": "",
  "sourceInfoBaseName": "",
  "ibUser": "",
  "ibPassword": "",
  "repositoryPath": "tcp://1c-repository/trade",
  "repositoryUser": "repository-user",
  "repositoryPassword": ""
}
```

Для server infobase задайте `"infoBaseKind": "server"`, `sourceServerName` и `sourceInfoBaseName`; `sourceInfoBasePath` можно оставить пустым.

`configId` потом выбирает разработчик при подключении remote `code`/`graph` MCP. Даже если конфигурация одна, выбор должен быть явным.

## Секреты

Рабочий `vibecoding1c-mcp-host/host.config.json` добавлен в `.gitignore`, потому что может содержать локальные пути, пароли ИБ/хранилища и `ONEC_AI_TOKEN`. Не коммитьте этот файл и не публикуйте его содержимое в registry repo.

Лицензионные ключи и другие секреты держите только на выделенной машине:

- в `config.env` внутри checkout приватного `MCP-vibecoding1c` distribution;
- в локальном `vibecoding1c-mcp-host/host.config.json`;
- или в локальном окружении пользователя/службы, которая запускает Docker.

`registry.json` должен содержать только URL endpoints, scope/config metadata, health и freshness hashes.

## Первый запуск

Для проверки сгенерированных путей и payload можно выполнить dry run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action setup -ConfigPath .\host.config.json -DryRun
```

Для реального запуска:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action setup -ConfigPath .\host.config.json
```

`setup` делает полный цикл:

1. Проверяет `git`, `docker`, `python`.
2. Обновляет `distributionRepo`.
3. Читает `vibecoding1c-mcp.manifest.json` из distribution checkout.
4. Обновляет XML dump repositories из `sourceRepo` или читает готовые локальные XML dump folders из `sourcePath`.
5. Генерирует `Report.txt` и fingerprints.
6. Запускает Docker containers.
7. Записывает host state под `stateRoot`.
8. Клонирует или обновляет `registryRepo`.
9. Записывает `registry.json`.
10. Делает commit `publish vibecoding1c MCP registry` и `git push`, если registry изменился.

`setup` не запускает выгрузку из 1C. Если `sourcePath` должен обновляться из базы, сначала выполните ручной `dump-config`.

## Проверка

Проверьте локальное состояние:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action status -ConfigPath .\host.config.json
```

Проверьте Docker:

```powershell
docker ps
```

Проверьте, что registry попал в GitLab:

```powershell
git -C D:\ITL\MCP\vibecoding1c\registry log --oneline -5
git -C D:\ITL\MCP\vibecoding1c\registry status --short
```

Путь `D:\ITL\MCP\vibecoding1c\registry` соответствует примеру `stateRoot`. Если у вас другой `stateRoot`, registry checkout будет в `<stateRoot>\registry`.

Минимально в `registry.json` должны быть:

```json
{
  "schemaVersion": 1,
  "publishedAt": "...",
  "host": {
    "hostId": "...",
    "baseUrl": "..."
  },
  "configurations": [],
  "servers": []
}
```

В `servers[]` должны быть опубликованы remote endpoints с `provider: "remote"` и `family: "vibecoding1c"`.

## Регулярная эксплуатация

Посмотреть состояние:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action status -ConfigPath .\host.config.json
```

Запустить или обновить containers без публикации registry:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action start -ConfigPath .\host.config.json
```

Остановить tracked containers:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action stop -ConfigPath .\host.config.json
```

Обновить локальную XML-выгрузку из ИБ, подключенной к 1C-хранилищу:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action dump-config -ConfigPath .\host.config.json -ConfigId trade-local
```

`dump-config` сначала выполняет `/ConfigurationRepositoryUpdateCfg -force /UpdateDBCfg`, затем `/DumpConfigToFiles`. Если в папке уже есть `ConfigDumpInfo.xml`, используется incremental режим `-update -force`; если папка не пустая и `ConfigDumpInfo.xml` отсутствует, команда останавливается.

Пересобрать `Report.txt` и fingerprints по всем конфигурациям:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action refresh-config -ConfigPath .\host.config.json
```

Пересобрать только одну конфигурацию:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action refresh-config -ConfigPath .\host.config.json -ConfigId trade
```

Пересобрать `Report.txt`, пересоздать все включенные MCP-серверы, использующие embedding-модель, и передать им `RESET_DATABASE=true`:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action reindex -ConfigPath .\host.config.json
```

Переиндексировать только одну конфигурацию:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action reindex -ConfigPath .\host.config.json -ConfigId trade
```

После `reindex` выполните `publish`, если клиентам нужно увидеть обновленные `indexedAt`/`reportHash` в registry.

Опубликовать текущее состояние в GitLab registry repo:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action publish -ConfigPath .\host.config.json
```

Обновить sources, поднять servers и сразу опубликовать registry:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action setup -ConfigPath .\host.config.json
```

## Подключение разработчиков

В 1C workflow проектах разработчики не подключаются напрямую к выделенной машине вручную. Они обновляют registry и выбирают remote endpoints через helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-refresh-registry
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-select -McpProvider remote -McpConfigId trade
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-setup
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-status
```

В Kilo Code это тот же сценарий через `/itl-vibecoding1c-mcp`.

Developer-side helper пишет только ignored runtime/client config:

- `.agent-1c/mcp/*`;
- `.codex/config.toml`;
- `.kilo/kilo.json` или `.kilo/kilo.jsonc`;
- `%LOCALAPPDATA%\ITL\MCP\vibecoding1c`.

Эти файлы не нужно коммитить в project repo.

## Что публикуется в registry

`registryRepo` хранит `registry.json`. Его пишет только выделенная машина через `publish` или `setup`.

Контракт:

- `schemaVersion`, `publishedAt`;
- `host.hostId`, `host.baseUrl`;
- `configurations[]`: `configId`, title/source, source commit, source fingerprint, report hash, indexed time. Для локального `sourcePath` поле `source` содержит `sourceLabel` или `local:<configId>`, но не абсолютный локальный путь;
- `servers[]`: server id, scope, family, provider, configId, name, URL, health, image и freshness inputs.

Не публикуйте туда:

- license keys;
- API tokens;
- пароли ИБ или хранилища;
- локальные пути, которые не нужны клиентам;
- developer-specific client config.

## Ограничения

Текущий publisher записывает один `registry.json` по текущему host state. Если нужно несколько выделенных машин, нужен явный процесс владения registry:

- либо публикует одна основная машина;
- либо registry format и publisher дорабатываются под merge нескольких hosts.

Не используйте `vibecoding1c` registry как источник правды по текущей `itldev/*` ветке. Remote `code`/`graph` endpoints индексируют опубликованные XML dumps, а не незакоммиченные локальные изменения разработчика.

## Типовые проблемы

`Required command was not found: docker`

Установите Docker и проверьте, что команда доступна в PowerShell с тем же пользователем.

`Docker is installed but not available to the current user/session`

Проверьте, что Docker service запущен, пользователь имеет права на Docker, и `docker info` работает без elevation issues.

`Docker image '<image>' is not available locally and docker pull failed`

Скрипт перед `docker run` проверяет образ через `docker image inspect`. Если образ отсутствует, он делает `docker pull <image>`. Ошибка из скриншота `read-only file system` означает проблему Docker Desktop/WSL daemon: Docker не может записать metadata DB и не сможет скачать новый image.

Минимальная проверка:

```powershell
docker info
docker pull comol/template-search-mcp:latest
```

Если `docker pull` падает с `read-only file system`, перезапустите Docker Desktop или выполните `wsl --shutdown`, затем снова проверьте `docker info` и `docker pull`. Если доступа к registry нет, загрузите образ вручную через `docker load` или временно уберите ненужный server, например `templates`, из `enabledServers.global`.

`Distribution manifest was not found`

Проверьте `distributionRepo` и наличие `vibecoding1c-mcp.manifest.json` в корне приватного distribution repo.

`norkins/metadata failed for configId <id>`

Проверьте пути, которые пишет ошибка: `Generator config`, `Python log`, `Source root`, `mainConfigPath` и `Resolved main config root`. Чаще всего причина в том, что XML-выгрузка лежит прямо в `sourcePath`, а в `host.config.json` оставлено `"mainConfigPath": "src/cf"`. В этом случае задайте `"mainConfigPath": "."`.

Exit code `1` у `norkins/metadata` означает diagnostics warnings, а не критический сбой. Host setup продолжает работу, если `Report.txt` создан, и печатает путь к `report-diagnostics.json`.

Если exit code равен `9009` или в выводе есть только `Python`, проверьте, что используется реальный Python 3, а не Windows Store App Execution Alias:

```powershell
python --version
where python
```

Установите Python 3 или задайте полный путь в `host.config.json`:

```json
"pythonPath": "C:/Python312/python.exe"
```

Для ручной диагностики запустите тот же generator напрямую:

```powershell
python -B <stateRoot>\tools\norkins-metadata\generate_config_report.py --config <stateRoot>\configs\<configId>\generate-config-report.json
```

`git push` не прошел при публикации registry

Проверьте права на `registryRepo`, Git credentials и `git config user.name/user.email`.

Разработчик не видит remote endpoints

На рабочем проекте нужно выполнить `vibecoding1c-mcp-refresh-registry`, затем выбрать remote `configId` и повторить `vibecoding1c-mcp-setup`.

Endpoint недоступен с рабочей станции

Проверьте DNS для `baseUrl`, firewall выделенной машины, опубликованные порты из `portRanges`, и что containers видны в `docker ps`.
