# VAExtension HTML command handlers

Original PM5 repair attempt 2/5 retained session fc750d84db284a789f4f474407094cbb
and business refresh target ae6911539de91b2f60fc6ef420acafdacb995a37. The repaired
client_mcp passed the three service-base Gate 6 checks. The existing paired
VAExtension.1.32-itl-r1.cfe, SHA
0019ecbca5dd5dccba27f652e789a391e2113b4ee085813760d1dc2ac2fe1ae5,
failed the target-base configuration check with native result 101. Snapshot
restoration ran; the original full check remains failed.

Pinned upstream a0ce2ee9803dd69be52f682e5cf49e0938fd33f1 declares server buttons
and commands in VAExtension_НажатьГиперссылкуHTMLДокумента and
VAExtension_НажатьКнопкуHTMLДокумента, but their exact BSL modules do not contain
ВыполнитьКодСервер. The existing ITL r1 patch does not affect these forms.
The authoritative HTML feature implementations use the client button; the
modules implement the client click and close actions. This is an inherited
component defect, not PM5 business-source drift.

The new immutable 1.2.043.42-itl-r2 component retains the complete r1 patch and
adds removal of those two orphan buttons and commands. It retains every other
form node, the modules, working client/close actions, existing metadata IDs and
file-code protocol. It does not add a fake handler or invent server execution.
The existing Vanessa build and paired-artifact delivery owner still build and
qualify EPF plus VAExtension together. Production templates keep the published
r1 until the r2 pair has been qualified and publication is authorized.

Four hash-pinned verbatim upstream XML/BSL blobs preserve the original defect in
tests/fixtures/vanessa-html-forms with BSD license provenance. Executable tests
apply the cumulative patch to the original XML, require the original missing
handler, compare every remaining form node, resolve every remaining command
action to its actual module procedure and compare module bytes. Windows
PowerShell 5.1 focused result: 3 passed, 0 failed, 7.59 seconds.

The five other native messages are possible-reference diagnostics for platform
system forms and УниверсальныйОтчет; the latter exists in this PM5 source.
Their independent effect on exit 101 is unverified. The deciding control is the
same unchanged native Gate 6 and original unfiltered check after the real
handler repair. No flag, assertion, workload, target or budget is relaxed.

Retained live evidence: build/pm5-client-live-gate6-attempt2-20261001.json and
build/pm5-client-repair-check-20261001.log. These records do not close the
remaining installed acceptance tasks or authorize publication.
