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

## 1.2.043.42 listening sockets (`listeners-*`)

`listeners-source.json` pins the verbatim 1.2.043.42 text of
`ПроверитьПортНаЗанятость` (КлиентТестирования) and `ПолучитьМассивЗанятыхПортов`
(ОбщегоНазначенияVA) at commit `a0ce2ee`, with three lines of surrounding
context so the recipe hunks apply. The test applies the hunks of a recipe, runs
every complete patched method in OneScript and simulates only `netstat -ano`
and `ss -ltn` through `listeners-vanessa.os`.

Upstream took the local port of every netstat row in any state, and on Linux
every `ss -tuwan4` socket. With the r11 allocator this rejected the assigned
port of a TestClient closed a moment earlier with `ITL_TESTCLIENT_NO_FREE_PORT`
(PM5 branch 1-branch4); `baseline-time-wait` reproduces that with the r11 recipe.
From r12 only a TCP row with the unspecified foreign address `0.0.0.0:0` or
`[::]:0` (any system language) or an `ss -ltn` LISTEN row occupies a port:
TIME_WAIT, ESTABLISHED, CLOSE_WAIT and UDP rows of the port stay free, while
IPv4, IPv6 and localized LISTENING rows stay busy.
