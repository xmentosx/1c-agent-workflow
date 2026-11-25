# New helper recovery and multi-client update — 2026-09-30

All operations below used disposable, local Git fixtures without an infobase.
The controlled rules fork was the clean, locally qualified commit
`38d315de9cf611ca211619fec7f9a2254e7ef04e`, tree
`3a9ec9b49444c9a6ae47affa83152fb9a30e76da`. Its local canary tag is not a
published or installable release. The source package's delivery pin remains r36.

The fixture originated from the published-master r33 installation at
`e56326f6bdbe5f50c9218f6cfa59706aa16a19a3`. Its first successful upgrade to this
fork used source `3180e283139e2c54f33bb15d91f3858f87851729` and created project
commit `d95b766278ab7fb5cb1088a5e628661088283f4b`.

## Failures reached and fixed

Actual Cursor attachment first encountered a managed USER-RULES overlay flagged
as user-modified. The existing pure overlay comparison now exempts that exact
managed change in the manifest query without changing the manifest. Arbitrary
user text remains protected.

An actual subsequent package update from source
`cb425ae0bb218214af9b8d38f5877999d648f35b` reached the already-current rules route
and failed because native installer diagnostics polluted the structured
post-copy return. Those diagnostics now go to the host; only the expected
path-inventory object returns. The same run exposed a second defect: the fresh
child launcher exited its parent, so ordinary post-copy failure could not be
recorded by the parent's existing catch. The update owner now requests a returned
exit status; other launcher users retain the original behavior.

The resulting `post-copy-running` capsule
`c25e45a2257c448395e9c56ab2cb487b` had two uncheckpointed outputs. Scoped recovery
report SHA was
`426b531f898ae6ef09c8e433f6f8c45f66fc2eb15813365611b738f03fe90188`.
The recorded source's real session-limit writer reconstructed `.dev.env`
byte-for-byte from its saved before bytes. `.ai-rules.json` changed only its
native timestamp within the failed run and added 24 foreign inventory entries;
each was a generated Codex ITL surface matching the recorded source renderer's
exact byte hash. All other manifest fields and file entries matched canonically.
The review happened in a separate fixture. No installed file or receipt was
manually repaired.

Hash-bound reconciliation acknowledged those two outputs without changing
project files, HEAD or staging. New clean source helper
`f1bdf8f1b47d322ccdbc5477b950242e82ec255f` then completed the pinned `cb425ae...`
payload and recorded both identities. Project commit was
`67bbabed5af6ec178154dabd026d9c25ffb796c1`. Its typed
`WORKFLOW_UPDATE_NEW_CANDIDATE_PENDING` required repeating the same source-side
command to install the new payload, without replaying the completed old update.

That repeat installed `f1bdf8f...` at
`f6a2163cffa27cb0bf6b8096df9111dd86d66d2d`, but exposed a parent fall-through after
successful child completion. The owner now returns after the child's completed
transaction. A regression uses an actual Windows PowerShell child and requires
the normal update to finish without entering parent post-copy a second time.

## Multiple clients

The installed helper subsequently attached Cursor to Codex successfully. The
fixture-owned attachment was committed at
`91d352735c13732b436f241329e2c355f5bf04c4` after verifying every changed path was
within the workflow write-set. The next exact source
`3113f92bb16a0ed6aa5873dcda0838b0eea64731` updated both clients through the ordinary
source-side owner and exited 0 at project commit
`be8347f0eac83d94e303a96584538b69ea938a0c`, with a clean tracked tree.

Its capsule `358215660db34454a2e331259a6089e5` was restored through the source-side
owner in commit `091447d94965a875569265542cb72b04d0c7dfa3`. All 643 before-path
states matched exactly, including ignored settings and ownership files. The Git
tree equaled the attachment baseline `91d3527...`, tree
`80b354ccde56c3e7f359f767ba2623861e9fd09b`; both clients remained attached.
Repeating the ordinary update exited 0 at
`716cb83feb04b5437aca3aa94a290ad5182e0a3f`, with a clean tree.

The migration snapshot inventory now includes client-surface and MCP ownership
receipts, ZCode and MiMo Code roots. Outer baseline/client recovery shares the
MCP owner's typed preservation policy: late edits and completed-write receipts
survive while other owned files and membership return to their before state.
The regression reaches the outer attach failure, verifies retained edits,
restored membership and generated files, and completes the original attach on
repeat. It also exercises normal complete inventory restoration.

The source batch covering handoff, membership and shared MCP ownership passed
54/54. After extending the snapshot to ignore/attribute files, Claude entry and
legacy Cline/Kimi roots, the outer rollback and retained Kilo runtime regressions
passed 2/2. A branch recovery regression verified stopped payload A → exact new
candidate B under the existing owner: changed A was refused, unchanged A was
completed first, then B installed; staged business bytes and the original failed
refresh record survived. The three branch transition tests passed. A subsequent
case proved that an unchanged backup-only attempt can restart from B without its
unused old source checkout. These are executable Git fixtures; the original
business refresh command has not yet been live-resumed by this canary.

Actual MCP/provider callability and native client runtime execution are separate
acceptances. These canaries do not establish them. Optional UI preparation
reported agent-browser failure and unavailable uvx; those remain explicit
degraded capabilities rather than successful live UI proof. No user project,
database, global client configuration or published ref was changed.
