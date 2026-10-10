# Actual legacy rule-layout qualification

This file qualifies project-file migration only. The host workflow package is
the genuine published-r33 installation at `e56326f6bdbe5f50c9218f6cfa59706aa16a19a3`;
the older rules were placed by their actual unmodified installers. It does not
claim that the whole host package came from a historical r11 release, or that
Cursor, a model, MCP providers, or native 1C executed these rules.

The historical first candidate is source C3 `647df3dafd81c3bf0b18785a6861453fe320d943`,
snapshot `b442c324a12bec221a3d10e82da77bbb322df4e4`, at
`build/canary-source-final-618396463c12494cb653973622360938`. The rules are the
unchanged qualified fork `9ec86f75343ba4eded66e2085f097ff4baab7d67`, local tag
`itl-main-20a083e5-r39-canary-9ec86f7`. Fresh remote master before qualification
was `69c0863bfe3bd837543267f122e81a28dcfa5488`. No default pin or remote ref moved.

## Authentic baseline provenance

| Baseline | Actual rules source | Actual manifest | Owned preparation baseline |
| --- | --- | --- | --- |
| Earlier controlled fork, Codex | `af82570afca06c40a9588c8a678bf3665bba4870`, tag `itl-main-b4d9875b-r11` | protocol 1.1, 181 actual targets; SHA-256 `a4673a691b02376c4d82c648f7c1b1f2037f3e6801dead3171cf3f0108d288e4` | commit `30584a2123d18a822d45ab28f2db5efcc4a0bb99`, tree `316cfb20a3afaf94a9989359aba8d6fcf5108fdb` |
| Raw upstream, Cursor | `a421cf44eb1f5859cf2a2b74884f8fbcaefc4826` | protocol 1.0, 175 actual targets; SHA-256 `d84e1cf9ee0a9b303e7977bb52f9c477faed86d22a3e8bfc44033c6b5af23b08` | commit `348770aa00c381c30e8ee21f8617bec247a426c2`, tree `cf55a3a47faa9a45cd1c004f15e34e9134eaf5dc` |

Artifact directories are respectively
`build/r39-r33-preservation-9c08651a493f44748e142141ce7a91e1` and
`build/r39-r33-preservation-b18994a42bd649e1bab88cc840484599`. The separate
projects retain their original `build/r39 r33 приёмка <id>` paths: spaces and
Cyrillic were not shortened to obtain a pass.

Preparation first invoked the actual r33 rules owner's `remove`, then the
actual old `init`. The r11 adapter places Codex commands in project skills and
supports explicit delegated MCP; its final init used `-Tools codex -McpMode
delegated -NonInteractive`. Raw a421 Cursor targets are project-relative; its
init used `-Tools cursor -McpMode managed -NonInteractive`. The infobase HTTP
placeholder remained unset, so the raw installer's only applicable `/hs/`
probe was skipped for its original unresolved-placeholder condition. No
provider or native 1C process was authorized or launched.

The controlled-r11 config/lock rules identity comes from genuine historical
`a2885b2b:templates/dependency-lock.json`. Raw upstream config/lock explicitly
records the actual local a421 source. These are stated fixture source identities,
not fabricated installer ownership. Both actual manifests were retained byte
for byte while adding a user-rule prefix, memory addition, user note, foreign
project MCP file and local On/full setting. Installed hashes and `template`
flags were never rewritten. The actual old entries for USER-RULES, memory and
LLM-RULES use `source=<root file name>, template=true`.

An additional genuine raw b4d9875/protocol1.1 Cursor preparation remains at
`build/r39-r33-preservation-ebe3d76c7fd74043ae97407787ff5146`. It was not selected
for a duplicate update; a421 provides the older protocol1.0 qualification.

## Retained preparation and concurrency failures

The first private source clone tried to check out current long eval-fixture
paths and failed with Windows `Filename too long` before an old installer ran.
The failed private source directory was retained. The ignored preparation
driver uses `clone --no-checkout` with `core.longpaths=true` in a fresh private
source staging directory, then checks out the exact old ref. The original
project root and workload remain unchanged.

Actual r11 init with `-Tools codex,cursor` refused in Phase 1 Detection:
`Exactly one tool must be selected`. Its original log and exit1 remain
`actual-legacy-owner-init.log`; no manifest was placed by that refused init.
Continuation ran the same old owner with its supported single Codex client.
No two-client manifest was synthesized, and no legacy multi-client support is
claimed. Actual attached Codex+Cursor transition/restore is qualified by the
separate new-helper recovery and fault-window evidence.

The first C3 r11 update was run alongside the raw a421 update and failed before
copy/transaction creation in 3.400 s. Git reported `.git/config: Permission
denied` while both calls used the shared user TEMP `ai_rules_1c` source cache.
The project stayed at its exact original baseline. The failure is retained in
`update-2ad345cee7a44db8b42bf4b29acf6391.log`, SHA-256
`d6e3548e8f58ff716552727f2218ba1eec0bb11665110d1e86b937a3db87bd94`.
After raw completion a read-only idle admission captured zero remaining owned
children, zero matching active Git operations and empty cache status. The same
r11 public update was then retried sequentially without cache, ACL, TEMP,
manifest or project-precondition changes. The initial parallel failure is not
erased by a later serial result, and the C3 qualification does not assert
concurrent independent-project updates.

The source owner-local repair and causal active-Git-lock regression are recorded
in [ai-rules-project-checkout-isolation.md](ai-rules-project-checkout-isolation.md).
The original C3 failure remains historical. The actual repaired parallel pair
on C4 is separately recorded below; it is not inferred from these serial runs.

## C3 execution results

Both selected baselines passed the exact C3 public route. Only read-only helper
calls were independent; mutation calls were sequential after the retained
shared-cache failure.

| Public action | Earlier controlled r11 / Codex | Raw a421 / Cursor |
| --- | --- | --- |
| Actual old helper before update | passed, 1.985 s | passed, 1.825 s |
| Normal C3 update | serial passed, 108.740 s; commit `c4fdc2e945efce19422f8087098dda6855b06248` | passed, 122.470 s; commit `aac0ece84671b176df1c1051e220f08a2bda38b8` |
| Same update repeat | passed, 2.266 s; unchanged HEAD | passed, 1.852 s; unchanged HEAD |
| Public recovery status | passed, 2.107 s; no pending operation | passed, 2.064 s; no pending operation |
| Actual materialized new helper | passed, 5.505 s | passed, 5.081 s |
| Guarded same-C3 restore | passed, 47.997 s; inverse `f9a8b3e02e068225df9f6398b80616b04d38044b` | passed, 48.830 s; inverse `24057f19faeaa0a0896fa5b617a636fe61a09f00` |
| Same restore repeat | passed, 8.131 s; unchanged inverse HEAD | passed, 8.293 s; unchanged inverse HEAD |
| Actual restored old helper | passed, 1.168 s; output identical to original | passed, 1.122 s; output identical to original |

The completed audits found clean Git trees, exact C3/r39 pins, each original
desired single-client set and all six canonical phase skills in its real
client directory. On migrated to auto; full and the unrelated local setting
remained. Memory, note, OpenSpec scaffold and all 14 global config/prompt files
stayed unchanged. No legacy alias retirement is inferred from these two
layouts: their actual manifests already used four canonical phases, and the
new installation adds the full six-phase contract.

Independent raw-byte comparison confirmed all 62 user-prefix bytes and entire
memory SHA-256 `020b48bfc87d755e5b235ba1b3b8d134ede873bab66ce6e86db604abbb659256`
after update and restore. USER-RULES receives the ITL-owned section update;
after restore its entire raw hash again equals the original
`4d7d92c0a3af541802217361b53d375154d09b3387b075f2e2b61a5cd5f7a452`.
Codex's original foreign MCP bytes remain the exact prefix before separate ITL
owner blocks. Cursor's inactive foreign `.codex/config.toml` remains wholly
unchanged, SHA-256
`2cc83f131e05da4238b28533d563b767b806764a2fc84f9c63627fb00cb9e65e`.
Entire foreign MCP bytes are restored in both cases. The audit reads original
update-owner backups and the actual rollback-owner capture of the completed
installation, without reconstructing or writing project files. The inactive
Cursor foreign file correctly never entered the owner write-set; its exact
raw hash was observed directly before restore and again after restore.

Restore returns both exact original baseline trees, raw actual old manifests,
ignored dotenv bytes, old helper and config/lock. The originally absent Caveman
receipt is absent again. The actual restored old helper log is byte-identical
to its original output, and repeated restore adds no HEAD or capsule. Each
case has exactly two terminal `post-copy-complete` receipts: original updates
`5e53ca7894d84c4cbf8026af238e9fa0` / `b0f0cdd29b1d4ac0828fcb5917554492` and
rollback receipts `85a40ed2fb5a497cbc8434bb6612edf1` /
`3382ce5056b2447eb4d9aa7a2f92eca3`.

Each artifact directory retains `metadata-c3.json`, exact named native logs,
after-update/restored raw-byte proofs and `legacy-final-preservation.json`.
Final preservation proof SHA-256 is
`c9def9f784c77c3952e6d063b7486d321bdb96a94b6f62fe00e586f723413c00`
for r11 and `e90aba178b50224073ea91610909ee0d373646f8fdde78c4891e2bc0322c4ab4`
for a421. Supplemental ignored driver's argument spelling and mistaken
assumption that an inactive foreign file had an owner backup were corrected;
neither changed product source, fixture bytes or acceptance assertions.

Preparation `metadata.json` is retained as C2 provenance. Before any update
capsule existed, `metadata-c3.json` selected the authorized immutable C3 and
records that distinction. Actual old helper execution passed before each
update, without changing HEAD or global files. The ignored harness establishes
UTF-8 before decoding native output and adjusts only the child's native Windows
PowerShell module path; it does not change host registry, profiles or modules.
`ITL_UI_TOOLS_AUTO_INSTALL=skip` is the documented file-update scope; separately
qualified UI readiness is not relabelled as a result of these runs.

## Same authentic projects on final C4

Immutable C4 is `6c651f9b164ae1932c65bab661de315640017e83`, snapshot
`ee3d58314a310e42798cd01a186fbae3271d4844`, at
`build/canary-source-final-33c0b55c03964fe98657d6eadf85b0d5`. The fork/tag and
fresh captured remote master remain as above. Both original project paths,
old manifests and original preparation trees were reused exactly. C3 terminal
receipts remain in place and retain their original raw SHA-256 values.

| Actual public C4 action | r11/Codex | Raw a421/Cursor |
| --- | --- | --- |
| Original normal update, simultaneous | passed, 117.448 s | passed, 127.550 s |
| Repeat, no HEAD/capsule change | passed, 2.000 s | passed, 1.910 s |
| Status, clean/no pending owner | passed, 2.640 s | passed, 2.750 s |
| Guarded restore through exact C4 public wrapper | passed, 46.059 s | passed, 48.453 s |
| Restore repeat, no HEAD/capsule change | passed, 7.580 s | passed, 8.064 s |
| Restored actual old helper, original output bytes | passed, 1.730 s | passed, 1.159 s |

Actual native update intervals overlap by 117.448 s. Their native clone logs
prove distinct project-scoped caches beneath the same original TEMP owner,
exact fork HEAD and local longpaths; the complete 686-file old shared-cache
inventory is unchanged. See
[ai-rules-project-checkout-isolation.md](ai-rules-project-checkout-isolation.md).
No TEMP override, ACL change, lock removal, shortened root or separate profile
was introduced to make this original pair pass.

After update, raw owner-backup comparisons prove the exact original 62-byte
user prefix, whole memory file and foreign MCP prefix are preserved; the
inactive Cursor project's foreign Codex configuration remains whole-file
identical. Desired client sets and all six corresponding OpenSpec phase skills
are present, exact C4/r39 pins and helper materialization pass, and local
On/full migrates to auto/full with the unrelated setting retained. These are
file-update results; no C4 native new-helper `help` call, model, client
application, MCP provider or 1C execution is claimed.

Guarded restore returns exact original trees
`316cfb20a3afaf94a9989359aba8d6fcf5108fdb` and
`cf55a3a47faa9a45cd1c004f15e34e9134eaf5dc`, raw actual old manifests, whole
USER-RULES/memory/foreign configuration, ignored dotenv, old helper and old
rules pins. Both remain clean. Restored old-helper output SHA-256 exactly
matches each original output. All 14 global prompt/config files retain their
original inventory and bytes throughout.

Each project now has exactly four terminal receipts: the two unchanged C3
receipts, plus C4 update/rollback
`c13b5104dcfa4c1793d81250c5a3172e` / `17ad48071f7847d39bade5bc51864b83`
for r11 and
`fa2c3c90bdc5499b80e4c7bde26b90af` / `d3edd22b65144f03ad42df7e6c27825a`
for a421. No failed or pending update capsule remains. Final inverse HEADs are
`9f016f15fdc4405e649f4026d39fe05a242f5128` and
`44b79ad3980b10b35e947f8953c07e2396b15121`; they preserve history rather than
resetting original HEADs.

Each original artifact directory retains `metadata-c4.json`, named native logs,
`legacy-c4-user-raw-bytes-after-update.json`,
`legacy-c4-user-raw-bytes-restored.json` and
`legacy-c4-final-preservation.json`. The latter SHA-256 is
`e4d48dc8f01ff17b938fc6b23096214a90593299065a2a7088a65888b487ab6a` for r11
and `eef1aef63b435faa091c06efb4baccad6c565e10a11b3a7e0f9fe7409d038aa1`
for a421. The aggregate is
`build/original-legacy-pair-c4-final-acceptance.json`. Original C3 receipts,
failure and preservation proof files were not overwritten or relabelled.

## Raw Codex global-class limit

Raw a421 Codex uses `[Environment]::GetFolderPath('UserProfile')` for global
prompts; it does not honor CODEX_HOME. A safe child-only native Windows
PowerShell probe by the review owner set process USERPROFILE to an isolated
literal path, but `GetFolderPath('UserProfile')` still returned the real
`C:\Users\xment` (tool chunk `d510d1`, exit0). The caller restored its process
variable; no files were written. There is no authentic archived raw Codex
global manifest available in this stand. Consequently actual old raw-Codex
global relinquishment remains **unverified** here. The nine focused source
classifier regressions are original-installer-shaped fixtures, identified as
such in [legacy-global-prompt-admission.md](legacy-global-prompt-admission.md);
they are not promoted to live old Codex acceptance.

No installed user project, global prompt/config, customer database, publication,
registration or remote tag was changed. This evidence is an input to the root
9.4 review; it does not independently close that task checkbox.
