## ADDED Requirements

### Requirement: Isolated remote retrieval profile
BookStack SHALL support its own OpenRouter/Qwen profile without changing other MCP settings and SHALL distinguish query instructions from passage inputs and incompatible profile identities.

#### Scenario: BookStack override with shared CPU configuration
- **WHEN** BookStack selects Qwen and other services inherit the shared E5 settings
- **THEN** only BookStack resolves OpenRouter credentials and Qwen, queries include the Qwen instruction, and old-profile vectors are excluded

### Requirement: Complete section-aware fragments
Every nonempty page SHALL be represented by token-bounded fragments covering all normalized text, with a source page, section and offsets. Search SHALL deduplicate pages before limiting and retain exact/FTS results, links and cursor pagination.

#### Scenario: Relevant content beyond the former prefix
- **WHEN** relevant passages occur in the middle and end beyond character 6000, including one oversized section and HTML-only headings
- **THEN** each passage is indexed, its expected page is retrieved within the first five results on the fixed acceptance sample, and a bounded matching fragment identifies the section

### Requirement: Consistent and reusable indexing
The index SHALL publish only complete current page revisions, reuse unchanged inputs within the same profile, remove outdated mappings, and reconcile deletions only from a complete successful inventory.

#### Scenario: Interruption and resume
- **WHEN** a provider fails or the process stops after some fragment vectors are saved
- **THEN** the page remains incomplete, status and search disclose incomplete coverage, and reindex_docs resumes without paying for saved identical inputs again

#### Scenario: Content updates and deletions
- **WHEN** a title or content changes, an empty page appears, or a page disappears from a complete inventory
- **THEN** stale fragments are not returned, unchanged fragment inputs are reused, empty pages count as complete, and removed pages disappear from all search channels

#### Scenario: Limited or failed inventory
- **WHEN** a limited reindex or failed source listing omits cached pages
- **THEN** those pages are preserved and the run does not claim full-corpus readiness

### Requirement: Recoverable qualified transition
E5 SHALL remain available until a separate Qwen candidate passes full coverage and the fixed 12–15-query acceptance sample. The owner SHALL retain and verify a recoverable previous image/configuration/SQLite kit and expose provider usage separately from estimates.

#### Scenario: Candidate fails before cutover
- **WHEN** Qwen preparation or acceptance fails
- **THEN** E5 continues serving and candidate progress can be resumed without changing the live cache

#### Scenario: Successful switch and recovery proof
- **WHEN** the candidate is complete and qualified
- **THEN** only BookStack is switched, public MCP tools work through the existing endpoint, and the previous SQLite remains restorable with the previous code without automatic fallback
