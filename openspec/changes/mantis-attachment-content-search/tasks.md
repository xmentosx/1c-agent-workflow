## 1. Bounded extraction

- [x] 1.1 Build isolated PDF/DOCX/XLSX parser with byte, expanded ZIP, time, memory, item and text limits; retain coordinates and explicit partial outcomes.
- [x] 1.2 Verify unique Unicode phrases, malformed files, scans, macros, oversized documents and an interrupted parser.

## 2. Mantis-owned state

- [x] 2.1 Add compatible per-file extraction status and transactional publication of attachment-content fragments/FTS rows.
- [x] 2.2 Reconcile unchanged descriptors, changed/removed/private files, process restart and old-image rollback without changing the write journal.
- [x] 2.3 Schedule bounded extraction after visible issue synchronization and report progress/errors through `index_control`.

## 3. Search and qualification

- [x] 3.1 Add content-only search mode, filename/coordinate matches, source links and existing cursor/output limits; share the Mantis embedding budget.
- [x] 3.2 Test search, revocation, no-repeat extraction, semantic outage and budget behavior locally.
- [x] 3.3 Commit and register the source change and acceptance fixes through `RegisterChange` with their owner tests.
- [x] 3.4 Deploy the exact image with extraction off, preserve mounts and other runtimes, then qualify marked PDF/DOCX/XLSX files in project 397.
- [x] 3.5 Measure live progress/disk, enable bounded corpus extraction, and record rollback plus current coverage in `test-plan.md`.
