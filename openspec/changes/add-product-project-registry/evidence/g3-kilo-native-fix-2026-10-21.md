# G3 Kilo: import aliases и native tool API, 2026-10-21

**G3-KILO-MULTICLIENT-ALIASES и G3-KILO-TOOLS-API-404 закрыты в указанной source/native CLI области. Full G3/AC-39 открыт.** Основание `4ef768b924141de17ef215da6e106b42137e2c49`; [JSON evidence](g3-kilo-native-fix-2026-10-21.json) содержит exact source inputs, raw SHA и результаты. Исходные [failures](g3-clients-installed-2026-10-21.md) сохранены. VS Code frontend, остальные клиенты и полный installed/platform journey не приняты.

## Причины и исправление

**Aliases.** Kilo deep-merges root `opencode.json[c]` вместе со своим config — это штатное [поведение клиента](https://kilo.ai/docs/getting-started/settings). Прежние генераторы оставляли `1c-*` в Kilo и `onec-*` в OpenCode; поэтому Kilo активировал две пары для тех же endpoint. Удалять OpenCode-файл, переносить его или переименовывать Kilo tools/permission keys не нужно.

Existing `Write-ItlClientMcpEndpointSet` теперь добавляет отключённые `onec-*` overlays в **собственный Kilo config** для назначенных этому владельцу `1c-*` endpoints. Это обычные native entries с `enabled=false`, прежним transport/URL, существующими ownership/baseline/receipts и pinned restore; отдельного state, parser, watcher, coordinator или нового backend protocol нет. Во внешнем OpenCode конфиге эти же имена остаются включёнными. Сохранены Kilo `1c-*` names, permissions, auth/policy/disabled fields и unrelated MCP. Restore не генерирует overlays заново, а возвращает сохранённые native entries; проверены before-state с overlays и без них.

Alias, уже явно записанный в физическом Kilo config другим владельцем, **не захватывается**: overlay пропускается, выводится WARN, primary setup завершается. Наличие такого override не позволяет объявить устранение дублей; пользователь/агент проверяет его через текущий Kilo config и native activation. Явная попытка перезаписать чужой alias по-прежнему получает existing `CLIENT_MCP_USER_COLLISION` до записи. Не добавлен общий блокер независимых задач или автоматическое изменение чужой настройки. Native override включённого пользователем owned overlay также сохраняется обычным механизмом user changes.

Existing preview использует имена из prepared writer requests: две добавленные записи видимы и не теряются за прежним no-op. Источником materialization остаётся один writer. Общая проекция не копируется в новый resolver; Code/Graph/business IDs/home/grants прежние. Trigger/source changes ограничены Kilo/vibecoding1c materialization, не startup/status/context probes. Явный sync работает на прежних связных проектах без init/reset; installed rollout сейчас не выполнялся.

**404.** В установленном bundled Kilo **7.8.15**, EXE SHA `c171387724dd935d6fe8ca9b162383ac0aa41e9a04af97ca3ea1d5c4c4a79b2f`, advertised `POST /experimental/mcp/call-tool` закрыт флагом MCP Apps. Тот же дефект описан в [upstream PR #14956](https://github.com/Kilo-Org/kilocode/pull/14956) (draft, не подтверждение установленного исправления). Нативный контроль того же бинарника с `KILO_EXPERIMENTAL_MCP_APPS=1` прошёл четыре настоящих Code/Graph calls без изменения исходных client files. Исправлена **процедура квалификации**: флаг только у отдельного authenticated loopback `kilo serve` с private HOME/USERPROFILE/XDG и `--pure`. Глобальные настройки/нормальные model tool calls не меняются, Kilo не патчился/не обновлялся, Code/Graph не менялись. Старый flag-off 404 не объявлен сбоем этих серверов.

## Повтор на исходном workload

Сохранены все 12 client config files в прежних `Контекст клиента CUSTOM` / `Контекст клиента PROF`. Production/старые installed stands/failed copies не использовались. На каждом root настоящая source public команда `vibecoding1c-mcp-write-client-config -Client kilocode` завершилась exit 0 и добавила overlays через existing apply. Основные две native entries и их policy сохранены; OpenCode bytes/mtime и остальные client files не изменились. Изменились только Kilo config и предусмотренные selection/operation/applied/ownership receipts. Project/product IDs и явные custom/base/reference различия прежние.

| Native проверка | CUSTOM | ПРОФ |
|---|---|---|
| Effective catalog | 2 connected `1c-*`, 2 disabled `onec-*` | То же |
| Code stats/структура + Graph status/fulltext | Passed, 10.073 s на пару | Passed, 12.437 s на пару |
| Graph чужой `pm4corp` и неизвестный project | `project_not_accessible` для обоих | То же |
| Вызов disabled imported alias | Local API 404, backend tool не вызван | То же |
| Disconnect/connect | Обе основные роли вернулись в connected | То же |
| Native `/instance/dispose` reload и actual Code/Graph reads | Passed, aliases остались disabled | То же |

Результаты получены через настоящий Kilo SDK HTTP surface и его MCP connections; raw записи не переупакованы как Codex RPC и не заменены direct MCP/replay. HTTP 200/`isError=false` отдельно не считается semantic pass: проверены полезные payload, Graph project/namespace, returned result и явные negative error codes. Reload — runtime instance, **не VS Code webview**. Сохранённый registry version/index context не объявлен новой index attestation.

Два основных accepted runs дали **16 executed native MCP calls**: 12 полезных чтений + 4 negative scope controls. Ещё две local call-tool попытки к disabled alias дали ожидаемые 404. До source apply выполнены отдельные flag-on/mask mechanism probes по четыре calls; всего новых executed backend calls 24, local tool API attempts 26, LLM turns 0. First pair budget 20 s не ослаблен; reconnect/reload измеряются отдельно. Token count/backend model usage не инструментировались. Четыре конфигурационных имени не равны четырём активным подключениям/наборам tools.

## Регрессии, сохранность и ограничения

Focused owner suites проверяют PlanOnly/no-op, существующие auth/disabled/permission fields, OpenCode byte preservation, foreign alias WARN с продолжением primary setup и неизменный explicit collision guard, ручное включение overlay, restore обоих предыдущих layouts и видимость добавлений в preview старого receipt. Исходные failures сохранены отдельно: parse typo нового теста; некорректная whole-file JSON assertion при одном лишь порядке properties (заменена проверкой **всех** native полей); PSObject indexing в новом validator; legacy fixture сначала сохранял baseline уже созданного overlay и тем самым моделировал его ручное удаление, которое writer правомерно защищал. Исправлен fixture до настоящего old receipt без overlay baseline; assertions additions/ownership/policy/restore не сняты, исходный filesystem/workload сохранён.

**Accepted batch: 145 passed, 0 failed, 0 skipped** (Windows PowerShell 5.1/Pester 5.8.0): MultiClientMcpOwnership 36, ProductProjectApply 48, ProductProjectSetup 39, ProductProjectContext 22. Считается только финальный общий batch; ранние failed/corrected runs не суммируются.

Public writer сохранил OpenCode bytes/actual mtime. После первых native runs из **19 paths/root, всего 38** неизменны 36; две CUSTOM exceptions принадлежат первому чтению самим Kilo: `.kilo/kilo.json` добавил `$schema` (+49 bytes, остальные bytes exact), `opencode.json` добавил `$schema` и переформатировался (+174 bytes). Все остальные JSON values, включая MCP/policy, совпали. Для OpenCode старые bytes отдельно восстановлены тем же неизменённым OpenCode writer в diagnostic root: SHA `d9e9b8506448e283d16fb1b88a16d5d27162bb44e810567c1e09d2b425895549` (341 bytes) точно совпал с before-record; actual client file не заменялся. Первый слишком строгий metadata-byte validator сохранён как failed. **Свежий native `mcp list --pure` процесс** после нормализации дал 2 connected/2 disabled за 3.621 s и сохранил SHA + actual `mtime_ns` всех 38 paths. Это не whole-file byte preservation через первый native load. Нативные процессы остановлены владельцем. File-size delta относится к ignored Kilo settings/receipts и именам в explicit preview; новых always-on rules/tool schemas/startup probes/provider or memory calls нет. Disabled aliases не дают отдельного доступного native tool namespace; точное снижение model context не измерялось. Managed on-demand `references/mcp.md` описывает совместное использование и version-scoped diagnostic flag.

Остаток прежний: full client/IDE/installed/platform/cost proof G3/AC-39, release population AC-36–38 и consumer памяти 4.2/AC-43/G5/44. Шесть областей, canonical home, Q1–Q7/D9/G2 и ai_rules_1c не меняются; aliases/flag не становятся project/product/dataset IDs. **Gate 6 не запускался/не исправлялся; G4, рабочая миграция, server deploy/reindex, client upgrade и публикация не начинались.** Delivery outcome — existing RegisterChange/Status ledger, не новый ledger OpenSpec.

## Последующая проверка frontend

[Native desktop result](g3-desktop-native-2026-10-21.md) отдельно подтвердил visible Kilo VS Code и actual Ask Code/Graph read subset на исходном ПРОФ root. Исторический CLI/core report/JSON остаётся неизменным по области доказательств; новый canary имеет свои model requests, semantic failure и cost counters. Full G3/client/platform/installed acceptance по-прежнему открыт.
