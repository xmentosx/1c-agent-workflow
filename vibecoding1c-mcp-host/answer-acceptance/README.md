# Offline CodeChecker answer acceptance

This source-side helper owns acceptance of retained **whole answers** in our
CodeChecker qualification work. It makes no MCP/AI calls and is excluded from
the server Docker build. It does not modify the server, prompt, returned Markdown,
retry policy, installed projects or lifecycle eligibility.

## Use the actual submitted input and retained result

Run with an explicit Python 3 interpreter; paths may contain whitespace and
Cyrillic. The source component tests use the existing CodeChecker test runtime.

```powershell
& $Python -X utf8 -B .\vibecoding1c-mcp-host\answer-acceptance\assess.py prepare `
  --code 'C:\Evidence\исходный код.bsl' `
  --response 'C:\Evidence\полный MCP result.json' `
  --out 'C:\Evidence\приёмка ответа'
```

Alternatively, `--answer` takes an existing UTF-8 plain-text answer. This does not
prove MCP transport identity: the reviewer must bind it to the submitted source.
`--response` accepts a saved MCP result, JSON-RPC result or capture `response`
envelope; incompatible answer/result/content copies remain unusable.

`prepare` creates a new packet directory and refuses to replace existing evidence.
It retains source and response bytes, extracts the complete answer without newline
normalization, and writes `packet.json` and an initially pending `review.json`.
Hashes bind the review to exact source/response/answer identities. Each paragraph,
table line and fenced code block is included, including introductions, extra
findings, recommendations and conclusions. Unrecognized Markdown remains text.
Raw replies can contain private code: keep these packets in ignored evidence
directories; hashes do not make a packet content-safe telemetry.

## Review every unit, then assess the same packet

Edit only `review.json`. Set a reviewer identity and explicitly assess format
(`pass`, `fail` or `unverified`, with rationale) against the preserved prompt.
For each unit keep its id/hash and record one verdict with rationale:

- `supported`: its claims agree with the source and applicable contract;
- `contradicted`: an exact witness disproves a claim in this unit;
- `out-of-scope`: for example, an excluded style finding or untested repair advice;
- `unverified`: evidence is insufficient; this is not a disproven finding;
- `not-a-claim`: genuinely non-assertive headings/separators, not a way to ignore
  inconvenient prose; an answer with no supported analysis cannot pass;
- `pending`: the unit has not been reviewed.

`supported` and `contradicted` require a concrete `witness` and `evidence` array.
Review **all** claims within a unit; one correct sentence cannot validate another.
For a logic defect, explain input/path, actual result, required result and the
source of that requirement. Presence, Boolean output and value are distinct;
unreachable code, names or hypothetical future requirements alone prove no defect.
For performance, identify reachable scalable work without invented measurements.
Record platform details as unverified unless the actual evidence supports them.

```json
{
  "verdict": "supported",
  "rationale": "The quoted return determines this path; no other result is required.",
  "witness": "Any call reaches Return 0 and returns 0.",
  "evidence": [{"kind": "source", "quote": "Возврат 0;", "line": 2}]
}
```

Each quote must occur at the stated one-based source line, including multiline
quotes. `kind: reference` instead requires an absolute retained UTF-8 `path`, its
`sha256`, exact `quote` and `line`; no URL is fetched. Source/reference matching is
mechanical. The helper does **not** prove language semantics or the reviewer's
rationale: those decisions remain with the existing reviewer/evidence owner.

```powershell
& $Python -X utf8 -B .\vibecoding1c-mcp-host\answer-acceptance\assess.py assess `
  --packet 'C:\Evidence\приёмка ответа' `
  --review 'C:\Evidence\приёмка ответа\review.json'
```

`assessment.json` separates rejected units from unresolved evidence. Missing,
duplicate, stale or altered coverage cannot pass. Every unit must be resolved,
there must be supported substantive analysis, and format must pass before the
**answer quality** result is `accepted` (exit 0). Proven contradictions, excluded
scope or format failures produce `rejected` (exit 1); incomplete review/evidence
produces `unverified` (exit 2). Known rejection and unresolved evidence are both
retained; no finding or original text is removed to obtain green output.

Correct a missing reference or review entry and repeat `assess` on the same packet.
Changed input needs a new packet and fresh affected decisions. Neither a primary
classification nor a successful transport result substitutes for whole-answer
acceptance. Do not keep calling AI until it returns a convenient answer.

A rejected **answer** does not establish a defect in product code and does not
force appeasement edits. Resolve individual product findings through the existing
controlled-fork verification/evidence policy; syntax/runtime/fresh-proof duties
remain independent. This helper adds no lifecycle barrier or new risk authority.

## Source verification

`host-answer-acceptance` selects `HostAnswerAcceptance.Tests.ps1`, separately from
overlay transport/prompt tests. It uses the existing CodeChecker stdlib-only test
runtime; external runtime identity keeps this shard non-reusable. A runtime-owner
change selects this consumer too. The independent host-selection regression proves
selection and reuse applicability. The initial focused wrapper took 2.99 seconds
(17 Python cases took 0.50 seconds); two additional Unicode/malformed-input cases
extend that same suite. Catalog validation remains its separate existing owner.
