# OpenSpec in a development branch

Use this reference with `planningMode=OpenSpec`: the user explicitly asked for OpenSpec, or formal research and agreement on requirements, architecture, acceptance criteria or implementation stages really adds value. `executionPath=quick-fix|full-cycle` is chosen independently by the upstream eligibility/promotion policy. A promotion trigger changes only the execution path and by itself does not require OpenSpec.

## Readiness rule

Here `itldev/*` means the current Git branch name (`git branch --show-current`), not a directory or a file glob. In such a branch a change under `exportPath`/`extensionsPath` passes the assessment of applicable obligations and a fresh passed `/itl-check`; `testsPath` stores retained tests, and sufficient one-off proof needs no placeholder test file. A started runner with zero tests, invalid JUnit or a failure remains an error. On `master` a source edit remains a branch-safety blocker.

Before algorithm tests read `references/yaxunit-tests.md`; before Vanessa tests read `references/vanessa-tests.md`. Mode `off` forbids the automatic run, not authoring a test or reusing already fresh sufficient proof. Without such proof the skip stays partial: `verificationPolicy=block` blocks result/close, `warn` permits a warned export; closing the branch needs a separate confirmation.

Large OpenSpec changes use the hybrid cadence: each slice with observable behavior is linked to sufficient current proof and the applicable targeted/static checks of the changed BSL, XML, form and feature file. Retained YAxUnit/Vanessa tests are added for their future value, not by the number of tasks or iterations. An intermediate `/itl-check` is needed at a milestone whose runtime result decides further implementation. Preparatory tasks are recorded as pending verification. After the last verification-relevant edit an ordinary unfiltered `/itl-check` assesses the whole applicable obligation set and reuses fresh proof.

## Process

OpenSpec is for tasks that must be described, agreed and then implemented.

Usually start with the propose entrypoint shown by `/itl`. `/opsx-explore` is optional, needed only when understanding of the current code, task boundaries or a possible approach is missing before the proposal. The `/opsx-*` names below are an example of the native syntax, not a universal contract. In Codex use the explicit `$opsx-explore`, `$opsx-propose`, `$opsx-apply`, `$opsx-archive`, `$openspec-update-change` and `$openspec-sync-specs`; the canonical `openspec-*` skills stay available to the model for implicit selection.

`/opsx-propose` creates the proposal and the other OpenSpec artifacts for agreement without changing code.

In the `natural` mode the user invokes the same stages with ordinary requests (user-facing examples, keep in Russian):

```text
Исследуй задачу в режиме OpenSpec, не создавая proposal и не меняя код
Подготовь OpenSpec proposal для <изменение>; создай proposal, design, tasks и spec deltas; зафиксируй проверяемые сценарии, отдельный test-plan только при необходимости; код не меняй
Реализуй согласованный OpenSpec change <change-id> по tasks.md и утверждённым проверкам
Заархивируй принятый OpenSpec change <change-id> и синхронизируй specs
Обнови согласованный OpenSpec change <change-id> по текущему контексту, сохраняя принятые решения
Синхронизируй spec deltas OpenSpec change <change-id> с основными specs после проверки конфликтов
```

Both modes use one agreed OpenSpec root, a shared preflight and a fresh `/itl-check`. First check the pinned Node + OpenSpec CLI pair through the helper. When it is missing, run the explicit `-Action provision-openspec-cli` in this checkout; a global `openspec` does not replace the project pin. Do not run an arbitrary `openspec update`: updating the installed bundle and documents has a separate owner. Until a separate external-store release, all six phases work only with the local `openspec/` of this checkout: call `agent-1c.ps1 -Action openspec-context -OpenSpecChangeId <change-id>` (not the compact runner) before writing, and do not bypass `OPEN_SPEC_EXTERNAL_STORE_DEFERRED` with a direct `--store` or by moving files.

### 0. Explore the context when needed

`/opsx-explore` is optional. The agent studies the code, the current implementation and the task boundaries, but creates no proposal and changes no code.

### 1. Create the proposal

`/opsx-propose` with the task, the known context of the current implementation and the expected result. At this step prepare the OpenSpec artifacts:

- `proposal.md` — what changes and why;
- `design.md` — how it is implemented technically, when the change is not trivial;
- `tasks.md` — the concrete tasks to perform;
- verifiable scenarios and the way to obtain sufficient evidence — in `tasks.md` or in a separate `test-plan.md` when it helps agreement. For a retained regression name its owner and run cadence separately; one-off proof does not require creating a suite. For algorithmic risks use suitable existing or new YAxUnit checks, for integration/UI sufficient Vanessa scenarios reusing existing ones; list the dangerous negative cases;
- spec deltas — which requirements change or are added.

Code does not change at this step.

### 2. Review the OpenSpec documents

The developer checks that the problem is clear, the proposal matches the original task, the design is concrete enough, `tasks.md` can be implemented without guessing, and the result checks are named with the steps after which they run. When the plan is unclear, refine `tasks.md` into small concrete steps naming objects, modules, procedures and checks, still without changing code.

### 3. Agree on the implementation

Code is written only after the developer has agreed `proposal.md`, `design.md` when needed, `tasks.md` and the requirement changes in spec deltas. Agreement is mandatory when the solution touches architecture, metadata, integrations or permissions.

### 4. Implement the change

`/opsx-apply`: implement the agreed OpenSpec change strictly by `tasks.md` and the approved checks, marking completed tasks after each significant step.

After each significant slice and before reporting to the user, compare the affected `tasks.md` items with their own criteria. Close an item when all its conditions hold and name the applicable proof. A functional item may be closed while overall acceptance is open. When the implementation is ready but the item's own required check is not yet confirmed, leave `[ ]` and note next to it what is implemented and which result is missing. A partial or neighboring check does not close the item.

When a relevant edit makes a confirmation stale, reopen only the affected mark. Keep the reference to the historical result and state which confirmation is needed now. Reuse applicable fresh results. Overall readiness is determined by all DoD criteria, including the final unfiltered `/itl-check` after the last relevant edit.

When the change is large or consists of several independent steps, split the work into verifiable slices. For each slice with observable behavior name a sufficient existing test contract, or add or update a narrow test only for an uncovered risk, and run the cheapest sufficient targeted/static checks. Do not run `/itl-check` automatically after every slice. Preparatory tasks without their own observable behavior are recorded as pending verification and are covered by the nearest following verifiable slice.

For a change of an end-to-end user path, make the first observable slice its minimal real variant from input to result in an available and permitted environment, for example export → import → open. Do it before expanding variants and check matrices so that faults of the main chain surface early. Clarify in advance only the dependencies of this path. When the needed environment is unavailable, keep the dependent proof open and continue independent tasks; this is not a new mandatory gate or document and does not replace final acceptance.

### 5. Executable milestone or final check

An intermediate `/itl-check` runs only at a milestone where the actual 1C load or behavior decides whether the chosen implementation can continue or must be redone. After the last verification-relevant edit the final `/itl-check` is mandatory (skill-based clients such as Codex use `$itl-check`; `/itl` shows the exact command name).

An ordinary unfiltered `/itl-check` without `VanessaFeaturePath` and `VanessaFilterTags` assesses all applicable obligations on the exact final fingerprint. The helper loads the changed configuration and runs only the missing permitted checks; fresh sufficient proof is reused. Verification-relevant edits after the check make the dependent proof stale and require a new assessment. Do not run `/deploy-and-test` afterwards to repeat the same already confirmed cycle.

### 6. Test the scenario through Vanessa Automation

Vanessa Automation is the standard test framework of the development branch. Tests live in `tests/features`, reports in `build/test-results/vanessa`.

Before creating or editing tests read only the matching layer: `references/yaxunit-tests.md` for algorithms or `references/vanessa-tests.md` for integration/UI; ordinary lifecycle commands need neither.

The minimal check set:

- BSL syntax;
- correctness of changed metadata XML;
- completion of all `tasks.md` items;
- no unrelated changes;
- sufficient current proof for representative end-to-end paths; when a retained regression is useful, usually 1–2 Vanessa integration/UI scenarios reusing existing ones, and algorithmic boundaries as compact parameterized YAxUnit tests.

Choose the check type by the nature of the change:

- YAxUnit unit — application logic, calculations, conditions, data filling and the boundary matrix;
- integration — interaction of objects, registers, documents, exchanges;
- UI — only user forms, commands and visible behavior.

When the change touches interaction of objects, registers, documents or exchanges, include an integration check in this set.

When a UI scenario is needed and the infobase is published for the web client, test through the published URL. Without publication use an available user-mode scenario against the branch infobase copy, or record the limitation explicitly in the report.

When an executable milestone or the final check fails, analyze the YAxUnit/Vanessa JUnit, the helper status, the 1C log, screenshots of a UI failure and the changed code. Distinguish a runner/environment failure, a fixture failure and a proven product defect. Fix the cause at its owner and confirm the fix with the affected targeted/static checks. The full helper run is needed at the next deciding milestone or after the last relevant edit when the run is permitted. When the limit is exhausted, keep the repair session, leave the dependent checks open with a reference to the report, and continue available diagnosis and independent items in the agreed order. When no available action remains, name the affected items and which permitted action is needed to continue.

Record in the OpenSpec change `test-report.md` the proven failure cause (`runner|fixture|product`), the layer chosen after it (`YAxUnit|Vanessa|both`) and the rationale for both layers when both are needed. Name the reused, strengthened or new test contract, which scenarios ran, the JUnit/Vanessa report paths and which errors were fixed. For a change without a red run a coverage rationale is enough; do not invent a failure category.

Move on to review or `CF` export only after successful testing.

### 7. Code review when needed

Code review does not start automatically; the user asks for it explicitly. A review looks for runtime errors, regressions, violations of the OpenSpec requirements, risky metadata changes, insufficient checks and unrelated changes.

### 8. Export the result

To pass the current version of the changes into the infobase bound to the repository use `/itl-result` (Codex: `$itl-result`).

Without fresh sufficient proof the helper applies `VERIFICATION_POLICY`: `warn` permits the result with an explicit warning and no repeated confirmation, `block` forbids the result until a fresh passed `/itl-check` assessment. A successful old runner with changed inputs is stale, and a sufficient one-off result is assessed on the same terms.

### 9. Close the OpenSpec change

After acceptance archive the change with `/opsx-archive`, which also syncs specs: the agreed requirement changes move from `openspec/changes/<change-id>/` into the project's current specifications.
