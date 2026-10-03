# Карта решений, смыслов и проверок миграции

**Обновление 2026-09-29:** пользователь перенёс внешний OpenSpec store и D7
store-write owner в отдельный change `add-external-openspec-store` и чат.
Строки ниже с историческими Q10.1/Q11/Q12 сохранены для provenance, но
текущий релиз реализует только локальный OpenSpec; внешний выбор должен явно
останавливаться до записи. Требования OS1–OS3 и их приёмка относятся к
отложенному change.

## Что эта карта доказывает

Это завершённая классификация входов для постановки, а не доказательство
реализации. `path-inventory.json` содержит 459 уникальных путей, включая все
197 записей прежнего ledger: 196 downstream изменений, 379 upstream изменений,
116 пересечений. Путь не равен требованию: один файл может потреблять несколько
инвариантов. `previousLedgerRequirement` сохраняет исходную классификацию;
`plannedTreatment` указывает способ обработки, а не окончательный Git diff.

Базовые свидетельства:

- [Старый upstream](https://github.com/comol/ai_rules_1c/tree/410951e74fd3e6b7a763cf49757935b9a34d3f31).
- [Проверенный r36](https://github.com/xmentosx/itl_ai_rules_1c/tree/451c5a52e5b614c67406445d4af4b636da043aec),
  его `docs/DOWNSTREAM-PATCHES.md`, actual code и regression tests.
- [Целевой upstream](https://github.com/comol/ai_rules_1c/tree/20a083e5bd9fa41402ad8428b740c4c01f0cc3d6).
- [Опубликованный workflow master — главный installed baseline](https://github.com/xmentosx/1c-agent-workflow/tree/69c0863bfe3bd837543267f122e81a28dcfa5488):
  rules `itl-main-410951e7-r33` / `9309bfbbc9f8d844a21bce55178c2e0d72eaf965`.
  Remote/lock проверены 2026-09-28; r36 — baseline сохранения доработок и отдельной
  дополнительной приёмки, а не замена реального upgrade с опубликованного пакета.
- [Текущий path ledger](../../../templates/ai-rules-overlay/sections.json),
  [host ownership/transition](../../../docs/ai-rules-fork-upgrades.md),
  [действующий установленный overlay](../../../templates/USER-RULES.append.md).

Inventory воспроизводится shared `scripts/git-path-list.ps1` через
`Get-RepositoryGitPathList` с `diff --no-renames --name-only -z` для old→fork и
old→new; к объединению добавляются все `pathDecisions.path`. Числа и distinct
paths сверяются перед созданием нового release ledger. Итоговые upstream/baseline/
result SHA-256 рассчитывает реконструктор после реализации. Изменение intake
требует incremental re-audit, а не сохранения этих чисел как вечной константы.

## Принятые решения Q1–Q21

| Решение | Зафиксированный результат | Где реализуется / приёмка |
|---|---|---|
| Q1 | Отдельный test-plan не обязателен; существующий сохраняется | D3/D6; EV2, OS5 |
| Q2 | Типовая depth matrix, closing snapshot, standalone syntax, logic-only preference, bounded adjudication | D4; EV1 |
| Q3 | Текущее доказательство, сохранение теста и cadence независимы | D3; EV2/EV3 |
| Q4 | auto/full, session level, one-time on→auto, сохранить наши вызовы Caveman | D11; IM2/IM3 |
| Q5 | Достаточное one-off proof даёт обычную готовность, включая block | D3; EV2/EV7 |
| Q6 | Агент решает retention по риску/ценности, без отдельного одобрения для каждого опасного дефекта | D3; EV2 |
| Q7 | Дорогая регрессия по затронутым inputs/значимой передаче | D3; EV2/EV3 |
| Q8а–в | Authoring отдельно; named one-off отдельно; interactive UI отдельно от saved Vanessa | D4; EV4/EV5 |
| Q9 | MCP standards upstream с реальной квалификацией; local ITL additions сохраняются | D1/D12; SM7/RQ2 |
| Q10.1 | Первоначально: external OpenSpec сейчас; решением 2026-09-29 перенесён на потом | Отдельный `add-external-openspec-store`; OS1–OS3 |
| Q10.2 | Совместимые CLI/bundle, отдельное владение | D6; OS4 |
| Q10.3 | Новые memory providers — отдельная задача; действующая изоляция сохраняется | SM7, раздел исключений proposal |
| Q10.4 | YAxUnit/Vanessa приоритетны; новый Playwright contour автоматически не добавляется | D4/D5; EV4–EV6 |
| Q10.5 | Новый test-fix-loop через одного ITL owner/budget, transient proof допустим | D5; EV6/EV7 |
| Q11 | Local default для старых и новых проектов сейчас; внешний выбор доступен после отдельной задачи | D6/D7; OS0 сейчас, OS1 позже |
| Q12 | External docs независимы от branch lifecycle; изменения согласуются перед записью | Отдельный change; OS2/OS3 |
| Q13 | Bounded read-only queries/pure BSL в текущей test IB; ROCTUP эквивалентность доказывается | D4; EV5 |
| Q14 | Установленные OpenSpec routes и source pilot обновляются с разделением области | D6; OS5 |
| Q15 | Новый root, перенос всех действующих смысловых добавок | D1; SM1/SM2 |
| Q16 | Явный reviewer model и фактическое применение; parent fallback | D4/D9; SM3/CL2/CL4 |
| Q17 | error-fixer coding; bounded defect-class и один writing owner | D1/D4; SM3/SM5 |
| Q18 | Optional plugin controlled fork через ITL; отдельный version lifecycle | D10; PL1–PL3 |
| Q19 | Несколько установленных клиентов и отдельный session client | D8; CL1/CL3 |
| Q20 | Десять текущих + ZCode/MiMo; other не полноценный ITL-клиент | D9; CL2/CL4 |
| Q21.1 | Update основного проекта обновляет workflow доступных веток без merge бизнес-конфигурации, DB load и автотестов; deferred продолжается повтором update, refresh не обязателен | D3/D11; EV3, IM1/IM2 |
| Q21.2 | Работающий процесс откладывает update; остановленные pending/failed операции получают обычную новую версию и продолжаются/восстанавливаются у прежнего owner; отдельный hotfix механизм не добавляется | D11; IM6 |

## Закрытие замечаний полного ревью в постановке

Ни одна строка ниже не означает выполненную реализацию или live-приёмку.
Q21 заменяет прежний запрет обновления рабочих веток до refresh; остальные
уточнения конкретизируют уже согласованные границы без нового продуктового выбора.

| Замечание | Принятое уточнение | Требования / задачи |
|---|---|---|
| P1 Snapshot начинается поздно и заканчивается до post-copy | Одна root-транзакция pre-copy → новый процесс → rules/clients → commit → terminal; partial rollout по roots | D11; IM1; 5.1, 9.1 |
| P1 Execution-guard cutover обновляет часть веток вне обычной миграции | Q21: полноценный файловый update всех доступных roots у одного owner; guard transition — его этап | D11; IM2/IM6; 9.3, 9.5, 9.6 |
| P1 Resume зависит от движущегося master | Входы операции закреплены независимо от нового helper; ignored files из exact fork/client/render, main только проверенный cache | D11; IM6; 9.7 |
| P1 Gate 6 не включён в ITL apply | Условная platform ladder и три сигнала внутри существующего load/check/apply, с recovery | D4; EV8; 3.6, 10.2, 10.4 |
| P1 Малую правку блокируют старые замечания всей CF | Полная matching MCP coverage сохраняет условность; подтверждённые неизменные outside-scope findings получают non-clean assessment, строгие новые ошибки остаются блокирующими | D13; EV8a/EV8b; 13.1–13.3 |
| P1 Условный load может применить устаревший proof, а rollback теряет прежнюю identity | Существующий snapshot/split-load owner повторно сверяет proof до apply и возвращает прежний Designer proof только после подтверждённого exact rollback/cursor restore | D13; EV8a/EV8b; 13.2/13.3 |
| P2 Истечение one-off permission обесценивает proof | Authorization provenance отдельно от достаточности; обычный check/export переиспользует proof при persistent off | D3/D4; EV3/EV4; 4.2, 4.4 |
| P2 CLI mutations обходят store-write owner | Внешний store не включён в текущий релиз; staging/batch/journal и native archive остаются обязательными до его будущего включения | `add-external-openspec-store`; OS3 |
| P2 Приёмка ограничена r36 | Главный baseline — реальный published master/r33 со старым helper; r36 и legacy classes дополнительно | Context/D12; RQ1; 9.4, 10.4 |

Дополнение Q21 к verification: весь dependency-lock больше не является единым
основанием сброса proof; учитываются релевантные входы, без автоматического запуска
тестов в update (EV3, задача 4.2). Сохранённая доработка metadata `Template` /
`IntegrationService` остаётся SM5 и задачами 3.3/3.4. MCP standards Q9 — отдельное
свидетельство SM7/RQ2; оно не заменяет эти validators и не создаёт новую задачу
по переделке metadata Templates или MCP templates.

## Все 22 группы старого path ledger

«Сохранить» ниже означает сохранить поведение. Это не приказ механически
назначить `carry-forward` старому файлу. Число путей относится к прежнему ledger.
Повторяющаяся обязанность получает одного владельца; остальные файлы ссылаются
на него. Сценарии с ID определены в `specs/*/spec.md`.

| Группа / путей | Было → решение | Новый owner и обязательные потребители | Доказательство переноса |
|---|---|---|---|
| ITL-ADAPTER-001 / 4 | Single-client ten → adapt multi-client twelve; other не включать | fork adapters + host registry, doctor, model renderer, plugin/add/remove | CL1–CL4; свежий host context, layout/MCP/rollback |
| ITL-AI-REVIEW-EVIDENCE-001 / 2 | Сохранить raw evidence, exact unit, one bounded recovery, adjudication | verification-ai-evidence; mcp-policy, 1c-validate, subagent-core, test/OpenSpec/final-review consumers | EV1/EV3; ValidatorExecutionPolicy regressions; unresolved/accepted-risk не clean |
| ITL-CAVEMAN-001 / 3 | Удалить persistent level/persist; принять auto/full | upstream command/skill; host runtime profile + migration receipt; все wrappers и шесть phases | IM3; session override, on/off/auto, rollback/repeat, exact userReport |
| ITL-CODECHECKER-LATENCY-001 / 32 | Удалить always-three; сохранить closing snapshot, syntax, logic preference | upstream verification-policy → adapted verification-gates/1c-validate; agents/subagent-core/models/evolve | EV1; quick/full × lite/standard/full; bad-response budget и actual checker tools |
| ITL-CODEX-001 / 1 | Сохранить project-local skills; адаптировать новый bundle | codex adapter + host renderer; OpenSpec remap/plugin/aliases | CL4/OS5; no new global prompts, old globals сохранены, no duplicate skills |
| ITL-DOCTOR-001 / 1 | Read-only, script-owned; обновить устаревшие client assumptions | host doctor; fork thin command | PL3/CL2/OS4; configured/exposed/callable отдельно; no install/repair side effects |
| ITL-ECONOMY-001 / 1 | Orchestration/tier semantics сохраняются; single-client model routing адаптируется | host client-aware model settings; pinned fork rerender/routine agents | SM3/CL2; смена orchestration не ослабляет gates; другой клиент не теряет модель |
| ITL-FORM-COMMAND-ADVISORY-001 / 4 | Сохранить absent/empty/whitespace Action как advisory | form validator + forms rule; host warning propagation; все реализованные runtimes | SM5; пустой Action не требует dummy handler; structural errors сохраняются |
| ITL-GRILLING-001 / 22 | Сохранить четыре skills, formats, attribution, frontier, явный выбор | fork family/host source invocation; 12 adapters/plugin discovery | SM3/OS5/CL4; docs не запускают implementation; source-only не managed-copy |
| ITL-INFRA-001 / 31 | Сохранить immutable provenance и историю; расширить qualification inputs | fork check/publish + host PublishDevelop finalizer | SM1/RQ1–RQ3; exact hashes/tree, pending lock, no direct publication |
| ITL-INSTALL-001 / 1 | Сохранить plan/hash/idempotence/preservation, заменить single-client ownership | fork unified renderer + host migration/snapshot | CL3/IM1/IM5; два updates byte-identical; genuine modified preserved; failed second client rollback |
| ITL-LIFECYCLE-DB-001 / 18 | Сохранить guarded base/web scope; расширить на repo/Python/EDT/plugin; descriptor fixes отдельно | existing host lifecycle/guard; fork bridge. form-add/add-template → metadata owner | SM4/SM5/IM4; detached branch; source locks; compatible descriptor completion |
| ITL-MANAGED-FORM-CONTEXT-001 / 2 | Сохранить runtime boundary checks локально, не полагаться на MCP standard | локальное ITL rule + forms/debug routing; operation skills/subagents | SM5/SM7; UI entry→client/server transitions, types/serialization, focused runtime proof |
| ITL-MANAGED-FORM-ROW-GUARD-001 / 5 | Сохранить три состояния absent/false/true row set/order | form DSL/compiler/editor/scaffold и реализованные Python equivalents | SM5; false сохраняется, отсутствие не false; handlers не заменяют свойства |
| ITL-MCP-002 / 4 | Сохранить delegated owner и branch delta; принять новые provider policies | host MCP config + fork mcp-policy/search/operation skills | SM7/EV5; actual local delta, required/off rules, no alias bypass, no installer config mutation |
| ITL-MEMORY-001 / 2 | Сохранить local project corrections и shared-memory границу | project memory rule + host overlay, memory operation skill/subagents | SM7; project facts не в shared remember; templatesearch остаётся доступным; providers deferred |
| ITL-METADATA-001 / 1 | Сохранить safety; убрать поглощённое повторение structural routing | новый metadata skill + точные host owner clauses | SM5/SM6; tool route, vendor-support refusal, preview dirty/concurrency/recovery |
| ITL-METADATA-VALIDATOR-001 / 4 | Сохранить IncludePathList/UUID definitions и descriptors; не раздувать scope | reusable fork validator + host aggregate validator | SM5; UTF-8 contained explicit delta/no silent full scan; Form/Template/IntegrationService; payload/path у aggregate |
| ITL-OPENSPEC-001 / 51 | Сменить 1.2.0 на 1.13.1, four на six phases; убрать mandatory test-plan/off→no-author | fork bundle/overlay; pinned CLI; host evidence/source pilot | OS0/OS4/OS5/EV2 сейчас; OS1–OS3 отдельно; local context, existing plans, external refusal, archive proof, style integrity |
| ITL-RETRY-001 / 3 | Сохранить update/dump bridges, убрать возможность второго retry owner | host lifecycle/update owner; fork thin commands | SM4/EV6; exact branch, known-PID recovery, unchanged retry forbidden, logs retained |
| ITL-UPSTREAM-ANCHORS-001 / 4 | Новый root вместо старого; старые искусственные anchors убрать после ремонта ссылок | upstream root/index/mcp-policy + routed ITL rule | SM1–SM3; planning/execution независимы; нового root достаточно; корректные extension semantics take upstream |
| ITL-VERIFY-001 / 1 | Адаптировать suite-only readiness/partial blanket в obligation evidence | host verification/evidence/repair; deploy/test-fix routes | EV2–EV7; one-off block export, no fake pass, one budget, parent full-cycle review |

Семантическая сверка прежних изменённых путей выявила три случая, которые
совпадением SHA не закрывались: новый `memory.md` без оговорки управляемого ITL
проекта и прямые роли/команды со старым маршрутом Gate 2 через
`check_1c_code`, а также `/test-fix-loop`, который останавливался без уже
существующего `.feature` вопреки принятому transient-пути. Первый уточнён в
placed-once root-файле; второй согласован с единым `verification-policy.md` в
одиннадцати потребителях. Третий теперь направляет минимальный временный
исполняемый сценарий через тот же persisted ITL owner и отдельно требует
one-off receipt при соответствующей обязанности. Регрессии `WorkflowHardening`,
`ValidatorExecutionPolicy` и `ToolingReadiness` проверяют эти границы; ledger
классифицирует изменённые результаты как `resolved`, сохраняя прежние причины.

## Подинварианты функционального реестра

| Прежний ID / скрытое поведение | Решение и место |
|---|---|
| INFRA-002 / INFRA-003 | Immutable source/ref и atomic component refs сохраняются у существующего finalizer. Fork origin/main fast-forward до audited upstream выполняется тем же atomic push, что immutable release branch/tag; remote ancestry preflight сохраняется. Никаких старых manual push шагов |
| INSTALL-ENTRY-001 | Clean generated CLAUDE.md/entry не теряет ownership при update, не становится ложным userModified |
| INSTALL-REMOVE-001 | Kilo cleanup различает .kilo и legacy .kilocode; пользовательские/RTK rules не удаляются |
| INSTALL-DEVENV-001 | Full/scoped removal сохраняет .dev.env bytes и пользовательскую принадлежность, backfill metadata не стирает drift |
| CLAUDE-MIGRATION-001 | On-demand rules остаются rules-1c; clean legacy copies мигрируют, modified legacy сохраняются с отчётом |
| MANIFEST-001 | Старое «ровно один» удаляется по Q19; desired/actual sets и multi-owner result заменяют его |
| ADAPTER-002 | Native layouts и client-specific MCP сохраняются с реальной capability qualification |
| KILO-001 | USER-RULES injection, native paths и collision .kilo/kilo.jsonc сохраняются |
| LAYOUT-OLD-001 | Не возвращать общий старый Codex/Kilo layout; чужие legacy files не очищать |
| CODEX-OPSX-001 | Canonical OpenSpec skills/discovery сохраняются; «ровно четыре aliases» заменяется six-phase coverage без дублей |
| CONTEXT-001 | Compact mandatory ownership + on-demand details; не сохранять старый root ради прежнего размера |
| QUICKFIX-001 | Лимит/eligibility и independent execution/planning; новая gate matrix вместо blanket-three |
| COMMANDS-001 | Allowlist расширяется для принятых функций; запреты второго lifecycle/MCP owner сохраняются у dispatcher |
| EVOLVE-001 | Явный запуск, per-entry approval, USER precedence, реальные актуальные ITL invariants |
| FORM-ROUTING-001 | Новое operation-based правило уже запрещает structural hand-edit; убрать только доказанно поглощённый дубль |
| Compatible Form/Template descriptor completion | Отдельная наработка внутри LIFECYCLE-DB: exact Name/TemplateType, прежний UUID, synonym update, payload preservation; несовместимое отвергается |

Последний пункт подтверждён сравнением actual form-add/add-template: в r36
достройка совместимого descriptor допускается, в новом upstream существующий
descriptor снова приводит к отказу. Поэтому это реальный перенос исправления,
а не общий текст «сохранить metadata safety».

## Новые поверхности upstream и disposition

| Поверхность | Принять / адаптировать / ограничить | Закрываемый риск |
|---|---|---|
| mcp-policy, typed responses, per-operation skills, subagent-core | Принять структуру; подключить ITL evidence/search/memory/ownership | Новый путь не обходит старую смысловую гарантию |
| 1c-validate и model-gpt6 | Принять с effective gates/checker/permissions; model profile не ослабляет contracts | Независимая старая цепочка из skill и ошибочная модель по клиенту |
| repository-manage/repo-ops | Standalone принять; managed scope dispatch/refusal | REPOSITORY_PATH source ошибочно привязывает branch |
| Python metadata/web tools, help/interface/support tooling | Принять applicable tools с parity и guard; external prerequisites on demand | Потеря fixes или обход ITL через другой runtime |
| write-then-rollback preview | Адаптировать write-set/rollback к SM6 | Dirty/concurrent data loss; preview request превращается в apply |
| business/UI test skills и test-fix-loop | Принять optional authoring; ITL runner/budget/evidence, без default Playwright contour | Nested retries и ложная полная готовность |
| OpenSpec update/sync, external stores | Шесть фаз принять сейчас только для local root; внешний store явно остановить до отдельного релиза | Wrong root и прямой внешний write из bundle |
| marketplace/plugin manifests/hooks | Optional controlled dispatcher | Floating HEAD, второй MCP writer, silent hook failure |
| ZCode/MiMo и обновлённые tools/permissions | Добавить registry/renderer/capability qualification | Файлы есть, но host не видит tools/model/role |
| install recovery / first source dump / installtools | Managed scope у ITL; standalone semantics сохраняются | Второй recovery/export/install owner |
| Новый handoff/resume | Принять continuation и source verification, сохранять прежнюю авторизацию и заданный scope | Handoff теряет store/client/proof context или запускает новую область |
| Новые memory/provider setup routes | Контент остаётся у upstream; managed auto-activation ограничена существующей isolation, реализация providers отдельно | Неявное вынесение project facts в общий сервис |
| DOCX/transcription/OfficeCLI и прочие optional integrations | Принять исходники/зависимости/attribution; запуск по явной релевантной задаче, без обязательной установки в каждый проект | Рост обязательного runtime/контекста и исчезновение regressions |
| Scheduled MCP refresh и support feedback | Принять только owner-aware маршруты, без auto scheduling/отправки данных от одного upgrade | Установка rules не разрешает новый background job или отправку project data |
| CI/tests/eval renderer | Включить применимые проверки в authoritative qualification inventory | Старый Full зелёный, новые behavior checks не запускались |

## Клиентская матрица реализации и приёмки

Колонка «проверить» — обязательство будущей реализации, не уже полученный passed.
Точные runtime version/build и actual host evidence заполняются при qualification.

| Клиент | Сохраняем / принимаем | OpenSpec / plugin channel | Проверить |
|---|---|---|---|
| Codex | Project .agents/skills, TOML agents, MCP config, actual model | native six phases; plugin skills, hook не обещан | discovery/new context, no global prompts, no duplicate aliases |
| Kilo | .kilo native paths, routine-agent, config collision guard, exact helper output | native; CLI plugin отдельно от editor | CLI/editor discovery, RTK config preservation, no old .kilocode regression |
| Claude | rules-1c, new tool denylist/MCP inheritance | native; SessionStart plugin hook | read-only capabilities, model, shared .mcp.json/skills |
| Cursor | readonly flag вместо abstract tools; private MCP enablement diagnostic | native; session/workspace hooks | actual enablement/call, removing canonical layout, model |
| OpenCode | Native workspace/plugin/handoff, singular command/agent dirs, permission format | native; event plugin | совместимость двух plugins, SDK/runtime identity, shared skills |
| Kimi | Project skills/MCP; current fallback роли до native proof; new runtime permissions | natural; upstream wrapper channel отсутствует | model override unsupported не включает reviewer; tools actually exposed |
| Qwen | Host tool-name denylist и HTTP MCP layout | natural; обычный adapter | MCP/shell, command and role discovery |
| Command Code | Explicit tools=* плюс denylist, shared .mcp.json | natural; обычный adapter | executable/commands, shared key ownership, model |
| Cline | Project MCP в поддерживающем runtime; роли reference-only до native proof | natural; обычный adapter | CLI/editor variant и реальный config discovery; no silent global write |
| Pi | Pinned MCP extension 1.5.0/integrity, Node>=22, project trust, prompts | natural; обычный adapter | extension loads actual scoped MCP; parent role fallback |
| ZCode | Новый layout, mcp.servers deep merge, tool denylist | natural; обычный adapter | foreign settings/server name collisions, model, doctor, rollback |
| MiMo | Новый layout, permission/MCP merge, jsonc precedence | natural; обычный adapter | effective config, foreign keys, tools/model, rollback |

`other` остаётся за пределами supported ITL clients. Адреса глобальных legacy
файлов и их содержимое сохраняются; root/tool count не является live readiness.

## Новые замечания ревью: точное закрытие

| Замечание | Решение design | Приёмка |
|---|---|---|
| Repository source/current mismatch | D2: binding из lifecycle state, source settings сохраняются | SM4 |
| Freshness one-off proof | D3: obligation + input/requirement/base identity | EV3/EV7 |
| TOOL flags и NOT_READY recovery | D4: invocation policy, qualified ROCTUP, no implied mutation | EV4/EV5 |
| 3×5 loops | D5: один persisted session и remaining budget | EV6 |
| Разные changes пишут один внешний main spec | Отложенный D7: path write-set, hashes и scoped operation | `add-external-openspec-store`, OS3 |
| CLI coexistence/rollback | D6: exact side-by-side component, no global PATH rewrite | OS4 |
| Preview/web mutations | D2: owner/guard/write-set preservation | SM4/SM6 |
| New 1c-validate routes | D1/D4: новый consumer той же effective policy | EV1 |
| Parent full-cycle review | D4: обязателен отдельно от reviewer gate | SM3 |
| User overrides | D1: conflict report с приоритетом и dependent continuation | SM2 |
| Plugin floating source/hidden failure | D10: pinned helper dispatch, read-only ensure, visible errors | PL1–PL3 |
| Multiple clients/shared files | D8: whole set plan, physical ownership, rerender all references | CL1/CL3 |
| Snapshot забывает ownership files | D11: client-surface и mcp/client-managed в write-set snapshot | IM1 |
| Caveman across projects | D11: конечный root/worktree inventory и per-scope receipt | IM2/IM3 |
| Propose discards prior authority | D1/SM3: planning-only сохраняет stop, explicit combined request сохраняет scope | SM3/OS5 |
| Agent repair/first dump bypass | D2/D11: existing bootstrap/recovery owner | IM4 |
| Qualification omits tools/tests | D12: полный применимый inventory и точные reuse inputs | RQ1/RQ2 |
| Crash оставляет вечный lock внешнего store | Отложенный D7: OS/file-handle lease и journal recovery | `add-external-openspec-store`, OS3 crash scenario |
| Внешняя delta меняется между sync и archive | Отложенный D7: защищённая revision и состав change tree | `add-external-openspec-store`, OS3 delta drift scenario |
| Node незаметно меняется через PATH | D6: absolute Node + JS entrypoint, version/hash qualification | OS4 PATH scenario |
| Дорогой functional test ошибочно превращён в benchmark | D3: purpose отдельно от cadence, промежуточный proof и due handoff | EV2 expensive retained coverage |
| Loop меняет ожидаемый результат ради pass | D5: evidence и подтверждение изменения бизнес-ожидания, отдельно от исправления fixture | EV6 expectation scenario |
| Rollback стирает позднейшие user settings | D11: expected post-state и scoped reconciliation для env/MCP/ownership | IM1 post-migration edit |
| Session client отсутствует в installed set | D8: идентификация не attach; общие операции доступны, client action даёт continuation | CL1 Claude-only project |
| Новая ветка повторно сбрасывает намеренное on | D11: eligibility по provenance/version, новые scopes наследуют policy receipt | IM3 inherited on |

## Итоговый release ledger

Schema-3 ledger построен из зафиксированных `oldUpstream`, `baselineFork=r36` и
`targetUpstream`. Плановый inventory охватывал 459 путей из объединения
old→r36 и old→target; итоговая реконструкция охватывает 470 решений с новыми
путями, включая все прежние 197 entries. Каждая запись содержит `path`, один
первичный `requirementId`, disposition
`take-upstream|carry-forward|resolved|downstream-only` и проверяемую причину.
Связанные смысловые требования и потребители остаются в таблицах выше: один
первичный ID в ledger не отменяет их проверок.

`AGENTS.md` собран как точный новый upstream root плюс компактный `ITL-ROOT.md`
с disposition `resolved`. Все девять upstream `##`-разделов сопоставлены себе
с disposition `upstream-root`; прежняя полная замена root не возвращена.
`USER-RULES.md` и пересекающиеся runtime, adapter, OpenSpec и verification
файлы получили `resolved` после проверки соответствующих смысловых границ.
`carry-forward` сохранён для неизменённых downstream-owned файлов,
`take-upstream` — для принятых новых upstream файлов. Риски исполнения и
доказательства, которые SHA не устанавливает, остаются в unchecked задачах.

`sections.json` содержит реальные `upstreamSha256`, `baselineSha256` и
`resultSha256` из committed result; `Verify` сверяет их, линейное происхождение
и installed target bytes. Source dependency lock пока остаётся на r36 до
отдельной публикации и установки нового fork.

## Остаток доказательств

Часть переноса уже реализована и проверена в fork/host fixtures. Native client
execution, live MCP/1С, аварийное восстановление, публикация и миграция реальных
проектов остаются отдельными unchecked задачами. Точные границы fixture, local
canary и live acceptance указаны в `tasks.md` и файлах `evidence/`; один
прошедший hash/Full не подменяет ни один из этих результатов.
