# Native help client resolution — 2026-10-01

Two genuine installed Windows PowerShell 5.1 `help` observations took
48.811 s on the pure published-r33 canary and 41.310 s on the idle custom-source
canary. Both exited 0 with clean Git and unchanged global profiles. They were
single observations, not proof that cold start was the cause.

The causal observation retained the exact idle custom project root
`build/r39 r33 приёмка f79b62393df74eeba1fa341681e2723e`, native PowerShell 5.1,
and public helper arguments `-ProjectRoot <same root> -Action help`.
Command breakpoints measured the existing process-chain lookup and recorded
caller names and elapsed time only; no process command lines, credentials or
ancestry contents were saved. The before helper came from immutable source C
`92964456bf1931ad3a3d24af1250f6e244ea5574`.

| Observation | Total native helper time | Process-chain calls | Time inside those lookups |
| --- | ---: | ---: | ---: |
| Before | 43.833 s | 12 | 42.593 s |
| After owner-local display fix | 5.479 s | 1 | 4.233 s |

All twelve before stacks were
`Write-ItlActiveClientCommandText → ConvertTo-ItlActiveClientCommandText → Get-ItlActiveClient → Get-InitAgentExecutionProcessChain`.
The lookups consumed approximately 97.2% of the observed before operation.
This explains the repeated work and the local improvement; it does not promise
a fixed timing on other hosts.

The after helper used the source worktree with the announced display change,
not a patched installed copy. The project HEAD stayed
`06c0944e2d0528683320ba7869ca7afe9dcd43ff`, Git stayed clean, and the same
14 real global file hashes stayed unchanged in both observations. Native
stdout was byte-identical before, after and the original root observation,
including the complete whitespace-and-Cyrillic path and Russian text.
All three logs have SHA-256
`ab979d389638c95b9c163f98dd36f29a6545df9910ea58e9f7d345b43bfbf4dd`.
The original cold observations remain present.

## Owner boundary and focused checks

`Show-Help` resolves the executing display client once in a function-local
variable. It forwards that explicit client through the existing command-text
converter and writer. Each resolved command still calls the authoritative
`Get-ItlActiveClient -Client` and keeps configured/installed membership checks.
An explicitly unresolved display client keeps the existing plain command-text
fallback. `Get-ItlActiveClient` and execution-context discovery are unchanged;
there is no global cache, persistent owner, new permission or disabled guard.

The same explicit client is forwarded to the already supported
`Get-AiRules1cOpenSpecStatus -Client` and Kilo display check within dev help.
The first focused context test exposed that omitted status argument as a second
lookup; it was fixed at the existing caller without changing status ownership.
That final dev-only adjustment follows the native master measurement above.
The final full function body is covered by the nine prefix/context comparisons.

Exactly two selected regressions in `ClientMembership.Tests.ps1` ran under
Windows PowerShell 5.1.26100.9549 and Pester 5.8.0. They passed, with 66 source
and test input hashes unchanged during the run. The first compares complete
explicit-client output with automatically resolved output for Codex, Kilo and
Kimi across master, itldev and unknown branch contexts, preserving the original
Unicode path, branch identity and command prefixes; each uses one lookup.
The second retains rejection of an unattached executor, ambiguous context and
configured/manifest mismatch, plus plain help fallback without choosing a
foreign client. No real client profile, registry writer, MCP or 1C was invoked.

The initial test capture's default `Out-String` inserted console-width breaks
into the long path. Its failure is retained; only test capture width was made
explicit, keeping the root and exact assertions. The next retained failure
exposed the real dev status lookup described above. No failing expectation or
reproducer workload was removed. Source/test UTF-8 BOMs remained present and
Windows PowerShell ParseFile returned zero errors for all three changed files.

Artifacts:

- `build/native-help-client-resolution-before-20261001.json`, SHA-256
  `99161aab8fdc5ad489a2829320c2a7e18c1a1b26f4c22c979163ffa6be4a66dc`;
  matching `.log` retains native output.
- `build/native-help-client-resolution-after-20261001.json`, SHA-256
  `2787bf2862f75ee306a4119c7b263209425e10566920667dc399c8817a8f9ac5`;
  matching `.log` retains identical native output.
- Final selected-case record:
  `build/client-help-owner-a095a3f2a5e544c3a2dbcb0f99892ec8/`,
  `result.json` SHA-256
  `153420b1888ff03c4897485113f7aaa9bec60e8c4d6ccadc2ee678a7156f8819`,
  `inputs.json` SHA-256
  `897a7ecd8eccf47d1b5e985fbd2f7bd0f7a0401da78263d30172701af7ba11e3`,
  and `pester.xml` SHA-256
  `bd9afcf75a3c55435a5d5695dd69fd2a6047be52c77a6ade1282359b67cb44a6`.
- Retained selected-case failures:
  `build/client-help-owner-2ef2b80ea3784ac7aa4c84ac89b54f69/` and
  `build/client-help-owner-3c10e4a2a9f941bbb33d74e429889945/`.

This is focused source-owner evidence. It neither qualifies a released package
nor retroactively changes immutable C/C2 canary identities. No broad source
gate, source registration, publication or ordinary-project installation ran.
