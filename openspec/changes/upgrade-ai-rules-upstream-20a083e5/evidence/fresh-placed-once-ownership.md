# Fresh refresh: mutable project ownership

The unchanged fresh journey for candidate `7163ad940487038a0b188cd9d7affb13dda3b555` reached refresh-lite after successful configuration load, validation, saved Vanessa, stale-export refusal, recovery check and export. It failed at refresh hydration, not at the journey time limit. Full fresh acceptance remains incomplete.

## Observed boundary

- Source Full: 2519 passed, 0 failed, 0 skipped; candidate tree `648c729c3aae570be910ee55702c4ae82fe58abe`, clean checkout.
- Native Gate6: before `101`, modules `0`, after `101`. Assessment permitted application with 629 pre-existing findings, 0 new and 0 unresolved findings; `cleanPassed=false` remains visible.
- Saved Vanessa: both original application/server scenarios passed. The original stale-result refusal, recovery check and verified export passed.
- Refresh merged the recorded main target, re-executed the current helper, then failed with `AI_RULES_MANAGED_IGNORED_USER_MODIFIED` for `.dev.env`.
- Q23's completed main migration changed env SHA `c2eb8263c1405e7117e089b9b6cd04b6536d798f991f9efb99d26352f916399f` to `e1b9e8399bf9f7d82cc315885d445f318024fe78b9cf69ec7f5c079672e23baf`. The former equals the manifest's initial template hash. Branch activation subsequently changed only the existing branch-context fields; unrelated env content was preserved.
- `USER-RULES.md` also contains the legitimate ITL/user overlay and differs from its initial placed-once hash.

## Existing owner contract

`Sync-AiRules1cManagedIgnoredFilesFromMain` must consume the existing ownership classifiers before immutable hash comparison or restoration: `Test-AiRulesManifestPathOwnedByWorkflow` for local env, and `Test-AiRulesPlacedOnceProjectTemplate` for the three supported root templates. The latter checks exact source, a boolean template marker, an existing file and valid UTF-8. Arbitrary validator/runtime files do not acquire this exemption from a template marker.

This repairs the existing hydration owner. It introduces no state, coordinator, new migration, manifest rehash, or installed-copy patch. Existing guards for changed immutable files and missing/mismatched immutable sources remain required. The original fresh workload and assertions remain the acceptance path.

## Retained evidence and remaining acceptance

Task-local raw failure and every completed journey step are retained in `build/gate6-r41-source-delivery/develop-fresh-7163ad94-refresh-red`. Native raw results, legacy assessment and the first saved Vanessa report are retained in `develop-fresh-7163ad94-native`. Those ignored files are evidence, not a substitute for a passed full fresh qualification.

The owning regression must first reproduce the failure, then preserve the exact mutable bytes through hydration while restoring a genuine ignored runtime file and retaining negative immutable-file guards. After registration, publication must rerun the unchanged original fresh journey on the corrected candidate. Paired publication, separate covered small-CF load/apply and the frozen essential UI scenario remain pending.

## Focused causal regression

Before the production change, native PowerShell 5.1.26100.9549 / Pester 5.8.0 ran the two new cases: 1 passed, 1 failed, 0 skipped (6.328 seconds). The real Git fixture used paths with whitespace and Cyrillic, actual Q23 default/inherited receipt, two real branch-context writes, a two-parent merge and current-helper hydration. Its failure was the observed `.dev.env` ownership refusal. The forged-validator template case passed. All original test text and 38 focused input hashes stayed unchanged.

The production change reuses both existing owner classifiers before immutable hydration. Focused GREEN ran the two new cases and both existing ignored-hydration/restore cases: 4 passed, 0 failed, 0 skipped (12.442 seconds), same native runtime/Pester. Env, USER-RULES and manifest bytes were preserved; the actual ignored immutable runtime was restored. Edited arbitrary-template validators, unavailable/mismatched immutable sources and pinned-version guards retain their previous assertions. The green result and JUnit are retained under `build/fresh-env-template-recovery/native-green-20261004`; all 38 inputs remained unchanged during the test run.

The outer one-off test launcher incorrectly named its job-handle cleanup argument after Pester had completed and written these results. This launcher error is retained; it is not a product-test failure or publication qualification. Registration's normal owner launcher must still pass. The original full fresh journey, covered small-CF load/apply and frozen essential UI acceptance remain pending.