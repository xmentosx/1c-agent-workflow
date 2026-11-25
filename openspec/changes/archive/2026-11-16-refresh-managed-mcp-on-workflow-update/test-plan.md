# Acceptance evidence

Локальная постановка и реализация: 2026-10-13, base 81e8f1f3.

| Проверка | Результат |
|---|---|
| MCP config + shared ownership, Windows PowerShell 5.1 shard runner | 88 passed; build/test-results/mcp-continuity-acceptance/junit.xml |
| Последующее уточнение fallback: нет локальных изменений / восстановление локального facade при отказе registry | 2 passed focused Pester |
| Legacy TOML без ownership receipt с inline comment | focused regression сохраняет URL и комментарий при добавлении SPPR |
| Host direct health budget/publication | 7 passed (DirectHealthBudget) |
| Python identity / foreign route / safe health / SSE heartbeat / Unicode child | 14 passed |
| Client adapters / workflow snapshot and ready checkpoint | 41 + 52 passed в build/test-results/mcp-continuity; соседний MCP shard имел исправленную затем ошибку duplicate filtering, весь тот run не считается passed |
| OpenSpec validate --strict | passed |

Основные сценарии: default URL обновлён, override сохранён после двух sync,
SPPR добавлен, legacy/External/auth/disablement не утрачены; свежий Git registry
заменяет старый URL с сохранённым host; вывод не обещает attachment текущему чату.
Уникальный недоступный endpoint проходит Prepare...ForInit без повторного выбора,
но New...RemoteRuntime не сообщает его ready. Foreign identity и timeout внутренней
health при foreign public route не разрешают restart. SSE heartbeat не продлевает
0.3s бюджет до конца двухсекундного потока.

Старое ожидание «health failure делает selection incomplete» намеренно заменено:
полнота настройки и доступность инструмента имеют разных владельцев. Регрессия
небезопасной runtime connection сохранена. Для matched identity safe-call timeout
перенесён в health_error; проверка foreign endpoint сохраняет unverified и отсутствие
safe calls на чужой public endpoint.

Product-docs source SKILL: 7046 → 7523 bytes (приблизительно +477 bytes, сравнение
старого текста с LF и текущего файла). Добавлена маршрутизация bounded recovery,
обязательные запреты на loops/ложный pass не удалялись. Периодичность 60 секунд
реализуется инструкцией текущего агента, без нового runtime state/coordinator.

Граница доказательства: настоящие init ERPPM5/PM5 на Уфе, live fetch_its,
публикация, установка и attachment/reconnect реального клиента не выполнялись.
Нет нового RPC канала к owning App Server; при его отсутствии результат требует
reload/discovery. Серверы и контейнеры не менялись.

Финальная регистрация и её exact-head Targeted проверяются через source-delivery
Status, а не отдельной копией delivery ledger в этом документе.

## Completion acceptance, 2026-10-13

The earlier task checkmarks covered implementation and focused tests, not the
missing complete scenarios. They were reopened for this completion pass.

| Request | Evidence / acceptance boundary |
| --- | --- |
| Original update adds SPPR and updates unchanged managed entries | McpConfig SPPR Git-publication test; MultiClientMcpOwnership JSON/TOML/OpenCode default update tests |
| Preserve custom URL, policy/auth, disabled, external, host/provider/configId, legacy | MultiClientMcpOwnership baseline/override/legacy/collision tests; McpConfig choice/ambiguity tests |
| First chat: sole unavailable codechecker cannot block independent init | McpContinuityAcceptance runs actual Initialize-Project orchestrator through init.complete with real selection/setup/start/config; native 1C/dependency/Git/report seams are fixtures |
| Registry failure preserves remote config, independent work continues | Same init scenario with failed refresh and existing remote URL; ownership tests retain bytes and repair local families |
| Second chat: identity survives fetch_its failure; safe recovery | endpoint_identity actual loopback fetch_its timeout -> retained signature -> successful same-identity health; HostTooling DirectHealthBudget publication stays running/degraded |
| Wrong identity / indexing / unavailable cannot authorize restart | Existing endpoint_identity foreign/unstable/internal-failure tests and host proof restrictions unchanged |
| SSE/header/open/cleanup elapsed limits | Actual heartbeat, header-trickle and delayed DELETE fixtures; cancellable stdlib transport bounds each request and separate cleanup budget |
| Third chat: old URL -> new publication -> owner sync -> original read | endpoint_identity Windows integration uses real local Git publisher/cache, actual owner writer and Sync-ItlClientMcpConfig, loopback MCP handshake/discovery and original safe call after reconnect |
| One registry snapshot across operation | McpContinuityAcceptance nested-operation publication-change test and full init refresh counter; common master/development post-copy wraps all reconciliation in same owner scope |
| No invented current-client attachment | Sync report explicitly says config does not attach current chat; owning loopback test client can reconnect, actual Codex channel remains absent |
| Retry only on actual next need >=60 sec, immediate changed evidence; no success/business/disabled/uncertain-mutation refresh | Agent-owned continuation contract in references/mcp.md; no background polling, new persistent retry state or helper auto-replay introduced |
| Rollback/resume and no refresh after ready checkpoint | WorkflowUpdateRollback existing 52 scenarios |

Local integration is server-free acceptance of package behavior. It does not
claim real Ufa/PM5 infobase qualification, production fetch_its availability,
production server publication/deployment, or current Codex chat attachment.
Those operations are excluded by the user's explicit server boundary. The
60-second policy is an agent instruction, not a newly implemented runtime timer;
this distinction remains part of acceptance, rather than counting a fake clock
unit test as proof of human/agent behavior.

Final focused and registration results are recorded below after completion.

Completed focused evidence:
- Python unittest: 18 passed, including real local Git/PowerShell owner/MCP recovery,
  fetch_its failure/continuation, header trickle and bounded session cleanup.
- Windows PowerShell 5.1 final client shards: 134 passed (58 MCP config, 32
  ownership, 41 client adapters, 3 continuity before the additional post-copy
  and host-choice cases). No failures or skipped tests.
- Updated selection shards: 63 passed (58 MCP config + 5 continuity).
- Final continuity suite after separate degraded-capability reporting: 6 passed.
- Workflow rollback/resume: 52 passed on the common post-copy refactor.
- OpenSpec strict validation and git diff whitespace checks passed.

The first completion shard run failed on PowerShell scalar Count handling in the
new request filter. The implementation was fixed by retaining an explicit array;
subsequent client/selection runs passed. A recovery fixture initially lost its
seed mode when dot-sourcing the helper's Mode parameter; the fixture now captures
its own mode before importing and verifies the saved host as well as config.
No assertions or reproducer topology were relaxed to hide either failure.

Final source registration (including exact integrated-tree Targeted proof) is
owned by source-delivery Status for queue workflow-mcp-continuity. It is not
publication or installation. The completion commit descends from the already
registered eb4848f3 rather than rewriting its history.

Final recheck read the three source chats again (01a116be, 01a116b8, 01a116ae).
Their delegated scope matches the matrix above; no additional server authority
or parallel implementation was present. The current callable tool inventory has
no owning-client MCP reload/RPC capability; this is a verified interface boundary,
not a claim that all possible external attachment mechanisms are impossible.
The late selection audit also removed health-based rerouting: saved host wins,
a single published candidate may be selected regardless of temporary health,
and multiple candidates still require an explicit unambiguous choice.

The first completion RegisterChange candidate (7a02ecc9, preserved at
itl-source-register-b4ab52cd43644bac81f1b40cc7be7b33) failed Targeted in the existing
CompactRunnerWatchdog controlled-handoff fixture: expected native terminal exit
7, observed RUNNER_STATUS_STALE at its two-second threshold. The exact same
scenario passed on that exact candidate in a focused Windows PowerShell 5.1 run
without modifying implementation, workload, topology, timeout or assertions.
Two other concurrent registrations were present during the failing run and had
completed before the retry; scheduling contention is a hypothesis, not a proven
watchdog root cause. Accepted refs were preserved. The normal RegisterChange
continuation incorporates the subsequently accepted w06/w10 queue entries and
must itself pass; the isolated pass is not substituted for Targeted acceptance.

Before final registration, the recovery fixture was strengthened to begin with a
working endpoint and record its actual identity signature, then stop that local
listener and require the replacement to match that signature before owner sync.
The same original read then succeeds after the loopback client's reconnect.
All 18 Python tests passed again. The in-progress retry was cancelled before
acceptance to include this stronger proof in the final coherent source commit;
its owned processes exited and accepted refs remained unchanged.

Final wording review makes the client warning claim retained configuration only;
it does not infer live identity from a registry publication. The continuity case
names also distinguish optional degradation from complete endpoint outage.
Neither reporting correction changes readiness, timeout, restart or assertion
contracts. Interrupted qualification attempts do not count as accepted proof.

Further integrated qualification diagnosed a different failure in the same
watchdog file: the long-heartbeat helper had already published complete/success,
but the action deadline preempted its existing terminal cleanup grace and
replaced success with runner.operation-timeout. Raw retained artifact:
itl-source-register-3971b3aef4814b39a1ccb66ccc5711fc/.agent-1c/runs/
compact-20261013-224405-726-d1b755e1/status.json. The earlier handoff case passed
in that run; the failures are not conflated as one proven contention cause.

A new native reproducer retains the old timeout/owned-process topology while
explicitly crossing the deadline during terminal cleanup. Against the unchanged
old runner it fails in 9.58s with terminal success overwritten. With the owning
runner fixed, the complete Windows PowerShell 5.1 watchdog file passes 14 tests:
cleanup exits successfully in 14.16s; stuck terminal helper is stopped in 63.53s.
Existing stale heartbeat, active operation deadline, terminal result and exit
failure assertions remain unchanged. See design checkpoint for exact scope and
bounded operation-time effect. The following RegisterChange explicitly retries
the diagnosed failed stage; only its final accepted result closes delivery.

The subsequent integrated run passed all 18 watchdog cases and reached 1464
passing checks before HostTestSelection rejected the expanded MCP owner test set.
Its old exact expected set omitted the intentionally added continuity acceptance
file. The selector expectation is updated by adding that file; every previous
member and the exact-set equality assertion are retained. This is an intentional
coverage-contract expansion, not a weakened regression or removed reproducer.

The next resumed run exposed KiloContextDiagnostics' old static assumption that
the Browser summary call lives directly in Initialize-Project. The new registry
scope delegates to Initialize-ProjectCore; actual init behavior remains one
summary. The static test now requires exactly one delegation, no duplicate
wrapper summary, and exactly one Core summary. The complete init acceptance also
counts the runtime summary call and requires exactly one in each outage/optional
capability scenario. This retains and strengthens the original observable
contract instead of skipping the static check or allowing duplicate summaries.
