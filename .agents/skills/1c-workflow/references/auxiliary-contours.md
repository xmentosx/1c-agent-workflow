# Auxiliary Contours

Use this reference when one development branch needs another configuration or infobase: exchange tests, a disposable server stand, or an experiment that should not become another Git branch. `auxiliaryContours` is optional; when absent, primary lifecycle, verification, result, and MCP behavior is unchanged.

## Declaration

Declare named contours in tracked `.agent-1c/project.json`:

```json
{
  "auxiliaryContours": {
    "exchange": {
      "configurationPath": "src/configs/exchange/cf",
      "baseMode": "managed-file",
      "connectionRef": "EXCHANGE",
      "sourceMode": "read-write",
      "tests": { "includePrimary": true, "path": "tests/auxiliary/exchange" },
      "extensions": [
        { "name": "ExchangeSupport", "path": "src/configs/exchange/cfe/ExchangeSupport" }
      ],
      "mcp": { "roctup": true, "vanessaUi": true }
    }
  }
}
```

Names use lowercase Latin letters, digits, and hyphens. Prefer `src/configs/<id>/cf`; managed `src/configs/** -text` preserves the bytes emitted by 1C. Primary `src/cf` may be reused only with `sourceMode=load-only`. Exactly one contour may be the `read-write` owner of a path.

Base modes stay deliberately small:

- `managed-file`: workflow-owned branch-local file infobase; reset archives it and the next update recreates it.
- `attached-readonly`: external base for status and ROCTUP/Vanessa UI diagnostics; source/base mutation and automated tests are blocked.
- `attached-disposable`: explicitly disposable external file or server test base; update, tests, and source dump are allowed.

Supply attached connections only through ignored `.dev.env` values:

```dotenv
ITL_AUX_EXCHANGE_INFOBASE_KIND=server
ITL_AUX_EXCHANGE_INFOBASE_PATH=server-name\test-base
ITL_AUX_EXCHANGE_USER=test-user
ITL_AUX_EXCHANGE_PASSWORD=secret
```

`connectionRef` becomes the uppercase middle token. Never put credentials in project JSON.

## Operations and proof

Agents route natural-language requests to `status-auxiliary-contours`, `update-auxiliary-contour`, `dump-auxiliary-contour`, `check-auxiliary-contour`, `export-auxiliary-contour-result`, or `reset-auxiliary-contour`. These are advanced helper actions, not a new slash-command family. Every mutating or proving action requires exact `-AuxiliaryContourName`; there is no implicit active contour.

Update performs a full configuration load, full declared extension loads, and Enterprise normalization. Equal source and connection fingerprints skip Designer. Before mutation, workflow-owned MCP and exact-infobase sessions are drained. Primary refresh/check/result/reset never updates a contour.

Dump is available only to a `read-write` contour and installs a validated staged dump transactionally. Reset is `managed-file` only and moves the old infobase into ignored `.agent-1c/auxiliary-archives/`. Auxiliary CF and manifest files live under `build/result/auxiliary/<id>/` and never overwrite primary evidence. Export without a fresh contour proof requires the explicit unverified override and records it.

`tests.includePrimary=true` reruns the primary feature suite against the contour. `tests.path` adds a contour-owned suite. Suites run sequentially with cleanup between them; when both are configured, only `all` creates canonical contour proof. `primary` or `contour` alone is diagnostic. Results live under `build/test-results/vanessa/auxiliary/<id>/<suite>/`.
Suite roots must be disjoint; do not put the contour suite inside `tests/features` when that is the primary root.

For exchange scenarios that open clients in different bases, use TestClient manifest schema 2:

```json
{
  "schemaVersion": 2,
  "maxConcurrency": 2,
  "profiles": [
    { "name": "Source", "contour": "primary", "userEnv": "SOURCE_USER", "passwordEnv": "SOURCE_PASSWORD" },
    { "name": "Receiver", "contour": "exchange", "userEnv": "TARGET_USER", "passwordEnv": "TARGET_PASSWORD" }
  ]
}
```

Schema 1 remains primary-only. Feature paths remain the scenario registry.

## MCP

`mcp.roctup` and `mcp.vanessaUi` add `itl-roctup-aux-<id>` and `itl-vanessa-ui-aux-<id>`. Each keeps the compact `resolve_tool`/`call_tool` surface but has its own generated helper wrapper, backend, ports, and exact infobase. Existing primary endpoint arguments remain unchanged. MCP is diagnostic; contour verification still uses Vanessa Automation `TESTMANAGER -> TESTCLIENT`.
