# Справочник публикации source workflow

Процедуры, которые нужны только во время публикации: единое продвижение
`develop` и `master`, Release уже опубликованного `develop`, cleanup и
disposition ресурсов поставки, Develop retry cache и Release budget projection.
Читайте его после `docs/source-publication.md` и только перед соответствующей
операцией. Обычная разработка и `RegisterChange` описаны в
[local-quality-gate.md](local-quality-gate.md).

## Единое продвижение develop и master

Если одна поставка должна опубликовать непустую очередь сразу в оба канала,
используется одна операция:

```powershell
.\scripts\source-delivery.ps1 -Action PromoteRelease `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r31-codechecker-logic
```

Она строит один exact candidate, выполняет `Develop` и `Release`, публикует его в
`develop`, затем выпускает то же дерево в `master`. Перед дорогими gate проходят
installability, owned-component plan и read-only finalizer preflight; для
невыпущенной ревизии Vanessa он сразу находит её exact сборку или останавливается с
`COMPONENT_ARCHIVE_UNAVAILABLE` до подготовки стенда. Второй
`Develop`/`Release` перед master запрещён: reuse разрешается только при совпадении
commit/tree и наличии двух passed run records, созданных текущей publication
attempt. Если reconciliation с `master` меняет candidate, reuse закрывается и
обычный release gate выполняется полностью.

После публикации в `develop` release-train checkpoint остаётся в общем Git
каталоге до подтверждённого `master`. Поэтому новый процесс `PromoteRelease`
возобновляет тот же commit/tree и не повторяет уже прошедшие Develop/Release.

Supervisor ведёт `.git/itl/resources/v1/ledger.json`. Он регистрирует candidate и
fresh worktree/базы/launcher identity, reusable stands, snapshots, current
CF/CFE+manifest, capability generation и owned PID/ports. Authority из стабильного
`master` сохраняет единственный operation lease, но cleanup-код выполняется из
detached worktree точного опубликованного канала по краткоживущей capability:
`PublishDevelop` — из текущего `origin/develop` до операции и из фактически
опубликованного develop commit после неё; `ReleaseMaster` — аналогично из
`origin/master` до и из фактически опубликованного master commit после неё.
`PromoteRelease` последовательно использует обе пары. Сдвиг ref, несовпадение
commit/result identity или отсутствие executor закрывает именно этот cleanup с
warning; fallback на другой канал запрещён.

В каждом проходе повторяется весь `cleanup-pending`. Используются прежние safe cleanup-функции: launcher-entry
удаляется до базы, `ibases.v8i` меняется под lock с BOM-backup (остаются три), а
имена, roots, process/worktree use, tracked drift, configured stand и artifact
SHA проверяются до удаления. Housekeeping failure не отменяет push и даёт
`completed-with-cleanup-warnings`; product cleanup assertion остаётся блокирующей.
Ручной безопасный повтор по умолчанию выполняется из develop:
`-Action Cleanup`; явный стабильный канал выбирается только через
`-Action Cleanup -CleanupChannel Master`. Ref-only cleanup очереди и promotion
refs остаётся у authority-supervisor и не делегируется канальному executor.
Shim закрепляет supervisor выбранного Cleanup-канала уже до передачи параметров.
Lease сравнивает время запуска владельца как точный UTC instant, включая ticks:
материализация JSON в DateTime не меняет identity, а другое время, PID или id
по-прежнему блокирует удаление refs.
На Windows read-only `ls-remote` cleanup-probe использует существующий process
job owner: быстрый выход Git не оставляет потомка, удерживающего вывод. Прежние
deadline и no-prompt environment сохраняются, environment задаётся только ребёнку.

Release-runner и cleanup используют `release-artifact-paths.ps1` для capability
generations в `.agent-1c/runs/release-e2e-capabilities/<run>/<generation>`;
ранее принимаемый `.agent-1c/release-capability-cache` также распознаётся.
Checkpoint-ссылки на snapshots, stage evidence и state files удерживают ресурс
в существующем `retained`, независимо от статуса checkpoint и TTL плана.
Такие ресурсы не занимают квоту двух failed plans и не повторяют ложные попытки
удаления. После снятия ссылки прежняя retention вновь применима. Повреждённый
checkpoint остаётся диагностируемым отказом. Удаление generation дополнительно
проверяет manifest SHA/identity, active/retained записи и отсутствие reparse points.
`Status` показывает count, bytes,
возраст, последнюю ошибку и следующую попытку. Failed plans сохраняют ресурсы
только для двух новейших plan и не дольше семи дней. Proof и stage evidence
после уборки сохраняются; срок хранения крупных recovery payloads описан ниже.

`Cleanup` также вызывает владельца qualification-копий в `FreshProjectsRoot/q Проект`.
Современная Develop-копия удаляется только после terminal proof и утилизации базы.
Для старого манифеста v1 требуется завершённая квитанция утилизации с тем же
candidate, точные project/branch paths и установленный workflow из того же
исходного репозитория; установленный commit должен принадлежать истории candidate.
Удаление сохраняет диагностические файлы, конфигурацию, завершённые execution
checkpoints, Git bundle, изменения и незарегистрированные исходники в общем Git
каталоге `itl/evidence/fixture-cleanup`. Это квитанция уборки, а не новая
квалификация тестов. Активная/retained ссылка, занятая copy lease, живой процесс,
оставшаяся база, reparse point или незавершённый checkpoint сохраняют копию.
Снимок читателей запрашивает у CIM только PID и командную строку всех процессов.
При ошибке разрешён один новый запрос с прежним лимитом 2 секунды; частичный
результат не используется. Повторная ошибка сохраняет копию и требует повторить
ту же уборку после восстановления CIM; обнаруженный читатель также запрещает её.
Подготовка пишет owner claim и внешнюю квитанцию до клонирования, удерживает
copy lease и записывает исходную ошибку как `preparation-failed`. Незавершённый
Develop factory target не используется повторно: повтор готовит новую копию из
sealed capsule. Уборка такой копии, включая старый каталог без манифеста,
требует привязки к проверенному capsule/source.bundle и candidate из общего
исходного Git. Для старого `ready` дополнительно требуется неизменённый
qualification report с точным target и завершённой проверкой/rollback.
Состояние повторно читается под copy lease. База неудачной подготовки удаляется
только прежним per-infobase владельцем после проверки resume-защит; другая
оставшаяся база сохраняет копию. Уникальные файлы сохраняются в проверенном
`recovery.zip`; побайтовый дубликат seed DT заменяется в recovery index ссылкой
на сохранённый оригинал и его SHA. Ни статус успешной проверки, ни disposal
для старого target не выдумываются. Release resume, активные/retained ссылки,
живые процессы и незавершённые checkpoints по-прежнему защищены. Каталоги без
доказанной принадлежности не усыновляются по имени или возрасту; результат
показывает причину сохранения.

После отдельного разбора старой попытки source-владелец копии поддерживает
явный `ArchiveInactive` для Develop/Release. Pre/post-operation и ручной Cleanup
также используют его для собственных schema v2 `ready`-копий после семи дней
бездействия, оставляя одну новейшую копию на фазу суммарно по корням.
Ищутся `q Проект` непосредственно в FreshProjectsRoot и на одном уровне групп
ниже (например, `C:\itlj\g3-...\q Проект`); деревья проектов не обходятся поиском.
Настройки исходного `.dev.env` (checkout override, затем process env имеют
приоритет): `ITL_SOURCE_FIXTURE_CLEANUP_ENABLED=true`,
`ITL_SOURCE_FIXTURE_RETENTION_DAYS=7`, `ITL_SOURCE_FIXTURE_KEEP_COUNT=1`.
`false` отключает архивирование по сроку, но сохраняет прежнюю уборку terminal
копий и завершение уже архивированного удаления. Ошибка настроек сохраняет
копии с warning; исправьте env и повторите ту же операцию. Возраст манифеста
служит лишь предварительным фильтром: под copy lease проверяются текущее `ready`
и время каждого файла. Новая активность сохраняет копию до следующего срока.
Это согласованное 2026-10-26 расширение прежнего source-copy owner: нет нового
сервиса, состояния, блокировок или installed migration; рабочие проекты и seed
стенды не включены. Прежние lease/process/ledger/checkpoint guards сохраняются;
приёмка — архив, проверка SHA и прежнее guarded disposal, без test pass или
публикации. Откат — `ITL_SOURCE_FIXTURE_CLEANUP_ENABLED=false`. Полный ZIP и его
проверка добавляют I/O только для просроченных кандидатов; metadata discovery
ограничен одним уровнем. Ошибка остаётся cleanup warning, исходная операция
продолжается; после сбоя удаления используется тот же архив и его proof.
Live-наблюдение 2026-10-26: прежний ArchiveInactive для копии 5,161 ГиБ
с 42047 файлами занял 615,2 с и оставил ZIP 1,607 ГиБ; поэтому большой backlog
может добавить минуты к housekeeping. `ITL_SOURCE_FIXTURE_ARCHIVE_BATCH_SIZE=1`
ограничивает число новых архивов за sweep, чтобы backlog не заполнял прежний
30-минутный budget executor. Защищённые копии лимит не расходуют; остальные
продолжатся на следующей операции или Cleanup. Уже архивированное удаление
завершается независимо от этого лимита. Это время архивирования и удаления,
не повторная квалификация. Обычный путь без просроченных копий не создаёт ZIP.
Режим не означает успешной проверки: он сохраняет полный `recovery.zip`,
включая базы, raw Git/index и незавершённый merge, до удаления исходной копии.
Действующие copy lease, процессы, owner-ссылки и producer checkpoints защищаются
как прежде. Для утилизации базы владелец проверяет архивную запись и SHA базы;
Release без такого архива по-прежнему не допускается к disposal. Восстановление
в исходный `copyRoot` из ZIP возвращает прежние абсолютные worktree pointers;
seed DT, вынесенный по точному SHA, восстанавливается из `retainedSource` в index.
Архив и исходная диагностика остаются на месте при ошибке; повторяется тот же
вызов владельца с теми же путями. Нужные текущему плану копии в этот режим не
включаются. Никаких passed-отметок или публикации этот режим не создаёт.
Если данные изменились после первого архива, сохраняются обе версии: исходный
архив не перезаписывается, новый вызов получает другой DiagnosticRoot.

Срок хранения крупных recovery payloads, записей регистраций и Pester shard
cache, а также read-only предпросмотр ручной уборки:
[source recovery retention](source-recovery-retention.md). Proofs, indexes и
stage evidence сохраняются; publication sweeps не удаляют recovery payloads.

Run history keeps every raw `itl/runs/*.json` proof in place. Routine timing and
`Status` read the atomic `itl/run-index/v1/hot.json` projection instead of
opening every raw file; the projection retains 2048 detailed recent entries and
lifetime counts/durations. A missing, stale, or corrupt index is reported as
unavailable rather than silently returning a partial raw scan. Serialized manual
`Cleanup` rebuilds it from raw proof once; writing a new run advances it
atomically under a short cross-process lock. If the projection lock or update
fails, the authoritative raw proof is still written and a pending marker makes
the projection explicitly stale until `Cleanup` repairs it. Exact Targeted
lookup tries the index first, then the unchanged raw store, and still accepts
only the known raw schemas 1, 2 and 3 with exact commit/tree and the mandatory
passed stages, plus a freshly calculated file SHA. Schemas 2 and 3 add timing
and failure metadata; unknown schemas remain unverified. Recorded continuation
uses the same proof predicate and rechecks the bound raw SHA and stages.

Only serialized manual `Cleanup` compacts exact-owned `removed` resource-ledger
records. It writes immutable content-addressed shards keyed by the first two hex
digits of `resourceId`, each containing complete records (including unknown
fields), then atomically removes them from the hot ledger. The fixed 256-way
address space makes rehydration a single-shard lookup instead of an archive
scan; unchanged shards are cached within the process. A restart between blob
write and ledger swap is idempotent. Re-registration uses the deterministic
`resourceId` to rehydrate the archived record before changing its state, so
extension fields survive. Active, retained, cleanup-pending, malformed, and
unknown-owner records remain hot. `Status` never rebuilds, compacts, deletes, or
rewrites either store; qualification, evidence, Pester shards, plans, and raw
runs are outside this retention action.

Для release-снимков распознаются текущий путь
`.agent-1c/runs/release-e2e/<run>/snapshots/{baseline,post-config}.dt`,
прежний `.agent-1c/release-e2e-runs/<run>/snapshots/` с теми же именами и
старые `release-e2e-*.dt`/`extension-init-*.dt` под `.agent-1c/snapshots/`.
SHA из ledger, отсутствие процесса и tracked drift по-прежнему обязательны;
reparse point ниже worktree не даёт права удалить перенаправленный файл.
Любая active/retained запись снимка защищает тот же путь от очистки
старой pending-записью, даже при одинаковом SHA. После штатного удаления по
совпадающей записи старые записи исчезнувшего файла закрываются в том же
проходе. Несовпадение SHA само по себе никогда не разрешает удаление.
Ссылка из соседнего producer `checkpoint.json` также сохраняет baseline и
post-config независимо от двух последних планов, TTL, статуса и версии
кандидата: эти байты нужны штатному Auto/Restart. Перед удалением уже pending
записи ссылка проверяется повторно. Нечитаемый checkpoint сохраняет снимок с
предупреждением очистки; после удаления checkpoint действуют прежние правила
очистки orphan-снимков. Legacy flat временные dumps сохраняют прежнюю политику.

`Status.disposition` is a read-only, compact inventory of only the
source-delivery namespaces and ledger identities. It classifies records as
`keep`, `eligible`, or `not-owned`, explains the reason, and never deletes or
prunes anything. User branches and arbitrary `codex/*` worktrees are outside
the inventory. The public `-Action Status` route uses the checked-out supervisor
directly and does not create or remove a bootstrap worktree. Exact ledger
ownership includes recomputing both `identitySha256` and `resourceId` from
`planId|kind|owner|identitySha256`.

Published ancestry or exact tree equivalence is proved only against the exact
`develop`/`master` tips returned by a bounded, non-interactive, read-only
`git ls-remote`; local remote-tracking refs are not publication evidence. The
probe disables Git/GCM/SSH credential prompts and has a fixed timeout. Timeout,
authentication failure, an unavailable remote, or a remote commit object that
cannot be inspected locally leaves the item `keep`.
Its native stdout/stderr boundary is explicitly UTF-8, including repository
paths containing spaces and non-ASCII text. Timeout teardown bounds both
`taskkill /T` and the direct-kill fallback, so descendant cleanup cannot turn
the probe into an unbounded Status call. The same deadline covers both async
stdout/stderr readers: if an already exited Git root leaves a descendant holding
an inherited pipe, reader expiry is a timeout and triggers best-effort descendant
cleanup instead of waiting without a deadline.
`taskkill /T` is used only while the root PID still has its exact creation
identity. If the root already exited, cleanup considers only descendants
captured while that root identity was live, rejects creation times after the
root exit, and rechecks each PID plus creation time immediately before stopping
it. An unknown pipe holder is reported as a timeout and may leak; PID reuse never
authorizes killing an unproven process.
`eligible` in `Status` remains advisory. Only an explicit manual `-Action Cleanup`
recomputes the disposition while holding the exact live `Cleanup`
`delivery-operation` lease. It may remove complete queue base/head pairs and stale
promotion refs in one `git update-ref --no-deref --stdin` transaction, with the
observed old SHA on every delete. A changed old object SHA or publication attempt
aborts the whole transaction. Symbolic refs observed by the cleanup snapshot are
rejected, and `--no-deref` prevents a later symbolic ref from exposing its target
to deletion. Publication pre/post sweeps never invoke this ref cleanup.

The current CIM command-line scan is only an advisory active-process signal. A
clear scan does not prove absence of open handles, a process cwd, or an
unobservable process, so candidate worktrees stay `keep/process-free-proof-required`.
An unavailable advisory probe is also `keep`, not a Status failure. A later
mutating implementation must add a complete process-free proof before treating
that deletion guard as satisfied. Qualification and content-addressed evidence
are always retained by this disposition batch.

Status brackets that remote probe with snapshots of the publication-attempt
file and the exact owned ref namespaces, then re-reads both. If the attempt
appears, disappears, or changes during the probe, every promotion ref remains
`keep`. If the owned ref snapshot changes, no ref from that unstable snapshot is
eligible. `Status.snapshot` exposes this validation result; it is a bounded
observation, not a cleanup lease.

The mutating cleanup consumes no previously printed `Status` result: it recomputes
every guard and rejects symbolic refs before committing its expected-SHA CAS.
Queue base/head refs always enter the same transaction, and eligible promotion
singletons use the same old-value guard. A moved ref leaves every target untouched.
Repeated Cleanup is idempotent: after a committed transaction the next fresh
disposition contains no target refs. Worktrees and ledger resources remain
read-only in this slice; worktree removal still requires a complete process,
handle, and cwd absence proof that is not currently available. A bare ref delete,
name-only worktree match, or age-based decision is never allowed.

An exact `publication-attempts/develop.json` `promotionRef` remains `keep` while
the attempt exists, even when its commit is already published. Its
`promotionCommit` is the expected SHA. A missing field, changed ref SHA,
unsupported schema, or unreadable attempt is fail-closed and cannot produce an
eligible promotion disposition; the promotion ref may still be required by
`Restore-DevelopCompatibilityPromotion` after interruption.

## Release уже опубликованного develop в master

```powershell
.\scripts\source-delivery.ps1 -Action ReleaseMaster `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r31-codechecker-logic
```

Очередь должна быть пустой, а локальный `develop` совпадать с
`origin/develop`. Этот маршрут нужен для уже опубликованного development channel;
для непустой очереди используется `PromoteRelease`. Оркестратор включает отсутствующие изменения текущего
`origin/master`, получает/reuses Develop proof точного дерева и запускает
release-only E2E. Для GitHub он публикует временную release-ветку, создаёт или
возобновляет PR в защищённый `master`, выполняет разрешённый linear-history
rebase merge и затем без force присоединяет фактический master commit к
`develop`. Для остальных Git remote сохраняется атомарный fast-forward обеих
веток. В обоих случаях финальная сверка требует одинаковое квалифицированное
дерево в `develop` и `master`; retry безопасно завершает прерванную сверку после
уже слитого PR.

`-Version itl-workflow-vX.Y.Z` отдельно создаёт annotated tag и GitHub Release
после успешного продвижения веток. Без `-Version` происходит только перенос в
стабильный канал.

Release сохраняет provenance/immutable dependencies, live MCP и Vanessa
isolation, `maxConcurrentSessions <= 3`, измеренный `ownedProcessExitWaitMs`,
snapshot rollback, config/extension roundtrip, fresh passed check, CF/CFE SHA и
cleanup. Он требует существующий Develop proof и не повторяет standard journeys.
On-demand probe отдельно записывает полное время `facadeCloseWaitMs` и
подтверждённое логом ожидание общей базы `executionGuardWaitMs`.
`ownedProcessExitWaitMs` остаётся ограниченным 15 секундами временем закрытия
после вычета только доказанного ожидания guard; непротоколируемая задержка
закрытия продолжает блокировать Release.
Серверные инфобазы остаются поддерживаемым runtime-контуром. Если все три поля
`serverProjectRoot`, `serverWorktreePath` и `serverDevBranchName` отсутствуют,
Release явно записывает `server-reset: unverified` и продолжает публикацию; это
не является passed evidence. Полностью настроенный серверный стенд запускает
прежний обязательный `server-reset`, а частичная конфигурация блокирует Release.
При новом workflow-кандидате `Auto` переносит совпавшие capability proofs в
неизменяемый cache, создаёт новый rollback baseline/HEAD и всегда повторяет
свежую проверку, export и cleanup. `-ReleaseResumeMode Restart` остаётся
штатным полным rollback; state/status вручную не редактируются.
Если предыдущий Release остановился на конкретном этапе, `Auto` проверяет
stage-version, production inputs, dependencies и релевантную environment identity.
Исправление только test/delivery harness не сбрасывает независимые целые этапы.
Упавший этап и затронутый downstream выполняются снова; verification refresh и
cleanup всегда свежие.

Полный диагностический прогон больше не является fallback. Он запускается только
вручную через `.\scripts\source-delivery.ps1 -Action DiagnoseFull` и ничего не
публикует.

Git hooks автоматически не устанавливаются. GitHub Actions не являются
каноническим источником локальной квалификации; доказательства создают команды
выше и их SHA-проверяемые JSON/JUnit artifacts.

## Develop retry cache

`Develop` persists an exact-tree static qualification immediately after
Full/Pester and tracked-state checks pass, before starting live journeys. Each
successful `upgrade` or `fresh` journey is then saved atomically as a separate
SHA-verified exact-tree checkpoint, including the clean post-journey HEAD of the
master and dedicated Develop stand worktrees. If a later journey fails, the retry restores
both the static proof and every completed journey, then resumes with the first
missing journey. A different tree, environment/fork/stand/package identity,
missing evidence, or corrupt cache disables reuse for that evidence.

Gate помечает сбой как owner или infrastructure. Только безопасные read-only
leaf stages (`fork-check`, `ai-rules-compatibility`) получают один автоматический
повтор при узко распознанной временной инфраструктурной ошибке. Pester, live 1C
journey, Release E2E и assertion failures автоматически не повторяются.

Тот же sweep удаляет просроченные не-Git work-каталоги контролируемой сборки
Vanessa из `C:\itlvabld`, старые passed-снимки миграции `ai_rules_1c`, точные
`*-artifact-hold-YYYYMMDD-HHmm\build` и распознанные release quarantine/evidence.
Автоматические pre/post-publication проходы выдерживают семь дней, ручной
`Cleanup` удаляет их сразу. Dirty Git, активные процессы, reparse/junction,
последний passed migration snapshot, текущие capability/rollback-каталоги и
неизвестная форма артефакта всегда сохраняются. В build work root распознаются
только непосредственные не-Git каталоги выделенного `C:\itlvabld`; содержимое
за его пределами sweep не рассматривает.

### Release budget projection

The Release stage catalog owns each capability ceiling and the enclosing
setup/restore/seal/finally reserve. `quality-contracts.ps1` projects the selected
dependency closure for the nested E2E process, and Full static plus the complete
E2E catalog for the enclosing `check.ps1 -Mode Release`. The serialized
`budgets.releaseHardSeconds` is a validated compatibility projection for already
published supervisors, not a second budget policy. The source wrapper retains
its separate 300-second finalization allowance and the existing no-progress
watchdog. Missing overhead on an older candidate retains its old mode budget;
a malformed present field does not select that fallback.

The original config-cadence workload still makes two independent metadata
changes and checks. One retained fresh full check took 1772.528 seconds;
two such envelopes model 3545.056 seconds before the original test-only failure,
cursor commits and postConfig snapshot. Cadence therefore has a conservative
4800-second ceiling, with unchanged version 3 and unchanged proof predicates.
The retained original publication terminated with `check-dev-branch timed out
after 1197 seconds`, matching the old 1200-second shared stage deadline after
its preceding work. That failed run and its native evidence remain failed.
The enclosing reserve is 1140 seconds: 600 for setup/prestage/retry/seal plus
three existing finally operations of at most 180 seconds each. The observed
baseline DT took about 140 seconds and readiness 11 seconds; the 600-second
part allows a comparable retry restore and remaining context/sealing work.
These are reserve estimates, not a measured complete successful cadence or
overhead. Full E2E ceilings sum to 11700 seconds; E2E including reserve is
12840, and the whole Release gate with Full static 4200 is 17040 seconds.
Selected capabilities keep their original scope and include the reserve once.
No fake capability is added. New immutable plans pin the reserve and include
it even when all selected runtime evidence is reusable; retained older plans
and failed evidence are not rewritten. The corrected candidate requires a new
immutable planId. Bind the continuation to it with `-ResumePlan`; the
unchanged workload needs no renewed user approval.

The original extension-smoke run on 2026-10-07 passed its UI scenario but
exhausted the former 900-second ceiling during Cfe initialization's canonical
dump, before the required final restore. Gate 6 added about 117 seconds of
snapshots and 208 seconds of checks in that run; recorded guard waits were zero.
The catalog now allows 1200 seconds for the unchanged Empty/authored/Cfe
roundtrips, checks and restoration. The additional 300 seconds cover the
remaining dump/restore/validation and reserve; this is an allowance estimate,
not a measured successful run. Other stage ceilings, no-progress limits and
proof predicates stay unchanged. The old timeout remains failed evidence.

The original ondemand-mcp run on 2026-10-08 completed the unchanged ROCTUP
and Vanessa UI probes, including cold/hot/file-loading scenarios, serialized
facade handoff and idle cleanup, in 1177.836 seconds. The stage then failed
its old 900-second ceiling. Its raw checkpoint, logs and both probe receipts
are retained under `build/lifecycle-record-publication/closed-ondemand-budget-50140d73-20261008`;
their successful predicates do not turn the failed stage into release proof.
The stage catalog now allows 1500 seconds: the observed workload plus about
322 seconds of allowance for the same preparation, probes and completion.
Version 5, input paths, workload, assertions, exit-wait ceiling and no-progress
limits remain unchanged. This changes the immutable delivery plan and its
budget projection, while preserving the fingerprints of reusable stages.

Before an Auto cross-release resume, a clean stand branch may have advanced
through completed workflow-only updates without merging master. Release reuses
the lifecycle owner's retained transaction chain proof (Git parents/trees,
before/current dependency locks, snapshot hashes and pinned write-set ownership).
It does not admit a commit by its subject or a path whitelist. Unproved changes,
configuration/test edits, damaged receipts and dirty owned files remain blocked;
the existing managed merge/cursor admission remains available. This read-only
admission neither rewrites checkpoints nor qualifies a stage. Normal Release
refresh and stage fingerprint validation still run under their existing owners.
Interrupted extension-smoke recovery belongs to the mutating Release owner.
It runs before ordinary readiness only with predeclared exact ownership sealed
after confirmed child/native stop. The same checkpoint and pinned postConfig
snapshot remain authoritative; foreign changes still fail the dirty guard.
Recovery archives exact bytes outside the run root and restores through the
existing snapshot helper. It records recovery, never a passed stage. Read-only
Plan/Status/readiness do not restore anything. A lost restore acknowledgement may
replay only that same validated DT after owned writer stop. Legacy residue without
prior ownership requires explicit bounded adoption, not prefix-based cleanup.
