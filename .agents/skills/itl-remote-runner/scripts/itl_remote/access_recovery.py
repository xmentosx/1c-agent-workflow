"""Exclusive crash reconciliation; admission is never a recovery side effect.

The coordinator owns exclusion and fencing. An operation-specific Python
adapter owns live verification of stopped work and restoration. There is no
CLI accepting a user-written success record or automatically replaying cleanup.
"""
from __future__ import annotations

import copy
from dataclasses import dataclass
import os
import platform
import re
import secrets
import time
import uuid

from .access import Coordinator, public
from .common import FileLock, WorkError, identity, stamp


def _record(coordinator, ticket):
    if not isinstance(ticket, str) or not re.fullmatch(r"[0-9a-f]{32}", ticket):
        raise WorkError("INFOBASE_ACCESS_RECOVERY_TICKET_INVALID")
    for record in coordinator.records():
        if record["ticket"] == ticket:
            return record
    raise WorkError("INFOBASE_ACCESS_RECOVERY_TICKET_MISSING")


def _eligible(coordinator, record):
    if record["status"] not in ("running", "recovering", "needs-attention"):
        raise WorkError("INFOBASE_ACCESS_RECOVERY_NOT_REQUIRED")
    if coordinator.alive(record["ticket"]):
        raise WorkError("INFOBASE_ACCESS_RECOVERY_OWNER_LIVE")


def plan(root, ticket):
    """Read-only inspection; the revision is compared again at exclusive claim."""
    coordinator = Coordinator(root)
    with coordinator.mutex(time.monotonic() + 30, lambda: False):
        record = _record(coordinator, ticket)
        _eligible(coordinator, record)
        return {"schemaVersion": 1, "coordinator": str(coordinator.root),
                "ticket": ticket, "revision": identity(record),
                "operation": public(record),
                "requirements": ["verify-owned-work-stopped", "verify-restoration-complete"],
                "automaticReplay": False}


@dataclass(frozen=True)
class VerifiedRecovery:
    """Return value of a trusted live verifier, not a serialized approval input.

The adapter must inspect every resource and retain the observations establishing
both quiescence and restoration. Resources with nothing to restore still need
evidence of why the original operation had no outstanding restoration duty.
"""
    resources: tuple[str, ...]
    evidence: dict


class Recovery:
    def __init__(self, root, ticket, revision, owner, *, cancelled=lambda: False):
        self.coordinator = Coordinator(root)
        self.ticket, self.revision = ticket, revision
        self.owner, self.cancelled = owner, cancelled
        self.record = None
        self.live_lock = None
        self.attempt = None
        self.completed = False

    def __enter__(self):
        try:
            with self.coordinator.mutex(time.monotonic() + 30, self.cancelled):
                record = _record(self.coordinator, self.ticket)
                if identity(record) != self.revision:
                    raise WorkError("INFOBASE_ACCESS_RECOVERY_PLAN_STALE")
                _eligible(self.coordinator, record)
                self.live_lock = FileLock(self.coordinator.root / "tickets" / (self.ticket + ".alive"))
                self.live_lock.__enter__()
                attempts = record.setdefault("recoveryAttempts", [])
                if record["status"] == "recovering":
                    attempts[-1].update(status="interrupted", finishedAt=stamp())
                self.attempt = uuid.uuid4().hex
                attempts.append({"id": self.attempt, "status": "running", "startedAt": stamp(),
                                 "previousRevision": self.revision, "previousStatus": record["status"],
                                 "previousReason": record.get("reason"),
                                 "owner": {**self.owner, "host": platform.node(), "pid": os.getpid()}})
                # Keep the original ticket, sequence and complete resource set.
                # Old inherited proofs must never authorize recovery or replay.
                record.update(status="recovering", token=secrets.token_hex(32), reason="recovery-in-progress")
                self.record = record
                self.coordinator.save(record)
            return self
        except BaseException:
            self._close()
            raise

    def _current(self):
        if not self.live_lock or self.completed:
            raise WorkError("INFOBASE_ACCESS_RECOVERY_NOT_OWNED")
        record = _record(self.coordinator, self.ticket)
        if (record["status"] != "recovering" or record["token"] != self.record["token"] or
                record.get("recoveryAttempts", [{}])[-1].get("id") != self.attempt or
                record["resources"] != self.record["resources"]):
            raise WorkError("INFOBASE_ACCESS_RECOVERY_OWNERSHIP_CHANGED")
        return record

    def complete(self, verify):
        """Invoke an operation adapter now, under ownership; never trust a flag.

        The callback may diagnose or complete authorized restoration, but must
        not replay the original workload. Failure preserves needs-attention.
        No allocator lock is held while the adapter talks to the database.
        """
        with self.coordinator.mutex(time.monotonic() + 30, self.cancelled):
            record = self._current()
        proof = verify(copy.deepcopy(public(record)))
        if (not isinstance(proof, VerifiedRecovery) or not isinstance(proof.resources, tuple) or
                len(proof.resources) != len(set(proof.resources)) or
                set(proof.resources) != set(record["resources"]) or
                not isinstance(proof.evidence, dict) or not proof.evidence):
            raise WorkError("INFOBASE_ACCESS_RECOVERY_VERIFICATION_INVALID")
        # Serialize before changing status; an invalid evidence object cannot
        # produce a successful release. Retain an independent immutable value.
        evidence = copy.deepcopy(proof.evidence)
        evidence_hash = identity(evidence)
        with self.coordinator.mutex(time.monotonic() + 30, self.cancelled):
            record = self._current()
            record["recoveryAttempts"][-1].update(status="completed", finishedAt=stamp(),
                                                  evidence=evidence, evidenceSha256=evidence_hash)
            record.update(status="released", finishedAt=stamp(), reason="recovery-verified")
            self.coordinator.save(record)
            self.record = record
            self.completed = True
        self._close()
        return public(record)

    def _close(self):
        if self.live_lock:
            self.live_lock.__exit__(None, None, None)
            self.live_lock = None

    def __exit__(self, kind, value, traceback):
        try:
            if self.live_lock and not self.completed:
                with self.coordinator.mutex(time.monotonic() + 30, lambda: False):
                    record = self._current()
                    record["recoveryAttempts"][-1].update(
                        status="failed" if kind else "incomplete", finishedAt=stamp())
                    record.update(status="needs-attention", reason="recovery-unproven")
                    self.coordinator.save(record)
        finally:
            self._close()
