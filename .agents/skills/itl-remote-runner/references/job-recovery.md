# Superseded generic job recovery

The coordinator-backed `recovery-plan`, `recover` and `recovery-cancel` routes
were removed with the legacy database-ticket protocol. A failed or interrupted
job is not replayed and does not block a later independent command.

Use job status, cancellation, partial collection and operation-specific product
repair tools. Current execution and cleanup rules are documented in
[execution ownership](execution-ownership.md).
