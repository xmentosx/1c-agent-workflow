## ITL managed-project ownership

When `.agent-1c/project.json` exists, read the managed block of project-root
`USER-RULES.md` before acting. It owns the project-specific lifecycle and
verification boundaries; this appendix routes those boundaries without
replacing the upstream process, coding, MCP, memory, or OpenSpec rules.

- ITL owns bootstrap, branch infobases, configuration repository sync, MCP
  client configuration, executable verification, export, and recovery. Use the
  matching installed `/itl*` command or project helper for those operations.
  A generic bundled tool must refuse a managed mutation it cannot delegate.
- Decide `executionPath=quick-fix|full-cycle` and
  `planningMode=direct|OpenSpec` independently. Full-cycle does not by itself
  start OpenSpec. Verification depth, retention of a regression, and permission
  for a named test invocation are separate decisions.
- When substantial uncertainty remains, offer the installed `grill-me` or
  `grill-with-docs` route and OpenSpec where useful; the user selects a route.
  A request to analyze or document alone does not authorize implementation.
- Treat current worktree code, staged and unstaged changes, and untracked
  relevant files as the local delta. MCP indexing of the baseline does not
  replace that delta. Read the matching on-demand ITL rule before changing a
  managed form or using project-specific architecture facts.
- An installed ITL project's completion and export status come from its
  helper-owned evidence assessment. A syntax result or a file preview alone
  cannot establish loaded infobase behavior. Preserve exact raw findings and
  use the helper's continuation when a dependent check is unavailable.
- Keep project corrections in project memory. Shared `remember` is only for
  verified cross-project knowledge; `templatesearch` remains available for
  code templates. Do not turn on a new shared-memory provider implicitly.
