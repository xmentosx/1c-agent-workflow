# OpenSpec publication metadata correction

The first final c1 publication attempt stopped before qualification, 1C or
push. Source was clean at `3bd88028c0ad508523eadd4a418f60a3be100758`, tree
`d4dac44288dd52f5c8320061189e47afd47ae761`. The public delivery owner refused
`aiRules1c=pending, openSpecCli=pending`; the isolated queue remained intact
and `activeOperation` returned to null. Remote develop remained `f5466e6` and
master `69c0863b`. Original attempt, plan and status are retained under the
publication checkout's `build/c1-publication-blocked-3bd88028/retention.json`,
SHA256 `91d3e0a593893cd6f212b9bceac85864a9b64e2ae748b54a162d9d8a4ae029ca`.

Two independent read-only audits traced `openSpecCli.compatibilityStatus`
to the initial integration commit `a192f6be`. D6/OS4 require the exact
project-pinned Node/CLI pair, npm integrity, transitive lock and real phase
behavior; they introduce no publication status transition for this component.
The `openspec-runtime` owner qualifies that contract. Its library, source
launcher and npm package/lock blobs are unchanged from the initial integration
through `3bd88028`; no OpenSpec status reader or promoter exists.

The correction removes only this unowned template field. It does not declare
compatibility passed. Exact CLI version, integrity, package-lock hash, Node
requirement, runtime binding and installed phase acceptance remain required.
The generic publication guard still refuses every declared non-passed status;
the evidence-backed promoter remains restricted to `aiRules1c`.

Historical native OpenSpec phase evidence remains bound to its original fork
and installed workflow. It is not whole-candidate evidence for c1. Current
publication qualification and final installed acceptance remain separate.

The existing publication classifier case now reads the actual source template
with only a test-local passed fork status. Native Windows PowerShell 5.1/Pester
5.8 first reproduced the original blocker (0/1, 1.293 s), then passed the same
case (1/0, 1.550 s) after the field removal. It also proves an unknown pending
dependency remains the sole precise blocker. Original assertions and all other
case bodies are preserved; the guard/promoter code is unchanged. All 15
captured focused inputs were stable within each run; only the template changed
between RED and GREEN. Retained receipt:
`build/openspec-compat-marker-causal-1af6613ef7604e21835df3bf54b041a3/qualification.json`,
SHA256 `119c4338d8b982bcebf2f37b6ad86c4bf95d49c556dac57241ed4cd95ddd46ef`.
Independent read-only review found no material findings. Strict source
OpenSpec 1.13.1 validation passed after this evidence update.
