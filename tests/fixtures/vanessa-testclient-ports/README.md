# TestClient port allocation reproduction

The two verbatim upstream functions are pinned by commit, source path, line
bounds and SHA-256 in `source.json`. Tests apply the shipping r12 patch hunks
before executing the actual allocator and occupied-port parser in OneScript.
Only the native command boundary supplies controlled Windows netstat output;
the parser, profile reservation filtering and allocation decisions execute.

The baseline reproduces returning client A's occupied port when launching B
with two assigned profiles and a two-port range. Corrected cases retain B's
free assigned port, respect another profile's reservation, reject a real
listener and fail explicitly when the range is exhausted. No profile or
range is removed to avoid the original failure.

The native counterpart is the retained two-database run `probe-c0865302`:
both profiles were assigned distinct ports, but the log recorded connecting
both to the first port. B's unchanged connection assertion failed with
`ITL_CLIENT_B_WRONG_DATABASE`. These fixtures do not themselves prove native
candidate acceptance. Upstream code is BSD-3-Clause; see the candidate asset's
`LICENSE.upstream`.
