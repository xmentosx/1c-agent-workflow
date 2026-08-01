# User Rules

## Migrated content from a previous setup

<!-- start of migrated content -->
<!-- end of migrated content -->

## ITL hard gates

- Before changing code or metadata, run the host ITL preflight and record both independent axes by applying `AGENTS.md` and `verification-policy.md` exactly: `executionPath=quick-fix|full-cycle` and `planningMode=direct|OpenSpec`. All four combinations are valid. `direct` is the default; use OpenSpec only when the user requests it or formal discovery/agreement of requirements, architecture, or acceptance criteria adds value. Promotion triggers set `executionPath=full-cycle` but never change `planningMode` by themselves.
- In a managed project, lifecycle, branch-infobase safety, verification modes, `verificationPolicy`, approved test plans, partial-evidence labels, and fresh-check semantics are owned by the host ITL workflow.
- In a managed project, do not invoke `1c-db-ops` or mutating `1c-web-ops` scripts directly. Use the matching `/itl*` bridge or host lifecycle helper; those scripts fail with `ITL_LIFECYCLE_HELPER_REQUIRED` when `.agent-1c/project.json` is present.
- An explicit `/itl*` lifecycle or verification request authorizes the helper-managed operations required by that command only against the owned branch infobase and its local publication. It does not authorize mutation of the source infobase, publication outside the configured local contour, or unrelated external actions.
- In a managed project, `/install-agent-browser` and `/install-windows-mcp` delegate installation and MCP configuration to the host ITL helper. Do not run their generic global-install steps or overwrite workflow-managed MCP entries.
- Never substitute the source infobase for a managed branch infobase.
- `LLM-RULES.md` may refine generic behavior only. It cannot weaken this section or host ITL safety/verification gates.
- Load detailed lifecycle instructions through the project router/helper instead of duplicating them here.
