# G3: нативные Code/Graph и reload на текущем PM5, 2026-10-24

**Результат: Kilo и Cursor прошли в указанном PM5 subset; OpenCode — частично, агентские чтения BLOCKED квотой провайдера. Полная G3/AC-39 не принята.** Код workflow и серверов не менялся. Gate 6, G4, рабочая миграция и публикация не выполнялись.

## Стенд и идентичность

Существующий изолированный PM5 stand: `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`. Ветка — соседний `branch`, без binding; основной проект `pm5-core-development` / `pm5-corp`, membership Kilo+Cursor. Установленный workflow `dfae2ff3353cd0784867eb8eac5d115a2d3d741a`, ai_rules r43 `987320be139b4ac0d28f1f5b0f2515f63c7f140f`. Source `08ad9751d1d55077fc80efdb27cb2565f4db1afd`; 10 relevant runtime paths совпадают с установленным пакетом и прежним cost proof. Файловая база находится в branch, SHA-256 `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`, 3295928320 bytes. 1С не запускалась. UTC timestamps 23 октября относятся к локальному 24 октября (UTC+3).

Для OpenCode выполнен существующий публичный `sync-client-mcp -Client opencode` только на этом stand; membership/выбор инструментов не изменён. Это подготовка тестового клиента, не миграция установки. После проверки подготовка снята с точным восстановлением пяти архивированных файлов/отсутствий.

## Нативная матрица

| Клиент | До reload | Reload | После reload | Приёмка этого subset |
|---|---|---|---|---|
| Kilo 7.8.15 в VS Code 1.142.0 | `stats({})` + `list_graph_projects({})`, completed | Настоящий Developer: Reload Window; новая webview, та же сессия/PM5 root | Два новых completed вызова | PASS, 4 native tool calls |
| Cursor 3.27.12, ранее авторизованный default профиль | Два completed вызова | Настоящий Developer: Reload Window; тот же root/чат, project MCP retained | Два новых completed вызова | PASS, 4 новых native tool calls, executable SHA до/после одинаков |
| OpenCode Desktop 1.19.3, отдельный qualification профиль/build | Выбран точный PM5 root; оба MCP connected. Big Pickle: `Free usage exceeded, subscribe to Go`, 0 tool calls | Нативный renderer Page.reload; scoped frontend GET `/path` и `/mcp` вернули 200 | PM5 directory/worktree и оба connected сохранены; модель повторно не запрашивалась | Контекст/подключения PASS; агентские чтения до/после BLOCKED |

Вызовы сделаны агентами в настоящих клиентах; это не прямые MCP-requests из harness. Разрешены только `stats` и `list_graph_projects`, аргументы пустые. Kilo: Ask/Auto Free, 4 отдельных Allow once, private test profile с прежним qualification flag `KILO_EXPERIMENTAL_MCP_APPS=1`; это не proof всех default environment вариантов. Cursor: текущий повтор — Agent/Grok 4.7 Extra High, два source switches временно включены штатным UI (28/54 tools) и возвращены в Disabled; общие Computer Use9/Origin33 и canaries не изменены. Авторизация не читалась и не переносилась.

Первый Cursor-прогон дал ещё 4 native calls на стартовой 3.26.16 (Grok 4.7 High Fast). После закрытия executable на диске уже 3.27.12: strict identity guard не прошёл. `Install Now` не нажимался, источник обновления не установлен; первый прогон не объявлен проверкой неизменного клиента. Он сохранён, затем проведён полный новый прогон на 3.27.12 с повторной проверкой SHA. Всего за задачу 12 реальных MCP tool calls; 8 относятся к стабильным принятым Kilo/Cursor-прогонам.

OpenCode использует ранее отдельно извлечённый vendor build 1.19.3 с сохранённым SHA; проверка не означает обновление/исправление установленной 1.18.11. Native Windows folder picker подтвердил Unicode round-trip для точного PM5 пути. После quota error отложенный autoretry6007s остановлен кнопкой Stop; после reload Stop отсутствует, native DB подтверждает 0 вызовов. Для продолжения запрошен уже настроенный доступный профиль/провайдер, без ключей; ответа с таким профилем к фиксации результата нет. Нужен повтор обоих чтений до/после reload с доступной моделью, а не новый proxy или изменение workflow.

## Что установили payloads

Каждый из 8 принятых native payloads проверен по фактическому JSON. Code: `status=success`, основная конфигурация `УправлениеПроектамиКОРП`, `/app/code`, marker `/app/code/Configuration.xml`. `release.version=1.0.0` — версия сервера; версия конфигурации здесь отсутствует. Graph: `pm5corp` / `default`, ready, accessible, valid configuration root `/app/code`. Null project/namespace в envelope списка и inherited ingestion не являются отказом. Эти payloads доказывают доступность источников в выбранном клиенте, не актуальность версии конфигурации или совпадение всех доработок проекта с типовым источником.

Версия/индексация и назначение источника остаются сведениями registry; различия проекта и MCP-source задаются вручную в реестре, без обязательных server patches или собственного revision verifier. Этот CORP-прогон не повторяет прежние custom → typical / ПРОФ → КОРП сценарии и не расширяет их приёмку. Registry origin не изменён; свежая актуальность удалённого registry отдельно не квалифицировалась.

## Сохранность и расходы

Начальная whole-byte проверка после native первого старта **не прошла**: клиент добавил ровно49 bytes `$schema` в `.kilo/kilo.json` и переформатировал подготовленный `opencode.json`. Все исходные Kilo bytes кроме новой строки сохранены, весь `mcp` равен исходному; все5 OpenCode MCP entries равны сохранённым до запуска owner signatures. Эти факты не заменяют failed byte assertion. После native settling reload/остальные клиенты сохраняли SHA и настоящий mtime всех46 контролируемых путей. После закрытия клиентов CAS проверил все46 путей; test-actor teardown восстановил ровно5 изменённых fixture files/отсутствий из архива. Final guard:46/46 byte+mtime equal исходному, membership и оба Git roots прежние/clean. Это снятие подготовки fixture, не дополнительная приёмка штатного product restore.

База, 21 historical protected artifact, 4 seed/failed roots, 11 capsule artifacts и 1361 файлов двух прежних sealed manifests проверены и сохранены. Старый live raw seed не восстановлен этим прогоном; capsule не выдаётся за live-seed currentness. Клиенты закрыты штатно: owned trees21/16/15 процессов и13 повторного Cursor, remaining0; raw PID kill не использовался. Fixture lease освобождена.

Kilo native session counters: input140744, output293, reasoning699, cache-read132683. Это показания конкретного клиента, не отдельные оплачиваемые токены и не incremental G3 overhead. Для Cursor сопоставимый token/billing counter не получен; известно4+4 tool calls в двух прогонах, по2 квалификационных user turns. OpenCode имел один отклонённый запрос к модели, 0 tools. Initialize/tools-list/title/schema traffic не заявляется нулевым. Stats payload объёмный; этот диагностический сценарий не добавлен в Startup/always-on. Новых always-on инструкций/схем, probes или memory calls нет; прежний cost baseline сохраняет свою отдельную область доказательств.

Ошибки инструментирования сохранены отдельно: stdout Unicode до явного UTF-8, запросы до готовности CDP, ранние свернутые/пустые tool cards, screenshot чужого foreground и попытка разобрать усечённый stdout preview вместо полного сохранённого JSON. Они не превращены в pass нативных вызовов; окончательная проверка использует exact root, полные transcript/DB/payloads и app-specific CDP. Непригодный foreground screenshot исключён из proof/manifest и не публикуется.

## Остаток и доказательства

G3-B4 сужен: current PM5 native Kilo/Cursor reads+reload закрыты; **G3-OPENCODE-PROVIDER-QUOTA** открыт. Остальная client/platform/terminal/PM4/full lifecycle матрица и общая AC-39 остаются открытыми по [итоговой матрице](g3-completion-2026-10-23.md); B5 имеет отдельный [cost result](g3-cost-baseline-2026-10-24.md). Release population AC-36–38 и memory AC-44 остаётся обязательным до первого выпуска, этим прогоном не выполнено. G4 consumer/G5 не приняты.

[Машиночитаемый результат](g3-pm5-native-clients-2026-10-24.json) содержит session/tool IDs, executable SHA, actual payload summaries, blockers и hashed primary evidence. Raw root: `C:\Users\xment\.codex\worktrees\product-project-registry-g3\1c-agent-workflow\build\test-results\g3\native-pm5-clients-20261024`. Manifest: `b9901b815b7f16888bcd319089fde1ac8cc3f01e495711612e61491f2aaf1932`, 486 files; поздние delivery/validation records хранятся отдельно. Source OpenSpec validation и RegisterChange фиксируются после seal, не подменяют native acceptance.
