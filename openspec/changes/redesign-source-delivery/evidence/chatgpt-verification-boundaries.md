# ChatGPT verification and endpoint/watchdog necessity review

Source baseline: `fa0e3c91694112c1da3ecda7209a8a81ea828264`.
The original four ChatGptBridge Pester definitions combined unrelated source,
installation and Python boundaries. Guide edits did not select their policy
assertions. Three Python plugin-bundle definitions duplicated these policies
while also carrying unique absence and guide requirements.

The original Pester definitions are now separated into ChatGptSourcePolicy,
ChatGptInstall and ChatGptBridge. SourcePolicy retains the unique Python
requirements, including case-sensitive literal guide checks, absence of nested
SKILL entries and generators, and canonical tracked bridge/bootstrap paths.
The actual NoInit installation and copy/readback assertions remain unchanged.
Only the three redundant Python definitions are removed; all six stdio,
HTTP/configuration and CLI runtime cases remain. Their interpreter uses the
same checkout-owned stdlib environment owner as the other host source suites.

The catalog routes guide edits to SourcePolicy and ParserDocsBudgets, bootstrap
edits to SourcePolicy and Install, and bridge edits to all three boundaries.
Unknown Python, installer and Git runtime identity disables reuse for these
small suites. This is verification ownership, not a new runtime coordinator.
Always-on instruction delta: zero. No new installed-project barrier.

Windows PowerShell5.1 focused proof: initial split17/0 in4.46s, including actual
NoInit installation890ms and protocol1.91s; final source-policy2/0 in723ms and
selection13/0 in1.21s after exact literal/case preservation and conservative
reuse classification. A single RegisterChange owns Targeted for this unit.
These fixtures do not qualify a live RDC service or publication.

The 64 additional individual entries in nested-boundary-review.csv cover
endpoint identity12, legacy Linux watchdog10, native watchdog5, native refresh8,
CodeChecker retry16, ChatGPT Python9 and the original Pester wrappers4.
Each entry binds the frozen source SHA, original definition, concrete risk,
proof, resources and limitations. Similar watchdog cases remain because their
production owners differ. Actual POSIX locks remain platform-specific; fake
Docker/SSH/vendor adapters are not live service acceptance. Unchanged suites
were not rerun just for the audit. Only the three proven plugin-policy
duplicates are merged. Reviewed original definitions:407/2814;2407 pending.
This does not close the requested complete necessity audit.
