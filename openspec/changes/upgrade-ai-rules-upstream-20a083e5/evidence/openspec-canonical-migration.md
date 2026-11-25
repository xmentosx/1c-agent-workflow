# Codex OpenSpec placement defect — 2026-09-30

Review of the actual installed r33 → fork `38d315de...` canary found two sets of
OpenSpec skills. The old four-phase bundle remained in `.agents/skills` with its
old Caveman contract, while the new six-phase bundle was placed into
`.codex/skills`. The installed old `openspec-explore` SHA-256 was
`ee48b2aeb1f32e49847ee5679ce2dc23d77a4364d3bc0a20327791b33eb6b6a7`.
Its manifest source still named the retired
`content/openspec-bundle/codex/.codex/skills/openspec-explore/SKILL.md`.
No installed file was patched to bypass this failure.

The controlled Codex adapter already places both generic commands and skills
into `.agents/skills`. An upstream OpenSpec destination remap instead sent new
vendor-neutral bundle files into `.codex/skills`. Update retained prior bundle
entries, so the old canonical files never received the new phase contracts.
Source-only phase checks and manifest source-to-target existence checks did not
detect that behavioral mismatch. Task 9.2 was reopened pending corrected
installed acceptance.

Controlled-fork commit `1fef9b4dfbfcebe2c3312bd5c73d4feb730f64fa` restores the
canonical destination and removes only unchanged manifest-owned legacy Codex
aliases. User-edited aliases survive with a warning. An actual installer
init/update regression passed: all six canonical phase bodies contain the new
managed contract and auto/full policy, the old managed four-phase body updates,
unchanged legacy aliases disappear, and a user edit remains byte-identical.

The exact Full run of that commit failed at Pester: 133/136 passed. The first
layout assertion still expected `.codex/skills` despite the adapter's canonical
path. Its early failure prevented later client fixtures from initializing and
caused two dependent failures. The assertion is being aligned with the actual
adapter and the stronger migration regression; client list, workload and
preservation assertions are unchanged. The failed proof is retained and is not
reusable qualification.

Source compatibility now checks the actual phase bytes against the exact bundle
and requires canonical Codex placement. Read-only runtime status also selects
only the requested client's native entries, prefers that client's command
surface, and detects legacy Codex targets with an owner reconciliation
continuation. The selected-client regression passed 3/3, including preserved
user clarification, missing own phase despite another complete client, nested
Claude commands and duplicate legacy refusal followed by successful retry.

Fork `11c0f0b524beef0898e223d28cd4dd534be9c90c` subsequently passed exact Full:
136/136 Pester tests, 18/18 stages, clean tree and reusable qualification.
Exact-commit init/update/doctor passed for all 12 clients, with byte comparison
against that run's checked-out bundle. Builder Verify checked 471 ledger paths.
Those records are retained; they do not qualify later commits.

A fresh actual published-r33 update then completed through the source wrapper
at installed HEAD `7d8a6708b6f1f7f4587b2733c6d4ba38bf8e5d4e`, with a clean Git
worktree. It updated all six canonical phase bodies, but left eight retired
`.agents/skills/opsx-*` files: four alias bodies and their invocation metadata.
These manifest-owned aliases came from r33's old `.codex` bundle source.
The earlier `.codex` cleanup did not cover that older destination. Task 9.2
therefore remains open; a successful updater exit alone is insufficient.

Commit `ee9d7b8` expands the same installer-owned cleanup to those known retired
paths. The focused installer regression passed 1/1, including unchanged owned
alias removal, exact preservation of two user-edited aliases and an unowned
note. The exact commit is `ee9d7b8815bfc32b2182cf7f601d439a843f7a1e`.
Its Full passed 136/136 Pester tests and 18/18 stages, with clean tree and
reusable qualification at
`build/test-results/qualification/openspec-r33-alias-final.json` in the fork.
Exact-commit init/update/doctor passed for all 12 clients, and builder Verify
checked 471 ledger paths. Source compatibility also rejects retired aliases
and manifest entries for the pinned 1.13.1 bundle.

The source client-routing batch exposed a strict-mode access to an empty
array's `target` property. The classifier now enumerates targets explicitly.
Four focused regressions passed after correction: old bundle compatibility,
native routes without Markdown-hash gating, selected-client route isolation
and duplicate retirement/retry, and secondary-client atomic MCP dispatch.
The last test had still expected separate per-family writers; it now checks
the single final-set owner and forbids those separate calls. Existing real
MCP ownership regressions retain the collision/no-write assertions.

The installed USER-RULES appendix also contained an obsolete authoring ban
for an execution-off test layer. It now states the agreed separation:
execution off does not prohibit needed test authoring and approved plans
remain preserved. The source overlay regression checks that meaning and
the continued fresh unfiltered assessment, partial-proof and closing gates.
Form-tool behavior remains checked by the fork's R8 policy owner, while
source overlay tests check the compact router and the owner's ledger entries.

The corrected source wrapper updated a new published-r33 clone successfully
to installed HEAD `20db908b67b36b9cb4f51eab1751f1fc58bd1181`, Git-clean.
Source clone commit: `d7ae10f2c879206aa41b5e2c6edadaa28864a169`;
fixture: `build/r33-final-63ffcdf6ad5241fea4982bc58712ceea`.
Explicit pinned CLI provisioning passed. All six canonical phase bytes and
their installed hashes match the actual helper's exact source checkout;
no retired alias files or manifest entries remain. Runtime reports native,
CLI 1.13.1. This accepts the corrected file transition, not native phase execution.

A fresh native Codex explore invocation in read-only unelevated Windows sandbox
stopped at `DotSourceNotSupported` / `ConstrainedLanguage` before context was
resolved. Its process exited 0 because it accurately reported the blocker;
that is **not** phase acceptance. A direct sandbox reproduction retained the
same failure on both the new helper and original published-r33 helper, without
changing paths, assertions or sandbox controls. The same new-helper context
action passed in the standard workspace permissions profile with unelevated
sandbox still enabled, returning this checkout's root and absolute pinned pair.
The read-only result remains an existing runtime-mode limitation. Fresh native
phase execution in workspace mode is now being checked.

Native probe records remain in the ignored build directory. No real projects,
user client config, global sandbox settings, live MCP providers or 1C bases
were changed. The official [Windows sandbox documentation](https://learn.chatgpt.com/docs/windows/windows-sandbox)
describes the two native sandbox implementations; it does not establish the
specific PowerShell language-mode behavior, which is observed probe evidence.

## Actual six-phase execution on the upgraded published-r33 fixture

Fresh ephemeral Codex CLI sessions on the installed `ee9d7b8...` candidate
executed explore, propose, update, apply, sync and archive in the unelevated
workspace sandbox. Explore resolved the exact checkout/root/Node/CLI pair and
left Git state unchanged. Propose and update preserved Context Sources and
accepted decisions, created only planning artifacts and passed CLI validation.

Initial apply produced the exact expected 65-byte UTF-8/LF document, but its
additional preservation script misparsed C-quoted Cyrillic Git paths and paused
at 1/2 tasks. The same task continued with strict UTF-8/NUL path transport:
2/2 tasks completed, the other 493 file hashes and tracked/index state were
preserved, and the permitted untracked set matched exactly. No assertion was
weakened or source metadata changed to hide the failure.

The approved documentation-only change legitimately used `skip_specs: true`.
Sync inspected the actual document/evidence and returned without a write because
no delta existed. Archive used the helper/pinned CLI and moved only that change
to `archive/2026-09-30-native-openspec-canary`, preserving artifact/document
hashes. This proves the six native entrypoints and the upstream no-spec path;
actual main-spec merge is a separate normative-delta acceptance case.

Records: `build/native-{explore,propose,update,apply,apply-resume,sync,archive}-workspace-ee9.*`.
Actual execution durations respectively: 127.61, 223.72, 144.44, 248.57 (paused),
367.20 (successful continuation), 117.33 and 172.35 seconds. These include model
work and are not helper operation-time or always-on context measurements.

## Main-spec sync, stopped archive and helper repair

An independent fixture supplied a real `native-proof-contract` baseline and an
ADDED requirement for the already verified document, without claiming sync had
run. The pinned CLI validated this change. Fresh native sync then added exactly
one requirement and preserved the complete existing baseline byte prefix.
Main-spec SHA256 changed from
`65ccbf19c8ea195ed719124c98a3f1115fcfd75963467945ee5fd5bf7c0831a2` to
`642bd7dc9a4edc3a09c5dc8c12328c45c657d44e6dc1b54215ddab888fd0b5a2`;
the document remained at its exact checked hash. Main-spec validation passed;
the other 502 files were preserved. Native sync took 175.84 seconds.

The native archive selected `OpenSpecArchiveSkipSpecs` because the delta was
already synchronized. It exposed an executable helper defect before mutation:
`Get-Agent1cReexecArguments` used `+=` on a generic List, producing a string and
then failing at `ToArray`. The initial archive process exited 0 while accurately
reporting the blocked task; it is not counted as passed. A direct reproduction
retained the same stack at helper line 344.

The source owner now adds this switch through the existing common argument
builder. A focused Pester regression passes selected/omitted switch cases,
exact change ID and a whitespace/Cyrillic project path (1/1 selected). No new
dispatcher, permissions or recovery state was added.

The same paused fixture then received the source repair via ordinary
`scripts/update-installed-workflow.ps1`, using private clean source commit
`0e2aa393fd5d1fbf657f11a5206b852f44c2e820`. Installed workflow commit is
`109ec6ef50a57547fd6adb0ae1970150cc88df79`. All eighteen protected document/spec
inputs were independently hash-checked before and after update. No infobase or
tests were run by file update; the active change was preserved.

Fresh native continuation of the original archive passed in 173.93 seconds,
using the repaired helper and CLI 1.13.1. It moved only the selected change to
`archive/2026-09-30-native-spec-sync-canary`, retained the six artifact hashes,
and left main-spec, first archive and document bytes unchanged. Independent
parent checks confirmed absence of the active root, unchanged synchronized main
spec and exact archived delta bytes. Failed proof was retained, not overwritten.

Ignored records: `native-spec-sync-{input,acceptance}.json`,
`native-spec-archive-acceptance.json`, `native-archive-helper-update-acceptance.json`,
`native-openspec-binding-acceptance.json`, and both
`native-archive-delta-{resume-}workspace-ee9.*` probe families under `build/`.
Read-only binding checks also switched between two real owned project roots and
their pinned runtime paths: stale checkout and borrowed CLI selections were
rejected as `OPEN_SPEC_STORE_BINDING_CHANGED`, and restoring the original
selection passed without file mutation.
