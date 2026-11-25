# Живое продолжение остановленного lifecycle после обновления workflow

Стенд изолирован от реальных проектов и общего Release-стенда PM5. Он создан
из опубликованного r33 fixture `build/parallel-r33-old-2d3`: отдельный Git root
`build/paused-refresh-1ef38ccdcfef4d43b7cb7816d5d86ad9`, worktree
`build/paused-refresh-1ef38ccdcfef4d43b7cb7816d5d86ad9-ветка проверки` и две
локальные копии прежней маленькой Gate 6 файловой ИБ. Пути содержат кириллицу
и пробелы. Shared PM5 `D:/Git/itl-workflow-e2e-pm5` не обновляется.

Исходная Gate 6 ИБ сохранена: SHA-256 `1Cv8.1CD`
`d5d5eab06b94c81d01bb7750c3a632d5238a133275ccd5c68d57a5a38d99f5a4`.
Authoritative seed создан публичным r33 `sync-master`;
`build/paused-refresh-seed-r33.log`. Ошибка первого fixture (готовая branch ИБ
до создания seed) сохранена в диагностике; существующая копия перемещена в
проверенную область того же disposable root, затем seed создан обычным owner.
Ни lifecycle state, ни Git lock вручную не исправлялись.

## Подтверждённый старый дефект перед продолжением

Публичный `initialize-dev-branch-runtime` дошёл до `launcher-registered`,
но PowerShell 7.6.5 не смог прочитать существующий event-log cursor. Это
сохранённый настоящий failed-init checkpoint, а не вручную придуманное
состояние (`build/paused-refresh-initialize-owner-r33.log`). JSON содержал
`2026-09-30T15:59:01.1861975Z`. Новый `ConvertFrom-Json` возвращает `DateTime`;
приведение к `string` даёт `09/30/2026 15:59:01`, а `TryParse` с `ru-RU` это
отвергает. Повтор через Windows PowerShell остановился раньше на отсутствии
`Get-FileHash` при branch-local MCP setup; обе диагностики сохранены.

Исправлен существующий `Read-DevBranchEventLogCursorInfo`: `DateTime` сохраняется
без промежуточного форматирования; `DateTimeOffset` сохраняет UTC instant;
старые ISO строки читаются с invariant culture и `RoundtripKind`.
Недопустимый timestamp по-прежнему вызывает ошибку, файл cursor не меняется.
Это совместимость чтения существующего owner, без нового recovery runtime.

Адресная проверка `DevBranchLifecycle.Tests.ps1`: четыре теста passed за 4,32 с
(`build/event-log-cursor-roundtrip.xml`): настоящий ISO JSON roundtrip при
`ru-RU`, старый строковый cursor, invalid rejection с сохранением bytes и
существующая проверка actual event-log tail. Отдельный DateTimeOffset regression
passed за 2,78 с (`build/event-log-cursor-offset.xml`). Старый installed helper
не патчится: получение исправления должно пройти обычный `update-workflow`.

Исходные HEAD, index hash, .dev.env/MCP/configuration hashes, cursor и полный
failed-init checkpoint сохранены в
`build/paused-refresh-before-stopped-init-update.json`.

## Публичное обновление остановленного init

Source B1: private clean commit `705be6564fa4c513de1a772917291f1367818cd6`,
snapshot `188262d479a05adf3bda20c8fea4b68256b6a20a`; fork ee9/r37 canary.
Публичный source wrapper обновил main и штатно выполнил rollout ветки с
`launcher-registered`. Terminal exit 0: main
`165fe46d37022646dee8e111119a91762b889b61`, branch
`e532a6f53386fdc7adedab6662027390d5406e6d`;
`build/paused-refresh-update-stopped-init-b1-pm5-profile.log`.

Два дополнительных отказа сохранены. Первоначальный fixture ошибочно указывал
`baseConfigurationVersion=StandaloneGate6`: это неподдерживаемая настройка
installed workflow, который принимает PM4/PM5. Post-copy snapshot остался
`post-copy-failed`; ни receipt, ни состояние не исправлялись вручную. Повтор
той же команды с официальным process override `BASE_CONFIGURATION_VERSION=PM5`
завершил этот checkpoint. После completion только fixture metadata исправлена
обычными tracked commits `69876e3524e0e2e5ab6493ae8b729ba4b5f1887d` и
`4f0d9860e9501ad9b276c0f688b0d45ac66fdf15`. Поддержка продукта не расширялась.

Optional `agent-browser doctor` завис на своём Chrome `--version`. UI owner
проверил PID, время создания, parent chain и exact executable десяти созданных
процессов и остановил только этот probe существующим safety owner;
`build/ui-owned-doctor-stop.json`. Исходный update после этого завершился.
Это ограничение B1: успех файлового обновления не доказывает здоровую установку
UI tools без исправления bounded command execution.

`build/paused-refresh-stopped-init-update-acceptance.json` подтверждает сохранение
failed-init checkpoint, error, cursor/baseline и всех трёх `src/cf` файлов.
Все 25 существовавших branch dotenv keys сохранили значения; добавлены только
11 закреплённых Vanessa artifact/default settings. MCP сохранил branch root и
старые families; writer обновил broker 0.4.9→0.4.15, Vanessa catalog и добавил
UI endpoint. Изменение управляемых contributions не является копированием
соединения из main. После старта исходного init изменились только ожидаемый
active-context timestamp и порядок intact UI block; их реконструкция лишь в
памяти совпала с точными SHA сохранённого after-update capture.

Own main source copy сохранила исходный SHA `d5d5eab0…`;
authoritative seed и branch copy сохранили записанный seed SHA
`5ba84c220d17eb20321699ea064e8b3385b83ab7ae4b46d68a92924f79e4ee75`.
Source copy и производный seed изначально имеют разные native file bytes;
сравнивать source copy с seed как одинаковые файлы было ошибкой probe oracle.
Каждый сравнивается со своим неизменным исходным input.

Shared original Gate 6 `1Cv8.1CD` тем временем законно изменился от параллельных
DT restore/apply другого Gate 6 owner; это не наш update. Исходный before SHA
сохранён, текущий drift `074583af…` отражён в after capture со ссылками на
`build/gate6-negative-d429b95232f34ff9b41d7fa6eb9a259c` и
`build/gate6-negative-91262e1df8fc41dd87869934b3ce4a55`. Заявления о неизменности
shared original после этих операций нет.

## Исходное продолжение и границы tiny fixture

Повтор первоначального `initialize-dev-branch-runtime` новым installed helper
успешно прочитал тот же cursor и дошёл до guarded Enterprise normalization;
`build/paused-refresh-initialize-resume-b1.log`. Затем выяснилась вторая
непригодность tiny fixture для полного PM5 init: штатная ITL proof EPF вызывает
BSP `ОбновлениеИнформационнойБазы` и `ОбновлениеИнформационнойБазыСлужебный`,
которых минимальная конфигурация не содержит. Owned 1C launch исчерпал 900-секундный
deadline и вернул `ITL_ENTERPRISE_AUTO_UPDATE_PROOF_MISSING`; checkpoint и
диагностика сохранены, вручную `ready`/result не создавались, BSP не подделывался.

Таким образом, tiny fixture квалифицирует файловое обновление реально
остановленной операции и переход через исправленный cursor; полного успеха
original PM5 init она не доказывает. Для завершения 9.6/9.7/10.4 используется
отдельный representative PM5 fixture из уже существующего immutable seed,
без запуска или обновления shared stand. Задачи здесь пока не закрыты.

В tool invocation, фиксировавшем tiny fixture metadata, был выведен
`fatal: '$GIT_DIR' too big`. Первоначальная обвязка не сохранила exit code
каждого read, поэтому точная исходная команда не установлена и этот вывод
не объявляется здоровой проверкой. Сам `git add/commit` проверял exit code.
Последующая read-only сверка тех же полных путей сохранена в
`build/paused-refresh-transient-git-review.json`: все восемь отдельных read
вызовов завершились с exit 0, оба NUL-delimited diff выполнены с exit 0,
оба уже существующих commit изменили только `.agent-1c/project.json`.
Успешные commit не повторялись, пути не сокращались. Сверка подтверждает
их реальные tree effects, но не объясняет первоначальный transient отказ.

## Representative PM5: независимый source и исходный отказ

`build/representative-pm5-refresh-canary.json` описывает новый r33 fixture
`paused-pm5-12b12430b91c4c06b71ac2722c5215c2`: отдельный main на C,
штатный Git worktree `itldev/paused-pm5` на D с пробелами и кириллицей,
собственная source infobase на E с пробелами и кириллицей. Shared PM5 main
`D:\Git\itl-workflow-e2e-pm5` и его рабочие ветки не запускались и не обновлялись.
CF скопирована из проверенного master `fb3ae31b…`: 19 286 файлов,
663 558 539 байт, каждый исходный и целевой файл проверен по SHA.

Источник базы — готовый immutable file seed shared stand, 3 347 070 976 байт,
SHA `13329259999ff6fd31ed0cbed26f49e9bb6a2e8a63b5a9079252f725737b32df`.
Копирование держало writer-exclusive source handle; SHA источника до/после
совпала с копией. Seed fingerprint `v2|git-tree-sha256|a7ff319d…` совпал
с CF inventory. Повторная сверка shared master/CF после копирования подтвердила
отсутствие движения source. Old ready/manual-confirm state не переносилась.

Original r33 `sync-master` на собственной source завершился с exit 0;
`build/representative-pm5-seed-r33.log`, собственный seed source key
`554a4281a35aacd223e999077d11ccbcd63b50c19c8e1e98e322c52a8696ab52`,
sync id `58f49417303a4247bbb483d9059503ba`. Original
`initialize-dev-branch-runtime` на собственной новой branch base завершился
с exit 1 на том же дефекте `Event log cursor capturedAt is invalid`;
`build/representative-pm5-initialize-r33.log`, status `launcher-registered`.
Ни cursor, ни status вручную не исправлялись. Дальнейший stopped rollout
и исходное продолжение ещё должны подтвердить полную живую приёмку.

Public B2 update создал clean main commit
`efc00402e75a9b5e5d99b7a76f5279799e994894`, но штатно сохранил blocked
child rollout с exit 1: `WORKFLOW_UPDATE_RULES_USER_MODIFIED: AGENTS.md`;
`build/representative-pm5-update-stopped-init-b2.log`.
Диагноз `build/representative-pm5-agents-newline-block.json` доказал ровно
Git newline transport: authoritative installed r33 root имел CRLF, 13 524
байта, SHA `e6e475e1…`, совпадающий с `installedHash`; новый Git worktree
получил LF, 13 391 байт, SHA `d3b40529…`. Strict UTF-8 текст после замены
CRLF→LF совпал полностью, пользовательских добавок нет. Managed root,
manifest и failed-init checkpoint вручную не менялись.

Source owner исправлен только в двух root hash checks:
`Get-AiRulesManifestUserModifiedPaths` и `Assert-WorkflowUpdateRulesRootReady`
используют уже существующий `Test-AiRulesFileMatchesInstalledHash`.
Его контракт сохраняет BOM и отвергает invalid UTF-8/control bytes;
допускается только доказанная LF/CRLF-equivalent версия recorded hash.
В `SourceUpgradeHandoff.Tests.ps1` реальный Git worktree reproducer сначала
упал 0/1 (`build/agents-newline-before.xml`), после fix прошли 4/4 за 4,42 с
(`build/agents-newline-after.xml`), включая прежний negative user-policy edit
и новый invalid UTF-8 negative с неизменными bytes/manifest. B2 snapshot
не заменён исправленным содержимым задним числом.

## Pinned B2 recovery: сохранённый отказ native Git

Public B4 executor со штатным process source override на immutable B2
прошёл root preflight и branch post-copy, затем остановился с exit 1:
`WORKFLOW_UPDATE_BRANCH_POST_COPY_INCOMPLETE`, внутренний native Git start
ошибочно сообщает `StandardOutputEncoding is only supported when standard
output is redirected`. Branch snapshot
`itl-workflow-update-rollback-6f15293247f1440589b661cddeb69488` сохранил
`post-copy-failed`. Ни source candidate B2, ни его completed main capsule
не заменялись. Исходные и диагностические повторы сохранены:
`build/representative-pm5-b2-child-recovery-b4-executor.log`,
`build/representative-pm5-b2-child-recovery-b4-traced.log`,
`build/representative-pm5-b2-child-recovery-b4-command-traced.log`.

Ошибка повторилась в public owner; свежие read-only getter/pipeline/context
пробы на тех же полных путях проходят. Parent debugger breakpoints не дали
фактический failing call trace; это ограничение диагностики, а не доказанный
успех. В PowerShell 7.6.5 native start fallback способен маскировать исходную
Win32 ошибку encoding exception; для этого стенда причина первого start
отказа ещё не установлена.

Узкий source prototype `Get-GitPathListAt` использует существующий
`Invoke-ItlNativeProcessCapture` с explicit UTF-8 stdout/stderr, NUL данными,
shared quoting и `UseShellExecute=false`. Core all-Git/guards не менялись.
Сохранён PowerShell caller CWD contract: существующий filesystem location,
иначе наследование process CWD; authoritative repository остаётся `-C Root`.
Новая диагностика показывает executable, command, реальный CWD/его fallback,
исходный Win32 code или реальный Git exit/stderr. Unit acceptance: 4/4 за 4,64 с
(`build/git-path-native-capture-after.xml`) и 2/2 за 2,39 с
(`build/git-path-native-failure-after.xml`), с real Unicode NUL stdout,
Unicode native stderr/exit 128, vanished caller location success и actual
missing executable Win32 failure без shell fallback.

Первоначальное ожидание отказа при deleted caller location было неверным:
старый PowerShell корректно наследует process CWD. Сохранён rejected probe
`build/git-path-native-start-before.xml`; его отказ не объявляется дефектом
workflow. Исправленная проверка сохраняет исходное successful fallback
поведение. Prototype пока не квалифицирован original public continuation;
сам по себе этот targeted proof не закрывает 9.6/9.7/10.4.

В повторном fork installer также сохранены warnings о восьми legacy Codex
`opsx-*` artifacts. Они не удалялись вручную и не объявлены разрешёнными;
их exact mapping/hash и native OpenSpec readiness нужно проверить через owner.

## Установленная причина public Git start: Windows argv limit

Тот же public continuation с clean B5 executor
`657ee4d912bf3470855775a3380fdf726e233174` и прежним immutable B2 candidate
завершился exit 1. Explicit native capture раскрыл исходный Win32 error 206:
длина командной строки `ls-files --stage -z --` с полным managed literal
path set составляет 32 841 символ. Executable — штатный
`C:\Program Files\Git\cmd\git.exe`, caller CWD существует. Причина прежнего
encoding exception теперь установлена: PowerShell fallback маскировал
отказ запуска слишком длинной команды. Unicode/space roots не сокращались.

Полная исходная диагностика сохранена до дальнейшей правки:
`build/representative-pm5-b5-native-206-reason.txt`; публичный лог —
`build/representative-pm5-b2-child-recovery-b5-executor.log`, machine receipt —
`.agent-1c/snapshots/workflow-update-rollout.json` собственного main.
Main B2 HEAD остаётся `efc00402e75a9b5e5d99b7a76f5279799e994894`, тот же
branch rollback checkpoint сохранил `post-copy-failed`. Native capture
доказал корректность диагностики; original lifecycle acceptance остаётся
открытой до успешного повторения исходной команды.

Owning caller — `New-WorkflowBranchCommitPlan`; соседние `add`, index checks,
`diff` и `reset` в plan/apply передают тот же полный literal path set через
argv. Исправление только первого `ls-files` оставило бы следующие команды
уязвимыми. Для owner-local bounded batching требуется сохранить полный
write-set, точные NUL данные, неизменный пользовательский index и запрет
частичного плана при ошибке любой пачки.

Source owner repair делит только read-only path queries на заранее
рассчитанные пачки до 24 000 символ с учётом executable, shared quoting и
`-C Root`; все NUL records накоплены до полного успеха. `add`/`rm`/`reset`
используют существующий UTF-8 NUL pathspec-file pattern, каждая mutation
остаётся одним Git invocation. Для старых receipts before/now сравниваются
в одинаковом ordinal порядке в памяти; persisted receipt не переписывается.

Focused acceptance: 2/2 за 8,44 с
(`build/workflow-large-path-plan-after2.xml`): реальный Git, 420 Unicode/space/
apostrophe paths, исходный argv более 32 767 символ, полный managed tree,
сохранённый staged business index, reverse-order legacy receipt и ошибка
второй read batch без partial plan/commit/index mutation. Первоначальная
fixture read ошибочно трактовала relative `.git/index` как путь текущего
source; исправлено только получение absolute Git-owned index path, topology
не менялась (`build/workflow-large-path-plan-after.xml` сохранён).
Три существующих stopped-update/conflict continuation regression прошли
3/3 за 34,02 с (`build/workflow-large-path-existing-continuation.xml`).
Это source proof; original public continuation ещё предстоит повторить
новым coherent executor на прежнем candidate B2.

## Сохранённый exit-0-but-dirty отказ и original retirement ownership

B6 public continuation прошёл исходный Windows argv limit и завершился
exit 0, но public `status` и shared NUL getter выявили шесть tracked
deletions вне созданного workflow commit. Приёмка признана неуспешной:
`build/representative-pm5-former-exit0-dirty-oracle.json` и public status log
сохранены. Main B2 HEAD/terminal capsule, original failed-init state,
19 286 main CF файлов, branch CF/cursor/baseline, все прежние env values,
оба exact base SHA/length и authoritative seed остались неизменны.

Исходные пути: metadata-manage `form-patterns.md`, `ssl-patterns.md` и Codex
rules `dev-standards-core.md`, `development-process.md`, `rule-index.md`,
`verification-checklist.md`. Каждый существует в original snapshot records
и сохранённом r33 `.ai-rules.json` manifest. Shared strict installed-hash
matcher подтвердил все 6/6, включая допустимую Git LF/CRLF разницу двух
документов (`build/representative-pm5-retired-path-provenance.json`).
Причина: повторный post-copy использовал уже новый manifest и терял
retired paths из before ownership при создании branch commit plan.

Source fix добавляет exact authoritative snapshot records к commit owner
write-set. Snapshot factory уже определяет managed writes и runtime
metadata; broad rules/skills ownership не вводится. Causal regression
`build/workflow-retired-path-continuation-before3.xml` оставил ровно шесть
original deletions. После source fix — 1/1 за 14,49 с
(`build/workflow-retired-path-continuation-after.xml`): retained manifest
ownership, original interrupted post-copy, late user recreation rejected
с сохранением текста, unrelated `.codex/rules/user-extra.md` вне write-set,
staged business preserved и все retired paths удалены из нового Git tree.
Первые fixture diagnostics отдельно сохранены; API backup field исправлен
на `backupPath`, current managed set сохранил типовой `.ai-rules.json`.

Для уже completed capsule применяется существующий public `-Recovery
restore` с exact original branch snapshot. Terminal/state не переводятся
в pending вручную. Public `-Recovery status` рассчитан на pending update
и отказал `WORKFLOW_UPDATE_RECONCILIATION_PENDING_MISSING`; этот отдельный
отказ сохранён. После штатного rollback следует та же main public update
команда на immutable B2 через coherent B7 executor. До строгого clean
oracle нативная init continuation и fixture compression не запускаются.

Public B7 restore прошёл exit 0: branch rollback commit
`5bf9f3279a2f0356c32da4c7b18d91aca89b89e5`. Та же public main update через
B7 executor на immutable B2 завершилась exit 0, branch commit
`010ad86d4b8c2531d607ba5c857c272950f53aa2`. Полный oracle
`build/representative-pm5-b2-recovery-oracle.json` passed: оба tracked trees
clean, original CF/cursor/baseline/env/base/seed unchanged, main B2
HEAD/terminal SHA unchanged, original init state raw SHA unchanged,
branch pin остаётся B2. Original exit-0-but-dirty proof не переписан.
Public branch rollback закономерно заменил latest lifecycle diagnostic
на succeeded `update-workflow`; original init run/error сохранены,
initialization checkpoint остался `launcher-registered`.

MCP preservation подтверждён по bytes исходных backup config и parsed
entries: прежние families/root/provider/enablement и все args сохранены,
кроме единственного exact managed Vanessa catalog `.28` → `.42`; новый
catalog SHA совпадает с immutable B2 payload. Это configuration proof,
фактический MCP runtime/tool call здесь не заявляется. Добавлен browser
entry, optional windows-mcp остаётся degraded из-за отсутствия uv/uvx.

После strict oracle выполнена разрешённая isolated fixture capacity
preparation: NTFS compression только собственного остановленного D
`1Cv8.1CD`, exclusive lifecycle/base handles, ноль target sessions и
pending reservations. SHA `97baa97b7c7961c6a4eed8e3434c780a74fe1a60d6d879f81f22c792db5433d8`
и logical length 3 347 070 976 unchanged; physical allocation
3 347 070 976 → 1 309 962 240, volume free bytes
1 219 518 464 → 3 256 602 624
(`build/representative-pm5-ntfs-capacity.json`). E source/shared fixture
не сжимались. Это disk headroom, не продуктовый fix или performance proof;
logical 1CD size сам по себе не доказывает невозможность compressed DT.

Исходная public initialize command продолжена именно installed B2.
Date cursor failure пройден, owner запустил guarded PM5 Enterprise
auto-update с сохранённым 900-секундным deadline. Та же original command
завершилась exit 0; initializationStatus=ready,
enterpriseNormalizationStatus=passed, configLoadStatus=passed.
Native proof run `51f5bed0c95345078b7bbf9ff6100e89` содержит
status=passed, updateResult=Успешно и пустые errorMessage/errorDetails.
Source и Designer fingerprint совпали; tracked branch tree clean.
Артефакты: `build/representative-pm5-original-init-resume-installed-b2.log`
и `build/representative-pm5-original-init-acceptance.json`.

Таким образом, r33 failed initialize → public update с rollback/retry
существующего owner → original installed initialize завершён полностью.
Исходный дефект old helper не потребовал сначала закончить сломанный шаг;
immutable B2 payload, исходный target, cursor/baseline и данные были
сохранены strict oracle до разрешённой native фазы. Native update изменяет
собственную branch базу штатно; unchanged-byte claim относится только к
workflow-only update до неё. Полный paused business refresh A → workflow B
→ original refresh A остаётся отдельной проверкой 9.7.

### Full original refresh: discovered managed staged-merge barrier

В той же representative PM5 fixture созданы отдельные tracked synthetic
business commits: main `ae6911539de91b2f60fc6ef420acafdacb995a37`, branch
`d92a2a197a6521d1269a23294cb0b7ea4611115c`. Public installed B2
`refresh-dev-branch` выполнил full native SyncMaster, повторно использовал
compatible authoritative seed и сохранил target A=ae6911539. Штатный merge
остановился: business add/add плюс project/manifest/attributes conflicts.
Dependency lock conflict разрешён самим owner. Host exit 0 при явном
status=failed/errorCategory=merge-conflict является остановленным failure,
а не успешной приёмкой (`representative-pm5-full-refresh-original-target-a.log`).

Exact NUL index stages сохранены в
`build/representative-pm5-original-conflict-stages.json`; обе исходные
стороны трёх managed файлов — `representative-conflict-*-stage{2,3}.txt`.
Полный immutable before oracle после native SyncMaster:
`build/representative-pm5-paused-a-before-workflow-b.json`.

Normal public workflow C929/r39 update создал main commit
`0b301b415f5d40ffa1bbf47b0ce6ceeaa3d01efd`, но заблокировал branch на
`WORKFLOW_UPDATE_RULES_MANIFEST_INVALID`: conflict markers не допускают
чтение manifest. Его штатное continuation требует сохранить before/current/
candidate, разрешить named write-set conflict и повторить update из master.
Completed main capsule/head и original branch/A сохранены в
`build/representative-pm5-normal-c-before-managed-conflict-continuation.json`.

Разрешены только три named managed conflicts по исходным stages target A,
а не по движущемуся main C: project JSON семантически одинаковы; attributes
сохраняет lock -text и добавляет входящий обязательный source -text block;
manifest использует hashes merged rules stage3, сохраняет точную branch
generated openspec/project.md ownership/projectMdGenerated и foreign union.
Contributions unchanged, восемь retired aliases не возвращались.
Before/after hashes и rationale:
`build/representative-pm5-managed-conflict-resolution.json`.
Business NUL stages, MERGE_HEAD, pending target и lifecycle state SHA
не изменены; git add выполнен только для этих трёх paths.

Повтор той же public C update снова status=failed, хотя host exit=0:
`workflow-write-set-conflict`.
`Get-WorkflowUpdateRootWriteSetConflicts` возвращает все четыре штатных
staged результата original pending merge: dependency-lock.json,
project.json, .ai-rules.json, AGENTS.md. Все четыре входят recorded
pendingMergePaths, managed unstaged changes отсутствуют, unresolved
остался только canary-business.txt. Текущее continuation не позволяет
закончить original task без сброса pending merge либо ручного commit;
такие обходы не выполнялись. Это открытый продуктовый owner defect для
9.6/9.7; original reproducer/preconditions сохранены.

Первый manifest parse failure также проявил отдельный diagnostic gap:
ConvertFrom-Json в PS5 включает весь input в exception, а catch/throw
`Get-WorkflowUpdateRootWriteSetConflicts` повторно печатает его в rollout
и итоговом failure. Raw failed output сохранён без заднего исправления;
bounded diagnostics здесь ещё не квалифицированы.

### Staged merge provenance: owner checkpoint before live retry

Исправлен существующий eligibility owner, без новой state/authority/recovery.
`Get-WorkflowUpdateRootWriteSetConflicts` допускает только resolved staged
paths записанного original pending merge: exact current HEAD/MERGE_HEAD,
recorded target/branch/root/allowedPaths, отсутствие unstaged edits. Для
rules/executable/config bytes требуется exact mode/blob одного immutable
merge parent. Неизвестные provenance или ошибка чтения закрывают весь
частично проверенный set и сохраняют прежний write-set conflict.

Для semantic manifest merge добавлен один stateless typed validator в
ai-rules-migration owner. Metadata/mandatory file inventory берутся из
original target; каждый целый file record — из одного known parent.
Допускаются только existing upstream generated OpenSpec record/flag и
foreignFiles union known parents. Actual installed hashes, client/source
membership и полнота metadata проверяются; неизвестные additions или
изменённые hashes/template flags отвергаются. Existing ITL-owned `.dev.env`
и placed-once user template policy переиспользованы через свои owners.
Индекс/state/manifest/source receipts этот validator не меняет.

Focused tests: 2/2 в `build/staged-managed-merge-owner-final.xml`;
negative cases включают late staged rules, unstaged config, forged manifest
hash/foreign/template/missing record, foreign HEAD/target/unknown ownership.
Business NUL stages сохранены. Typed invalid-manifest diagnostic меньше
900 символов, не содержит исходный 25KB JSON input, original file SHA
не меняется. Две existing inventory regressions также прошли:
`build/staged-managed-merge-inventory-final.xml` (2/2), включая повтор
deferred root без повторного применения completed root и Unicode+space.

На неизменённой original PM5 ветке read-only qualification возвращает
manifestProvenance=true и writeSetConflicts=[] при target A=ae6911539.
State SHA и business NUL stages не изменены; source/parent identity и
точные hashes сохранены в
`build/representative-pm5-staged-merge-provenance-qualified.json`.
Это source checkpoint, а не завершённая live приёмка. Следующий шаг —
normal immutable C2 workflow update после completed main C929, затем
тот же original full refresh. Main C929 capsule сохраняется как исходное
completed proof; branch update snapshot ещё не создавался. 9.6/9.7 остаются
открыты до успешного исходного continuation через исправленный owner.

### Original C2 update and full-refresh continuation

Normal public update из exact clean C2 `ce107ee1bd0484223b3a87b15e649273aae3c574`
завершил оба roots: main `9d65ad1c737b8a48d7937a64c860335d327c5806`
tracked clean, branch workflow child
`0757ccfd17900ec5f3c7fcf2c135160b4fa754aa`. Исходный target A=ae6911539,
MERGE_HEAD и original branch d92a2 сохранены. Strict before/after oracle
`build/representative-pm5-workflow-c2-paused-oracle.json` passed: все CF
bytes/inventory, E/D base SHA256+length, authoritative seed, env key hashes,
MCP config, cursor/baseline unchanged. State изменил только current branch
parent и записал original parent; workflow commit содержит только paths
authoritative snapshot write-set. Completed main C929 capsule hashes
сохранены; они не переобозначены как C2.

Synthetic business add/add разрешён сохранением обоих immutable stage
2/3 bodies; staged только canary-business.txt, без ручного merge commit
или lifecycle mutation. Proof:
`build/representative-pm5-business-resolution-after-c2.json`.
Повтор исходного полного `refresh-dev-branch` сначала штатно остановился
на merge-preservation review: 19 managed paths заменили старую target B2
сторону установленным branch C2. Это честный failure/continuation, не pass.
Exact review в common Git directory keyed original parents/planId26a477.

Существующий result-bound decisions contract применён с concrete evidence:
14 package files raw SHA256 exact immutable C2, project semantic diff только
aiRules.ref, lock diff только пять identity/time fields, все target gitignore
lines сохранены, user text вне managed USER-RULES block сохранён modulo
LF/CRLF. Manifest generated exact r39, contributions unchanged. Both-side
patches и result blobs сохранены, business/CF paths в review отсутствуют.
Proof: `build/representative-pm5-c2-merge-preservation-proof.json`.
Проверка helper приняла decisions; только helper создал merge
`f4c35f78a4c4af0d0aa0c5b9e73e2fd7b00d3869` с родителями workflowB0757+Aae69
и передал post-merge phase свежему updated branch helper.

Нативное завершение пока FAILED: partial и full fallback загрузки вернули
exit1. Exact Designer logs 1c-20261001-003238-493-61884-334da4c3.log и
1c-20261001-003306-374-61884-33137c37.log указывают сохранённую repository
binding («текущая конфигурация помещена в хранилище»). Immutable PM5 seed
реально bound, а fixture SOURCE_USES_REPOSITORY=false привёл к штатному
skip unbind при original initialization. Это доказанный fixture profile
mismatch; CF/workload/guards/assertions не менялись для обхода ошибки.
Raw result:
`build/representative-pm5-full-refresh-original-resume-reviewed-c2.log`.
Host exit0 при status=failed/errorCategory=runner не означает приёмку.
State сохраняет pendingStage=merged, original target A и postmerge head;
configLoadStatus=fallback-failed, application readiness unverified.
Existing public unbind находится только в initialization/reset owners;
ready initialization не resumable, reset потеряет original pending refresh.
Прямой Designer, manual state и speculative DT roundtrip не запускались.
9.7/full 10.4 остаются открыты до применимого guarded fixture recovery и
успешного завершения штатного post-merge continuation.

### Bound fixture backup failure and read-only capacity diagnosis

Для исправления ошибочно подготовленного собственного standalone fixture
разрешён только существующий guarded Invoke-Designer с теми же
`/ConfigurationRepositoryUnbindCfg -force`, которые использует initializer,
в ignored fixture driver. Это не новая package action, authority или repair
state. E immutable source, shared stand, CF, env и original pending A менять
нельзя. После выполненного merge и failed load helper требует `/itl-check`
(`check-dev-branch`), запрещая повтор refresh/sync как recovery. Эту
continuation сохраняем; прежнее намерение повторить full refresh после
ошибки load отменено в пользу фактического helper contract.

Перед unbind public `release-e2e-snapshot` exact D branch завершился
native exit1: log 1c-20261001-004619-944-38956-6d492554.log сообщает
«Файл базы данных поврежден». Dump DT не создан, unbind НЕ выполнялся,
usable backup/restoration duty отсутствует. Public snapshot прошёл
existing per-infobase guard; после завершения exact-base sessions=0,
pending reservations=0. Unknown/foreign 1C процессы не остановлены.
Raw output: `build/representative-pm5-bound-fixture-public-snapshot.log`.

Первая readonly exclusive FileShare.None SHA попытка дала IOException
Win32 112 (disk full), D free=8192 bytes. D1CD logical length
3,347,070,976 и NTFS allocation 1,309,978,624; allocation практически та же,
что после прежней разрешённой lossless compression. DT directory пуст,
новых крупных файлов в exact own D area нет. Record:
`build/representative-pm5-base-after-snapshot-failure.json`. Это failed
read boundary, а не доказательство byte equality или подтверждённой
структурной порчи базы.

Следующая одна readonly streaming SHA попытка при D free=3,009,204,224
успешно прочитала все bytes за 5 s, free оставался неизменен на 52 samples.
Current SHA256=34c61e407439db0487dda4f9b719edb8fd8219ce5c16e89807861eedb842fd79;
pending state hash unchanged. Record:
`build/representative-pm5-base-read-telemetry.json`. Прежний failed read
сохранён; новый hash отличается от pre-native file-only oracle, что после
native 1C writes само по себе не доказывает порчу. Единственный readonly
Win32_PageFileUsage record — C:\pagefile.sys; D pagefile не обнаружен.
Причина transient free-space fluctuation не установлена. Readability
сама по себе не опровергает native DumpIB error; native/repair без usable
backup не запускаются.

После streaming success разрешён один повтор ТОГО ЖЕ public backup с
тем же exact D root/destination/flags. Он PASSED: native log
1c-20261001-010104-415-44396-6d413d56.log сообщает успешную выгрузку;
DT=483,144,773 bytes,
SHA256=b87da5faf966d932e6f48e05af39704a892ef3f2b3d0d527ee6e3d70deb49516.
Existing guard execution9783c217/nativePID41712 released, terminal
snapshot succeeded/complete. Read-only observer с exact own PIDs, free,
memory и DT size:
`build/representative-pm5-backup-repeat-telemetry.json`;
raw `build/representative-pm5-bound-fixture-public-snapshot-repeat.log`.
Это снимает утверждение о доказанной постоянной структурной порче;
первый failed native run сохранён без переобозначения.

Fixture driver загрузил installed entrypoint `-Action help` обычным
loader, без source extraction или signed-context fabrication. До вызова
Invoke-Designer его предварительный Get-FileHash снова получил Win32 112,
D free=36,864. Unbind не запускался, backup остаётся доступным. Последующий
readonly FileStream.Read(1 MB) также failed on FIRST read (0 bytes), поэтому
размер буфера не объясняет проблему. Pending state SHA unchanged;
`build/representative-pm5-base-read-low-space-telemetry.json` и
`build/representative-pm5-standalone-binding-preparation.log` сохраняют
оба отказа. Никаких дополнительных native retries, chdbfl, cleanup,
изменения compression/pagefile/filter/global settings не выполнено.

При текущем low-space состоянии DriveInfo, Get-Volume и Win32_LogicalDisk
согласованно возвращают36,864 bytes free. FileStandardInfo exact own file:
AllocationSize=1,309,974,528, EndOfFile=3,347,070,976, NumberOfLinks=1,
DeletePending=false; FSCTL_GET_COMPRESSION=2, единственный stream :$DATA.
То есть видимые own file allocation/output не объясняют новый расход
~2.5 GB. Filter/quota readonly queries denied без elevation. Причина
не локализована в принадлежащей fixture области; safe disposable cleanup
candidates не обнаружены. Сохранён точный handoff
`build/representative-pm5-resource-blocker-handoff.json`. Original A,
merge parents, pending merged stage и application failed/unverified
состояние сохранены; /itl-check ещё не запускался. Приёмка9.7/10.4
открыта до стабильного resource состояния и штатного продолжения.

### Post-cleanup continuation and current installed helper

После пользовательской и разрешённой локальной чистки ресурсный stop снят.
Повторный guarded backup уже был успешен; existing Designer owner выполнил
standalone unbind собственного D fixture. Original bound DT сохранён с SHA
`b87da5faf966d932e6f48e05af39704a892ef3f2b3d0d527ee6e3d70deb49516`.
`build/representative-pm5-standalone-binding-preparation.json` подтверждает
успех и сохранение защищённых входов. E source, shared stand и original A
не изменялись.

Штатный public repair/check с существующим session
`fc750d84db284a789f4f474407094cbb` выполнил partial load пяти
ParentConfigurations files и Enterprise normalization. Source fingerprint
`a7ff319d7947131a146c4f417957227932659c4cd61a9ac8c2a3b147a1305f50`
совпадает с immutable seed. Однако весь check не passed: на следующем
Vanessa service Gate 6 опубликованный `client_mcp` v0.6.5 с SHA
`d1093475a15e50a33ad48a64b61d09d1108b5a39328c73e6be17a5c914825e7f`
прошёл modules/applicability, но full CheckConfig завершился exit101:
`Конфигурация.client_mcp.ОсновнойЯзык Неразрешимые ссылки на объекты метаданных (1)`.
Автоматическое exact-DT восстановление service прошло. Repair budget остаётся
1/5; fresh verification, canonical export и completion pending A не заявлены.
Raw public result: `build/pm5-public-repair-check-after-cleanup-20261001.log`.

У исходного helper обнаружен отдельный дефект cursor snapshot: relative
ExportPath разрешался от caller CWD вместо ProjectRoot. Проверка из C для D
временно изменила два configVersion в actual D ConfigDumpInfo.xml. Source
commit `8588aaa755d2f73cf7e7672410264ae4d685c22d` переводит check/export к
существующему project path owner; regression сохраняет BOM/CRLF и отдельный
caller cursor. Red 0/2, green 3/3; RegisterChange после диагностированного
неизменённого deadline retry passed 711/0/0. Exact original cursor восстановлен
до SHA `5cff28fdbbc4940f81276de5d8fc9d747f70633d570fda4ade270ccd9f2bbe0f`
существующим snapshot/restoration owner; state/env/MCP сохранены, native1C=0.
Record: `build/pm5-cursor-baseline-recovery-20261001.json`.

Source commit `b37d4ffbfc2742bcc98d54a4369939bcfb36ea68` устранил
противоречие mcp reference: read NOT_READY не даёт нового разрешения на load.
RegisterChange documentation passed 40/0/0. Сам runtime и его полномочия
не расширены.

После живой ROCTUP приёмки обнаружена provenance-only запись tracked lock:
при acquisition того же version/name/URL/SHA label менялся с template baseline
на compatibility-manifest вместе с updatedAt. Dirty guard корректно остановил
новое обновление; его не ослабляли. Source commit
`c3de4a7804e77e8a016262d81cdad69a02a2a3bc` сохраняет raw lock при exact pin,
но оставляет прежнюю запись для реального нового pin. Реальные acquisition,
corrupt/cold cache, BOM и Unicode paths проверены: red 2 passed/3 failed,
green 5/0; RegisterChange Targeted passed 22/0/0 за 21.271 s, clean tree.
Own generated two-field side effect восстановлен из точного raw Git blob и
проверенного pre-live SHA `c8471d7592097ca1691685784ab9bd747dce6f1d1a15eaf2b06171e9fbe76a2f`.
Current bytes сохранены; HEAD/index/checkpoint/budget не менялись.
Record: `build/roctup-provenance-recovery-20261001.json`.

Через `scripts/update-installed-workflow.ps1` принят новый чистый local
acceptance source `360b806c63274be124be76ba9a9988379dfcef50`: exact registered
c3 code плюс только два template overrides на уже принятый r39 fork
`9ec86f75343ba4eded66e2085f097ff4baab7d67`. Это не published dependency pin
или Release qualification; штатные source defaults ещё r36 до отдельного
publication шага. Current helper установлен source-side launcher из отдельного
managed worktree, без ручного копирования installed файлов.

Public update завершён за 156.479 s. Main HEAD теперь
`9001b04c154fcd19afcec872de799438da3b0510`, D branch HEAD
`dbee04a36103e070b7426cddf2ed8502ccd112fc` — потомок original f4 merge.
CF tree, raw cursor, обе infobases, env, branch state, acceptance features,
repair budget и original target A сохранились. Initial raw oracle отдельно
зафиксировал изменение `.codex/config.toml`; это оказалось перестановкой
целых generated managed blocks. Повторная read-only проверка доказала exact
содержимое каждого блока и outside content под UTF8/CRLF transport; ни field,
ни binding не изменились. Failed raw oracle не переобозначен.
Qualified record: `build/pm5-c3-r39-workflow-update-qualified-20261001.json`.
Обновление не выполняло load/configuration merge/tests и не завершало refresh.

Current installed ROCTUP прошёл initialize/initialized/tools-list (два gateway
tools), bounded metadata (returned1/count319) и запрос43, limit1/schema.
Exact owned instance `b36e768a40cc11adfa6f5f3b87d6d623`, catalog SHA
`c61009dafbd8d781f44482419a72036155acc5a60f5a65c2d10df6e046cb8011`,
binary 0.4.15 SHA `95968cccdcc38e3327ce7dc2ebe521fc34d55b44459d0a9d301cdec0be114aff`.
Фактический результат — Ответ=43. Facade EOF/exit0, удалённый owned runtime
record и закрытый observed port6003 подтверждают штатное завершение; retained
schema3 evidence содержит passed get_metadata/execute_query. Branch
state/lock/env/MCP/cursor не изменились.
`build/data-current-pm5-c3-qualified-20261001.json` и actual RPC SHA
`3f67842f9ab5bb7d6d142b68755fa364a7086cc5fee11511feed7eb5d5665f7f`
отдельно указывают provenance и границы этого proof.

Fresh ephemeral unelevated Codex read-only sessions реально прочитали installed
rules и приняли решения для named DATA при persistent off, required pure BSL
без vcexecutecode и unknown effects. Только три read commands, ноль MCP calls:
named request даёт scoped override без persistent write, отсутствие provider
оставляет unverified; required pure BSL блокирует зависимое proof без alias
на execute_code; unknown effects не исполняются. Второй свежий trace сохраняет
off при общем «проверь» и не даёт load из fixture NOT_READY. Последний —
executed agent decision на явно отмеченном fixture input, не live NOT_READY.
Records: `build/native-data-policy-c3-20261001.*`,
`build/native-data-off-not-ready-c3-20261001.*`.

9.7/10.4 и полный 4.4/4.5/4.7 остаются открыты. Diagnostic copies с adopted
Russian Language прошли тот же full service Gate6, но это ещё не installable
client_mcp component. Production route ставит client_mcp только в Vanessa
service/TestManager, VAExtension — в PM5/TestClient; direct diagnostic CFE в
PM5 выявил отдельную неприменимость handler и восстановлен, поэтому PM5 не
меняем. Minimal owned-component maintenance/delivery proposal вынесен на
отдельное решение; runtime cache rewriting, bypass checks и публикации нет.
External Docs/Templates/Syntax/CodeChecker на 10.0.12.53:18000–18003 остаются
TCP timeout, latest bounded record
`build/mcp-reachability-after-user-cleanup-20261001-083358.json`; provider
handshake/functional acceptance unverified. Positive pure-BSL provider также
не обнаружен. Эти ограничения не маскируются passed fixture tests.
