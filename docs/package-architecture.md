# Workflow package architecture

This source-only document describes the package layout for maintainers. It is not copied into initialized projects.

- `.agents/skills/1c-workflow` owns the full lifecycle router, references, helper scripts, and generated client templates.
- `.agents/skills/1c-workflow-fast` owns the compact routine-operation surface.
- `.agents/skills/product-docs`, `itl-roctup-1c-data`, and `itl-vanessa-ui-mcp` own optional product/runtime integrations.
- `docs/itl-workflow` contains the human-facing documentation installed into projects.
- `templates` contains tracked project defaults, ignored-file additions, dependency locks, and project guidance overlays.
- `install-agent-1c-workflow.ps1` installs the managed package and starts monitored initialization.
- `scripts/check.ps1` and `scripts/test-ai-rules-compatibility.ps1` own source-repository qualification.

Client routine files are generated from `.agents/skills/1c-workflow/kilo-command-templates`. The capability registry maps them to native commands for Kilo, Claude Code, Cursor, OpenCode, Qwen, and Command Code; to skills for Kimi and Cline; and to prompts for Pi. Generated client surfaces are installed-project runtime state, not source files.

The controlled `ai_rules_1c` fork owns general rules, the common OpenSpec workspace, upstream-native OpenSpec bundles, agents, and its installer manifest. ITL owns bootstrap, lifecycle, local MCP configuration, executable verification, result export, the five ITL skills, and host UX for the `native`/`natural`/`unavailable` OpenSpec states. ITL does not generate client bundles, install `@fission-ai/openspec`, or run `openspec update`. See `ai-rules-fork-upgrades.md` for the release boundary.

## Runtime check blocking policy

A runtime check may block only when continuing can lose data, mutate the wrong target, violate an explicit safety boundary, or produce false success or verification evidence. Every other diagnostic discrepancy is `WARN`, not `FAIL`.

Test classification is an executable-verification prerequisite, not a runtime
diagnostic. A normal check stops before launching 1C when Vanessa or YAxUnit
tests cannot be mapped to their declared cadence and production owners; silently
substituting the complete test inventory would misrepresent the intended
verification scope and consume an unbounded runner budget. Refresh only
inventories this contract and returns agent-owned continuation work, because the
helper cannot infer semantic ownership safely.

Keep integrity checks with their owning component. ITL may duplicate one only after a reproduced cross-boundary failure proves that the owner's check cannot protect the ITL operation.

Capability checks use only the minimum prerequisites needed to perform the operation. File identity, update safety, and exact-result verification are separate contracts; integrity does not participate in capability detection unless exact identity is itself required for execution.

## 1C source byte-preservation policy

Git is transport for platform-generated `src/cf/**`, `src/cfe/**`, and optional auxiliary `src/configs/**` files, not their line-ending formatter. Installed projects carry a managed `.gitattributes` block with `-text` for these trees, so checkout, worktree creation, branch transfer, and result assembly preserve the bytes emitted by 1C even when global `core.autocrlf=true`.

The contract is activated only by `init-project` or an authoritative `sync-master`. The same commit rebuilds the configuration and extension indexes from the physical source trees. When an existing development branch first merges such a master, the transition merge ignores end-of-line whitespace only for that merge and immediately rebuilds both source indexes under `-text`; later merges remain strict. Do not apply the attributes alone during `update-workflow`, normalize all repository files globally, or use content hashes to compensate for transport mutation.

Before a workflow-owned checkpoint, configuration load, repository transfer plan, or completion of a merge, ITL inspects only the changed `.bsl` and `.xml` paths already reported by Git. If the corresponding local `master` blob uses one homogeneous line-ending style, ITL restores that style automatically without changing file content. New files, binary data, `ConfigDumpInfo.xml`, and references with mixed or ambiguous line endings are skipped; this repair does not block the operation or request user action.

Managed source-only maintenance references:

- `local-quality-gate.md` — local Fast/Full checks;
- `ai-rules-fork-upgrades.md` — controlled-fork intake and migration;
- `release-checklist.md` — release-only 1C validation.
