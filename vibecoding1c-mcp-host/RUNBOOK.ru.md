# Выделенная машина vibecoding1c MCP

Эта инструкция описывает установку и эксплуатацию общей LAN-машины, которая поднимает remote `vibecoding1c` MCP endpoints и публикует сведения о них в GitLab registry repo.

Машина не требует установленного Codex, Kilo Code, workflow agent или конкретного рабочего 1C-проекта. Она работает как отдельный хост Docker-контейнеров и registry publisher.

## Что получается

После `setup` на выделенной машине будут:

- склонирован или обновлен приватный GitLab-дистрибутив `MCP-vibecoding1c`;
- склонированы или обновлены XML-выгрузки конфигураций из `sourceRepo`;
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
- доступ в GitLab для чтения `distributionRepo` и `sourceRepo`;
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
  "stateRoot": "D:/ITL/MCP/vibecoding1c"
}
```

Ключевые поля:

- `hostId`: уникальное имя выделенной машины в registry.
- `baseUrl`: HTTP base URL, который видят рабочие станции разработчиков.
- `distributionRepo`: приватный repo с `vibecoding1c` MCP distribution.
- `registryRepo`: repo, куда будет записан `registry.json`.
- `stateRoot`: постоянный локальный каталог для checkout, runtime state и generated files.
- `embedding`: endpoint и модель embedding-сервиса, которые увидят Docker containers.
- `portRanges.globalStart`: первый порт для global MCP servers.
- `portRanges.projectStart`: первый порт для config-specific MCP servers.
- `enabledServers.global`: global servers, обычно `docs`, `templates`, `syntax`, `codechecker`, `ssl`.
- `enabledServers.project`: project/config servers, обычно `code`, `graph`.
- `configurations`: список конфигураций 1C, для которых нужно поднять `code`/`graph`.

Пример одной конфигурации:

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

`configId` потом выбирает разработчик при подключении remote `code`/`graph` MCP. Даже если конфигурация одна, выбор должен быть явным.

## Секреты

Не добавляйте секреты в `host.config.json` и не публикуйте их в registry repo.

Лицензионные ключи и другие секреты держите только на выделенной машине:

- в `config.env` внутри checkout приватного `MCP-vibecoding1c` distribution;
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
4. Обновляет XML dump repositories из `configurations`.
5. Генерирует `Report.txt` и fingerprints.
6. Запускает Docker containers.
7. Записывает host state под `stateRoot`.
8. Клонирует или обновляет `registryRepo`.
9. Записывает `registry.json`.
10. Делает commit `publish vibecoding1c MCP registry` и `git push`, если registry изменился.

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

Пересобрать `Report.txt` и fingerprints по всем конфигурациям:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action refresh-config -ConfigPath .\host.config.json
```

Пересобрать только одну конфигурацию:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action refresh-config -ConfigPath .\host.config.json -ConfigId trade
```

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
- `configurations[]`: `configId`, title/source, source commit, source fingerprint, report hash, indexed time;
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

`Distribution manifest was not found`

Проверьте `distributionRepo` и наличие `vibecoding1c-mcp.manifest.json` в корне приватного distribution repo.

`git push` не прошел при публикации registry

Проверьте права на `registryRepo`, Git credentials и `git config user.name/user.email`.

Разработчик не видит remote endpoints

На рабочем проекте нужно выполнить `vibecoding1c-mcp-refresh-registry`, затем выбрать remote `configId` и повторить `vibecoding1c-mcp-setup`.

Endpoint недоступен с рабочей станции

Проверьте DNS для `baseUrl`, firewall выделенной машины, опубликованные порты из `portRanges`, и что containers видны в `docker ps`.
