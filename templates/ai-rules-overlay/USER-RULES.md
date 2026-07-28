# User Rules

## Migrated content from a previous setup

<!-- start of migrated content -->
<!-- end of migrated content -->

## ITL hard gates

- Before changing code or metadata, run the host ITL preflight. First record `executionPath=quick-fix|full-cycle` by applying `AGENTS.md` and `verification-policy.md` exactly. For `full-cycle`, also record `planningMode=direct|OpenSpec`: direct is the default when scope and solution are clear; use OpenSpec only when the user requests it or formal discovery/agreement of requirements, architecture, or acceptance criteria adds value. Promotion triggers require full-cycle depth but never force OpenSpec by themselves.
- In a managed project, lifecycle, branch-infobase safety, verification modes, `verificationPolicy`, approved test plans, partial-evidence labels, and fresh-check semantics are owned by the host ITL workflow.
- Never substitute the source infobase for a managed branch infobase.
- `LLM-RULES.md` may refine generic behavior only. It cannot weaken this section or host ITL safety/verification gates.
- Load detailed lifecycle instructions through the project router/helper instead of duplicating them here.
