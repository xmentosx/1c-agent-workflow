# Legacy user-global prompt admission — 2026-10-01

Exact upstream `a421cf44eb1f5859cf2a2b74884f8fbcaefc4826` uses protocol
1.0. Its Codex command adapter targets `~/.codex/prompts/{name}.md`;
`Resolve-CopyToPath` expands that target to an absolute user-profile path,
and `Invoke-PlaceArtifactFile` records that absolute key with a
`content/commands/<name>.md` source. The existing controlled fork already
relinquishes this ownership during update without deleting or rewriting the
shared prompt bytes. The ITL pre-copy project-path guard rejected the absolute
key before that existing migration could run.

One stateless predicate, `Test-AiRulesLegacyUserGlobalPrompt`, now recognizes
only rooted paths beneath the current user profile's `.codex/prompts/` and
historical command-file source declarations. Parent traversal, another profile,
other absolute destinations, unknown sources and source traversal receive no
exemption. The predicate does not open, hash, write or remove global files.
Its explicit profile argument is a pure classification input; normal callers
use the actual Windows user profile.

The authoritative project manifest-entry getter excludes this known legacy
class from managed paths, before-path inventories and project snapshots.
The marked-file scan and root write-set/preflight reuse that classification.
The manifest itself remains unchanged until the existing fork installer
relinquishes the old ownership. Pending-merge metadata may preserve the same
known global record only when its complete record matches an immutable parent;
this does not make a new hash or global ownership claim admissible. Existing
local rules and `AGENTS.md` keep their normal hash and dirty-state protection.

The source regression uses real Git projects, protocol-1.0 absolute manifest
keys and an owned isolated profile containing user additions. Only the pure
profile classifier is mapped to that profile inside the test. Both marked and
unmarked legacy records previously failed the same root write-set barrier;
five untrusted-path/source negatives already passed. The causal before result
is `build/legacy-global-owner-causal-before.xml` (5/8; its additional missing
predicate case is structural, not a separate product failure). The first test
capture had unset result variables after the expected guard refusal; its
retained result is `build/legacy-global-owner-before.xml` and is not the causal
proof.

After the correction, all nine selected regressions passed under Windows
PowerShell 5.1 and Pester 5.8.0 in 6.03 seconds:
`build/legacy-global-owner-final.xml`. They verify unchanged global fixture and
manifest hashes, unchanged real HEAD/clean tracked state, absence of snapshots,
ordinary local-rule rejection, exact parent-record preservation, forged global
hash rejection and the actual-profile classifier without global IO. An earlier
eight-case pass remains in `build/legacy-global-owner-after.xml`.

These are source-owner regressions and a verified historical manifest shape,
not a complete installation by the original upstream installer or a final
legacy update/rollback qualification. Task 9.4 still needs its representative
raw legacy installation continuations through the complete immutable candidate.
The fork, its qualification, source publication and real client profiles were
not changed. RegisterChange/Targeted has not run for this correction.
