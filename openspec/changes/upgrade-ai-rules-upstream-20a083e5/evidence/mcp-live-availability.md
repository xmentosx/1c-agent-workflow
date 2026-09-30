# Live MCP qualification boundary

The four configured native providers remain unqualified from this host. The
earlier real `initialize` calls to Docs, Templates, Syntax and Code Checker each
reached the 20-second discovery deadline without a session or tool catalog.
Their original requests and results remain in the ignored `build/mcp-live-*`
artifacts. Configuration, a port probe and fixture tests cannot substitute for
`initialize -> notifications/initialized -> tools/list -> tools/call`.

On 2026-09-30 at 17:39:38 UTC a bounded read-only reachability check resolved
`dev-ermakov.itland.local` to `10.0.12.53`. None of ports 18000, 18001, 18002 or
18003 connected within the shared three-second budget. This is only TCP
evidence, not an MCP result. The raw record is
`build/mcp-reachability-20260930-final.json`. Since no connection became
available, the failed protocol calls were not repeated.

A second bounded read-only TCP check at 18:50:56 UTC had the same outcome for
all four ports. Its separate record is
`build/mcp-reachability-20260930-late.json`. No protocol success or provider
callability is inferred from this probe.

After more than three hours, a further bounded read-only TCP check at
2026-09-30 22:03:59 UTC (2026-10-01 in Moscow) still reached none of the four
ports. `build/mcp-reachability-20261001.json` retains the result. The protocol
calls were not repeated while this prerequisite remained unavailable.

A bounded transport check at 2026-09-30 23:44:36 UTC again connected to none
of these four ports. Its separate record is
`build/mcp-reachability-20261001-post-source-commit.json`; all attempts timed
out. This remains transport evidence only and does not qualify a provider.

During the next source registration, a one-time parallel transport refresh at
2026-10-01 01:30:19 UTC resolved the same host to 10.0.12.53 and again timed out
on all four ports within the shared 3000 ms bound. Report:
`build/mcp-reachability-register-refresh-20261001-013019.json`, SHA256
`7167b8a0b7fed89d7552aded9ecd64adda632909d6bc4140e6c0ef9032a7103f`.
No initialize/tools-list call was made while this prerequisite was unavailable.
Provider functionality remains unverified, rather than a failed provider test.

Q9 standards through Docs and metadata/code templates through Templates remain
separate pending functional checks. Platform verification of configuration
Template objects is independent and has its own native Designer evidence in
`reused-stands-and-template-platform.md`; the unavailable provider does not
erase that proof or justify changes to its object-verification implementation.
Actual syntax/logic validator calls and executed agent evaluations also remain
unverified where their providers are unavailable. No alias, CLI or direct HTTP
substitution was used to bypass provider policy.

Resume the provider-dependent checks when the configured endpoints become
reachable from this host, using the existing qualification driver and the exact
exposed schemas. No server restart, client-profile rewrite, credential copy or
production project update is authorized by this availability probe.
