# План сужения ownership до execution/job boundary

Статус: согласованное направление, реализация не начата.  
Область: database admission, lifecycle/runtime locks, on-demand MCP, remote jobs,
`update-workflow`, `refresh-dev-branch`, `refresh-dev-branch-lite` и
`refresh-all-dev-branches`.  
Публикация: этот план не разрешает публикацию в `develop` или `master`; каждая
реализационная волна проходит обычную локальную регистрацию отдельно.

## 1. Зафиксированные решения

1. Все записи старого database-access coordinator считаются ошибочным
   техническим состоянием. Они не мигрируются, не восстанавливаются и не
   участвуют в принятии решений нового механизма.
2. Старый протокол не получает compatibility reader, legacy aliases или
   параллельный recovery path. После переключения runtime-код его не читает.
3. Блокировка принадлежит не проекту, ветке, MCP-сессии или долгоживущему
   facade, а одной конкретной выполняемой операции 1С или remote job.
4. Конфликтующие операции над одной точной базой ожидают друг друга с видимым
   статусом. Операции над разными базами выполняются независимо.
5. Ожидание, остановка зависшего владельца и очистка после его смерти должны
   завершаться автоматически и за ограниченное время. Обычный workflow-owned
   crash или hang не является поводом требовать действий пользователя.
6. Возраст записи сам по себе не даёт права отобрать живую операцию. Основания
   для cleanup: подтверждённая смерть точного владельца, истёкший deadline его
   конкретной фазы или явная отмена.
7. Чужой или неоднозначно идентифицированный процесс не завершается. Такой
   внешний конфликт блокирует только точную базу, возвращает ограниченную
   диагностику и не останавливает другие базы, Git или обновление workflow.
8. Для начала реализации дополнительных runtime-данных не требуется. Live-логи
   текущих инцидентов могут дополнять acceptance, но не определяют архитектуру.

## 2. Почему текущая граница неверна

Сейчас `refresh-dev-branch` и `refresh-dev-branch-lite` получают
`mutation-exclusive` admission до lifecycle lock и удерживают его до конца всей
команды. Внутрь этого интервала попадают Git merge, обновление managed-файлов,
установка зависимостей, запуск 1С, MCP reconcile и запись branch state.

Кроме этого почти каждая mutating-команда получает эксклюзивный
`runtime-mcp.lock`. Поэтому idle facade или сохранённый `needs-attention` ticket
может блокировать операцию, хотя конфликтующей работы с базой уже нет.

Текущие последствия по командам:

| Команда | Что может блокировать её сейчас |
|---|---|
| `update-workflow` | lifecycle lock и `runtime-mcp.lock`; database ticket напрямую не запрашивается |
| `itl-refresh` | database admission всей команды, locks рабочей ветки и `master`, `runtime-mcp.lock` |
| `itl-refresh-lite` | database admission всей команды, lock рабочей ветки, `runtime-mcp.lock` |
| `itl-refresh-all` | lock `master`, затем те же блокировки каждого дочернего `refresh-lite` |

Это нарушает blocking policy: состояние базы блокирует файловые и Git-фазы,
продолжение которых само по себе не может повредить базу.

## 3. Целевая модель

### 3.1. Единственная единица ownership

Новый owner — это `executionId` одной ограниченной операции:

- один remote runner job;
- один конкретный Designer/Enterprise/test/measurement запуск;
- один on-demand tool call;
- одна операция над файлом базы или seed, если она действительно изменяет этот
  ресурс без запуска 1С.

Idle backend, задача Codex, ветка и MCP-сессия owner-ами базы не являются.
Долгоживущий `finish_database_access` удаляется из публичного контракта.

### 3.2. Ключ ресурса

Guard строится из canonical exact infobase identity:

- file base: нормализованный физический путь и проверенная alias identity;
- server base: нормализованные cluster/server и infobase identity;
- несколько ресурсов: полный набор ключей фиксируется до ожидания, сортируется и
  получается без удержания частичного набора.

Authority находится на execution host. Для server base все workflow-owned
операции маршрутизируются через один объявленный execution host. Если одна база
настроена на независимое выполнение с нескольких hosts, конфигурация отклоняется
до запуска; общий файловый coordinator через SMB не возвращается.

### 3.3. Минимальное состояние guard

Предлагаемый новый корень имеет отдельную protocol generation, например
`execution-guards-v2`, и не пересекается со старым coordinator.

Для одного execution сохраняются только:

- `executionId`, operation и exact resource keys;
- PID, process start time и identity supervisor-а;
- состояние `waiting`, `running`, `cancelling` или terminal;
- heartbeat, phase deadline и cancel endpoint/path;
- сведения о принадлежащем Job Object/process tree;
- ссылка на operation-specific recovery evidence только после фактического
  начала native side effect.

Авторитетом владения является живой OS handle, а не JSON-файл. После смерти
процесса OS освобождает handle; диагностическая запись не способна сама по себе
заблокировать следующую операцию. Terminal-записи очищаются ограниченной
retention-политикой и не сканируются на hot path.

### 3.4. Ожидание

Ожидание происходит до lifecycle/Git locks и до запуска 1С:

1. caller публикует `waiting-for-base` с точным resource key, owner и elapsed;
2. полный набор ресурсов пробуется в canonical order;
3. при частичном успехе все handles немедленно освобождаются;
4. очередь повторяется до admission, отмены или настроенного wait deadline;
5. после admission caller повторно проверяет target, HEAD, `.dev.env` и pending
   transaction; изменившийся input завершается точной ошибкой, а не выполняется
   по устаревшему плану.

Сохраняются полезные части `Wait-Agent1cLockSet`: видимый статус, cancellation,
полный release частичного набора, повторная проверка input и ограниченный timeout.
Старые lifecycle waiter-файлы не становятся database authority.

### 3.5. Выполнение и cleanup

Native execution запускается через supervisor, который:

1. получает guard;
2. создаёт Job Object с kill-on-close;
3. запускает только принадлежащий workflow process tree;
4. обновляет heartbeat и контролирует operation-specific deadline;
5. при cancel/hang сначала выполняет штатную остановку, затем после grace period
   завершает только проверенный owned process tree;
6. подтверждает отсутствие owned descendants и только затем освобождает guard.

Если caller умер, supervisor завершает cleanup самостоятельно. Если умер
supervisor, следующий агент проверяет PID + start time + executable/script
identity + executionId, закрывает или завершает только этого владельца; закрытие
Job Object удаляет его descendants, а OS handle освобождается автоматически.

Если процесс успел начать native side effect, применяется adapter конкретной
операции, а не generic recovery coordinator:

- доказать, что целевое состояние уже достигнуто, и завершить operation;
- либо восстановить заранее объявленный snapshot/checkpoint;
- только после доказанного восстановления разрешить новый bounded attempt;
- никогда не replay-ить неизвестный side effect без такого доказательства.

Каждая поддерживаемая mutating-фаза обязана иметь автоматический adapter до
включения в новый runtime. Необслуживаемая неоднозначность является дефектом
реализации и не переводится в вечный `needs-attention`.

## 4. Поведение пользовательских команд

### `update-workflow`

- Не получает database guard и не ждёт on-demand/backend owners.
- Не получает общий `runtime-mcp.lock` writer.
- Сериализуется только с другой модификацией managed workflow файлов и `master`
  через отдельный узкий package-update/lifecycle lock.
- Пишет managed-файлы staged/atomic способом. Запущенный facade заканчивает
  текущий вызов на прежнем immutable component generation; новый вызов или новый
  процесс использует обновлённую generation.
- Первый переход со старой установленной версии должен иметь source-owned
  bootstrap path, который копирует новый updater до входа в старые locks.

### `itl-refresh-lite`

1. Под branch lifecycle lock выполняет preflight, merge точного `master` SHA,
   managed workflow copy и dependency preparation.
2. Записывает продолжимый checkpoint и освобождает locks перед ожиданием базы.
3. Ожидает guard только target branch base.
4. Повторно получает branch lock и проверяет checkpoint/HEAD/target.
5. Под guard останавливает только owned idle runtimes этой базы, выполняет
   необходимый Designer/Enterprise load и подтверждает cleanup.
6. Освобождает guard сразу после native фазы; последующие чисто файловые отчёты
   не продлевают ownership.
7. Если fingerprint доказывает, что native load не нужен, database guard вообще
   не получается.

### `itl-refresh`

- Использует ту же phase boundary, что `refresh-lite`.
- Синхронизация `master`, source base и seed разделяется на собственные
  конкретные execution phases; branch base не резервируется на время Git/source
  подготовки.
- Main-worktree lock освобождается до ожидания branch base.

### `itl-refresh-all`

- Один раз синхронизирует и фиксирует exact master SHA.
- Каждый branch worker проходит новый `refresh-lite` независимо.
- Ветка с занятой базой публикует `waiting-for-base`; остальные ветки продолжают
  работу в пределах worker limit.
- Две ветки на одной canonical базе выполняются последовательно. Разные базы —
  параллельно.
- Aggregate остаётся активным до terminal result всех веток либо явной отмены,
  но одна ожидающая ветка не удерживает `master` writer и не мешает другим.

### On-demand MCP

- Guard получается на один tool call и освобождается после его atomic result.
- Idle backend может оставаться прогретым, но не владеет базой.
- Перед mutating native phase lifecycle owner под guard выполняет адресный drain
  backend-а по exact base, PID/start identity, executable и markers.
- `finish_database_access`, retained phase и idle-timeout-as-release удаляются.

### Remote jobs, tests и measurements

- Remote worker job остаётся естественной ownership boundary.
- Job claim, status, cancel, deadline, artifacts и no-replay сохраняются.
- Functional test и measurement владеют точной базой только на время job/phase,
  а не на время проекта или сессии агента.
- Для простоты новый guard эксклюзивен. Старые режимы `shared-read`,
  `functional-test`, `measurement-exclusive`, `mutation-exclusive` и их
  transitions не переносятся. Короткие read calls получают тот же guard только
  на длительность вызова.

## 5. Однократный cutover без legacy support

Cutover является частью поставки, а не ручной инструкцией по удалению locks.

1. Установить новый package updater и execution supervisor, не входя в старый
   database admission и `runtime-mcp.lock`.
2. Поставить protocol-generation marker, после которого новые процессы используют
   только `execution-guards-v2`.
3. Найти только exact workflow-owned facade/worker/supervisor processes по PID,
   start time, executable, project/worktree markers и base identity.
4. Штатно остановить их; после bounded grace period завершить только подтверждённый
   owned process tree. Чужие и неоднозначные процессы не завершать.
5. Не читая recovery semantics старых tickets, удалить старые tickets, indexes,
   waiters, pins, archives, recovery markers и локальные `runtime-mcp.lock` /
   lifecycle waiter records, относящиеся к удаляемому протоколу.
6. Обновить managed workflow files активных веток из нового master-owned runner,
   чтобы branch-local старый helper не мог снова войти в прежний admission path.
7. Запустить дальнейший refresh уже новым runner-ом.

Смешанная работа старого и нового протоколов не поддерживается. Старый branch
helper после generation switch должен вернуть понятное `WORKFLOW_UPDATE_REQUIRED`
до запуска 1С, а не создавать старый ticket. Это fencing перехода, а не runtime
совместимость или миграция старого состояния.

Если cutover падает до generation switch, staged package copy откатывается. После
switch возврат к старому admission protocol не поддерживается; исправление идёт
вперёд. Старые lock/recovery данные не сохраняются как rollback state.

## 6. Что сохраняется из уже сделанных доработок

| Полезный контракт | Как используется дальше |
|---|---|
| Canonical exact base identity и aliases | Ключ нового guard и проверка target после ожидания |
| Независимость разных баз | Базовый concurrency-инвариант |
| Ordered multi-resource acquisition без partial hold | Для jobs, затрагивающих несколько точных баз |
| Видимое ожидание, timeout и cancel | Статус `waiting-for-base` и bounded queue |
| PID + process start time + executable/markers | Доказательство owned supervisor/process tree |
| Windows Job Object и bounded process cleanup | Автоматическая очистка crash/hang |
| Job claim, status, artifacts и no-replay | Remote execution contract |
| Native journal/checkpoints/snapshots | Только operation-specific evidence после начала side effect |
| Session-capacity registry | Ограничение лицензий/сеансов, отдельно от ownership guard |
| Exact target revalidation после ожидания | Защита от запуска по изменившемуся `.dev.env`/state |
| Windows quoting, whitespace+Cyrillic и UTF-8 boundaries | Обязательная транспортная безопасность |

То есть полезная process ownership и recovery-механика не откатывается вместе со
старым coordinator. Она переносится внутрь конкретного supervisor/job adapter.

## 7. Что удаляется

- generic cross-project ticket database и lookup по historical state;
- `needs-attention` как блокирующее состояние будущих операций;
- generic auto-recovery до начала каждой команды;
- root/participant/inherited lease protocol;
- access-mode transitions и legacy mode aliases;
- retained on-demand database phase и `finish_database_access`;
- archive/pin/migration/compaction логика старых tickets на runtime hot path;
- общий `runtime-mcp.lock` writer для `update-workflow`, refresh Git/dependency
  phases и других операций без текущего native execution;
- ожидание базы при удерживаемом lifecycle/Git/master lock.

После завершения перехода старые модули и их тесты удаляются, а не оставляются
как неиспользуемый fallback.

## 8. Изменения по компонентам

### Portable runner

- Добавить минимальный `execution_guard.py` и supervisor contract рядом с
  `itl_remote/execution.py`.
- Перевести `execution.py` на job-scoped guard и owned Job Object cleanup.
- Удалить runtime-вызовы `access.py`, `access_host.py`,
  `access_autorecovery.py`, `ondemand_recovery.py` и старый PowerShell
  `DatabaseAccess.ps1` после переключения всех producers.
- Сохранить current job claim/status/cancel/no-replay schema, добавив
  `waiting-for-base`, heartbeat, deadline и exact owner evidence.

### On-demand Go facade

- В `database_runtime.go` заменить retained owner на call-scoped guard.
- В `runtime.go` отделить idle backend lifetime от database ownership.
- В `gateway.go` удалить `finish_database_access` и его fencing state.
- Добавить адресный drain API, который доступен только mutating supervisor-у и
  проверяет exact base/process identity.

### Lifecycle PowerShell

- В `agent-1c.ps1` убрать pre-lifecycle admission для refresh и остальных
  операций, где база нужна только в отдельных native phases.
- В `agent-1c.core.ps1` разделить lifecycle locks, package-update lock и native
  execution guard; убрать общий `runtime-mcp.lock` writer из файловых фаз.
- В `agent-1c.lifecycle.ps1` разбить refresh/sync/reset/test paths на checkpointed
  file/Git phases и guarded native phases.
- Все workflow-owned запуски 1С направить через один supervisor API; прямой
  `Start-Process` для таких запусков остаётся запрещён.
- Добавить set-completeness test: каждая операция из entrypoint registry либо не
  запускает 1С, либо объявляет execution boundary, resources, deadline и recovery
  adapter.

### Installer и managed copies

- Добавить source-owned one-time cutover entrypoint, способный обновить старую
  установку при stale old locks.
- Научить master-owned новый runner обновлять managed helper files активной ветки
  до запуска её refresh continuation.
- Не добавлять root `AGENTS.md` в managed-copy lists.

### Документация

- После реализации переписать `database-access-acceptance-matrix.md` под новый
  guard и отметить старую matrix superseded.
- Обновить remote runner operations, branch lifecycle, advanced actions и
  human-facing installed docs.
- Старые stabilization/reliability plans оставить историей; не выдавать их
  прежний admission contract за действующий.

## 9. Реализационные волны

### Wave 0 — executable contract и отрицательные тесты

- Зафиксировать registry всех native producers и точных ресурсов.
- Добавить падающие regressions для `update-workflow`, трёх refresh routes,
  owner death, owner hang, different-base concurrency и cutover.
- Зафиксировать operation-specific timeout/recovery adapter для каждого producer.

Критерий: нет producer-а с неопределённой ownership boundary; тесты воспроизводят
текущую ошибочную блокировку без ослабления существующих safety assertions.

### Wave 1 — новый guard и supervisor параллельно старому коду

- Реализовать OS-handle authority, canonical keys, queue/status/cancel и ordered
  multi-resource acquisition.
- Реализовать owned Job Object, heartbeat, deadline, graceful cancel и exact kill.
- Старый production route пока не переключать.

Критерий: unit/integration tests доказывают wait, FIFO, crash/hang cleanup,
отсутствие partial hold и независимость разных баз.

### Wave 2 — remote jobs и on-demand

- Первым production consumer сделать bounded remote job.
- Затем перевести on-demand на call scope и targeted idle-runtime drain.
- Удалить public `finish_database_access` после переключения clients/tests/docs.

Критерий: backend idle не удерживает guard; параллельный mutating job безопасно
останавливает только exact owned backend и продолжает автоматически.

### Wave 3 — lifecycle phase split

- Перевести refresh-lite, refresh, refresh-all, sync/reset/test/measurement paths.
- Добавить checkpoint/release/wait/reacquire/revalidate sequence.
- Убрать database wait и `runtime-mcp.lock` из Git/dependency phases.

Критерий: workflow update и Git merge выполняются при наличии старого/stale base
state; guard появляется только в трассе фактической native фазы.

### Wave 4 — cutover и удаление старого протокола

- Реализовать source-owned bootstrap, generation switch и managed branch update.
- Удалить старое состояние на acceptance fixture без migration/recovery.
- Удалить old coordinator modules, command routes, tests и managed files.

Критерий: repo-wide search не находит runtime producer-ов старого protocol;
свежая установка и upgrade со старой установки используют только новый guard.

### Wave 5 — installed/live acceptance и доставка

- Выполнить file-base, server-base и remote execution acceptance.
- Проверить upgrade реальной старой установки со stale tickets.
- Каждую coherent source change завершать commit + `RegisterChange`; не выполнять
  `PublishDevelop`, `Release` или master promotion без отдельного разрешения.

Критерий: все сценарии ниже пройдены на exact candidate; локальная регистрация,
публикация, установка и live proof сообщаются как разные состояния.

## 10. Обязательная acceptance-матрица

1. Старые tickets/indexes/recovery markers существуют, процессов нет:
   `update-workflow` и cutover завершаются, `itl-refresh-lite` доходит до native
   phase без ручного unlock.
2. Два jobs на одной базе: второй показывает `waiting-for-base`, после первого
   запускается автоматически и не теряет input revalidation.
3. Jobs на разных базах: выполняются одновременно.
4. Owner process аварийно завершён до native side effect: OS handle освобождён,
   следующий waiter admitted автоматически.
5. Owned 1C child завис после старта: deadline запускает cancel, затем exact
   process-tree cleanup; следующий waiter продолжает работу.
6. Caller умер, supervisor жив: supervisor завершает cleanup без исходного агента.
7. Supervisor умер: следующий агент валидирует identity, Job Object закрывает
   descendants, guard освобождается.
8. Crash после side effect: adapter доказывает desired state либо восстанавливает
   snapshot; неизвестный effect не replay-ится.
9. Foreign/unidentified 1C process: не завершается; только exact base получает
   bounded external-conflict result, другая база и `update-workflow` продолжаются.
10. `itl-refresh-lite` с неизменным fingerprint: database guard не создаётся.
11. `itl-refresh` ожидает branch base без удержания `master`/Git/runtime writer.
12. `itl-refresh-all`: одна занятая база не мешает завершить остальные ветки;
    две ветки одной базы сериализуются.
13. Multi-resource job не удерживает первый resource, ожидая второй.
14. Wait cancel завершает только waiter и не затрагивает owner.
15. Reboot/kill оставляет диагностический JSON, но он не является lock и не
    блокирует следующую операцию.
16. File path одновременно содержит пробелы и кириллицу; native arguments и
    output проходят общие quoting/UTF-8 helpers.
17. Server base запускается только через её configured execution host; конфликтная
    multi-host configuration отклоняется до native start.
18. Upgrade active branches выполняется новым master-owned runner-ом, даже если
    branch-local прежний helper не способен пройти старый admission.

## 11. Stop rules и критерий завершения

- Не добавлять новый generic recovery слой для закрытия отдельного failing test.
- Не вводить TTL-based force unlock живого owner-а.
- Не ослаблять ownership identity ради автоматического cleanup.
- После двух одинаковых сбоев без новой причинной информации остановить retry и
  исправлять owner implementation/fixture.
- Новые пожелания, не необходимые для acceptance выше, помещать в отдельный
  backlog, не расширяя текущую волну.

Работа завершена только когда одновременно выполнено следующее:

- старый protocol не участвует в runtime и его state удаляется cutover-ом;
- `update-workflow` не зависит от database/on-demand locks;
- все refresh routes блокируют только точную native phase и умеют ждать;
- ordinary owned crash/hang очищается автоматически и bounded;
- чужой процесс никогда не force-kill;
- разные базы независимы, multi-resource acquisition не удерживает partial set;
- полезные job/process/session/recovery контракты из раздела 6 сохранены;
- source tests, registration, installed upgrade и live acceptance имеют отдельное
  подтверждённое evidence.
