---
name: itl-check
description: "ChatGPT/RDC thin wrapper for the installed project's local itl-check skill."
---

# ChatGPT RDC router

This wrapper is optional and ChatGPT-only. Do not reimplement ITL behavior here.

1. Use Remote Desktop Commander and the PROJECT_ROOT bound for this chat.
2. Read `<PROJECT_ROOT>\.agents\skills\itl-check\SKILL.md`; that local file is authoritative.
3. Follow that skill exactly, executing filesystem, Git, helper, and test actions on the remote computer.
4. When the local contract requires MCP, call `<PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py` against PROJECT_ROOT; never rewrite `.codex/config.toml`.
5. Preserve unrelated dirty changes. Do not push unless the user explicitly asks.
6. If PROJECT_ROOT is not bound, activate `project-connect` first.
