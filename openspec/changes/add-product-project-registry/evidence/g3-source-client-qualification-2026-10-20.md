# Code/Graph и native MCP clients, 2026-10-20

**Native Codex app-server subset passed. Полный AC-08, affected-client matrix и G3/AC-39 остаются открытыми.** [JSON proof](g3-source-client-qualification-2026-10-20.json) содержит exact runtime blobs/SHA-256, 41 raw references и пределы каждого результата. Source `8f54de3cd998d5452652fe40c0b5ceeeb543c8ff`; Windows 11, PowerShell 5.1 и установленный `codex-cli 0.163.0-alpha.10.2`. Исходники runtime, серверы и рабочие проекты не менялись. Созданы два новых synthetic Git/config roots с пробелами и кириллицей; локальный тестовый каталог не является наполнением/публикацией бизнес-реестра.

## Привязка источников

Свежие `initialize → initialized → tools/list` прошли на `dev-ermakov`: Code PM5/PM4 `22100/mcp` / `22200/mcp`, Graph `22101/mcp/` / `22201/mcp/`. Code публикует 28 tools, Graph — 54. Выполнены 16 прямых безопасных tool calls: Code stats/ограниченный compact read; Graph metadata/status и fulltext own/unknown/foreign controls. Scope отказа проверен по содержимому ответа `project_not_accessible` и отсутствию результата, а не по transport success или `isError`.

| Контроль | Подтверждённая граница | Что не подтверждено |
|---|---|---|
| Exact host/server/config | По три неизвестных поля на family отвергнуты existing resolver до client apply; настоящий selected URL записан во все 12 adapters | Это проверка ссылки в registry, а не live admission фактического источника |
| Одинаковый Code native ID | Оба endpoints возвращают `code-20d3eae87f48`, но URL и observed generation различны: PM5 `20261019T230814Z-aca520f1`, PM4 `20261017T235843Z-d972befd`; native client вызвал оба отдельно | ID не глобальный business ID. Code не публикует проверяемый native namespace в этих ответах |
| Graph project/namespace | `get_graph_project_status` и `list_graph_projects` дают ожидаемые `pm5corp` / `pm4corp`, namespace `default`; own fulltext возвращает результат, чужой/неизвестный ID отвергается | Верхний `context.project_id/mcp_namespace=null`; это не bound context. `active_generation=null`, точная версия индекса не доказана |
| Wrong declared namespace | При `g3-wrong-namespace` resolver сохраняет `unverified`, не объявляет ready | Правильный namespace также `unverified`: автоматического live сравнения ожидаемого и фактического binding/admission сейчас нет |
| Source/build version | Зафиксированы текущие native metadata и generation | Code release `1.0.0` имеет `pinned=false`, `build_digest=null`; framework/serverInfo не заменяет build/source proof. Точная версия конфигурации не установлена |

Это уточняет незакрытый существующий AC-08, а не вводит новое условие или runtime FAIL. Readiness остаётся intent/unverified; успешная нативная активация MCP не превращает её в доказанную привязку продукта. Продолжение принадлежит existing registry/source readiness и publication identity owners; новый coordinator, глобальный probe или расширение startup guard не добавлены.

## Реальная активация Codex

Проверка использует установленный клиент и его version-matched JSON schemas. Официальный [app-server API](https://learn.chatgpt.com/docs/app-server) предоставляет thread-scoped MCP discovery/call и config reload; [MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) описывает trusted project config. Здесь каждый процесс имеет отдельный `CODEX_HOME`, explicit trust только новой fixture, без копирования credentials и без изменения реального trust/config.

В каждой новой PM4/PM5 thread выполнены именно native `mcpServerStatus/list` и `mcpServer/tool/call` через канонические имена `1c-code-metadata-mcp` / `1c-graph-metadata-mcp`: Code stats, Graph project status, own fulltext и foreign negative. Оба результата passed. Native thread вернул точный Unicode cwd; всего шесть checked cwd round-trips. Это сильнее прежнего `codex mcp get`, но не является наблюдением tool picker/агента в уже открытом desktop/IDE frontend.

Отдельный test-only manual endpoint override в PM5 fixture проверил reload, не меняя business binding/семейство/базу:

| Фаза | Наблюдаемые Graph projects / Code generation |
|---|---|
| До правки | PM5 / `20261019T230814Z-aca520f1` |
| Файл указывает PM4, reload ещё нет | Тот же действующий контекст продолжает PM5 |
| Штатный `config/mcpServer/reload` | Тот же контекст видит PM4; новая thread также PM4 |
| Negative на новом endpoint | Запрос ожидаемого PM5 отвергнут как `project_not_accessible` |
| Возврат исходных bytes + reload | Новая thread снова видит PM5 и исходную generation |

Config восстановлен побайтно; `.agent-1c/project.json`, applied/operation receipts неизменны. Initial native runs сохранили глобальный Codex config; весь reload использовал private home и новую fixture. Ручная замена URL здесь — отрицательный контроль клиента, не workflow migration/автоматическая смена продукта. Она также показывает, почему соединение и наличие tools недостаточны для business-source readiness.

Первый reload attempt был **failed harness control**: Python text writer превратил CRLF в CRCRLF, Codex правильно отклонил TOML. Исходные script/JSON/RPC сохранены; только запись тестового файла заменена на bytes, те же phases/root/preconditions повторены успешно. Первый PS5.1 fixture script остановился на UTF-8 без BOM до выполнения; после BOM использован существующий native child capture с explicit UTF-8. Ранние диагностические Python console summaries не используются как Unicode transport proof; raw HTTP/RPC JSON строгий UTF-8, финальный inspector `-X utf8`, native cwd совпал точно. Продуктовые дефекты из этих ошибок стенда не выводятся.

## Клиенты, стоимость и остаток

Повторные **48/48 file-role checks** (2 family × 12 adapters × 2 roles) passed. Native proof относится к Codex core/API. Найдены OpenCode Desktop `1.18.11`, Cursor, VS Code/Kilo `7.8.12`; это inventory, их MCP tool invocation не выполнен. Standalone диагностические CLI этих клиентов в проверенных PATH/common locations не найдены; desktop/IDE и остальные 11 adapters остаются unverified, поддержка не сокращается. Файл настройки, версия установленного приложения или общий backend не объявляются активацией всех frontends.

Принятые native runs: **19 safe MCP tool calls**, плюс 4 сохранённого failed reload harness; прямые HTTP probes — 16 safe tool calls. **LLM turn starts 0, Cognee calls 0**, новых always-on правил/tool schemas нет. Два прямых Code compact reads могли использовать существующий Qwen embedding backend/cache; его внутренний usage не измерен. Полученные tool catalogs — диагностический transport, не утверждение точного prompt/token budget. Иных runtime suites после неизменного source повторно не запускали; mandatory Targeted/регистрация документации принадлежат существующему source-delivery ledger.

Открыты live binding admission/namespace и source-version proof, полная native client/frontend matrix, остальные installed journeys/platform stands и выпускные условия общей [матрицы G3](g3-final-qualification-2026-10-20.md). Registry AC-39, memory AC-43/G5 и AC-44/registry AC-36–38 не закрыты. G1/Q1–Q7/D9/G2 не переоткрывались. Шесть областей/canonical home/ai_rules_1c/optional OpenViking прежние; Gate 6 не исправлялся/не запускался, G4, рабочая миграция и публикация не начинались.
