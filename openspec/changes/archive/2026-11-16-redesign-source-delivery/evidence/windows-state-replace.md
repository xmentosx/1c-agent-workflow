# Windows SPPR state replacement and stale owner expectation

Develop candidate6a65b159 passed the original negative PM5 journey and positive
upgrade, fresh verification inside upgrade and export. Its enclosing static
stage stopped on two failures; the overall Develop and separate fresh journey
remain unqualified. Raw evidence is in ignored runtime-proof/develop-6a65b159.

SPPR test_rate_limit_cooldown_survives_scheduled_restart failed at the initial
atomic_json replacement of embed_attempt.json: PermissionError WinError5.
The writer had already flushed/fsynced its unique temp; os.replace failed.
The external holder in that run is unknown; no antivirus/load attribution is
claimed. A real Windows reader without delete sharing reproduces the denial
on a whitespace/Cyrillic path. The old state remains readable until release.
Windows rename/delete sharing follows the native contract documented by
[Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilea).

The existing SPPR atomic_json owner retries only native Windows errors5/32/33
at the replace boundary, for at most one second. The same flushed temp is
reused; the committed target is never deleted. Persistent denial keeps the
old state, surfaces the original exception and removes the owned temp.
Other errors are not retried. No runner timeout, workload or original
rate-limit/overlap assertion changes. Three boundary regressions plus the
original scheduled-restart test passed4/0 in1.433s, including real reader release
and exact Unicode readback. Native component acceptance belongs to RegisterChange.

The second failure was ImmutableDownloadRetry's expectation of only one owner.
The shared helper is used by Pester archive preparation and release readiness;
the catalog already declares pester-cache-compatibility, pester-shard-identity
and release-readiness-tests. The corrected assertion requires all four exact
owners and retains the six original consumer assertions, adding the two Pester
consumers. Focused original case passed1/0. No dependency or reproducer is removed.

This does not establish that earlier SPPR overlap failures had the same cause.
Their original workload and exception-cause instrumentation remain intact.

Normal registration `0d337815` passed207/0/0 in53207ms (raw54715ms).
The native HostSppr wrapper executed all64 Python cases; HostTooling and
ParserDocs remained static, and the explicitly changed ImmutableDownloadRetry
suite also passed. No unrelated Python component or1C journey was selected.
