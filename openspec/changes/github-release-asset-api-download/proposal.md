# Proposal

## Why

Загрузки релизных ассетов с `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>` регулярно получают HTTP 504, и из-за этого падают bootstrap и гейты. 2026-11-09 Develop-гейт PublishDevelop упал в `fresh-bootstrap-init-project`: YAxUnit 25.12 три раза подряд вернул 504. Сбой на стороне GitHub, а не машины. При этом REST API отдаёт те же байты быстро и без ключей, а workflow сейчас ходит только через web-URL.

Наблюдения (2026-11-09, 08:30–08:41, `curl.exe -4`):

- Сам `github.com` отвечает `504 Gateway Time-out` с заголовками `X-GitHub-Request-Id` и `x-github-edge-region: fra` примерно через 11,3 с. Другие edge-узлы через `--resolve` отдают `302` за 11–14 с. Повторы приходят из кэша edge за 0,2–0,4 с; шесть попыток за 75 с с тремя разными User-Agent — все `504`. С токеном в запросе — `302` за 11,04 с: кэш обходится, но ответ всё равно на грани таймаута.
- Ассет `cli/cli` и путь `/raw/...` дают тот же `504`. `/releases/tag`, `/expanded_assets` и `/archive`→codeload отвечают быстро. О том же сбое с 2026-11-08 ~08:45 UTC пишут сторонние проекты (winget-cli#6665, hivecommons/hive#17224, tamld/g8s#838).
- `api.github.com/repos/bia-technologies/yaxunit/releases/assets/334915768` с `Accept: application/octet-stream` без токена отвечает `302` за 0,55 с, затем CDN отдаёт `200` за 1,2 с. SHA `805a2277…6d70` совпадает с lock. В Windows PowerShell 5.1 `Invoke-WebRequest` по этому адресу проходит за 4 с, `gh release download` — за 1,9 с. Одна загрузка расходует один запрос из лимита 60 в час на внешний IP.
- Локальные причины исключены: DNS (системный, 1.1.1.1, 8.8.8.8), маршрут через Wi-Fi, а не через Kerio, прокси нет, MTU 1500, hosts чистый.
- Общий загрузчик `Invoke-ItlImmutableFileAcquire` ходит только по web-URL: три попытки с паузами 1 и 2 с. Эти повторы попадают в кэшированный 504. YAxUnit не использует общий кэш и при каждом fresh-bootstrap качается заново в `.agent-1c/tools/yaxunit`. `Install-ItlOnDemandMcp` вызывает `Invoke-WebRequest` напрямую, без повторов.

## What Changes

- Общий владелец неизменяемых загрузок сначала получает точный GitHub release URL через REST API: ищет ассет по тегу и имени и скачивает его через asset endpoint. Locked web-URL остаётся резервным маршрутом с текущей ограниченной политикой повторов.
- Ключи не требуются и в workflow не встраиваются. Если в окружении процесса есть `GITHUB_TOKEN` или `GH_TOKEN`, токен используется только для `api.github.com` и никогда не уходит на CDN и не печатается.
- SHA256 из lock остаётся единственным критерием подлинности. Если API сообщает `digest`, отличный от lock, загрузка отказывает до скачивания и без резервного маршрута.
- YAxUnit получает файл через общий кэш `%LOCALAPPDATA%\ITL\artifacts`, а затем точную копию в прежний путь проекта. On-demand MCP переходит на общий загрузчик.
- Формат lock, публикация собственных ассетов и топология E2E не меняются. Остальные вызывающие (Vanessa, ROCTUP, client MCP, stand-env, Pester shards, release-readiness, source-delivery) получают новый маршрут автоматически через общего владельца.

## Capabilities

### New Capabilities

- `immutable-artifact-acquisition`: маршруты, учётные данные, резервный путь и кэш при получении закреплённых по SHA256 ассетов.

### Modified Capabilities

## Impact

- Код: `.agents/skills/1c-workflow/scripts/lib/agent-1c.immutable-download.ps1` (владелец), `agent-1c.yaxunit.ps1`, `agent-1c.ondemand-mcp.ps1`.
- Тесты: `tests/pester/ImmutableDownloadRetry.Tests.ps1`, а также тесты интеграции YAxUnit и on-demand MCP. Контракт `immutable-download` в каталоге quality contracts уже выбирает тесты зависимых владельцев.
- Документация: `docs/itl-workflow/DEV-ENV-REFERENCE.ru.md` — список содержимого общего кэша.
- Без изменений: `templates/dependency-lock.json`, установленный lock, публикация в source-delivery, гейты и E2E-фикстуры. Миграция установленных проектов не нужна: прежний путь YAxUnit сохраняется, и существующая точная копия принимается по SHA.
- Архитектурный checkpoint не требуется: решение остаётся у существующего владельца, без нового состояния, блокировки, координатора и миграции, без роста always-on контекста. Обоснование — в `design.md`.
