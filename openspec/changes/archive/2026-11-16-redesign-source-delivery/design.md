# Design

## Context

Мотивация и требования: [proposal](proposal.md), [specs](specs), порядок исполнения:
[tasks](tasks.md). Исходное состояние после публикации: [baseline](evidence/baseline.md).
Данный change начинается от `fa0e3c91`; общая очередь пуста. План, составленный
на `c900620e`, сохранён с историческими измерениями и не считается текущей приёмкой.

## Goals / Non-Goals

Основная единица готовности — проверенный интегрированный кандидат. Регистрация
остаётся ограниченной проверкой его дельты, а квалификация выпуска привязывается
к зафиксированному installable-составу. Изоляция окружений и ресурсов позволяет
независимым задачам проверяться одновременно.

Не вводятся служба, elevation, второй coordinator/ledger, новый общий кэш,
автоматическая правка пользовательских конфигураций или отказ от серверной
поддержки. Согласованный roadmap не разрешает ослаблять тесты или заменять
наблюдавшийся reproducer более удобным сценарием.

## Decisions

### A. Доказанная гранулярность тестов

Источник инвентаря — NUL-delimited tracked Git paths через существующий helper,
а не только `rg --files`: ignored patterns могут скрывать уже tracked тесты.
Одноразовый [audit-test-inventory.ps1](evidence/audit-test-inventory.ps1) извлекает
определения и кандидаты на review, не запускает тесты и не назначает им
автоматически статус ненужных. Raw отчёты пишутся в ignored `build`;
окончательные решения и необходимые source-only таблицы сохраняются в change.

Группировать тесты по защищаемому поведению, исполняемому компоненту и среде.
Разделение файла допустимо только вместе с доказанными входами и маршрутом
исполнения каждого перенесённого кейса. Сохранять тестовые идентичности и
контрактные негативные проверки; перенос не является разрешением удаления.

Каталог остаётся единственным владельцем selection/reuse зависимостей; runner
исполняет полученный набор. Выбор и fingerprint не дублировать в новом
манифесте. TestSupport не должен без необходимости загружать всё окружение для
статической проверки одного документа. Обязательные реальные process/time
границы сохраняются, но выбираются только по их зависимостям.

Альтернативы: увеличение worker count не устраняет serial critical path;
понижение assertions или случайное исключение файлов создаёт ложную готовность.
Полный fallback для неизвестных зависимостей не вводится: действует текущий
контракт владельца. Ускорение измеряется с подготовкой и повтором, а не числом
удалённых тестов.

### B. Принадлежащие фазе окружения и транспорт

Каждый native boundary устанавливает encoding до декодирования. PowerShell
source validation остаётся существующим коротким маршрутом; файл с кириллицей
сохраняет совместимость с Windows PowerShell 5.1. Нормализация не затрагивает
byte-preserving `src/cf` и `src/cfe`.

JSON date strings — данные подписываемого/хэшируемого payload, а не разрешение
reader преобразовать их в DateTime. Сериализация для hash должна иметь одну
детерминированную семантику на поддерживаемых runtime, учитывать precision,
offset, Unicode/escaping и порядок контрактных полей. Исторические valid hashes
сохраняют проверяемую совместимость; реальная порча отвергается. Источник proof
не переписывается ради соответствия reader. Индекс — восстанавливаемая проекция;
его восстановление выполняет существующий owner, а не ручное редактирование.
Детали совместимости подтверждаются минимальными cross-runtime fixtures до
изменения общего helper; глобальная замена всех JSON-вызовов без анализа не нужна.

Python-компонент разрешает свой interpreter и dependency inputs. Подготовка
одного компонента не устанавливает среду остальных. Identity реального runtime
должна соответствовать reuse, а неопределённая identity не даёт reusable proof.

Fixture factory квалификации описывает состояние каждой фазы и использует
существующие lifecycle/snapshot действия в принадлежащих сценарию disposable
корнях. Upgrade начинает с своего опубликованного baseline; installed-candidate
проверка — с нужного кандидата. История посторонних branches не входит в стенд.
Отрицательная регрессия сохраняет исходную конфигурацию, отсутствие/наличие
trusted Designer-baseline и pending state; положительный сценарий независим.
Проверяется receipt через реальный child boundary и продолжение исходной задачи.

Альтернатива в виде ещё одного preflight только раньше обнаруживает отсутствие
среды. Здесь подготовка и восстановление завершаются действием владельца;
обнаружение mismatch само по себе не считается выполненной задачей.

### C. Согласованный checkpoint общего кандидата

Статус: 2026-10-11 пользователь подтвердил точный protocol checkpoint ответом
«Да, реализовать описанный этап C». Разрешение охватывает единый кандидат с CAS,
проверки вне общей блокировки, фиксированный состав выпуска и новые регистрации
через опубликованный develop supervisor в границах ниже. Пробная публикация V.7
требует отдельного разрешения после готовности проверяемого результата.

**Invariant / owner.** `source-delivery` принимает изменение только для
проверенной комбинации accepted queue и задачи. Единственный существующий
supervisor владеет queue, candidate checkpoint, qualification и remote ref;
публикатор сохраняет доверенную authority опубликованного канала. Runtime
authority не передаётся queued candidate или fixture. Общая фиксация кандидата
является расширением текущего queue-протокола внутри того же common Git.

**Минимальный reproducer.** A и B отдельно проходят проверки на опубликованном
develop, но меняют один общий контракт несовместимо. Сегодня конфликт впервые
обнаруживается в PublishDevelop. Новый registration route обязан обнаружить
его при включении B и сохранить уже принятый A. Отдельный canary: независимый B
меняет общий candidate, пока A выполняет проверку; A не вправе принять stale tree.

**Состояние.** Immutable Git commit представляет принятую интегрированную
комбинацию. Общая candidate reference и queue base/head изменяются одной
compare-and-swap Git transaction с ожидаемыми прежними значениями. Это один
протокол существующего владельца, без внешней БД или shadow queue. Точная форма
refs и запись состава являются внутренними деталями только в пределах этой
границы; совместимость с существующими refs проверяется до перехода.

**Sequencing.** Снять snapshot queue/candidate, собрать next tree в изолированном
worktree, проверить delta, атомарно принять результат. Длительные проверки идут
вне общей критической секции. При движении accepted candidate пересобрать tree;
по совпавшим входам сохранить proof, по изменившимся повторить соответствующие
checks. Один исходный бюджет операции охватывает ожидание и продолжения;
его нельзя обнулять каждым CAS retry. Исчерпание бюджета сохраняет task work,
proof/checkpoint и возвращает штатное продолжение вместо бесконечного цикла.

**Замороженный выпуск.** Publication использует существующий operation lease
и checkpoint для фиксированного состава. Новые регистрации продолжают next
candidate; они не меняют frozen release и не теряются при очистке. Очистка refs
сопоставляет опубликованные base/head с текущими и сохраняет новые значения.
Dependencies/assets/installable tree зафиксированы до окончательной qualification.
После успешной qualification transfer retry повторяет доставку, сохраняя valid
proof; integrity failure/remote movement обрабатывает тот же owner без bypass.

**Совместимость / откат.** Уже начатые планы продолжают закреплённый authority
commit и прежний immutable состав. Старую queue принимать новым протоколом
через проверенную интеграцию, без ручной переписи refs/checkpoint. При отказе
перехода сохраняется прежнее состояние и конкретное продолжение. До переключения
старый published owner остаётся действующим; после переключения rollback должен
понимать новые принятые записи, сохранять commits и не сбрасывать concurrent work.
Точный compatible rollback проверяется fixture перед включением нового протокола.

**Активация source registration.** Обнаруженный после первой регистрации
writer mismatch описан в [доказательствах](evidence/registration-authority.md).
Сейчас RegisterChange выбирает опубликованный master; публикация develop сама
по себе не активирует ни новый registration protocol, ни новый index writer.
Согласовано выбирать опубликованный develop supervisor для новых source
registrations, сохраняя immutable authority уже начатых планов и master-owned
release operations. Этот выбор канала является частью подтверждённого checkpoint,
а не рутинной заменой строки. До переключения fixture должен доказать переход
существующей очереди, старый план, безопасный resume и compatible rollback.
Не передавать authority незарегистрированному task checkout, не обходить locks
и не менять опубликованные refs ради активации.

**Границы ресурсов и платформ.** Затрагиваются source registration, candidate
worktrees, common-Git refs/checkpoints/proof и delivery. Lifecycle/1C guards,
remote agents, MCP runtime и пользовательские infobases не получают новой
authority. Shared resources ограничивают существующие владельцы. Windows 10/11,
Server 2019+, Windows PowerShell 5.1, поддерживаемый invocation из Core и terminal
sessions сохраняются. Нового installed-state migration, admin шага, background
service и always-on клиентского контекста не появляется.

**Альтернативы.** Owner-local проверки отдельных веток не устанавливают
совместимость комбинации. Stateless merge preview может выявить конфликт,
но без атомарной привязки к queue не доказывает принятую комбинацию при гонке.
Поэтому общей durable фиксацией владеет текущий queue owner. Новый coordinator
или длительный lock вокруг всех проверок не нужен.

**Canary / приёмка.** Конфликт при регистрации, конкурентное движение кандидата,
отмена только принадлежащих процессов, сохранение новой записи при очистке,
resume прежнего плана, incompatible state continuation и transfer retry без
повторной 1С. Fixture не подменяет финальные реальные qualification journeys.

### B. Checkpoint переноса состояния qualification fixture (подтверждён)

Исследование 2026-10-12 выявило границу, не разрешённую checkpoint этапа C.
Обычный `fork-dev-branch` вызывает `Remove-DevBranchForkTransientState` и удаляет
`pendingMerge*`, `pendingRefresh*`, cursor и runtime ownership. Это правильное
поведение пользовательского fork. У исходного отрицательного PM5-стенда,
напротив, требуются `pendingMergeOperation=refresh-dev-branch`,
`pendingMergeStage=merged` и отсутствие trusted Designer fingerprint/tree.
Заменить его обычным fork означает изменить предусловия регрессии.

Текущий upgrade в `invoke-develop-e2e.ps1` обновляет постоянно используемый
проект и оставляет новый HEAD/установку/базу. `Restore-DevelopE2ETrackedState`
восстанавливает только dirty tracked files относительно текущего HEAD.
`release-e2e-snapshot/restore` уже владеет guarded DumpIB/RestoreIB, но не
доказывает перенос исходного branch state в другой project context.

**Подтверждённый инвариант и владелец.** Qualification работает в новом,
принадлежащем сценарию проекте, восстановленном из проверенного fixture capsule.
Lifecycle остаётся единственным владельцем базы и восстановления branch state.
Source factory выбирает фазу и вызывает этот владелец; не пишет cursor,
Designer proof, pending state или status вручную. Обычный fork не меняется.

**Новая граница.** Узкий opt-in адаптер lifecycle материализует состояние capsule
в другом принадлежащем qualification project context. Он переносит только
объявленный branch и необходимые ему Git objects/history; foreign branch refs,
leases, PID, порты, launcher и client MCP ownership не переносятся. Связанные
пути переназначаются владельцем только внутри нового target root. Pending
operation/cursor и отсутствие либо наличие application baseline сохраняются
семантически; перенос не создаёт доверенный proof из одного имени поля.
Snapshot SHA, state/environment bytes, Git endpoints и declared expected outcome
образуют один вход восстановления. Частично materialized root не является proof.

**Фазы.** Upgrade начинается с immutable published workflow commit и его locks;
после штатного update-workflow проверяется exact candidate commit/tree.
Installed-candidate Release начинается с exact candidate. Negative PM5 и positive
journeys используют разные принадлежащие сценарию roots/базы. Seed не обновляется
кандидатом; следующий кандидат материализуется из того же проверенного seed.
Snapshot получают один раз для данного seed, а не делают новый DumpIB перед
каждым маленьким source Targeted. Изменение declared seed инвалидирует capsule.

**Почему существующей композиции недостаточно.** Stateless readiness только
отвергает mismatch. Обычный fork удаляет обязательный pending state. Восстановление
постоянного стенда на месте сохраняет накопленные unrelated branches и расширяет
восстановление на его изменённую историю. Нужен ограниченный перенос состояния,
а не ещё один preflight или ослабление исходной regression.

**Границы воздействия.** Затронуты source Develop/Release fixture preparation и
внутренний opt-in lifecycle adapter. Не затронуты пользовательские проекты,
обычный fork/refresh/check/export, master publication authority, общий кандидат,
очередь, guards, server support и clients. Нет нового coordinator, lock family,
machine-wide state, elevation, сервиса или always-on client context. Режим server
сохраняет существующее unverified правило; без своего доказанного disposable
target серверная база не назначается целью автоматически.

**Ожидание, отмена, recovery.** Native действия используют существующие per-infobase
guard, execution context и ограниченные бюджеты DumpIB/RestoreIB. Status и логи
остаются у текущего qualification owner. Отмена освобождает только owned child
processes; capsule и неуспешный target сохраняются для диагностики. Повтор того же
owner action проверяет capsule и незавершённый target, продолжает либо создаёт
следующий owned disposable target; никаких прямых reset/status edits агентом.
Успех требует полного materialization, затем исходного upgrade/check/export.

**Совместимость и откат.** Старые Release checkpoints продолжаются прежним owner;
им не приписывается portable identity. Новый adapter не мигрирует существующие
пользовательские state files. При его откате seed и исходный PM5-стенд остаются
сохранёнными; неуспешные owned targets не объявляются пригодными для старого пути.

**Решающая приёмка.** Сначала сохранить неизменённый исходный PM5 reproducer и его
реальный child receipt. Затем сравнить перенесённый negative: exact source SHA и
diagnostic, отсутствующий trusted baseline, исходные pending/cursor, отказ до
Apply и snapshot/cursor rollback. Независимый positive заканчивается fresh passed,
export/SHA. Два последовательных кандидата стартуют из одного seed без ручных
правок и не затрагивают соседний проект. Broken capsule/wrong target останавливают
только dependent journey и дают повторяемое owner continuation. Fixture tests
не заменяют эти live proofs; подготовка и восстановление измеряются отдельно.

Пользователь подтвердил checkpoint B 2026-10-12 и разрешил реализацию и
live-приёмку. Source-only adapter находится в `scripts/lifecycle-qualification-fixture.ps1`,
factory — в `scripts/source-e2e-fixture.ps1`; обычный installed fork не изменён.
Согласование C остаётся действующим. Реализация не означает завершение BA:
адресные fixtures и реальная приёмка учитываются отдельно.

## Risks / Trade-offs

- Неполные dependency inputs → негативные invalidation tests и консервативный
  reuse; новые dependency assertions не копируют реализацию выбора.
- Разделение suites теряет кейсы → сравнение старого и нового inventory/идентичностей,
  исполнение сохранённых nested routes и явное решение по каждому удалению.
- Параллельность затрагивает чужой console/process → isolation canary с настоящей
  отменой и неизменностью соседней задачи; serial restriction сохранять до доказательства.
- Воспроизводимый стенд теряет исходный дефект → неизменяемые исходные preconditions,
  отдельный negative/positive proof и контроль фактического DB/cursor состояния.
- CAS-гонка вызывает бесконечную работу → один бюджет и bounded owner continuation.
- Новая JSON canonicalization отклоняет старый valid proof → cross-runtime и
  legacy fixtures; не отключать SHA и не менять raw доказательства вручную.
- Ускорение только cache-hot пути скрывает стоимость → cold/warm/retry сравнение
  полного пути, с раздельными длительностями стадий и подготовкой.

## Migration Plan

1. Закончить audit/review, сохранить baseline и точные приёмочные сценарии.
2. Поставлять законченные A/B единицы через local commit и RegisterChange,
   без полного выпуска для каждого подпункта. Реальные gate-owned runs остаются штатными.
3. После protocol checkpoint реализовать C и fixture transition/recovery.
4. Для общего кандидата выполнить штатную qualification с допустимым reuse;
   отдельный Full после passed Develop того же дерева не требуется.
5. После отдельного разрешения на пробную публикацию выполнить PublishDevelop,
   проверить installability и refs/queue. Master и tags не менять.
6. Архивировать change только после фактической конечной приёмки всех требований.
