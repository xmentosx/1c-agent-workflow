# Operation evidence

Operation evidence is an explicit diagnostic sidecar over the existing portable measurement runtime. It is not part of ordinary `/itl-check`, does not select its own diagnostic depth, and does not define product readiness or business equivalence.

## Version and files

Scenario/request v1 keeps the original behavior and has `result.operationEvidence.status=notRequested`. A diagnostic scenario uses schema v2 and declares:

```json
{
  "diagnostics": {
    "schemaVersion": 1,
    "level": "D1",
    "evidencePath": "private/operation-evidence.json",
    "required": false
  }
}
```

The path is relative to the iteration and must stay under `private/`. The adapter writes raw evidence there after the measured operation reaches its declared boundary. The runtime analyzes it after timing, preserves the raw file locally, and writes a public normalized `operation-evidence.json`. Result transfer excludes every `private` path. A v2 package is rejected by a v1 worker before `action`; the controller never silently downgrades it.

The sidecar schemaVersion 1 binds `jobId`, numeric `iterationId`, and a fresh `operationId`. It contains the selected D0-D3 level, explicit clocks, spans, causal links, coverage, milestones, equivalence status and stream completion. Product adapters own phase names, correlation propagation, readiness predicates and equivalence checks. Unknown values use `null` plus a reason; they are never encoded as zero.

## Interpretation

- A span duration records availability, evidence kind, value and unit. Large ticks use decimal strings so JSON readers cannot round them.
- `rpc` links require one matching call ID. `C-S` is emitted only for compatible durations of that correlated call and is labelled uncovered client-window time, never pure network time.
- Dependency links must be acyclic. Critical paths use the longest proven dependency path; parallel branches are not summed. Missing duration, incompatible clocks or incomplete dependencies leave the path partial.
- Truncated streams, dropped events, unclosed spans, unknown coverage and unverified equivalence stay visible as partial evidence. An invalid sidecar does not erase a separately verified timing sample.
- Diagnostics are opt-in and separate from profile mode. The runtime does not decide when D1, D2 or D3 is mandatory.

`result.json` remains schema v1. Its additive `operationEvidence` field contains per-iteration status, level, operation ID, normalized path/hash, coverage and limitations. Existing `timings`, `phases`, `summary`, profile evidence and historical compare retain their meanings.

## Deferred product and live contract

Automatic depth thresholds, product BSL probes, `firstViewApplied`/`editable`/`fullyReady` predicates, complete business equivalence, background-session ownership, live overhead experiments and treatment-aware A/B are separate product/live work. Until supplied by an authorized adapter and stand, those capabilities remain unverified.
