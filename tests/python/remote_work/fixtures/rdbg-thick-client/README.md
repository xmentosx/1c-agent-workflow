# Thick-client discovery incident

Derived from the retained UFA `plan-card-20260909-03` response
`discovery/9dd6299ce0db48368896a3e78885b3ba/000003-getDbgTargets.response.xml`.
Original response SHA-256:
`42388d0abf75e8de38c96749fed649fc5335d7f706fcdd02277e26f9b214df9e`.
Only the observed session 47 is retained; its database alias is replaced with
`base` and the user name is omitted. Native target types, identifiers, session
and database-instance relationships remain unchanged. The executable was
`1cv8.exe` 8.3.27.2074; the response contains one `Client` and one `Server`.
The subsequent `plan-card-20260909-04` used `1cv8c.exe` and succeeded, which
diagnosed the unsupported client family rather than a genuinely ambiguous owner.
This is discovery evidence, not a successful thick-client profile capture.
