# G3 OpenCode Desktop provider 403: owner repair и native reads, 2026-10-21

**G3-OPENCODE-DESKTOP-PROVIDER-403 закрыт в области отдельной официальной Desktop 1.19.3 и исходного PROF-проекта.** Ровно два actual native tool calls прошли: Code `stats({})`, Graph `list_graph_projects({})`. Проверены payloads в native session DB, видимый frontend и scoped MCP activation после renderer reload. [Machine evidence](g3-opencode-provider-repair-2026-10-21.json) закрепляет исходники диагностики, hashes и расходы.

## Причина и выбранное исправление

У установленного Desktop 1.18.11 обнаружен дефект метаданных встроенного backend: `InstallationVersion` берётся из отсутствующего compile-time `OPENCODE_VERSION` и становится `local`. Native session прежнего неуспешного запуска также имеет `version=local`; provider-код формирует `User-Agent` из этой версии. Это согласуется с [upstream issue #49433](https://github.com/anomalyco/opencode/issues/49433), где нерелизные версии отклоняются free-tier проверкой. Сам текст 403 неоднозначен: в upstream есть и другие причины, поэтому он сам по себе не доказывает отсутствие входа в аккаунт или поломку MCP.

В [официальном релизе 1.19.3](https://github.com/anomalyco/opencode/releases/tag/v1.19.3) native constant корректен: `InstallationVersion="1.19.3"`. Уже скачанный updater package проверен по Authenticode (Anomaly Innovations, Inc) и SHA-512 его сохранённого manifest; installer **не запускался**. Его неизменённое приложение извлечено в отдельный ignored qualification directory и запущено с копией прежнего private test profile. Новая native session подтверждает `version=1.19.3`, тот же provider/model Big Pickle и исходный root; 403 отсутствует.

Исправление выполнено у владельца дефекта заменой тестируемой vendor build. Исходная установленная **1.18.11 не обновлялась**; её EXE SHA, профиль и failed session сохранены. Это не утверждение о починенной основной установке или о пройденном installed/client matrix. Header spoofing, vendor source/binary patch, новые credentials, proxy/bridge, ослабление permissions и workflow/server patches не применялись. Прямая wire-level вариация только одного header не проводилась: вывод о факторе версии опирается на статический native code path, старую/новую session version, upstream и успешный повтор с исправленным vendor release; другие изменения между релизами не изолированы.

Исходный путь и workload сохранены: `build/test-results/g3/registry-source-model-20261021/Контекст клиента PROF` в worktree `product-project-registry-g3/1c-agent-workflow`, все 12 client formats (11 physical config files), association `qual-prof` → `qual-pm5prof`, прежние CORP endpoints и applied context. Profile клонирован только из созданного для этой квалификации профиля, пользовательские credentials не переносились. Same prompt отправлен через обычный native editor в новую сессию; прямые MCP/CLI/model API вызовы не заменяют результат.

## Проверенный результат

| Проверка | Результат |
|---|---|
| Code | Native `onec-code-metadata-mcp_stats`, input `{}`, `completed` **и** JSON `status=success`. Конфигурационное имя `УправлениеПроектамиКОРП`, root `/app/code`; collections metadata 3694/code 134160/help 4189/forms 1744. Tool duration **386 ms** |
| Graph | Native `onec-graph-metadata-mcp_list_graph_projects`, input `{}`, `completed` **и** один доступный `pm5corp`, namespace `default`, `status=ready`, `is_accessible=true`, `configuration_root_valid=true`, root `/app/code`. Tool duration **374 ms** |
| Scope/применимость | Exact original PROF directory в native session и frontend-originated scoped GET `/path`/`/mcp`. Ни native `project_id=global`, ни Graph namespace не заменяют business association или memory home/grants. PROF не объявлен равным CORP |
| Reload | Renderer reload сохранил новую успешную session и два expected connected MCP; собственные frontend GET `/path`, `/mcp` вернули HTTP 200 с exact root. После reload дополнительных LLM/tool calls не запускалось |
| Preservation/cleanup | Fresh before/final **19 unique paths** (16 существующих + 3 отсутствующих): 11 physical client config files для 12 client formats и 5 state/receipt files. SHA/bytes/actual mtimeNs/absence прежние. Исходный installed EXE SHA прежний. Семь owned процессов завершены обычным Browser.close, remaining 0; обе версии/profile/artifacts сохранены |

Native Graph `active_generation=null`/`ingestion_state=inherited` допустим по прежней registry-only модели. Envelope context содержит null project/namespace для list operation, но positive acceptance опирается на **item** `pm5corp/default` и `data.mcp_namespace=default`. Code `release.version=1.0.0` — версия сервера, **не конфигурации**. Название/версия конфигурации и indexing metadata продолжают приходить из technical registry/applied context; новый probe/version stamp или Code/Graph patch не требуется. В этом срезе свежесть registry version отдельно не переквалифицировалась.

Payloads, inputs, statuses, model output и usage сохранены отдельно. В UI tool-group caption повторяет Graph label; подсчёт и семантика взяты из двух distinct native tool parts, а не из caption или пересказа модели. Поддержка всех client/provider/model сочетаний этим canary не заявляется.

## Расходы и оставшийся объём

Один новый user turn вызвал **3 provider stream attempts**: native auto-title и два build rounds (tools → answer), ровно **2 tools**, других tool calls и provider errors нет. Native **основные** assistant counters: input **56 619**, cache read **56 887**, output **458**, reasoning **507**, reported cost **0**. Auto-title usage этими assistant counters отдельно не измерен; они не являются billing proof или paired G3 token delta. Tool durations 386/374 ms не заменяют измерение startup/context/полного user journey. Новые workflow always-on правила, tool schemas, startup probes и memory calls — **0**.

Счёт уточнён: 12 logical client formats используют 11 существующих physical client files; ещё 5 существующих state/receipt files и 3 отсутствующих допустимых OpenCode paths дают 19 guards. Прежнее выражение «12 client files» было неточным; raw before/after maps сохранены.

Начальное неверно декодированное 7-Zip listing не использовано как evidence: повтор с `-sccUTF-8`, strict decode и exact whitespace+Cyrillic path round trip сохранён. Неуспешные [первый desktop срез](g3-desktop-native-2026-10-21.md) и [403/selected-context срез](g3-opencode-selected-context-2026-10-21.md), их JSON/raw records не переписаны.

Source-only native qualification использует vendor release с согласованной frontend/backend версией; это не новый installed startup barrier, не поддерживаемый workflow updater для OpenCode и не обязательный memory provider. Полные G3/AC-39/3.4/5.4–5.6, остальные clients/CUSTOM/installed/platform journeys, Cursor auth и release population AC-36–38 остаются открытыми. Memory consumer 4.2/AC-43/G5/44 не реализован. Gate 6 не исправлялся/не запускался; G4, рабочая миграция и workflow publication не начинались. Commit/RegisterChange outcome остаётся у общего delivery ledger.
