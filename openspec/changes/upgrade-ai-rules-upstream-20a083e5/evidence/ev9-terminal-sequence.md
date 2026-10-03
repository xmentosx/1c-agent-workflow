# EV9 terminal consumer preparation, 2026-10-03

The existing Kilo stand already configures the managed Vanessa UI facade.
The current Codex task does not expose that Kilo MCP connection. The previous
diagnostic probe supported one arbitrary call or a fixed Release smoke; neither
could execute the accepted seven-call form journey in one session. The fixed
smoke's workload is retained and is not presented as the 7-to-14 acceptance.

The existing `tools/itl-ondemand-mcp/cmd/itl-ondemand-probe` now accepts optional
`-sequence-json`: an ordered array of existing inner tool names and arguments.
It validates UTF-8/BOM JSON and the actual compatibility catalog before launch,
then uses one existing ClientSession, callInnerTool and closeMeasured owner.
Real arguments/results are retained, including partial failure evidence;
an error or cancellation stops subsequent calls. It does not infer product
acceptance from call completion. Ordinary single-call and fixed smoke modes
remain available. Sequence mode cannot combine with replay or multiple instances.

This is a diagnostic consumer change. The production executable builds module
root package `.` and does not import this command. Production executable/version/
asset pins, the facade, helper guards, catalogs, stand settings, installed
migration and the native component's 43 build inputs remain unchanged. No new
MCP tool, runner, coordinator or client membership is introduced. Existing
Targeted owner `mcp-hosts` covers these source paths.

Fresh Go 1.26.4/windows amd64 owning-package verification passed 19 top-level
tests and eight subtests (27 passed events, zero failures) in 11.078 s. The same
batch includes existing single-call, fixed cold/hot/selected smoke, timeout,
client-close, backend-error and handoff cases. New cases cover actual seven-call
in-memory session order and observations 7/14, Unicode/space input and evidence
paths, fail-fast retaining IsError, cancellation/cleanup failure and invalid
input refusal before launch. All seven captured inputs remained unchanged.

Receipt `build/ev9-probe-sequence-3e7637a9f92a4e289294a93fc696d5c6/qualification.json`
SHA256: `aec14e9820c118ef0fc31026bcb4b8e2c32ed02608ce25f66cd3813aeabe77f3`.
Independent read-only review found no material findings; strict OpenSpec
validation passed after the evidence update.
These are consumer tests, not live 1C or MCP acceptance. The actual installed
form journey, snapshots, one-off proof and cleanup remain pending, after exact
paired publication and installation on the existing authorized dev/test stand.
