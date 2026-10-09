# Incremental ai_rules_1c r42 intake

## Exact identities and delivery boundary

The source baseline is published Develop `c900620e6569ce4cec39e30abfa3f8ce2c150ce1`.
Its controlled rules are r41, `84ed7c7a8dcc783159537f41f38196640ffa968c`, based on
upstream `c1fb8e687be5b9d71d5a05c6f5d32cf6a6919dcb`. The next candidate is
`827e5ccaa7e319dc5871555f7e997093478359c4`, local ref `itl-main-5700f54-r42`,
reconstructed directly from upstream `5700f54a899abb1e8b6483badd6986e5a0e6c1af`.
The source pin is `pending`; local registration does not publish either repository.

Upstream added two commits: `709ecac` moves situational instructions behind
on-demand routes; `5700f54` adds BSP common-form references to external reports.
The upstream delta has 45 paths, including eight new documentation/rule paths.
Twenty-one paths overlap the published downstream delta; eight textual conflicts
were resolved against their semantic owners. Schema-3 decisions cover 267 paths
with exact upstream/baseline/result text hashes, including the explicitly retained
unchanged mandatory `forms-add.md` owner. Reconstruction starts from the new
upstream rather than merging the old release history.

## Behavior before and after

| Area | Upstream at c1 | Upstream now 5700 | ITL at r41 | ITL after r42 |
|---|---|---|---|---|
| Tool policy | Policy and availability coupled to the 1C MCP route | Shared `tool-policy.md`; operation-specific routing stays with its owner | Same shared route, plus ITL validation and provider constraints | New shared policy; ITL constraints remain in their relevant owners |
| Project memory | Memory could pull in the non-memory MCP router and template skill | Direct `project-memory.md` route; template skill handles code templates | Managed ITL memory requires a verified project-isolated provider binding | Direct route with the same isolation, local fallback and dependent-step refusal; no implicit Cognee/OpenViking |
| Metadata, QA, binary skills | Detailed situational instructions loaded in the entrypoint | Short entrypoints route to runtime selection, interaction recipes and format references | ITL preview refusal and managed form-context rules layered on those entrypoints | Short routes retain those mandatory ITL checks before mutation |
| MCP catalog | Server descriptions in the main skill | Catalog moved to an on-demand document | Preferred `check_1c_logic`, ROCTUP data and managed Vanessa UI distinctions | Same preferences and distinctions in the relocated catalog; saved-suite and standalone QA remain separate |
| ERF form references | Local report forms expected; `CommonForm.*` was not handled consistently | Validator accepts common forms; stub builder supplies forms; `-BspForms` sets all three references | Inherited earlier ERF behavior | Same new capability; default scaffold remains unchanged and missing local forms still fail |
| Lifecycle and acceptance | Upstream general development rules | General development rules retained | ITL owns branch infobases, fresh checks, verification, export, recovery, Q23 and OpenSpec integration | Same ITL owners and contracts; no lifecycle or migration implementation changes |

## Context cost

UTF-8 byte counts below use Git text normalized to LF. They measure entrypoint
size, not model-token billing, total documentation size or end-to-end latency.
The referenced details are loaded when the selected operation needs them.

| Entry | r41 bytes | r42 bytes |
|---|---:|---:|
| Root AGENTS | 13,554 | 12,800 |
| Project memory | 10,726 | 7,944 |
| Metadata skill | 16,329 | 9,036 |
| MCP skill | 6,661 | 4,809 |
| Template skill | 4,136 | 2,435 |
| QA skill | 19,834 | 10,103 |
| v8unpack skill | 16,102 | 4,844 |

No new runtime barrier, coordinator, elevation requirement or always-on service
was added. Existing per-infobase guard ownership was reused for platform proof.

## Qualification

Exact final commit `827e5ccaa7e319dc5871555f7e997093478359c4` passed Full:
**170/170 Pester, 18/18 stages, clean and reusable**. The real publisher's
qualification probe passed and local ref preparation reused that proof. Local
annotated tag `itl-main-5700f54-r42` and its required release branch
`upgrade/main-5700f54-r42` identify this commit; no remote was changed.
The Python-port stage passed 59/60 cases with one unchanged host skip: Windows
symlink creation is unavailable without the required privilege. That scenario
remains unverified on this host; no elevation or weakened assertion was used.

The rules validator passed its existing context ceilings and routed references.
New fork regressions cover direct memory routing, managed preview refusal,
relocated provider distinctions, default versus opt-in BSP scaffolding, and the
negative missing-local-form case. The first Full found one obsolete root-anchor
assertion (169 passed, 1 failed). Upstream moved those detailed obligations into
the mandatory `mcp-policy.md` owner; the corrected regression proves both the
root route and the original platform discovery, same-goal template query, reuse
and named-rejection obligations. UTF-8 BOM preserves its Unicode assertions in
Windows PowerShell 5.1; the focused policy file passes 12/12 there. The Python
inventory regression likewise follows the required `runtime-selection.md` route,
proves every shipped port and rejects unshipped-port promises in both the short
entrypoint and its routed owner. Its focused documentation case passes without
changing the original command/parity/packaging scenarios.

The r41-to-r42 transition passed for all twelve supported clients in delegated
MCP mode, including preservation checks, byte-idempotent repeat and doctor.
This is installed-file compatibility, not native client or live MCP evidence.
The transition and ERF canary executed on prototype
`c938fa8a244ccf584a9c6a599eb4da3611182bbc`. NUL-delimited Git comparison with the
final `827e5ccaa7e319dc5871555f7e997093478359c4` shows only
`tests/R8Policy.Tests.ps1` and `tools/tests/python-ports-regression.py` changed:
installer, installed content and ERF tool bytes are identical. The final commit's
own Full qualifies the changed regressions; prototype proof is not relabelled as
execution on that commit.

The real platform canary passed on Windows 1C **8.3.27.2130**, in a newly created
disposable directory containing whitespace and Cyrillic. The guarded sequence
was scaffold with `-WithSKD -BspForms`, stub database creation, ERF build, XML dump,
then validation with **0 errors and 0 warnings**. All three `CommonForm.*`
references survived the round trip. ERF SHA-256:
`c954d820fe9261438d0f06870988dae01e12dcaf8465b7c9ab3bd268abcb2ff3`.
This proves report transport and generated metadata; actual business BSP form
opening and behavior remain unverified by this disposable stub canary.

Retained ignored receipts are under source worktree `build/ai-rules-r42/`:
`prepare.json`, `verify-final.json`, `context-delta.json`, `erf-platform.json`,
`qualification-input-binding.json` and the client-transition log/fixtures.
Fork Full receipts remain in the exact fork's
`build/test-results/qualification/full.json` and its referenced JUnit/stage logs.
These local artifacts are evidence, not managed package inputs.

After the coherent source commit, use `source-delivery.ps1 -Action RegisterChange`
with this exact local fork. The owner runs Targeted and writes the shared local
queue only on success. Later publication uses the normal paired `PublishDevelop`
owner with the exact fork and authorized E2E stand. It must establish dependency
installability and compatibility before advertising r42 as available to projects.
Do not push or move immutable fork refs as part of local registration.
