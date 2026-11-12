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
  managed form (`content/rules/itl-managed-form-context.md`) or using
  project-specific architecture facts.
- For a code review, including `/ponytail-review`, take the scope from the
  helper action `get-review-scope` (see
  `.agents/skills/1c-workflow/references/verification-result.md#review-scope`),
  not from the local delta above, and pass it as the explicit scope.
- An installed ITL project's completion and export status come from its
  helper-owned evidence assessment. A syntax result or a file preview alone
  cannot establish loaded infobase behavior. Preserve exact raw findings and
  use the helper's continuation when a dependent check is unavailable.
- For the upstream validation route above, obtain standalone `syntaxcheck` / `syntaxcheck_file` evidence first; Gate 1 remains mandatory;
  Gate 2 prefers `check_1c_logic` when exposed and otherwise uses
  `check_1c_code`. `verification-policy.md` selects which gates run. A Code
  Checker syntax section never substitutes for standalone `syntaxcheck` /
  `syntaxcheck_file` evidence.
- ITL MCP hosts cannot validate by path (`syntaxcheck_file`, `files`); pass text.

## Completion and repeated obstacles

Authorized work ends when the deliverable and every check its task path
selects have run, or each remaining check has a stated blocker, user limit or
absent tool. A finished sub-item, a check you can run yourself or a tight
context window (hand off instead) is not a stopping point; end earlier only at
a `CONFUSION` fork, a confirmation-gated action or input only the user has.
When the same obstacle survives two attempts without new evidence, change the
route (another tool or entry point, the code path instead of the UI) or report
the blocker with its raw errors; rewording an attempt is not a new route.

## Scoped project memory

Applies only when the `memory_status` tool is available; `project-memory`
holds the details on demand.

- Call `memory_status` once at session start and after a `contextChanged`
  notice: continuation, pending, standing rules and a title index.
- `recall` the topic before designing a 1C change, in an unfamiliar area and
  whenever context is missing.
- `remember` in the same turn after a user correction, a rejected approach, a
  non-obvious finding or a standing condition. A user statement is `verified`,
  an "always/never" rule `standing`, with evidence
  `{source:"user", reference:"chat <date>"}`; never `candidate`.
- A note that contradicts checked code, documentation or the user is updated
  in place (`note_id` + `data_id`) or removed with `retire_note` in the same
  turn, never duplicated under a new ID.
- Choose one `dataset_name` from `memory_status` by lifetime and reach: task
  for the current cycle, workspace across this copy's branches, project across
  branches or copies, product with registry home and independent evidence,
  workplace for its practices, and `host`: environment facts only.
- Organization: only knowledge true across projects and products (platform,
  BSP, tooling, company conventions), never client, project or configuration
  data; `standing` there only at the user's explicit word; retire another
  project's organization note only after the user confirms.
- Give relevant conditions and versions. For a recalled fix, verify current
  branch code and test as needed before claiming it is present.
- After a transient recall failure, use the read recovery in `project-memory`
  if needed. Recall afresh in the next eligible turn of the same chat.
- End a 1C task report with `Memory: recall N, saved N, updated N, retired N`,
  naming any `standing` note.
- Project corrections stay in project memory. Shared `1c-templates-mcp`
  `remember` is only for verified cross-project knowledge; `templatesearch`
  remains available for code templates. Do not turn on a new shared-memory
  provider implicitly.
