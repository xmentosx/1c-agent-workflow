# G3 Cursor: native Code/Graph и reload, 2026-10-22

[Машинный отчёт и hashes 29 исходных артефактов](g3-cursor-native-reads-2026-10-22.json). **G3-CURSOR-NATIVE-AGENT-AUTH закрыт в проверенной области**: пользователь разрешил использовать другой, уже авторизованный профиль; native Agent выполнил два нужных чтения на исходном PROF root, signed-in reload и cleanup прошли. Полная G3 не объявляется принятой.

## Область и авторизация

Исходный private profile после сообщения пользователя о входе всё ещё показывал Login, в том числе после обычного Reload Window. Пользователь подтвердил, что вошёл в другом окне, и прямо разрешил его использовать. Credentials не копировались; auth stores/private Agent switches не читались и не редактировались. [Прежний failed/handoff report](g3-cursor-auth-qualification-2026-10-21.md) и его raw evidence сохранены.

Перед запуском в разрешённом профиле процессов Cursor уже не было. Запущен тот же installed executable с обычным пользовательским профилем и loopback debugger; обнаружена **3.26.16** вместо прежней 3.25.9. Причина смены installed build отдельно не устанавливалась, явные updater/deployment команды не выполнялись. Hash новой версии стабилен от запуска до cleanup. Это новый proof для 3.26.16, а не ретроспективная приёмка private 3.25.9.

Default profile сначала восстановил Agents dashboard/прежнюю IDE-папку. CLI argument сам по себе не подтвердил выбор PROF. Через обычные IDE → Open Folder/native picker открыт exact исходный Unicode root `build/test-results/g3/registry-source-model-20261021/Контекст клиента PROF`; установлен точный Unicode roundtrip поля выбора папки. До подтверждения этого root qualification prompt не отправлялся. Business association `qual-prof` → `qual-pm5prof`, intentional typical CORP endpoints и applied context не менялись.

## Нативная приёмка

Visible Settings показывал Log Out, Login overlay отсутствовал. Оба project MCP в разрешённом профиле первоначально имели состояние Disabled. Они включены **обычными UI source switches**: Code — 28 tools, Graph — 54. Common Computer Use/Origin и глобальный auto-run не менялись.

Один bounded Agent turn в модели из текущего UI `Grok 4.7 High Fast` потребовал ровно два вызова, без shell/files/search/browser/subagents/write/reindex. Named native JSONL transcript подтверждает actual namespaces/имена/аргументы; две отдельные native tool cards — completed и реальные payloads, а не только narration модели.

| Вызов | Actual arguments | Результат |
|---|---|---|
| `1c-code-metadata-mcp.stats` | `{}` | `status=success`; main source `УправлениеПроектамиКОРП`, `/app/code/Configuration.xml` |
| `1c-graph-metadata-mcp.list_graph_projects` | `{}` | accessible `pm5corp`, namespace `default`, `status=ready` |

Code `release.version=1.0.0` — версия сервера; отдельной версии конфигурации в stats payload нет. Её владельцем остаётся registry/applied context, его freshness здесь отдельно не переквалифицировался. Graph envelope namespace null и item `active_generation=null/ingestion_state=inherited` не отвергают readable `pm5corp/default`. PROF/CORP различие остаётся явным, новых producer stamps или патчей серверов нет.

Обычный **Developer: Reload Window** сохранил authenticated frontend, exact PROF workspace, 28/54 enabled tools и canary session. Через нормальное раскрытие persisted activity cards проверено точное равенство двух tool IDs/statuses/summaries/payloads до и после reload. Дополнительный qualification user/model turn для reload не запускался. Первый DOM probe увидел collapsed work group; промежуточный probe использовал другую projection без summary. Оба наблюдения сохранены; раскрытие UI и исходная полная projection подтвердили первоначальный контракт, критерии не ослаблялись.

## Сохранность, cleanup и расходы

- Fresh guard **19/19 unchanged** относительно начала и прежнего handoff: 16 existing + 3 absent; 11 physical client config files для 12 logical formats и 5 state/receipt files. Сравнивались exists/SHA256/bytes/actual mtimeNs; EXE новой версии стабилен.
- Оба project source switches через UI возвращены в первоначальные Disabled. Common Computer Use 9/Origin 31 tools прежние. Private auth/enablement API, credential copy и direct MCP substitute не применялись.
- Первоначальная IDE-папка восстановлена через native Open Folder. Один подготовительный UI helper до готовности command palette создал там несохранённый draft `File: Open Folder`; он не отправлялся. При возврате draft пуст, qualification canary в рабочей папке отсутствует. Квалификация выполнена только на PROF fixture, lifecycle/рабочая миграция не запускались.
- Native Browser.close завершил собственный Cursor. После двух временно оставшихся conhost helpers повторная проверка подтвердила **0 из 30 owned processes**; process termination не применялся. Log Out не выполнялся.
- **1 qualification user turn, 2 actual MCP calls**, UI `Worked for 12s`. Input/output/cache/reasoning tokens, provider request count/title traffic и billing отдельно не измерены; это не paired G3 added-context delta и не доказательство нулевой стоимости. Автоматический MCP/schema/background traffic, включая восстановленную первоначальную папку до выбора PROF, не назван нулевым. Startup/context/20 s budgets прежние; этот срез не устанавливает новую latency baseline.

Новых workflow always-on rules/tool schemas/startup probes и memory calls — 0. Остальные clients/CUSTOM/installed/platform/cost, full G3/AC-39/tasks 3.4/5.4–5.6 и release population AC-36–38 открыты. Memory consumer 4.2/AC-43/G5/44 не реализован; шесть областей/home/grants/ai_rules_1c/optional OpenViking прежние. Gate 6 не запускался/не исправлялся, G4, рабочая миграция и публикация не начинались. Commit/RegisterChange фиксирует source-only qualification evidence.
