# External runtime reuse admission

The previous catalog unconditionally disabled reuse for 20 Pester files. Audit
found three distinct inputs: native Git/Windows fixture dependencies, actual
language runtimes, and genuinely fresh unpinned Python environment resolution.
There is no actual 1C launch in SourceQualificationFixture: native launch/admission
is mocked, while the original Git, rollback and Unicode child-process cases stay.

The existing scheduler now observes per-file external profiles in its selected
Windows PowerShell child. The adapter runs the unchanged original worker and
collects the same profile before/after. Cache admission additionally requires the
actual witness to match the parent observation. Unknown/missing/altered witnesses
disable reuse; tests still execute and failures still fail. Manifest/JUnit SHA,
selected-test path, owner inputs, locks, base Pester identity and native assertions
are retained. Ordinary non-profiled worker keys and script bytes are unchanged.

The 17 potentially reusable files cover SourceQualificationFixture, SourceE2E
storage/disk monitor, four Vanessa OneScript suites, stdlib host/ChatGPT suites,
Node tools proxy, ChatGPT install/policy and the Go component. Their profiles hash
actual consumed distributions/configuration. SourceQualificationFixture includes
its published ancestor/template input. Python stdlib venv bootstrap bypasses
global site plugins. Each stdlib profile also hashes every byte of the selected
component's existing venv generations, including Scripts, configuration and
site-packages; missing environments cannot qualify proof. Other components do
not invalidate its identity. Go uses its locally available pinned toolchain and an offline
`go list` source closure, not an expensive hash of the whole SDK/test corpus.
Initial Desktop observation before adding per-component venv closure took about
four seconds on this host; the final closure is measured separately.

The final real-environment probe rejected a cost regression in the initial
19-file draft: one BookStack environment observation took 17.572s, SPPR 64.343s.
Their unchanged native tests passed 3/3 together in 39.582s (bodies 9.375s and
25.76s). Repeating full package hashes before/after each test costs more than
these original checks. They retain direct native execution with that reason;
no package-byte or assertion shortcut was introduced. HostSourceRuntime still
creates fresh fixture environments resolving unpinned dependencies and retains
that distinct reason. The accepted scope therefore removes 17 unconditional
repeats, not all 20 at any cost.

The bounded parent probe publishes atomic incremental receipts, Windows first.
A slow or interrupted profile leaves its row unknown while completed independent
profiles remain eligible. This avoids losing all qualified inputs at the 60s
observer limit. It neither extends the deadline nor permits unknown reuse.
No runtime is installed or repaired by Plan/identity observation.

Regressions use the real scheduler and worker with an external directory whose
path contains whitespace and Cyrillic. They cover cold/warm proof, changed bytes
at an unchanged path, cross-worktree reuse, read-only preview, integrity-valid
proof without an external witness, missing profile definitions, unknown runtime
and drift during execution. A native timeout regression proves independent
completed-profile reuse and unfinished-profile execution without running tests
during preview. The component closure regression binds DLL, cfg and
site-package bytes, rejects system-site leakage and avoids unrelated components.
Validation and registration receipts are retained under ignored build/external-runtime-*.

The original 17-file cold workload passed 269 tests, with zero failed/skipped.
This is execution acceptance, not yet final qualified reuse: subsequent review
added the per-component venv closure before registration.

Final focused regressions before the timeout addition passed 7/7, zero failed or
skipped. Package original-workload cost qualification passed 3/3.

The native Windows PowerShell regression caught the null-backup boundary in
File.Replace. The stateless writer now uses an explicit backup and a unique
receipt path for each observation invocation; old outputs cannot qualify a new
probe. Cold/warm/unknown proof and native partial-timeout regressions then passed
2/2 (67.09s), with their original assertions retained.

Unobserved Python startup/search hooks and custom Git execution/configuration
paths fail closed for reuse. Native regressions cover actual Git hooks/override
configuration; the component regression rejects injected .pth startup input.
The unfiltered catalog-consumer fixture now imports the authoritative profile
selector alongside the digest function. Its original 29-consumer invalidation
assertions passed unchanged (16.05s); no catalog or consumer was removed.

Host unknown-identity admission remains an early refusal: the digest now checks
profile qualification before inventory/pattern preparation. The original host
unknown-runtime reproducer still supplies no inventory, and its assertions are
unchanged. Only its extracted helper dependency was added. The host refusal,
fingerprint variants and real cold/warm regression passed 3/3 (63.66s).

The exact accepted candidate 063f0b85 passed Targeted, and its original 17-file
native workload passed 269/0/0. That real invocation exposed an overbroad Git
override rejection: the execution host inherits GIT_PAGER=cat. The original Git
calls capture stdout through pipes, so this pager does not select an external
runtime/input. A follow-up admits this exact setting and normalizes it out of
Git/ancestor/inventory identity; other overrides remain unqualified. Native
regressions compare unset and cat identity, while retaining hooks and template
rejection. All three Git configuration cases passed.

The accepted 2a01f1cb workload passed 269/0/0 with 17 qualified files; its warm
run executed zero files and reused all 17. A separate exact-candidate worktree
then exposed a false Git mismatch: effective ordered settings matched, but
--show-origin included different administrative config.worktree paths. The
observer now hashes ordered effective settings without their origin spelling.
A real two-worktree regression first failed on that mismatch; it also requires
execution after a changed worktree setting and reuse only after requalification.
Conditional configuration and external hook/attribute/template rejection remain.

Reuse of checkout-local Python environments remains conditional on their actual
bytes. A clean planner copy with no component venv must execute those seven files;
same-checkout proof cannot substitute for an unobserved environment. The three
explicit original-workload exceptions above also remain. Concurrent queue runtime
changes can independently require fresh and ondemand-mcp Release qualification;
the external-shard optimization does not authorize skipping those stages.
