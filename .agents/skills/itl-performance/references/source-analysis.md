# Source analysis of retained profiles

Measuring a database does not require its configuration to match the checkout.
Never update that database or overwrite the checkout to make source mapping pass.

## Choosing whether source information is needed

`remote_work.py analyze --raw <packets...> --source-analysis <policy>` supports:

- `none`: analyze timings without reading source files or a source manifest.
- `optional` (default): report available mappings and explicit missing reasons.
- `required`: retain the complete analysis JSON but exit 2 if any requested module
  or line lacks a verified binding. This is an unmet source-analysis requirement,
  not a claim that the raw packets were lost or that the measurement failed.

Top-level `complete` and `coverage` describe profile packet coverage. The separate
`sourceAnalysis` reports its policy, status, matched/total modules and lines, and
`requirementSatisfied`. Consumers requiring code analysis must check this field.

By default all measured modules are requested. To investigate only certain
modules, put their native `moduleID` objects from `packets[].sourceModules[]` in
a JSON array and pass `--source-modules <file>`. A scenario uses the same array
in `sourceAnalysisModules` together with `sourceAnalysis: optional|required`.
Keep all identity fields, especially extension/context distinctions. `version`
may be omitted in a reusable scenario selector; the actual source binding still
must match the version in the new packet. Empty or malformed lists are rejected.

Excluded modules and rows remain in the raw analysis with
`sourceIssue: outside-requested-scope`; they do not make selected-source analysis
incomplete. `sourceAnalysis.selection`, `excludedModules` and `missingSelections`
make the scope explicit. A requested identity absent from the profile leaves a
required analysis unsatisfied. It does not trigger an export with nothing to map.
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

Fresh capture seals the exported XML metadata and BSL bytes, including empty
modules, before constructing bindings. The producer validates each used metadata
file and module against that inventory. An unchanged ConfigDumpInfo.xml does not
authorize mapping a subsequently edited module to its old native version.
Unsealed legacy snapshots require a fresh capture for new bindings; the producer
does not repair their evidence by hashing current files. Existing pinned binding
manifests still use their original per-module hashes during reuse.

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

A measurement scenario can request automatic resolution with `"sourceAnalysis":
"optional"` or `"required"`; the default `"none"` does not export sources.
Source analysis requires profile or time+profile mode. Set a separate
`phaseTimeoutSeconds.source-capture` budget for a large configuration. Capture
runs after scenario verification and before cleanup, under the existing database
lease and outside every timed interval. It also obeys the per-base session limit;
it never stops a foreign client to obtain a Designer slot.
For a repository-bound base, the English startup notice about working without
repository authentication is retained in snapshot diagnostics and excluded from
the extension list. The helper fixes its language with `/L en`. Unknown log
messages remain an invalid-list failure. This follows the documented
[/DisableStartupDialogs behavior](https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Appendix_7._Startup_command-line_options_of_1C_Enterprise/7.3._General_startup_commands/7.3.11._Other_parameters/?language=en).
The capture process reads the target workspace's `.dev.env` session limit and
waits for capacity within the existing capture deadline, including cancellation.
When a missing binding actually requires capture, the engine first closes this
run's Vanessa facade through its existing cleanup protocol, freeing its owned
TestClient slot. It checks the job identity and waits for confirmed shutdown.
It does not run the scenario's data restoration at this point: final cleanup
still follows capture under the same database lease. A later adapter cleanup
accepts the already completed shutdown instead of sending to a stopped daemon.
Complete source reuse skips both capture and early adapter shutdown.

Custom persistent workloads can declare `commands.quiesce`, an argument array
which closes only their owned clients without changing measured data or restoring
snapshots. It runs after the last verification, only when capture is needed,
inside the existing `source-capture` deadline. `commands.cleanup` still owns final
restoration and must support already closed clients. Quiescence failure prevents
Designer launch while retaining profiles and the original cleanup path. Foreign
sessions can still exhaust capacity; they are never stopped to make a slot.

The Windows capture step reads `/DumpDBCfg` and `/DumpDBCfgList -AllExtensions`
from the target, including each extension's saved database configuration. It
creates its own scratch file base, loads the CF/CFE there, and exports hierarchical
XML/BSL. Target commands cannot load, restore or update a configuration. The
scratch base is removed only after its identity and process exit are established;
unproven termination reaches `cleanupErrors`, retained scratch files are reported.
The selected platform's sibling `1cv8.exe` is used when the client is `1cv8c.exe`.
Optional private target `sourceCapture.userEnv` and `sourceCapture.passwordEnv`
refer to environment variable names; plaintext credentials are not stored.

`source-snapshots/<id>/snapshot.json` retains phase progress, CF/CFE hashes and
source indexes. `source-map.json` binds requested native module versions to the
export's object UUID/version, module property and source bytes. Required capture
or mapping failure leaves raw profiles available but the job needs attention;
optional failure is a visible limitation. Each profile JSON is updated along with
the job result. A fresh export after the target changed does not establish that
it matches an earlier profile: mismatched modules remain unresolved.

## Reusing captured sources before exporting

The execution-host target can supply `sourceCapture.manifests`, an array of
`{"path": "<source-map.json>", "sha256": "<pinned manifest hash>"}` references.
Relative paths resolve from that target's workspace, not the caller's checkout.
References must come from a verified producer as described above. The engine
checks the pinned manifest bytes and exact module identity/version/source bytes
before reuse. It does not rebuild an old binding by hashing a modified file.

Matching sources are copied byte-for-byte into the current run's
`source-analysis/` directory, with retained binding manifests. The result's
`sourceManifest` contains the path and hash to configure for a later run.
`sourceResolution` records the requested scope, reused modules, input references,
rejected bindings and whether capture was attempted. Identical bytes from two
references are reusable; conflicting bindings are unresolved until an
authoritative fresh capture establishes a binding. Bad cache entries do not
block otherwise successful resolution, but remain in diagnostics.

When every requested module and line matches, no Designer capture is launched.
Otherwise the existing read-only capture obtains the base and extensions, and
the producer binds only missing modules; verified reused modules are retained.
Missing sources outside the selected scope do not require capture. The full
CF/CFE export is currently retained because opaque native extension identities
can require checking both the base and its extensions to detect ambiguity.

Normal full configuration and extension source exports automatically save a
catalog under `.agent-1c/source-exports/` after successful source installation.
The catalog retains the original dump index, workspace/export identity and
hashes of exported metadata and BSL bytes. It is local runtime evidence and is
not added to the configuration transport or Git. Failure to save this optional
catalog warns without rolling back a successful source export.

Source analysis automatically discovers catalogs in the target workspace.
It compares requested native versions to the retained export index and checks
each current metadata/module file against its original hash. An unrelated
checkout change or later ConfigDumpInfo update does not invalidate unchanged
modules. Changed modules remain unresolved and follow normal target capture.
ExtensionName selects the configuration catalog; opaque extId values stay in
the exact binding identity and are never interpreted as extension names.
Analysis copies accepted bytes and catalog evidence into its run without
editing checkout files. A checkout with no catalog simply uses the existing
capture fallback; do not fabricate a catalog from arbitrary current sources.

Full runtime acceptance of Designer capacity with persistent adapter sessions
and PM5/UFA measurements remains open. No analysis path overwrites checkout sources.
