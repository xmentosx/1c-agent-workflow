# Общий Cognee: подключение и наблюдение

Cognee предоставляет native REST API. MCP-инструменты памяти остаются у
существующего workflow adapter; добавлять REST-сервер в список Code/Graph MCP
или в каждый бизнес-проект реестра не нужно.

## Подготовленное размещение

- Windows-хост: `dev-karimov-new`, прежняя Linux VM `itl-mcp-karimov`.
- Контейнер: `itl-cognee-common-v1`, профиль `cognee-qwen4096-v1`.
- Native instance: `cognee-qwen-prod-20261028-v1`, прежний ordinary principal
  и 17 пустых shared datasets из QP. Рабочие знания не импортированы.
- Данные и собственный cache: `/var/lib/itl-cognee/common-qwen-v1/data`.
  Файлы окружения и ключ healthcheck: `/etc/itl-cognee/common-qwen-v1`, приватно.
- Закреплённый образ: `sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`.
  Native Cognee 1.6.5 не дорабатывался; Qwen4096/cache6/pacing off и прежние
  лимиты 2 CPU / 5 GiB RAM+swap сохранены.
- Подготовленный адрес VM: `http://172.29.204.2:18220/`.
  Предлагаемый общий адрес: `http://dev-karimov-new.itland.local:18220/`.
  **LAN NAT/firewall ещё не настроены; общий адрес не объявляется доступным.**

Это подготовка инфраструктуры, не QP5: active provider, bindings, pending,
client MCP settings и explicit off не меняются. Старые BGE, остановленный
QP-кандидат, failed stands и snapshots сохранены. Общий контейнер использует
отдельную холодную копию пустого candidate и собственную копию cache, не пути
данных тестового стенда. Одновременной записи обычных клиентов в два target нет.

## Как работает наблюдение

Единственный владелец восстановления процесса — Docker с `restart=unless-stopped`.
Он поднимает контейнер после выхода процесса/перезапуска daemon. Намеренный
`docker stop` сохраняет остановку; последующий `docker start` возвращает обычный
режим. Не нужен отдельный Cognee supervisor или heartbeat Codex.

Docker HEALTHCHECK вызывает `cognee_healthcheck.py` внутри контейнера:

- период 120 секунд, timeout процесса 12 секунд, общий бюджет API 8 секунд;
- start period 90 секунд, 3 последовательных отказа до unhealthy;
- только authenticated GET `users/me` и `datasets`, без originals, поиска,
  embeddings, LLM, login/refresh и изменения данных;
- проверка того же ordinary principal; никакой employee/outsider/admin матрицы;
- свободное место менее 2 GiB — unhealthy, менее 5 GiB — warning;
- cgroup memory от 90% — warning; сведения о памяти/диске идут в health output.

Unhealthy — операторская диагностика, **не команда перезапуска**. Долгая
индексация, timeout провайдера или нехватка диска не должны запускать restart loop
и терять неизвестный результат записи. Общий watchdog Code/Graph не расширяется,
его allowlist/lease/config/защищённые SHA и nightly не меняются. Для намеренного
обслуживания по-прежнему используется существующая host maintenance lease.

Состояние running/healthy, CPU/RAM, health output и логи видны в существующем
Portainer: `https://dev-karimov-new.itland.local:9443`, контейнер
`itl-cognee-common-v1`. Для оператора по прежнему SSH-профилю:

```sh
sudo docker inspect --format '{{json .State.Health}}' itl-cognee-common-v1
sudo docker stats --no-stream itl-cognee-common-v1
sudo docker inspect --format '{{json .State}}' itl-cognee-common-v1
```

Последняя команда показывает также OOMKilled/ExitCode. Native Docker health
history короткая; это наблюдение текущего состояния, не долговременная система
метрик и не уведомления людям. Нового платного мониторинга или фоновых model
запросов нет. Два небольших API GET раз в две минуты не увеличивают контекст агента.
Healthcheck не доказывает качество поиска, готовность embedding-провайдера,
полную индексацию или успешное рабочее переключение.

## Подключение ПК после отдельного допуска QP5

1. Оператор выдаёт по разрешённому защищённому каналу общий provider и native
   API key **того же ordinary principal**. Ключ не публикуется в Git/реестре,
   сообщении агенту или аргументах команд. СППР/Mantis и MCP роли не меняются.
2. На ПК файлы размещаются в существующем user-local MCP home
   `%LOCALAPPDATA%/ITL/MCP/vibecoding1c/memory`. `credentialFile` в provider —
   абсолютный путь именно на этом ПК, файл содержит только `apiKey`.
   Используется штатная защита приватного каталога пользователя.
3. Подготовленный `provider-lan-prepared.json` не является active `provider.json`.
   Оператор проверяет точный profile/certificate, instance/principal, 17 shared
   mappings и LAN URL. Секрет на текущем ПК уже сохранён отдельно, не в descriptor.
4. Во время разрешённого QP5 существующий memory setup/reload применяет комплект
   и допущенные bindings; действуют финальная сверка данных и правило одного
   normal writer target. Повторять вопросы по шести областям не требуется.
   Прежние выключенные настройки не включаются автоматически.

Native API key в этом qualified Cognee не истекает по TTL. При ротации оператор
обновляет приватные credential files клиентов и отдельный read-only файл
healthcheck под тем же principal, затем отзывает старый ключ. Его credential
смонтирован отдельным read-only bind-файлом: оператор обновляет этот host-файл
с сохранением inode, а не заменяет путь через rename, иначе работающий bind
продолжит видеть старый inode. Для клиентов сохраняется штатная атомарная замена
их приватных файлов. Возможный краткий промежуточный отказ healthcheck не
перезапускает сервер; старый ключ отзывается после подтверждения нового чтения.
Healthcheck не
переходит на пароль/Bearer и не пытается чинить авторизацию самостоятельно.

## Архитектурный checkpoint LAN — ожидает согласования

Причина: VM находится за Windows NAT, порт 18220 не опубликован. Существующие
Code/Graph доступны через `ITL-MCP-NAT`; их настройки не подходят для нового порта.
Нужны только две операции на **dev-karimov-new**, без новой Windows-службы:

```powershell
Add-NetNatStaticMapping -NatName 'ITL-MCP-NAT' -Protocol TCP `
  -ExternalIPAddress '0.0.0.0' -ExternalPort 18220 `
  -InternalIPAddress '172.29.204.2' -InternalPort 18220
New-NetFirewallRule -Name 'ITL-Cognee-Common-18220' `
  -DisplayName 'ITL shared Cognee - dev-karimov-new' `
  -Direction Inbound -Action Allow -Protocol TCP -LocalPort 18220 `
  -Profile Domain,Private -RemoteAddress '10.0.0.0/8','172.29.204.0/24'
```

Scope совпадает с существующим MCP firewall scope. До записи сверяются NAT
name/prefix и отсутствие чужого mapping/rule этого порта; при конфликте ничего
не перезаписывается. Изменение NAT выполняется существующим Windows network
owner, контейнером продолжает владеть Docker; второго recovery coordinator нет.
Нет firewall изменений на ПК разработчиков, автоповышения их прав, новых правил
клиентов или runtime workflow barrier. Административная операция только на сервере.

Приёмка границы: один read-only запрос к native API через общий адрес с тем же
ключом/principal, затем штатный health tick; без recall/remember, новых корпусных
сценариев, QP5, Gate6 или миграции. Отказ сохраняет прежние MCP и подготовленные
данные. Откат удаляет только созданные точные mapping/rule; контейнер можно
намеренно остановить. Томы, старые стенды, ключи и proof не удаляются.
После согласования фиксируется actual LAN result; до него LAN не считается PASS.

Фактическое исполнение: [отчёт подготовки](../../openspec/changes/add-scoped-cognee-memory/evidence/common-ops-2026-10-28.md).
