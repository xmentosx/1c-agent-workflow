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


def participants(record):
    entries = record.get("participants", {})
    if (not isinstance(entries, dict) or any(
            not isinstance(key, str) or not re.fullmatch(r"[0-9a-f]{32}", key) or not isinstance(value, dict) or
            value.get("status") not in ("active", "uncertain") or
            not re.fullmatch(r"[0-9a-f]{64}", str(value.get("generation", ""))) or
            not isinstance(value.get("resources"), list) or
            any(not isinstance(resource, str) for resource in value["resources"]) or
            not set(value["resources"]) <= set(record["resources"])
            for key, value in entries.items())):
        raise WorkError("INFOBASE_ACCESS_PARTICIPANTS_INVALID")
    return entries


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
            participants(record)
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


def public(record, *, include_native_journal=True):
    return {key: value for key, value in record.items() if key != "token" and (include_native_journal or key != "nativeJournal")}


def inheritance_token(record):
    if record.get("participantProtocol") != 1:
        raise WorkError("INFOBASE_ACCESS_INHERITANCE_PROTOCOL_UNSUPPORTED")
    # Legacy children compare the supplied token directly to record['token'].
    # A domain-separated proof makes them reject admission rather than silently
    # borrowing without registering their native work. Do not expose this proof
    # in the public ticket or derive it from the public participant generation.
    return identity({"protocol": "itl-database-participants-v1", "secret": record["token"]})


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
        self.participant_id = None
        self.release_status = None

    def __enter__(self):
        deadline = self.started + self.timeout
        try:
            with self.coordinator.mutex(deadline, self.cancelled):
                resources = self.coordinator.resources(self.bases)
                if self.inherited:
                    self._inherit(resources)
                    self.participant_id = uuid.uuid4().hex
                    self.record.setdefault("participants", {})[self.participant_id] = {
                        "status": "active", "generation": identity(self.record["token"]),
                        "resources": resources, "admittedAt": stamp(),
                        "owner": {**self.owner, "host": platform.node(), "pid": os.getpid()}}
                    self.coordinator.save(self.record)
                    return self
                records = self.coordinator.records()
                ticket = uuid.uuid4().hex
                self.live_lock = FileLock(self.coordinator.root / "tickets" / (ticket + ".alive"))
                self.live_lock.__enter__()
                self.record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket, "token": secrets.token_hex(32),
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
                            blockers.append(public(record, include_native_journal=False))
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
                not secrets.compare_digest(inheritance_token(record), self.inherited.get("token", "")) or
                not set(resources) <= set(record["resources"]) or not self.coordinator.alive(ticket)):
            raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
        participants(record)
        self.record = record

    def proof(self):
        return {"coordinator": str(self.coordinator.root), "ticket": self.record["ticket"],
                "token": inheritance_token(self.record), **({"purpose": "recovery"} if self.purpose == "recovery" else {})}

    def validate(self):
        """Check the current fencing authority without creating a work participant."""
        if self.record is None or self.release_status is not None:
            raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
        with self.coordinator.mutex(time.monotonic() + 30, self.cancelled):
            current = read_json(self.coordinator.root / "tickets" / (self.record["ticket"] + ".json"))
            expected = "recovering" if self.purpose == "recovery" else "running"
            if (current["status"] != expected or current["token"] != self.record["token"] or
                    not self.coordinator.alive(current["ticket"]) or
                    not set(self.coordinator.resources(self.bases)) <= set(current["resources"])):
                raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
            entries = participants(current)
            if self.participant_id and entries.get(self.participant_id, {}).get("status") != "active":
                raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
            self.record = current

    def release(self, *, cleanup_errors=()):
        if self.inherited:
            if self.participant_id is None:
                return self.release_status
            try:
                with self.coordinator.mutex(time.monotonic() + 30, lambda: False):
                    current = read_json(self.coordinator.root / "tickets" / (self.record["ticket"] + ".json"))
                    if current["token"] != self.record["token"] or current["status"] not in ("running", "recovering", "needs-attention"):
                        raise WorkError("INFOBASE_ACCESS_RELEASE_OWNERSHIP_CHANGED")
                    entries = participants(current)
                    if self.participant_id not in entries:
                        raise WorkError("INFOBASE_ACCESS_RELEASE_OWNERSHIP_CHANGED")
                    if cleanup_errors:
                        entries[self.participant_id].update(status="uncertain", finishedAt=stamp(), reason="cleanup-unproven")
                    else:
                        del entries[self.participant_id]
                    self.coordinator.save(current)
                    self.record = current
                    self.release_status = "needs-attention" if cleanup_errors else "released"
                    return self.release_status
            finally:
                self.participant_id = None
        if not self.live_lock:
            return self.release_status
        try:
            with self.coordinator.mutex(time.monotonic() + 30, lambda: False):
                current = read_json(self.coordinator.root / "tickets" / (self.record["ticket"] + ".json"))
                if (current.get("status") != "running" or
                        current.get("token") != self.record["token"]):
                    raise WorkError("INFOBASE_ACCESS_RELEASE_OWNERSHIP_CHANGED")
                # Reload the authoritative record: children may have registered
                # or failed since this parent's last in-memory observation.
                self.record = current
                pending = participants(current)
                self.release_status = "needs-attention" if cleanup_errors or pending else "released"
                self.record.update(status=self.release_status, finishedAt=stamp())
                if cleanup_errors or pending:
                    self.record["reason"] = "nested-cleanup-unproven" if pending else "cleanup-unproven"
                self.coordinator.save(self.record)
                return self.release_status
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
