# Tasks

Delivery is split by the publication contract: a candidate lock may pin a new
owned asset only after the published supervisor can finalize it
(`Get-DeliveryOwnedAssetContracts`). Stage A ships the relay, its finalizer
support and the pin-gated workflow integration; stage B pins the relay after
stage A is published.

## 1. Relay executable (stage A)

- [x] 1.1 Add `tools/itl-ondemand-mcp/cmd/itl-ondemand-relay` (version constant, `--project-root`, `--server`) that reads the launch descriptor, verifies the facade SHA-256 and starts it through `internal/childprocess`; verified by `TestRelayServesTheDescribedFacadeWithExactArguments` with a whitespace-and-Cyrillic project root
- [x] 1.2 Implement line-level forwarding with in-flight tracking, `initialize` capture and `listChanged` in the forwarded `initialize` result; verified by the same test (byte-identical Cyrillic progress notification, `listChanged`)
- [x] 1.3 Implement descriptor-change replacement between requests; verified by `TestRelayReplacesTheFacadeBetweenRequests` and `TestRelayDefersReplacementWhileARequestIsInFlight`
- [x] 1.4 Implement keep-current on an absent or mismatched facade and `ITL_ONDEMAND_RELAY_FACADE_UNAVAILABLE` without a current facade; verified by `TestRelayKeepsTheCurrentFacadeWhenTheNewOneIsMissing` and `TestRelayWithoutAFacadeRefusesWithTheContinuation`
- [x] 1.5 Implement unexpected-exit handling and the 3-in-5-minutes bound; verified by `TestRelayRestartsACrashedFacadeWithinTheBound`
- [x] 1.6 Write relay evidence JSONL per design D7; verified by `TestRelayEvidenceRecordsLifecycleWithoutPayloads`

## 2. Facade continuation (stage A)

- [x] 2.1 Switch the `ITL_ONDEMAND_FACADE_SUPERSEDED` continuation on `ITL_ONDEMAND_RELAY=1`; verified by `TestFacadeSupersededNoteNamesThePinnedVersion`; facade 0.4.37 repinned

## 3. Workflow and publication integration (stage A)

- [x] 3.1 Build the relay next to the facade in `scripts/Build-ItlOnDemandMcp.ps1` (reported as `relayPath`/`relaySha256`) and record the reviewed builder digest in `scripts/develop-journey-inputs.ps1`; verified by the OnDemandMcpLock and DeliveryGoInputScope Pester tests
- [x] 3.2 Acquire the relay through the immutable acquire path from `Install-ItlOnDemandMcp`, failing the step on error; verified by the OnDemandMcp Pester relay test (`ITL_ONDEMAND_RELAY_URL_MISSING`, entries unchanged)
- [x] 3.3 Write one launch descriptor per on-demand server and point the endpoints at the relay when `itlOndemandRelay` is pinned; verified by the OnDemandMcp Pester relay test (relay command, descriptor with the resolved facade override and catalog arguments)
- [x] 3.4 Verify that a later facade-only change rewrites descriptors but not client entries and reports no MCP client change; verified by the same test. User-modified entries keep the existing `managed-mcp-continuity` preservation unchanged
- [x] 3.5 New paths are owned by the existing `ondemand-go-source-tests` contract (`tools/itl-ondemand-mcp/*`, `go test ./...`); no new contract needed
- [x] 3.6 Teach the component publisher to plan and finalize `dependencies.itlOndemandRelay` as its own immutable release under the `ondemand-mcp` capability; verified by the SourceDeliveryComponentPublication Pester relay plan test

## 4. Documentation and delivery (stage A)

- [x] 4.1 Document the relay, descriptor, notes and error codes in `tools/itl-ondemand-mcp/README.md`
- [ ] 4.2 Commit and run `scripts/source-delivery.ps1 -Action RegisterChange`; verify the registration reports `registered`

## 5. Pin and acceptance (stage B, after the user publishes stage A)

- [ ] 5.1 Add `itlOndemandRelay` to `templates/dependency-lock.json` (repin tooling for the relay SHA in `scripts/ondemand-mcp-lock.ps1`); verify the dependency-lock and lock-staleness tests
- [ ] 5.2 Pass the relay source build through Develop/Release E2E stands (`ITL_ONDEMAND_RELAY_SOURCE_BUILD_EXE` in artifact discovery, stand identity and the `ondemand-mcp` stage) so the Release stage serves both families through the relay; verify with the release orchestration and stand preparation Pester tests
- [ ] 5.3 Align auxiliary-contour retirement (queued `codex/retire-auxiliary-contours`: `Test-ItlOnDemandLegacyAuxiliaryEntry` compares entries with the direct facade shape) with relay entries before pinning; verify with its retirement Pester tests in relay mode
- [ ] 5.4 After the user requests publication: release the relay and facade, then perform the live acceptance in an installed project (open chat, `update-workflow` to a new facade, next `itl-vanessa-ui` call served by the new version without reconnect, replacement note present); until then report it as unverified
