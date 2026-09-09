# Source analysis of retained profiles

Measuring a database does not require its configuration to match the checkout.
Never update that database or overwrite the checkout to make source mapping pass.

## Choosing whether source information is needed

`remote_work.py analyze --raw <packets...> --source-analysis <policy>` supports:

- `none`: analyze timings without reading source files or a source manifest.
- `optional` (default): report available mappings and explicit missing reasons.
- `required`: retain the complete analysis JSON but exit 2 if any measured module
  or line lacks a verified binding. This is an unmet source-analysis requirement,
  not a claim that the raw packets were lost or that the measurement failed.

Top-level `complete` and `coverage` describe profile packet coverage. The separate
`sourceAnalysis` reports its policy, status, matched/total modules and lines, and
`requirementSatisfied`. Consumers requiring code analysis must check this field.
Each packet retains `sourceModules` for every module, including those outside
the thirty displayed hotspot rows. Rows carry `sourceMatched` and `sourceIssue`.

## Binding format

`--source-map <manifest.json>` accepts schema 2:

```json
{
  "schemaVersion": 2,
  "modules": [{
    "moduleID": {
      "objectID": "<native object UUID>",
      "propertyID": "<native module property UUID>",
      "extId": "<native value>",
      "version": "<native version>"
    },
    "path": "sources/module.bsl",
    "sha256": "<SHA256 of original source bytes>",
    "origin": "database-snapshot",
    "snapshotId": "<capture identifier>"
  }]
}
```

Paths resolve relative to the manifest directory. UTF-8 with or without BOM and
original CRLF bytes are supported; hashing never normalizes source bytes. The
manifest producer must establish the identity/version-to-file relationship from
authoritative source evidence. Copying an observed version onto arbitrary local
code is not such evidence. Hash checking protects the supplied binding from file
drift; it cannot establish the producer's correctness on its own.

All native identity fields are retained, including `type`, `URL`, `extensionName`
and opaque `extId` when present. `extId` is not interpreted as an extension name.
Platform defaults follow the official [BSLModuleIdInternal model](https://edt.1c.ru/dev/edt/2024.2/apidocs/com/_1c/g5/v8/dt/debug/model/base/data/BSLModuleIdInternal.html).
The version in a native module identity must not be confused with a nested
`.Module` version in ConfigDumpInfo or with the whole configuration fingerprint.
Identical modules may be reused even when the rest of the checkout differs.
Different bindings for one identity/version remain ambiguous, never first-match.

The legacy explicit-id dictionary is still readable for packets containing that
id. A native packet without an id never resolves through an empty dictionary key.

## Source capture boundary

This analyzer consumes bindings; automatic target-source capture is a separate
implementation stage. Until the supported capture producer is delivered, missing
bindings remain missing. Preserve packets for later analysis. A fresh export
after the target changed does not prove it matches an earlier measurement.

Target capture must use the actually executed database configuration and relevant
extensions, preserve their identities and versions, and write separate immutable
artifacts. Hold the database operation lease through capture and verification,
outside the timed interval. Merely exporting the editable Designer configuration
does not establish equivalence with the executing database configuration.
