# Итоговая матрица квалификации G3, 2026-10-20

**G3 / AC-39 остаётся открытым.** Это консолидация доказательств, а не новое условие приёмки или разрешение следующего этапа. Source проверок: `d94ab1392c27dcc4593b626b79c7f23e4ed3d6c9`, Windows PowerShell 5.1.26100.9711, Windows 11 Home build 26300, обычный токен без elevation. Только синтетические каталоги/локальные roots и read-only обращения к существующим Code/Graph. Gate 6, Cognee/G4, рабочие установки и публикация не запускались.

Канонические receipts, SHA и результаты этого среза — [JSON evidence](g3-final-qualification-2026-10-20.json). «Подтверждён subset» означает ровно указанную область; исходные source/native failures сохранены. Полная матрица требований остаётся в [test-plan](../test-plan.md), задачи — в [tasks](../tasks.md). Эта таблица не заменяет их checkbox и source-delivery ledger.

| Критерии | Подтверждённая граница | Остаток / следующий шаг у существующего владельца |
|---|---|---|
| AC-01–03, 05–07, 27–29, 35 | G2 reader/schema/resolver/publisher и consumer fixture квалифицированы; pure G2 завершён | Не приписывать этим fixtures live readiness, grants или installed migration |
| AC-04 | Source Git save/read-back/concurrency fixtures passed | Реальная публикация каталога не выполнялась и не требуется для повторения fixtures |
| AC-08 | Свежие 4 Code/Graph handshakes, 2 Code functional reads, Graph own/unknown/foreign controls; всего 12 controls passed | Полный selected host/server/config/namespace admission и точная версия источника не приняты. Pure resolver возвращает `unverified` и для правильной, и для ошибочной объявленной namespace; это не native admission |
| AC-09 | BookStack server-bound view/negative controls приняты в прежнем attested server subset | Не заменяет включение выбранного view в реальном клиентском контексте |
| AC-10 | СППР bounded metadata/read/exact links — прежние server/source subsets | Полный выбранный project consumer journey и выпускные реальные связи ещё не приняты |
| AC-11 | Mantis scope-before-cap/union/cursor regressions и прежний live subset passed | Search scope не является ACL и не доказывает write target |
| AC-12 | Purpose routing и сохранение writer operation ID подтверждены fixtures | Реальную запись Mantis не делали; не объявлять её приёмкой маршрутизации |
| AC-13, 22 | Source PM4/PM5 catalog-only выбор/необязательные defer; bounded PM5 upgrade доказан отдельно | Полные новые init и PM4 installed journeys, все реальные вопросы/подключения остаются открытыми |
| AC-14 | Source tracked/private/pending contracts и bounded PM5 binding/restore | Полный pending → опубликованная запись и native клиентский путь ещё не принят |
| AC-15, 23 | На текущем source обе family: unchanged/publisher/change/offline; custom entries сохранены, endpoint change достиг 12 client adapters | Это synthetic hook/file proof; реальная смена наследуемых MCP/scope/routes перед основной installed командой требует отдельной приёмки |
| AC-16 | Owner fault/receipt-gap/pinned resume/owned restore fixtures; новые 2 процесса сериализуются, диагностика доступна | Same-user no-op concurrency не закрывает native partial apply/cancel, race после ответа или terminal multi-user recovery |
| AC-17 | Native synthetic CLI пережил stalled origin, сохранил pinned snapshot и выполнил основную фазу; warm protected bytes неизменны | Первый CLI-вызов изменил 2 ignored receipts без client writes: исходный cold assertion failed сохранён, причина/допустимость ещё не установлена. No-cache/corrupt остаются в своих fixtures |
| AC-18 | Legacy/compatibility/branch rematerialization source subsets и PM5 late select/restore | Полный branch/init/managed downgrade installed journey не принят; прежний Gate 6 остановил PM5 путь |
| AC-19 | Windows 11 standard-user, Unicode paths, 2 native процесса одного пользователя | PM4 installed, Windows 10, Server 2019+ и независимые terminal users отсутствуют/не проверены; поддержку не сокращать |
| AC-20 | 48 чтений (2 family × 12 adapters × 2 roles) совпали с ожидаемыми URL; три router/managed-rule surfaces без прироста к G2 base | Actual tools/reload не доказаны. UTF-8 bytes/4 — proxy, не agent tokens; полного installed before/after context proof нет |
| AC-21 | Все bounded результаты и failures имеют отдельные receipts/области | **Конечный путь целиком не принят**; source tests/регистрация не заменяют его |
| AC-24 | Conflict/override/defer/cancel source fixtures passed | Полный native диалог/последующая исходная команда и межсессионная race приёмка ещё открыты |
| AC-25 | По 20 warm samples; один fetch/top-level, nested без второго, no-op/publisher/offline не переписывают clients. Stalled transport — 9.729 s fetch-to-pinned-verify, whole CLI 24.888 s | PM4 median/p95 **1.771/2.003 s**, PM5 **1.644/2.321 s** превышают цели 1/2 s. Нужны owner-local анализ и решение в прежнем checkpoint; это не новый runtime FAIL. Причинная связь с кодом и полный paired выигрыш не доказаны |
| AC-26 | Все 96 dispatcher actions и 8 непустых broker operations классифицированы; inherited broker не получает новый guard. Под нагрузкой другой сессии status завершился за 3.618 s | Codex в private home видит project config только после explicit trust. `mcp get` не доказывает actual tools; новый контекст/reload остальных клиентов ещё не принят |
| AC-30, 34 | G1/Q1–Q7 и D9 имеют прежний самостоятельный статус; G2 завершён. Registry-only PM5 memory off, новых provider calls нет | G4 запрещён текущим scope; Q и memory adapter/installed критерии не закрываются registry proof |
| AC-31–33 | G3-PROMPT, LEGACY-ENROLLMENT, LEGACY-CALLER-OFFER и RESTORE-FORMAT закрыты в ранее указанной native PM5 области | Полная PM4/PM5 choose/create/later/association/client/platform matrix не принята. Capsule replay с dependency resume не новый uninterrupted old-caller proof |
| AC-36–38 | Подтверждён только минимальный PM5 КОРП pilot | До первого выпуска обязательны перечень продуктов/проектов, настройки, карта функциональности и согласованный опубликованный SHA. Не начинались; это release condition, не prerequisite разработки G3/G4 |
| AC-39 | Checkpoint одобрен, G3.0–6 source реализован; G3.7 дал перечисленные subsets | **Не принят** до покрытия обязательных original journeys, source/client/platform/cost критериев; изолированные успехи не суммируются в полный pass |

## Стоимость и пределы новых наблюдений

На каждой family 23 observations: 20 unchanged и по одному publisher-only/change/offline. PM4: 4.207/9.337/4.829 s для трёх последних сценариев; PM5: 3.834/8.785/4.312 s. Это функции hook с реальным локальным Git и 12 файловыми adapters, не время всей 1С-команды и не оценка сетевой задержки production. В сравнении с историческим `d17f29da` изменились 13 runtime paths; новый замер не paired baseline и не доказывает источник замедления. Цели, deadline, asserts и workload не ослаблялись; в этом срезе runtime не правился.

Три проверенных always-on/router surfaces к `181e1da0` имеют delta 0 bytes. On-demand `references/mcp.md` имеет +662 UTF-8 bytes / +166 `ceil(bytes/4)` proxy в совокупной source базе; diff относится к уже принятой отдельной facade-recovery работе, не к новому правилу каталога. Эти выборочные размеры не выданы за полный расход контекста/точные токены. Локальные startup/client проверки не инициировали LLM/memory calls; внутренний usage/embedding Code search не измерялся и остаётся unknown. Новых tool schemas, координатора или runtime barrier нет.

## Сохранённые failures и ограничения стенда

- Первый cold CLI: exit 0/main reached/offline warning, но 2 receipt hashes изменились. Это **failed no-write control**, не общий pass по одному exit 0; последующий warm/concurrent успех его не закрывает.
- Первый source audit использовал direct helper под StrictMode без optional `binding`; corrected harness явно передал пустую binding. Исходный failure сохранён; публичному workflow дефект не приписан. Итоговая поверхность измерена по существующему `mcp.md`, не по отсутствующему reference.
- Deadline harness первоначально не инициализировал частный Git root: Git нашёл ancestor source repo, и config-команды затронули его local name/email/core.longpaths до failed add. Код/индекс не менялись. Name/email восстановлены к совпадающим global/последнему source commit; прежнее local `core.longpaths` неизвестно, `true` оставлено. Перед повтором exact test Git root проверен. Это ограничение сохранности local Git config, не «всё побайтно неизменно».
- Первый concurrent validator потерял exit codes из-за позднего получения process handle. Повтор удержал handles до wait, control `exit 7` дал 7; оба native clients exit 0. Второй validator посчитал 2 fetch в append-трассе двух разных запусков: предыдущий immutable файл является её точным byte prefix, новая часть содержит ровно 1 fetch. Отдельная reconciliation сохраняет оба failed harness records, все события, workload и assertion «один fetch на вызов»; runtime не переигрывался ради очистки трассы.
- Новая integrity проверка подтвердила 13 protected files/4 старых roots, 68 raw refs прошлого capsule proof, 2 восстановленных PM5 roots и 7 Gate 6 artifacts. Исходный raw seed всё ещё отсутствует; новый restored DB SHA в этой консолидации не перемерялся. Native data restore proof остаётся историческим, старый failed descriptor/diff не очищен.

## Остаток и порядок продолжения

1. У существующих source/client owners закрыть full binding admission и actual project tools/reload; private Codex trust discovery использовать только как объяснение прежнего отказа.
2. Разобрать over-target startup и cold receipt writes без ослабления no-op/deadline/whole-command требований; затем повторять только затронутые исходные проверки.
3. Продолжить original isolated installed init/association/branch/recovery/compatibility controls. Gate 6 остаётся явно отложенной PM5 product ошибкой; обходом/filtered gate его не закрывать. Исчезнувший live raw seed не заменять заявлением о currentness capsule.
4. Подготовить отсутствующие PM4/platform/terminal stands и пройти оставшиеся клетки. Отсутствие proof не означает отказ от поддержки.
5. Отдельно перед первым выпуском выполнить release population AC-36–38 и проверить доступность locked component через обычный delivery путь. Прежний HEAD 404 для этого клиента и exact-SHA source-build recovery не являются публикацией/Release proof компонента.

G1/Q1–Q7/D9/G2 не переоткрываются. Memory change потребляет эту же матрицу для своей installed зависимости AC-43/G5; AC-44 использует одно выпускное наполнение. G4, миграция рабочих проектов и публикация требуют отдельного разрешения и здесь не выполняются.
