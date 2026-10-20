# R45: canonical release provenance

The accumulated Develop candidate failed `fork-check` after all 3469 workflow
Pester tests passed. Its local r44 annotation did not contain the canonical
`upstream=refs/heads/main@<commit>` provenance. A fork Full invoked with an
explicit SHA recorded `upstreamRef=explicit`, which does not match the locked
`refs/heads/main` identity and cannot replace release qualification.

R45 uses commit `b5177c16b236a9177d2c18e23600c5daaf9ce993`, an empty release
preparation commit after r44 `0e304aaa7989df1daaec1fc4b7b38e419188aec9`. Both
commits have the same tree `37f81b3019f436e9f87ec620ecbbd2c2e3f68998`.
The existing r44 tag is preserved. The fork's `publish-fork-release.ps1` owns
the new annotation and release branch. The audited upstream remains
`5700f54a899abb1e8b6483badd6986e5a0e6c1af`.

The workflow lock remains `pending` until the standard source-delivery
compatibility qualification and promotion. Local preparation and registration
do not establish publication, installation, or live E2E acceptance. Preserve
the original failed candidate and its evidence; ordinary exact-input shard
reuse may retain the passed workflow tests during the next qualification.
