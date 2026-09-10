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

Candidate r11 changes both the Vanessa step library and VAExtension. It retains
r10 row-caption and r9 nested-feature corrections. The existing file-code step
publishes a complete JSON request by moving a temporary file to
`Event_ITL_<uuid>.json`. One unresolved command cannot be overwritten by a later
send. Every monitor start gets a unique generation below the provided root and
the selected TestClient PID; starting another monitor for that same client is
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

Complete native paired build and compile/runtime checks, then run the original
BDR scenario with its existing assertions and command boundaries. Verify the
actual monitor start/stop UI, server and privileged-server commands, process
interruption, stale/foreign responses, two clients and two independent channels.
The busy-clipboard and competing-consumer OneScript regressions are protocol
evidence; they do not establish live 1C acceptance.

Requests, responses and claims are currently retained as recovery evidence.
Do not remove a claim while its request may still be consumed, delete a shared
monitor root, or reset unresolved context to force a repeat. Automatic scoped
cleanup must first prove the owning consumer has stopped, retain the operation
outcome in run artifacts and remove only that generation's files. Cleanup and
restart reconciliation, installed authoring guidance and normal delivery remain
open parts of item 10; no candidate completion is claimed by this document.
