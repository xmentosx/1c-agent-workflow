# Git continuation for branch creation and refresh

Use this reference on `requiredAction=prepare-lifecycle-git:`. This is agent-owned
work within the requested operation. `blockerRequiresUserDecision=false` means
inspect and continue, not ask for general permission or stop at the diagnostic.
The result's `blockerOwner` identifies the operation, phase and exact paths.
If a bounded compact result omits that object, read `blockerOwner` and
`requiredAction` from its `statusPath`; do not load the whole console log.

## Before branch creation

Review staged and unstaged diffs for those exact paths and establish ownership
from the current task. Commit the necessary task-owned work locally without an
additional confirmation. Use literal, quoted pathspecs and a path-limited commit
(`git commit --only -m <message> -- <reviewed-paths>`); never commit the entire
index just because it is staged. Preserve other owners' staged entries and
unstaged bytes. Inspect both sides of a rename. Do not include secrets/runtime.
When one file mixes different owners' work, separate it only if provenance and
the intended result are clear; otherwise give concrete options and recommend
the smallest decision needed. Do not reset, stash, discard or overwrite work.

`/handoffs/` is the installed project's local report directory; install/update
ensures its ignore rule. Existing tracked reports remain tracked. On an older
installation, an exact local `/handoffs/` info/exclude rule can unblock untracked
reports while retaining all bytes and user exclusions. This is a local recovery,
not proof that upstream is fixed. Do not commit diagnostics solely to hide them.

After the reviewed local commit or report exclusion, repeat the original wrapper
with its original arguments. Record the local commit SHA; it is not publication.
Do not claim that a passing Git preflight created a worktree or infobase.

## During refresh and refresh-lite

The existing pre-merge checkpoint remains helper-owned. Once merge has completed,
the helper admits independent `CONTEXT.md`, `docs/` and `handoffs/` changes only
when they do not intersect source/runtime/configuration or declared verification
inputs. A `.md` suffix or a documentation directory alone never proves independence.
These independent changes stay on disk and in the index; no commit is required.

For changed inputs or an unknown path, inspect the exact diff and phase. Satisfy
the input requirement through the existing owner, preserve the saved transaction
and repeat the same refresh wrapper. A reviewed ordinary local commit outside an
unfinished merge can be appropriate; it does not replace source integrity or fresh
verification. Before committing, check that the recorded transaction accepts that
continuation. Never create a lifecycle merge commit manually or edit its journal.
For an active helper-owned merge, repair and stage the supported semantic paths,
then repeat the wrapper so the helper validates and commits its own merge.

Do not repeat completed master/seed/merge stages, retarget the operation, bypass
the exact infobase guard or broaden this exception to close/reset/source-sync or
publication. If another Git operation or active owner conflicts, continue
independent work and ask only for the unresolved incompatible choice, with
options, consequences and a recommendation. Re-read paths after a concurrent
change; do not repeatedly retry the same failure without changing its cause.

Success requires the original lifecycle result, not a clean tree or local commit.
Follow the command's existing `userReport` and post-refresh classification rules.
