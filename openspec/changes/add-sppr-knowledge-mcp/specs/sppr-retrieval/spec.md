## ADDED Requirements

### Requirement: Hybrid search with exact identifiers and filters
The MCP SHALL support semantic and lexical search plus exact typed object identifiers and Mantis references. Structured filters SHALL cover applicable project, object type, work status, developer, tester, type and sprint values. Filters and eligibility MUST apply to every returned candidate; exact matches SHALL be identifiable in the response.

#### Scenario: Investigation begins with a Mantis number
- **WHEN** a user searches an existing Mantis identifier with a work-status filter
- **THEN** matching eligible cards are returned with matching source fields and current filtered values, independently of semantic similarity

#### Scenario: Semantic candidate does not satisfy filters
- **WHEN** a textually similar card has a different developer or excluded type
- **THEN** the filtered result does not include it

### Requirement: Complete object reading with field provenance
The MCP SHALL provide bounded reading of all available indexed business fields and descriptions for a typed object, with pagination or section continuation when necessary. Each excerpt SHALL identify its card or relation-row source, field and observation generation. Truncation MUST be explicit and continuable.

#### Scenario: Long card exceeds one response
- **WHEN** an object's descriptions exceed the response budget
- **THEN** the response provides a continuation that can retrieve the remaining indexed text without presenting the first page as complete

#### Scenario: Implementation text is found on a relation
- **WHEN** search matches realization text on a technical-project–idea row
- **THEN** the excerpt identifies both endpoints and the row source, and object/relation reading retrieves its complete available text

### Requirement: Actual relationships and bounded exhaustive traversal
The MCP SHALL expose actual typed directed relations with pagination and explicit traversal limits. A completed traversal SHALL mean all indexed relations in the requested scope were enumerated. Semantic suggestions MUST be separately labeled «возможно связано» and MUST NOT be presented as stored relations.

#### Scenario: Collect all ideas in a technical project
- **WHEN** a user follows every relation page for a technical project
- **THEN** all its indexed idea rows are returned with their implementation texts and the final page explicitly reports completion

#### Scenario: Cycle, depth limit or top-k search
- **WHEN** traversal reaches a cycle/depth limit or the user receives only top-k similar cards
- **THEN** the response identifies its boundary and does not claim a complete investigation across all SPPR relationships

### Requirement: Query embeddings and bounded process cache
The MCP SHALL generate query vectors through OpenRouter using a profile compatible with the corpus and cache them in a bounded in-memory LRU until process restart. Cache identity MUST include query text and compatible profile. Search-result pages MUST NOT be cached by this mechanism.

#### Scenario: Repeated query after index refresh
- **WHEN** an identical query is repeated with the same profile after a new generation becomes active
- **THEN** its query vector is reused but results reflect the new generation and current allowlist

#### Scenario: Eviction, restart or profile change
- **WHEN** a vector is evicted, the process restarts or its profile becomes incompatible
- **THEN** the query is a cache miss and a compatible vector is recomputed when the provider is available

### Requirement: Useful degraded search
The MCP SHALL remain usable with the last valid corpus when OData is unavailable. When OpenRouter is unavailable, it SHALL use compatible cached query vectors where present and otherwise offer exact/lexical search. Responses MUST expose freshness, search mode and incomplete vector/extraction coverage.

#### Scenario: Provider outage with cached and uncached queries
- **WHEN** OpenRouter fails and one query has a compatible cached vector while another does not
- **THEN** the first can use indexed compatible vectors and the second returns lexical/exact results, each with an accurate mode and degradation explanation

#### Scenario: Source outage leaves old data available
- **WHEN** the latest synchronization failed due to OData unavailability
- **THEN** searches continue against the previous generation and show its observation time and last synchronization failure

### Requirement: Explicit ChTZ and developer task context
For an idea, the relation tool SHALL provide a bounded development view deriving roles from technical-project membership, type `СрезТП` and explicit `итлРодитель_Key` chains. If only a resolved ChTZ is present, it SHALL perform both roles; separate developer tasks SHALL be paired with their ChTZ using stored parent evidence. The view MUST distinguish rule-derived interpretation from stored edges, retain multiple contexts and report unknown roles, missing/out-of-scope parents and cycles without guessing by names or folder parents. Current policy SHALL apply to every endpoint and continuation.

#### Scenario: The same technical project performs both roles
- **WHEN** an idea has a ChTZ membership and no separate or unresolved task membership in the current corpus
- **THEN** one context identifies the same technical project as both ChTZ and developer task, with source evidence and the explicit fallback rule

#### Scenario: Idea is moved into a separate developer task
- **WHEN** an idea belongs to a developer task whose explicit parent chain reaches a ChTZ
- **THEN** the context returns both technical projects and parent evidence even if the idea no longer appears in the ChTZ table

#### Scenario: Role is unknown or project access is revoked
- **WHEN** type evidence or a required parent is unavailable, or current policy excludes a previously indexed task
- **THEN** the view does not disclose excluded content, does not infer a role from the title and invalidates continuations issued under the old policy

### Requirement: Native and web navigation
The MCP SHALL return installed-client and web-client navigation links for every supported eligible object in search hits, card responses and relation lists. Both links MUST address the same typed object in `pskov/itland_work_SPPR`, remain stable across renames and contain no credentials. Platform-compatible encoding MUST be established from actual 1C reference behavior.

#### Scenario: Open an idea from search and its relation list
- **WHEN** a user opens either link for the same idea in both views
- **THEN** the installed client and web client open that idea in the intended infobase

#### Scenario: Card rename and unsupported out-of-scope reference
- **WHEN** an eligible card is renamed or a relation stub has an unsupported metadata type
- **THEN** rename does not change the eligible card's destination and the unsupported stub explicitly explains why its link cannot be generated

### Requirement: Consistent bounded responses and continuation
The MCP SHALL bound page size, text and traversal work while providing an explicit continuation or stop reason. A request MUST read one consistent generation. Continuation MUST bind to generation, query parameters and policy; an invalid cursor MUST yield a recoverable restart instruction rather than mixed or unauthorized results.

#### Scenario: Generation changes between pages
- **WHEN** a user resumes a cursor after the active generation changes
- **THEN** the system either serves its still-retained consistent generation under current policy or instructs the user to restart, without silently mixing generations

#### Scenario: Allowlist changes before continuation
- **WHEN** a cursor was issued under a now-revoked project policy
- **THEN** continuation is invalidated and no newly excluded content is returned

### Requirement: Read-only MCP interface and common visibility
The MCP SHALL expose search, object reading, relation listing, index status, bounded context collection, exact enumeration and shortest stored paths to admitted clients with the same corpus visibility. It MUST NOT expose source mutation, arbitrary SQL/OData execution or automatic full-rescan commands through those tools. Payloads SHALL avoid duplicating complete structured JSON in text.

#### Scenario: Two admitted clients request the same object
- **WHEN** two clients use identical parameters against the same generation and policy
- **THEN** the same eligible business content is available without impersonating their individual SPPR users

#### Scenario: Client attempts to supply an arbitrary OData expression
- **WHEN** a tool receives an unsupported raw query or write parameter
- **THEN** it rejects that input with supported parameter guidance and performs no source mutation or unbounded fetch

### Requirement: Bounded context and connection evidence
`get_sppr_context` SHALL traverse incoming/outgoing stored relationships from one or more indexed seeds in one generation, deduplicate nodes and retain distinct relationship rows. It SHALL return compact cards with navigation, predecessor evidence, optional selected card/row fields, and explicit boundary/frontier records. Depth, admitted object count and adjacency work SHALL be bounded separately from page size. Development-role interpretation SHALL reuse the existing authoritative rule over allowed indexed evidence, not assume missing memberships from a truncated walk.

#### Scenario: Idea investigation reaches cycles and excluded objects
- **WHEN** an idea connects through technical projects to cyclic shared solutions and an excluded project
- **THEN** allowed objects appear once, each reached card has connection evidence, realization rows remain separately readable, and excluded contents never appear

#### Scenario: Traversal stops before a separate developer task
- **WHEN** a depth/object/work limit stops traversal
- **THEN** stop reasons and continuation are explicit and the idea is not falsely classified as using its ChTZ as the developer task

### Requirement: Complete enumeration and selective batch reading
`list_sppr_objects` SHALL enumerate all indexed objects matching the same exact filters as search with a stable order, total and generation-bound continuation. `read_sppr_object` SHALL preserve its single-object response while accepting up to twenty object IDs for bounded batch reading with optional field selection. Long field values and metadata SHALL remain reconstructable through continuation.

#### Scenario: More matching cards than a search page
- **WHEN** forty-five ideas match an exact status filter
- **THEN** enumeration returns all forty-five across pages without a query embedding call

### Requirement: Scoped search and shortest paths
Search SHALL optionally restrict fragments by selected indexed cards and field names, including incoming realization rows while retaining source-card/edge provenance. `find_sppr_paths` SHALL explain bounded shortest stored paths between eligible endpoints, honor direction and relationship filters, and distinguish complete absence from a truncated search. Semantic similarity MUST NOT create graph edges.

#### Scenario: Search implementation attached to an idea through a TP row
- **WHEN** only the idea and realization field are selected
- **THEN** the idea is found from the incoming realization and the excerpt identifies the source TP and exact row

#### Scenario: Multiple shortest routes or interrupted exploration
- **WHEN** several shortest stored routes exist or exploration reaches a limit
- **THEN** returned routes retain edge IDs and the response reports omitted routes or exploration limits without claiming unrestricted completeness
