# Auxiliary Contours

Use this reference when one development branch needs another configuration or infobase: exchange tests, a disposable server stand, or an experiment that should not become another Git branch. `auxiliaryContours` is optional; when absent, primary lifecycle, verification, result, and MCP behavior is unchanged.

## Agent-led setup

The user never edits `project.json`, `.dev.env`, or MCP client files to connect a contour. On requests such as "connect another base", "add a server test base", or "make a separate exchange configuration", collect the following in chat using plain-language choices. Recommend a value when context supports it, ask only unresolved questions, and do not expose the helper invocation.

1. Purpose and a short human name. Derive a stable lowercase contour id; ask for a different id only on collision.
2. Base ownership: workflow-created local base; existing external diagnostic base that must not change; or dedicated external test base that workflow may update. State the mutation consequence before accepting the third choice.
3. Configuration source: primary `src/cf` or a separate existing project-relative source directory. Ask whether reverse source dump is required; never allow it for `src/cf` or a read-only base.
4. Verification: no automated tests, primary suite, separate contour suite, or both. Propose `tests/auxiliary/<id>` for a separate suite.
5. Optional extensions: ask for each extension name and its existing project-relative source directory.
6. Diagnostics: ROCTUP, Vanessa UI MCP, both, or neither. Explain that Vanessa UI MCP is interactive diagnosis and does not replace Vanessa Automation proof.
7. For an external base only: file/server kind, exact connection path, user, and whether a password exists. Never ask the user to paste a password into chat. If it exists, ask them to copy it to the clipboard and confirm readiness; configure with clipboard password mode. If absent, explicitly clear the stored password.

Summarize the selected base-mutation rights, source ownership, test suites, extensions, and MCP before the one configuration call. Invoke `configure-auxiliary-contour` with the resolved values. It preserves unrelated project and `.dev.env` settings, writes each file atomically, rolls back handled failures, validates path ownership and suite separation, and keeps secrets out of tracked files. After success, run `update-auxiliary-contour` only for `managed-file` or an explicitly disposable attached base; a read-only base proceeds to status or requested MCP diagnostics.

When reconfiguring an existing contour, show current effective settings, ask only for intended changes plus any choices whose consequences changed, then call the same configuration action with the complete resulting definition. Password mode `keep` preserves an existing local password, `empty` removes it, and `clipboard` replaces it without command-line disclosure.

## Internal declaration contract

The setup action writes named contours into tracked `.agent-1c/project.json`; this structure is implementation evidence, not a user setup instruction:

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

The setup action stores attached connections only in ignored `.dev.env` values:

```dotenv
ITL_AUX_EXCHANGE_INFOBASE_KIND=server
ITL_AUX_EXCHANGE_INFOBASE_PATH=server-name\test-base
ITL_AUX_EXCHANGE_USER=test-user
ITL_AUX_EXCHANGE_PASSWORD=secret
```

`connectionRef` becomes the uppercase middle token. Never put credentials in project JSON.

## Operations and proof

Agents route natural-language requests to `configure-auxiliary-contour`, `status-auxiliary-contours`, `update-auxiliary-contour`, `dump-auxiliary-contour`, `check-auxiliary-contour`, `export-auxiliary-contour-result`, or `reset-auxiliary-contour`. These are advanced helper actions, not a new slash-command family. Every mutating or proving action requires an exact contour name; there is no implicit active contour.

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
