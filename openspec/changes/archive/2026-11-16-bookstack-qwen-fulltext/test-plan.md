# Acceptance plan

Run the owned Python BookStack suite and host settings Pester tests during implementation. RegisterChange owns the single final Targeted run. Do not invoke broad gates.

Freeze a corpus-derived sample in `acceptance-queries.json` before measuring Qwen: 12–15 queries, expected page IDs and evidence excerpts/offsets, with ordinary, paraphrased, middle/tail and absent-topic cases. Compare the same cached source snapshot under E5 and Qwen; assess semantic-only and public hybrid top-five results separately. Do not hide a failed semantic case behind FTS. Calibrate cosine cutoff against positive and absent-topic scores; report limits of this small sample.

Coverage proof must inspect every page/fragment: all non-whitespace text is covered with no gap, exact tokenizer input count stays within the configured bound, ready pages equal the full source inventory (empty pages accounted for), no stale profile/revision mapping is searchable. Record page/fragment/token counts, maximum input, elapsed time, cache size and actual provider usage/cost when supplied.

Regressions cover Markdown and HTML headings, oversized paragraphs, Unicode paths/text, title-only changes, empty pages, deletion after complete inventory, preservation after limited/failed inventory, provider malformed/empty/nonfinite/wrong-size responses, interrupted page construction and process restart, unchanged vector reuse, profile changes, semantic page deduplication, exact/FTS ranking and pagination. A legacy fixture is backed up and opened with the old code to prove recovery.

The live acceptance records before/after container identities and config fingerprints excluding secrets, source commit/image/cache profile identity, initialize -> initialized -> tools/list, index_status and real queries through the existing Product endpoint. E5 stays available during candidate work. Runtime corpus, credentials, snapshots and raw responses remain ignored; only bounded non-secret results belong in the source report.
