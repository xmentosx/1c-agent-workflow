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

For an initial investigation, D1 is the normal operation-map target when a product adapter is available. D0 is a smaller outer-boundary measurement; D2 expands only a selected expensive window, and D3 is reserved for an explicit costly hypothesis. Choosing a level does not authorize a retry or a modifying run.

## Product producer contract

A useful D1 document describes one execution, not a comparison. It should provide:

- one root `container` span for every observed client, server or background window; domains may overlap and are never added as a wall-clock total;
- nested semantic spans with stable names, `parentSpanId`, domain, boundaries, duration, status and source reference;
- one client `rpcWindow` and one correlated server span per observed synchronous call, joined by a unique `callId`;
- request and response payload records that keep semantic counts, diagnostic serialization size and qualified wire bytes separate;
- background operation identity and available lifecycle stages from submit through result application;
- product milestones and a coverage status for every expected domain.

The portable runtime does not invent these product facts from a profile. A profile can identify expensive modules and lines, while spans establish operation order and causality. Missing producers remain explicit `unknown` or `notApplicable` with a reason.

The supplied `OperationEvidenceFragment.bsl` creates in-memory, JSON-serializable fragments. It deliberately has no filesystem writer: a real server or background session generally cannot address the worker iteration directory. The product adapter owns correlation and transport of each fragment. Once the measured operation and its readiness predicate have completed, scenario-side Python calls `itl_measure.publish_operation_evidence(envelope, fragments)` to validate identities, merge collections, inventory missing producers and atomically write the configured private sidecar. Raw arbitrary payload values are outside this contract.

The envelope declares every expected emitter with `emitterId`, domain and whether it is required. Every fragment repeats `jobId`, `iterationId`, `operationId`, emitter and domain, plus coverage and stream status. Foreign operation identity, an unexpected/duplicate emitter or a colliding clock/span/background ID is invalid. A missing, truncated or lossy producer yields a valid partial map with an explicit limitation; it never disappears silently and never invalidates a separately verified outer timing.

The scenario-side assembly call is intentionally small; `client_json` and `server_json` may be serialized BSL strings, dictionaries or private JSON paths:

```python
from itl_measure import publish_operation_evidence

publish_operation_evidence({
    "operationId": operation_id,
    "expectedEmitters": [
        {"emitterId": "client", "domain": "client", "required": True},
        {"emitterId": "server", "domain": "serverWithoutContext", "required": True},
        {"emitterId": "background", "domain": "background", "required": False},
    ],
    "equivalence": {"status": "verified", "checks": verified_business_checks},
}, [client_json, server_json, *background_json])
```

Keep the BSL helper in a diagnostic extension, external processor or project-owned test adapter when that can observe the required boundaries. Changing the main configuration is not a prerequisite of the format. If no external adapter can see an internal boundary, leave that coverage unknown or make a separately authorized product instrumentation change; do not infer the missing block from total time.

## Interpretation

- A span duration records availability, evidence kind, value and unit. Large ticks use decimal strings so JSON readers cannot round them.
- `rpc` links require one matching call ID. `C-S` is emitted only for compatible durations of that correlated call and is labelled uncovered client-window time, never pure network time.
- Dependency links must be acyclic. Critical paths use the longest proven dependency path; parallel branches are not summed. Missing duration, incompatible clocks or incomplete dependencies leave the path partial.
- Truncated streams, dropped events, unclosed spans, unknown coverage and unverified equivalence stay visible as partial evidence. An invalid sidecar does not erase a separately verified timing sample.
- Diagnostics are opt-in and separate from profile mode. The runtime does not decide when D1, D2 or D3 is mandatory.

`result.json` remains schema v1. Its additive `operationEvidence` field contains per-iteration status, level, operation ID, normalized path/hash, coverage and limitations. Existing `timings`, `phases`, `summary`, profile evidence and historical compare retain their meanings.

Every valid diagnostic iteration also produces public `operation-evidence.md`. It presents:

1. expected and observed producers, including missing/truncated streams;
2. recorded root windows by domain;
3. the nested operation-step tree;
4. correlated RPC client/server/remainder durations;
5. request/response semantics, counts, diagnostic bytes and wire bytes;
6. background lifecycle, milestones and product-result status;
7. coverage, clock domains, the proven critical path and limitations.

The main `report.md` links each diagnostic iteration to this map. Local, SSH and agent routes use the same renderer on the execution host and transfer the same public JSON/Markdown artifacts. Arbitrary raw payload values are not rendered; private evidence remains local.

## Deferred product and live contract

Product-specific placement of the neutral BSL probes, `firstViewApplied`/`editable`/`fullyReady` predicates, complete business equivalence, background-session ownership, live overhead experiments and treatment-aware A/B are separate product/live work. Until supplied by an authorized adapter and stand, those capabilities remain unverified.
