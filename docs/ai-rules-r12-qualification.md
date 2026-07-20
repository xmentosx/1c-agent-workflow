# ai_rules_1c r12 qualification

- Release branch/tag: `release/itl-main-72665287-r12` / `itl-main-72665287-r12`
- Fork commit: `16e9e44318a79d9e82c12b19e6759cdf6492d9a4`
- Upstream provenance: `refs/heads/main@72665287e77361aea3aaf866fef163d98f0fabcd`
- Fork Full: 54 passed, 0 failed

`r12` preserves ITL single-client installation, delegated MCP ownership, downstream hardening, and release tooling while adding Kimi, Qwen, Command Code, Cline, and Pi. Kimi and Cline agent material is reference-only; their ITL routines are skills. Pi routines are project prompts and MCP is mandatory through project-local `npm:pi-mcp-extension@1.5.0`.

Pi was qualified with Node.js `24.15.0` and `@earendil-works/pi-coding-agent@0.80.10`: the pinned package installed project-locally and reached MCP state `ready` through a real stdio handshake. Its registry tarball and SHA-512 integrity are pinned in `templates/dependency-lock.json`.

The workflow compatibility matrix installs, updates, diagnoses, and validates exact-one-client manifests for all ten clients. Project switching removes only hash-recorded ITL surfaces, owned MCP entries, and the managed Pi package item; unrelated shared-config keys and user packages remain intact.
