# Vanessa Automation 1.2.043.28-itl-r6

This directory contains the minimal controlled downstream patch, immutable
provenance, license notice, and build contract. It does not vendor upstream
sources or a user-machine EPF.

Build the candidate from the repository root:

```powershell
& .\scripts\build-vanessa-automation-patched.ps1
```

The build clones the exact upstream tag, verifies its commit and canonical
archive SHA-256, verifies and applies this patch, and runs the upstream
`Compile.os` and `MakeVASingle.os` flows. Qualification promotes the exact EPF
bytes exercised by the live smoke; the candidate must not be rebuilt afterward.

Revision `itl-r6` deliberately restores upstream `1.2.043.28` behavior for
client file/directory access and `reloadAndRunFromLine`. Safe mode is disabled
for the separately installed `client_mcp` and `VAExtension` extensions by the
workflow through a localhost-only Designer Agent session, so those Vanessa
workarounds are no longer appropriate.

The patch retains only four independent corrections:

- `get_data_from_knowledge_base.search_string` is a string, backported from
  upstream commit `b02d884e2636cc4ba6d351861368df14e4bf293b`;
- `get_window_screenshot_os` directs callers to `get_window_list_os`, backported
  from upstream commit `91b1d07584ef2df5858e44c98ff33638bef7b6cf`;
- `run_scenario` preserves the MCP callback parameters and returns after opening
  a feature that was not already active;
- the on-demand facade remains the sole owner of MCP TestClient startup while a
  freshly launched client is becoming connectable.

No safe-mode path probes, `PATH_*` result contract, active-tab disk-check bypass,
or in-memory `reloadAndRunFromLine` substitution is present in this revision.

Do not patch installed EPF/CFE files. Consumers install only the qualified
immutable artifact and verify its separately recorded SHA-256.
