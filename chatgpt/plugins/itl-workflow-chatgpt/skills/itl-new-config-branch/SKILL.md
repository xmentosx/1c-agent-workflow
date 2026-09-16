---
name: itl-new-config-branch
description: "ChatGPT/RDC thin wrapper for the installed project's local itl-new-config-branch skill."
---

# ChatGPT RDC router

This wrapper is optional and ChatGPT-only. Do not reimplement ITL behavior here.

1. Use Remote Desktop Commander and the PROJECT_ROOT bound for this chat.
2. Read `<PROJECT_ROOT>\.agents\skills\itl-new-config-branch\SKILL.md`; that local file is authoritative.
3. Follow that skill exactly, executing filesystem, Git, helper, and test actions on the remote computer.
4. When the local contract requires MCP, call `<WORKFLOW_ROOT>\chatgpt\mcp_bridge.py` against PROJECT_ROOT; never rewrite `.codex/config.toml`.
5. Preserve unrelated dirty changes. Do not push unless the user explicitly asks.
6. If PROJECT_ROOT or WORKFLOW_ROOT is not bound, activate `project-connect` first.
