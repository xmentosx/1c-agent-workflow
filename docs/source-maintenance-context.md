# Durable context for source maintenance

This source-only contract preserves the objective and next safe action of work on
`1c-agent-workflow`. It is separate from source-delivery plans, qualification
evidence, and publication checkpoints. It is not copied into installed projects.

## Wave A baseline (2026-09-13)

The baseline used five completed Codex source-maintenance sessions selected by
task class. The collector read only exact JSONL sessions and retained aggregates;
it did not retain prompts, user messages, assistant messages, or tool output.
Token totals are sums of each `last_token_usage` record, so resets between turns
or compactions do not discard work. `Peak` is the largest single input divided by
the reported 258,400-token context window. Tool-result size is UTF-8 serialized
bytes; the five largest results are identified only by tool type and size.

| Class / session suffix | Input total | Cached / uncached input | Output | Peak | Compact | Turns / tools | Tool result bytes | Exact repeat proxy | Result boundary |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Small documentation / `019fc1aa` | 906,220 | 832,256 / 73,964 | 7,579 | 62,988 (24.4%) | 0 | 4 / 13 | 151,560 | 0 / 0 / 0 | local-only change complete; publication excluded |
| PowerShell + focused regression / `01a0211e` | 15,407,573 | 15,140,096 / 267,477 | 37,214 | 212,978 (82.4%) | 0 | 1 / 86 | 544,029 | 0 / 0 / 0 | implementation and focused evidence registered; not published |
| Owner/test selection / `01a01978` | 439,737,423 | 434,807,808 / 4,929,615 | 586,954 | 244,835 (94.8%) | 10 | 8 / 3,161 | 6,171,245 | 171 / 0 / 2 | repair registered; accumulated publication remained incomplete |
| Source-delivery failure diagnosis / `01a03ada` | 313,671,570 | 309,803,008 / 3,868,562 | 423,534 | 244,657 (94.7%) | 7 | 6 / 2,350 | 4,485,353 | 134 / 0 / 2 | diagnosis complete; requested release incomplete |
| Continued source task / `01a0400c` | 172,229,993 | 169,980,416 / 2,249,577 | 226,973 | 244,621 (94.7%) | 4 | 3 / 1,252 | 2,092,924 | 67 / 0 / 3 | release continuation complete |

The repeat proxy is `read / search / gate`: the same exact call repeated with no
observed repository mutation between calls. It is conservative for semantic
re-reading and does not prove an unchanged gate input fingerprint. No exact call
crossed a compaction boundary in this sample, and no assistant message contained
a structured objective/scope/stage/next-action restoration. Those two measures
are therefore `unknown` for unstructured recovery, not zero semantic recovery.

The five largest tool results were all command-execution results. They comprised
95.5% of tool-result bytes for the documentation task, but only 39.7%, 3.7%,
5.0%, and 10.4% in the other four sessions. The baseline therefore supports two
bounded conclusions: long tasks can reach 94.7-94.8% peak context and compact
repeatedly, while a universal claim that a few large outputs dominate long tasks
is not established. Cached input must remain separate from uncached input: cache
hit rates were high, but cached replay still occupied the context window.

No numeric checkpoint or rotation threshold is defined by Wave A. Later A/B must
compare tasks with the same behavior and evidence completeness. The preselected
pairs are: small documentation with manual checkpoint vs the same class with
prompted rotation; PowerShell + focused regression with the same pair; and a
source-delivery diagnosis continued from a safe boundary with and without a
checkpoint. Total/cached/uncached input, output, peak, elapsed time, repeated
reads/searches/gates, compactions, and result completeness must all be retained.

## Storage and authority

Run `scripts/source-maintenance-context.ps1` from the exact source worktree. A
task is stored at:

```text
<git-common-dir>/itl/source-maintenance/v1/<lowercase-task-id>.json
```

The common Git directory makes state visible to worktrees in the same clone and
keeps it outside tracked and untracked worktree state. It is not portable between
clones. The helper does not create or rotate app tasks, mutate Git, run tests or
gates, invoke source delivery, commit, register, publish, or grant authority for
any of those actions.

The state contains `schemaVersion`, `taskId`, `updatedAt`, `objective`, `scope`,
`exclusions`, repository/common-Git/worktree paths, branch, base/HEAD/tree,
fingerprinted staged/unstaged/untracked paths, `stage`, `approvedPlan`,
`ownerContracts`, `changedPaths`, compact decisions/evidence/blockers,
`nextAction`, and aggregate telemetry. A missing client metric is the string
`unknown`, never numeric zero.

## Safe payload

`Checkpoint` accepts a UTF-8 JSON payload through `-PayloadPath`. Its top-level
fields are exactly:

```json
{
  "objective": "one compact objective",
  "scope": ["authorized unit"],
  "exclusions": ["explicitly excluded work"],
  "stage": "implementation",
  "approvedPlan": ["bounded step"],
  "ownerContracts": ["source-maintenance-context"],
  "changedPaths": ["repository/relative/path"],
  "decisions": [{"decision":"choice","reason":"evidence","rejectedAlternatives":["alternative"]}],
  "evidence": [{"kind":"test","commandType":"focused-pester","artifact":"safe path","inputFingerprint":"sha256","status":"passed","recordedAt":"UTC time","summary":"compact result"}],
  "blockers": [{"code":"CODE","summary":"bounded diagnosis","requiredAction":"one external action"}],
  "nextAction": "exactly one concrete action",
  "telemetry": {"inputTokens":"unknown","compactions":0,"resultComplete":false}
}
```

Stages are `discovery`, `plan`, `implementation`, `verification`, `registered`,
`blocked`, and `complete`. Nested objects have fixed allowlists and bounded text.
Unknown fields fail closed. Fields suggesting prompts, transcripts, responses,
raw output, credentials, or secrets are forbidden. Secret assignments and bearer
credentials found inside allowed compact strings are replaced with `[REDACTED]`.
Do not put `.dev.env` values, file contents, raw commands, prompts, model answers,
tool output, PID-only liveness claims, or inferred commit/delivery permission in
the payload.

## Identity and operations

The helper captures identity with read-only Git commands. Path inventories are
NUL-delimited. Staged entries use their index object ID; unstaged and untracked
files use SHA-256 plus size; deleted files use a deletion marker. Contents are
never stored. The combined dirty fingerprint covers sorted status/path records.

Create a checkpoint:

```powershell
$payload = Join-Path ([IO.Path]::GetTempPath()) 'WF-CTX-01.safe.json'
.\scripts\source-maintenance-context.ps1 -Action Checkpoint `
  -TaskId WF-CTX-01 -PayloadPath $payload
```

`Status` reports the state SHA, stage, and any mismatch without exposing the
checkpoint body. `Resume` returns the safe checkpoint only when repository,
common Git directory, worktree, branch, HEAD, tree, and dirty fingerprint match
exactly. `Complete` requires the matching `-ExpectedStateSha256`, repeats the
same identity check, sets `stage=complete`, and sets `nextAction=none`.

Updating an existing checkpoint is a compare-and-swap operation. Pass the SHA
returned by `Status` or `Resume` as `-ExpectedStateSha256`. Exact Git state is the
default. After an intentional edit or descendant commit, also pass
`-AdvanceGitState`; topology and branch must still match, and a changed HEAD must
be a descendant of the saved HEAD. This records advancement explicitly without
authorizing or performing the Git change.

State writes use a temporary file in the destination directory, write-through
flush, and atomic move/replace. A failed replacement leaves the last valid state
readable and removes the temporary file.

Safe checkpoint boundaries are after an approved plan, after a coherent edit,
before and after a long external verification, before handoff, and before/after
`RegisterChange`. A checkpoint is never a delivery boundary or test result. Do
not switch tasks during an atomic edit, Git operation, or foreground gate.

Wave A intentionally adds no root `AGENTS.md` route: the file measured 1,150
words and 2,102 approximate UTF-8-byte tokens, exactly its word hard limit and
above its review threshold. Adding a route without proven removable duplication
would weaken or exceed the existing contract. Rotation/coordinator behavior,
installed-project templates and skills, controlled `ai_rules_1c`, delivery
semantics, and RLM remain outside this wave.
