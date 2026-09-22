# Superseded database-admission contract

The ticket/coordinator, access-mode, retained-owner and generic recovery protocol
described by older releases is removed. Runtime code does not read or migrate its
tickets, indexes, waiters, pins, archives or recovery markers.

Use [execution ownership](execution-ownership.md) for the current
`execution-guards-v2` contract. Historical plans may still describe the removed
protocol; they are not operational instructions.
