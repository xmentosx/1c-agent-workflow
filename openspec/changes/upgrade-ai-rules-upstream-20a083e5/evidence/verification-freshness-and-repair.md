# Verification identity and the shared repair session — 2026-09-30

## Relevant proof inputs

The existing verification owner now assesses source and declared requirement
inputs, obligation/expected-result identity, actual loaded target generations,
relevant runner/dependency bytes, checker identity, result artifacts and proof
limitations. Invocation authorization remains provenance; its expiry does not
invalidate an already completed observation. Unrelated dependency pins,
package commit ids for unchanged verification bytes and unrelated OpenSpec
changes do not force a test run.

Four focused `VerificationProofReuse` regressions passed, alongside the transient
scenario test, in `build/proof-and-transient-final-focused.xml` (5/5, 16.33 s).
They executed the actual fingerprint/selection/evidence functions on owned Git
fixtures, checking a false-pass checker correction, loaded configuration and
infobase/service generation changes, relevant versus irrelevant dependency
updates, and a declared OpenSpec requirement versus an unrelated change. Checker
changes during an observation are rejected rather than signing the old result
with a new checker. A passed one-off result with expired invocation provenance
remains reusable when its actual checked inputs still match.

The loaded-target test was then extended with the actual pre-upgrade absence of
`lastVerifiedLoadedBaseIdentity`. The same bytes/commit-independent result stays
fresh before removing that field, and becomes stale when the legacy record
cannot identify what infobase was tested. This is an intentional conservative
transition, not fabricated compatibility with old proof. The changed test alone
passed (`build/proof-legacy-loaded-base-final.xml`, 1/1, 1.59 s). It does not
start tests during workflow file update; the next explicitly requested canonical
assessment decides which currently due proof must be obtained.

These are source-owner identity and assessment qualifications. Actual combined
installed one-off → canonical check → block export and remote validator execution
remain separate canaries; no fake runtime response is reported as their pass.

## One persisted repair owner

The qualified fork's `content/commands/test-fix-loop.md` routes managed projects
to `begin-verification-repair -VerificationRepairKind scenario-loop`, then the
same canonical `check-dev-branch` owner with the recorded scenario scope and
session id. Standalone deploy/web loops apply outside managed projects only.
The actual fork command was inspected; exact fork Full qualification includes
the installed route, independently of the source fixture tests.

Nine selected existing repair/diagnostic regressions passed
(`build/repair-session-final-focused.xml`, 9/9, 6.91 s). They exercise persisted
session id/remaining attempts, canonical default 5 versus scenario default 3,
scope preservation, no-change repeat rejection, feature disappearance without
consuming another attempt, exhaustion and genuine tooling recovery. A stale,
reissued or partial recovery receipt cannot reset the outer budget. The named
round invokes one load and consumes one attempt, followed by diagnostic and
unfiltered assessment in that same round; only the latter can complete it.

The additional existing transient-feature regression passed in the 5-test run
above. An ignored Cyrillic `.feature` is executable current proof and remains in
the recorded scope; it is not silently classified as retained regression
coverage. Changing an agreed business expectation still requires evidence and
the user's confirmation, as required by the fork command and the installed
verification reference. Passed scenario proof uses the same source/input
freshness owner, so a later relevant fix invalidates dependent prior evidence.

These tests qualify the persisted owner and canonical orchestration, including
bounded recovery. They do not claim a native Vanessa application scenario ran
on PM5; that live proof belongs to the remaining installed end-to-end canary.

## Effective saved-runner policy

Review found that the executable decision owner respected
`ITL_VANESSA_TESTING` but omitted the accepted `TOOL_BROWSER` filter for saved
Vanessa. The retained regression failed before the fix: a routine command ran
despite provider off (`build/vanessa-provider-policy-before.xml`, 0/1).
The owner now checks both settings, reports an invalid provider value with its
correction, and records a named invocation's provider override explicitly.
There is no persistent settings write or alternative launcher.

The provider regression and existing execution-mode matrix passed together
(`build/vanessa-provider-policy-after.xml`, 2/2, 12.12 s). They cover routine
off, an unrelated named component, the named Vanessa exception, expiry on the
next ordinary call, independent YAxUnit, invalid values, required/default policy,
and unchanged project settings bytes. `UI_TESTING` still selects interactive
UI separately; it does not disable saved Vanessa by itself. Required policy
never proves runtime readiness: the existing runner's capability checks remain.
The agent must resolve a broader current no-UI instruction before requesting
the helper; a named scenario does not silently lift that instruction.

The same repair owner's no-change identity includes the actual provider policy,
so correcting that prerequisite permits continuation without creating a new
session or resetting its budget. Six directly related regressions passed
(`build/verification-provider-continuation.xml`, 6/6, 4.05 s), preserving the
original feature/source changes, transient-feature handling, stale proof,
fresh-proof reuse and skipped-runner preflight behavior. The installed
named-run → ordinary canonical check → block export canary remains pending;
these source tests are not reported as that native runtime proof.

Cross-review reproduced two further invocation defects: an explicit named
Vanessa call also selected unrelated automatic YAxUnit/event-log components,
and policy case/whitespace changes could consume a new scenario round. Both
expanded regressions failed before correction
(`build/verification-named-scope-before.xml`, 0/2). The decision now confines
explicit calls to their named set (`all` remains an explicit set), and repair
identity uses normalized effective policy plus validity. Eight directly owned
regressions then passed (`build/verification-named-scope-after.xml`, 8/8,
15.85 s). A named component's partial result is still not whole-task proof.

The same cross-review found a distinct readiness gap: current one-off receipts
could not establish whole readiness without a pre-existing global passed state,
even when all due component/suite proof was sufficient. The original mock-based
fresh-proof tests did not cover that boundary. Correction and a regression that
uses actual hashed receipts belong to the existing assessment owner and are in
progress; no completion or block-export pass is claimed yet.
