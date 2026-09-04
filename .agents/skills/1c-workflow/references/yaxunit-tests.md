# YAxUnit: Algorithmic Unit Tests

Read this reference before changing non-trivial calculations, parsers, selectors, grouping, allocation, rounding, date/period logic, recursive traversal, state transitions, or error recovery. YAxUnit complements Vanessa: it proves local algorithmic contracts quickly; Vanessa proves object interaction, persistence, integration, and visible UI behavior.

## Required decision

Before implementation, identify the changed decision points and risky invariants. Add or update YAxUnit tests when the change can be exercised without a real user journey. At minimum cover:

- the ordinary representative case;
- empty input and the smallest valid input;
- values immediately below, at, and immediately above every changed boundary;
- maximum or practically large input where overflow, performance, or truncation is plausible;
- duplicate, missing, `Неопределено`, zero, negative, and invalid values that the contract permits or rejects;
- rounding, precision, date/period ends, ordering, and locale-sensitive behavior when relevant;
- the dangerous branch whose failure could corrupt data, select the wrong objects, silently lose rows, or report false success.

Use equivalence partitions rather than many copies of the happy path. Parameterized YAxUnit cases are preferred for boundary tables. Every test name should state the contract and expected outcome. A regression must fail on the old defect and retain the original reproducer's path and preconditions.

## Optimization contract

Treat an optimization as a risky algorithm change even when its intended business result is unchanged. Before replacing the implementation, lock the current functional contract with characterization cases across representative equivalence partitions. Preserve the resulting expected values in the tests; do not retain or copy a second production algorithm merely to compare implementations.

In addition to the boundary matrix, an optimization must prove:

- the same values, ordering, rounding, errors, and permitted mutations for representative inputs;
- repeatability for the same input and cache or intermediate-state invalidation when a dependency, calendar, setting, or other relevant input changes;
- isolation between independent plans, objects, tenants, sessions, or calculation contexts;
- no partial or stale state after an error or cancellation, and a safe full-calculation fallback when readiness cannot be proven;
- one small representative performance regression that finishes quickly. Prefer a work-count invariant or a generous stable ceiling over a strict wall-clock comparison.

Correctness failures cannot be waived by a speed improvement. Large data sets, cold/warm timing comparisons, memory profiling, and precise benchmarks are explicit benchmark evidence; keep them outside the ordinary `/itl-check` and never make them part of its default test registration.

## Test groups and cadence

Organize the hierarchical test extension by the owning production subsystem, object, and algorithm. Within each owner, keep fast functional/boundary cases, retained defect regressions, and optimization invariants as recognizable groups. Parameter rows are cases within one contract, not separate execution groups. Every new or changed exported `Module.bsl` must be classified immediately in the YAxUnit catalog described by `verification-suite-selection.md`; do not leave classification for refresh or the final check.

Run all `purpose=default-fast` groups together in one normal YAxUnit session. Do not start a separate 1C process per group: platform and extension startup commonly dominate unit-test time. Keep `purpose=explicit-benchmark` modules outside the default `ИсполняемыеСценарии` registration and run them only through an explicit project benchmark harness. The machine preflight requires complete module/owner assignments and rejects an explicit benchmark module referenced by ordinary registration. Add owner-aware selective execution only after measurements show that the complete fast suite is a material bottleneck; any later selection must preserve a final unfiltered fast run.

## Test seam

Put tests in the hierarchical test extension configured by `yaxunit.testsPath` (default `tests/yaxunit`). Register them from exported `ИсполняемыеСценарии`. Prefer testing a deterministic server/common-module function. If important logic is buried in a form or long procedure, extract the narrow pure calculation or decision into a suitable common module without changing its public behavior. Do not expose broad production APIs solely for tests and do not copy the algorithm into the test.

Use Vanessa instead of YAxUnit when the assertion depends on a form, command visibility, permissions in an actual session, document/register persistence, exchange, background jobs, or a multi-object user workflow. Complex changes commonly need both layers: a boundary matrix in YAxUnit and one or two representative Vanessa scenarios.

## Execution contract

Before any normal executable verification starts, `/itl-check` validates both test catalogs. Missing, invalid, ambiguous, or incomplete classification stops before Designer or Enterprise. It then loads the workflow-pinned YAxUnit CFE and the separate test extension, disables safe mode and unsafe-action protection only for the fixed `YAXUNIT` extension through the local Designer Agent allowlist, and runs `1C:Enterprise /C RunUnitTests=<config.json>`. The authoritative result is JUnit under `build/test-results/yaxunit`; a missing report, zero executed tests, failures, or errors fails verification. The exit-code file is supplemental and a disagreement is reported.

Do not commit the downloaded CFE, generated JSON, logs, or reports. Do not call a locally installed unpinned YAxUnit build. `ITL_YAXUNIT_TESTING=off` may skip execution, but skipped executable verification is partial evidence and must never be reported as verified or done.
