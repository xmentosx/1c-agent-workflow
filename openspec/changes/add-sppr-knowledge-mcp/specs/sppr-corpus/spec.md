## ADDED Requirements

### Requirement: Explicit project boundary
The system MUST restrict business content to an explicit project UUID allowlist, initially «Кейс проект PM5» (`76bcfc1f-e8c2-4cd6-80ef-997b99bca476`). Eligibility MUST be established before fetching content, external embedding, persistence as searchable content, and serving results. Minimal ownership checks and typed reference stubs MUST NOT include foreign titles or descriptions.

#### Scenario: Reference points to another project
- **WHEN** an allowed PM5 card references a card owned by an excluded project
- **THEN** the system may retain its type and UUID as an out-of-scope reference but does not fetch, embed, index or return its business content

#### Scenario: Project is removed while a generation remains active
- **WHEN** an operator removes a project from the allowlist
- **THEN** subsequent responses and external submissions exclude that project and shared objects with no remaining allowed provenance, without waiting for a full scan

#### Scenario: Project is renamed or added
- **WHEN** an allowed project is renamed, or another UUID is explicitly added
- **THEN** rename preserves existing identity and the added project becomes searchable only after a successful authorized collection

### Requirement: Supported current-state objects
The system SHALL index current non-deleted technical projects, ideas, processes, process steps, project sections, meeting protocols, system functions and target tasks belonging to allowed projects, including closed/completed cards. It SHALL distinguish folders from cards and preserve their hierarchy. Mechanism functions and historical versions MUST be excluded.

#### Scenario: Completed idea and its process step
- **WHEN** a completed idea belongs to PM5 and a step belongs to a process owned by PM5
- **THEN** both objects are eligible, their current states are retained and completion does not remove them

#### Scenario: Similar names denote different metadata types
- **WHEN** a system function and a mechanism function have similar names
- **THEN** only the system function is eligible and the distinction is based on metadata type rather than title matching

### Requirement: Shared content and provenance
The system SHALL include descriptions of projectless LCM solutions, problematics and functional solutions only when reachable through permitted explicit relations from an eligible root. It MUST retain provenance, terminate cyclic traversal and exclude reverse expansion into foreign project cards. Required lookup labels SHALL be resolved selectively without indexing entire dictionaries.

#### Scenario: Shared solution has two allowed roots
- **WHEN** a shared solution is reachable from two allowed roots and one root is removed
- **THEN** the solution remains eligible through the surviving root and its recorded provenance is updated

#### Scenario: LCM cycle and foreign back-reference
- **WHEN** allowed traversal encounters a cycle and a back-reference to another project's card
- **THEN** the cycle terminates, the foreign card remains out of scope, and unrelated LCM entries are not enumerated

### Requirement: Explicit business-field extraction
The system SHALL use per-type business-field projections covering applicable status, notes, developer, tester, type, Mantis identifiers/links, sprints, descriptions, goals/concept and implementation fields. It MUST distinguish not-applicable, empty and unreadable fields. Credentials and service-secret fields MUST NOT be fetched for indexing or sent to the embedding provider.

#### Scenario: Object has no tester field
- **WHEN** the metadata type lacks a tester field
- **THEN** the returned card identifies the field as not applicable instead of inventing a value or reporting a read failure

#### Scenario: Metadata contains a repository password field
- **WHEN** a technical-project entity exposes a service password beside business fields
- **THEN** the indexer's projection excludes that field and its value cannot enter the corpus, provider requests, logs or MCP responses

### Requirement: Readable rich descriptions and extraction coverage
The system SHALL extract readable text and meaningful links from supported plain and formatted descriptions, including published Base64/XML/XDTO formats. Extraction MUST be bounded and MUST NOT load external XML entities, attachments or linked documents. Unsupported formats and extraction errors SHALL be visible as incomplete coverage.

#### Scenario: Formatted description contains paragraphs and links
- **WHEN** a supported FormattedDocument is decoded
- **THEN** paragraph text and source-field provenance are searchable and readable without internal markup identifiers polluting the text

#### Scenario: Unknown rich format or external content
- **WHEN** a field uses an unsupported format or links to Mantis, a file or 1C:DO
- **THEN** the system reports unsupported extraction or returns link metadata, and does not silently treat the description as empty or fetch the external body

### Requirement: Typed relations with row-specific content
The system SHALL preserve actual relation types, direction, endpoint identities, provenance and row-level text. Implementation and comments on a technical-project–idea row MUST remain associated with that row and project. Polymorphic reference types MUST be validated; unsupported targets MUST NOT expand the eligible type set automatically.

#### Scenario: One idea has different implementations in two projects
- **WHEN** two eligible technical projects reference one idea with different realization text
- **THEN** both relations and both texts remain independently searchable and readable with their respective technical-project sources

#### Scenario: Polymorphic idea row points to an unsupported type
- **WHEN** an idea/error table row contains a target type outside the supported type mapping
- **THEN** the system reports the unresolved target and coverage limitation without treating it as a supported idea or fetching its content

### Requirement: Idea provenance and additional attributes
The system SHALL collect the idea registrant, source, topic and typed basis, and additional attributes of ideas and technical projects. Property labels, values, value types and text values SHALL remain readable. Meaningful values and addressed lookup labels SHALL participate in lexical and semantic indexing. Typed business references SHALL use the existing corpus admission and stub rules; scalar values MUST NOT become links merely because their text resembles a UUID.

#### Scenario: Additional attribute contains a foreign reference and another contains zero
- **WHEN** an eligible idea or technical project has additional attributes with a reference outside the corpus, a zero, a false or a scalar string
- **THEN** their values and explicit types remain readable, the reference becomes a stub without foreign content, and zero/false are not treated as empty

#### Scenario: Idea basis is a supported typed reference
- **WHEN** an eligible idea contains an explicit basis type and nonempty reference
- **THEN** the graph preserves the actual basis relation and exposes the original type without guessing from the referenced UUID or expanding the allowed projects

### Requirement: Idea-step row identity
The system SHALL retain the technical identifier on idea-step rows and use it with the relation and endpoints for stable identity. Reciprocal rows SHALL be correlated only for the same endpoints and identifier. A technical identifier alone MUST NOT create a missing step reference. Duplicate identities SHALL preserve the previous generation and provide a source-correction continuation.

#### Scenario: Two requirements share the same idea and step
- **WHEN** two differently identified rows between one idea and step are reordered
- **THEN** both texts and identities remain distinct, and matching reciprocal rows can still be correlated

#### Scenario: Duplicate technical identity is corrected
- **WHEN** duplicate identities prevent collection and the operator corrects the source rows
- **THEN** the previous generation remains readable until a successful retry publishes both corrected relationships

### Requirement: Reliable reconciliation and removal
The system SHALL reconcile membership, deletion marks, versions and dependencies during complete scans and publish source-content changes only after successful collection. Missing pages, authorization errors and timeouts MUST NOT be interpreted as deletions. Successful reconciliation SHALL remove deleted, marked or moved-out card content and edges removed from the source, while retaining surviving recorded references to unavailable objects as stubs.

#### Scenario: Object disappears during a successful scan
- **WHEN** complete inventory and ownership checks confirm deletion or movement out of the allowed corpus
- **THEN** the next published generation excludes the object's content and outgoing edges, while surviving incoming references remain unavailable stubs

#### Scenario: Addressed optional dependency returns HTTP 404
- **WHEN** a shared LCM or lookup dependency returns HTTP 404 and a successful filtered entity-set query confirms the same UUID is absent
- **THEN** collection continues without its stale content/label and exposes the reference as not_found in the next successful generation

#### Scenario: HTTP 404 does not establish absence
- **WHEN** the confirmation fails or still returns the object, or HTTP 404 occurs on a required card, table, or page
- **THEN** collection fails without publishing partial deletions or treating authorization/transport/publication errors as absence

#### Scenario: Scan fails after reading some pages
- **WHEN** a later page fails or collection cannot establish a complete inventory
- **THEN** the previous valid generation remains active and the partial inventory does not remove previously indexed content

#### Scenario: Shared value or relation row changes
- **WHEN** a lookup/LCM description or a technical-project idea row changes
- **THEN** the successful collection refreshes the affected content even if another referencing card's version did not change

### Requirement: Whole-object version reuse
The system SHALL treat DataVersion as covering card fields and table rows, as confirmed by the source owner. It SHALL reuse saved raw fields and table rows only when the object version and corresponding projections match. Version changes SHALL refresh card content and rows; projection changes or legacy snapshots without table projection metadata SHALL refresh the affected tables. Version checks around collection and independent dependency refresh MUST remain effective.

#### Scenario: Nightly reconciliation finds an unchanged object
- **WHEN** its version and scalar/table projections match the saved snapshot
- **THEN** no business-field or table read is needed for that object, while membership/version checks and addressed dependency checks still execute

#### Scenario: Table edit or projection extension
- **WHEN** a table edit changes its object's DataVersion, or a table projection changes without a source edit
- **THEN** the affected rows are reread, graph/text content reflects the new projection, and only changed text fragments require new compatible vectors

### Requirement: Compatible content embeddings
The system SHALL use OpenRouter `qwen/qwen3-embedding-8b` for eligible text and reuse a vector only when text and embedding profile are compatible. The profile MUST include model/provider, dimension and relevant instructions/normalization versions. Vectors for changed text or incompatible profiles MUST NOT be represented as current semantic coverage.

#### Scenario: Unchanged text is collected again
- **WHEN** a later scan finds the same fragment and compatible embedding profile
- **THEN** its stored vector is reused without another embedding request for that fragment

#### Scenario: Provider fails for changed text
- **WHEN** source collection succeeds but the provider cannot embed a changed fragment
- **THEN** the current text may be published for lexical search with incomplete semantic coverage and the old vector is not attached to the changed text

#### Scenario: Profile changes
- **WHEN** model, dimension or embedding instructions change incompatibly
- **THEN** old and new vectors are not mixed and the need for rebuilding semantic coverage is reported
