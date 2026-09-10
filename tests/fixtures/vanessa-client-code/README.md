# Correlated Vanessa file-code regression

`source.json` identifies the exact 1.2.043.28 upstream commit and source paths.
The receiver is the complete verbatim upstream module; the producer excerpt
includes its complete original function and the context needed by the shipping
hunks. Exact excerpt boundaries and hashes are recorded in `source.json`.
SHA checks run before applying the actual r11 and r12 shipping patch hunks.

The original producer returns success without sending anything when no monitor
or no monitor for the selected TestClient exists. The original receiver consumes
the request but emits no reply for void success or a thrown client-code error.
These original failures are exercised, not inferred from text assertions.
For that receiver the test selects its Windows thin-client preprocessor branch;
the BSL body remains unchanged. A JSON helper and Vanessa UI continuation double
replace only framework calls. OneScript performs actual Execute, JSON, native
filesystem I/O and exclusive CreateNew claims. The revised producer and receiver
are extracted after applying the shipping hunks; no separately rewritten protocol
implementation is used as the test target.

Paths contain Cyrillic and whitespace together, and an ancestor contains `Event`
to expose accidental whole-path Event/Result substitution. Separate native
processes compete for one request, then a new consumer retries after loss of the
response; only one execution marker may exist. Another regression holds Windows
OpenClipboard while the file command runs. It never reads or changes clipboard
contents and releases the handle in finally.

This is executable protocol evidence, not proof of an installed 1C TestClient,
monitor form UI, server execution or cleanup after an interrupted live scenario.
The r12 cases reproduce the r11 misrouting when two selected profiles have PID 0,
then exercise connection identity, PID changes, missing identity, foreign waits,
and a selection change after starting the actual asynchronous wait. Only timer
registration is replaced; the production start and callback functions execute.
Native paired EPF/CFE qualification and the original BDR acceptance remain needed.
Upstream code is BSD-3-Clause; see the r11 asset's LICENSE.upstream.
