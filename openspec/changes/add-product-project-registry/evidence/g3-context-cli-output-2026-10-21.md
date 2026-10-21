# G3-CONTEXT-CLI-OUTPUT: исправление и повтор, 2026-10-21

**Дефект вывода закрыт в проверенной CLI/source области; full G3/AC-39 открыт.** Основание `9f8663dda5b7ecf7efa621b069ba939f885cf6ad`. [Exact inputs и raw SHA](g3-context-cli-output-2026-10-21.json) сохраняют before/after, регрессии и границы. Исходные [client/installed findings](g3-clients-installed-2026-10-21.md) не переписаны; Kilo aliases/API и остальные client/installed/platform gaps не закрыты этим исправлением.

## Изменение у существующего владельца

Public `agent-1c.ps1` с `-CatalogAction context` теперь выводит compact UTF-8 JSON на обоих прежних входах `vibecoding1c-mcp-status` и `vibecoding1c-mcp-select`. Existing UI owner сериализует уже построенную selected projection, включая unbound status. Новый CLI флаг не добавлен; внутренний `Invoke-ItlProductProjectCommand context` по умолчанию возвращает прежний DTO. Project/product IDs, origin/usage/limitations, registry provenance, readiness и optional observation comparison не менялись. Serialization не добавляет source inference, second resolver, full-catalog output, transport, state или runtime barrier.

Managed on-demand `references/mcp.md` уточняет формат: дополнительный `| ConvertTo-Json` публичному CLI больше не нужен. Старый diagnostic pipeline из прошлого report остаётся историческим workaround: после исправления он сериализовал бы JSON-строку повторно. Для программного чтения public stdout используется `ConvertFrom-Json`; внутренний helper остаётся объектным.

## Исходный reproducer и повтор

Использованы **те же** отдельные roots `Контекст клиента CUSTOM` и `Контекст клиента PROF`, прежние applied snapshots/catalog revision/role settings и сохранённые observation records. Before: обе реальные child CLI команды завершились exit 0, но дали нечитаемые nested dictionaries, 838/842 UTF-8 bytes; версия `5.0.3.66` и source differences не видны. После исправления **6/6** вызовов passed: на каждом root status с observation, status без observation и select с observation. Это проверки вывода, не новые native MCP calls и не свежая attestation старого observation.

| Сценарий | Видимые в JSON сведения |
|---|---|
| Custom PM5 КОРП → typical PM5 КОРП | project `qual-custom`, product/source origin `qual-pm5corp`, `customized=true`, полное описание доработки, Code/Graph `base-product`, ограничения типового source, configurationName/version/indexedAt с registry provenance |
| PM5 ПРОФ → PM5 КОРП | project `qual-prof`, product `qual-pm5prof`, source origin `qual-pm5corp`, `customized=false`, Code/Graph `reference-product`, явное ограничение функций КОРП, та же версия именно источника |

У обоих preserved observations видны binding/clientActivation `matched` с прежним checkedAt; без record поле sourceObservations отсутствует, базовые readiness/activeClientContext остаются `unverified`. Название `УправлениеПроектамиКОРП` прошло точный UTF-8 round-trip; `System.Collections...` не осталось. Ни productId ПРОФ, ни собственная версия проекта не подменены данными источника. Raw transport/full catalog/невыбранные проекты в stdout не добавлены.

На каждом root до/после сверены **19 уникальных paths** (всего 38) по SHA и actual `mtime_ns`: descriptor, selection/applied/operation/ownership receipts и все ранее перечисленные client config paths, включая отсутствующие файлы. Всё неизменно. Уточнение счёта: прошлый raw guard также содержит 19 уникальных keys, хотя summary называл 20. Это не потеря покрытия или изменение reproducer; прежний JSON сохранён, настоящий count теперь вычисляется из списка. Независимые explicit Codex config/Startup receipt proofs не затронуты. Старые Kilo `$schema` edits сохранены.

## Регрессии и стоимость

Existing ProductProjectSetup regression теперь запускает настоящий PowerShell child CLI для custom/PROF на обоих входах, проверяет nested values, кириллицу и пробелы в пути, ограничения/ссылки, registry version/indexedAt, отсутствие unselected catalog data, binding-vs-clientActivation distinction и неизменность state SHA/mtime. Отдельный unbound child не создаёт association; прежний in-process DTO test сохраняется. Проверки используют synthetic external-probe observation и не выдают его за native activation. PS5.1/Pester 5.8.0: **60/60**, zero failures/skips (Setup 38, Context 22), JUnit aggregate suite time 84.462 s; это не wall time или Startup benchmark.

Compact stdout с observation: custom **3071**, ПРОФ **3036 bytes**; без него **2367/2332 bytes**. Рост относительно неисправного default вывода +2233/+2194 bytes объясняется ранее скрытыми значениями. Для ПРОФ это на 4689 bytes меньше прежнего рабочего pretty-JSON workaround 7725 bytes. Whole diagnostic CLI after 2.479–3.129 s; before 2.550–3.821 s — несколько single runs под общей нагрузкой, не Startup benchmark и не доказанное ускорение. Native source/Startup pair budget, 20-warm engineering цели и ai_rules_1c lookup/card budgets не меняются. Новых always-on правил/tool schemas/MCP/LLM/embedding запросов — 0; exact tokens и внутренний backend usage не измерялись.

Результат узко закрывает G3-CONTEXT-CLI-OUTPUT / presentation часть 3.5 и AC-08/13/20. Полные 3.5/5.2/5.4–5.6, registry AC-39, обязательное выпускное наполнение AC-36–38 и memory consumer 4.2/AC-43/G5/44 остаются открытыми. Память использует тот же applied DTO; шесть областей/canonical home/grants/Q1–Q7/D9/G2/ai_rules_1c не меняются. Gate 6 не запускался/не исправлялся; G4, рабочая миграция, серверные изменения и публикация не начинались. Delivery/Targeted принадлежат обычному source-delivery ledger.
