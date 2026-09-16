---
name: project-connect
description: "Bind a ChatGPT conversation to one installed ITL 1C worktree reachable through Remote Desktop Commander."
---

# Connect an ITL worktree

Use this skill when the user asks to connect/open a local ITL project or provides a worktree path.

1. Require Remote Desktop Commander in the chat. If it is not exposed, ask the user to add it; do not simulate local access.
2. Treat the exact user-provided path as `PROJECT_ROOT`. Work only inside this worktree; do not discover or use a master worktree or a separate workflow-source checkout.
3. Run `python <PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py --project-root <PROJECT_ROOT> project-info` through RDC.
4. Read project rules in the precedence returned by `project-info`. The installed worktree is the only project authority.
5. For subsequent work, use RDC for files, Git, helpers, tests, and commands. Load the exact installed project skill before an `itl-*` operation.
6. Use the bridge under this same `PROJECT_ROOT` only when the local contract calls for MCP. `.codex/config.toml` remains authoritative and unchanged.
7. Preserve unrelated dirty changes and project safety gates. Never push unless the user explicitly asks.

After binding, keep only `PROJECT_ROOT` as conversation project context and do not ask for it again unless the user switches worktrees.