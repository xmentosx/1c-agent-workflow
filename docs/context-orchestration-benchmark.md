# Installed-project context orchestration benchmark

This diagnostic compares context-management modes for work performed by the installed workflow in real 1C projects. It does not cover maintenance of the `1c-agent-workflow` source repository and does not enable coordinator, rotation, hybrid, or RLM policy.

## Scope and phases

The first phase accepts sanitized aggregate records for four modes:

- `S0` — current behavior;
- `C` — one coordinator session with bounded subtasks;
- `R` — phase-by-phase task rotation through a durable checkpoint;
- `H` — bounded subtasks plus safe coordinator rotation.

The synthetic fixture proves the record and decision contracts only. A real pilot remains blocked until the user explicitly names installed projects and test contours; the harness must not infer them from nearby worktrees or runtime state.

## Input contract

Use `tests/pester/fixtures/context-orchestration-benchmark/exact.json` as the schema example. Each scenario must contain exactly one `S0`, `C`, `R`, and `H` record. Comparable records use the same:

- client and model;
- project fingerprint;
- checkout commit and dirty-state fingerprint;
- infobase snapshot fingerprint;
- required gate set.

`outcomeFingerprint`, passed gates, locked-decision counts, wrong-scope actions, and dirty-state violations represent result equality. A mode is never efficient when its result is not equivalent to `S0`.

The schema is closed. Do not add prompts, messages, raw transcripts, tool arguments, secrets, credentials, connection strings, source bodies, or long logs. Store only counters, fingerprints, status, and provenance. Every record must explicitly assert that it is sanitized.

## Telemetry boundary

`telemetry.tokenEvidence` has three values:

- `exact` — all parent and child input/output token counters plus exact peak parent context are present;
- `proxy` — only `messageCharacters` is present; it is not converted into tokens;
- `unavailable` — neither token nor proxy counters are present.

Exact and proxy fields cannot be mixed. Proxy and unavailable modes may pass functional equality but remain `functional-only`; they cannot be called token-qualified and receive no token-reduction percentages. Total tokens always include parent and child calls.

`context-benchmark` remains a separate Kilo-only baseline diagnostic for initial rules/MCP context. Its results are not conversational-growth records for this benchmark.

## Run the analyzer

The script is read-only unless `-OutputPath` is supplied. The explicit output contains only an aggregate summary and cannot overwrite the input record set.

```powershell
$root = (Get-Location).Path
$script = Join-Path $root ".agents\skills\1c-workflow\scripts\context-orchestration-benchmark.ps1"
$input = Join-Path $root "tests\pester\fixtures\context-orchestration-benchmark\exact.json"
$output = Join-Path $root ".agent-1c\diagnostics\context-orchestration\summary.json"
& $script -InputPath $input -OutputPath $output
```

Installed-project measurements should write ignored diagnostic artifacts under `.agent-1c/diagnostics/context-orchestration/`. Recording or analysis must not launch 1C, mutate project sources, or run verification gates.

## Decision gate

A candidate is `eligible` only when every scenario preserves result equality and the exact aggregate metrics show:

- at least 25% median total-token reduction against `S0`;
- at least 40% median peak-parent-context reduction;
- no more than 15% median elapsed-time regression;
- at most five targeted reads to resume;
- at most 1500 checkpoint tokens;
- no context overflow, repeated unchanged gate, wrong-scope action, or dirty-state violation.

The thresholds select a candidate for the later policy implementation; they do not implement or enable that policy.

## Later capability mapping

Before a real pilot, each client adapter must separately declare:

- subtask launch: native, reference-only, or unavailable;
- continuation creation: automatic, suggested-manual, or unavailable;
- continuation switch: automatic or user action;
- usage telemetry: exact, partial, or unavailable;
- safe manual fallback through a portable checkpoint.

This phase deliberately does not change adapters. A client without exact usage telemetry can be functionally qualified but cannot prove token savings.

## RLM boundary

RLM is not part of this harness. A read-only RLM sidecar may be investigated only after `C`, `R`, and `H` fail on large sanitized static inputs. Such a spike must have explicit depth, call, token, cost, and timeout limits; no write tools, secrets, infobase access, lifecycle commands, or production policy are allowed.
