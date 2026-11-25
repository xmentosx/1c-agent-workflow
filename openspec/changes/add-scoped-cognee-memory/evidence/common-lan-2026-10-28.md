# Общий адрес Cognee — 2026-10-28

Пользователь согласовал точный LAN checkpoint из
[runbook](../../../../vibecoding1c-mcp-host/linux-native-host/COGNEE.ru.md).
Это разрешение относится только к сетевой границе: QP5, Gate6, рабочая миграция
и публикация workflow не запускались.

## Применено и проверено

- На `dev-karimov-new` в существующий `ITL-MCP-NAT` добавлено одно TCP
  сопоставление ID5: `0.0.0.0:18220` → `172.29.204.2:18220`.
- Добавлено только `ITL-Cognee-Common-18220`: inbound allow TCP18220,
  Domain/Private, remote `10.0.0.0/8` и `172.29.204.0/24`.
- Пять прежних NAT mappings и прежнее firewall rule Code/Graph совпали до/после.
  Нет новой Windows-службы или изменений на ПК разработчиков.
- С текущего ПК выполнен **один** authenticated native GET `api/v1/users/me`
  через `http://dev-karimov-new.itland.local:18220/` (DNS `10.0.12.24`).
  HTTP200,0.437976s; native principal совпал с подготовленным provider,
  `is_superuser=false`. Ключ прочитан из прежнего приватного locator, не выведен.
- После GET в12:44:45.572603UTC прошёл штатный Docker health tick
  в12:45:09.641206225UTC: healthy,exit0,17datasets,0.076s,без warnings.
  На этом tick свободно10,058,412,032bytes, cgroup384,204,800bytes.
  Это автоматический tick, не дополнительный ручной API probe.
- Тот же container ID `962e45caf9091616467812a930d1b3ac8250b8c34e81b390b9650c27c2440a0e`,
  StartedAt `2026-10-28T12:26:55.790187783Z`, restartCount0.

Сетевая граница принята. Это не recall/remember, корпусный прогон, reboot proof,
перенос знаний или включение памяти в обычных клиентах. Active provider, bindings,
pending и explicit off не менялись; business registry не публиковался заново.

## Сохранённое исполнение

Ignored evidence: `build/agent-artifacts/cognee-lan-20261028/evidence/`:
`apply-windows-network-file.json`, `native-lan-get.json`,
`lan-and-health-proof.json`, точные источники команд и transport stderr.
Windows provisioning receipt: `C:\ITL\mcp-host\state\cognee-lan-20261028.json`.

Первый oversized encoded-command транспортный вызов остановился до исполнения:
последующий prestate подтвердил отсутствие receipt, NAT18220 и firewall rule.
Тот же скрипт передан файлом и выполнен штатным PowerShell; failed output сохранён.
Это восстановление оснастки до сетевой записи, не повтор native acceptance GET.

При откате удаляются только exact mapping ID5 и firewall rule нового порта,
после сверки их текущей принадлежности/параметров. Данные, snapshots, ключи и
старые правила остаются. Дальнейшее подключение клиентов выполняется только
через отдельно разрешённый QP5 и существующий setup/reload owner.
Source-регистрацию подтверждает общий RegisterChange/Status ledger отдельно от
этого native LAN proof; публикация этой операцией не выполняется.
