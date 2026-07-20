# ai_rules_1c r13 qualification

- Release branch/tag: `release/itl-main-72665287-r13` / `itl-main-72665287-r13`
- Fork commit: `b66569bebf46e0369efa53983fca69368e16d57a`
- Upstream provenance: `refs/heads/main@72665287e77361aea3aaf866fef163d98f0fabcd`
- Downstream revision: `13`
- OpenSpec snapshot: `1.2.0`; native bundles remain limited to Cursor, Claude Code, Codex, OpenCode, and Kilo Code
- Natural clients: Kimi, Qwen, Command Code, Cline, and Pi use the shared workspace/rules without downstream bundles
- Fork Full: 57 passed, 0 failed on the clean release commit
- Publication: atomic branch/tag push followed by remote-ref and fresh-clone verification
- Workflow targeted matrix: 119 passed, 0 failed; all five natural clients classify from real r13 manifests and intact workspaces
- Client CLI smoke: Kimi 0.28.0, Qwen 0.20.0, Command Code 0.52.1, Cline 3.0.46, and Pi 0.80.10 reached their authentication boundary without changing OpenSpec artifacts
- Pi runtime: trusted project-local `npm:pi-mcp-extension@1.5.0` installed under `.pi/npm`; an eager stdio server completed MCP initialization and reported `1/1 servers ready`

The smoke host has no model credentials for these five CLIs, so model-backed natural proposal/apply/archive execution is not claimed. The workflow qualifies the pinned checkout again through its final Full gate.
