# client_mcp publication support cut

This source-only cut starts at published develop
`81f0a649fa98ece826aec97b60ed58202e208b2b`. It carries the client component
recognition, immutable plan identity, paired CFE/source finalizer and exact
Release evidence contract from `38643929e6075e8268f973c81f6be81e72435c69`.
The 23-path cut includes the matching Release stage catalog and test expectation: `ondemand-mcp`
version 5 and its complete existing input inventory.

The production dependency lock remains the baseline: ai_rules r36, Vanessa
1.2.043.42-itl-r1 and the upstream client_mcp v0.6.5 CFE. External client pins
remain valid; paired corresponding-source assets become mandatory only for an
owned client pin. No migration runtime or installed-project files are included.

The native builder and its stateless source contract are internal support for
the later component candidate. This baseline does not contain
`New-DesignerGate6Snapshot` or `Invoke-DesignerGate6CheckLadder`; do not run the
native builder from this support cut. Build the component from the exact later
candidate that contains its existing Gate 6 owner. The published finalizer
reads that candidate's manifest and complete build-input inventory and requires
its native checks, snapshot restoration, released processes and exact CFE/ZIP
hashes. It does not build the component or import the candidate's runtime into
the supervisor.

Qualify and publish this support cut through the existing delivery owner in its
separate clone/common Git before introducing an owned client pin in the later
candidate. Reverify the actual published baseline and remote movement when
publication is authorized. Do not alter the migration checkout's queue or use
the candidate as its own supervisor. Preparing this cut grants no publication
authority and is not native or live qualification.
