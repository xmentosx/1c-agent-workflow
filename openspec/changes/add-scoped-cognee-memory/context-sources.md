# Context Sources

## Актуальные входы плана G4, 2026-10-25

[План G4](g4-implementation-plan.md) имеет приоритет для текущей готовности над
историческими baseline/readiness формулировками ниже. Source base
`568379a540e3504bcce1b65e94c853f1704154f7`; опубликованный registry snapshot
`0274a8ffb5a03ba7b856736c2b4a637ccbe98b73` содержит 44 области и 0 назначенных homes.
Qualified G2, принятый G3 и закрытый R6 подтверждены их существующими evidence.

Текущий lock прочитан на месте: `itl-main-2f640143-r47`, fork commit
`c91682404a498f356810b179ce8336711a411170`, upstream
`2f640143756ecd01fed42100e412632aa9082385`. Из точного Git объекта прочитан
`content/rules/project-memory.md` (blob `5fe9348da25fd364fb455bad96e3e97f0e78994e`);
root `memory.md` blob `dd3bbbd3896a7ca3e7ebc28a42806b782eb7593e`.
Managed boundary ещё исключает Cognee/OpenViking, templates wording конфликтует
с shared boundary `templates/USER-RULES.append.md`; это известная D7 адаптация
у fork owner, не разрешение патчить установленный ruleset.

Local qualification-result-r2.json этапа C существует, SHA-256
`be8219d1d090343f2d7deebace513b77d5aa7a322e353f10b9f3324d7048582d` совпал.
Q1–Q7 имеют passed для exact local profile; это не свежий live probe. Стенд,
runtime/API, assets/lock/fork, registry данные, datasets и grants не менялись.
Полный старый контекст и hashes ниже остаются evidence на дату первоначального
чтения, не актуальным fork pin и не доказательством текущего работающего сервера.

## Основание и границы проверки

Текущая source граница G3: registry Git/source contracts и client apply/recovery подключены к выбору проекта, bootstrap/startup, конфликтам, ordinary sync и fixture-only compatibility path по отдельному approval. Pure G2 home/read interface уже проверен; источник фактической G3 приёмки — соседний registry test-plan. Эти source/isolated client fixtures не квалифицируют память, весь installed G3 или активные MCP tools. G4/реальные installed migration не начаты. Таблица dependency hashes ниже обновлена по этой source постановке; G1/D9 evidence и budgets не меняются.

Постановка подготовлена 2026-10-18 и уточнена 2026-10-19 по решениям текущего чата: Cognee, шесть областей, отдельный реестр, OpenViking optional, максимум совместимости с ai_rules_1c, только проектирование. Семь уточнений отражены в AC-31–37; общий порядок/миграция и native допуск Q1–Q7 — в design/specs/tasks и AC-38–42. Основной критерий — стоимость правильно решённой задачи, а не размер одного ответа.

Planning checkout: `C:\Users\xment\.codex\worktrees\scoped-cognee-memory\1c-agent-workflow`, baseline HEAD `e9dc695d3b792179f10c35898ba02daebf0bb66c`. Исследованы перечисленные контракты, а не живые экземпляры памяти. Наличие конфигурации, схемы API или прошедшая проверка OpenSpec не доказывают live readiness.

## Локальные владельцы

| Источник | Проверенный факт / следствие |
|---|---|
| `AGENTS.md`, `docs/source-planning.md`, `openspec/config.yaml` | Это source repository; OpenSpec здесь — постановка. Код, сервисы и gates не изменяются данным запросом. |
| `docs/package-architecture.md`, ownership и architecture checkpoint | ITL владеет lifecycle и MCP config; общие agent rules принадлежат controlled fork. Новый binding/persistent scope требует рассмотрения границы перед apply. |
| `templates/dependency-lock.json` baseline | Controlled fork `itl-main-5700f54-r43`, commit `987320be139b4ac0d28f1f5b0f2515f63c7f140f`, upstream `5700f54a899abb1e8b6483badd6986e5a0e6c1af`. Перед apply сверить действующий lock. |
| `templates/USER-RULES.append.md`, Shared Cross-Project Memory | templates memory общая, проектные факты туда запрещены; текущая ссылка для project corrections ведёт в root memory.md. При будущем qualified opt-in source overlay должен явно выбирать новый private fallback, сохранив legacy route. |
| `content/rules/project-memory.md` controlled fork, прочитан через `git show` точного commit | Managed boundary пока не активирует новые providers и ошибочно называет templates project-scoped. Для нового opt-in нужен согласованный owner-local binding; нельзя считать эту формулировку доказательством изоляции. |
| `.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1`, `Reset-DevBranch` | Reset хранит фазы/resume и может сохранить HEAD при восстановлении базы. Новое поколение памяти принадлежит этой операции. |
| `.agents/skills/1c-workflow/scripts/lib/agent-1c.vibecoding1c-mcp.ps1`, registry/selection/client writer | Есть владельцы discovery, личного выбора и управляемых client sections. Новая привязка использует их и сохраняет External MCP. |
| `tests/pester/McpConfig.Tests.ps1`, `BootstrapUpdate.Tests.ps1`, `DevBranchLifecycle.Tests.ps1`, `DevBranchWorktrees.Tests.ps1`, `AiRulesOverlay.Tests.ps1`, `AiRulesMigration.Tests.ps1` | Найдены owner suites для будущих точечных regressions; тесты при оформлении не запускались. |

## Зависимость от разработанного реестра

Авторитетная постановка — соседний change `add-product-project-registry` в этом source checkout; исходный чат `codex://threads/01a0f95e-46ff-7aa0-8593-0e4a55b2df5c`, основной planning mirror сохранён. Согласованная пара помещена вместе в commit `29501656`; первоначальный отдельный planning worktree памяти сохранён. Файлы ниже расположены относительно `openspec/changes/add-product-project-registry/`; hashes фиксируют прочитанное planning основание, не опубликованный runtime contract. Перед apply интерфейс/owners сверяются по смыслу и критериям, без автоматического принятия несовместимой зависимости.

| Файл | SHA-256 прочитанного основания |
|---|---|
| `proposal.md` | `eca1531cf6f17a6d611b598bf5ca5186307754affe67d57a71838aa165269a71` |
| `design.md` | `0772d69ec359dd9de20edc80d92b1a2206e428db163d1034793804ff677ad4bc` |
| `test-plan.md` | `cb8e7b60bd080ed65b199e224b1e41de2844aaf1a3a607466343762a56c8fe98` |
| `tasks.md` | `03c3dd464eb7495d053e5acf05376dd267cb07bf8c70fb45550050e08bd12f59` |
| `inventory.md` | `a216881d6eb43722a87d925a9ea40a419f9e668e6baa397fe88135b352bb9e27` |
| `specs/product-project-registry/spec.md` | `74a31ae7222f68c5a23847102cebbff913b6dd615652565352335680ca246e16` |
| `specs/product-knowledge-applicability/spec.md` | `80a8a59d585a52055b11832a4cabf22b166123e7dc8143c175d1c02885ddcdd1` |
| `specs/registry-source-binding/spec.md` | `f54af27e91f7788eabf9594713b7775ee17934d24c99380e67df3052b903c5ba` |
| `specs/registry-project-configuration/spec.md` | `e0dae8198af153806543d2ccc103b1016011c156e446915febc1b603f70cafbf` |

Основание обновлено 2026-10-19 после согласования общего порядка G0–G6 и миграции; таблица содержит текущие SHA-256 девяти прочитанных документов. Сохраняются отдельные catalog/catalog.json и catalog/product-relations.json, business IDs, optional profiles, отношения/knowledgeAreas, раздельные origin/applicability/evidence и три статуса. Новое/изменённое общее правило home подтверждает человек. Три проектные MCP-роли прежние, Cognee общий; один updater/pinned context, defer сохраняет valid current local на прежней catalog revision. Диагностика/recovery исключены из автоприменения.

**Согласованный интерфейс, pure G2 реализован и проверен:** registry-spec теперь задаёт optional `knowledgeAreas.<area>.memoryHomeProductId`, одну scalar product reference из availableIn/того же SHA, valid missing field и consumer home/read set с revision. AC-27–29 реестра сопоставлены с AC-20/32/35 памяти. Неоднозначное назначение остаётся узким candidate; смена home не означает перенос заметок или полноту поиска. Native dataset IDs/grants остаются у Cognee/binding, не в каталоге; нет четвёртой роли, второго resolver/updater, IAM/provisioning. Schema/resolver и подтверждённый minimal seed имеют source evidence G2; реальные homes, выпускное наполнение и installed/native qualification остаются отдельными зависимостями. Source G3 не объявляет memory consumer работающим.

## Уточнение границ D9/G2, 2026-10-19

Подготовлено предложение D9 по package architecture policy: один native-backed context-bound adapter у ITL MCP owner, settings/recovery у прежнего client owner, initial/reset cycle у lifecycle, compact continuation в user-local root, native storage/ACL/restore у Cognee/admin, общая policy только у controlled fork. Checkpoint подготовлен, но не одобрен; задачи 1.1/1.2 остаются открытыми. Отдельного approval manifest/координатора/restore epoch не вводится. Q1–Q7 этапа C квалифицируют exact native profile, а не разрешение кода или установленный Windows/terminal путь.

В registry design конкретизированы G2.1–5 и consumer handoff: действительные reader/resolver/publisher плюс fixtures AC-01–03/05–07/27–29/35; selected IDs/roles/links, applicability/home/read candidates, provenance/revision и отдельные settings/knowledge hashes. Документы и mock не закрывают interface; pure G2 не ждёт D9/Cognee и не пишет installed state. Git save/association/startup/reload относятся к G3. Memory G4 требует вместе квалифицированный interface, применимый G1 и отдельно одобренный D9/разрешение кода; G5 по-прежнему требует installed контекст и paired/native клиентский proof. Synthetic interface не утверждает реальные homes или grants. Девять hashes dependency выше обновлены после этой синхронизации.

Точки расширения проверены по локальным исходникам: основной checkout `c900620e6569ce4cec39e30abfa3f8ce2c150ce1`, memory worktree `e9dc695d3b792179f10c35898ba02daebf0bb66c`; registry lib reader/selection/client entrypoint, lifecycle branch state/New/Reset, host publisher и owner tests. Это разные старые bases: перед кодом нужен актуальный отдельный source base и повторная owner сверка. Fetch/merge/implementation сейчас отсутствуют. Upstream policy ниже не перечитывалась live: её согласованный frozen контракт сохранён, новые изменения fork не заявляются выполненными.

## Внешние первичные источники

Источники ниже прочитаны при первоначальной постановке; повторной live проверки upstream нет. Native profile/исходные результаты — этап B, последующая квалификация пересмотренных Q5/Q7 — этап C. Общий порядок сохраняет independent registry G2/G3 и native G1 до memory G4; installed G5 требует применённый registry context. Update/association/memory opt-in раздельны, later/unattended сохраняет legacy/off, initial cycle не требует reset, старые заметки не импортируются массово. Registry AC-30–34 сопоставлены с memory AC-38–42, граница interface/approval — registry AC-35 и memory AC-43.

| Источник, проверен 2026-10-18 | Что используется |
|---|---|
| [Upstream project-memory, точный SHA](https://github.com/comol/ai_rules_1c/blob/5700f54a899abb1e8b6483badd6986e5a0e6c1af/content/rules/project-memory.md) | Политика провайдеров, memory-only route, durable vs unconfirmed, локальный fallback; источник правил, а не доказательство установленной версии. |
| [Upstream provider calls](https://github.com/comol/ai_rules_1c/blob/5700f54a899abb1e8b6483badd6986e5a0e6c1af/content/skills/mcp-1c-tools/docs/memory-providers.md) | Native Cognee `remember`/`recall(CHUNKS)`; optional OpenViking; live descriptors определяют параметры. |
| [Cognee MCP tools](https://docs.cognee.ai/cognee-mcp/mcp-tools) | Owner-scoped lookup имён; для shared IDs нужен штатный SDK/REST. Документирован `self_improvement` с default true; false отключает improve, сохраняя ingestion/graph. Старые get_document/list_data MCP tools удалены: original/current-status по ID этим источником не доказан. |
| [Cognee MCP setup](https://docs.cognee.ai/cognee-mcp/mcp-local-setup) | Различие native MCP/direct/API deployment и backend identity; shared instance требует реального разделения доступа. |

Совместимость проверена по точному fork commit выше и его upstream policy. Сохраняются native argument names, correction-capture, один durable save, task/standing query budget, ambiguous-write handling и TOOL/Memory line. Планируемые managed отличия явно ограничены qualified binding/назначением, private pending fallback с read route и shared templates wording; они требуют будущего изменения у fork owner, а не установленной копии. Текстовая project метка из generic fallback не заменяет строгую dataset изоляцию этой постановки.

Рабочие данные, история чатов и реальные заметки в провайдеры не отправлялись. До зависимой реализации квалифицируются exact-ID shared read/write двумя пользователями, original/envelope/current-status/correction, retirement/restore и ingestion profile. Документация не доказывает эти возможности выбранной версии. Отдельный запрос 2026-10-19 разрешает native Q на тестовом экземпляре, но не memory implementation/production изменения; ссылки на latest не заменяют выбранный profile или functional proof.

## Предварительное обследование по запросу Q1–Q7

Run `cognee-q1-q7-20261019-a8bd3718`, 2026-10-19: пользователь подтвердил отсутствие созданного тестового экземпляра. В exposed tools нет native Cognee; local Python `3.13.13` доступен, пакет не установлен; Docker CLI `29.5.3` найден, local daemon pipe недоступен (exit 1), Ollama нет в PATH. Проверялась только presence отдельных provider environment variables, значения/секреты не выводились/не публиковались. Другие hosts/credential stores не объявляются обследованными.

Из [официальных PyPI metadata 1.6.5](https://pypi.org/pypi/cognee/1.6.5/json) скачан candidate wheel и проверен SHA-256 `aaef9fdc02f542b1d125cde21759dde2fac56355d8928e39c734e7b5c6705eca`. ZIP/AST чтение показывает raw data/permission/delete REST routes, без import/install/execution провайдера. [Installation](https://docs.cognee.ai/getting-started/installation) и [Permissions Setup](https://docs.cognee.ai/setup-configuration/permissions) просмотрены как setup guidance; они не дают live результатов Q. Candidate package не объявлен deployed version.

На этом первоначальном этапе A все Q были unverified/not_started; native операций — 0. B01/B03 означали отсутствие instance/profile; B02 относился только к неработающему локальному Docker daemon. Исторический preflight hash сохранён в test-plan.

**Этап B по последующему разрешению пользователя:** Docker deployment выбран на dev-karimov (`itl-mcp-karimov`, существующий SSH `dev-karimov-mcp`), отдельный loopback-only stand. Cognee 1.6.5 установлен из того же SHA-verified wheel без patches; image `sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`; live OpenAPI SHA `b863f72d912c07ceb4bb914d790152659427c0ad33863d553d38b5fa64e24171`. Models/versions/principals/grants/datasets и полный expected/actual — test-plan этап B. Native REST responses, raw originals, graph outputs, pipeline usage и stopped backup/restore являются фактическим основанием; опубликованная документация по-прежнему не подменяет их.

Исторический итог native проверки: Q1–Q4/Q6 passed; Q5 failed — старый restore вернул ACL/deleted fact/old original; Q7 flag/graph/counters частично подтверждены, полный accounting unverified. B01/setup B03 закрыты; B04/B05 выявили избыточные гарантии исходного контракта, не доказанный дефект Cognee. Семь прежних MCP containers сохранили IDs/images/StartedAt; после теста возвращено позднее test state (revoke403/delete404/current200), что не является automatic restore protection. Исходный qualification-result и его hashes не меняются.

После документального согласования Q5/Q7 пользователь поручил «иди по плану». Native этап C `cognee-q5-q7-r2-20261019T094637Z-b4127852` подтвердил admin restore admission и whole-run accounting: Q5/Q7 passed; image/schema/auth и model refs совпали, неизменные Q1–Q4/Q6 proof сохранены с явным reuse. G1 пройден для local profile; frozen baseline 37 notes/12 tasks/43 payload hashes подготовлен, evaluator answers отделены. Native CPU 46.486933 s, peak 3,368,210,432 bytes, wall 37.443 s; null internal usage остаётся unknown, экономия не заявлена. Tenantless ACL-list404 сохранён как optional limitation, права проверены фактическими allow/deny без создания tenant. Клиентские cache/new-chat/installed-task/paired части остаются G5. 1.4/1.6/1.7 закрыты только в предварительной области; 1.1/1.2/qualified G2/D9 открыты, G4 не начат. Семь прежних MCP containers сохранены; normal18190 работает, admin18191 закрыт. Implementation/provider/fork/production config/1C базы не менялись.

Sanitized evidence исторического этапа B: [qualification-result.json](C:/Users/xment/AppData/Local/Temp/cognee-q1-q7-20261019-a8bd3718/evidence/qualification-result.json), SHA-256 `ad2b8796e52fcef98e503f4775dd45277c35e63b03fc16f4d71744025d73971b`; [evidence-manifest.json](C:/Users/xment/AppData/Local/Temp/cognee-q1-q7-20261019-a8bd3718/evidence/evidence-manifest.json), SHA-256 `c4c95e623bf580a46b84c2ba161aeaa633cd4a5eb8a9179a3a035e4ba5f7c903`. Remote primary — `/home/mcp/itl-qual/cognee-q1-q7-20261019-a8bd3718/evidence/`. Credentials/env/native backups не экспортированы; one-off probes не являются workflow adapter. Тексты требований, ai_rules_1c policy и registry dependency hashes не изменены результатом native тестов.

Актуальный этап C: [qualification-result-r2.json](C:/Users/xment/AppData/Local/Temp/cognee-q5-q7-r2-20261019T094637Z-b4127852/evidence/qualification-result-r2.json), SHA `be8219d1d090343f2d7deebace513b77d5aa7a322e353f10b9f3324d7048582d`. Expected/actual, manifest 38 evidence files, frozen baseline manifest и durable remote paths — [test-plan.md](test-plan.md), этап C. Это дополнение не переписывает исходный failed proof; G1 квалифицирует только точный native local profile.

## Принятый D9 и фактический G2 handoff

2026-10-19 пользователь явно одобрил D9 и разрешил только G2, запретив G4/installed migration. Actual registry source base `181e1da00a08e56d2d0ac57d24a92e7187484e06`, отдельный worktree `C:/Users/xment/.codex/worktrees/product-project-registry-g2/1c-agent-workflow`. 42/42 focused Windows PowerShell 5.1/Pester tests квалифицировали reader/resolver/publisher/consumer contract. Registry test-plan владеет деталями; native Cognee proof не повторялся и не подменён fixtures. Пилот PM5 КОРП/типовой проект подтверждены, integrations deferred, общие areas/homes не придуманы. Задачи 1.1/1.2 закрыты только как dependency/checkpoint, код памяти и installed AC не начаты. Исторические статусы подготовки D9/G2 выше относятся к предыдущему этапу.

Registry source commit `59ad14c9`: G2 code/consumer proof сохранён в отдельном worktree, каталог не опубликован. Девять dependency hashes сверены с синхронизированной постановкой исходного checkout; регистрация/Targeted читаются отдельно из source-delivery Status. Это не запуск G4.

Текущий G2 candidate `b160d92c` заменяет незарегистрированный `59ad14c9`: первый Targeted выявил слишком широкую маршрутизацию новых test suites. Исправлены узкие coverage contracts у прежних владельцев, исходные independent component assertions сохранены; focused selection 18/18 passed. Runtime G2 не менялся после 42/42 PS5.1 proof. Failed proof не удалён; повторная регистрация учитывается source-delivery Status, до неё публикация/успех Targeted не заявляются. G4/installed migration по-прежнему не начаты.

Финальная dependency проверка: source-delivery Status подтвердил `product-project-registry-g2` registered, source head `b160d92c2bdfb53b586b9ee9e9a10903c571144d`; общий candidate `33a2557da42bc82151f6ea94675f150118102747` имеет passed Targeted (126733 ms), source worktree clean. Helper выполнил две попытки принятия при конкурентном изменении общей очереди; чужой зарегистрированный change сохранён. Авторитетный результат — shared ledger/Status, не новый gate или журнал в памяти. Каталог/пакет не опубликованы; G4 и installed migration не начаты. Девять dependency hashes сверены.

## Наполнение перед первым выпуском, 2026-10-19

По прямому поручению пользователя обе OpenSpec уточнены только документально: registry tasks 1.9–1.11/5.7 и AC-36–38 обязательны до первого выпуска каталога и памяти; memory task 6.6/AC-44 ссылается на тот же результат. Продукты/проекты, resolved MCP/СППР/Mantis и карта основной функциональности подтверждаются для выпускного набора на одном опубликованном Git SHA. Minimal seed G2 не заменяет наполнение. Optional home/осознанно отсутствующие необязательные связи допустимы; shared-memory сценарии требуют home и отдельного native grants/currentness proof. Нет bulk ingestion, второго реестра/updater, увеличения always-on context или нового runtime barrier. G3/G4, наполнение и миграция сейчас не начинаются.

Таблица девяти hashes выше сверена с актуальными registry planning files после этого уточнения; копия в основном checkout совпадает. Согласованная пара OpenSpec сохраняется вместе в source worktree product-project-registry-g2 для одного документального commit/RegisterChange; исходный planning worktree памяти сохранён. Это не меняет native profile, прежние результаты, G2 implementation или отдельные границы публикации/первого memory opt-in.

## Checkpoint и план G3, 2026-10-19

В registry design подготовлены отдельный installed-state checkpoint и G3.0–7 с owners, sequencing, continuation/recovery, compatibility, source/installed evidence и выпускным наполнением. Локальные source points повторно проверены на HEAD 29501656; новые runtime возможности и live readiness не заявлены. Registry AC-39 связывает план с original-task canary, bounded waiting/context и managed downgrade; 10 s metadata startup не распространяется на memory budgets. Checkpoint пока не одобрен, G3/G4 и миграция не начинаются, D9 approval не заменяет G3. Наполнение AC-36–38/здесь AC-44 по-прежнему обязательно до первого выпуска обеих функций, отдельный source/installed/data результат не подменяет другие. Девять hashes основания обновлены после согласования документов; qualification profile и prior native evidence не менялись.


## Разрешённый source G3 apply

Checkpoint G3 одобрен прямым сообщением пользователя и source G3 разрешён; G4 и миграция действующих установок отложены. G3.1 authoring и G3.2 server scopes имеют отдельный source proof в registry tasks; это не client activation, native Linux deployment, весь AC-39 или memory readiness. Исходный native G1 profile/семь выполненных memory задач не изменены, consumer/runtime G4 не реализуется.
