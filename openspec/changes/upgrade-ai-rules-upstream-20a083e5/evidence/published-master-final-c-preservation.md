# Published-master/r33 to source C/r39 — isolated file qualification

Date: 2026-09-30. Exact source C is
`92964456bf1931ad3a3d24af1250f6e244ea5574` in the clean ignored
`build/canary-source-final-01a1ba42d6944a5789d466cf846dfb9b` checkout.
Its rules candidate is clean fork `9ec86f75343ba4eded66e2085f097ff4baab7d67`,
local immutable `itl-main-20a083e5-r39-canary-9ec86f7`.
This record qualifies those bytes; a subsequent owner repair needs its own
continuation evidence. The source default remains r36, and no remote ref,
ordinary project, infobase or client profile was updated.

## Baseline and execution boundary

Each fresh project uses a whitespace-and-Cyrillic root
`build/r39 r33 приёмка <guid>` and begins at original installed r33 commit
`e56326f6bdbe5f50c9218f6cfa59706aa16a19a3`, copied from the clean
`build/parallel-r33-old-2d3` stand. Separate captured
`git ls-remote origin refs/heads/master` probes immediately before preparation
confirmed published source `69c0863bfe3bd837543267f122e81a28dcfa5488`.
The old lock pins r33 `9309bfbbc9f8d844a21bce55178c2e0d72eaf965`.
All 226 manifest targets exist except the originally absent ignored `.dev.env`.
The canary's local `CAVEMAN=On`, `CAVEMAN_LEVEL=full` and user setting are an
explicit new local baseline, not a fabricated installer hash or manifest flag.

The installed old helper, `AGENT-INSTALL.md` and installed dependency-lock
Git blobs exactly match their corresponding published-master blobs. Their
fresh checkout bytes also exactly match the original installed stand.
The initial harness incorrectly compared CRLF checkout bytes directly with
an LF Git blob. Its retained failure and causal record show both installed
checkout hashes equal and both Git blob hashes equal; no project bytes or
reproducer path were normalized to pass the check.

The initial update/repeat/status/restore actions entered the public source-side
`scripts/update-installed-workflow.ps1`, using process-scoped exact
`ITL_WORKFLOW_SOURCE_PATH`, `ITL_AI_RULES_SOURCE_PATH` and clean-source checks.
`ITL_UI_TOOLS_AUTO_INSTALL=skip` is the documented file-qualification override;
it is not UI installation/readiness proof. Native helper actions execute in
Windows PowerShell 5.1. No 1C or MCP provider was launched.

A second retained harness failure exposed a process-launch mismatch:
`.NET ProcessStartInfo` inherited PowerShell 7's module search path and the
WinPS child could not find `Get-FileHash`. The independent read-only probe
`build/r39-windowsps-modulepath-probe.json` demonstrates that the ordinary
`& powershell.exe` launch finds `Microsoft.PowerShell.Utility` through the
Windows module path. Only the ignored driver's child environment was corrected
to that native path; no production/fork code, installed copy, host module or
registry was changed for this transport correction. Original failure logs
remain present, and all subsequent action logs use unique names.

## Pure published baseline: passed

Artifact directory:
`build/r39-r33-preservation-215632fb47f640fa9251213241a168e5/`.
This project retains the original tracked baseline exactly before update;
it has no new tracked policy, memory or foreign MCP contribution.

| Public action | Result | Elapsed | Project HEAD after action |
| --- | --- | --- | --- |
| Actual old installed helper `help` | passed, exit 0 | 2.054 s | original `e56326f6…` |
| Source-side update | passed, exit 0 | 93.994 s | `0c9136d54470b29f6613112b1c63125ec8a9f20f` |
| Actual new installed helper `help` | passed, exit 0 | 48.811 s | same update HEAD |
| Same update repeat | passed, exit 0 | 2.002 s | same update HEAD |
| Public recovery status | passed, exit 0 | 2.072 s | same update HEAD |
| Explicit restore of completed capsule | passed, exit 0 | 42.804 s | `41d0e8b94ea47828b2168fabbee6e8acfe961be3` |
| Actual restored old helper `help` | passed, exit 0 | 1.133 s | same inverse HEAD |
| Same restore repeat | passed, exit 0 | 7.706 s | same inverse HEAD |

The update is clean, directly descends from the original r33 installation,
and installs workflow pin `92964456…`, rules pin `9ec86f7…` and revision 39.
The new helper bytes match source C. All eight unchanged owned Codex OpenSpec
alias files retire and all six canonical phase skills exist. Caveman migrates
On to auto with full retained. Original `memory.md`, local OpenSpec scaffold
and user-rule prefix remain exact; all 14 real user-global Codex config/prompt
file hashes and their inventory remain unchanged. Only hashes, not credentials
or profile contents, were collected.

Status reports one completed capsule
`28484a0e1f83431f95c08a106ab01b05`, no pending transaction, and no extra
capsule on unchanged update repeat. Restore returns the exact original tree
`fa481f93f9335aad58f13c1f00735f69fc0f33ed`, exact ignored dotenv bytes,
old r33 lock/helper and the originally absent Caveman receipt. Both retained
capsules are terminal after restore; the restored Git tree is clean.
These are file/settings and recovery results, not live infobase acceptance.

## Explicit custom source choice: passed preservation

Artifact directory:
`build/r39-r33-preservation-f79b62393df74eeba1fa341681e2723e/`.
Its explicit fixture commit `745d11ca07a27d45edcaee151d9c719db9238635`
changes only the installed project and lock repository choice to
`https://example.invalid/canary-owned-ai-rules.git`, retaining the genuine
installed r33 manifest and payload. No manifest ownership, installed hash or
userModified flag was fabricated. This is custom configuration preservation,
not provenance or execution qualification of the named repository.

Actual old helper `help` passed in 1.769 s. Public update passed in 69.645 s,
creating clean `06c0944e2d0528683320ba7869ca7afe9dcd43ff`; workflow pin
becomes source C while the entire custom aiRules config and dependency record,
raw old manifest and 224 installed rule files remain exact, including old
AGENTS, memory, LLM rules and aliases. USER-RULES may receive the ITL host
overlay and is not claimed wholly unchanged. All 14 global files remain exact.
The single completed capsule is `abed2587a16e47f98a490a94d3109be7`.
Repeat passed in 2.022 s with the same HEAD. No custom-repository fetch or
live provider call was needed.

## Original source C failures and their continuation status

- `build/r39-r33-preservation-34a0f8947bf84114bd7363bdeb2b90f0/`
  keeps explicitly committed user USER-RULES prefix and memory additions,
  user note and tracked foreign MCP configuration. Source C refused before
  any package copy with `WORKFLOW_UPDATE_RULES_USER_MODIFIED` naming
  `memory.md` and `USER-RULES.md`. HEAD `fc1af3bb…`, manifest, local settings,
  foreign prefix and 14 global files remain unchanged. These legitimate
  placed-once template additions were not removed or rehashed to obtain a pass.
- `build/r39-r33-preservation-d1b4a435851d4bf49b12ff69f623914e/`
  retains unchanged policy/memory plus the same explicitly tracked foreign
  MCP contribution. After driver transport correction, post-copy migration
  completed but master commit refused `.codex/config.toml` as outside its
  managed allowlist. The foreign prefix is byte-exact; the appended changes
  are helper-owned on-demand facade and UI blocks. Original snapshot
  `9f6fbf873a4142b59f5f98bfd8f9bcdf` owns this literal file, records both
  before/current expected hashes and the planned path, and originally stopped at
  `master-commit-ready` with unchanged HEAD `fc84f7ab…`. Repeated copying,
  manual Git/state edits and deleting the foreign contribution are not recovery.

`blocked-preservation.json` in both directories records the preservation facts.
The initial preflight/module-path error in the second directory is retained
separately and is not the product allowlist defect. The commit-owner repair
must retain the original recorded source C payload and checkpoint. The accepted
continuation below resolves the second failure; the first user-template failure
is resolved by the separate exact C2 continuation recorded at the end. Neither
failure was replaced by the narrower passing cases above. Whole task 9.4 still
requires its legacy and multi-client inventory review.
Additional legacy formats and multi-client/lifecycle acceptance remain in
their own existing owner records.

## Same tracked foreign-MCP checkpoint: continuation and rollback passed

The original `d1b4a435851d4bf49b12ff69f623914e` fixture, additions, installed
manifest, index and receipt were left intact. The clean recovery executor
`build/master recovery executor 9da55b76bbb24c63a77e911933fb542f`, exact HEAD
`27a07c1fd2676fe5473ab82adfb96db3f271cd7f`, contained the bounded
`Commit-WorkflowUpdate` repair. Its public helper continued the existing
`master-commit-ready` transaction, with process `ITL_WORKFLOW_SOURCE_PATH`
still pointing to source C `92964456…` and the same fork `9ec86f7…`.
The executor was not installed as a new payload and did not repeat package copy.

| Action on the original fixture | Result | Elapsed | Project HEAD after action |
| --- | --- | --- | --- |
| X helper continues update | passed, exit 0 | 36.692 s | `3953027dfaeaf6a2cdef4712012106954e84e8c0` |
| X helper repeat | passed, exit 0 | 1.649 s | same update HEAD |
| X helper recovery status | passed, exit 0 | 1.946 s | same update HEAD |
| Direct X helper restore with C payload source | rejected before mutation, exit 1 | 1.498 s | same update HEAD |
| Exact C public wrapper restore | passed, exit 0 | 42.450 s | `b3664e72aec8c43cc7a6a1bf73d52afef1d8eac2` |
| Exact C wrapper restore repeat | passed, exit 0 | 8.518 s | same inverse HEAD |
| Actual restored old installed helper `help` | passed, exit 0 | 1.531 s | same inverse HEAD |

The direct-X restore refusal is admission proof, not a product failure:
`WORKFLOW_UPDATE_ROLLBACK_SOURCE_HELPER_REQUIRED` requires the executing
source helper to match its clean source root while rollback replaces installed
files. The exact C public wrapper satisfies this contract without bypassing it.

Update retained the original foreign TOML prefix exactly while appending
separate ITL-owned facade/UI blocks. Raw hashes of memory, the user note and
OpenSpec scaffold stayed equal, user-rule prefix stayed equal, all 14 global
files stayed equal, the eight aliases retired, and On became auto/full.
The original capsule `9f6fbf873a4142b59f5f98bfd8f9bcdf` became
`post-copy-complete`; status had no pending transaction. Repeat created neither
a new commit nor a new capsule. Workflow and rules pins remained C/fork9ec.

Rollback returned the exact user-baseline tree
`4206c362d3b879e6c7b5407d23b3095ddb0a87ee`, including the entire original
foreign TOML file, ignored dotenv bytes and old helper/lock. The originally
absent Caveman receipt was absent again. Git was clean after rollback, repeat
and actual restored help; both retained capsules were terminal, with rollback
capsule `8f40daa6ad854e9aa9c606c5576ad7f2`. No global profile, MCP provider
or infobase was changed.

All named logs, command input identities and raw byte audits remain in the
original artifact directory. The successful continuation log is
`update-18d91366cc8f4f09a7c97207a273961a.log`, SHA-256
`9ef32605f699b81d81a704144a8003cdf3bfabfc3f01cf3a71563ec902f7df2d`.
The rejected direct-X restore log is
`restore-a4211701b40e47f988b4fa6b1bc88b04.log`, SHA-256
`e2f4465af35c01e26b6eaf9746a9d250f63b0291ed2b91423aaa6f32ee98ec7d`;
the accepted C restore log is `restore-b48057d8001a4bfd9dbed7e5f00c354d.log`,
SHA-256 `e0b6ba30f82c2db4ae772cec47866c7fecdd93ccac563eb1db57f72d53e61722`.

## Original user-template additions: exact C2 update and rollback passed

On 2026-10-01 the original `34a0f8947bf84114bd7363bdeb2b90f0` fixture
remained at its exact user baseline `fc1af3bb3b3b282aeef82cb6a8dc46edb406971e`.
Its genuine r33 manifest was unchanged, SHA-256
`ab44af938ebf48ea9db0febfd93e33c348c2defe4cb4ea4c9cf13890bb9b1368`.
Source C had refused before creating a capsule or copying files. Therefore
the authorized new normal candidate could enter the same original fixture:
clean C2 `ce107ee1bd0484223b3a87b15e649273aae3c574`, snapshot
`5dced5254b603294828823c530539dd4bd068e49`, at
`build/canary-source-final-85d0d90a3f4f4543999e83c3b76a9af8`.
Fork9ec/r39 was unchanged. `metadata-c2.json` preserves the original C run
records and explicitly records the different candidate after pre-copy refusal.
No user contribution, manifest flag or installed hash was changed for admission.

| Exact C2 public action | Result | Elapsed | Project HEAD after action |
| --- | --- | --- | --- |
| Normal source-wrapper update | passed, exit 0 | 128.934 s | `9d853bf54f036531f93da35ea1621760280de54f` |
| Same update repeat | passed, exit 0 | 1.729 s | same update HEAD |
| Recovery status | passed, exit 0 | 2.000 s | same update HEAD |
| Guarded restore | passed, exit 0 | 54.699 s | `b27d93dab07692afc7159c6723b11b2cebbc744e` |
| Same restore repeat | passed, exit 0 | 9.279 s | same inverse HEAD |
| Actual restored old helper `help` | passed, exit 0 | 1.744 s | same inverse HEAD |

The completed update was clean and pinned workflow C2 and rules9ec/r39. The
original user-rule prefix, memory additions, note, local OpenSpec scaffold and
foreign MCP prefix were preserved. The eight unchanged aliases retired and
six canonical phase skills existed. Caveman changed On to auto/full, preserving
the unrelated local setting. Status had no pending transaction and reported
completed capsule `87a704f53cbe4a4d936947d53806434b`; repeat did not add
a commit or capsule.

The independent `user-additions-byte-roundtrip.json` additionally compares raw
bytes from the owner's original backup and the rollback owner's captured
completed installation. All 78 user-prefix bytes stayed equal after update;
whole memory SHA-256 stayed
`661710cdf1b484e607baa61ced96429af22d4de6bf9fe07484259a8a239fc0c1`.
USER-RULES receives a changed ITL-owned section, so it is not claimed wholly
unchanged after update. After restore the entire USER-RULES file again has
its original SHA-256
`24e9648d8bad5ce0f82e12eac69255381c05c71005d93f91f487791d13ad4ffb`.
No project bytes were reconstructed or written for this additional comparison.

Restore returned the exact original user-baseline tree
`c60d5f03c92e25455037454dc839e23adbd5111f`, entire foreign MCP file,
ignored dotenv bytes, old helper/lock and originally absent Caveman receipt.
Git remained clean through repeated restore and actual old helper execution.
Both retained capsules were terminal; rollback capsule is
`9b9ceee3bc6a4c519e5160e3fed69d69`. All 14 real global config/prompt files
and their inventory remained unchanged. No native 1C or MCP provider ran.

The original refusal remains `update.log`. Successful C2 update is
`update-68ac5473e0e2479bbd96eeb6ea982478.log`, SHA-256
`c7fa7cbeceef7d32da9afdd2321ad8a57b28be73cb616e19fafae0d631026c91`;
restore is `restore-2ce17cd4eeaa40a3beb831a6351a86fa.log`, SHA-256
`61930b186e7b788ffe24da66af74114fe2d0377a3e48ce4af3139d210ff9a51d`.
Unique repeat/status logs and both raw byte audits remain in the original
artifact directory. One supplemental read-only driver's mistaken use of
`backupPath` instead of serialized `backupName` was retained separately;
the corrected byte comparison reads the actual named owner backups and passes.

These facts close the specific user-text/memory/foreign-MCP preservation and
recovery gap. They do not qualify other runtime capabilities or close the
complete 9.4 legacy/multi-client requirement by themselves.

## Additional authentic old-rule layouts: exact C3

[legacy-file-layout-qualification.md](legacy-file-layout-qualification.md)
records actual upstream a421/protocol1.0 Cursor and controlled-r11/protocol1.1
Codex manifests generated by their unmodified old installers, with the genuine
published-r33 host package. Both passed immutable C3 normal update, repeat,
status, actual new helper, guarded restore, repeat restore and actual old
helper. Their original trees/manifests/user/global bytes are restored. This
adds the missing old-layout file migration evidence; it preserves the initial
parallel shared-cache failure and explicitly leaves live raw Codex global
manifest relinquishment unverified. It does not replace the earlier C/C2
receipts or qualify concurrent updates/native client runtimes.
