# Основания постановки

## Область и свежесть

Это фиксация результатов проведённой read-only инвентаризации 15–16 октября 2026 года и узкого просмотра исходников для постановки. При оформлении OpenSpec сетевые пробы повторно не запускались. Значения ниже являются снимком, а не гарантией текущего состояния endpoints. Запись в Mantis, переиндексация, перезапуски, установка и вызовы проверки кода с LLM не выполнялись.

Checkout постановки: `1c-agent-workflow`, ветка `develop`, HEAD `c900620e6569ce4cec39e30abfa3f8ce2c150ce1`. Сохранённый `origin/develop` — `81e8f1f38bf1e751898bb974ff4876cd2ca1adb2`, отставание 155 commits. Это разные основания: местный исходник не доказывает поведение развёрнутого сервера. Перед будущей реализацией требуется согласовать change с актуальным исходным base, сохранив чужие изменения; fetch/merge сейчас не выполняется.

## Git-реестр и владение

Для конкретизации G2/D9 2026-10-19 повторно прочитаны только локальные owner paths: `agent-1c.vibecoding1c-mcp.ps1` (`Ensure-/Read-Vibecoding1cMcpRegistry`, selection, `Write-Vibecoding1cMcpClientConfig`), `agent-1c.lifecycle.ps1` (branch state/New/Reset), host `New-RegistryPayload`/`Write-MergedRegistryPayload`/`Publish-Registry`, точки owner tests `McpConfig.Tests.ps1`/`HostTooling.Tests.ps1`. Основной HEAD остаётся `c900620e6569ce4cec39e30abfa3f8ce2c150ce1`, memory worktree HEAD — `e9dc695d3b792179f10c35898ba02daebf0bb66c`. Business resolver пока отсутствует; в design исправлено описание его как уже существующего. Это уточнение планирования по локальным исходникам, без fetch, повторных live probes или утверждения актуальности deployed source. Перед кодом G2 нужен актуальный отдельный source base с повторной проверкой владельцев.

Реестр: [MCP-vibecoding1c-registry](http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry). В дереве проверенного tip были только `README` и `registry.json`; `catalog.json` и `product-relations.json` отсутствовали (raw 404).

Во время инвентаризации tip изменился с `092a392e34dd490ff0d49ab3f5f4806c2b93374b` на `3ebe67eb99e5f897f6c18058e5df8176f3094ab9`; версия и bindings проверенных источников не изменились. [Закреплённый registry.json](http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry/raw/3ebe67eb99e5f897f6c18058e5df8176f3094ab9/registry.json), publishedAt `2026-10-16T00:20:53.7527413+03:00`.

[`New-RegistryPayload`](../../../vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1) заново строит корневой объект schema v2. Произвольные бизнес-поля в корне `registry.json` будут потеряны при публикации. Следствие: каталог и отношения должны быть отдельными файлами в отдельном каталоге того же репозитория; publisher не владеет их содержимым. Все нужные файлы читатель разрешает из одного Git SHA.

## MCP: протокол и источники

Для 16 endpoints двух hosts прошли `initialize → notifications/initialized → tools/list`. Дополнительно выполнены ограниченные безопасные функциональные чтения. Это подтверждает доступность перечисленных путей, но не полный набор функций каждого инструмента.

| Host / конфигурация | Code / Graph | Что подтверждено |
|---|---|---|
| `dev-ermakov.itland.local`, `pm5corp` | `22100/mcp`, `22101/mcp` | Отдельные источники PM5, code stats и структурный graph search |
| тот же host, `pm4corp` | `22200/mcp`, `22201/mcp` | Отдельные источники PM4, code stats и структурный graph search |
| `dev-karimov-new.itland.local`, `unfpm5` | `22100/mcp`, `22101/mcp/` | Составная конфигурация УНФ+PM5 одним источником |
| тот же host, `erppm5-lts` | `22200/mcp`, `22201/mcp/` | Отдельный составной ERP+PM5 LTS, без основания подменять им любой ERP+PM5 |

В registry указаны версии: PM5 `5.0.3.62`, PM4 `4.2.40.2`, УНФ+PM5 `3.1.14.146`, ERP+PM5 LTS `2.5.527.94`. У PM4/PM5 есть fingerprints, у двух составных записей их нет. Эти строки принадлежат registry; code stats не доказывает точное равенство текущей конфигурации указанной версии. Отдельных опубликованных источников ПРОФ, PM4-составных продуктов и расширений не обнаружено.

Code возвращает 28 tools на endpoint. Внутренний `project_id` всех четырёх индексов одинаков: `code-20d3eae87f48`, поскольку вычислен по одинаковому внутреннему пути `/app/code`. Collections, source hashes и generation при этом различаются. Этот ID без endpoint и namespace нельзя считать глобальной идентичностью проекта. В составном источнике PM-компонент не выделен самостоятельным `origin`; метка каталога не создаст такую сегментацию.

Graph возвращает 54 tools. На каждом endpoint найден один проект: `erppm5-lts`, `unfpm5`, `default` для PM4 и PM5 на разных endpoints. Структурный `search_code` с правильным project ID вернул результат, с `inventory-unregistered-project` — `project_not_accessible`. `graph_scope_enforced=false` и отсутствие активной ingestion generation сами по себе не доказали непригодность этого выделенного endpoint: чтение работало. Business search отключён без LLM key; он не нужен для данной постановки.

Общие восемь endpoints на `dev-ermakov`: BookStack `18005`, Mantis `18006`, СППР `18007`, документация платформы `22000`, шаблоны `22001`, синтаксис `22002`, code checker `22003`, БСП `22004`. Имена существующих клиентских серверов сохраняются, включая `1c-code-metadata-mcp`, `1c-graph-metadata-mcp`, `BookStack-product-docs-mcp`, `sppr-knowledge`, `itl-mantis-ticket-mcp`.

## BookStack: обнаруженный дефект области

Endpoint работал: 199 страниц (198 embedded, одна пустая), 1495 fragments, pending 0. Книги включали IDs 19, 20, 25, 26, 30, 65, 82. Страница [«Подготовка демо-базы PM5 ПРОФ из демо-базы PM5 КОРП»](https://kb.itland.ru/link/628) подтверждает документированный сценарий преобразования, но не отдельный полный источник документации ПРОФ.

| Контроль `search_docs`, query `планирование`, mode `text`, limit 2 | Наблюдение |
|---|---|
| Без фильтра | 41 совпадение, среди возвращённых pages 309, 656 |
| `book=__inventory_missing_book_20261016__` | Вернулись чужие live pages 168, 185, total 3 |
| `book_id=-1` | Фильтр проигнорирован: те же 41 совпадение |

В [`bookstack-product-docs-mcp/server.py`](../../../vibecoding1c-mcp-host/bookstack-product-docs-mcp/server.py) `matches_filters` не обрабатывает `book_id`, а live fallback сливается без той же проверки фильтров. Причина подтверждена также исходником развёрнутого commit `814b0b234fcdf9066b774d64d0f9b6ff6ce29a0d`; переиндексация не исправляет этот дефект.

Требуется единая серверная проверка стабильных selectors для cache/semantic/live и чтения выбранной страницы. Неизвестный selector должен давать понятный отказ/пустой результат по контракту, никогда весь каталог. Наличие `sourceId` только в локальном JSON недостаточно.

## СППР и точная связь Mantis

Endpoint предоставляет семь tools: поиск/чтение, отношения, context, список объектов, пути, index status. Доступна область проекта `76bcfc1f-e8c2-4cd6-80ef-997b99bca476`: 4883 видимых объекта, 72268 fragments/vectors, pending 0; observation end `2026-10-14T22:57:57Z`. Ссылки ведут в `pskov/itland_work_SPPR`.

`list_sppr_objects` с этим project UUID вернул объекты, с несуществующим UUID — total 0. Область чтения работает; статус не даёт достаточного справочника названий проектов для удобного выбора. Нужны ограниченные metadata существующего сервера, а не полный обход СППР.

Точная проверенная пара: объект `Catalog_ТехническиеПроекты:0089e9c3-75a7-11ef-8122-000c295e34e3`, «Механизм выбора картинок из коллекции», код `00-00001092`, поле `итлКодMantis=59095`; `итлСсылкаНаМантис` пусто. [Mantis 59095](https://support.itland.ru/view.php?id=59095) имеет то же название, проект 609. Это фактическая ссылка. Семантические похожие результаты для другого номера не являются связью.

Коллектор сейчас обслуживает одну область; добавление ссылки в каталог не расширяет сбор и серверные разрешения. Развёрнутый сервер новее локальной копии исходников с четырьмя tools; реализация должна опираться на актуальный владеющий source base.

## Mantis: несколько проектов и ограничение поиска

Endpoint предоставляет десять tools, метаданные 30 проектов, индекс 18778 обращений, embedding backlog 0. Текущая service account показывает доступ developer (55); прежние записи о viewer не описывают этот снимок. `write_enabled=true` и наличие writer tools не проверялись реальной записью.

| ID | Название из метаданных |
|---|---|
| 305 | Развитие «1С:PM» |
| 327 | 04. PM и ERP+PM (поддержка) |
| 609 | Разработка «1С:PM5» |
| 699 | 10. Поддержка PM5, EPR+PM5, Модуль PM5 |
| 814 | 11. Поддержка УНФ+PM5 |
| 815 | Развитие «1С:PM5» |

`search_tickets` принимает скалярный `filters.project_id`. Массив `[699,814]` дал ошибку преобразования `int(list)`; [`mantis_index.py`](../../../vibecoding1c-mcp-host/mantis-ticket-mcp/mantis_index.py) подтверждает скалярное преобразование. Поиск для 699 с limit 2 вернул 62503/62154; для 815 пустой запрос дал 0, однако оба пути ограничили глобальную выборку 10000 кандидатов до проектной фильтрации. Поэтому ноль не доказывает отсутствие задач проекта. Наблюдавшееся время этих запросов — примерно 26–39 секунд; это диагностический baseline, не новый SLA.

[Обращение 62503](https://support.itland.ru/view.php?id=62503) про демо-базу УНФ находится в проекте 699, а не обязательно 814. Название продукта или задачи не даёт надёжного правила маршрутизации. Список поиска и purpose-маршруты создания должны задаваться явно. Multi-project filter нужно применять до ограничения кандидатов и сохранить корректность cursor/полноты; локальный fan-out по N проектам не решает глобальное отсечение и умножает стоимость.

## Существующие владельцы локальной настройки

- [`agent-1c.vibecoding1c-mcp.ps1`](../../../.agents/skills/1c-workflow/scripts/lib/agent-1c.vibecoding1c-mcp.ps1): чтение registry v2, отдельные `configId`/`hostId`, выбор remote runtime, сохранение ignored selection. При отсутствии записи сервер обычно enabled; полнота выбранных code/graph проверяется до unattended. Клиентский endpoint сейчас передаёт URL/timeout без бизнес-области.
- [`agent-1c.core.ps1`](../../../.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1): мастер PM4/PM5, текущий PM5-only допуск BookStack. Новый opt-in профиль требует совместимой замены этого допуска; старый непомеченный проект сохраняет контракт.
- [`Write-ItlClientMcpEndpointSet`](../../../.agents/skills/1c-workflow/scripts/lib/agent-1c.client-adapters.ps1): preflight всего набора, hashes входов, managed ownership и receipts. Уже завершённые записи при более позднем конфликте остаются учтёнными; автоматической атомарной транзакции по всем файлам нет. Требуется расширить восстановление этого владельца, не создавать второй writer/coordinator.
- [`AGENT-INSTALL.md`](../../../AGENT-INSTALL.md): все решения конфигурации принимаются до unattended/download/1C/Git baseline; отказ выбранной настройки нельзя превращать в молчаливый пропуск.
- [`templates/project.json`](../../../templates/project.json): tracked общие настройки; `.agent-1c/mcp/vibecoding1c-selection.json` и runtime snapshot — ignored. Личные пути и credentials не попадают в общий каталог.

Ближайшие проверки: `tests/pester/McpConfig.Tests.ps1` (неполный выбор, независимые роли), `BootstrapUpdate.Tests.ps1` (мастер/отмена), `MultiClientMcpOwnership.Tests.ps1` и client adapter suites (ownership/JSONC), серверные `test_server.py`, `test_index.py`, `test_sppr.py`, `test_transport.py`. Эти тесты при подготовке постановки не запускались.

## Связанные постановки

В основной `openspec/specs` нет опубликованных capabilities. Существующие delta changes не являются основной спецификацией и сохраняют собственную приёмку:

- [add-sppr-knowledge-mcp / sppr-retrieval](../add-sppr-knowledge-mcp/specs/sppr-retrieval/spec.md): точные ссылки, типизированные отношения, bounded provenance и read-only corpus. Переиспользовать; не выдавать семантическое сходство за связь и не вводить новую систему прав.
- [extend-mantis-mcp-search-and-write / mantis-search](../extend-mantis-mcp-search-and-write/specs/mantis-search/spec.md): общая видимость, фильтры, cursors, bounded context; новый список проектов дополняет существующий scalar API. Старый сценарий запрещает поиск содержимого вложений, а живой сервер уже имеет extraction: это отдельное расхождение истории данной постановки, не основание откатить текущую функцию или менять её здесь.
- [bookstack-qwen-fulltext / bookstack-complete-semantic-index](../bookstack-qwen-fulltext/specs/bookstack-complete-semantic-index/spec.md): полнота индексирования и embedding migration. Фильтрация источников не требует повторения миграции Qwen.
- `redesign-source-delivery` и `workflow-bound-dependencies` — существующие посторонние untracked changes; эта работа не меняет их или delivery authority.
- [add-scoped-cognee-memory](../add-scoped-cognee-memory/proposal.md) — связанная постановка, первоначально в отдельном planning worktree; согласованная пара теперь сохранена одним source commit `29501656`. Реестр владеет business home/applicability/revision; memory consumer — native IDs/grants/currentness. Код/consumer proof G2 и native G1 имеют отдельное evidence, документы сами их не доказывают. Исходный planning worktree памяти сохранён; G3/G4 остаются не начатыми.

2026-10-19 по отдельному запросу пользователя согласованы общий порядок G0–G6 и миграция legacy установок: package update → choose/create/later → preview/association → separate memory opt-in. Existing selection/writer/lifecycle остаются владельцами defer/receipts/initial cycle; нет нового migration manager. Q1–Q7 Cognee обязательны до зависимого G4 памяти и не блокируют registry-only G2/G3/выпуск. Эти пункты — новые требования планирования, а не результаты live проверки или реализованная миграция; приёмка добавлена в test-plan обоих changes.

## Что пока не доказано

Нет опубликованного каталога, подтверждённого полного набора связей продуктов/областей знаний и окончательного списка маршрутов СППР/Mantis. Приведённые IDs пригодны как проверенные примеры, но не как автоматически утверждённая бизнес-карта. Не проверены новая bootstrap/update цепочка, offline/conflict/rollback, live multi-project API и BookStack source isolation после исправления, Win10/Server/terminal canary, а также запись Mantis. Эти результаты нельзя считать выполненной приёмкой; их будущие доказательства определены в [test-plan.md](test-plan.md).

## Основание checkpoint G3, 2026-10-19

План подготовлен по чистому source HEAD `29501656b64285023be97b2b0edac908cd9e9ea3` в worktree `product-project-registry-g2`, без fetch/deploy/probe или запуска installed helper. Проверены только целевые локальные paths:

- `agent-1c.ps1`: lifecycle admission и повторный Read-ProjectConfig предшествуют action dispatcher; native database admission находится на собственной phase boundary. Отсюда одно место будущего startup, без перехвата каждого wrapper/broker.
- `agent-1c.vibecoding1c-mcp.ps1`: G2 on-demand reader/resolver, existing `Invoke-Vibecoding1cMcpRegistryOperation` кэширует попытку на script operation; managed refresh делает clone/fetch/ff через shared Git helper. Это ещё не G3 10 s startup transport или persistent apply/recovery.
- `Write-ItlClientMcpEndpointSet` в `agent-1c.client-adapters.ps1`: full-input/owner hash preflight, per-write receipts и lastWritten есть; полный G3 persisted before-write plan/status/resume/owned restore требует расширения этого же owner. Current-root MCP paths и все clients берутся из действующего adapter registry.
- `Read-ProjectConfig` в core читает JSON без capability rejection; wizard спрашивает PM4/PM5, BookStack guard основан на PM5. Поэтому opt-in parser/setup и managed downgrade требуют явной compatibility реализации; историческому parser нельзя приписать будущую проверку.
- Локальный BookStack `matches_filters` по-прежнему не проверяет book_id; Mantis локально использует scalar project_id и SEARCH_CANDIDATE_LIMIT=10000. Это source основания G3.2, не повторный live inventory и не заявление об актуальном deployed сервере.

Выпускной перечень, реальные настройки/карта и data publication не выполнялись. Предложенные бюджеты startup/save и no-op цели не измерены; AC-39 открыт. Перед будущим кодом сверить актуальный source/queue, перед canary — build/stand/source identity. Checkpoint подготовлен, approval не получен; текущая граница только документы.

## Source base G2, 2026-10-19

Для разрешённого G2 выполнен fetch origin/develop; создан отдельный managed worktree `product-project-registry-g2` на `181e1da00a08e56d2d0ac57d24a92e7187484e06`. Main checkout, memory worktree и unrelated changes сохранены. Повторно проверены текущие reader/continuity owner и publisher: pure catalog API добавлен только on demand, continuity/startup не изменены. Native Cognee/рабочие базы/production registry не затрагивались; прошлый live inventory не объявляется обновлённым. Пилот PM5 КОРП/его типовой проект подтверждён текущим ответом пользователя, новые areas/homes и внешние routes не утверждались.
