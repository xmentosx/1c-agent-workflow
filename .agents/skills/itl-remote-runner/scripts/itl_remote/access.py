"""Database admission protocol: one configured filesystem authority, no TTL stealing.

The authority may be an SMB directory shared by execution hosts. OS byte locks
protect the allocator and each live ticket. A released OS lock alone never
proves that a crashed operation's database side effects have stopped.
"""
from __future__ import annotations

import contextlib
import math
import os
from pathlib import Path
import platform
import re
import secrets
import time
import uuid

from .common import FileLock, WorkError, identity, read_json, stamp, write_json


def binding(base):
    kind = base.get("kind", "")
    value = str(base.get("path", "")).strip()
    if kind not in ("file", "server", "workspace") or not value:
        raise WorkError("INFOBASE_ACCESS_IDENTITY_REQUIRED")
    if kind == "server":
        value = value.replace("\\", "/").rstrip("/").casefold()
        return "server|" + value
    value = os.path.normcase(os.path.realpath(value)).replace("\\", "/")
    if os.name == "nt":
        value = value.casefold()
    host = "" if value.startswith("//") else str(base.get("host", platform.node())).casefold()
    return kind + "|" + host + "|" + value.rstrip("/")


def resource_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}", value):
        raise WorkError("INFOBASE_ACCESS_RESOURCE_ID_INVALID")
    return value


def busy(error):
    return isinstance(error, WorkError) and str(error).startswith("OWNER_BUSY:")


class Coordinator:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "tickets").mkdir(exist_ok=True)

    @contextlib.contextmanager
    def mutex(self, deadline, cancelled):
        lock = FileLock(self.root / "allocator.lock")
        while True:
            if cancelled():
                raise WorkError("INFOBASE_ACCESS_CANCELLED")
            try:
                lock.__enter__()
                break
            except WorkError as error:
                if not busy(error):
                    raise
                if time.monotonic() >= deadline:
                    raise WorkError("INFOBASE_ACCESS_WAIT_TIMEOUT") from error
                time.sleep(0.05)
        try:
            yield
        finally:
            lock.__exit__(None, None, None)

    def records(self):
        records = []
        for path in (self.root / "tickets").glob("*.json"):
            record = read_json(path)
            if (record.get("schemaVersion") != 1 or record.get("ticket") != path.stem or
                    record.get("status") not in ("waiting", "running", "recovering", "released", "cancelled", "needs-attention") or
                    type(record.get("sequence")) is not int or not isinstance(record.get("resources"), list)):
                raise WorkError("INFOBASE_ACCESS_RECORD_INVALID: " + str(path))
            if record["status"] == "recovering":
                attempts = record.get("recoveryAttempts")
                if (not isinstance(attempts, list) or not attempts or not isinstance(attempts[-1], dict) or
                        attempts[-1].get("status") != "running" or not attempts[-1].get("id")):
                    raise WorkError("INFOBASE_ACCESS_RECORD_INVALID: " + str(path))
            records.append(record)
        return sorted(records, key=lambda item: item["sequence"])

    def save(self, record):
        write_json(self.root / "tickets" / (record["ticket"] + ".json"), record)

    def alive(self, ticket):
        try:
            with FileLock(self.root / "tickets" / (ticket + ".alive")):
                return False
        except WorkError as error:
            if busy(error):
                return True
            raise

    def register(self, name, bases):
        """Explicitly associate alternate connections; conflicting claims fail closed."""
        name = resource_id(name)
        keys = [binding(base) for base in bases]
        if not keys:
            raise WorkError("INFOBASE_ACCESS_BINDINGS_REQUIRED")
        with self.mutex(time.monotonic() + 30, lambda: False):
            path = self.root / "resources.json"
            registry = read_json(path) if path.exists() else {"schemaVersion": 1, "bindings": {}}
            if registry.get("schemaVersion") != 1:
                raise WorkError("INFOBASE_ACCESS_REGISTRY_INVALID")
            for key in keys:
                previous = registry["bindings"].get(key)
                if previous and previous != name:
                    raise WorkError("INFOBASE_ACCESS_BINDING_CONFLICT: " + key)
            # Changing a default identity while a ticket is queued/running would
            # create two independent queues for the very same database.
            affected = {"base-" + identity(key) for key in keys}
            for record in self.records():
                if record["status"] in ("waiting", "running", "recovering", "needs-attention") and affected.intersection(record["resources"]):
                    raise WorkError("INFOBASE_ACCESS_REGISTRATION_BUSY")
            registry["bindings"].update({key: name for key in keys})
            write_json(path, registry)
        return {"resourceId": name, "bindings": keys}

    def resources(self, bases):
        path = self.root / "resources.json"
        registry = read_json(path) if path.exists() else {"schemaVersion": 1, "bindings": {}}
        if registry.get("schemaVersion") != 1:
            raise WorkError("INFOBASE_ACCESS_REGISTRY_INVALID")
        return sorted({resource_id(registry["bindings"].get(binding(base), "base-" + identity(binding(base)))) for base in bases})

    def snapshot(self):
        with self.mutex(time.monotonic() + 30, lambda: False):
            return [public(record) for record in self.records() if record["status"] in ("waiting", "running", "recovering", "needs-attention")]


def public(record):
    return {key: value for key, value in record.items() if key != "token"}


class Lease:
    def __init__(self, coordinator, bases, owner, *, timeout=3600, cancelled=lambda: False,
                 progress=lambda record: None, inherited=None, purpose="operation"):
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or not 0 <= timeout <= 86400:
            raise WorkError("INFOBASE_ACCESS_TIMEOUT_INVALID")
        if not bases:
            raise WorkError("INFOBASE_ACCESS_IDENTITY_REQUIRED")
        if purpose not in ("operation", "recovery") or (purpose == "recovery" and not inherited):
            raise WorkError("INFOBASE_ACCESS_PURPOSE_INVALID")
        self.coordinator = Coordinator(coordinator)
        self.bases, self.owner = bases, owner
        self.timeout, self.cancelled, self.progress = timeout, cancelled, progress
        self.inherited = inherited
        self.purpose = purpose
        self.record = None
        self.live_lock = None
        self.started = time.monotonic()
        self.wait_seconds = 0

    def __enter__(self):
        deadline = self.started + self.timeout
        try:
            with self.coordinator.mutex(deadline, self.cancelled):
                resources = self.coordinator.resources(self.bases)
                if self.inherited:
                    self._inherit(resources)
                    return self
                records = self.coordinator.records()
                ticket = uuid.uuid4().hex
                self.live_lock = FileLock(self.coordinator.root / "tickets" / (ticket + ".alive"))
                self.live_lock.__enter__()
                self.record = {"schemaVersion": 1, "ticket": ticket, "token": secrets.token_hex(32),
                               "sequence": max((r["sequence"] for r in records), default=0) + 1,
                               "resources": resources, "status": "waiting", "createdAt": stamp(),
                               "owner": {**self.owner, "host": platform.node(), "pid": os.getpid()}}
                self.coordinator.save(self.record)
            while True:
                with self.coordinator.mutex(deadline, self.cancelled):
                    blockers = []
                    # Process records in sequence order, allowing unrelated bases
                    # to proceed without holding any subset of the requested set.
                    for record in self.coordinator.records():
                        if record["ticket"] == self.record["ticket"] or record["status"] in ("released", "cancelled"):
                            continue
                        if not set(resources).intersection(record["resources"]):
                            continue
                        if record["status"] == "waiting" and not self.coordinator.alive(record["ticket"]):
                            record.update(status="cancelled", finishedAt=stamp(), reason="waiter-exited-before-admission")
                            self.coordinator.save(record)
                            continue
                        if record["status"] in ("running", "recovering") and not self.coordinator.alive(record["ticket"]):
                            if record["status"] == "recovering":
                                record["recoveryAttempts"][-1].update(status="interrupted", finishedAt=stamp())
                            record.update(status="needs-attention", reason="owner-exited; inspect surviving work and restoration")
                            self.coordinator.save(record)
                        if record["status"] == "needs-attention":
                            raise WorkError("INFOBASE_ACCESS_RECOVERY_REQUIRED: " + record["ticket"])
                        if record["status"] in ("running", "recovering") or record["sequence"] < self.record["sequence"]:
                            blockers.append(public(record))
                    if not blockers:
                        self.record.update(status="running", admittedAt=stamp())
                        self.coordinator.save(self.record)
                        self.wait_seconds = time.monotonic() - self.started
                        return self
                self.progress({"status": "waiting-for-base", "ticket": self.record["ticket"],
                               "resources": resources, "waitSeconds": time.monotonic() - self.started,
                               "blockers": blockers})
                if time.monotonic() >= deadline:
                    raise WorkError("INFOBASE_ACCESS_WAIT_TIMEOUT")
                time.sleep(0.05)
        except BaseException:
            # Admission errors never mean that database work ran. A record which
            # reached running is retained if the admission write was uncertain.
            try:
                if self.record and self.record["status"] == "waiting":
                    self.record.update(status="cancelled", finishedAt=stamp())
                    with self.coordinator.mutex(time.monotonic() + 10, lambda: False):
                        self.coordinator.save(self.record)
            finally:
                if self.live_lock:
                    self.live_lock.__exit__(None, None, None)
                    self.live_lock = None
            raise

    def _inherit(self, resources):
        ticket = self.inherited.get("ticket", "")
        if (not re.fullmatch(r"[0-9a-f]{32}", ticket) or
                Path(self.inherited.get("coordinator", "")).resolve() != self.coordinator.root):
            raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
        record = read_json(self.coordinator.root / "tickets" / (ticket + ".json"))
        expected_status = "recovering" if self.purpose == "recovery" else "running"
        if (record["status"] != expected_status or self.inherited.get("purpose", "operation") != self.purpose or
                not secrets.compare_digest(record["token"], self.inherited.get("token", "")) or
                not set(resources) <= set(record["resources"]) or not self.coordinator.alive(ticket)):
            raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
        self.record = record

    def proof(self):
        return {"coordinator": str(self.coordinator.root), "ticket": self.record["ticket"],
                "token": self.record["token"], **({"purpose": "recovery"} if self.purpose == "recovery" else {})}

    def release(self, *, cleanup_errors=()):
        if self.inherited or not self.live_lock:
            return
        try:
            with self.coordinator.mutex(time.monotonic() + 30, lambda: False):
                current = read_json(self.coordinator.root / "tickets" / (self.record["ticket"] + ".json"))
                if (current.get("status") != "running" or
                        current.get("token") != self.record["token"]):
                    raise WorkError("INFOBASE_ACCESS_RELEASE_OWNERSHIP_CHANGED")
                self.record.update(status="needs-attention" if cleanup_errors else "released", finishedAt=stamp())
                if cleanup_errors:
                    self.record["reason"] = "cleanup-unproven"
                self.coordinator.save(self.record)
        finally:
            self.live_lock.__exit__(None, None, None)
            self.live_lock = None

    def __exit__(self, kind, value, traceback):
        self.release(cleanup_errors=["unhandled operation failure"] if kind else [])


def target_access(target):
    import tempfile
    access = target.get("access", {})
    root = access.get("coordinator") or os.environ.get("ITL_INFOBASE_ACCESS_ROOT")
    scope = "configured-authority" if root else "execution-host-only"
    if not root:
        root = str(Path(os.environ.get("PROGRAMDATA", tempfile.gettempdir())) / "ITL" / "infobase-access")
    bases = [target.get("infoBase", {"kind": "workspace", "path": target["workspace"]})]
    manager = target.get("vanessa", {}).get("managerBase")
    if manager:
        bases.append(manager)
    bases.extend(access.get("additionalBases", []))
    return {"coordinator": root, "bases": bases, "timeout": access.get("waitTimeoutSeconds", 3600), "scope": scope}
