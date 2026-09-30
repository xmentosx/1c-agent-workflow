# OpenSpec CLI lock transport — 2026-09-30

A read-only Codex CLI probe in the disposable published-r33→fork project
loaded the installed `openspec-explore` skill but could not run its CLI:
`OPEN_SPEC_CLI_LOCK_DRIFT`. The project's managed
`.agents/skills/1c-workflow/resources/openspec-cli/package-lock.json` had
1,264 CRLF line endings and SHA-256 `70375d14…`, while the dependency lock
pins the original LF bytes at `7fa9c50d…`. The same conversion occurred in
the clean test source clone. This is a Windows Git checkout transport defect,
not a package or dependency version change. The read-only probe did not install
or repair anything. Its ignored JSONL is `build/codex-openspec-explore-2d3.jsonl`.
It used 424,336 cumulative input tokens (373,504 cached), so it is not a
representative unchanged-operation cost measurement.

The source `.gitattributes` now marks that exact lock path `-text`. Bootstrap
and update add the same rule to the installed project's `.gitattributes`
before committing it; the update snapshot/write-set includes that file. An
existing 1C byte-preservation block remains at the end and is not rewritten.
The SHA requirement in `Get-ItlOpenSpecCliPin` is unchanged.

The focused Git regression reproduced a hash mismatch after checkout with
`core.autocrlf=true` without the rule, then kept the exact pinned bytes with
the rule. Two more regressions covered both initialization orders: a
pre-existing 1C `.gitattributes` block and one added after the OpenSpec rule
(3/3). `SourceUpgradeHandoff` passed 23/23 and the existing
`AiRulesMigration` set passed 27/27.

The repaired source snapshot `39766f20a751867a90f8a0193c8994aafc699715`
and local test-pin commit `4a2528a8…` updated a fresh disposable r33 project
at `build/r33-preflight-lockfix` using the same exact rules fork
`2d3e7705f79e37a130349b88ecea78b964adabf5`. The update exited 0 and
left a clean Git project at `ed1004b5db266119d8c5592de7da7114426e8eb5`.
Its installed lock bytes match the pinned SHA, contain zero CRLF pairs, and
`git check-attr text` reports `unset`. Explicit `provision-openspec-cli`
then exited 0; the project-local OpenSpec 1.13.1 CLI ran `list --json` with
exit 0 and reported the project's nearest local root. Provisioning changed
only ignored runtime; Git remained clean. Raw logs are ignored
`build/r33-to-lockfix-canary.log` and `build/openspec-lockfix-provision.log`.

Repeating the installed update after provisioning exited 0 in 1.8 seconds,
kept the same `ed1004b5...` HEAD and clean Git state, and retained exact lock
SHA-256 `7fa9c50d3a7e194687346641755beffadb33c03486411e92fc3f84c09a5e06d4`.
The installed helper then reported the CLI available at version 1.13.1;
`openspec-context` returned `source=nearest` and this project's local root.
The ignored repeat log is `build/r33-to-lockfix-repeat.log`.

In a parallel disposable checkout, the synthetic published-r33 installed
project stayed at baseline commit `e56326f6bdbe5f50c9218f6cfa59706aa16a19a3`.
Its original helper `help` exited 0, it had no new OpenSpec CLI runtime, and
both projects stayed Git-clean while the upgraded peer still resolved its own
project-local 1.13.1 executable. This checks old/new coexistence on the same
host; actual installed rollback and retained CLI bytes were subsequently checked
in `workflow-rollback-canary.md`. The ignored old-helper log is
`build/parallel-r33-old-help.log`.

This proves file transport and one real local CLI read path after the installed
transition. It does not prove native phase execution by Codex, all six phase
write paths, live 1C/MCP providers, or crash recovery. Those remain in tasks
5.3, 6.1, 10.3 and 10.4.
