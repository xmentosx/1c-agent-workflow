# Native YAxUnit applicability label, 2026-10-09

The original Release attempt on workflow `e1ea797795f5b9ac086a67aa95bed562fca6ef4f`
failed before MCP backend testing. The official immutable YAxUnit 25.12 CFE
retained SHA `805a2277c997a3c24be0b0d080696479e91e4a15ed7e27aaf3991a7346522d70`.
Native applicability exit/DumpResult remained `0/0`; the full raw output contained
the same two missing intercepted-method messages twice each. All four messages
used the label `YAXUNIT (25.12):`, while the previous capture used `YAXUNIT:`.
The shared strict baseline rejected that native presentation and the existing
load owner restored its operation-local DT snapshot. No apply or publication
was reported successful.

Retained raw applicability SHA is
`17f1a74bd5c1e62691e2194e9e65b44f28e7525196c81949fd7dceba7eb847ef`.
Platform/context: `8.3.27.2130`, file infobase, original thin/server/external
connection modes, owned `D:\Git\itl-workflow-e2e-pm5-rel-e2e-r8` stand. The
failed source candidate was
`C:\Users\xment\AppData\Local\Temp\itl-source-publish-develop-5dfe240d971047bc8c3fb8b6e335e2d4`.
Raw log/result/assessment are retained under source ignored
`build/gate6-r41-source-delivery/yaxunit-versioned-prefix-20261009`.

The reproducer retains the exact native bytes/hash: before repair, 0 passed / 1
failed because assessment returned `rejected`. The owner now matches either
complete exact applicability multiset, preserving raw bytes without stripping
version text. Mixed labels, another version, altered annotation, missing
repetition and extra diagnostics are negative regressions. The complete
YAxUnitVerification file passed 65/0, including all prior strict pin, source,
codes, encoding, configuration, modules and load/runtime-selector negatives.

This repairs an invalid assumption about a native extension display label; it
does not expand accepted vendor findings, change the artifact, or change the
CheckConfig/modules contract. Local regression proof is not Release acceptance.
Publication and original both-backend runtime/cleanup acceptance remain open.
