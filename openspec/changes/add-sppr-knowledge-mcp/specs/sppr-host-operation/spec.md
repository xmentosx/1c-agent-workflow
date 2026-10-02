## ADDED Requirements

### Requirement: Isolated operation on the existing host
The SPPR component SHALL run on `dev-ermakov` through the existing MCP host registration/proxy conventions with its own configuration, state and schedule. Installation, recovery and removal MUST NOT change other servers' corpus, embedding profiles or indexing schedules.

#### Scenario: Install or recover the SPPR component
- **WHEN** an authorized operator installs or restarts it
- **THEN** Code/Graph, BookStack and Mantis retain their settings and data and no unrelated index rebuild is triggered

### Requirement: Standard 1C authentication and secret handling
The collector SHALL use standard 1C username/password authentication for the configured OData publication. Credentials MUST reside outside Git and corpus files, remain unavailable in navigation links and ordinary logs, and be used only by processes that need them. Unicode credentials and Windows paths MUST survive transport unchanged.

#### Scenario: Authentication fails
- **WHEN** OData rejects configured credentials
- **THEN** collection stops with a redacted actionable status, leaves the valid index available and does not log the password or Authorization header

#### Scenario: Cyrillic username and data directory with spaces
- **WHEN** the configured user and runtime path contain Cyrillic characters and spaces
- **THEN** the collector receives the exact configured values without mojibake or altered command arguments

### Requirement: Collection requires an open Windows session
The collector SHALL run only while its configured user's Windows session is open, including a disconnected but preserved session. It MUST NOT operate as a signed-out background service. The read-only MCP MAY continue serving the last valid index without that session.

#### Scenario: User disconnects and later signs out
- **WHEN** an RDP session is disconnected but remains open, then the user signs out
- **THEN** collection is allowed during the preserved session and stops on sign-out, without activating an incomplete generation

#### Scenario: Nightly trigger occurs without an open session
- **WHEN** the schedule fires while the user has no open session
- **THEN** no collection starts and clients can still see the last generation with its actual age

### Requirement: Nightly full enumeration and evidence-based incremental mode
The collector SHALL restrict scheduled full source enumeration to a configured night window and time zone. Startup and missed triggers MUST NOT cause automatic daytime full scans. A mode promising at most 15-minute freshness MUST rely on a demonstrated complete change-selection mechanism without full enumeration.

#### Scenario: Only DataVersion is available
- **WHEN** the source exposes versions but no proven change selection
- **THEN** the configured mode remains nightly reconciliation, with reuse of unchanged content vectors, and is not advertised as 15-minute incremental synchronization

#### Scenario: Window ends or daytime restart occurs
- **WHEN** the night window ends during collection or a component restarts during the day
- **THEN** full-enumeration source requests stop or remain unscheduled and the previous generation stays available until an allowed successful collection

#### Scenario: Reliable delta selection has been proven
- **WHEN** a source mechanism covers creation, relevant changes, deletion and project movement without full scans
- **THEN** incremental scheduling can maintain at most 15-minute update latency while dependencies are available and reports missed updates when they are not

### Requirement: Single publisher and atomic generations
The component SHALL have one collection/publishing owner and immutable readable generations. It MUST publish a complete validated source generation atomically and preserve a usable predecessor on failure. Readers MUST NOT observe partial publication or concurrent Windows/Linux database writes.

#### Scenario: Two collection triggers overlap
- **WHEN** a second trigger arrives while collection is active
- **THEN** it reports the existing run rather than starting a concurrent writer or publishing a conflicting generation

#### Scenario: Crash or disk failure during publication
- **WHEN** a collector stops before a validated generation and active pointer are fully published
- **THEN** restart selects a valid completed generation and the partial file is never treated as the active corpus

### Requirement: Operational status and coverage
The MCP SHALL expose active generation, allowed scope, observation interval, last successful collection, last attempt outcome, synchronization mode, vector/extraction coverage and applicable next update timing. Status MUST distinguish configured endpoint, protocol readiness and verified functional availability, without exposing secrets or excluded content.

#### Scenario: Endpoint responds but tools are not initialized
- **WHEN** a deployment has only TCP/HTTP reachability
- **THEN** it is not reported as a verified working MCP until initialize, initialized notification, tools/list and functional calls succeed

#### Scenario: Index contains unextracted fields or missing vectors
- **WHEN** some source fields could not be decoded or embedding requests failed
- **THEN** status and affected responses expose those gaps instead of claiming full coverage

### Requirement: Scoped deployment and recovery evidence
The component SHALL provide documented installation, maintenance and rollback steps owned by the existing host tooling. Source validation/registration MUST be distinguished from host installation and live acceptance. Recovery MUST preserve the active project policy and MUST NOT write to SPPR.

#### Scenario: Roll back after an allowlist removal
- **WHEN** an operator restores an older completed generation
- **THEN** current exclusions remain effective and rollback does not restore access to revoked project data

#### Scenario: Only source checks have passed
- **WHEN** implementation has local test evidence and source registration but no live host acceptance
- **THEN** its status remains locally verified and does not claim deployed or end-to-end accepted behavior
