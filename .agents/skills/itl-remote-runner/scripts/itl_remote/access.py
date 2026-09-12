"""Database admission protocol: one configured filesystem authority, no TTL stealing.

The authority may be an SMB directory shared by execution hosts. OS byte locks
protect the allocator and each live ticket. A released OS lock alone never
proves that a crashed operation's database side effects have stopped.
"""
from __future__ import annotations

import contextlib
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import platform
import re
import secrets
import time
import uuid

from .common import FileLock, WorkError, identity, read_json, stamp, write_json


DEFAULT_RECOVERY_HORIZON_DAYS = 90
DEFAULT_TOMBSTONE_RETENTION_DAYS = 730
DEFAULT_COMPACTION_BATCH_SIZE = 128


def admission_error(code, coordinator, blockers, elapsed):
    """Keep the terminal error actionable even when progress output is hidden."""
    details = {"coordinator": str(coordinator.root), "waitSeconds": round(elapsed, 3),
               "blockers": [], "requestExecuted": False}
    for record in blockers:
        recovery = record["status"] == "needs-attention" and not record.get("corruptRecord")
        details["blockers"].append({
            "ticket": record["ticket"], "status": record["status"],
            "owner": {key: record.get("owner", {})[key] for key in
                      ("project", "workspace", "operation", "jobId", "threadId", "host", "pid", "parentPid")
                      if key in record.get("owner", {})},
            "reason": record.get("reason", "owner has not released database access"),
            "nextAction": (
                {"command": "access-recovery-plan", "coordinator": str(coordinator.root),
                 "ticket": record["ticket"]} if recovery else
                {"command": "access-status", "coordinator": str(coordinator.root),
                 "instruction": ("repair the indexed ticket record before retrying" if record.get("corruptRecord") else
                                 "inspect the owner on its host; cancel through its owning helper if stuck; retry after verified release")})})
    return WorkError(code + ": " + json.dumps(details, ensure_ascii=True))


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
            value.get("accessMode", "exclusive") not in ACCESS_MODES or
            any(not isinstance(resource, str) for resource in value["resources"]) or
            not set(value["resources"]) <= set(record["resources"])
            for key, value in entries.items())):
        raise WorkError("INFOBASE_ACCESS_PARTICIPANTS_INVALID")
    return entries


class Coordinator:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.tickets = self.root / "tickets"
        self.tickets.mkdir(exist_ok=True)
        self.layout_path = self.tickets / "layout.json"
        self.index_path = self.root / "active-index.json"
        self.archive_root = self.root / "ticket-archive"
        self.cleanup_debt_path = self.root / "cleanup-debt.json"
        self.retention_path = self.root / "archive-retention.json"
        self.compaction_path = self.root / "archive-compaction.json"
        self.pins_path = self.root / "archive-pins.json"

    def _published(self, boundary):
        """Fault-injection seam after durable publication boundaries."""

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
            self._ensure_layout_locked()
            if self._layout_v2():
                self._run_cleanup_locked(limit=8)
            yield
        finally:
            lock.__exit__(None, None, None)

    def _validate_record(self, record, path):
        if (not isinstance(record, dict) or record.get("schemaVersion") != 1 or
                record.get("ticket") != path.stem or
                record.get("status") not in ACTIVE_STATUSES + TERMINAL_STATUSES or
                type(record.get("sequence")) is not int or record["sequence"] < 1 or
                not isinstance(record.get("resources"), list) or not record["resources"] or
                any(not isinstance(resource, str) for resource in record["resources"])):
            raise WorkError("INFOBASE_ACCESS_RECORD_INVALID: " + str(path))
        if record["status"] == "recovering":
            attempts = record.get("recoveryAttempts")
            if (not isinstance(attempts, list) or not attempts or not isinstance(attempts[-1], dict) or
                    attempts[-1].get("status") != "running" or not attempts[-1].get("id")):
                raise WorkError("INFOBASE_ACCESS_RECORD_INVALID: " + str(path))
        participants(record)
        access_mode(record)
        effective_access_mode(record)
        return record

    def _legacy_records(self):
        records = []
        for path in self.tickets.glob("*.json"):
            try:
                records.append(self._validate_record(read_json(path), path))
            except Exception as error:
                if isinstance(error, WorkError):
                    raise
                raise WorkError("INFOBASE_ACCESS_RECORD_INVALID: " + str(path)) from error
        return sorted(records, key=lambda item: item["sequence"])

    def _layout_v2(self):
        if not self.layout_path.exists():
            return False
        try:
            value = read_json(self.layout_path)
        except Exception as error:
            raise WorkError("INFOBASE_ACCESS_LAYOUT_INVALID: " + str(self.layout_path)) from error
        if value != {"schemaVersion": 2}:
            raise WorkError("INFOBASE_ACCESS_LAYOUT_INVALID: " + str(self.layout_path))
        return True

    def _read_index(self):
        try:
            value = read_json(self.index_path)
        except Exception as error:
            raise WorkError("INFOBASE_ACCESS_INDEX_INVALID: " + str(self.index_path)) from error
        if not isinstance(value, dict):
            raise WorkError("INFOBASE_ACCESS_INDEX_INVALID: " + str(self.index_path))
        entries = value.get("entries")
        if (value.get("schemaVersion") != 2 or type(value.get("nextSequence")) is not int or
                value["nextSequence"] < 1 or not isinstance(entries, dict)):
            raise WorkError("INFOBASE_ACCESS_INDEX_INVALID: " + str(self.index_path))
        sequences = []
        for ticket, entry in entries.items():
            if (not re.fullmatch(r"[0-9a-f]{32}", ticket) or not isinstance(entry, dict) or
                    set(entry) != {"sequence", "resources"} or type(entry["sequence"]) is not int or
                    entry["sequence"] < 1 or not isinstance(entry["resources"], list) or
                    not entry["resources"] or entry["resources"] != sorted(set(entry["resources"])) or
                    any(not isinstance(resource, str) or
                        not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}", resource)
                        for resource in entry["resources"])):
                raise WorkError("INFOBASE_ACCESS_INDEX_INVALID: " + str(self.index_path))
            sequences.append(entry["sequence"])
        if len(sequences) != len(set(sequences)) or sequences and value["nextSequence"] <= max(sequences):
            raise WorkError("INFOBASE_ACCESS_INDEX_INVALID: " + str(self.index_path))
        return value

    def _read_cleanup_debt(self):
        if not self.cleanup_debt_path.exists():
            return {"schemaVersion": 1, "items": {}}
        try:
            value = read_json(self.cleanup_debt_path)
        except Exception as error:
            raise WorkError("INFOBASE_ACCESS_CLEANUP_DEBT_INVALID: " + str(self.cleanup_debt_path)) from error
        if not isinstance(value, dict):
            raise WorkError("INFOBASE_ACCESS_CLEANUP_DEBT_INVALID: " + str(self.cleanup_debt_path))
        items = value.get("items")
        if value.get("schemaVersion") != 1 or not isinstance(items, dict):
            raise WorkError("INFOBASE_ACCESS_CLEANUP_DEBT_INVALID: " + str(self.cleanup_debt_path))
        for key, item in items.items():
            if (not isinstance(key, str) or not isinstance(item, dict) or
                    item.get("kind") not in ("terminal-record", "alive-sidecar") or
                    not re.fullmatch(r"[0-9a-f]{32}", str(item.get("ticket", ""))) or
                    type(item.get("attempts")) is not int or item["attempts"] < 0 or
                    not isinstance(item.get("createdAt"), str) or
                    (item["kind"] == "terminal-record" and
                     not re.fullmatch(r"[0-9a-f]{64}", str(item.get("recordIdentity", ""))))):
                raise WorkError("INFOBASE_ACCESS_CLEANUP_DEBT_INVALID: " + str(self.cleanup_debt_path))
        return value

    def _schedule_cleanup_locked(self, records):
        debt = self._read_cleanup_debt()
        for record in records:
            ticket = record["ticket"]
            for kind in ("terminal-record", "alive-sidecar"):
                key = kind + "|" + ticket
                expected = {"kind": kind, "ticket": ticket, "attempts": 0, "createdAt": stamp()}
                if kind == "terminal-record":
                    expected["recordIdentity"] = identity(record)
                existing = debt["items"].get(key)
                if existing:
                    fields = ("kind", "ticket", "recordIdentity") if kind == "terminal-record" else ("kind", "ticket")
                    stable = {name: existing[name] for name in fields}
                    expected_stable = {name: expected[name] for name in fields}
                    if stable != expected_stable:
                        raise WorkError("INFOBASE_ACCESS_CLEANUP_DEBT_CONFLICT: " + ticket)
                    continue
                debt["items"][key] = expected
        write_json(self.cleanup_debt_path, debt)
        self._published("cleanup-debt")

    def _cleanup_item_locked(self, item):
        ticket = item["ticket"]
        if ticket in self._read_index()["entries"]:
            return False
        if item["kind"] == "terminal-record":
            path = self.tickets / (ticket + ".json")
            if not path.exists():
                return True
            try:
                record = self._validate_record(read_json(path), path)
            except Exception as error:
                raise WorkError("INFOBASE_ACCESS_CLEANUP_RECORD_INVALID: " + str(path)) from error
            if record["status"] not in TERMINAL_STATUSES or identity(record) != item["recordIdentity"]:
                raise WorkError("INFOBASE_ACCESS_CLEANUP_RECORD_CHANGED: " + str(path))
            path.unlink()
            self._published("cleanup-terminal-record")
            return True
        path = self.tickets / (ticket + ".alive")
        if not path.exists():
            return True
        lock = FileLock(path)
        lock.__enter__()
        lock.__exit__(None, None, None)
        path.unlink()
        self._published("cleanup-alive-sidecar")
        return True

    def _run_cleanup_locked(self, *, limit, ticket=None, retries=1):
        debt = self._read_cleanup_debt()
        selected = [(key, item) for key, item in debt["items"].items()
                    if ticket is None or item["ticket"] == ticket][:limit]
        changed = False
        for key, item in selected:
            completed = False
            last_error = None
            for attempt in range(retries):
                try:
                    completed = self._cleanup_item_locked(item)
                    break
                except (OSError, WorkError) as error:
                    last_error = error
                    if isinstance(error, WorkError) and not busy(error):
                        break
                    if attempt + 1 < retries:
                        time.sleep(0.05 * (attempt + 1))
            if completed:
                debt["items"].pop(key, None)
                changed = True
            elif last_error is not None:
                item["attempts"] += 1
                item["lastAttemptAt"] = stamp()
                item["lastError"] = str(last_error)
                changed = True
        if changed:
            write_json(self.cleanup_debt_path, debt)
        return {"remaining": len(debt["items"]), "attempted": len(selected)}

    def _archive_path(self, ticket):
        return self.archive_root / ticket[:2] / (ticket + ".json")

    def _retention_policy(self):
        value = (read_json(self.retention_path) if self.retention_path.exists() else
                 {"schemaVersion": 1, "recoveryHorizonDays": DEFAULT_RECOVERY_HORIZON_DAYS,
                  "tombstoneRetentionDays": DEFAULT_TOMBSTONE_RETENTION_DAYS,
                  "batchSize": DEFAULT_COMPACTION_BATCH_SIZE})
        return self._validate_retention(value)

    def _validate_retention(self, value):
        if (not isinstance(value, dict) or value.get("schemaVersion") != 1 or
                type(value.get("recoveryHorizonDays")) is not int or
                type(value.get("tombstoneRetentionDays")) is not int or
                type(value.get("batchSize")) is not int or
                not 1 <= value["recoveryHorizonDays"] <= 3650 or
                not value["recoveryHorizonDays"] <= value["tombstoneRetentionDays"] <= 3650 or
                not 1 <= value["batchSize"] <= 10000):
            raise WorkError("INFOBASE_ACCESS_RETENTION_INVALID: " + str(self.retention_path))
        return value

    def configure_retention(self, recovery_horizon_days, tombstone_retention_days, batch_size):
        value = {"schemaVersion": 1, "recoveryHorizonDays": recovery_horizon_days,
                 "tombstoneRetentionDays": tombstone_retention_days, "batchSize": batch_size}
        self._validate_retention(value)
        with self.mutex(time.monotonic() + 30, lambda: False):
            pins = self._read_pins()
            latest = datetime.now(timezone.utc) + timedelta(days=tombstone_retention_days)
            pins_changed = False
            for reasons in pins["entries"].values():
                for reason, expires_at in reasons.items():
                    if self._time(expires_at, "INFOBASE_ACCESS_PINS_INVALID", self.pins_path) > latest:
                        reasons[reason] = latest.isoformat()
                        pins_changed = True
            if pins_changed:
                write_json(self.pins_path, pins)
            write_json(self.retention_path, value)
            return value

    def _read_pins(self):
        value = read_json(self.pins_path) if self.pins_path.exists() else {"schemaVersion": 1, "entries": {}}
        entries = value.get("entries") if isinstance(value, dict) else None
        if not isinstance(value, dict) or value.get("schemaVersion") != 1 or not isinstance(entries, dict):
            raise WorkError("INFOBASE_ACCESS_PINS_INVALID: " + str(self.pins_path))
        for ticket, reasons in entries.items():
            if (not re.fullmatch(r"[0-9a-f]{32}", ticket) or not isinstance(reasons, dict) or not reasons or
                    any(not isinstance(reason, str) or not reason or len(reason) > 200 or
                        not isinstance(expires_at, str) for reason, expires_at in reasons.items())):
                raise WorkError("INFOBASE_ACCESS_PINS_INVALID: " + str(self.pins_path))
            for expires_at in reasons.values():
                self._time(expires_at, "INFOBASE_ACCESS_PINS_INVALID", self.pins_path)
        return value

    @staticmethod
    def _time(value, code, path):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except (AttributeError, TypeError, ValueError) as error:
            raise WorkError(code + ": " + str(path)) from error
        if parsed.tzinfo is None:
            raise WorkError(code + ": " + str(path))
        return parsed.astimezone(timezone.utc)

    def pin(self, ticket, reason, *, days=None):
        if not isinstance(ticket, str) or not re.fullmatch(r"[0-9a-f]{32}", ticket):
            raise WorkError("INFOBASE_ACCESS_TICKET_INVALID")
        if not isinstance(reason, str) or not reason or len(reason) > 200:
            raise WorkError("INFOBASE_ACCESS_PIN_REASON_INVALID")
        with self.mutex(time.monotonic() + 30, lambda: False):
            self.record(ticket)
            return self._pin_locked(ticket, reason, days=days)

    def _pin_locked(self, ticket, reason, *, days=None):
        policy = self._retention_policy()
        lifetime = policy["tombstoneRetentionDays"] if days is None else days
        if type(lifetime) is not int or not 1 <= lifetime <= policy["tombstoneRetentionDays"]:
            raise WorkError("INFOBASE_ACCESS_PIN_HORIZON_INVALID")
        pins = self._read_pins()
        expires = datetime.now(timezone.utc) + timedelta(days=lifetime)
        pins["entries"].setdefault(ticket, {})[reason] = expires.isoformat()
        write_json(self.pins_path, pins)
        return {"reason": reason, "expiresAt": pins["entries"][ticket][reason]}

    def unpin(self, ticket, reason=None):
        with self.mutex(time.monotonic() + 30, lambda: False):
            self._unpin_locked(ticket, reason)

    def _unpin_locked(self, ticket, reason=None):
        pins = self._read_pins()
        reasons = pins["entries"].get(ticket)
        if reasons is not None and reason is None:
            del pins["entries"][ticket]
            write_json(self.pins_path, pins)
        elif reasons is not None and reason in reasons:
            del reasons[reason]
            if not reasons:
                del pins["entries"][ticket]
            write_json(self.pins_path, pins)

    def _read_compaction_state(self):
        value = (read_json(self.compaction_path) if self.compaction_path.exists() else
                 {"schemaVersion": 1, "nextShard": 0, "afterTicket": ""})
        if (not isinstance(value, dict) or set(value) != {"schemaVersion", "nextShard", "afterTicket"} or
                value["schemaVersion"] != 1 or type(value["nextShard"]) is not int or
                not 0 <= value["nextShard"] <= 255 or not isinstance(value["afterTicket"], str) or
                (value["afterTicket"] and not re.fullmatch(r"[0-9a-f]{32}", value["afterTicket"]))):
            raise WorkError("INFOBASE_ACCESS_COMPACTION_INVALID: " + str(self.compaction_path))
        return value

    def _tombstone(self, value, path):
        if (not isinstance(value, dict) or set(value) != {"schemaVersion", "ticket", "status", "finishedAt",
                                                         "compactedAt", "recordIdentity"} or
                value["schemaVersion"] != 2 or value["ticket"] != path.stem or
                value["status"] not in TERMINAL_STATUSES or
                not re.fullmatch(r"[0-9a-f]{64}", str(value["recordIdentity"]))):
            raise WorkError("INFOBASE_ACCESS_ARCHIVE_INVALID: " + str(path))
        self._time(value["finishedAt"], "INFOBASE_ACCESS_ARCHIVE_INVALID", path)
        self._time(value["compactedAt"], "INFOBASE_ACCESS_ARCHIVE_INVALID", path)
        return value

    def _compact_locked(self, shards=1):
        if type(shards) is not int or not 1 <= shards <= 256:
            raise WorkError("INFOBASE_ACCESS_COMPACTION_SHARDS_INVALID")
        policy = self._retention_policy()
        state = self._read_compaction_state()
        pins = self._read_pins()
        debt_tickets = {item["ticket"] for item in self._read_cleanup_debt()["items"].values()}
        now = datetime.now(timezone.utc)
        pins_changed = False
        for ticket, reasons in list(pins["entries"].items()):
            for reason, expires_at in list(reasons.items()):
                if self._time(expires_at, "INFOBASE_ACCESS_PINS_INVALID", self.pins_path) <= now:
                    del reasons[reason]
                    pins_changed = True
            if not reasons:
                del pins["entries"][ticket]
        if pins_changed:
            write_json(self.pins_path, pins)
            self._published("compaction-pins")
        result = {"visited": 0, "compacted": 0, "deleted": 0, "pinned": 0, "shards": 0}
        for _ in range(shards):
            shard = state["nextShard"]
            directory = self.archive_root / f"{shard:02x}"
            paths = sorted(path for path in directory.glob("*.json")
                           if path.stem > state["afterTicket"]) if directory.exists() else []
            batch = paths[:policy["batchSize"]]
            for path in batch:
                result["visited"] += 1
                value = read_json(path)
                if isinstance(value, dict) and value.get("schemaVersion") == 2:
                    tombstone = self._tombstone(value, path)
                    if now - self._time(tombstone["compactedAt"], "INFOBASE_ACCESS_ARCHIVE_INVALID", path) >= timedelta(
                            days=policy["tombstoneRetentionDays"]):
                        path.unlink()
                        self._published("compaction-delete")
                        result["deleted"] += 1
                else:
                    record = self._validate_record(value, path)
                    if record["status"] not in TERMINAL_STATUSES:
                        raise WorkError("INFOBASE_ACCESS_ARCHIVE_INVALID: " + str(path))
                    if path.stem in pins["entries"] or path.stem in debt_tickets:
                        result["pinned"] += 1
                    elif now - self._time(record.get("finishedAt"), "INFOBASE_ACCESS_ARCHIVE_INVALID", path) >= timedelta(
                            days=policy["recoveryHorizonDays"]):
                        tombstone = {"schemaVersion": 2, "ticket": record["ticket"], "status": record["status"],
                                     "finishedAt": record["finishedAt"], "compactedAt": now.isoformat(),
                                     "recordIdentity": identity(record)}
                        write_json(path, tombstone)
                        self._published("compaction-tombstone")
                        result["compacted"] += 1
            if len(paths) > len(batch):
                state["afterTicket"] = batch[-1].stem
            else:
                state.update(nextShard=(shard + 1) % 256, afterTicket="")
            result["shards"] += 1
        write_json(self.compaction_path, state)
        self._published("compaction-state")
        result["nextShard"] = state["nextShard"]
        return result

    def compact(self, shards=1):
        with self.mutex(time.monotonic() + 30, lambda: False):
            return self._compact_locked(shards)

    def _archive_terminal(self, record):
        path = self._archive_path(record["ticket"])
        if path.exists():
            try:
                existing = self._validate_record(read_json(path), path)
            except Exception as error:
                if isinstance(error, WorkError):
                    raise
                raise WorkError("INFOBASE_ACCESS_ARCHIVE_INVALID: " + str(path)) from error
            if existing != record:
                raise WorkError("INFOBASE_ACCESS_ARCHIVE_CONFLICT: " + str(path))
        else:
            write_json(path, record)

    def _ensure_layout_locked(self):
        if self._layout_v2():
            self._repair_terminal_transitions_locked()
            return
        records = self._legacy_records()
        # A legacy process updates its per-ticket JSON directly. Switching the
        # authority while it is live would split one queue into two writers.
        if any(record["status"] in ("waiting", "running", "recovering") and
               self.alive(record["ticket"]) for record in records):
            return
        entries = {}
        terminal = []
        for record in records:
            if record["status"] in TERMINAL_STATUSES:
                self._archive_terminal(record)
                self._published("migration-terminal-archive")
                terminal.append(record)
            else:
                entries[record["ticket"]] = {"sequence": record["sequence"],
                                              "resources": record["resources"]}
        if terminal:
            self._schedule_cleanup_locked(terminal)
        write_json(self.index_path, {"schemaVersion": 2,
                                     "nextSequence": max((r["sequence"] for r in records), default=0) + 1,
                                     "entries": entries})
        self._published("migration-active-index")
        # Publish this sentinel last. Old runtimes see it as an invalid ticket
        # and fail closed instead of silently bypassing the indexed authority.
        write_json(self.layout_path, {"schemaVersion": 2})
        self._published("migration-layout")

    def _repair_terminal_transitions_locked(self):
        index = self._read_index()
        changed = False
        obsolete = []
        for ticket in list(index["entries"]):
            path = self.tickets / (ticket + ".json")
            try:
                record = self._validate_record(read_json(path), path)
            except Exception:
                continue
            if record["status"] in TERMINAL_STATUSES:
                # The indexed record is still authoritative. Re-publish its
                # terminal copy even if an interrupted prior copy is damaged.
                write_json(self._archive_path(ticket), record)
                self._published("terminal-archive-repair")
                del index["entries"][ticket]
                changed = True
                obsolete.append(record)
        if changed:
            self._schedule_cleanup_locked(obsolete)
            write_json(self.index_path, index)
            self._published("terminal-index-repair")

    def _corrupt_record(self, ticket, entry, error):
        return {"schemaVersion": 1, "ticket": ticket, "sequence": entry["sequence"],
                "resources": entry["resources"], "accessMode": "exclusive",
                "status": "needs-attention", "corruptRecord": True,
                "reason": "indexed active ticket record is missing or invalid",
                "recordError": type(error).__name__, "owner": {}}

    def records(self, resources=None):
        if not self._layout_v2():
            return self._legacy_records()
        requested = set(resources) if resources is not None else None
        index = self._read_index()
        records = []
        for ticket, entry in sorted(index["entries"].items(), key=lambda item: item[1]["sequence"]):
            if requested is not None and not requested.intersection(entry["resources"]):
                continue
            path = self.tickets / (ticket + ".json")
            try:
                record = self._validate_record(read_json(path), path)
                if record["sequence"] != entry["sequence"] or record["resources"] != entry["resources"]:
                    raise WorkError("INFOBASE_ACCESS_RECORD_INDEX_MISMATCH: " + str(path))
                if record["status"] not in TERMINAL_STATUSES:
                    records.append(record)
            except Exception as error:
                records.append(self._corrupt_record(ticket, entry, error))
        return records

    def record(self, ticket):
        if not isinstance(ticket, str) or not re.fullmatch(r"[0-9a-f]{32}", ticket):
            raise WorkError("INFOBASE_ACCESS_TICKET_INVALID")
        index = indexed = None
        if not self._layout_v2():
            path = self.tickets / (ticket + ".json")
        else:
            index = self._read_index()
            indexed = index["entries"].get(ticket)
            path = self.tickets / (ticket + ".json") if indexed else self._archive_path(ticket)
        if not path.is_file():
            raise WorkError("INFOBASE_ACCESS_TICKET_MISSING: " + ticket)
        try:
            value = read_json(path)
            if not indexed and value.get("schemaVersion") == 2:
                self._tombstone(value, path)
                raise WorkError("INFOBASE_ACCESS_TICKET_COMPACTED: " + ticket)
            record = self._validate_record(value, path)
        except Exception as error:
            if isinstance(error, WorkError):
                raise
            raise WorkError("INFOBASE_ACCESS_RECORD_INVALID: " + str(path)) from error
        if indexed:
            if record["sequence"] != indexed["sequence"] or record["resources"] != indexed["resources"]:
                raise WorkError("INFOBASE_ACCESS_RECORD_INDEX_MISMATCH: " + str(path))
        elif index is not None and record["status"] not in TERMINAL_STATUSES:
            raise WorkError("INFOBASE_ACCESS_ARCHIVE_INVALID: " + str(path))
        return record

    def take_sequence(self):
        if not self._layout_v2():
            return max((record["sequence"] for record in self._legacy_records()), default=0) + 1
        index = self._read_index()
        sequence = index["nextSequence"]
        index["nextSequence"] += 1
        write_json(self.index_path, index)
        return sequence

    def save(self, record):
        path = self.tickets / (record["ticket"] + ".json")
        self._validate_record(record, path)
        if not self._layout_v2():
            write_json(path, record)
            return
        index = self._read_index()
        existing = index["entries"].get(record["ticket"])
        expected = {"sequence": record["sequence"], "resources": record["resources"]}
        if existing is not None and existing != expected:
            raise WorkError("INFOBASE_ACCESS_RECORD_INDEX_MISMATCH: " + str(path))
        write_json(path, record)
        if record["status"] in TERMINAL_STATUSES:
            self._published("terminal-active-record")
        if record["status"] in TERMINAL_STATUSES:
            self._archive_terminal(record)
            self._published("terminal-archive")
            self._schedule_cleanup_locked([record])
            index["entries"].pop(record["ticket"], None)
            write_json(self.index_path, index)
            self._published("terminal-index")
        else:
            index["entries"][record["ticket"]] = expected
            if index["nextSequence"] <= record["sequence"]:
                index["nextSequence"] = record["sequence"] + 1
            write_json(self.index_path, index)

    def alive(self, ticket):
        try:
            with FileLock(self.root / "tickets" / (ticket + ".alive")):
                return False
        except WorkError as error:
            if busy(error):
                return True
            raise

    def cleanup_alive(self, ticket):
        with self.mutex(time.monotonic() + 30, lambda: False):
            self._run_cleanup_locked(limit=2, ticket=ticket, retries=5)

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
            for record in self.records(resources=affected):
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
            return [public(record) for record in self.records()]


ACTIVE_STATUSES = ("waiting", "running", "recovering", "needs-attention")
TERMINAL_STATUSES = ("released", "cancelled")
ACCESS_MODES = ("exclusive", "shared-read", "test-run")


def access_mode(record):
    """Legacy tickets remain exclusive; only explicit new tickets may share."""
    mode = record.get("accessMode", "exclusive")
    if mode not in ACCESS_MODES:
        raise WorkError("INFOBASE_ACCESS_MODE_INVALID")
    return mode


def effective_access_mode(record):
    if record.get("status") in ("recovering", "needs-attention"):
        return "exclusive"
    requested = record.get("requestedAccessMode")
    if requested is not None:
        if requested not in ACCESS_MODES:
            raise WorkError("INFOBASE_ACCESS_MODE_INVALID")
        return requested
    return access_mode(record)


def compatible(first, second):
    if first == "exclusive" or second == "exclusive":
        return False
    if first == "test-run" and second == "test-run":
        return False
    return True


def permits(parent, child):
    if parent == "exclusive":
        return True
    if parent == "test-run":
        return child in ("test-run", "shared-read")
    return child == "shared-read"


def public(record, *, include_native_journal=True):
    result = {key: value for key, value in record.items() if key != "token" and (include_native_journal or key != "nativeJournal")}
    result.setdefault("accessMode", "exclusive")
    return result


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
                 progress=lambda record: None, inherited=None, purpose="operation", access_mode="exclusive"):
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or not 0 <= timeout <= 86400:
            raise WorkError("INFOBASE_ACCESS_TIMEOUT_INVALID")
        if not bases:
            raise WorkError("INFOBASE_ACCESS_IDENTITY_REQUIRED")
        if purpose not in ("operation", "recovery") or (purpose == "recovery" and not inherited):
            raise WorkError("INFOBASE_ACCESS_PURPOSE_INVALID")
        if access_mode not in ACCESS_MODES or (purpose == "recovery" and access_mode != "exclusive"):
            raise WorkError("INFOBASE_ACCESS_MODE_INVALID")
        self.coordinator = Coordinator(coordinator)
        self.bases, self.owner = bases, owner
        self.timeout, self.cancelled, self.progress = timeout, cancelled, progress
        self.inherited = inherited
        self.purpose = purpose
        self.access_mode = access_mode
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
                        "resources": resources, "accessMode": self.access_mode, "admittedAt": stamp(),
                        "owner": {**self.owner, "host": platform.node(), "pid": os.getpid()}}
                    self.coordinator.save(self.record)
                    return self
                records = self.coordinator.records(resources=resources)
                ticket = uuid.uuid4().hex
                self.live_lock = FileLock(self.coordinator.root / "tickets" / (ticket + ".alive"))
                self.live_lock.__enter__()
                self.record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket, "token": secrets.token_hex(32),
                               "sequence": self.coordinator.take_sequence(),
                               "resources": resources, "accessMode": self.access_mode,
                               "status": "waiting", "createdAt": stamp(),
                               "owner": {**self.owner, "host": platform.node(), "pid": os.getpid()}}
                self.coordinator.save(self.record)
            while True:
                with self.coordinator.mutex(deadline, self.cancelled):
                    blockers = []
                    # Process records in sequence order, allowing unrelated bases
                    # to proceed without holding any subset of the requested set.
                    for record in self.coordinator.records(resources=resources):
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
                            raise admission_error("INFOBASE_ACCESS_RECOVERY_REQUIRED", self.coordinator,
                                                  [record], time.monotonic() - self.started)
                        running_conflict = record["status"] in ("running", "recovering") and not compatible(self.access_mode, effective_access_mode(record))
                        queued_conflict = (record["status"] == "waiting" and record["sequence"] < self.record["sequence"] and
                                           not compatible(self.access_mode, effective_access_mode(record)))
                        if running_conflict or queued_conflict:
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
                    raise admission_error("INFOBASE_ACCESS_WAIT_TIMEOUT", self.coordinator,
                                          blockers, time.monotonic() - self.started)
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
                    if self.record:
                        self.coordinator.cleanup_alive(self.record["ticket"])
                    self.live_lock = None
            raise

    def _inherit(self, resources):
        ticket = self.inherited.get("ticket", "")
        if (not re.fullmatch(r"[0-9a-f]{32}", ticket) or
                Path(self.inherited.get("coordinator", "")).resolve() != self.coordinator.root):
            raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
        record = self.coordinator.record(ticket)
        expected_status = "recovering" if self.purpose == "recovery" else "running"
        if (record["status"] != expected_status or self.inherited.get("purpose", "operation") != self.purpose or
                not secrets.compare_digest(inheritance_token(record), self.inherited.get("token", "")) or
                not set(resources) <= set(record["resources"]) or not self.coordinator.alive(ticket)):
            raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
        if not permits(effective_access_mode(record), self.access_mode):
            raise WorkError("INFOBASE_ACCESS_INHERITED_MODE_INVALID")
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
            current = self.coordinator.record(self.record["ticket"])
            expected = "recovering" if self.purpose == "recovery" else "running"
            if (current["status"] != expected or current["token"] != self.record["token"] or
                    not self.coordinator.alive(current["ticket"]) or
                    not set(self.coordinator.resources(self.bases)) <= set(current["resources"])):
                raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
            entries = participants(current)
            if self.participant_id and entries.get(self.participant_id, {}).get("status") != "active":
                raise WorkError("INFOBASE_ACCESS_INHERITANCE_INVALID")
            self.record = current

    def transition(self, new_mode, *, timeout=None):
        """Change the mode of the same root ticket without creating another lock domain."""
        if new_mode not in ACCESS_MODES or self.inherited or self.record is None or self.release_status is not None:
            raise WorkError("INFOBASE_ACCESS_TRANSITION_INVALID")
        wait_budget = self.timeout if timeout is None else timeout
        if (isinstance(wait_budget, bool) or not isinstance(wait_budget, (int, float)) or
                not math.isfinite(wait_budget) or not 0 <= wait_budget <= 86400):
            raise WorkError("INFOBASE_ACCESS_TIMEOUT_INVALID")
        deadline = time.monotonic() + wait_budget
        resources = set(self.record["resources"])
        try:
            while True:
                with self.coordinator.mutex(deadline, self.cancelled):
                    current = self.coordinator.record(self.record["ticket"])
                    if (current.get("status") != "running" or current.get("token") != self.record["token"] or
                            not self.coordinator.alive(current["ticket"])):
                        raise WorkError("INFOBASE_ACCESS_TRANSITION_INVALID")
                    if participants(current):
                        raise WorkError("INFOBASE_ACCESS_TRANSITION_PARTICIPANTS_ACTIVE")
                    if access_mode(current) == new_mode and "requestedAccessMode" not in current:
                        self.record, self.access_mode = current, new_mode
                        return {"accessMode": new_mode, "waitSeconds": 0.0}
                    current["requestedAccessMode"] = new_mode
                    current.setdefault("transitionRequestedAt", stamp())
                    self.coordinator.save(current)
                    blockers = []
                    for record in self.coordinator.records(resources=resources):
                        if record["ticket"] == current["ticket"] or record["status"] in ("released", "cancelled", "waiting"):
                            continue
                        if not resources.intersection(record["resources"]):
                            continue
                        if record["status"] in ("running", "recovering") and not self.coordinator.alive(record["ticket"]):
                            if record["status"] == "recovering":
                                record["recoveryAttempts"][-1].update(status="interrupted", finishedAt=stamp())
                            record.update(status="needs-attention", reason="owner-exited; inspect surviving work and restoration")
                            self.coordinator.save(record)
                        if record["status"] == "needs-attention":
                            raise admission_error("INFOBASE_ACCESS_RECOVERY_REQUIRED", self.coordinator,
                                                  [record], time.monotonic() - (deadline - wait_budget))
                        if record["status"] in ("running", "recovering") and not compatible(new_mode, effective_access_mode(record)):
                            blockers.append(public(record, include_native_journal=False))
                    if not blockers:
                        current["accessMode"] = new_mode
                        current.pop("requestedAccessMode", None)
                        current.pop("transitionRequestedAt", None)
                        current["modeChangedAt"] = stamp()
                        self.coordinator.save(current)
                        self.record, self.access_mode = current, new_mode
                        return {"accessMode": new_mode, "waitSeconds": max(0.0, time.monotonic() - (deadline - wait_budget))}
                waited = max(0.0, time.monotonic() - (deadline - wait_budget))
                self.progress({"status": "waiting-for-mode", "ticket": self.record["ticket"],
                               "resources": sorted(resources), "accessMode": new_mode,
                               "waitSeconds": waited, "blockers": blockers})
                if time.monotonic() >= deadline:
                    raise admission_error("INFOBASE_ACCESS_WAIT_TIMEOUT", self.coordinator, blockers, waited)
                time.sleep(0.05)
        except BaseException:
            try:
                with self.coordinator.mutex(time.monotonic() + 10, lambda: False):
                    current = self.coordinator.record(self.record["ticket"])
                    if current.get("token") == self.record["token"]:
                        current.pop("requestedAccessMode", None)
                        current.pop("transitionRequestedAt", None)
                        self.coordinator.save(current)
                        self.record = current
            except BaseException:
                pass
            raise

    def release(self, *, cleanup_errors=()):
        if self.inherited:
            if self.participant_id is None:
                return self.release_status
            try:
                with self.coordinator.mutex(time.monotonic() + 30, lambda: False):
                    current = self.coordinator.record(self.record["ticket"])
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
                current = self.coordinator.record(self.record["ticket"])
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
            self.coordinator.cleanup_alive(self.record["ticket"])
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
