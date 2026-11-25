# Spec Delta

## Purpose

Workflow получает закреплённые по SHA256 ассеты так, чтобы сбой web-раздачи GitHub не ломал bootstrap и гейты, не требуя от пользователя ключей и не ослабляя проверку подлинности.

## ADDED Requirements

### Requirement: GitHub release assets use the API route first
Для источника, который точно соответствует `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`, общий владелец загрузок SHALL сначала получать ассет через GitHub REST API того же репозитория, тега и имени ассета. Источники другой формы, локальные файлы и `file://` SHALL получаться прежним способом.

#### Scenario: Web endpoint returns 504 while the API works
- **WHEN** web-URL ассета из lock отвечает 504, а API отдаёт ассет с SHA256 из lock
- **THEN** ассет публикуется по назначенному пути с SHA256 из lock, а web-URL не запрашивается

#### Scenario: Non-GitHub source
- **WHEN** источник — HTTPS-URL не GitHub release или существующий локальный файл
- **THEN** он получается прежним маршрутом с прежней политикой повторов и проверкой SHA256

### Requirement: Credentials are optional and confined to the API host
Загрузка SHALL работать без учётных данных и без настройки пользователем. Репозиторий workflow SHALL NOT содержать токенов. Если в окружении процесса задан `GITHUB_TOKEN` или `GH_TOKEN` (в этом порядке приоритета), токен SHALL отправляться только на `api.github.com` и SHALL NOT отправляться на хост перенаправления или появляться в выводе, предупреждениях и ошибках.

#### Scenario: No token configured
- **WHEN** ни `GITHUB_TOKEN`, ни `GH_TOKEN` не заданы
- **THEN** ассет публичного репозитория скачивается через API без авторизации

#### Scenario: Token present
- **WHEN** задан `GITHUB_TOKEN`
- **THEN** запросы к `api.github.com` несут этот токен, запрос к хосту перенаправления (CDN) идёт без заголовка авторизации, и значение токена отсутствует в выводе

### Requirement: Bounded fallback to the locked URL
Если API-маршрут не дал файл из-за лимита запросов (403/429), ошибки сервера (5xx), сетевой ошибки, отсутствия ассета или неполного ответа, загрузка SHALL перейти на locked web-URL с прежней ограниченной политикой повторов. Итоговая ошибка SHALL называть оба маршрута и их статусы. Ожидание SHALL оставаться ограниченным.

#### Scenario: API rate limit exhausted
- **WHEN** API отвечает 403 с `X-RateLimit-Remaining: 0`, а web-URL отдаёт ассет
- **THEN** ассет публикуется с SHA256 из lock, и выводится одно предупреждение о переходе на резервный маршрут

#### Scenario: Both routes fail
- **WHEN** API отвечает 5xx, а web-URL после всех разрешённых повторов отвечает 504
- **THEN** загрузка завершается ошибкой, в которой названы оба маршрута и последние статусы, а существующий целевой файл не изменяется

### Requirement: SHA256 from the lock stays authoritative
Каждый маршрут SHALL публиковать файл только после совпадения SHA256 с lock. Если API сообщает для ассета `digest`, отличный от lock, загрузка SHALL отказать до скачивания тела без перехода на резервный маршрут.

#### Scenario: API digest disagrees with the lock
- **WHEN** метаданные ассета содержат `sha256`-digest, отличный от ожидаемого SHA256
- **THEN** загрузка отказывает ошибкой о расхождении SHA256, и ни API-тело, ни web-URL не запрашиваются

#### Scenario: Downloaded bytes disagree with the lock
- **WHEN** скачанные через любой маршрут байты имеют другой SHA256
- **THEN** загрузка отказывает без повторов, и существующий целевой файл сохраняется

### Requirement: Verified cache before network for YAxUnit and on-demand MCP
YAxUnit и on-demand MCP SHALL использовать проверенную по SHA256 копию из общего кэша неизменяемых артефактов до обращения к сети. Путь установки YAxUnit в проекте SHALL оставаться прежним. On-demand MCP SHALL получать файл через общего владельца загрузок.

#### Scenario: Second project on the same machine
- **WHEN** YAxUnit с SHA256 из lock уже есть в общем кэше, и инициализируется новый проект
- **THEN** проект получает точную копию в свой путь установки YAxUnit без сетевого запроса

#### Scenario: On-demand MCP transient failure
- **WHEN** первый запрос за исполняемым файлом on-demand MCP завершается 503, а следующий успешен
- **THEN** файл устанавливается с SHA256 из lock по общей политике повторов, а не падает с первой ошибки
