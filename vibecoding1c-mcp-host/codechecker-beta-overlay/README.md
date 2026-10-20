# Direct retrieval and search completion

`fetch_completion.py` adapts the pinned vendor client at its existing ACK-stream
boundary. It accepts the upstream result of `its.fetch`, `its.search` and
`documentation.search` without waiting for subsequent assistant synthesis.
The search contracts cover `its_help`, `search_1c_documentation` and its
`onec_help` alias in direct mode.

Completion requires all of the following:

- An available capability with the exact qualified upstream name and argument
  set (`id`, `query`, or `query` plus `version`), containing non-empty strings.
- One completed assistant tool call matching those arguments exactly.
- A completed successful tool result matching the assistant UUID, call ID
  and upstream name, with structured non-empty text and `truncated: false`.

The original text and tool-result envelope are preserved. In particular,
`its_help` continues to build document records from the upstream envelope;
documentation search keeps the vendor's `version_used` handling. A partial,
ambiguous, mismatched or erroneous result stays on the native path. Empty
structured text is not inferred to mean a successful zero-result search.
The existing `_itl_fetch_completion` internal marker and
`its_fetch_completion` telemetry name remain compatible; telemetry reports
the actual capability. Only the existing `fetch_its` public result schema
exposes the completion marker. Search response schemas remain unchanged.

This is not completion of the assistant generation. It adds no retries,
conversation reuse, time budgets, transport monkey-patches or new state owner.
The native client still owns discovery, ACK, guards, deadlines and cleanup.
Prompt-mode logic/review/configuration/rewrite answers are not short-circuited
by intermediate search or syntax results.

The regression suite runs with standard Python, and `--native` additionally
uses the pinned binary client with deterministic HTTP streams. It proves the
original wait after a ready result, accepted completion, rejection of partial
results, cancellation, guard release and UTF-8 chunk handling. Docker image
construction runs these native tests. Live checks must additionally inspect
the completion telemetry: a fast native answer after a truncated result is
not evidence that the adapter completed it.

The adapter cannot fix a provider stream containing only a user message and
an empty unfinished assistant. Such a stream has no result to return. Provider
generation/event delivery owns that failure; conversation reuse remains a
separate diagnostic hypothesis, not an installed recovery policy.
