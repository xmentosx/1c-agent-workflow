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

## Completed review and supporting evidence

The modern compatibility overlay separates **only** `review_1c_code` presentation.
It does not change the vendor review prompt, collect another answer, require JSON,
filter findings, change `direct`, or alter deadlines/retries/cancellation.

After the existing collector completes and the existing sanitizer runs:

- `answer` contains the final review only when sanitized `final_text` is nonempty
  and is an exact suffix of the legacy assembled answer. Moving a prefix to
  evidence also requires sanitized `full_text` to equal that final text:
  no intermediate assistant findings may be hidden behind a final acknowledgement.
- `review_evidence.context` retains the preceding ITS search/document material
  only when this structural separation is proven. Missing or different
  `full_text` keeps the complete assembled answer in `answer`, including any
  intermediate review. There is no phrase, length, JSON or source-binding filter.
- The original rendered material and attribution stay in `context`. Native
  `PromptOutcome.tool_results` remains unchanged for existing internal consumers;
  its document bodies are not duplicated in the public envelope. The exchange's
  `reasoning_text` is not copied.
- `review_evidence.assembled_sha256` hashes the legacy **sanitized** assembled
  answer as UTF-8. Concatenate `context` with `answer` to reconstruct it.
  When an existing plugin or truncation verdict changes the selected text,
  `review_evidence.review_text` retains that selection instead; use it for
  reconstruction. The existing sanitizer's prior losses are not reversed.

`status=separated` means a prefix was moved to evidence; `unchanged` means the
final review already filled the answer (no text is moved). If the final is
missing, empty, not an exact suffix, or the prefix cannot be separated by the
contract above, `status=unseparated` keeps the complete legacy answer and empty
context. There is no new runtime rejection, retry, or readiness gate. These are
presentation statuses, **never** factual or semantic acceptance.
An acknowledgement such as "fixed in the code above" cannot replace a review
present only in earlier assistant text. The conservative fallback may make the
main answer longer; it adds no model request or retry and does not duplicate
the full text in `context`.

Readers must retain the evidence with the answer. A concise answer alone is not
the whole evidence record. Other tools keep their existing assembly behavior.
Sources/truncation/error handling and the existing plugin hook remain owned by
the vendor path. Deployment still requires normal component qualification; local
tests or queue registration do not install the overlay.

Run `python -X utf8 -B test_review_evidence.py` for offline regressions. The image
build also runs `--native` against the pinned model and review entrypoint with a
retained response stub, without an upstream request. Replays of actual saved
responses belong in ignored build evidence, not in the package or logs.
