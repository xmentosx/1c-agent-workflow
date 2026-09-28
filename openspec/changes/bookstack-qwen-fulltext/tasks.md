## 1. Retrieval and storage

- [x] 1.1 Implement isolated BookStack provider settings, Qwen instruction/tokenizer contract and response validation.
- [x] 1.2 Implement full section-aware token-bounded fragments and compact deduplicated hybrid retrieval.
- [x] 1.3 Implement additive SQLite migration, backup, vector reuse, complete-page publication, deletion reconciliation and persistent incomplete status.

## 2. Verification and candidate

- [x] 2.1 Add owner regressions for long/HTML pages, profile/title changes, errors/interruption/resume, empty/deleted pages, pagination and scoped settings.
- [x] 2.2 Freeze 12–15 real queries with expected pages/sections and record the E5 baseline before Qwen evaluation.
- [x] 2.3 Prepare a candidate cache while E5 serves; measure full coverage, Qwen relevance/thresholds, latency, usage and recovery on copies.

## 3. Delivery and live acceptance

- [x] 3.1 Document configuration, status/continuation and exact host migration/recovery procedure; complete focused verification.
- [x] 3.2 Prepare and verify the host-owned cache-preserving BookStack replacement and recovery procedure for the qualified cache.

Mandatory post-registration delivery: install only the exact registered BookStack
change using the host owner and qualified cache; verify the original MCP endpoint,
fixed real queries and unchanged unrelated containers/configuration. Record its actual
completion in the ignored runtime installation receipt, separately from publication.
This source checklist is frozen before registration and does not itself claim that
post-registration delivery has run.

Registration of the coherent source commit is checked through source-delivery Status, not by editing this file after registration. Source publication requires its own authority; no push, PR or broad source gate is part of ordinary registration.
