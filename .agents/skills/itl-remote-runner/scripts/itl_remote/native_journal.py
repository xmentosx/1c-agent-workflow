"""Native intent indexed by the admitted pipe owner, never a release verifier."""
from __future__ import annotations

import copy
from pathlib import Path
import platform
import re
import time
import uuid

from .access import participants, public
from .common import WorkError, beneath, digest, identity, read_json, stamp, write_json


def _identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{32}", value):
        raise WorkError("NATIVE_JOURNAL_IDENTIFIER_INVALID")
    return value


def _index(record):
    value = record.get("nativeJournal")
    if not isinstance(value, dict) or value.get("schemaVersion") != 1 or not isinstance(value.get("producers"), dict):
        raise WorkError("NATIVE_JOURNAL_INDEX_MISSING_OR_INVALID")
    return value


def _current(lease):
    record = read_json(lease.coordinator.root / "tickets" / (lease.record["ticket"] + ".json"))
    expected = "recovering" if lease.purpose == "recovery" else "running"
    if (record["token"] != lease.record["token"] or record["status"] != expected or
            not lease.coordinator.alive(record["ticket"])):
        raise WorkError("NATIVE_JOURNAL_OWNER_CHANGED")
    if lease.participant_id and participants(record).get(lease.participant_id, {}).get("status") != "active":
        raise WorkError("NATIVE_JOURNAL_PARTICIPANT_NOT_ACTIVE")
    return record


def register(lease):
    lease.validate()
    with lease.coordinator.mutex(time.monotonic() + 30, lease.cancelled):
        record = _current(lease)
        record.setdefault("nativeJournal", {"schemaVersion": 1, "producers": {}})
        producer_id = uuid.uuid4().hex
        _index(record)["producers"][producer_id] = {
            "protocol": lease.owner.get("nativeJournalProtocol", 0),
            "generation": identity(record["token"]), "participantId": lease.participant_id,
            "resources": lease.coordinator.resources(lease.bases), "createdAt": stamp(),
            "hostName": platform.node(), "ownerPid": lease.owner.get("parentPid"),
            "records": {},
        }
        lease.coordinator.save(record)
        lease.record = record
        return producer_id


def _validate(payload):
    fields = {"schemaVersion", "journalId", "ticket", "id", "createdAt", "updatedAt", "hostName", "ownerPid",
              "operation", "project", "purpose", "resources", "helperInputs", "admissions", "startAttempted",
              "processId", "launcherExited", "quiescenceConfirmed", "releaseEvidence", "ownedProcessScopes",
              "recoveryRequiresLiveVerification", "resourceIds"}
    if (not isinstance(payload, dict) or set(payload) != fields or payload.get("schemaVersion") != 1 or
            payload.get("recoveryRequiresLiveVerification") is not True):
        raise WorkError("NATIVE_JOURNAL_RECORD_INVALID")
    for name in ("ticket", "journalId", "id"):
        _identifier(payload[name])
    for name in ("createdAt", "updatedAt", "hostName", "operation", "project", "purpose", "releaseEvidence"):
        if not isinstance(payload[name], str):
            raise WorkError("NATIVE_JOURNAL_TEXT_INVALID")
    for name in ("startAttempted", "launcherExited", "quiescenceConfirmed"):
        if type(payload[name]) is not bool:
            raise WorkError("NATIVE_JOURNAL_OBSERVATION_INVALID")
    if (type(payload["ownerPid"]) is not int or payload["ownerPid"] <= 0 or
            type(payload["processId"]) is not int or payload["processId"] < 0 or
            (payload["processId"] and not payload["startAttempted"]) or
            (payload["quiescenceConfirmed"] and not (payload["startAttempted"] and payload["launcherExited"] and payload["releaseEvidence"]))):
        raise WorkError("NATIVE_JOURNAL_OBSERVATION_INVALID")
    for name in ("resources", "helperInputs", "admissions", "ownedProcessScopes", "resourceIds"):
        if not isinstance(payload[name], list):
            raise WorkError("NATIVE_JOURNAL_COLLECTION_INVALID")
    if not payload["resources"] or not payload["admissions"] or not payload["helperInputs"]:
        raise WorkError("NATIVE_JOURNAL_INPUTS_REQUIRED")
    for base in payload["resources"]:
        if (not isinstance(base, dict) or set(base) != {"kind", "path"} or
                base["kind"] not in ("file", "server") or not isinstance(base["path"], str) or not base["path"]):
            raise WorkError("NATIVE_JOURNAL_RESOURCE_INVALID")
    for admission in payload["admissions"]:
        # Runtime drain owns cleanup of existing sessions and starts no new
        # native session. Every process-launch admission still requires >= 1.
        minimum_sessions = 0 if payload["purpose"] == "owned-runtime-drain" else 1
        if (not isinstance(admission, dict) or set(admission) != {"kind", "path", "requiredSessions", "expectedChildRole"} or
                admission["kind"] not in ("file", "server") or not isinstance(admission["path"], str) or not admission["path"] or
                type(admission["requiredSessions"]) is not int or not minimum_sessions <= admission["requiredSessions"] <= 64 or
                admission["expectedChildRole"] not in ("", "test-client")):
            raise WorkError("NATIVE_JOURNAL_ADMISSION_INVALID")
    for helper in payload["helperInputs"]:
        if (not isinstance(helper, dict) or set(helper) != {"path", "sha256"} or not isinstance(helper["path"], str) or
                not helper["path"] or not isinstance(helper["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", helper["sha256"])):
            raise WorkError("NATIVE_JOURNAL_HELPER_INPUT_INVALID")
    for scope in payload["ownedProcessScopes"]:
        if (not isinstance(scope, dict) or set(scope) != {"schemaVersion", "role", "kind", "path", "runParamsPath", "runParamsSha256", "testPorts"} or
                scope["schemaVersion"] != 1 or scope["role"] not in ("test-manager", "test-client") or
                scope["kind"] not in ("file", "server") or any(not isinstance(scope[n], str) or not scope[n] for n in ("path", "runParamsPath", "runParamsSha256")) or
                not re.fullmatch(r"[a-f0-9]{64}", scope["runParamsSha256"]) or not isinstance(scope["testPorts"], list) or
                any(type(port) is not int or not 1 <= port <= 65535 for port in scope["testPorts"]) or
                (scope["role"] == "test-client" and not scope["testPorts"])):
            raise WorkError("NATIVE_JOURNAL_SCOPE_INVALID")


def publish(lease, producer_id, payload):
    _validate(payload)
    lease.validate()
    with lease.coordinator.mutex(time.monotonic() + 30, lease.cancelled):
        record = _current(lease)
        producers = _index(record)["producers"]
        producer = producers.get(producer_id)
        if producer and producer.get("protocol") != 1:
            raise WorkError("NATIVE_JOURNAL_PROTOCOL_NOT_DECLARED")
        if (not producer or producer["generation"] != identity(record["token"]) or
                producer["participantId"] != lease.participant_id or payload["ticket"] != record["ticket"] or
                payload["ownerPid"] != producer["ownerPid"] or payload["hostName"].casefold() != producer["hostName"].casefold()):
            raise WorkError("NATIVE_JOURNAL_PRODUCER_MISMATCH")
        resources = lease.coordinator.resources(payload["resources"])
        if (not set(resources) <= set(producer["resources"]) or
                not set(lease.coordinator.resources(payload["admissions"])) <= set(resources) or
                (payload["ownedProcessScopes"] and not set(lease.coordinator.resources(payload["ownedProcessScopes"])) <= set(resources))):
            raise WorkError("NATIVE_JOURNAL_TARGET_NOT_RESERVED")
        value = copy.deepcopy(payload)
        value["resourceIds"] = resources
        key = value["journalId"] + "/" + value["id"]
        if any(other_id != producer_id and any(k.startswith(value["journalId"] + "/") for k in other["records"])
               for other_id, other in producers.items()):
            raise WorkError("NATIVE_JOURNAL_BELONGS_TO_ANOTHER_PRODUCER")
        previous = producer["records"].get(key)
        if previous:
            before = _read_operation(lease.coordinator, record["ticket"], key, previous)
            stable = ("ticket", "journalId", "id", "createdAt", "hostName", "ownerPid", "operation", "project", "purpose", "resources", "resourceIds", "helperInputs", "admissions")
            if (any(before[n] != value[n] for n in stable) or
                    (before["startAttempted"] and (not value["startAttempted"] or before["ownedProcessScopes"] != value["ownedProcessScopes"])) or
                    (before["processId"] and before["processId"] != value["processId"])):
                raise WorkError("NATIVE_JOURNAL_IMMUTABLE_INPUT_CHANGED")
        # Write an immutable snapshot first. Only the ticket's atomic index
        # update makes it authoritative; no native start is allowed before ACK.
        relative = Path("native-operations") / record["ticket"] / value["journalId"] / value["id"] / (identity(value) + ".json")
        destination = beneath(lease.coordinator.root, relative.as_posix())
        if destination.exists():
            if read_json(destination) != value:
                raise WorkError("NATIVE_JOURNAL_IMMUTABLE_SNAPSHOT_CHANGED")
        else:
            write_json(destination, value)
        entry = {"path": relative.as_posix(), "sha256": digest(destination)}
        producer["records"][key] = entry
        lease.coordinator.save(record)
        lease.record = record
        return {"event": "native-operation-recorded", "ticket": record["ticket"], "journalId": value["journalId"],
                "id": value["id"], "path": str(destination), "sha256": entry["sha256"]}


def _read_operation(coordinator, ticket, key, entry):
    ids = key.split("/")
    if len(ids) != 2:
        raise WorkError("NATIVE_JOURNAL_INDEX_ENTRY_INVALID")
    for identifier in ids:
        _identifier(identifier)
    if not isinstance(entry, dict) or set(entry) != {"path", "sha256"} or not isinstance(entry["path"], str):
        raise WorkError("NATIVE_JOURNAL_INDEX_ENTRY_INVALID")
    relative = Path(entry["path"])
    prefix = ("native-operations", ticket, *ids)
    if (relative.is_absolute() or relative.parts[:-1] != prefix or
            not re.fullmatch(r"[a-f0-9]{64}\.json", relative.name) or not isinstance(entry["sha256"], str)):
        raise WorkError("NATIVE_JOURNAL_INDEX_PATH_INVALID")
    path = beneath(coordinator.root, relative.as_posix())
    if not path.is_file() or digest(path) != entry["sha256"]:
        raise WorkError("NATIVE_JOURNAL_RECORD_MISSING_OR_CHANGED")
    value = read_json(path)
    _validate(value)
    if (value["ticket"] != ticket or value["journalId"] != ids[0] or value["id"] != ids[1] or identity(value) != path.stem):
        raise WorkError("NATIVE_JOURNAL_RECORD_BINDING_CHANGED")
    return value


def inspect(coordinator, record):
    """Read every indexed operation; the returned data is not live recovery proof."""
    if record.get("owner", {}).get("nativeJournalProtocol") != 1:
        raise WorkError("NATIVE_JOURNAL_OWNER_PROTOCOL_REQUIRED")
    producers = _index(record)["producers"]
    for producer_id, producer in producers.items():
        _identifier(producer_id)
        if (not isinstance(producer, dict) or not isinstance(producer.get("records"), dict) or
                not isinstance(producer.get("resources"), list)):
            raise WorkError("NATIVE_JOURNAL_PRODUCER_INVALID")
        if producer.get("protocol") != 1:
            raise WorkError("NATIVE_JOURNAL_UNTRACKED_PRODUCER")
        if producer.get("participantId") is not None:
            _identifier(producer["participantId"])
    if not producers or not any(p.get("participantId") is None for p in producers.values()):
        raise WorkError("NATIVE_JOURNAL_OWNER_PRODUCER_MISSING")
    represented = {p.get("participantId") for p in producers.values()}
    if set(participants(record)) - represented:
        raise WorkError("NATIVE_JOURNAL_UNTRACKED_PARTICIPANT")
    operations, seen = [], set()
    journals = {}
    for producer_id, producer in producers.items():
        _identifier(producer_id)
        if not isinstance(producer, dict) or not isinstance(producer.get("records"), dict):
            raise WorkError("NATIVE_JOURNAL_PRODUCER_INVALID")
        for key, entry in producer["records"].items():
            value = _read_operation(coordinator, record["ticket"], key, entry)
            journal_id = value["journalId"]
            if key in seen or (journal_id in journals and journals[journal_id] != producer_id):
                raise WorkError("NATIVE_JOURNAL_DUPLICATE_OPERATION")
            seen.add(key)
            journals[journal_id] = producer_id
            resources = coordinator.resources(value["resources"])
            if resources != value["resourceIds"] or not set(resources) <= set(producer["resources"]) or not set(resources) <= set(record["resources"]):
                raise WorkError("NATIVE_JOURNAL_RESOURCE_BINDING_CHANGED")
            operations.append(value)
    return {"schemaVersion": 1, "ticket": record["ticket"], "recordRevision": identity(public(record)),
            "resources": list(record["resources"]), "operations": operations, "requiresLiveVerification": True}


def release_errors(lease, producer_id):
    with lease.coordinator.mutex(time.monotonic() + 30, lambda: False):
        record = _current(lease)
        producer = _index(record)["producers"][producer_id]
        for key, entry in producer["records"].items():
            value = _read_operation(lease.coordinator, record["ticket"], key, entry)
            if value["startAttempted"] and not value["quiescenceConfirmed"]:
                return ["native-operation-cleanup-unconfirmed"]
    return []
