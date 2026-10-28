# Проверки и доставка исходного workflow

Обычная доработка не запускает общий gate. Агент создаёт один связный локальный
коммит и регистрирует его:

```powershell
.\scripts\source-delivery.ps1 -Action RegisterChange `
  -CoverageContract <existing-contract-id>
```

Регистрация собирает общий кандидат из опубликованного develop, уже принятой
очереди и задачи в отдельном worktree. `Targeted` проверяет дельту от предыдущего
принятого кандидата. При первом переходе старой очереди без такого кандидата
базой проверки служит develop: старые записи включаются в проверяемую комбинацию.
Список изменений самой задачи и её coverage считают от прежнего head её QueueId
(либо `origin/develop` / явного `-BaseRef` для новой очереди). Исходный queue base
сохраняется. Замена диапазона, не продолжающая принятый head, отклоняется.

При конфликте с новым опубликованным develop разрешите его в source-ветке
задачи, сохранив её принятый head и published develop в ancestry, и повторите
`RegisterChange` с прежним QueueId. Регистрация сначала интегрирует проверенный
source head, затем опубликованный develop и остальные записи очереди. Это
позволяет прочитать явное разрешение до столкновения старого кандидата с develop.
Неразрешённый конфликт по-прежнему останавливает регистрацию; новые refs
принимаются только после Targeted и атомарного сравнения исходного состояния.

`Plan` проверяет актуальные release assets через GitHub SHA-256 digest и HEAD
точного download URL. При отсутствии digest или недоступности metadata/HEAD
сохраняется прежняя загрузка с проверкой SHA; несовпадение digest немедленно
отклоняется. Локальный cache не заменяет проверку удалённого asset. Финализатор
сохраняет проверки локальных upload bytes, provenance, tags и квалификации.
Stateless remote inspector точного чистого кандидата работает в дочерней области;
component selection и preflight остаются у опубликованного supervisor. Для
старого planner shim возвращает только advisory preview без сохранения resumable
плана; существующие планы и publication authority сохраняются. После публикации
поддержки обычный Plan снова сохраняет resumable план.
`invocationTiming` показывает полное время команды, подготовку supervisor,
вызов planner и очистку. `planningDurationMs` по-прежнему измеряет только расчёт
кандидата; эти времена не являются оценкой длительности будущего выпуска.

`Plan` фиксирует кандидат и точный состав queue id/base/head. `PublishDevelop`
сохраняет этот состав в существующем checkpoint; повторный вызов продолжает
его, не включая поздние регистрации. `-ResumePlan` использует сохранённый
кандидат и прежнюю authority. Старые планы без поля queue сохраняют свою
идентичность. Новые регистрации относятся к следующему выпуску.
После push очистка сравнивает только замороженные base/head: продвинутые и
новые записи сохраняются. Гонка CAS повторяет только очистку. Отказ после
push сохраняет checkpoint; тот же вызов завершает очистку без новой квалификации
уже опубликованного кандидата. Применимость proof по окружению и входам
продолжает проверять существующий владелец квалификации.

Обычный повтор автоматически закрепляет authority активного плана. При
изменившихся входах или remote до push `PublishDevelop -Replan <originalPlanId>`
явно создаёт замену, сохраняя прежние plan/proof и checkpoint по SHA. Повтор
этого Replan продолжает зафиксированную замену. `-ReplanQueueScope Frozen`
сохраняет исходные id/base/head и candidate, интегрируя только опубликованный
develop; поздние и продвинутые регистрации остаются на следующую публикацию.
Первый такой вызов передаёт checkpoint совместимому опубликованному develop
supervisor после проверок SHA, ancestry и immutable identity; повтор использует
supervisor замены. Поддержка этого режима сначала публикуется отдельно от
опубликованного baseline в clone/common Git со своей очередью, как support-only
поставка. При явно разрешённом исправлении `-FrozenRepair id@head` добавляет
только эту зарегистрированную запись, чья base равна исходному candidate.
Исходные пары не заменяются; незаявленные поздние записи не могут входить
в ancestry исправления. Новый immutable plan закрепляет полный состав и
проходит обычную квалификацию. Повтор проверяет pin по принятому плану,
поэтому позднее продвижение этой записи остаётся следующей публикации.
Расширение существующего Replan одобрено пользователем 2026-10-27 для
`e2e-negative-change-plan@b1f9f6b482df741051924a1fc85e02d438e0f4ea`.
Обычный Replan включает текущую очередь. Неизменённые входы не сбрасывают
circuit breaker. Повреждённый выбранный proof сообщает путь/SHA/причину;
Replan архивирует только повторно подтверждённый повреждённый record. Валидные
этапы остаются применимыми по прежним правилам. Закрытый ResumePlan возвращает
already-reachable без новой квалификации и изменения следующей очереди.
Исторический активный план завершается прежним owner перед новым RegisterChange;
функциональный rollback сохраняет совместимый queue decoder. Сценарии и пределы
доказательств: [candidate recovery](../openspec/changes/redesign-source-delivery/evidence/candidate-recovery.md).

### Ремонт упавшей замороженной публикации

Падение Pester, journey или сценария в `Frozen` публикации чинится в отдельном
ремонтном worktree без регистрации, Targeted и нового plan на каждую попытку.
`scripts/source-repair.ps1` не хранит своё состояние и не берёт authority:
он читает checkpoint и run index, отказывает при живой операции доставки и
вызывает существующих владельцев из ремонтного worktree.

```powershell
.\scripts\source-repair.ps1 -Action Start
# правка и обычный локальный commit в напечатанном worktree
.\scripts\source-repair.ps1 -Action Run -RepairRoot <worktree> -Test <File.Tests.ps1>
.\scripts\source-repair.ps1 -Action Run -RepairRoot <worktree> -Journey upgrade `
  -E2EProjectRoot <стенд> -AiRulesSource <fork> -AgentTarget <клиент>
.\scripts\source-repair.ps1 -Action Run -RepairRoot <worktree> -Unproven `
  -E2EProjectRoot <стенд> -AiRulesSource <fork> -AgentTarget <клиент>
.\scripts\source-repair.ps1 -Action Finish -RepairRoot <worktree> `
  -E2EProjectRoot <стенд> -AiRulesSource <fork> -AgentTarget <клиент>
```

`Start` создаёт `itl/repair/<candidate>` от candidate checkpoint, а после
принятой замены fast-forward переносит ветку на новый candidate. `Run` требует
чистое закоммиченное дерево и выполняет только названные тесты через
`invoke-pester-shards.ps1` (selection schema 1 сохраняет шард под ключом полного
inventory) и только названный journey/сценарий через `invoke-develop-e2e.ps1` с
той же привязкой артефактов и capture фикстур, что и gate. Прошедший сценарий
сохраняется существующим владельцем scenario proof; финальный gate берёт его
только после полного текущего static и совпадения всех входов, иначе выполняет
заново. Стенд, fork и клиент должны совпадать с публикацией.

Journey без `-Scenario` повторяет только сценарии без сохранённого proof для
текущего дерева; отрицательный сценарий, прошедший в последнем упавшем прогоне,
откладывается. Продолжить с середины сценария нельзя: каждый стартует с
неизменяемого снимка стенда. Перед `Finish` `Run -Unproven` выполняет то, что
финальный gate ещё не может переиспользовать: Pester-файлы, которые владелец
шардов выбрал бы через `-PlanOnly`, и сценарии upgrade/fresh без proof, до
первого сбоя. Финальный gate остаётся полным и решает reuse сам.

`Finish` — единственная регистрация ремонта: `RegisterChange` с `-BaseRef`
текущего candidate (Targeted только по diff ремонта), затем `PublishDevelop
-Replan <план> -ReplanQueueScope Frozen -FrozenRepair <id>@<head>`. Запуск
`Finish` пользователем является разрешением этого pin. Повтор после принятой
замены продолжает тот же pin без новой регистрации; после нового падения gate
цикл начинается с `Start`. Проверки, условия успеха и квалификация финального
дерева не меняются.

Проверка проходит вне общей блокировки. После успеха один Git CAS принимает
`base/head` задачи, `refs/itl/develop-candidate/head` и immutable membership blob
`refs/itl/develop-candidate/state`. При гонке регистрация пересобирает комбинацию;
существующий shard cache повторно использует только доказанно совпавшие входы.
Один исходный бюджет Targeted охватывает все попытки и дочерние проверки.
Отказ сохраняет исходную задачу, принятые refs и worktree кандидата с
`build/source-registration/checkpoint.json`; штатное продолжение — тот же
RegisterChange из исходной задачи с прежним QueueId. Новый вызов получает новый
бюджет, сохраняя доказательства прежних запусков. Отмена не удаляет принятую очередь.

Новые регистрации выбирают опубликованный develop supervisor. До публикации
нового владельца действует его прежний протокол; исходники задачи не получают
authority. Старый владелец может читать сохранённый интерфейс queue base/head;
его поздние записи включаются и проверяются следующим новым владельцем.
`Status.sourceCandidate` показывает `legacy`, `ready` или `requires-integration`;
это состояние интеграции, не доказательство квалификации выпуска.

`-CoverageContract` не нужен, если диапазон уже содержит изменённый Pester-тест.
Регистрация сама выполняет `Targeted` и только после успеха атомарно записывает
queue и candidate refs. Эти refs общие для worktree, но не
публикуются. `-Action Status` показывает компактную очередь, текущую фазу и три
последних запуска; `-StatusDetail Full` добавляет полные stage/test records
успешных/неуспешных gate из общего Git-каталога `.git/itl/runs` со временем по режимам.

## Implementation and registration batching

Choose implementation and registration boundaries by a finished behavior or
independently usable contract. Keep its connected producer, consumer, recovery,
documentation and tests in one reviewable unit. Do not register each intermediate
helper, schema or small correction separately merely to checkpoint progress;
a turn or context boundary is not a delivery boundary. Separate units only when
they are independently complete or the user requests separate delivery.

During implementation, use the smallest meaningful directly owned test selection
for changed behavior, a reproduced failure or an unresolved integration risk.
Group related edits before checking them; do not run tests mechanically after
each patch. Repeat passed checks only when their relevant inputs changed or new
evidence requires it.

Treat `Targeted` as a potentially expensive registration gate, not an intermediate
development check. Run it once through `RegisterChange` after the implementation
unit is complete; never pre-run it manually or start a broad gate merely because
a chat is ending. After a failure, diagnose and use focused regressions before
retrying registration. Keep the required final gates and their assertions intact.

Python source suites `Host*` prepare only their selected component's checkout-local
venv through `scripts/host-test-runtime.ps1`; tests use its absolute interpreter.
`ITL_SOURCE_TEST_PYTHON` selects bootstrap explicitly. `SPPR_TEST_PYTHON` is a
verified read-only isolated override. Owned missing dependencies repair through
the same component test; unknown runtime identity still disables proof reuse.
Scope and acceptance: [component environments](../openspec/changes/redesign-source-delivery/evidence/component-python-environments.md).

`MultiClientMcpOwnership` uses a private registry, distribution and local cache for
each test, including a cached-registry refresh failure. `OpenSpecCliRuntime` records
native command identity, PID/times, executable SHA, decimal/hex exit code and both
output streams. On failure it retains the exact Temp fixture and copies runtime
receipts and small workspace inputs to
`build/test-results/local/openspec-cli-failures/<id>/failure.json`. Follow the path
in the warning to investigate; a later passing run does not resolve the native
crash. Successful fixtures are removed through the same Temp boundary check.

For a new barrier, include the original task's agent-usable continuation in its
owned acceptance scenarios. Compare changed frequent paths against the same
before/after workload using existing timings; record context deltas separately.
Do not add a generic continuation gate or a metrics service. Reuse requirements
and publication channels below remain authoritative.

### Maintaining selection, cost and reuse

Implicit Full/Develop/Release Pester uses the catalog's
`pesterWorkers.qualificationImplicitDefault`, capped by available processors.
An explicit worker count remains authoritative; legacy catalogs retain their
previous choice. Implicit admission also accounts for physical and commit memory:
it allows one worker per available physical GiB, with 2 GiB commit headroom per
worker below 90% host commit usage (the remote runner's hard guard remains 92%). This
only limits this scheduler's children, never other owners or their locks;
an unavailable memory observation defers implicit admission. Plan uses the observed
limit, while execution reduces admission under pressure and restores it, up to
the configured limit, as memory becomes available again. The summary retains
the initial limit and actual peak concurrency. Below 256 MiB available physical
memory or without commit headroom it waits before starting parallel or serial
workers, then resumes automatically. Existing gate deadlines still apply; on
timeout free resources through their owner and repeat the same RegisterChange
with the same QueueId/checkpoint. No foreign process is stopped. Plan marks an
unknown resource wait separately; fully reused proof requires no worker admission.
The October 27 incident exceeded the remote runner's commit guard even with free
physical RAM; physical-only admission was insufficient. Neither guard is waived.
Private manifest continuation fixtures run alongside independent
files; real console/global boundaries remain serial. Ordering weights use observed
native file times, separately from hard deadlines. Plan reads its timing samples
from the existing bounded run index before filtering each stage; Targeted bursts
cannot displace qualification observations. Native scenario execution survives
the check-summary/raw-record/index boundary, so partial and composed coverage
cannot masquerade as a complete timing sample. Release estimates use executed
component wall time, never aggregate or reused-proof duration.

Cheap Release routing assertions run in the preflight cohort before expensive
native Pester files. The assertions and their contract/capability ownership are
preserved; real console/global tests remain serial. All synthetic plan/scope
fixtures use one helper to snapshot, clear and restore the three external artifact overrides so
Develop's actual archive/CFE/executable cannot replace fixture-owned bytes.

A support clone reads exact Pester proofs from its local origin, or repositories
listed by `git config --local --add itl.pesterProofSource <repository-root>`.
Sources must have verifiable common ancestry. No network lookup, recursive
discovery, foreign cache write or cleanup is performed. The current digest,
owner inventory, runtime/external witnesses, selected test, passed result and
manifest SHA checks still apply. Plan and results expose `proofSource`; a miss
executes the original test and saves only in the current common Git directory.
An older support baseline lacking these verifier capabilities must first acquire
them through normal source delivery; its live checkpoint is never rewritten.

Develop resolves journey ownership before requiring a stand. Without a supplied
stand, a plan with zero live journeys keeps complete Full/static checks and writes an explicit
`itl-workflow-develop-static-completion`, which cannot qualify Release E2E.
Selected live journeys and Release retain their stand, capsule and route proof
requirements. A supplied stand preserves existing route continuation for a
following Release instead of replacing its live proof with static completion.
Readiness receives the frozen candidate's `BaseRef` for encoding
checks instead of requiring an unrelated `origin/master` in a support clone;
an invalid explicit base remains a preflight failure.

For changes to test suites, selection rules or production/input dependencies,
acceptance includes selection, measured cost and reuse applicability, alongside
behavioral correctness. Use the existing selection plan, shard/check summaries
and relevant regressions; keep the result in the change's validation or existing
evidence. A new report format, service or broad gate is not required.

- Selection: identify the affected owner and the smallest meaningful test group.
  Prefer an existing behavioral contract. Keep unrelated components independently
  runnable; separate fast static checks from process/environment scenarios when
  they have different inputs. A catalog owner alone does not justify a mixed
  monolith, broad path wildcard or serial execution. Shared process/console
  restrictions need a concrete isolation dependency.
- Cost: inspect actual executed/reused files and the slowest groups from the
  required run. Compare an existing representative baseline when selection,
  execution order or frequent-path cost changes. Do not rerun unchanged checks
  merely to obtain timing. Explain material growth and retain the observation;
  `over-target` is an unresolved cost observation, not proof of meeting the target.
- Reuse: distinguish paths selecting tests from loaded dependencies invalidating
  their results. Keep all real child, fixture, runtime and external inputs bound;
  narrow unrelated invalidation without omitting dependencies. For changes to
  identity/cache/continuation, use an existing applicable regression to prove both
  unchanged-input reuse and changed-input rejection. If the parent/child or default
  artifact path changed, exercise that actual boundary with ordinary inputs;
  manually supplied overrides alone do not prove it works.

Cold execution and required invalidation are legitimate. Explain a surprising
cache miss before repeating an expensive journey; unknown inputs remain unsafe
for reuse. Unit/fixture proof is not live qualification. A change to this delivery
mechanism requires its applicable real warm/retry acceptance before claiming the
improvement is operational; ordinary features do not acquire an extra live gate.
Do not add duplicate tests or one test per helper just to satisfy this policy.

### Develop scenario coverage

`developJourneys.scenarios` in the existing quality catalog defines independent
coverage and ordered setup dependencies within `upgrade` and `fresh`.
`scenarioInputs` classifies changes to known runtime functions; top-level edits,
new/unknown functions, parse failures and unclassified inputs retain the complete
owned route. Selection and cache eligibility remain different decisions: absent
or invalid prior coverage requires an explicit first qualification, not a
synthetic pass or an exemption for the whole changed file.

The runner accepts `-Scenario` only with one journey and expands its required
setup. Omitting it runs the original complete lifecycle. Fresh verification,
stale export/recovery, refresh and close keep their original assertions and
workload. Verified export and close retain their fresh-check prerequisites.
A partial fresh run disposes its disposable branch through `delete-dev-branch`;
it does not claim a successful close or export. Unknown scenario identifiers,
missing required operations, branch-disposal failure and input drift never grant
proof. Fixture cleanup retains its existing owner and recovery policy.

Native summary schema 3 records executed coverage. An immutable execution-only
route schema 3 checkpoints its subset, including a separately run canary; it
cannot qualify a complete journey. Route report schema 2 composes
that execution with SHA-checked, applicable prior scenario evidence, after the
current candidate's complete static proof. The cache remains under the existing
`itl/develop-e2e-qualifications` owner. Native evidence and composed certificates
are immutable; warm reuse preserves the existing certificate and cannot refer
to itself. Repeated compositions reference the original scenario certificate
after rechecking direct input equivalence; they do not grow a chain of complete
reports. A full certificate still validates every required scenario. Copy-GC
retention/reporting changes use their current static owner proof; fixture
preparation and space admission remain native inputs. Scenario workload, source
inputs, stand/positive-stand facts, effective client selection, runtime, fork and
consumed physical artifact hashes bind reuse. Current binding admission always
checks all three physical files against the candidate lock. Fresh verification,
stale-export and close do not install or execute the broker: only these scenarios
can project out its hash, compiled root Go source and known release identity
fields. Install, branch, refresh, upgrade, whole-journey and unknown requests
retain the exact broker identity. Runner, builder, PowerShell consumers, transport,
platform, compatibility minimum, other artifacts and unknown fields remain bound.
Cold fresh bootstrap has no retained on-demand runtime directory. With the audited
bootstrap/runner bytes in both source snapshots, only the code after the exact
missing-directory return in `Assert-NoActiveCutoverRuntime` and its pure function
import may be projected out. The guard prefix, generation writer, unknown nodes
and top-level code still bind. Only `Get-ItlOnDemandRuntimeRecordFiles` is outside
fresh in the pure runtime-values library; its update callers remain exact for
upgrade. A closed reader-inventory regression runs under complete current static
proof. Changed consumers, import side effects, unknown scenarios or source/SHA
failures close the exception. No installed guard or native assertion is skipped.
For fresh verification, stale-export and close, the exact additive current-change
protection block has its own static owner. It only keeps additional paths and may
stop cleanup before deletion. The audited native caller catches optional cleanup
failure after the primary action; the pinned recipe never invokes explicit cleanup.
Project only that known block, with no ambient changePath use. Every other protection,
candidate/removal rule, unknown node and source SHA remains exact. Changed caller,
mandatory cleanup, unsafe/new block or unknown scenario closes the exception.
A separate cheap closed-reader inventory and the native retention regressions remain
in complete current static proof. This is not an exemption for the retention module.
The audited diagnostic-retention transition may also retain those three fresh
proofs: the pinned fresh recipe enrolls no diagnostic manifests; both exact
source versions return an empty cold plan. Existing-root/upgrade work, unknown
implementations, changed consumers and new enrollment remain outside this bridge.
The producer/CLI inventory is separate from the slower scenario regressions.
Shared verification planning in develop-configuration-rejection.ps1 is a fresh
input; only its three negative-fixture functions are upgrade-only. Its actual
shared assertions stay bound even when cleanup can reuse previous proof.
With authenticated disabled product context on every project/Develop/positive
target and no pending context operation, `Assert-ItlProductCatalog` is outside
native scenarios. Only that function is projected: shared catalog helpers,
unknown functions, top-level execution and binding admission stay exact. A
closed caller inventory and disabled-startup regression accompany current static
proof. Enabled, pending or unknown context retains native catalog qualification.
The linked `references/mcp.md` agent instruction is a static input; neither native
runner reads it. Unknown references keep conservative binding and historical
source SHA still authenticates this projection.
The main `1c-workflow/SKILL.md` content uses the same static boundary, with
authenticated prior/current file presence. Addition/removal remains conservative.
The explicit content-only set also includes `advanced-actions.md`, `artifact-retention.md`,
`init-setup.md`, `scoped-memory.md`, `verification-change.md`, `verification-result.md` and
`verification-suite-selection.md`: native callers print their links, while static
tests read their content. Unknown references retain native binding. Historical
source SHA authentication remains mandatory before every projection.
The fast skill retains exact native content: its contract marker and SHA are read.
The four declared product snapshot/publisher/initialization/application functions
may retain native proof only with known disabled context across all target roots
and no pending operation. Binding and settings readers remain exact inputs:
the updater calls binding admission even when context is disabled. Enabled/unknown
context, unknown functions and top-level execution remain bound.
The exact new broker still requires the real ondemand-mcp Release capability for
both backend families; Develop reuse cannot qualify its RPC behavior.
Artifact-repeat diagnostics identify each differing consumed artifact by name.
The broker-independent projection does not excuse a changed Vanessa archive,
client CFE, unknown artifact, positive environment or current artifact SHA.
Retained-launch cleanup is an internal broker RPC path. Develop lifecycle drain
does not supply `RetainedRuntimeState`. Its source projection excludes only the
closed `if ($retained)` block and its exclusive peer-ownership helper; registered
drain, parameter defaults, retained-mode admission, shared/new callers and all
other module code remain bound. An unknown AST shape closes this exception.
Selection and authenticated ancestor reuse share this projection. Static
regressions retain the exact caller set and reject shared-path changes; real
broker Release qualification remains responsible for the retained-launch case.
Current authenticated routing policy projects both source snapshots. Adding or
refining routing alone does not change a native assertion and therefore does not
invalidate existing proof. Known Pester policy, contract selection, fullPaths and
scenarioInputs are routing; authenticated source inventory, unknown fields and all
scenario operations/dependencies still bind. Removing a declared native input
does not remove its old inventory entry or authorize reuse with missing source.
Historical catalog LF/CRLF variants must match the recorded SHA before projection.
Go unit tests and README of the on-demand main package stay under static proof.
They do not select a native journey only with the audited runner/builder hashes
and no `go:embed` in compiled package source, on both historical/current snapshots.
Consumer drift, embedding, missing source or unknown paths close this exception.
After authenticating a cache input inventory, reject differing consumed hashes
before expensive report/source projection. Matching artifacts still require every
existing workload, provenance, static, environment and failure check.
The stateless client writer uses upgrade update and fresh install/branch as
native representatives alongside the current static preservation/PlanOnly/atomic
write tests. Other unchanged consumers may retain proof after those producers
pass, only with known disabled product context across all target roots and no
pending product operation. Unknown context, new ambient dependencies or unmapped
code retains conservative coverage.
An empty request and an explicit sole configured client have the same identity;
ambiguous selection and unknown identity fields disable this equivalence.

Legacy schema 1 means the original full journey, never a new partial execution.
Legacy proof is accepted only for its known coverage and authenticated equivalent
source/environment. A changed runner envelope or newly bound native input may
require one new baseline. Old receipts are not rewritten. An unselected journey
can only continue valid prior coverage; missing proof does not widen the route.
Newer applicable failures continue to reject reuse; scoped failures bind their
executed scenarios, while legacy failures retain conservative journey scope.

Plan lists each scenario as execution, setup or reuse with its evidence/rejection
reason and changed source functions or the conservative fallback cause.
Fork provenance retains its exact commit/tree. A different fork may reuse native
scenario proof only through `ai-rules-native-inputs.ps1`: both complete Git trees
must authenticate, the audited installer/readers must be unchanged, and differences
must be audited rule bodies with identical frontmatter and consumed UI-capability
signals, or the source-only validator. Reader inventory has its own cheap check.
Unknown files, layout/mode changes and changed consumers retain native execution.
Current exact fork Full and workflow static proof remain mandatory. Compatibility
also checks qualified-old init then current update for the affected clients,
matching changed payloads to current clean init and preserving user-owned files.
Only proofs actually selected for scenario reuse request that transition; requests
are deduplicated by old fork/client. Unselected historical forks add no probes.
The reader inventory binds all installed runtime scripts as reuse inputs without
claiming them as owners; unknown runtime paths retain the ownership failure.
Its SHA-addressed transition receipt is bound into Full and copied with static
cache/continuation proof. Plan may forecast pending static; execution never saves
that forecast as a pass. Original native reports and legacy fingerprints are not
rewritten; unavailable historical inputs select execution. Pester fork identity,
stand/runtime/artifact bindings and newer applicable failures remain strict.
Whole-journey timing samples are not estimates for a partial workload:
without an applicable measurement its duration is unknown. Keep hard deadlines
separate and use retained canary/warm evidence before claiming an operational
speedup. The regression matrix must exercise real candidate planning, checker
handoff, default binding and native-child launch counts, plus dependency and
tamper rejection. Never restore speed by dropping a negative assertion.
Budget and blocking authority remain those of the existing gate and architecture
policy; this section adds no runtime barrier or automatic performance threshold.

## Уровни проверки

| Режим | Когда | Цель | Hard limit |
|---|---|---:|---:|
| `Targeted` | регистрация одной доработки | 5 мин | 60 мин |
| `Smoke` | короткая проверка runner/catalog/delivery | 1 мин | 2 мин |
| `Full` | все изолированные Pester и fork compatibility | 10 мин | 70 мин |
| `Develop` | один Full и реальные стандартные journey | 25 мин | 220 мин |
| `Release` | только доказательства стабильной поставки после Develop | 60 мин | 284 мин |

Без параметров `check.ps1` запускает `Smoke`. Старый `Fast` временно является
deprecated alias для `Smoke`; в штатном процессе он не используется.
Публичный `PesterWorkers` по умолчанию остаётся равен `3`. Только неявный
`Targeted` использует объявленное каталогом значение `4`, ограниченное числом
логических процессоров; явно переданное значение и все остальные режимы не
изменяются. Оба summary сохраняют requested/explicit/effective worker count;
`effective` означает разрешённый предел sharded runner, а не число фактически
запущенных процессов. `Smoke` остаётся однопроцессным.
Hard limits учитывают наблюдения 2026-10-09: Targeted исчерпал 2100 секунд
после 50 прошедших файлов перед примерно восьмиминутным serial Compact;
Full исчерпал 2700 секунд, а продолжение завершило все 2745 проверок без
ошибок за ещё 642 секунды. Это составные наблюдения двух запусков, а не
измерение одного холодного прохода. Пределы 3600/4200 секунд дают запас к этим
наблюдениям; они не обещают длительность и не меняют целевые бюджеты,
timing weights, последовательность Compact или no-progress watchdog.

Tracked timings задают порядок запуска и округляются вверх от сохранённых
наблюдений; это не обещание длительности и не отдельный timeout.

В sharded runner выбранный `SourceDeliveryAdmission.Tests.ps1` завершается до
запуска дорогих parallel files. Его ошибка сохраняется в обычном summary/JUnit
и останавливает дальнейшее планирование; исправление продолжается той же
регистрацией. Это прежние четыре короткие проверки, выделенные из смешанного
файла очереди. Passed cache используется по прежним точным входам, без второго
запуска admission. Затем работают прежние parallel workers и serial tail;
исключения для console/process isolation и предел workers сохраняются.
`Targeted` получает изменённые пути через NUL-delimited Git output и
`tests/quality-contracts.json`. Неизвестный путь останавливает проверку и требует
назначить владельца — полного fallback-прогона нет.

Для точного `.agents/skills/1c-workflow/scripts/agent-1c.ps1` Targeted selection
schema v2 сравнивает baseline и current PowerShell AST. Common-plus-domain tests
может выбрать только literal `switch ($Action)` arm, явно внесённый в
`semanticTargeting.selectiveNodes` вместе с literal public-entrypoint probe из
owner test. Информационной привязки action к owner для этого недостаточно.
Любой недоказанный parameter/function/action, общий startup/dispatch/completion
код, `Action`/`ValidateSet`, метка arm, динамический или неизвестный узел,
rename, parse error и отсутствующий baseline выбирают полный `lifecycle`
contract. Full и Develop по-прежнему используют полный inventory.

Для трёх явно объявленных функций проверки в `semanticTargeting.libraries`
действует тот же AST-selector: `Invoke-DevBranchCheck`,
`Assert-VanessaVerificationPreflight`, `Get-ItlVanessaVerificationSelectionPlan`.
Каждая привязка перечисляет owner tests и literal public `check-dev-branch`
probe. Новый/удалённый callee, динамический вызов, смена member target,
необъявленная функция, общий код, inventory/порядок функций, rename, parse error
или отсутствие baseline сохраняют **все** прежние path contracts модуля.
`callsSha256` закрепляет проверенный набор вызовов: последующие правки после
расширения зависимостей также остаются широкими до ревью ownership и обновления
привязки, tests/probe и подписи в каталоге.
Безопасный широкий fallback не требует обновлять pin ради прохождения self-test;
валидные begin/process-only библиотеки также переходят в него без ошибки AST.
При rename проверяется и владелец нового пути. Только точный `R100` внутри того же
каталога `agent-1c.*.ps1` наследует прежние полные path contracts; неизвестное
внешнее назначение или изменённый новый модуль требуют обычного назначения owner.
Полные текущие module и entrypoint сохраняются в `additionalInputs` selection.
Их semantic-владельцы получают одинаковые полные входы в Targeted и Full;
независимые владельцы не наследуют чужой fallback. Неполный план отвергается; агент повторно создаёт его через
`resolve-targeted-tests.ps1` и продолжает исходную проверку.
`DevBranchCheck` содержит перенесённые без изменения случаев проверки cursor и
repair sequencing; прежние широкие выборки сохраняют их. Пилот подготовки
`WorkflowUpdateRollback` переиспользует только неизменяемый исторический текст и
скомпилированные определения внутри worker. Репозитории, commits, mutable
состояние и реальное воспроизведение missing receipt создаются для каждого случая.

Замер пилота 2026-10-24 (Windows PowerShell 5.1, Pester 5.8.0, fresh worker,
без reuse): WorkflowUpdateRollback — 84/84 до и после, 1013,199 → 1102,999 с;
внутри него 18 legacy-случаев — 596,529 → 560,543 с. Параллельная нагрузка
focused-проверок различалась, поэтому полное время не является чистым A/B.
Повторная подготовка исторического кода, 18 обращений с первой инициализацией:
22,457 → 1,055 с. AST-сравнение сохранило все исходные It/TestCases/assertions.
Для локальных правок трёх объявленных функций выбор файлов: 61 → 5, 39 → 4,
28 → 6, объединение 83 → 8. Холодный Targeted за пять минут этим не доказан.

Каждый дочерний этап имеет hard timeout, no-progress timeout, heartbeat и запись
длительности в `build/test-results/local/check-summary.json`. Там же сохраняются
целевой/hard бюджет и пять самых медленных стадий. Выход за цель виден как
`over-target`, а провал или выход за hard limit блокирует публикацию.
Release учитывает native-журналы основной ветки и `worktreePath` из того же
`release-e2e.json`, который читает запускатель: для каждого корня используется
его `project.logsPath` (по умолчанию `logs/1c`). Прогресс в посторонних ветках
не учитывается; no-progress 900 секунд и общий hard limit сохраняются.

`Targeted` и `Full` хранят каждый успешный Pester test-файл отдельно в
`.git/itl/pester-shards/v1`. Если файл падает, новые файлы больше не запускаются;
после исправления уже прошедшие файлы берутся из cache, выполнение начинается с
исправленного файла и продолжается дальше. Reuse возможен только при совпадении
самого test-файла, всех входов его контрактов, общих runner/locks и версий
PowerShell/Pester. Внешняя identity входит только для test-файлов, явно
перечисленных в `pesterExternalInputs`; смена controlled fork или Vanessa build
не сбрасывает не связанные с ними шарды. Неизвестный владелец теста отключает
кэш для шарда. Общий catalog-derived semantic binding включает полный entrypoint
и libraries для всех тестов их fallback/function/common владельцев независимо
от режима проверки. Неизвестные supplemental inputs остаются обязательными;
неполная или неизвестная semantic-схема отключает reuse. Поэтому semantic routing
не принимает proof другой версии полного входа, а независимый тест сохраняет
одинаковый digest в смешанном Targeted и Full. Провальные результаты не кэшируются.
Из этих двух переменных дочерний процесс получает только объявленные входы;
scheduler восстанавливает собственное окружение после каждого запуска.
Proof до изоляции окружения не соответствует `external-input-scope=declared-v1`
и не переиспользуется, в том числе через старые lookup keys.
Предел параллельных worker принадлежит scheduler и не входит в fingerprint:
изолированный дочерний тест не получает его. Targeted с четырьмя worker и
Full с тремя используют один proof при совпадении остальных входов. Старые
ключи для пределов 1–4 проверяются по заново рассчитанным полным owner inputs
и прежним SHA manifest/result/JUnit, затем сохраняются под общим ключом.
Неизвестный owner или отсутствующая обязательная reuse dependency по-прежнему
запрещают reuse. Это совместимость исходного кэша, без переноса live E2E proof.

Full schema 4 хранит actual child/OS/Pester identity и полный per-file input
manifest scheduler. Whole-Pester reuse требует совпадения этого manifest с
новым расчётом того же scheduler, включая external inputs; версия модуля в
родительском процессе не заменяет эту проверку. Старые Full records читаются,
но без manifest не разрешают whole shortcut. Unknown/nonreusable inputs или
изменение runtime во время теста оставляют текущий результат `passed` с
`reusable=false`. Cache/compatibility transport сохраняет этот факт; checker
продолжает обычным scheduler, переиспользуя подходящие shards и исполняя остальные.
Release после свежего static gate повторно валидирует прежние Develop routes
и только затем обновляет их Full binding. Runtime/stand, newer-failure, SHA,
dirty-state и E2E obligations сохраняются. Ручной дополнительный Full не нужен.

`reuseInputPaths` контракта добавляет загружаемые зависимости только в digest
его test-файлов и не расширяет выбор `Targeted` по `paths`. Контракт нативной
сборки учитывает весь набор модулей хелпера и зависимостей guard. Отсутствующий
вход отключает reuse; некорректные шаблоны отклоняет владелец каталога.

Нативный расчёт и оценка времени находятся в `scripts/delivery-native-plan.ps1`.
Supervisor с явным custom gate возвращает его план до загрузки этого модуля и
Develop qualification. Поэтому native planner/qualification не входят в digest
frozen publication, integrity, registration и recovery fixtures с подставным gate.
Их прежние проверки очереди, SHA, rollback и настоящего supervisor сохраняются.
Нативный планировщик проверяют SourceDeliveryPlan и SourceDeliveryIncremental;
регрессия PesterShardIdentity подтверждает настоящий cache hit после его изменения
и обязательный повтор после изменения orchestration. После изменения самого
разделения первый прогон затронутых fixture suites остаётся обязательным.

Исправление самого теста или gate-harness не сбрасывает уже доказанные более
ранние возможности. `tests/quality-contracts.json` объявляет пять continuation
scope: `static`, `deliveryPostGate`, `gate`, `develop`, `release`. Между
ancestor-кандидатом и новым
commit все изменённые пути должны целиком принадлежать этим scope, а новый
commit/tree должен иметь точный прошедший `Targeted` с неизменённым tracked state.
Тогда Full/Develop evidence накладывается на этот Targeted и выполнение
продолжается с первого затронутого этапа. Неизвестный или не объявленный в continuation scope runtime-путь,
отсутствующий/повреждённый Targeted record и изменение Develop-harness для
Develop proof закрывают reuse. Это продолжение по fingerprint входов, а не
эвристика «любой файл из tests безопасен».

Для отдельного Develop journey точный Targeted может заменить полная static
квалификация **текущего** commit/tree, выполненная штатным checker. При совпадении
всего source inventory этого journey, baseline/stand, fork, runtime, среды и SHA
артефактов ранний fail-fast откладывается до static; без подходящего proof
сохраняется обычный native прогон. Writer сохраняет неизменяемые Full/JUnit
байты, continuation привязывает их SHA, reader перепроверяет их вместе с
текущими входами и более новыми падениями. Это не разрешение переиспользовать
Pester pack с `reusable=false`: неизвестные и nonreusable shards выполняются
обычным scheduler. Общий Full/Release continuation по scope по-прежнему требует
Targeted; исключение принадлежит только Develop journey с полным совпадением
его входов. Незавершённый static probe не записывается как пройденный этап.

Fresh не включает upgrade-only `develop-configuration-rejection.ps1`, в том
числе во вложенной identity положительного seed. Общие harness/fixture/runtime
и фактическое состояние этого seed остаются входами fresh. Старые fingerprints
не переписываются: новый контракт может потребовать один холодный прогон.
Квитанции `qualificationFixtures.*.workflowUpdateAdmission` проверяет Capture
перед каждым gate; они не входят в journey fingerprint. Дескрипторы капсул
(включая path/SHA), прочие и неизвестные поля конфигурации остаются входами.
В `release` явно включён один уже проверяемый managed-input:
`.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1`.
Для него сохраняются полная source lineage и точный passed Targeted. Изменение
модуля выбирает `fresh` через владельца `mcp-hosts`, поэтому целый Develop proof
не продолжается поверх старого live результата; полный journey fingerprint также
изменяется. Release сохраняет лишь этапы с совпадающими workload inputs, а
затронутый ondemand выполняет заново. Соседние runtime-пути не включаются этим
исключением и не получают continuation по имени каталога.

`static` также включает только Markdown исходных change-артефактов
`openspec/changes/*/*.md`: обновление test-plan и сохранённых выводов приёмки
само по себе не меняет установленный runtime и не требует повторять live journeys.
Этот scope не включает соседние executable, YAML или JSON; точный прошедший
Targeted, проверка hash доказательств и запрет reuse для неизвестных путей
сохраняются.

## Клиент unattended E2E

Client MCP retains two distinct proofs when runtime helpers change without a
component source change. The original `candidate.provenance.json` remains
immutable and binds the CFE to its hash-pinned corresponding-source ZIP. Run
`scripts/build-client-mcp-patched.ps1 -RetainedCandidateDirectory <old-folder>
-OutputDirectory <new-folder>` from the clean candidate to obtain a separate
`candidate.native-qualification.json`: the producer checks the historical
ancestor, every archived source byte (including ConfigDumpInfo), and both asset
hashes; loads the retained CFE in its private service base; runs all three native
checks with current helpers; and restores/releases the base. The finalizer
requires the exact current helper inventory/hashes and successful native proof
bound to the unchanged original receipt and assets. This does not replace live
Release qualification of the exact CFE or permit rewriting historical receipts,
ignoring dump-index changes, or changing published assets.

`source-delivery.ps1`, `check.ps1` и оба `invoke-*-e2e.ps1` принимают
необязательный `-AgentTarget`. Без него E2E явно выбирает единственного клиента
из `.agent-1c/project.json.aiRules.tools` конкретного вызываемого корня, включая
серверный стенд. Если клиентов несколько, повторите ту же команду с конкретным
параметром, например `-AgentTarget kilocode`. Membership и установленное
подключение проверяет обычный helper; конфигурация и ambient guard не меняются.
Fresh journey после bootstrap продолжает с уже установленным `kilocode`.
Владелец fresh journey удерживает штатный Git worktree lock от создания ветки
до её закрытия, включая промежутки между lifecycle-командами. Cleanup проверяет
этот lock и доступность всех файлов базы, включая `1Cv8.lgf`, до изменения Git и списка баз: занятая
копия сохраняется с предупреждением, независимая поставка продолжается.
После выхода владельца повторяется штатный cleanup. Terminal-путь освобождает
только собственный lock; после аварийного завершения сначала проверяются
записанный fresh-прогон и отсутствие его процессов, затем агент снимает точный
Git worktree lock и повторяет cleanup. Чужой lock не снимается.
Старый закреплённый supervisor без этого параметра сообщает
`DELIVERY_E2E_CLIENT_OPTION_UNSUPPORTED`: сначала публикуется source-only поддержка
через прежний канал, затем повторяется исходная явная команда. Только для такой
публикации поддержки параметр можно опустить на проверенном стенде с одним
подходящим клиентом; authority и явный выбор не подменяются.
Выбор клиента и конфигурация клиентов стенда входят в существующие идентификаторы
плана, qualification и Release cache; другой клиент не наследует их proof.

## Публикация develop

### Инкрементальность и защита от замедления

External-runtime Pester files use per-file runtime profiles rather than a
blanket non-reuse list. The existing scheduler observes profiles in its selected
Desktop child and verifies matching before/after witnesses from the actual
worker. Missing identity, changed bytes at the same path, changed configuration,
or an older receipt without the witness executes the original file without
qualifying reuse. Native assertions and scenario selection are unchanged.
The adapter applies only to mapped files: ordinary workers and their existing
shared input keys stay unchanged. Plan uses the same read-only observation and
cache admission; it never installs or repairs a runtime.

Profiles cover Git binaries/configuration and the relevant published ancestor,
Windows/CLR inputs, OneScript engine/libraries, Node executable/DLLs, isolated
Python bootstrap and complete per-component venv/package bytes, and the local
pinned Go compiler plus offline source closure from `go list`. Unknown Node/OneScript search paths, Go overlays/CGo or
missing modules fail closed for reuse. Custom Python startup/search hooks and
Git path/execution overrides, conditional configuration or external hook/attribute paths
also disable reuse; the original checks remain executable. The noninteractive
`GIT_PAGER=cat` host setting is ignored consistently by Git, ancestor and inventory
identity, so it neither disables nor splits an otherwise identical proof. Go observation disables
downloads.
Source stdlib-only venv creation uses `-I -S` so global Python site plugins are
not unobserved inputs. BookStack/SPPR keep their original direct package tests:
measured full environment observation costs more than executing those tests.
HostSourceRuntime intentionally creates fresh environments from unpinned package
constraints and also executes. Each exception reports its concrete reason.
The bounded parent probe retains atomic completed rows if another profile times
out; unfinished identity remains unknown and cannot admit reuse. A slow profile
cannot discard already qualified inputs of unrelated files.


Static ETA uses the current full Pester inventory's read-only cache lookup:
the same owner digests, observed child runtime, legacy lookup, manifest/JUnit
SHA and selected-test checks as execution. It reports execute/reuse counts,
mandatory external-runtime repeats, the ten most expensive misses and changed
owner inputs. PlanOnly never launches test workers, provisions downloads,
restores or promotes qualification. Execution revalidates proof; a preview
cannot authorize reuse.

The estimate schedules only cache misses with the normal preflight/parallel/
serial barriers and catalog timing weights. Historical non-Pester overhead is
combined with Pester through max for parallel compatibility, not a sum.
Fixture capture is charged only when the plan selects E2E or Release.
Unknown historical overhead remains unknown; the hard deadline is never an ETA.
Weights are advisory observations, not a guarantee for a changed workload.
Parallel stages record process exit duration separately from delayed collection.
ETA prefers these native timings; old enclosing intervals are explicitly marked
as legacy upper bounds until a measured sample exists.

Pester reuse keys describe the actual child PowerShell/Pester executable and
module bytes, independently of the parent's shell version. Input ownership,
wildcard matches are resolved once per invocation against its fixed inventory.
Each digest still checks file existence and authenticates dirty/unindexed bytes;
changing catalog/inventory/root resets the transient selection cache. Missing
ownership/required inputs, unknown runtime, failed or altered proof still prevent
reuse. External-runtime files additionally require
qualified per-file profiles and matching witnesses from the original worker;
unknown inputs execute without reusable proof. The package
and fresh dependency workloads retain native execution for the reasons above.



Малый diff сам по себе не доказывает малый риск. Но количество изменённых
файлов также не разрешает выбирать все live journeys. Один контракт
`scripts/develop-journey-inputs.ps1` используется и маршрутизатором, и проверкой
reuse: изменения только явно перечисленных update/recovery функций, параметров
и закрытых условных веток не требуют повторять `fresh`. Оставшийся код файла
сравнивается через PowerShell AST/tokens. Изменение общего кода, неизвестной
функции, else/elseif, отсутствие baseline или ошибка разбора сохраняют широкий
маршрут. Update/recovery по-прежнему выбирает `upgrade`; специальные recovery
сценарии проверяются своими регрессиями, а не подменяются обычным happy path.

Изолированные `tests/pester/*.Tests.ps1` выбирают свои static-проверки, включая
тесты, явно перечисленные в runtime-контрактах. Они не выбирают live E2E;
в смешанном diff маршрутизация сохраняется для изменённого runtime. Добавление
такого test path в существующий контракт не инвалидирует native receipt.
В `invoke-develop-e2e.ps1` изменения только `Get-BranchWorktree`,
`Set-FreshConfigurationComment` и закрытого блока `fresh` не выбирают `upgrade`.
Общие вызовы этих функций, неизвестный код, else/elseif и ошибки разбора
сохраняют консервативный маршрут. `develop-configuration-rejection.ps1`
относится только к `upgrade`; негативный и позитивный стенды внутри этого
journey остаются обязательными и проверяют разные условия.

Исходные E2E receipts не переписываются при уточнении отбора. Старый schema-2
proof допускает continuation только после проверки его исходного SHA, Git blob
bytes, неизменной применимой части исходников, полного окружения и артефактов,
source lineage и текущего Targeted/static proof. Identity положительного стенда
также проверяется; более поздний применимый сбой запрещает старый успех.
Изменение одного hard timeout меняет immutable plan, но не workload acceptance.
AST-проекция применяет тот же LF/CRLF-контракт PowerShell, что и input hash,
включая многострочные токены. BOM, значимые разделители команд, native artifacts
и 1С transport не нормализуются этим уточнением.
Исторический `commit:path` читается с явным завершением revision-аргументов
Git (`--`): проверка одноимённого filesystem path в глубоком checkout не должна
превращать unchanged input в ложный cache miss.

Planner получает тот же SHA-проверяемый artifact binding, что checker. Его поиск
выполняется только в явных overrides и известных локальных cache paths; Plan
не провиженит этот source cache и не собирает EXE. Отдельный component preflight
опубликованного владельца по-прежнему скачивает remote assets для проверки SHA;
это время входит в полный CLI, но не в `planningDurationMs` расчёта DAG.
При недоступном binding reuse остаётся
неподтверждённым до обычного readiness, который готовит и проверяет артефакты.
Общий Vanessa cache использует имя `<sha256>-<assetName>`; поиск проверяет его
по полному SHA, сохраняя совместимость с прежним непредфиксным именем. Ошибка
override не заменяется другим файлом. При неполном binding диагностика называет
именно отсутствующий artifact, а не первый неустановленный process override.
Поиск CFE использует штатный `ITL/artifacts/vanessa-mcp-clientMcp/<version>/<sha>/<assetName>`,
а EXE — `ITL/MCP/ondemand/<version>/<sha>/<assetName>`, включая настроенные
корни владельцев cache. Каждый файл сверяется с SHA lock, override не допускает
fallback. Поиск вынесен в `source-e2e-artifact-discovery.ps1`: его изменение
выбирает только planner/incremental regressions, без SourceQualificationFixture
и Release orchestration. Исторические receipts со старой функцией в stand-модуле
сохраняют прежнюю строгую AST-проекцию; остальной stand contract и появление
общего caller по-прежнему выбирают native journey.
Каждый выбранный native stage содержит advisory `reuseDiagnostics`: причина
отклонения старого proof, его commit и изменившиеся source paths/external keys.
Значения окружения не выводятся; список ограничен восемью receipts и двенадцатью
именами на receipt с явным числом опущенных имён. Checker записывает эти причины
в reason этапа перед дорогим запуском. Отсутствие binding, повреждение SHA,
изменение входов, неподтверждённая lineage/static и более поздний применимый сбой
различаются. Диагностика не участвует в immutable plan identity и не разрешает reuse.

`executedBudgetSeconds` — сумма предельных таймаутов, а не прогноз.
Сквозная матрица `SourceDeliveryIncremental.Tests.ps1` имеет отдельный Pester
shard. Её зависимости от actual lifecycle/journey sources не сбрасывают proof
остальных тестов `SourceDeliveryPlan.Tests.ps1`; это проверяется реальным
расчётом shard digest в регрессии каталога. Общие fixtures принадлежат одному
`SourceDeliveryPlan.TestSupport.ps1`, без нового runner или gate.
На 2026-10-23 native scheduler выполнил десять incremental/default-boundary
сценариев за 94,59 с против 62,83 с прежних семи: добавлены discovery-only,
shared-stand и реальный legacy-Plan → candidate-calculator процесс. Ordering
weight — 100 с, deadline не расширен. Остальные 32 planner-теста заняли 48,18 с.
Разбор retained Targeted `955db4d114fb4513b2cfd5efb49db1cc` (29:45, 43 executed,
0 reused) показал поздние тяжёлые группы: SourceQualificationFixture — 341 с
при default ordering weight 1 с, Replan — 338 с при weight 57 с,
DevelopE2EQualification — 284 с при weight 33 с, RefCleanup — 304 с при 200 с.
Ordering weights исправлены по этим наблюдениям: тяжёлые независимые файлы
заполняют первые parallel slots, serial admission и hard deadlines сохранены.
Перенос discovery один раз затрагивает прежний stand owner; следующие изменения
его отдельного файла выбирают ровно два связанных shard, что закреплено регрессией.
После пакетного wildcard matching 34 planner-сценария заняли 28,50 с,
11 incremental-сценариев — 48,36 с (native default-path/shim fixtures).
Эти измерения относятся к изолированным fixtures, без запуска 1С или публикации;
операционное улучшение отдельно проверяется обычным и warm/retry `Plan`.

`timeEstimate` отдельно показывает advisory median последних пяти успешных
наблюдений этапа, число samples и неизвестные этапы. Для static используется
объединение временных интервалов его проверок: параллельные Pester/compatibility
не считаются дважды, live E2E не входит в static. Reused этапу не начисляется
повторный live runtime. При отсутствии подходящих timing records, в том числе
при недоступном hot index, прогноз остаётся неизвестным. Hard limits, approval
долгого плана и watchdog не ослабляются ради короткой оценки.

Для команды публикации `gateEstimatedSeconds` — только сумма основных gates.
`estimatedSeconds` остаётся неизвестным при ненулевом `unmeasuredPreparation`:
подготовка/проверка капсул, предварительный compatibility Full для pending fork,
очистка и remote finalization не должны исчезать из прогноза. Уже завершённая
подготовка отражается отдельно в `preparationSpentSeconds`, не как оставшееся время.
Например, в расследовании 2026-10-26 за пределами основных gates оказались
184794 мс позднего readiness, 1182225 мс обновления десяти веток, 367350 мс
двух Capture и 381265 мс отклонённого ResumePlan; preliminary Full занял
1493606 мс. Это наблюдения конкретного запуска, а не норматив будущей публикации.

Будущий PublishDevelop готовит стенд через штатные recovery/update-workflow/Capture
до финального расчёта и сохранения execution fingerprints. Rollout ограничен
двумя зарегистрированными ветками immutable капсул Release/Develop: checker
связывает обе с общим master до запуска любого journey. Контекстные ссылки на
квитанции других веток не добавляют эти ветки в область записи. Список корней и
source commit сохраняется в lifecycle receipt; retry не расширяет его. Capture
сохраняет исходную капсулу и проверяет всю цепочку workflow-only переходов,
backup, конфигурацию, окружение, business bytes и SHA базы. Автоматический
Recapture и создание новой baseline запрещены. Обычный update-workflow без
scope сохраняет rollout всех зарегистрированных development-веток.
Read-only Plan показывает требуемую подготовку; при ожидаемом изменении стенда
возвращает `resumable=false` и continuation для PublishDevelop без ResumePlan.
Publisher затем фиксирует окончательный план и запрашивает его обычное long-plan
approval. После фиксации automatic preparation повторно не запускается: дрейф
входов по-прежнему блокирует ResumePlan, исходный план и proof сохраняются.
Успешная best-effort pre-operation уборка переиспользуется только при ResumePlan
того же checkpoint. Legacy/неполная уборка и новый план выполняют её заново;
актуальные operation locks, process/lease guards, gates и post-operation уборка
сохраняются. Текущая публикация продолжает использовать прежний supervisor.

Изменение planner/checker, маршрутизации или reuse должно сохранять регрессии
обоих направлений: изолированная recovery-доработка не запускает `fresh`, общий
runtime его выбирает; старый неизменный proof переиспользуется, а изменённые
окружение, workload, SHA или более поздний сбой запрещают reuse. Проверять
передачу binding через planner и обязательный текущий static proof, а не только
каждый helper отдельно. Static публикации сохраняет полный inventory с
переиспользованием неизменных Pester-шардов; новый gate или полный повтор
требует конкретной изменившейся зависимости, а не конца работы над задачей.

`source-delivery.ps1` является bootstrap-shim. Для `Plan` и `PublishDevelop` он
закрепляет уже опубликованный `refs/remotes/origin/develop`, для публикации в
`master` — `refs/remotes/origin/master`, создаёт detached worktree и передаёт
управление supervisor этого канала. Supervisor один владеет
очередью, immutable plan, evidence, checkpoint, resource ledger и push; код
кандидата запускается отдельным процессом и может только выполнить актуальные
проверки. Отсутствие опубликованного develop-supervisor блокирует обычные `Plan`
и `PublishDevelop`; candidate-копия не подставляется. Исключение — явно заданный
подменный `-GateScript` для изолированного процессного fixture. Одноразовый
bootstrap-режим остаётся и для master-канала до появления supervisor.

Отбор, fingerprints и advisory ETA рассчитываются функциями закреплённого
кандидата в дочерней области видимости. Supervisor проверяет чистоту и точные
commit/tree/base/channel, результат identity и SHA calculator до сохранения;
calculator commit/SHA входят в plan identity. `Plan`, Develop и master delivery
используют один этот вызов. Запись, approval, очередь, checkpoint и push остаются
у опубликованного владельца; старые планы без calculator сохраняют свой decoder.
Если опубликованный supervisor ещё не умеет делегировать расчёт, стандартный
`Plan` один раз загружает его read-only readers и реконструирует кандидат через
его же queue/preflight functions, затем один раз вызывает candidate calculator.
Возвращаемый preview имеет `resumable=false` и не сохраняется. Существующие
immutable legacy plans/proof не меняются и старый calculator не запускается.
Мост применяется только к стандартному модулю с accepted-candidate readers;
непрозрачные и более старые supervisor выполняют свой исходный `Plan`.
Публикация продолжает использовать опубликованного владельца и его протокол;
preview не даёт права использовать новый decoder для старого checkpoint.
После публикации поддержки обычный Plan сразу использует candidate calculator.
Wildcard inventory сопоставляется пакетно с однажды созданными PowerShell
WildcardPattern; grammar, case rules, порядок, unknown-owner и все хэши сохранены.
Это сокращает повторные вызовы script-функций на каждый file × pattern, а не
уменьшает инвентарь или пределы проверок.
Planner валидирует каталог один раз до внутреннего отбора; самостоятельный
router сохраняет свою обязательную валидацию. Source inventory снимается один
раз для journey и его positive stand, а mutable stand/environment читаются
независимо при каждом вызове. Большие token streams имеют stateless-ускоритель,
тип которого закреплён SHA реализации; при недоступном компиляторе остаётся
исходный PowerShell путь. Регрессия сравнивает оба результата, включая Unicode,
here-strings, comments и statement separators. Профиль того же кандидата:
31,785 → 28,116 с; шесть source projections — 7,634 → 2,881 с.

Incremental-регрессия читает настоящий каталог: изменение его bytes выбирает её
и сбрасывает её proof. Custom-gate frozen/historical fixtures не копируют и не
исполняют discovery-модуль. Реальный расчёт per-file digest подтверждает, что
изменение поиска сбрасывает planner/incremental, сохраняя эти process proofs.

`Status` не является исполняющим supervisor: read-only вызов использует файл из
текущего checkout без создания worktree. Поэтому диагностика выводит две разные
identity: `statusReader` — коммит прочитанного кода,
`developAuthoritySupervisor` и `masterAuthoritySupervisor` — опубликованные
коммиты соответствующих каналов. Совместимые `authoritySupervisor` и
`supervisor` остаются master-identity; для `PublishDevelop` смотреть именно
`developAuthoritySupervisor`. `cleanupPolicy` отдельно показывает каналы
исполнения очистки.

Перед дорогим запуском маршрут можно получить без публикации:

```powershell
.\scripts\source-delivery.ps1 -Action Plan -RequireRelease
```

Plan хранится в `.git/itl/plans/v1/<planId>.json` и содержит DAG со статусами
`execute`, `reuse` и `blocked`, fingerprints входов, зависимости и бюджеты.
Статическая Develop qualification остаётся привязанной к текущему дереву.
Для живых `upgrade`/`fresh` planner и checker используют один полный fingerprint
входов конкретного journey. Квалифицированный предок допускает продолжение лишь
при доказанной source lineage, полном NUL delta, точном passed Targeted,
совпадении runtime/package/contract, среды, стенда, клиента, fork и разрешённых
artifacts, а также проверенном SHA исходного evidence. Release-only budget не
входит в Develop contract projection; изменение входов самого journey требует
execution. Старые записи без восстановимых внешних bindings и неизвестные входы
сохраняют exact-tree fallback. Более новый известный failed journey не заменяется
старым успехом. Исходный report сохраняет прежние commit/tree/result и bytes;
текущая combined qualification связывает continuation provenance с текущим
кандидатом и static proof. Старый опубликованный supervisor может консервативно
планировать execute; candidate checker всё равно проверяет эти условия. Release
capability сохраняет независимый fingerprint.
Неизвестный путь создаёт blocker `QUALITY_OWNER_MISSING`; автоматического Full
fallback нет. Повтор публикации может закрепить identity через
`-ResumePlan <planId>`. Shim при таком продолжении загружает supervisor, который
записан в immutable plan, и принимает его только как предка опубликованного
tip того же authority-канала. Старые планы без поля канала сохраняют master
authority, если их supervisor предок `origin/master`; иначе для
`PublishDevelop` принимается только предок `origin/develop`. Новый plan без
`-ResumePlan` использует текущий опубликованный tip выбранного канала.
Старый supervisor, умеющий публиковать только Vanessa ZIP без парного CFE,
блокируется entrypoint до запуска сохранённого плана; очередь остаётся на месте,
и требуется новый plan от опубликованного develop-supervisor.
Если сумма выполняемых стадий больше 60 минут, нужно явно
передать `-ApproveLongPlan <planId>`. `Plan` выполняет тот же read-only preflight
owned components, что и публикация, поэтому автоматическое повышение до Release
из-за отсутствующего immutable asset уже входит в сохранённый `planId`.
Исправление delivery/test harness меняет его собственный static proof, но не
fingerprint независимой runtime capability.
Component preflight не хранит булево «нужен Release»: он возвращает минимальный
набор `requiredReleaseCapabilities`, plan добавляет их dependency closure и
включает точный упорядоченный список в `planId`. Для отсутствующего
`itl-ondemand-mcp` это только `ondemand-mcp`; для Vanessa — `extension-smoke`
и его зависимость `config-cadence`. Явный `-RequireRelease` выбирает весь каталог.
`verification-refresh` и `result-cleanup` всегда свежие, когда они выбраны.

Delivery-бюджеты: planning — предупреждение после 120 секунд, жёсткий предел 300 секунд; Develop static — 70 минут; Develop
`upgrade` — 90 минут, `fresh` — 60 минут; Release использует отдельный hard budget
из `scripts/release-e2e/stages.json` для каждой capability. Этот бюджет включает
как основное доказательство, так и обязательную очистку принадлежащих stage
ресурсов. Timeout не расширяет маршрут и не удаляет checkpoint.

Превышение цели planning выдаёт предупреждение и сохраняет пригодность плана.
После разбиения E2E на девять сценариев и расширения inventory расчёты заняли
126 и 151 секунду: прежний жёсткий предел 120 секунд отклонял готовый план.
Теперь 120 секунд — предупреждение; общий контракт planning и вложенного static
preview допускает до 300 секунд, не увеличивая бюджеты проверок или 1С.
После превышения жёсткого предела диагностируйте стоимость расчёта и повторите ту же
команду Plan или публикации; очередь и checkpoint сохраняются. Уже начатый
план использует закреплённую версию supervisor и её прежние ограничения.

При известной полной journey identity planner использует только её fingerprint;
legacy route fingerprint рассчитывается лишь при недоступности полной identity.
Неизвестные входы по-прежнему запрещают ancestor reuse.

Planner разрешает authoritative каталог stage evidence один раз в пределах
расчёта, затем отдельно читает каждую запись и проверяет SHA её proof. Это не
кэш результатов и не перенос доказательств между репозиториями. На исходном
кандидате перехода шесть повторных `git rev-parse --git-common-dir` занимали
6,1 секунды суммарно; устранение пяти лишних вызовов сохраняет цель 30 секунд,
fingerprints и правила reuse. Смена корня и повреждённый proof проверяются
регрессией владельца planner.

Checker и planner получают journey hard budget через один stateless getter из
`developJourneys.routes.<journey>.hardSeconds` в `tests/quality-contracts.json`.
У старых catalog без этого поля остаются 1200/2100 секунд; заданное невалидное
значение отклоняется. Общий Develop hard budget — 13200 секунд, сумма static
4200 + upgrade 5400 + fresh 3600. Upgrade включает исходный негативный стенд
и отдельную успешную цепочку, когда они объявлены ниже. В прогоне r42 одно
обновление заняло около 800 секунд, затем проверка конфигурации около 600 секунд.
Полная загрузка с проверками и rollback на парном стенде заняла 1034 секунды:
прежние 1200 секунд не покрывают даже негативный сценарий. Новый предел покрывает
обе последовательные проверки; он не увеличивает фактическую работу обычного
стенда и не превращает timeout в успешное доказательство. Остальные deadline, no-progress и проверки
не изменяются.

Увеличение fresh основано на исходном cold journey кандидата `ce08d78a`,
остановленном через 2100 секунд во время after-CheckConfig. Между запуском before-CheckConfig и следующей загрузкой прошло около 482 секунд
(08:51:12–08:59:14 МСК), включая завершение и передачу guard;
snapshot, load, strict module checks, after-CheckConfig и прежний обязательный
verification/export/refresh/cleanup хвост входят в тот же budget. 3600 секунд —
оценка для полного неизменного маршрута, а не измеренная длительность нового
успешного journey. Baseline не переносится между информационными базами,
проверки и условия успеха сохраняются.

```powershell
.\scripts\source-delivery.ps1 -Action PublishDevelop `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r31-codechecker-logic `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
```

Команду запускают в foreground с внешним timeout, покрывающим одобренный plan и
запас на сборку кандидата, push и удалённую сверку. Не следует выбирать timeout
до получения plan: маршрут дороже часа всё равно остановится без явного
`-ApproveLongPlan`.

Полный Pester inventory использует hard budget из таблицы выше. Каталог
`pester-shards` входит в progress fingerprint, поэтому
лимит не скрывает зависание: отсутствие новых worker/result-артефактов по-прежнему
останавливает стадию отдельным no-progress watchdog.

Оркестратор атомарно создаёт общий для worktree delivery-operation lock и
публикует его через `Status` вместе с owner/gate PID. Если внешняя оболочка
прервана, но gate жив, повторный Publish/Release блокируется. После завершения
осиротевшего gate следующий запуск архивирует operation, восстанавливает запись
run history и exact-tree qualification, а затем продолжает обычную безопасную
сборку кандидата. Lock и status вручную не удаляются и не редактируются.

Pester-тест, который разбирает stdout/JSON или локализованный текст дочернего
PowerShell, обязан использовать `Invoke-TestPowerShellFile` и его UTF-8
`stdout`/`stderr`. Нативный pipeline-захват такого вывода запрещён: кодировка
меняется, когда worker сам запущен с перенаправленным выводом.

Оркестратор получает свежий `origin/develop`, строит временного кандидата из
локального `develop` и только зарегистрированных диапазонов, передаёт исходный
remote HEAD как границу `Develop`, выполняет обычный fast-forward push без force
и сверяет удалённый SHA/tree. Конфликт, сдвиг remote или ошибка gate сохраняют
очередь.

Если exact candidate содержит новый controlled-fork lock со статусом `pending`,
`PublishDevelop` сначала выполняет `Full` для этого дерева, evidence-backed
promoter меняет только `templates/dependency-lock.json` на `passed` и создаёт
обычный дочерний promotion commit, после чего `Develop` проверяет уже финальное
дерево. Только этот installable commit допускается к component finalizer и push;
промежуточный workflow commit с `pending` никогда не попадает в remote. Promotion
commit и локальный ref входят в durable checkpoint: повтор после сбоя финального
gate восстанавливает их и не повторяет preliminary `Develop` или promoter.
Любой другой непрошедший compatibility status закрыто блокирует публикацию.

Если необходима полная Release-проверка независимо от недостающих owned assets,
к той же команде добавляется `-RequireRelease`. Это не флаг сохранения `master`:
`PublishDevelop` никогда его не обновляет. Без флага отсутствующие owned assets
автоматически выбирают только свои Release capabilities с зависимостями. При
выбранных Release-стадиях оркестратор выполняет `Develop` и `Release` на одном
временном commit и делает единственный push лишь после двух успехов. Ошибка
любой стадии не двигает remote и не очищает очередь.
Release runner требует живую исходную базу `SOURCE_INFOBASE_PATH/1Cv8.1CD`
для `seed-parallel` и полного каталога, включающего этот сценарий. Выборочные
`config-cadence`, `extension-smoke` и `ondemand-mcp` используют восстановленную
базу ветки и замороженное дерево master; фабрика не достраивает для них вторую
базу и не меняет капсулу. Во всех scope путь источника остаётся внутри стенда;
Recovery-only требует исходную базу только при незавершённом восстановлении;
отсутствующий, recovered или completed recovery остаётся no-op без записи checkpoint.
До долгого `Develop` тот же кандидат проходит read-only Release readiness, если
план выбрал Release capabilities. Она проверяет точный стенд, fixture и SHA
checkpoint snapshots. Readiness и runner используют один read-only контракт
scope/identity/client/HEAD/workflow transition и stage-input eligibility: отчёт
различает reuse, rerun и rejected. Runner повторно проверяет актуальные входы
перед своими прежними mutations; restore, checkpoint write, rebind и evidence
import остаются у него. При изменении source commit/tree отсутствие
source-continuation proof запрещает reuse,
но само по себе не блокирует допустимый полный rerun.
При том же source общий SHA helper/runner не заменяет workload fingerprint:
reuse всё равно требует точных входов этапа и прежних проверок identity и SHA. Неподтверждённый transition
отклоняется до Develop с существующим continuation, без записи нового состояния.
Чистая принадлежащая Release-ветка без checkpoint может быть обновлена
runner-ом из master, если master ещё не входит в её историю. Повреждённый
checkpoint, чужая или грязная ветка блокируют gate до запуска 1С.
При повторе того же exact-tree кандидата прошедший `Develop` берётся из
qualification cache, поэтому после ошибки `Release` он не запускается заново.
Подготовка Release fixture и Develop upgrade используют один
`source-e2e-manifest-repair.ps1` для единственного конфликта `.ai-rules.json`.
Обработчик сверяет точную операцию (`refresh-dev-branch` или
`refresh-dev-branch-lite`), pending-транзакцию, родителей и стадии индекса,
затем проверяет provenance через установленного владельца. Он сохраняет
совместимый контекст OpenSpec и повторяет ту же команду один раз. Исходная
ошибка остаётся в журнале; merge commit и переход состояния выполняет lifecycle
helper. Неизвестные изменения, чужая операция или неуспешное продолжение
сохраняют отказ. Capsule, workload и qualification claim этим ремонтом не меняются.
Фабрика сохраняет прежний вызов `Invoke-SourceFixtureInstalledAction`; точный
refresh с branch/target и бюджетом 5400 секунд направляет его диспетчер в общий
обработчик. Дочерние вызовы с `AllowFailure` проходят к единственному владельцу
native process напрямую. Это позволяет объединить опубликованную поддержку
с замороженным кандидатом, уже выбравшим lite refresh; другие действия, опции
и бюджеты не получают автоматического ремонта.
Успешный `Develop` уже включает exact-tree Full/static proof: отдельный `Full`
для того же дерева не запускается.

`PublishDevelop` атомарно хранит цепочку `candidate-built -> develop-qualified ->
release-qualified -> component-finalized -> remote-pushed`. Retry начинает с
первой незавершённой фазы; сбой finalizer/push не повторяет gate. Новая identity
кандидата/gate создаёт новую цепочку. После 60 минут новый этап не стартует. Два
одинаковых сбоя блокируют третий; повтор после диагностики требует
`-RetryBlockedStage`. Scope `deliveryPostGate` включает только delivery control
plane, покрытый собственными source-delivery regression-тестами. Qualification
хранится по stage/input fingerprint, поэтому исправление control plane не
сбрасывает независимые Develop/Release capability proofs; изменившийся runtime
или stage-модуль инвалидирует только свои стадии и downstream dependencies.

Успешный JSON явно различает каналы поставки: для `PublishDevelop` это
`developPublished=true`, `dependenciesInstallable=true`, `masterReleased=false`
и фактический `aiRulesCompatibility`; только `PromoteRelease` или `ReleaseMaster` возвращает
`masterReleased=true`. Поэтому слово «опубликовать» без указания stable/master
означает полностью устанавливаемый `origin/develop`, но не релиз в `master`.

Перед gate команда строит exact-candidate plan для всех owned release surfaces:
controlled `ai_rules_1c`, patched Vanessa Automation и `itl-ondemand-mcp`.
Supervisor перечисляет собственные прямые assets из lock кандидата; незнакомый
asset в том же GitHub repository блокирует публикацию до внедрения его
финализатора в опубликованный supervisor. Для нового способа поставки сначала
публикуется совместимый supervisor, затем lock с новым требованием. Перед push,
в том числе при продолжении после `component-finalized`, каждый обязательный
URL перечитывается и сверяется с SHA lock: локальный архив или старое evidence
не подтверждают удалённую устанавливаемость.
После прерванного push та же сверка по lock опубликованного commit обязательна
перед очисткой очереди и ответом `dependenciesInstallable=true`.
Совпавшие remote identities проверяются без мутации; отсутствующий rules branch/tag
публикуется после Develop из явного clean `-AiRulesSource`, а отсутствующий Vanessa
или on-demand asset автоматически добавляет в тот же запуск только требуемые
Release capabilities. Для Vanessa это `extension-smoke` с `config-cadence`, для
`itl-ondemand-mcp` — `ondemand-mcp`; явный `-RequireRelease` по-прежнему означает
полную Release-проверку. Частичный релиз Vanessa можно завершить под прежним
аннотированным тегом без смены версии, если lock commit тега совпадает с lock
кандидата для ZIP и отдельного `VAExtension` по URL, имени и SHA. Отсутствующий
CFE извлекается из проверенного опубликованного ZIP, затем оба прямых URL
проверяются повторно. Конфликтующие refs или байты закрыто блокируют
публикацию. Внешние npm, PyPI и ROCTUP остаются только lock-проверяемыми
upstream-зависимостями; `PublishDevelop` их не публикует. Для `client_mcp`
прежний внешний pin остаётся допустимым. Owned pin требует одновременно CFE
и corresponding-source ZIP; missing asset выбирает существующую capability
`ondemand-mcp`, а exact native build provenance, полный Gate 6 и live Vanessa
доказываются для тех же байтов. Сначала отдельно публикуется поддержка finalizer
в authority channel; только следующий candidate вводит owned URLs в lock.
Если накопленная migration queue уже требует Gate 6, который отвергает прежний
внешний CFE, support-only candidate готовится от опубликованного baseline в
отдельном clone/common Git с собственной очередью. Его обычный PublishDevelop
не включает миграцию и не изменяет исходную очередь. После публикации поддержки
исходная очередь интегрируется с новым baseline через штатного владельца.
Локальный `VANESSA_MCP_CLIENT_CFE_PATH` подаёт exact SHA candidate до публикации
и не подтверждает устанавливаемость URL. Подробности сборки:
[controlled client_mcp](../third-party/client-mcp/v0.6.5-itl-r1/REBUILD.md).

Develop состоит из двух независимо квалифицируемых journey через публичные
поверхности workflow:

- обновление установленного N-1 стенда через `update-workflow`;
- refresh активной ветки, реальный `/itl-check`/Vanessa и экспорт результата;
- свежий bootstrap и `init-project` в коротком disposable-пути;
- `new-dev-branch`, минимальная конфигурационная правка и application feature;
- check, stale-result boundary через изменение feature без повторной загрузки
  конфигурации в Designer, recovery check, result, `refresh-dev-branch-lite`,
  повторный check и close.

Fresh получает источник настроенного init/close из отдельного qualification
target; `SOURCE_INFOBASE_PATH` указывает на его восстановленную базу. После close
тот же владелец Capture подтверждает неизменность исходного seed без Recapture.
При отказе сохраняются снимок и диагностика; сначала исправляется изоляция или
выясняется внешнее изменение seed, затем применяется явное продолжение Capture.

Если readiness потребовал обновить workflow самого seed, завершённые обновления
можно признать командой `scripts/source-e2e-fixture.ps1 -Action Capture -Phase
Develop -ProjectRoot <seed> -AcknowledgeWorkflowUpdate -OutputPath <receipt.json>`
(для Release повторить с соответствующей фазой). Capture проверяет точную
цепочку receipts владельца update-workflow, Git и сохранённые SHA. Capsule/DT,
опубликованный N-1 baseline, данные, pending/cursor/Designer state и context
не меняются. Обычный Capture повторно проверяет признанную цепочку; новый
workflow-update требует нового явного признания. Чужой коммит, изменённый backup,
данные или семантическое состояние продолжают блокировать квалификацию.
Флаг требует существующую capsule и несовместим с Recapture. После признания
повторяется исходная квалификация через её сохранённый план.

Для отдельно согласованного повтора из сохранённого снимка, когда raw seed
недоступен, source factory допускает явный `-Action Prepare -Phase Develop`
с `-CapsulePath`, `-CapsuleSha256` и положительным `-DatabaseBudgetBytes`.
Он проверяет все artifacts, source project, phase и опубликованный N-1 baseline,
затем создаёт новый owned target прежними clone/context/native restore owners.
Бюджет базы задаётся консервативно по измерениям, не заменяется нулём при
отсутствующем файле; capacity failure продолжает тот же explicit Prepare.
В claim фиксируются `sourceAdmission=sealed-capsule` и declared capacity basis.
Этот путь доказывает повтор на exact DT/source/context, но не currentness
недоступного оригинала. Обычный live-seed admission, Capture и Release остаются
строгими; автоматического fallback в PublishDevelop/Release нет. Capsule,
старый seed и failed copies сохраняются; recovery не является Recapture.

После upgrade/fresh Develop освобождает только производные `1Cv8.1CD` своего
qualification target, в том числе после неудачного первого RestoreIB. Сюда входит
только его локальный `project/.agent-1c/branch-seed/<sourceKey>/infobase/1Cv8.1CD`:
ready-манифест должен точно связывать ключ и путь, а существующие writer intent
и write lease кэша берутся до удаления любых баз. Чужой/занятый кэш сохраняется
с диагностикой; внешние cache roots и пользовательские project infobases
не очищаются. Манифесты кэша сохраняются. Его
candidate claim, общий Git, точные пути, per-infobase guard и эксклюзивный
файловый handle обязательны. Исходный seed, capsule/DT, исходники, pending/cursor
и журналы сохраняются; Release target продолжает жить по своему checkpoint.
Занятая база сохраняется с предупреждением и записанной командой продолжения
`dispose-upgrade-fixture` или `dispose-fresh-source-fixture`; очистка не подменяет
результат исходного journey.

Ошибки прикладной конфигурации не требуется исправлять ради выпуска workflow.
Если стенд воспроизводит известный отказ Gate6, в его ignored
`.agent-1c/release-e2e.json` задают `developConfigurationRejection` с полями
`sourcePath` (путь `src/cf/...`), `sourceSha256`, `diagnostic` (полная точная
диагностика) и `positiveProjectRoot` (отдельный согласованный установленный стенд).
Исходный файл, рабочая нагрузка и Designer-cursor негативного стенда сохраняются.
Новая ветка с доверенным baseline старых находок не эквивалентна отказавшей.
Full не отменяет правила legacy-baseline. Для helper с публичным `ResultPurpose`
runner сначала вызывает `check-dev-branch -ResultPurpose production -ConfigLoadMode Full`
на исходном pending-состоянии. Проверка должна отказать именно на объявленном
finding; затем обычный development-refresh обязан пройти. Старые helper без
этого параметра сохраняют прежний негативный refresh с `ConfigLoadMode Full`.
Полная загрузка не позволяет совпавшему fingerprint копии базы пропустить
воспроизведение; проверки и восстановление принадлежат прежнему владельцу.
Иной отказ или неожиданное успешное выполнение негативной операции проваливает
сценарий. Для принятия отказа нужны текущие
хешированные native log/result и журнал восстановления, подтверждённые DT/cursor
rollback, отсутствие попытки UpdateDBCfg, завершённые native операции и
сохранённое продолжение refresh. Exact finding сверяется с хешированным native
log, а не с сокращённым summary. Дополнительные diagnostics/legacy-context
artifacts допускаются только по точным путям и SHA из receipt; неизвестное
добавление отвергается. Receipt — диагностический артефакт владельца
загрузки, не новое разрешение или состояние recovery.
Он передаётся через стандартный `resultPath` terminal run-status и compact
artifacts, включая reexec; console marker остаётся диагностическим выводом.

Если прежний stand worktree нужно сохранить как доказательство, его абсолютный
путь добавляют в необязательный массив `preserveWorktreePaths` того же
`release-e2e.json`. Владелец E2E-очистки сохраняет эти worktrees, их ветки,
pending state и файлы; остальные stale-фикстуры проверяются и очищаются как прежде.

Develop upgrade и подготовка Release-копии сначала вызывают установленный
`update-workflow`. Только свежий terminal status того же compact run с
`UI_TESTING_POLICY_LEGACY_SNAPSHOT` или `VERIFICATION_MODEL_POLICY_LEGACY_SNAPSHOT`,
тем же project root и exact candidate допускает одно продолжение через
`scripts/update-installed-workflow.ps1 -Recovery update -AgentTarget <тот же клиент>`.
Оно использует оставшийся исходный бюджет. Исходный отказ и оба native журнала
сохраняются; обычный source-side updater остаётся единственным владельцем
snapshot/receipt, resume, rollback и rollout. Постороннее, неоднозначное или
устаревшее свидетельство, отказ продолжения и исчерпанный бюджет сохраняют отказ
E2E. Exact installed commit, неизменность workload и все последующие lifecycle
проверки остаются обязательными; исходный N-1 путь не заменяется pre-update.

После негативного исхода E2E обязательно выполняет обычный успешный `upgrade`
на `positiveProjectRoot`: update, refresh, fresh passed check, экспорт и чистый
tracked state. Этот стенд имеет собственный `release-e2e.json` с отдельными
Develop/Release ветками и не объявляет негативного исхода. Его исходники,
настройки, клиенты и runtime входят в proof identity; обе части отчёта связаны
с тем же candidate commit/tree. Отказ исходного refresh остаётся отказом в
публичном API, не даёт fresh passed или разрешения на экспорт. Настройка
негативного стенда без положительного доказательства не квалифицирует выпуск.
Fresh journey также берёт исходную базу и настройки с согласованного стенда,
сохраняя прежние шаги, Unicode-путь, stale-result и recovery проверки. Ошибка
исходной конфигурации продолжает обязательно воспроизводиться в upgrade.

Qualification `develop.json` связывает точный tree с SHA статического Full и
live-отчётов. Каталог владельцев сопоставляет диапазон `origin/develop...HEAD`
с `upgrade` и `fresh`; изменение самой оркестрации включает обе journey, а
неизвестный путь блокируется до назначения owner. Изменения, не входящие
в установленный lifecycle (например standalone MCP host), могут продолжить
незатронутые доказательства базового `develop` только при совпадении полного
input identity. Отсутствующая или несовместимая baseline qualification требует
доказательства недостающих сценариев выбранного маршрута. Невыбранная journey
без пригодного доказательства требует явной квалификации baseline; маршрут
самостоятельно не расширяется.

Маршруты различают наблюдаемое поведение: update/controlled-rules владельцы идут
в `upgrade`, init/dependency/lifecycle/MCP владельцы — в `fresh`, а общие
download/refresh/Vanessa границы — в обе journey. Source-delivery, документация,
standalone host и прямые тесты не запускают live 1C journey. Если план пуст,
точный Full плюс owner Targeted образуют явное `no-develop-journey-route`
доказательство; искусственная baseline двух journey не требуется. Сама
orchestration закрыто выбирает обе journey; неизвестный путь никогда не
расширяет маршрут автоматически.

## Controlled fork и Full

Новый fork lock сначала имеет `compatibilityStatus=pending`. Его может
квалифицировать только `Full`/`Develop` с явным clean annotated-tag checkout:

Targeted Pester shards that include bootstrap update coverage resolve the
locked Vanessa source-build archive automatically: first from any worktree in
the common Git directory, then from a shared SHA-addressed cache, and finally
from the immutable locked URL. Every source is accepted only after the lock
SHA-256 matches; an invalid explicit environment path fails closed.

```powershell
.\scripts\check.ps1 -Mode Full -AiRulesSource D:\Git\itl_ai_rules_1c-r31-codechecker-logic
```

В нормальной поставке этот Full запускает `PublishDevelop`, затем
`scripts/promote-ai-rules-compatibility.ps1` сверяет exact HEAD/tree и fork
qualification, меняет только status/timestamp, а оркестратор создаёт promotion
commit и запускает финальный Develop. Прямой promoter оставлен для
контролируемого recovery; его результат нельзя публиковать без финальной
квалификации. Обычный не-promotion Full и Release требуют
`compatibilityStatus=passed`.

## Единое продвижение develop и master

Если одна поставка должна опубликовать непустую очередь сразу в оба канала,
используется одна операция:

```powershell
.\scripts\source-delivery.ps1 -Action PromoteRelease `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r31-codechecker-logic `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
```

Она строит один exact candidate, выполняет `Develop` и `Release`, публикует его в
`develop`, затем выпускает то же дерево в `master`. Перед дорогими gate проходят
installability, owned-component plan и read-only finalizer preflight. Второй
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

Срок хранения крупных recovery payloads и read-only предпросмотр ручной уборки:
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
  -AiRulesSource D:\Git\itl_ai_rules_1c-r31-codechecker-logic `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
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
immutable planId. Bind the continuation to it with `-ResumePlan` and, when the
existing long-plan guard requires it, `-ApproveLongPlan`. The already authorized,
unchanged workload does not require renewed user approval.

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
# Qualification copy storage

Source-only Develop copy disposal, capacity checks and owned disk112 recovery:
[source-qualification-storage.md](source-qualification-storage.md).
