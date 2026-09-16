from pathlib import Path

chatgpt_root = Path(__file__).resolve().parent
workflow_root = chatgpt_root.parent
templates = workflow_root / "kilo-command-templates"
plugin_root = chatgpt_root / "plugins" / "itl-workflow-chatgpt"
out = plugin_root / "skills"
names = sorted({p.name.removesuffix(".md.template") for p in templates.rglob("*.md.template")})
text = """---
name: {name}
description: "ChatGPT/RDC thin wrapper for the installed project's local {name} skill."
---

# ChatGPT RDC router

This wrapper is optional and ChatGPT-only. Do not reimplement ITL behavior here.

1. Use Remote Desktop Commander and the PROJECT_ROOT bound for this chat.
2. Read `<PROJECT_ROOT>\\.agents\\skills\\{name}\\SKILL.md`; that local file is authoritative.
3. Follow that skill exactly, executing filesystem, Git, helper, and test actions on the remote computer.
4. When the local contract requires MCP, call `<PROJECT_ROOT>\\.agents\\skills\\1c-workflow\\chatgpt\\mcp_bridge.py` against PROJECT_ROOT; never rewrite `.codex/config.toml`.
5. Preserve unrelated dirty changes. Do not push unless the user explicitly asks.
6. If PROJECT_ROOT is not bound, activate `project-connect` first.
"""
for name in names:
    target = out / name / "SKILL.md"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text.format(name=name), encoding="utf-8")
print(f"generated={len(names)}")