# Installed context and operation cost — 2026-09-30

The comparison uses the actual published-master r33 fixture and the installed,
correct-provenance ee9/r37 canary, not an intermediate planning JSON or the
source repository's maintainer `AGENTS.md`. The captured paths and SHA256 values
are in `build/migration-context-bytes.json`.

| Installed surface | Published r33 bytes | New canary bytes | Change |
|---|---:|---:|---:|
| `AGENTS.md` | 13,524 | 13,586 | +62 |
| `USER-RULES.md` | 2,000 | 11,169 | +9,169 |
| Combined root instructions | 15,524 | 24,755 | +9,231 / 59.46% |

These are physical UTF-8 bytes, not exact model tokens or measured session
loading. There is no separate `.codex/instructions.md` at either root. The new
`USER-RULES.md` preserves the entire old user file as an exact text prefix.

The material increase is primarily the host-owned instructions appended to
`USER-RULES.md`: lifecycle and source-base isolation, command routing, current
evidence versus retained regressions, result readiness, recovery ownership,
product-documentation obligations, project versus shared memory, multi-client
ownership and the temporary local-only OpenSpec boundary. This is the approved
D1/Q15 composition: retain the upstream root and preserve the host's semantic
additions in its own contribution. It measures all accumulated package changes
against the published baseline; it does not isolate upstream-only growth.

The existing user prefix cannot be discarded as apparent duplication. Detailed
lifecycle, tests, MCP and update-recovery procedures remain in references loaded
on demand; root rules retain the prohibitions and completion obligations that
must survive ordinary tasks. No safety rule was compressed merely to lower the
byte count. Any later simplification needs a semantic comparison and separate
evidence, rather than silently removing preserved user or host behavior.

The corrected installed read-only doctor took 4.883 s, preserved its nine
protected paths plus Git HEAD/index, and launched neither test nor configuration
load (`build/installed-doctor-readonly-acceptance.json`). Exact native OpenSpec
phase timings are retained with their individual outcomes in the canonical
migration evidence. They are observations, not a paired old/new performance
benchmark. Native Gate 6 snapshot/recovery timings and original continuation
proof are in the Gate 6 evidence.

The stopped-operation update exposed a separate optional agent-browser doctor
hang. Its elapsed delay is a defect and must remain visible; it cannot be
reported as an ordinary healthy update time. The same original workload later
reached the UI owner's bounded timeout after 101.97 seconds and confirmed owned
process cleanup. This qualifies failure handling, not a healthy browser doctor;
see [the runtime and UI owner record](client-runtime-and-ui-owner.md).
The original PM5 initialize also completed after guarded recovery on immutable
B2; its later full refresh and package transition remain under acceptance.
Overall init/update, unchanged-operation and representative PM5/server costs
remain part of the open installed canary; this table alone does not close 10.4.

Ordinary Windows PowerShell 5.1 `help` also exposed a separate avoidable cost:
41.310 seconds in the root observation and 43.833 seconds in the causal probe.
Twelve repeated execution-context process scans consumed 42.593 seconds of the
latter. Resolving the display client once reduced that same command to 5.479
seconds with one scan, identical raw output, clean Git and unchanged 14 global
files. Membership and manifest checks remain at their original owner. The
separate development-context forwarding correction is covered by nine
prefix/context combinations rather than relabelled as native master timing.
See [the exact before/after and scope](native-help-client-resolution.md).
