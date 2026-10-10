# Original PM5 initialization duration recovered — 2026-10-02

The successful original public `initialize-dev-branch-runtime` continuation
took **85.0062262 seconds**, exit 0. This is the command execution's monotonic
duration, `secs=85`, `nanos=6226200`, not the later polling-call duration.
Its timestamp interval is 2026-09-30T19:40:01.823Z–19:41:26.830Z.

The executing subagent retained the primary record in
`C:\Users\xment\.codex\sessions\2026\09\30\rollout-2026-09-30T19-02-40-01a0f30d-c0ce-7d22-afd3-df424b5ec7bf.jsonl`:
line 2489 has the original public command, 2491 the initial session 49284,
2500 the completed command event, and 2504 the final exit-0 poll receipt.
The event is `exec-3d9c7b9a-71d7-454b-95c9-b9a9cfa96cb1`.

The root independently read those exact records and checked the command,
session, completion, native run `51f5bed0c95345078b7bbf9ff6100e89`, and the
original acceptance record's ready/passed outcome. The bounded raw records
are frozen in `build/original-pm5-init-duration-recovered-20261002/raw-events.json`,
SHA256 `2233152edfddac74f60bca7cce45e02d7738432de2bf21c4926382936781aa62`.
The independent `qualification.json` in that directory has SHA256
`fbaeb0f567692fc61d3ee64a6ac0949cac245eef532bbd00dd96301f2d48ebd2`.
Original acceptance SHA256 is
`4d6abf622e2f20255d22a7a7b781e8502d4991cb62c130faf59b9d1c71ea72d3`.

This covers the whole successful public continuation on the existing PM5
copy, including helper preparation, MCP setup, event baseline, native
normalization and cleanup. It excludes the preceding failed r33 invocation,
seed preparation and infobase copy. It is not a fresh cold-bootstrap benchmark
or a before/after performance comparison. The 73.871-second native file-write
window remains a separate observation and is not substituted for this duration.

No helper, initialization, provider, native process or gate was rerun to obtain
this measurement. Existing successful functional acceptance remains unchanged.
