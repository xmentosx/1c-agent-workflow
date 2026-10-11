# Component-owned source Python: B.4

Source verification used ambient PATH Python for Mantis, BookStack, CodeChecker,
native transport and Linux-host regressions. SPPR required a manually prepared
build/sppr-venv. Repeated runs depended on unrelated installed packages and left
preparation outside the owner continuation.

The source checker now delegates to scripts/host-test-runtime.ps1. It reuses the
existing host interpreter resolver and UTF-8 bounded child-process owner, then
creates a checkout-local, component-specific venv under ignored build. The key
binds bootstrap absolute executable/SHA/version, component and authoritative
requirements SHA. Tests use that venv's absolute Python path. Bootstrap discovery
retains the existing verified resolver; ITL_SOURCE_TEST_PYTHON selects it explicitly.
SPPR_TEST_PYTHON remains an isolated external override: verified, never modified.

Only the selected component is prepared. SPPR installs its complete requirements.
BookStack source tests use real snowballstemmer/httpx/numpy but fake the model/MCP
SDK; its three constraints are selected from production requirements without
duplicated version policy or transformer models. Other current source suites use
stdlib/fake-SDK fixtures. Original scripts/assertions remain; this does not claim
real SDK/model/Zvec acceptance. Additional routes must declare their real imports.

Preparation verifies actual isolation, pip consistency, package versions and
imports. A damaged owned dependency is repaired once and verified before the
original test proceeds. Failed repair retains that environment and gives the same
component-test continuation. External overrides report their own repair continuation.
No global Python, installed host, user database, common Git lock or coordinator
is changed. Config/state paths are per component. Unknown host runtime identity
still disables shard reuse; no unproved Python/Node cache was introduced.

Focused Windows PowerShell5.1 / Python3.13.13 proof:

- Mantis original wrappers:2/0,37.04s; test_index Unicode marker retained.
- Final BookStack/CodeChecker/native/selection/three short owner tests:19/0,
  46.35s including preparation. Linux and SPPR passed their original routes;
  SPPR corpus/HTTP case24.17s. Cohorts differ: no full-gate speed comparison.
- Owned dependency repair:1/0,82.01s total /74.29s case. A private real SPPR venv
  loses tzdata through pip uninstall, repeats preparation and successfully runs
  the original test_sppr.py in the same environment. No metadata is rewritten.
- Four new cases protect own-only isolation with poisoned PATH, missing-bootstrap
  continuation through original Mantis tests, read-only rejection of global SPPR
  and real dependency repair through original corpus. Selected for runtime-helper
  changes, not every component edit.

The first batch exposed missing BookStack real imports and PS5.1 treating successful
unittest stderr as a terminating error in two wrappers. Imports were added from
owning requirements. Wrappers restore ErrorActionPreference while capturing stderr;
exit-code and original test-count assertions remain strict. Workload was preserved.

Catalog ownership and loaded inputs were updated. Source-only, always-on context
delta0. One RegisterChange accepts this unit. Real 1C stand preparation, original
PM5 negative acceptance and trial publication remain separate open tasks.

## Additional necessity review

[node-proxy-review.csv](node-proxy-review.csv) covers all eight frozen Node
definitions: seven native HTTP/process journeys and top-level transformations.
They protect distinct risks; all retained. CLI port reservation and bounded
child-stop are explicit follow-ups, not inferred flakes or reasons to delete
the reproducer. Source SHA matches the inventory; no unchanged Node suite rerun.
Original-inventory coverage317/2814;2497 pending. Four new runtime-owner cases
are documented above and are not counted as reviewed original definitions.
