# План сужения ownership до execution/job boundary

Статус: реализовано в source candidate; локальные tests/registration, публикация,
установка и live acceptance учитываются раздельно.
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
9. Для пересоздаваемых dev/test-баз приоритет — продолжение работы после сбоя.
   Незавершённый запуск, неизвестный side effect и возможное повреждение тестовых
   данных не требуют обязательного recovery, rollback или пересоздания базы перед
   следующей командой. Старые записи и отсутствие evidence не являются lock.
10. Допуск защищает от одновременно работающих конфликтующих операций. Он не
    удостоверяет исправность тестовых данных. Прерванный запуск не считается
    успешной проверкой; fresh passed check перед экспортом сохраняется. Допущение
    о потере тестовых данных не распространяется на исходную базу и исходники Git.

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

Вложенные вызовы одного job используют тот же `executionId` и проверяемый
execution context: `measurement -> source capture -> Designer` и
`facade call -> broker -> native launch` не захватывают guard повторно.
Supervisor проверяет принадлежность дочернего вызова текущему execution и его
resource keys; одного переданного строкой ID недостаточно. Полный набор ресурсов
объявляется внешним execution до admission, дочерний вызов не расширяет его под
удерживаемым guard. Guard освобождает только внешний владелец после завершения
вложенной работы. Это наследование внутри нового bounded execution, без старых
root/participant tickets и без продления ownership между самостоятельными calls.

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
- terminal result (`succeeded`, `failed`, `interrupted` или `cancelled`) и ссылки
  на доступные логи/артефакты; они служат диагностике, а не разрешением на допуск.

Авторитетом владения является живой OS handle, а не JSON-файл. После смерти
процесса OS освобождает handle; диагностическая запись не способна сама по себе
заблокировать следующую операцию. Terminal-записи очищаются ограниченной
retention-политикой и не сканируются на hot path.

Освобождение handle не заменяет завершение активной работы execution: перед новым
native start исключается наложение на ещё работающего владельца или его дочернюю
активность. Проверяется текущая активность на exact base, а не полнота исторического
журнала. Отсутствующий, повреждённый или незавершённый диагностический JSON сам по
себе не создаёт запрета на запуск.

### 3.4. Ожидание

Ожидание происходит до lifecycle/Git locks и до запуска 1С:

1. caller публикует `waiting-for-base` с точным resource key, owner и elapsed;
2. полный набор ресурсов пробуется в canonical order;
3. при частичном успехе все handles немедленно освобождаются;
4. очередь повторяется до admission, отмены или настроенного wait deadline;
5. после admission caller повторно проверяет target, HEAD, `.dev.env` и checkpoint
   текущей файловой/Git-фазы; изменившийся input завершается точной ошибкой, а не
   выполняется по устаревшему плану. Запись о прерванной native-фазе dev/test-базы
   не является самостоятельным основанием отказать новой команде.

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
6. подтверждает завершение активной работы execution, включая вложенные вызовы и
   owned descendants этой работы, и только затем освобождает guard.

Если caller умер, supervisor завершает cleanup самостоятельно. Если умер
supervisor, Job Object закрывает принадлежащую execution активность. Следующий
supervisor автоматически проверяет текущую process identity и отсутствие
продолжающейся owned работы перед своим native start; участие агента в recovery
не требуется. Прогретый idle backend может жить отдельно от завершённого call,
но незавершённый запрос к нему не считается idle.

После сбоя dev/test-операции действует один контракт:

- операция получает `failed` или `interrupted`, имеющиеся логи сохраняются;
- после bounded cleanup guard освобождается, следующая команда допускается;
- неизвестный результат предыдущего side effect и состояние тестовых данных
  выводятся как диагностика, без обязательного восстановления или проверки
  исправности всей базы перед допуском;
- скрытого автоматического replay прерванной mutating-операции нет; no-replay
  относится к прежнему запуску и не запрещает следующую самостоятельную команду;
- следующий тест может упасть из-за оставшихся данных; разбор, reset или
  восстановление snapshot выполняются по необходимости отдельной операцией;
- прерванная загрузка не подтверждает свежесть базы, а неуспешный тест не выдаёт
  passed evidence. Следующий refresh/check выполняет свою обычную работу без
  предварительного recovery gate.

Если конфликтующая активность действительно остаётся живой и остановить её не
удалось, текущий запуск получает bounded error по exact base. После исчезновения
конфликта новая команда допускается без ручного сброса ошибок. Остальные базы,
Git-фазы и `update-workflow` продолжают работать. Ошибка cleanup в старом логе
сама по себе не доказывает наличие живого конфликта.

Обязательные recovery adapters для каждого producer не вводятся. Сохраняются
адресный process cleanup и существующие operation-specific контракты защиты
исходной базы, исходников и публикации; они не превращаются в общий recovery gate
для dev/test-баз. Snapshot rollback там, где он входит в явно выбранную операцию,
остаётся её контрактом, но не условием запуска произвольной следующей команды.

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

- Guard получается на один tool call; вложенный call использует execution context
  внешнего job без повторного захвата. Освобождение следует за atomic result и
  завершением активной работы; timeout ответа сам по себе этого не доказывает.
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

Cutover выполняется одним обновлением всех обслуживаемых веток. Исходное условие
этого перехода: известная проблема находится в workflow-блокировках; обязательная
проверка исправности баз или их восстановление в установку не добавляются.

1. Запустить source-owned новый updater в обход старого database admission и
   `runtime-mcp.lock`; подготовить новый package и supervisor без запуска v2 jobs.
2. На время установки остановить приём новых workflow jobs/calls и существующие
   exact workflow-owned helpers, facade/worker/supervisor processes. Проверять PID,
   start time, executable, project/worktree markers и base identity. После bounded
   grace period завершать только подтверждённую owned активность; чужие и
   неоднозначные процессы не завершать. Завершённость процессов не означает
   проверку исправности тестовых данных.
3. Новым master-owned updater обновить managed workflow files в master и всех
   обслуживаемых ветках, не вызывая старые branch-local admission paths.
4. Удалить obsolete tickets, indexes, waiters, pins, archives, recovery markers и
   записи удаляемого lock-протокола без чтения их recovery semantics и миграции.
   Исходники, базы и пользовательские артефакты не являются obsolete state.
5. После остановки старых исполнителей и обновления всех entrypoints активировать
   новую generation, возобновить jobs/calls и выполнять refresh новым runner-ом.

Сосуществование двух протоколов, compatibility reader и отдельная система
переходных database tickets не разрабатываются. От старого helper не требуется
понимать новый marker или возвращать `WORKFLOW_UPDATE_REQUIRED`: установщик
останавливает старые исполнители и заменяет helpers до включения нового runtime.
Конфликтующая активность чужого процесса остаётся локальным конфликтом конкретной
базы, а не причиной запретить обновление файлов остальных веток.

При прерывании установки повторный запуск того же updater завершает обновление
файлов и удаление obsolete state, затем включает новую generation. Уже включённый
новый runtime не откатывается к старому admission protocol. Исправность тестовых
данных и восстановление старых tickets не являются условиями продолжения cutover.

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
| Вложенные вызовы одного job/call | Один execution context, без повторного захвата guard |
| Native logs, checkpoints и snapshots | Диагностика и явно выбранные операции; не admission gate dev/test-базы |
| Session-capacity registry | Ограничение лицензий/сеансов, отдельно от ownership guard |
| Exact target revalidation после ожидания | Защита от запуска по изменившемуся `.dev.env`/state |
| Windows quoting, whitespace+Cyrillic и UTF-8 boundaries | Обязательная транспортная безопасность |

Process ownership и bounded cleanup сохраняются внутри supervisor. Доступные
средства восстановления остаются отдельными инструментами; обязательная цепочка
recovery перед продолжением работы dev/test-базы не переносится.

## 7. Что удаляется

- generic cross-project ticket database и lookup по historical state;
- `needs-attention` как блокирующее состояние будущих операций;
- generic auto-recovery до начала каждой команды;
- старый root/participant/inherited lease protocol; наследование нового execution
  context внутри ограниченного job/call сохраняется;
- обязательные recovery adapters и доказательство восстановления dev/test-базы
  как условие следующего запуска;
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
- Передавать проверяемый execution context в source capture и native helpers без
  повторного acquisition; после interrupted job допускать следующую команду по
  текущей активности, не по историческим journal/recovery записям.
- Удалить runtime-вызовы `access.py`, `access_host.py`,
  `access_autorecovery.py`, `ondemand_recovery.py` и старый PowerShell
  `DatabaseAccess.ps1` после переключения всех producers.
- Сохранить current job claim/status/cancel/no-replay schema, добавив
  `waiting-for-base`, heartbeat, deadline и exact owner evidence.

### On-demand Go facade

- В `database_runtime.go` заменить retained owner на call-scoped guard.
- В `runtime.go` отделить idle backend lifetime от database ownership.
- Передавать execution context в broker/native helper; при timeout завершать
  активный owned call, фиксировать ошибку и освобождать guard без recovery gate.
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
  запускает 1С, либо объявляет внешний/вложенный execution boundary, resources,
  deadline и bounded cleanup. Recovery adapter не является обязательным полем.

### Installer и managed copies

- Добавить source-owned one-time cutover entrypoint, способный обновить старую
  установку при stale old locks.
- Научить master-owned новый runner обновлять managed helper files всех
  обслуживаемых веток до включения новой generation и запуска refresh.
- Не добавлять root `AGENTS.md` в managed-copy lists.

### Документация

- После реализации переписать `database-access-acceptance-matrix.md` под новый
  guard и отметить старую matrix superseded.
- Обновить remote runner operations, branch lifecycle, advanced actions и
  human-facing installed docs.
- Старые stabilization/reliability plans оставить историей; не выдавать их
  прежний admission contract за действующий.

## 9. Реализационные волны

Волны разделяют разработку и локальную регистрацию. Production activation нового
протокола выполняется целиком в Wave 4; Wave 1–3 проверяются на изолированных
fixtures и не включают смешанный режим в установленных рабочих ветках.

### Wave 0 — executable contract и отрицательные тесты

- Зафиксировать registry всех native producers и точных ресурсов.
- Зафиксировать regressions для `update-workflow`, трёх refresh routes, owner
  death/hang, продолжения после прерванного теста, nested calls, different-base
  concurrency и cutover. Падающий reproducer используется при разработке;
  регистрируемая доработка включает исправление и проходящую проверку.
- Зафиксировать execution context, deadline и bounded cleanup каждого producer,
  без обязательного recovery adapter для dev/test-базы.

Критерий: нет producer-а с неопределённой ownership boundary. Assertions старого
протокола, требующие запрета после crash только из-за journal, заменяются проверкой
продолжения после cleanup. Сохраняются проверки отсутствия живого конфликта,
правильного target, защиты чужих процессов и достоверности passed evidence.

### Wave 1 — новый guard и supervisor параллельно старому коду

- Реализовать OS-handle authority, canonical keys, queue/status/cancel и ordered
  multi-resource acquisition.
- Реализовать owned Job Object, heartbeat, deadline, graceful cancel и exact kill.
- Реализовать наследование execution context и terminal failed/interrupted result
  без запрета следующего запуска по историческому состоянию.
- Старый production route пока не переключать.

Критерий: unit/integration tests доказывают wait, FIFO, crash/hang cleanup и
независимость разных баз. Нет partial hold или повторного захвата во вложенном
вызове; следующая команда допускается после cleanup без recovery.

### Wave 2 — remote jobs и on-demand

- Первым интегрировать bounded remote job в новый runtime на изолированном fixture.
- Затем перевести on-demand на call scope и targeted idle-runtime drain.
- Удалить public `finish_database_access` после переключения clients/tests/docs.

Критерий: backend idle не удерживает guard; параллельный mutating job безопасно
останавливает только exact owned backend и продолжает автоматически. Вложенные
source capture/broker calls не ждут собственный guard; interrupted call не оставляет
блокирующего recovery state.

### Wave 3 — lifecycle phase split

- Перевести refresh-lite, refresh, refresh-all, sync/reset/test/measurement paths.
- Добавить checkpoint/release/wait/reacquire/revalidate sequence.
- Убрать database wait и `runtime-mcp.lock` из Git/dependency phases.

Критерий: workflow update и Git merge выполняются при наличии старого/stale base
state; guard появляется только в трассе фактической native фазы.

### Wave 4 — cutover и удаление старого протокола

- Реализовать один source-owned updater: остановить старые исполнители, обновить
  все managed branches, удалить obsolete state и только затем включить v2.
- Удалить старое состояние на acceptance fixture без migration/recovery.
- Удалить old coordinator modules, command routes, tests и managed files.

Критерий: repo-wide search не находит runtime producer-ов старого protocol;
свежая установка и upgrade всех обслуживаемых веток используют только новый guard,
без миграции tickets и проверки исправности баз как условия обновления.

### Wave 5 — installed/live acceptance и доставка

- Выполнить file-base, server-base и remote execution acceptance.
- Проверить upgrade реальной старой установки со stale tickets.
- Прервать dev/test job посередине и выполнить следующую команду без recovery,
  ручного unlock, reset базы или ремонта служебных файлов.
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
7. Supervisor умер: Job Object закрывает owned активность; следующий supervisor
   автоматически проверяет её завершение перед native start, без recovery агента.
8. Dev/test job принудительно прерван после side effect: owned активность завершается,
   результат остаётся failed/interrupted, следующая команда запускается без recovery,
   rollback, ручного unlock или ремонта служебных файлов. Неизвестный effect не
   replay-ится автоматически; возможная ошибка следующих тестов не блокирует их запуск.
9. Foreign/unidentified 1C process: не завершается; только exact base получает
   bounded external-conflict result, другая база и `update-workflow` продолжаются.
10. `itl-refresh-lite` с неизменным fingerprint: database guard не создаётся.
11. `itl-refresh` ожидает branch base без удержания `master`/Git/runtime writer.
12. `itl-refresh-all`: одна занятая база не мешает завершить остальные ветки;
    две ветки одной базы сериализуются.
13. Multi-resource job не удерживает первый resource, ожидая второй.
14. Wait cancel завершает только waiter и не затрагивает owner.
15. Reboot/kill оставляет незавершённый/повреждённый JSON либо происходит до записи
    evidence: при отсутствии живой конфликтующей активности следующая команда
    запускается. Диагностические файлы не являются lock.
16. File path одновременно содержит пробелы и кириллицу; native arguments и
    output проходят общие quoting/UTF-8 helpers.
17. Server base запускается только через её configured execution host; конфликтная
    multi-host configuration отклоняется до native start.
18. Upgrade active branches выполняется новым master-owned runner-ом, даже если
    branch-local прежний helper не способен пройти старый admission. Все helpers
    обновлены, старые owned исполнители остановлены до активации v2; понимание
    нового marker старым helper и восстановление баз не требуются.
19. `measurement -> source capture -> Designer` и `facade call -> broker -> native
    launch` используют один execution context без повторного acquisition; внешний
    guard удерживается до завершения вложенной работы. Чужой context или ресурс за
    пределами объявленного набора отвергается без расширения захвата.
20. Cleanup не смог остановить реально живую конфликтующую активность: текущая
    команда завершается с bounded error только по этой базе. После завершения
    активности новая команда допускается без сброса прежнего error state.
21. Прерванный check не становится passed evidence и не разрешает экспорт вместо
    fresh passed check. Прерванная загрузка не подтверждает freshness; следующий
    refresh/check допускается и выполняет обычную проверку/загрузку.

## 11. Stop rules и критерий завершения

- Не добавлять новый generic recovery слой для закрытия отдельного failing test.
- Не превращать неизвестный результат или состояние данных dev/test-базы в
  обязательное восстановление перед следующей командой.
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
- после прерванного dev/test job следующая команда запускается без recovery gate,
  ручного unlock или ремонта диагностических файлов;
- чужой процесс никогда не force-kill;
- разные базы независимы, multi-resource acquisition не удерживает partial set;
- вложенные вызовы используют один execution context без повторного acquisition;
- полезные job/process/session/diagnostic контракты из раздела 6 сохранены;
- source tests, registration, installed upgrade и live acceptance имеют отдельное
  подтверждённое evidence.
