# Vanessa Automation 1.2.043.42-itl-r1

This source asset pins the upstream `1.2.043.42` tag and the ITL patch used to build the single EPF plus the matching `VAExtension.1.32-itl-r1.cfe`. The old `1.2.043.28` assets remain available for already installed projects.

Build with `scripts/build-vanessa-automation-patched.ps1 -UpstreamVersion 1.2.043.42 -DownstreamRevision itl-r1`. The manifest verifies the upstream commit and archive, patch paths and SHA, OneScript/1C toolchain, and bundled dependency bytes. Keep the EPF and CFE from one qualified archive together.

If a transient 1C license failure interrupts the native build, use the retained work directory printed by the script with the same build command and `-ResumeWorkDirectory <path>`. Resume requires confirmed release of native processes and rechecks the exact upstream archive, patch, build flow, and bundled dependencies before continuing the cached compile stage.

The patch preserves ITL's MCP scenario callbacks, TestClient port ownership, selected-feature tree, row criteria, and file-code channel. It also backports upstream fixes for MCP progress tokens and independent `Если/Иначе` conditions. All active client and server wait fallbacks use local sleep commands instead of `ping`; the legacy `dosleepusingping` setting is still accepted for parameter compatibility but cannot start ping.

Vanessa 1.2.043.42 exposes `manage_test_client` with `action=connect|disconnect` in place of `connect_test_client`; `close_test_client` remains a separate tool that closes the client session. It also exposes `get_vanessa_automation_state` in place of `get_VanessaAutomation_state`. The on-demand facade and its live `tools/list` catalog must be qualified against the candidate before updating the dependency lock or publishing assets.
