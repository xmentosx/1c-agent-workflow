# Project artifact placement

This contract applies to every client working in the project, including source
maintenance. It governs files whose output location the agent chooses.

## Choose the current project worktree

Put ad hoc diagnostics, raw tool-response captures, screenshots, investigation
scripts, downloaded investigation dependencies, unpacked research copies and
intermediate CF/CFE exports under ignored `build/agent-artifacts/<task-id>/` in
the current project worktree. Use a separate task directory to avoid collisions
with concurrent work. Do not use another branch's checkout or its main worktree.

Never choose a client home directory for those project files. This includes
`~/.codex/visualizations`, other directories under `CODEX_HOME`, and equivalent
Claude Code, Cursor, Kilo, OpenCode or other client homes. A host-provided writable
output directory is not a reason to choose it over the writable project.

Keep existing helper-owned locations authoritative: exports belong in their
configured result path, tests in their configured report path, and lifecycle
runs in their owned runtime directory. Do not redirect a helper's evidence,
snapshots or recovery files into the ad hoc directory. Put requested source,
documentation and final deliverables in the appropriate project location;
temporary placement must not hide intended versioned changes.

An explicit user destination takes precedence. If no project is selected or its
directory cannot be written, explain that specific limitation and obtain a
destination instead of silently falling back to a client home.

## Client and tool-owned exceptions

The client still owns its history, settings, authentication, internal state and
shared dependency caches. Preserve their supported locations. Reuse managed
shared caches rather than downloading a separate copy for each investigation.

When a tool fixes its own output location and offers no project-local output
option, preserve its contract and report the exact location and limitation.
Use a project-local destination whenever the tool supports one. Do not move,
delete or reconfigure client-owned files to enforce this rule, and do not copy
large outputs into both locations without a task requirement.

## Finish the task

Remove only this task's disposable intermediate files after their consumers
and owned processes finish. Preserve required verification evidence, recovery
artifacts, final deliverables and files needed to continue unfinished work.
Report retained large intermediates and why they remain. Keep runtime artifacts
out of Git; do not stage them simply because they are now inside the project.

This placement rule does not authorize a sweep, migration or deletion of old
files, and does not extend the existing helper's cleanup ownership. Existing
retention, reference and active-operation protections continue to apply.
