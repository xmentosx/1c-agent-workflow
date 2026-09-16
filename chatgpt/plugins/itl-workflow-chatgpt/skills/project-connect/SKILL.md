---
name: project-connect
description: "Bind a ChatGPT conversation to one installed ITL 1C project reachable through Remote Desktop Commander."
---

# Connect an ITL project

Use this skill when the user asks to connect/open a local ITL project or provides a project path.

1. Require Remote Desktop Commander to be available in the chat. If it is not exposed, ask the user to add `@Remote Desktop Commander`; do not simulate local access.
2. Treat the exact user-provided project path as `PROJECT_ROOT`. Treat the local `1c-agent-workflow` source repository containing `chatgpt/mcp_bridge.py` as `WORKFLOW_ROOT`.
3. Through Remote Desktop Commander run `python <WORKFLOW_ROOT>\chatgpt\mcp_bridge.py --project-root <PROJECT_ROOT> project-info` and verify that project rules, Git state, skills root, and MCP config are discoverable.
4. Read project rules in the precedence returned by `project-info`. Do not import the workflow source repository's root `AGENTS.md` as installed-project guidance.
5. For subsequent project work, use Remote Desktop Commander for local files, Git, helpers, tests, and commands. Load the exact installed project skill before an `itl-*` operation.
6. Use `<WORKFLOW_ROOT>\chatgpt\mcp_bridge.py` for MCP only when the project contract calls for an MCP tool. The bridge is a transport; `.codex/config.toml` remains authoritative and unchanged.
7. Preserve unrelated dirty changes and project safety gates. Never push unless the user explicitly asks.

After binding, keep `PROJECT_ROOT` and `WORKFLOW_ROOT` as conversation context and do not ask for them again unless the user switches projects.
