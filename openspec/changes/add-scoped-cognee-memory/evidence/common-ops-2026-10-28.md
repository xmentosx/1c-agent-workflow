# Подготовка общего Cognee и мониторинга — 2026-10-28

Пользователь разрешил подготовить постоянное подключение и мониторинг по аналогии
с MCP watchdog. QP5, Gate6, рабочая миграция и публикация workflow не разрешены.
Решение и конкретный ожидающий LAN checkpoint:
[единственный runbook](../../../../vibecoding1c-mcp-host/linux-native-host/COGNEE.ru.md).

## Выполнено

- Новый `itl-cognee-common-v1`, ID
  `962e45caf9091616467812a930d1b3ac8250b8c34e81b390b9650c27c2440a0e`,
  запущен с native image e5de806/Qwen4096; 2 CPU / 5 GiB, cache6/pacing off
  сохранены. Отдельные data/cache в `/var/lib/itl-cognee/common-qwen-v1`.
- Холодная копия пустого QP candidate сохраняет прежние instance/principal и
  17 shared datasets. Обычные клиентские writers не подключены.
- `restart=unless-stopped` и native Docker HEALTHCHECK включены; существующий
  Portainer показывает их через Docker. Общий watchdog Code/Graph не менялся.
- Probe выполняет два GET, проверяет ordinary principal, dataset API, диск;
  показывает cgroup memory. Нет model/token cost или growth клиентского контекста.
  8s API / 12s Docker timeout, период120s, start90s, retries3.
- Подготовлен отдельный user-local `provider-lan-prepared.json` с предлагаемым
  LAN URL; это не active provider. 17 mappings и существующий приватный key locator
  сохранены. Ключ не внесён в source, registry или tool output.

## Код, native proof и ограничения

| Область | Факт |
|---|---|
| Код monitor | 5/5 Python regressions: authenticated GET-only, pressure warnings, auth redaction/no retry, foreign/admin rejection, disk failure без recovery, общий deadline и transport redaction |
| Реальный Docker tick | Сначала холодный startup GET получил URLError в start period; следующий native tick healthy,17datasets,0.221s. Первый отказ сохранён, не удалён |
| Прямой probe в том же контейнере | healthy, обычный principal,17datasets,0.077s; Docker показывает failingStreak0 |
| Ресурсы в native proof | disk free10,058,588,160bytes; cgroup483,508,224bytes при cap5,368,709,120. Скопированный собственный cache около2.55GB, сохранён ради независимости от G5 fixture |
| Сохранность хоста | Все50 ранее существовавших containers: ID/name/image/mounts/StartedAt/running совпали. Все protectedFiles SHA установленного host contract совпали; иных restart нет |
| Автовосстановление | Политика Docker реально настроена. Падение/OOM/перезагрузка сервера здесь не провоцировались; полного reboot proof нет |
| LAN | **Не подключён:** Windows NAT/firewall требуют checkpoint, точные изменения подготовлены. VM API работает, LAN reachability не заявляется |
| Клиенты/рабочие знания | Не переключены; нет remember/recall, нового импорта, рабочего data reconciliation или QP5 |

Healthcheck — диагностический статус, не проверка качества поиска и не новый
workflow gate. Он не перезапускает unhealthy API; восстановлением вышедшего
процесса владеет Docker. Истечение ключа/автологин не добавляются.

## Артефакты и продолжение

Ignored evidence: `build/agent-artifacts/cognee-common-ops-20261028/evidence/`:
`prepare-common-result.json`, `native-ops-proof.json`, `healthcheck-tests.log`,
`prepared-lan-descriptor.json`, `windows-network-utf8.json` и точные источники
remote-команд. Операторская provisioning receipt хранится рядом с новыми данными;
старые QP/G5 evidence и stopped containers остаются на своих местах.

Следующий шаг после согласования LAN checkpoint — добавить только exact
NAT/firewall и подтвердить native GET через общий адрес. Это не разрешает QP5.
Регистрация source определяется штатным RegisterChange/Status в общей очереди;
она не подменяет native proof, LAN acceptance или публикацию.
