# Vanessa client-code channel maintenance

This is source-maintenance evidence for reliability plan item 10. It does not
declare the locally built candidate installed or authorize changing a target
database merely to obtain this channel.

## Observed failures

In `Замеры7 — работа с БДР` (01a07ce5-12c7-75c1-bd00-7baed4f09863), retained
`run-20260908-014535-467` and the subsequent 01:48 diagnostic reached
`VAExtension_ВыполнитьПроизвольныйКод` line 7 and failed in
`COMОбъектHtmlfile.ParentWindow.ClipboardData.Getdata("Text")`, with nested
`Ошибка при вызове OpenClipboard`. A later HWND=0 observation does not identify
the clipboard owner at the time of failure. An earlier missing VanessaExt
clipboard object is a separate initialization failure. Setting the option alone
does not create that object. Neither observation justifies replacing business
assertions, repeating a possibly executed command or changing conf.cfg.

The task recovered through the existing file-event steps and explicit
`BDR_EVENT_COMPLETED` markers. Source inspection and executable reproduction show
why simply recommending those steps is insufficient: a missing monitor silently
sends nothing, void success has no response, thrown client-code errors disappear,
the request remains executable until after execution, and Event/Result replacement
also changes matching parent-directory text.

## Paired downstream protocol

Candidate r13 retains the r11 changes to both the Vanessa step library and
VAExtension, and the r10 row-caption and r9 nested-feature corrections. The existing file-code step
publishes a complete JSON request by moving a temporary file to
`Event_ITL_<uuid>.json`. One unresolved command cannot be overwritten by a later
send. Every monitor start gets a unique generation below the provided root,
containing an `events` directory. The monitor registry uses the selected TestClient's host,
port and infobase connection, independently of its reported PID. Starting another
monitor for that same client is
rejected until its current monitor is stopped. Stop resolves the actual recorded
generation instead of reconstructing a path from the caller's argument.

The receiver exclusively creates `Claim_ITL_<uuid>.json` before executing code.
It keeps that claim if it crashes, throws or cannot publish the response. A later
consumer cannot repeat the command merely because the response is absent. This
provides at-most-once dispatch for the request; it cannot guarantee that an
interrupted business operation completed or rolled back.

`Result_ITL_<uuid>.json` includes protocol, request ID, succeeded/failed status,
value and error. Void success is explicit, the original code error survives and
the waiting step validates the response identity before continuing. Results use
the original directory plus a changed basename. Missing/invalid completion keeps
the unresolved request and fails the wait without resending. A reported code
failure may still have partial business effects; it is not retry authorization.

The build produces the paired CFE through the existing guarded Designer using
the prepared service database. The CFE, EPF, patched sources and provenance are
packaged together. The installed dependency pins remain unchanged until normal
component qualification and delivery. An upstream-only extension cannot execute
this protocol, so do not deploy the EPF alone.

## Remaining acceptance and recovery work

Run the original BDR scenario with its existing assertions and command boundaries.
The paired native build now verifies actual monitor start/stop UI plus two clients
and two independent channels; the earlier r11 run verifies server and
privileged-server commands. Native process-interruption recovery and installed
BDR acceptance remain open. The busy-clipboard and competing-consumer OneScript
regressions are protocol evidence; they do not establish those remaining live 1C
acceptance paths.

The r13 producer writes an immutable channel owner and a durable pending record
before publishing the event. A fresh Vanessa process scans only the supplied
monitor root, matches the exact normalized host/port/infobase identity and binds
at most one unacknowledged request. The same target and code resume that request:
an unpublished event is reconstructed, an unclaimed event can be consumed once,
and a terminal response is returned. A permanent claim without a response stays
unknown; a changed command or multiple pending requests fails closed. The result
is acknowledged only after Vanessa continues the waiting step, so a restart can
re-read a terminal response but cannot repeat its business effect.

Requests, responses, claims and acknowledgements remain recovery evidence. Do
not remove a claim while its request may still be consumed, delete a shared
monitor root, or reset unresolved state to force a repeat. Automatic scoped
cleanup must first prove the owning consumer has stopped, retain the operation
outcome in run artifacts and remove only that generation's files. Installed
authoring guidance, native restart-interruption acceptance, original BDR
acceptance and normal delivery remain open parts of item 10.

## Connection identity and native evidence

The registered r11 change at `75a36db` passed 578 Targeted tests. Its paired native
build and four real 1C file-base scenarios confirmed returned values, void success,
the original command exception, server execution and privileged server execution.
The negative scenario intentionally has one JUnit failure containing the original
exception. All owned native sessions and database admissions were released.
These server calls use file-base ServerEmulation; they do not establish remote
server-infobase acceptance.

Those runs also exposed that the selected Vanessa profile can retain PID 0 after
connecting a real TestClient. Two such profiles collide in the r11 PID-keyed
registry. An executable reproducer sends a selected client's command into the
other client's directory with the actual r11 producer. The r12 correction uses
the selected host/port/infobase in all six file-event consumers, including legacy
equipment events, monitor start/stop, sending and waiting. Host case and surrounding
whitespace are normalized; network aliases are not presumed equivalent. A missing
connection identity cannot authorize sending code to another client's monitor.

The wait starter captures the request and its sending connection before scheduling
the callback. Changing the selected profile does not redirect an already started
wait. Starting a new wait from a different client fails without consuming the
original request. There remains one unresolved command per sequential Vanessa
step stream; this is not a claim of concurrent waits inside that stream.

Executable r11/r12 protocol and connection-identity regressions cover these paths,
including a PID becoming known after monitor registration. The r13 restart cases
add terminal, unclaimed, unpublished, claimed-unknown, changed-command, foreign
owner and ambiguous-state coverage. Scoped cleanup remains a separate candidate.

The first native r12 two-client run (`probe-c0865302`) exposed another owning-layer
defect before channel acceptance could pass. Its two profiles had distinct ports
and databases, but Vanessa logged connecting both to the first port. The command
for B raised `ITL_CLIENT_B_WRONG_DATABASE`; the scenario retained that assertion
and stopped. Separate channel directories alone cannot establish correct targeting.

The upstream allocator resets the requested port to the range start, includes
every profile's assigned port in the busy set (including its own), then returns
the range start when no port remains. The correction retains a free assigned
port, excludes only the requesting profile's reservation from the busy list,
keeps actual listeners and other profile reservations, and rejects exhaustion
with `ITL_TESTCLIENT_NO_FREE_PORT`. The launch call passes the requesting profile
name. Six executable cases reproduce the original occupied-port return and
exercise the corrected allocator together with the actual Windows netstat parser.
The native two-client scenario must also pass on the resulting paired build;
neither widening its range nor removing its second profile establishes the fix.

The corrected native paired build has patch SHA-256
`ea92b1adfe628dd5c63ac3ac5f4efcef7dc0b1ad94002effb627d6a607a87566`
and ZIP SHA-256 `e9ef4849a5ad4b43c035dfb5aefa54fe29bb7fc1c932ccd96c82e43f2f12d7ec`.
Run `probe-0510e9cd` passed its one scenario with zero failures/errors: both
monitors were started, ports 59128 and 59129 stayed distinct, commands A/B/A
asserted their actual database connection strings, and both monitors stopped.
Three correlated successful replies reside in two separate channel generations.
The combined focused source group passes 160 tests.

The first r13 native candidate exposed a platform-only syntax defect that the
OneScript recovery fixture had accepted: `Новый Файл(Каталог).ПолноеИмя` failed
to initialize the embedded `Тест_VAExtension` form on platform 8.3.27.2130.
Vanessa consequently generated a cache without that library and reported its
monitor step as unimplemented. The expression now uses a separate `Файл` object,
and the guarded upstream build adapter rejects a cache that omits the monitor
procedure. The exact final paired build at `C:/va канал/18ec28e6` has patch
SHA-256 `6ca8c714e2a584eb58b0a0a95f111baf2831c754b9472fa3b3ba6ba8129acc71`,
EPF SHA-256 `d34d3eab326821f5d174f82032558c8ed1394f186f2d861e6339a8a02fb14473`,
CFE SHA-256 `466c7cdec3c5bb52a4b71dd38e35dec8bc6b900cdcee9abe6df602e5c1546bee`
and ZIP SHA-256 `fc081d5bc235a9444dace37e2a00d8c81be5739e0a4ffd1eb2936664ff9ad0fa`.
All six build-native records were released.

Run `r13-probe-f1e83dd1` passed one native A/B/A scenario with zero
failures/errors. Two client profiles retained distinct ports and databases,
both monitor generations started and stopped, and three correlated replies
proved two executions in A and one in B across two channel directories. Its
manager and both client database admissions were released. The retained failed
probe `r13-probe-9aa1bc84` used a manager base whose same-version cache had been
populated by the earlier defective unpublished r13; it also released every
database and led to the clean service-base rerun rather than a scenario change.

A separate process inspection contradicted the first failed run's `released=true`
claim: PID 27584, created at `2026-09-10T06:08:21.5136980Z`, remained with that
run's exact B database, port 53941 and `/Out` path. The existing scoped Vanessa
cleanup helper matched it, stopped that one client under renewed database
admission, and confirmed no remaining matching processes. The original result
is retained unchanged; `original-probe-cleanup-audit.json` records the contradiction
and recovery. This is an additional concrete item 4 recovery-probe defect, not
proof that descendant cleanup is fixed by the port correction. The second run's
own process scope was empty after completion. No foreign process was stopped.
