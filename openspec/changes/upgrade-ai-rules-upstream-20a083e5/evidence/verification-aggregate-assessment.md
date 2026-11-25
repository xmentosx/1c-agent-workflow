# Canonical assessment from current receipts — 2026-09-30

Scope: existing verification coordinator/selection/receipts and their existing
artifact-retention and repair consumers. No new journal, deployment owner,
execution override, infobase load or UI launch was introduced by assessment.

## Reproducer and correction

`VerificationAggregateAssessment.Tests.ps1` uses real Git input identities in a
path containing whitespace and Cyrillic, real begin/complete one-off receipts,
an exact loaded-target state, hashed observed event-log evidence and, in the
second case, retained `affected` plus `handoff` acceptance receipts. The source
and expected assertions are preserved. Reports are fixture evidence; this is
not a native 1C or MCP acceptance run.

Before correction both cases failed: all runners stayed off, but sufficient
current evidence could not become fresh whole readiness because legacy global
`lastVerificationStatus/lastVerifiedFingerprint` was the first prerequisite.
The original failing artifact is `build/verification-aggregate-before.xml`:
**0/2, 13.07 s**. Independent receipts previously could only supplement a
previously stamped full run.

Now `Get-VerificationState` assesses current component and obligation receipts
through the existing owner. All-off ordinary check starts no runner and reuses
complete proof; status and export/close read that same assessment. No legacy
global fingerprint is forged. A filtered named diagnostic cannot become a
whole result; a named component can contribute only its own actual receipt.

Readiness requires current source matching loaded CF/CFE, proved application
normalization, complete classification, current clean event-log evidence, all
one-off obligations, all retained acceptance suites and applicable default-fast
YAxUnit evidence. It validates original artifact SHA and the authoritative
JUnit rules. Unknown receipts stay unverified. A permitted unfiltered retained
runner supplies missing observed receipts through existing selection.

The existing catalog admits retained `handoff` with the same acceptance or
default-fast purpose; it does not rename or discard a functional test. A
classified current one-off decision may cover branch-owned BSL without falsely
claiming `not-applicable`; its actual receipt remains independently required.
Read-only assessment never creates a missing adoption baseline.

## Focused evidence

- Initial corrected causal cases: `build/verification-aggregate-after.xml`,
  **2/2, 23.07 s**.
- Expanded owner batch: `build/verification-aggregate-owner-tests.xml`,
  **48/50, 75.78 s**. The two failures were old isolated state doubles missing
  `isFreshPassed`; their real runner/reuse assertions were retained and the
  doubles gained that existing returned property.
- Corrected selector slice: `build/verification-aggregate-owner-after.xml`,
  **19/19 selector cases passed**; the combined run also exposed the new
  retained-artifact protection bug, preserved as a failing case. The retention
  owner now reads its known JSON array directly instead of the text-oriented
  state-value helper that dropped complex arrays.
- `build/verification-aggregate-receipt-retention-after.xml`: existing
  retention/branch-deletion **11/11 passed**. The new positive receipt producer
  exposed that Vanessa summary `files` are path/SHA objects; its adapter now
  uses their paths, preserving the original artifact assertions.
- `build/verification-aggregate-receipts-final.xml`: expanded causal cases
  **2/2, 53.23 s**. Checks include missing/changed event-log, changed exact
  target, source not loaded, missing retained handoff, zero-test JUnit even
  with a matching SHA, failed retained rerun, original-command receipt
  recovery, actual event/retained receipt writers and referenced-artifact
  retention. Permission expiry in provenance does not invalidate proof.

## Scoped retained target and native per-suite identities

The retained receipt binds nonempty project root, infobase kind/path, base
tooling generation and Vanessa service generation. It also binds branch kind,
extension/name, service kind/path/schema/template SHA/user and the connection
hash computed by the existing primary infobase identity owner. Auxiliary scope
additionally requires its existing nonempty connection hash and contour
name/base mode/suite. Missing identity is unverified. The full loaded identity
is preserved as provenance; one-off identity remains strict. Current source
must independently match loaded CF/CFE. Suite inputs, expected result and
relevant runner/checker contract remain strict, so an unrelated product change
and valid reload preserve unaffected coverage without claiming that changed
coverage passed.

- `build/verification-aggregate-scoped-target-after.xml`: **2/2, 79.10 s**,
  including valid Integration-only reload selecting Integration incrementally,
  preserving Orders' original provenance, and source/runner/auxiliary negatives.
- `build/verification-retained-unknown-target.xml`: **1/1, 1.79 s**, required
  missing target/generation and missing auxiliary connection reject reuse.

Producer review found that total JUnit count alone could give a passed receipt
to an unobserved selected suite. The pinned native source at
`C:\itlvabld\va42`, commit `a0ce2ee9803dd69be52f682e5cf49e0938fd33f1`,
emits feature basename as `classname` (optionally directory-qualified) and
scenario name as `name`; outline examples append ` №` plus the zero-based
index inside their Examples group. These contracts were read in
`lib/FeatureReader/FeatureReader/Ext/ObjectModule.bsl` and
`VanessaAutomation/Ext/ObjectModule.bsl`, not inferred from a green fixture.

The new causal reproducer selects Orders plus Integration. Two passed Orders
testcases satisfy the unchanged native total-count assertion; Integration must
remain partial. Original failure: `build/verification-suite-observed-before.xml`,
**0/1, 3.38 s**. Its extension also proved an older legacy global pass could
bypass that new partial receipt when no component receipt existed:
`build/verification-suite-partial-consumer-before.xml`, **0/1, 5.64 s**.

The existing receipt producer now records observed per-suite coverage;
missing/duplicate/ambiguous identities stay partial. The shared assessor
rechecks the exact hashed reports and that coverage. New suite receipts select
that assessor even when the earlier legacy state says full/passed. No extra
runner or state journal is used. The original all-off reproducer keeps its
feature paths, identical titles/scenario names, source workload and assertions;
its formerly generic XML fixture now uses the pinned native classnames.

- `build/verification-aggregate-coverage-after.xml`: **4/4, 77.54 s**,
  including the original two all-off causal cases and the new producer case.
- `build/verification-suite-observed-powershell51.xml`: **2/2, 6.23 s**,
  including the partial legacy consumer, directory-qualified same basenames,
  honest ambiguity and outlines with multiple Examples groups.
- Feature-content/name change had a separate preserved causal failure:
  `build/verification-feature-scoped-before.xml`, **1/2, 67.65 s**. The original
  Integration feature is temporarily changed and restored inside the existing
  test; its unmodified workload/assertions remain intact. The old passed receipt
  must validate its recorded coverage/artifact/checker, while current feature
  mapping is required in selection only when that suite's fingerprint stayed
  unchanged. Existing incremental selection reruns Integration; Orders stays
  reusable. Canonical readiness still requires current mapping. Corrected
  `build/verification-aggregate-complete-final.xml`: **5/5, 76.42 s**.
- A shared qualified XML initially counted the other suite's same-basename case
  again during per-suite reassessment. Preserved consumer failure:
  `build/verification-suite-qualified-consumer-before.xml`, **1/2, 5.59 s**.
  The same catalog path mapping now identifies explicitly qualified other
  suites before counting only this receipt's cases. Bare ambiguous identities
  remain partial. `build/verification-suite-qualified-consumer-after.xml`:
  **2/2, 5.69 s**; original ambiguity/outline/legacy partial assertions retained.
- Dependency-focused existing selection/proof-reuse/nested-selection tests:
  `build/verification-observed-dependent-checks.xml`, **46/46, 30.13 s**.
- Authoritative existing failed-verdict JUnit parser regression:
  `build/verification-junit-parser-dependent.xml`, **1/1, 1.85 s**.
- After the final shared-report mapping correction, the original expanded
  all-off/scoped causal cases were rerun against that exact implementation:
  `build/verification-aggregate-final-mapping-causal.xml`, **2/2, 73.69 s**.
  No runner started. Six owned PowerShell files parsed with **0 errors**;
  owned diff whitespace checks passed.

## Unverified dependency batch

`VerificationSelection.Tests.ps1` completed **19/19, 11.98 s** in the earlier
combined selector/ClientAdapters attempt. `ClientAdaptersAndModes.Tests.ps1`
did not finish after more than ten minutes; `build/verification-aggregate-selector-consumers.xml`
was never finalized. Normal output did not identify the active It, so its exact
identity and cause remain unknown. The last visible successful action was the
OpenCode required native workspace user setting, followed later by a Git
warning. Only the test's own `pwsh` PID 67428 (start 20:24:43; unique result-path
command identity) was stopped after checking its owned child tree. No foreign
process or lock was removed. Its registry-writing case may have been interrupted
before `finally`; the original User value was not captured. No guessed host
restoration or repeat of that case was performed. Environment broadcast is only
a hypothesis, not diagnosed causality or qualification.

These are separate focused runs, not one combined Full qualification. Parser
and owned diff checks passed. Native whole check → real export/close and
representative installed-project migration remain task **4.7/10.4** acceptance.
