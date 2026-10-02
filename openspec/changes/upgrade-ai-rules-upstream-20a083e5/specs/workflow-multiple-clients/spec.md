## ADDED Requirements

### Requirement: CL1 Installed set and invocation client are independent
ITL SHALL support multiple installed clients with one agreed rule version and
shared lifecycle ownership. Every client-sensitive invocation SHALL identify its
client from explicit input or a verified host context; ambiguity cannot choose an
arbitrary member. Single-client projects retain their selection on migration.
An identified but uninstalled client MUST NOT be attached by session selection,
sync or routine execution. Client-dependent work offers the owned attach action;
client-independent operations remain available without changing membership.

#### Scenario: Codex and Claude are both installed
- **WHEN** Claude invokes a routine
- **THEN** Claude syntax/config is used while Codex remains installed; no project-wide switch removes Codex

#### Scenario: Legacy codex and kilocode set
- **WHEN** migration encounters the formerly special legacy pair
- **THEN** it preserves and reconciles the set rather than automatically discarding Codex

#### Scenario: Codex opens a Claude-only project
- **WHEN** Codex is the verified calling host but only Claude is installed
- **THEN** Codex-specific work reports the attach continuation without adding Codex or removing Claude; a common read-only status can still run

### Requirement: CL2 Twelve named clients with explicit capabilities
Supported client scope SHALL include codex, kilocode, claude-code, cursor,
opencode, kimi, qwen, command-code, cline, pi, zcode and mimocode. Compatibility
SHALL identify runtime variant/version and verified discovery, MCP, role tools,
model selection, OpenSpec and command mechanisms. other is not a supported ITL
client. Missing native features use explicit supported fallbacks, never fake parity.

#### Scenario: Kimi cannot apply a reviewer model
- **WHEN** its runtime cannot enforce the requested model override
- **THEN** parent review supplies the required review and no separately selected model is claimed

#### Scenario: Pi or OpenCode is migrated
- **WHEN** the corresponding client surface is rebuilt
- **THEN** the pinned Pi MCP extension or ITL OpenCode workspace integration remains functional and owned

#### Scenario: Cline runtime variant differs
- **WHEN** a CLI or editor variant exposes different MCP configuration discovery
- **THEN** diagnostics name that variant and actual support; ITL does not silently write a global config or declare a project file operational without discovery evidence

### Requirement: CL3 Shared files survive client membership changes
Installation SHALL track all owners of shared files/config entries. Add, remove
and update SHALL render the final complete client set, including all cross-file
references, before transactional replacement. Removing a client MUST preserve
other owners, foreign configuration and project-owned dotenv values.

#### Scenario: Remove the canonical client
- **WHEN** Cursor is removed from Cursor plus Codex
- **THEN** remaining root and nested references resolve to retained files and Codex remains operational

#### Scenario: Shared MCP or skills path
- **WHEN** Claude/Command Code share .mcp.json or Claude/OpenCode share skills
- **THEN** removing one client retains the other's managed contributions and unrelated user content

### Requirement: CL4 Native discovery and restrictions are behaviorally qualified
Rendering SHALL preserve host-specific tool names/permissions, required MCP and
shell access, read-only constraints and actual model selection. Native agent
claims require host discovery. Codex user-global prompts MUST NOT be overwritten;
existing legacy prompts and modified legacy rules are reported and preserved.

#### Scenario: Adapter file exists but the host cannot discover it
- **WHEN** a fresh context cannot invoke the generated command or role
- **THEN** the capability is unqualified and the installer cannot report full client readiness

### Requirement: CL5 OpenCode layers preserve physical ownership and user bytes
ITL SHALL support opencode.json, opencode.jsonc, .opencode/opencode.json and
.opencode/opencode.jsonc without moving, deleting or consolidating existing
project configs. Effective reads SHALL use the qualified native merge order and
retain physical provenance separately from write authority. Legacy names-only
MCP ownership SHALL grant ownership only in root opencode.json. JSONC edits
SHALL preserve comments, BOM, newlines and bytes outside authorized edit spans.
Configuration, Product Docs and doctor SHALL use the same effective reader;
configuration alone MUST NOT establish an attached or working MCP connection.
The existing final-set owner SHALL bind all four path presence/hash inputs before
the first write. The existing snapshot/recovery owner SHALL preserve all four
original states, including absence, while commit selection MUST NOT acquire
ownership of user config files. A newer recovery executor SHALL preserve the
recorded target's config scope. Global configuration remains outside this scope.

#### Scenario: Existing nested JSONC is the only project config
- **WHEN** an explicit ITL reconciliation configures managed MCP
- **THEN** it edits that file without creating root JSON and preserves foreign MCP, comments, BOM and CRLF

#### Scenario: Foreign contribution overrides a legacy root-owned key
- **WHEN** reconciliation requests that key in a different project layer
- **THEN** it preserves configs and ownership, reports the existing collision continuation and completes the same operation after explicit supported resolution

#### Scenario: A previously absent config appears after planning
- **WHEN** the final-set writer observes changed presence or bytes in any of the four paths
- **THEN** it preserves the edits and refuses before writing; a new plan completes the original reconciliation

#### Scenario: Last managed owner is detached
- **WHEN** another layer contains a foreign contribution with the same name
- **THEN** detach removes only proved physical contributions, preserves foreign/shared entries and reports the actual effective remaining configuration

#### Scenario: Recovery uses a newer executor for an older recorded target
- **WHEN** the recorded target supports only root JSON
- **THEN** the executor does not widen its writes to other layers and the existing snapshot remains sufficient for the original operation

#### Scenario: Native loading is claimed
- **WHEN** the release qualifies OpenCode project-layer behavior
- **THEN** it records the actual runtime version and effective observation separately from source-fixture proof
