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

## Test seam

Put tests in the hierarchical test extension configured by `yaxunit.testsPath` (default `tests/yaxunit`). Register them from exported `ИсполняемыеСценарии`. Prefer testing a deterministic server/common-module function. If important logic is buried in a form or long procedure, extract the narrow pure calculation or decision into a suitable common module without changing its public behavior. Do not expose broad production APIs solely for tests and do not copy the algorithm into the test.

Use Vanessa instead of YAxUnit when the assertion depends on a form, command visibility, permissions in an actual session, document/register persistence, exchange, background jobs, or a multi-object user workflow. Complex changes commonly need both layers: a boundary matrix in YAxUnit and one or two representative Vanessa scenarios.

## Execution contract

`/itl-check` loads the workflow-pinned YAxUnit CFE and the separate test extension, disables safe mode and unsafe-action protection only for the fixed `YAXUNIT` extension through the local Designer Agent allowlist, then runs `1C:Enterprise /C RunUnitTests=<config.json>`. The authoritative result is JUnit under `build/test-results/yaxunit`; a missing report, zero executed tests, failures, or errors fails verification. The exit-code file is supplemental and a disagreement is reported.

Do not commit the downloaded CFE, generated JSON, logs, or reports. Do not call a locally installed unpinned YAxUnit build. `ITL_YAXUNIT_TESTING=off` may skip execution, but skipped executable verification is partial evidence and must never be reported as verified or done.
