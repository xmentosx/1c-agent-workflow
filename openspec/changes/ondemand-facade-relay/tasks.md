# Tasks

## 1. Relay executable

- [ ] 1.1 Add `tools/itl-ondemand-mcp/cmd/itl-ondemand-relay` (version constant, `--project-root`, `--server`) that reads the launch descriptor, verifies the facade SHA-256 and starts it through `internal/childprocess`; verify with a Go test that a project path with whitespace and Cyrillic reaches the child arguments exactly
- [ ] 1.2 Implement line-level forwarding with in-flight tracking, `initialize` capture and `listChanged` in the forwarded `initialize` result; verify with Go tests that requests, responses, progress notifications and cancellations pass byte-identical
- [ ] 1.3 Implement descriptor-change replacement between requests (stdin close, bounded wait, start, `initialize` replay, `tools/list_changed`, note on the first result); verify with Go tests for the idle swap and for a swap deferred by an in-flight request
- [ ] 1.4 Implement keep-current on an absent or mismatched facade and `ITL_ONDEMAND_RELAY_FACADE_UNAVAILABLE` without a current facade; verify with Go tests for both cases
- [ ] 1.5 Implement unexpected-exit handling (`callOutcome: unknown`, restart on next request, 3 per 5 minutes, `ITL_ONDEMAND_RELAY_RESTART_LIMIT`); verify with Go tests for a single crash and a crash loop
- [ ] 1.6 Write relay evidence JSONL per design D7; verify a Go test reads the expected records and that no payload text is stored

## 2. Facade continuation

- [ ] 2.1 Switch the `ITL_ONDEMAND_FACADE_SUPERSEDED` continuation on `ITL_ONDEMAND_RELAY=1`; verify with a facade Go test for both environments; bump the facade version and repin

## 3. Workflow integration

- [ ] 3.1 Build the relay in `scripts/Build-ItlOnDemandMcp.ps1` and add the `itlOndemandRelay` entry to `templates/dependency-lock.json`; verify with the dependency-lock Pester tests
- [ ] 3.2 Acquire the relay in `agent-1c.ondemand-mcp.ps1` through the immutable acquire path, failing the step on error; verify with a Pester test that a failed acquire leaves client entries unchanged
- [ ] 3.3 Write one launch descriptor per on-demand server (both families, auxiliary contours) and point `Get-ItlOnDemandMcpEndpointDescriptors` at the relay; verify with Pester that every client adapter receives relay entries and descriptors carry the resolved facade, including a hotfix catalog and an `ITL_ONDEMAND_MCP_EXE` override
- [ ] 3.4 Verify with Pester that a later facade-only change rewrites descriptors but not client entries and reports no MCP client change, and that a user-modified entry is preserved
- [ ] 3.5 Register new paths in `tests/quality-contracts.json` under the owning contracts; verify the quality-contract checks pass

## 4. Documentation and delivery

- [ ] 4.1 Document the relay, descriptor, notes and error codes in `tools/itl-ondemand-mcp/README.md` and the one-time restart in the update guidance; verify the documentation budget checks pass
- [ ] 4.2 Commit and run `scripts/source-delivery.ps1 -Action RegisterChange`; verify the registration reports `registered`
- [ ] 4.3 After the user requests publication: release the relay and facade, then perform the live acceptance in an installed project (open chat, `update-workflow` to a new facade, next `itl-vanessa-ui` call served by the new version without reconnect, replacement note present); until then report it as unverified
