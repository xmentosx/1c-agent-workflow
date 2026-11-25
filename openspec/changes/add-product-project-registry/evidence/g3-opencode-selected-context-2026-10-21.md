# G3 OpenCode Desktop: исходный выбранный каталог, 2026-10-21

**G3-OPENCODE-DESKTOP-SELECTED-CONTEXT закрыт для выбора исходного PROF root, native MCP activation и renderer reload.** Причина воспроизведённого зависания квалификации — незавершённый отдельный Windows folder picker, невидимый в Electron Page capture. Исправлена процедура проверки; runtime workflow, установленный OpenCode и серверы не менялись. Агентские чтения остаются открытыми отдельно: **G3-OPENCODE-DESKTOP-PROVIDER-403**.

[Machine evidence](g3-opencode-selected-context-2026-10-21.json) содержит SHA raw artifacts и точные границы. [Предыдущий desktop report](g3-desktop-native-2026-10-21.md) и его JSON/failed profiles сохраняются. Это продолжение прежнего reproducer, без нового каталога, удаления других client files или подмены source.

## Причина и исправление процедуры

- Тот же OpenCode Desktop **1.18.11**, SHA-256 `1ada75de8559702b55a1f9d6536fb6b9a5ab7edde6caedefcb98221936f7fe0f`, прежний отдельный private profile. Исходный каталог: `build/test-results/g3/registry-source-model-20261021/Контекст клиента PROF` в worktree `product-project-registry-g3/1c-agent-workflow`; exact absolute root закреплён в JSON.
- До выбора frontend показывает Default Project. Нажатие обычной кнопки `home-add-project` оставляет renderer неизменным, но Windows UI Automation находит отдельное окно `#32770` «Открыть проект» **того же main PID**. Его native Edit `1152` и Select `1` отсутствуют в DOM Electron. Поэтому отсутствие изменений в Page screenshot не доказывает отказ кнопки/привязки.
- Через ValuePattern в поле папки внесён **тот же полный путь**, проверен точный Unicode round trip, вызван обычный InvokePattern кнопки «Выбор папки». Сразу после завершения picker в Home появляется «Контекст клиента PROF»; новая сессия открывается с этим проектом и Git `main`. Backend сам загружает его прежний `opencode.json`.
- Квалификация теперь проверяет и завершает native dialog, затем отдельно доказывает selected directory, MCP status и actual reads. Минимальное повторяемое UIA извлечение использованной последовательности сохранено как raw helper `select-native-project.ps1`; это source-only evidence, не установленный runtime/новый bridge. Helper не выбирает другой root при ошибке.

Это причинный контроль «renderer прежний при открытом picker → штатный выбор исходного пути → нужный проект». Прежние позиционный аргумент/deep links не заменяют завершённый picker; работоспособность каждого из этих входов не заявляется. Причина **самого первого long-profile startup failure** по-прежнему не изолирована: прежняя попытка меняла одновременно длину profile path и наличие home/AppData. Она не переписана в pass и не превращена в MAX_PATH defect.

## Результаты native повторения

| Проверка | Результат и предел |
|---|---|
| Выбор каталога и новая сессия | Passed: видимое имя исходного PROF проекта, журнал загрузки его `opencode.json`, native session directory равен исходному root |
| Native MCP UI | Passed: ровно `onec-code-metadata-mcp` и `onec-graph-metadata-mcp`, два зелёных connected-индикатора; никаких imported Kilo aliases |
| Renderer reload | Passed: frontend сам отправил scoped GET `/path` и `/mcp` в свой штатный Desktop backend; оба HTTP 200. `/path.directory` равен исходному root, `/mcp` содержит ровно два `status=connected`. Это наблюдение собственных frontend requests, не прямой внешний MCP вызов или injected route/state |
| Агентский canary | **Blocked**: одна отправка в native session через Big Pickle, HTTP 403, `isRetryable=false`: “OpenCode's free tier can only be used from within OpenCode.” Ни одного tool part/call. Полезные Code/Graph payloads и native tool schema count этим запуском не квалифицированы |
| Preservation | Passed: fresh before/after **19 unique paths** исходного PROF root, включая все 12 client config files, receipts/selection/контекст; SHA, bytes, actual mtimeNs прежние. EXE SHA прежний |
| Cleanup | Passed: семь owned процессов закрыты обычным Browser.close, remaining 0. Failed/private profiles, прежние artifacts и исходный root сохранены |

Native session `project_id=global` — внутренний идентификатор OpenCode, **не** catalog association и не принятие Default Project. Выбранный каталог подтверждён отдельно exact directory и frontend requests. Business project `qual-prof`, его PROF product и намеренно выбранный typical CORP source/ограничения остаются в прежнем applied context. Code/Graph configuration/version берутся из registry; native подключение само по себе не обновляет registry-version observation и не доказывает применимость каждой функции CORP к PROF.

## Расходы, сохранённые ошибки и продолжение

Один user turn, **два** фактических provider stream attempts: native auto-title и основной build, tool calls 0. Native DB хранит usage/cost counters 0 после отказа; **это не измерение объёма отправленного контекста, нулевая стоимость биллинга или G3 token delta**. Другой provider/аккаунт не подключался, credentials не копировались, повторов 403 не было. Успешная tool-use приёмка требует доступного разрешённого provider в этом же Desktop/root и проверки actual `stats({})` / `list_graph_projects({})` payloads; не требует патча Code/Graph, отключения прав или переноса вызовов в shell.

Первый passive reload observer завершился собственной ошибкой `undefined.endsWith` на записи без URL; она исправлена у observer и reload повторён. В успешном raw trace сохранены три empty-body JSON warnings для OPTIONS 204; они не являются ошибками native GET 200. Native frontend не модифицировался observer. Прежний скачанный updater candidate оставлен pending, обновление клиента не устанавливалось. Время первоначальной активации и paired context/20 s budget здесь отдельно не измерялись.

Новых always-on правил, tool schemas, startup probes и memory calls **0**. Полные G3/AC-39, 3.4/5.4–5.6, CUSTOM/installed/platform journeys и release population AC-36–38 остаются открытыми. Cursor auth blocker не закрыт. Consumer memory 4.2/AC-43/G5/44 не реализован. Gate 6 не исправлялся/не запускался; G4, рабочая миграция и публикация не начинались. Mandatory Targeted и queue outcome фиксирует только RegisterChange.
