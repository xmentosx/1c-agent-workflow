# client_mcp v0.6.5 / ITL itl-r1

The authoritative binary input is the immutable upstream release identified in
manifest.json. Upstream keeps EDT sources; this build uses the pinned platform
to export that release to Designer XML and applies the bounded metadata repair.
The complete patched source is in `src/` in the corresponding-source ZIP.
Compatibility/API version stays v0.6.5; downstream identity is separate.

From a clean exact workflow source checkout run
`scripts/build-client-mcp-patched.ps1` using the manifest-pinned platform.
The existing infobase owner creates a private service base, checks modules,
applicability and the full configuration, dumps the CFE, and restores its DT.
The returned CFE and source ZIP SHA values identify that immutable candidate.
A rebuild may produce a different binary; never overwrite a published revision.

The standard Designer `LoadConfigFromFiles` operation can also compile `src/`
as extension `client_mcp` in the qualified Vanessa service/TestManager template.
Use the workflow's guarded load/check/dump owner and preserve its snapshot
rollback. Do not load this extension into the PM5 TestClient base.

Build checks are not live Vanessa qualification. Run the existing service to
TestClient scenarios and on-demand capability for the exact resulting CFE.
Before introducing owned asset URLs into the production dependency lock,
publish compatible component-supervisor support in the authority channel.
Publish CFE and corresponding-source ZIP together; verify both remote SHAs.
