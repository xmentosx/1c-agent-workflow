## ADDED Requirements

### Requirement: Bounded extraction of visible supported files
Mantis MCP SHALL extract text from visible PDF text layers, DOCX and XLSX files within published limits for input size, parser time/memory, pages/paragraphs/cells and output text. It MUST NOT execute macros, follow external links or OCR a scan in this change.

#### Scenario: Supported attachment
- **WHEN** a visible issue contains a supported file within limits
- **THEN** the service records bounded text segments with the file ID and page, paragraph or sheet/cell coordinate

#### Scenario: Unsupported or oversized attachment
- **WHEN** a file has no supported text layer, uses an unsupported format or exceeds a limit
- **THEN** the service records a bounded, explicit outcome and does not claim full searchable coverage

#### Scenario: Attachment metadata without backing bytes
- **WHEN** Mantis returns a visible file's metadata but omits its bytes
- **THEN** the service reports `source_unavailable`, does not claim searchable coverage, and retries later if the backing file is restored

### Requirement: Source-specific search results
The existing `search_tickets` tool SHALL support an attachment-content-only mode and include content matches in `all` mode. Each content match MUST name the file and coordinate, retain issue-card grouping and obey the established page and output limits. Filename-only mode MUST remain separate.

#### Scenario: Unique phrase inside a file
- **WHEN** a phrase occurs only inside a visible supported attachment
- **THEN** lexical search returns its issue card with the file ID, filename, coordinate, bounded snippet and source link

#### Scenario: Broad search
- **WHEN** the client supplies no narrow filters
- **THEN** only the requested page of at most 20 cards and 12000 characters is returned, with a continuation cursor when more results exist

### Requirement: Revocation and current visibility
Extracted text, FTS rows and vectors SHALL follow the parent issue, comment and file visibility contract. Confirmed loss of access or deletion MUST remove the derived searchable content. Transient Mantis unavailability MUST retain the last verified cache under the agreed no-TTL policy and label its freshness.

#### Scenario: Private comment file becomes inaccessible
- **WHEN** a refreshed issue no longer exposes the comment or attachment to the service account
- **THEN** content matches for that file disappear before the issue refresh is committed

### Requirement: Incremental and recoverable work
The service SHALL track extraction status per file, avoid repeating unchanged successful extraction, bound work per synchronization cycle and resume unfinished work after restart without dropping the write journal. Semantic embeddings SHALL use the existing Mantis budget and queue; lexical search SHALL remain usable when OpenRouter is unavailable or the budget is reached.

#### Scenario: Same file observed again
- **WHEN** an issue refresh repeats the same file descriptor and successful extraction exists
- **THEN** the service retains its segments and does not download or re-embed the file solely because another issue field changed

#### Scenario: Interrupted extraction
- **WHEN** the process ends before derived fragments are committed
- **THEN** the next run retries or rehydrates that file without publishing incomplete text as ready

### Requirement: Observable rollout and rollback
The service SHALL expose bounded pending/ready/unsupported/failed extraction counts and the current extractor state. A release MUST start with extraction disabled, preserve existing volumes and the write journal, and support disabling the extractor without removing existing search capability.

#### Scenario: Parser incident during live import
- **WHEN** extraction is disabled after a parser incident
- **THEN** issue synchronization, ordinary lexical search and approved writes continue while extraction stops accepting new work
