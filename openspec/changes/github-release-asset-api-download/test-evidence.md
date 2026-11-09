# Test Evidence

## Диагноз (2026-11-09, 08:30–08:41, до изменения)

| Команда | Ответ |
|---|---|
| `curl.exe -4 -I https://github.com/bia-technologies/yaxunit/releases/download/25.12/YAxUnit-25.12.cfe` | `504 Gateway Time-out`, 11,33 с, `X-GitHub-Request-Id`, `x-github-edge-region: fra`, без `Location` |
| Тот же URL, 6 раз за 75 с, User-Agent curl, Chrome, WindowsPowerShell | все `504`, 0,2–0,4 с (кэш edge) |
| `--resolve github.com:443:<edge>` для `cli/cli` v2.60.0 | 140.82.121.3/.4, 140.82.113.3 — `504`; 140.82.112.3, 140.82.114.4, 20.205.243.166 — `302` за 11–14 с |
| `api.github.com/repos/bia-technologies/yaxunit/releases/assets/334915768`, `Accept: application/octet-stream`, без токена | `302` за 0,55 с, затем `200` за 1,24 с, SHA256 `805a2277…6d70` = lock |
| `rate_limit` до и после одной загрузки ассета | `60` → `59` (`X-RateLimit-Resource: core`) |
| Сбой, который проявил проблему | PublishDevelop, `develop-e2e-fresh` → `fresh-bootstrap-init-project`: 3 × `(504)` на YAxUnit (`C:\itlj\p Проект\d-6209d141\.agent-1c\runs\20261109-082226-895-42412-fa8332a3\console.log`) |

## Live: общий владелец после изменения (задача 4.1)

Без `GITHUB_TOKEN`/`GH_TOKEN`, пустой временный каталог `…\scratchpad\Кэш проверки <N> <id>`, ассеты и SHA256 из `templates/dependency-lock.json`:

```
PS5 route=api attempts=1 published=True t=4s sha_ok=True YAxUnit-25.12.cfe
PS5 route=api attempts=1 published=True t=1s sha_ok=True VAExtension.1.32-itl-r11.cfe
PS7 route=api attempts=1 published=True t=1s sha_ok=True YAxUnit-25.12.cfe
PS7 route=api attempts=1 published=True t=1s sha_ok=True VAExtension.1.32-itl-r11.cfe
web now: 302 t=0.54 / 0.21
```

К моменту live-прогона web-маршрут GitHub восстановился и отвечал `302` за 0,2–0,5 с. Поэтому live подтверждает API-маршрут, но не его поведение во время живого 504. Сам 504 воспроизведён моками (см. ниже).

## Pester (задачи 1.x, 2.x, 3.1, 4.2)

| Файл | Среда | Итог |
|---|---|---|
| `tests/pester/ImmutableDownloadRetry.Tests.ps1` | Windows PowerShell 5.1.26100, Pester 5.8.0 | 26 passed, 0 failed |
| `tests/pester/ImmutableDownloadRetry.Tests.ps1` | PowerShell 7.6.9 (Codex runtime), Pester 5.8.0 | 26 passed, 0 failed |
| `tests/pester/YAxUnitVerification.Tests.ps1` | PS 5.1 | 76 passed, 0 failed |
| `tests/pester/OnDemandMcp.Tests.ps1`, фильтр `*facade*` | PS 5.1 | 75 passed, 0 failed |
| `tests/pester/ParserDocsBudgets.Tests.ps1` | PS 5.1 | 41 passed, 0 failed |

Резервный маршрут (задача 4.2) покрыт кейсами `falls back to the locked URL once when the API route fails with …`: 403, 429, 503, отсутствующий ассет, 502 на перенаправлении. Обе неудачи и сохранение статуса 404 покрыты кейсом `names both routes…`. В живом сбое API резервный маршрут не проверялся: такого сбоя не наблюдалось, а точку переопределения API-хоста ради этой проверки не добавляли.

Перенаправление проверено настоящим `HttpWebRequest` против локального TCP-сервера в PS 5.1 и PS 7. Функция возвращает `Location` и не идёт по нему: хост `release-assets.example.invalid` не резолвится, а ошибки нет. `Authorization` и `Accept: application/octet-stream` уходят только на API-endpoint.
