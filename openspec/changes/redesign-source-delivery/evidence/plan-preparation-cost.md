# Plan preparation cost

The reported 15,718 ms belonged only to `New-DeliveryQualityPlanForCandidate`.
The complete previous invocation took about 161 seconds. Read-only repeats on
2026-10-24 took 119.637 s and 239.795 s; the latter calculated its DAG in 20.717 s.
Git Trace2 places completed candidate reconstruction at 19:56:29 UTC (9 s after
entry). Sequential owned-asset verification then downloaded and discarded the
31,119,331-byte Vanessa ZIP, paired CFE, on-demand executable and client assets.
The first transfer alone occupied 130 s. This is variable network preparation,
not another E2E or 1C execution. The old internal clock excluded it.

The query now compares the current GitHub upload digest with the locked SHA-256
and verifies the exact download URL with HEAD. GitHub documents the digest as
computed on upload and immutable:
https://github.blog/changelog/2025-06-03-releases-now-expose-digests-for-release-assets/
An unavailable/malformed digest, API response or HEAD keeps the existing byte
verification fallback; a mismatched SHA fails without fallback. No persistent
remote observation cache or TTL is introduced. Source upload SHA/provenance,
current static, scenario reuse, dirty guards and publication finalization remain.

The candidate query runs within the existing stateless child-scope boundary;
published selection/preflight keep required capabilities. Historical supervisors
receive a marked non-resumable advisory preview. Immutable saved plans are not
replaced; publication stays with its published supervisor. The CLI reports the
complete invocation including supervisor preparation and final cleanup.

Regression coverage includes exact digests and Unicode URLs, missing/malformed
metadata, duplicate/wrong assets and tags, draft/not-uploaded releases, unavailable
download routes, mismatch rejection, byte fallback including 404 and bad SHA,
clean/dirty/mutating/historical candidate queries, scope isolation, and native
legacy calculator/inspection preview with immutable proof and authority retained.

A live read-only query of the locked Vanessa URL through the new helper returned
`matched`, `github-sha256-digest` and the exact locked SHA in 2,014 ms, including
HEAD. Windows PowerShell 5.1 returned the same digest in 2,047 ms. This is an
observation of this transfer, not a general network SLA or a
controlled publication benchmark. Full Plan/registration results are retained
under ignored `build/plan-overhead-*` in the implementation worktree.

Focused Windows PowerShell 5.1 validation: 97 passed, 0 failed, 0 skipped across
SourceDeliveryComponentPublication, SourceDeliveryIncremental and SourceDeliveryPlan.
Registration owns the subsequent Targeted run; no publication or native 1C gate
was started for this change.

The first registration caught the existing byte-fallback fixture loading only
`Get-DeliveryRemoteAssetState`. Its initializer now loads the real digest helper
too. The original `example.invalid` URL, eight requests, exact polling delays,
and one-attempt rejection of a bad SHA are unchanged. ImmutableDownloadRetry
focused validation passed 14/14. The failed draft did not update accepted refs.
