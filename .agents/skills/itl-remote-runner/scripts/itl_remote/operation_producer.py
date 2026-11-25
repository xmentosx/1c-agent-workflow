"""Assemble client/server/background fragments into one private operation sidecar."""
from __future__ import annotations

import copy
import json
from pathlib import Path

from .common import WorkError, read_json, write_json
from .operation_evidence import LEVELS


DOMAINS = ("client", "serverWithoutContext", "serverWithContext", "background")
COVERAGE = ("complete", "partial", "unknown", "notApplicable", "notExecuted")
ENVELOPE_FIELDS = {"schemaVersion", "jobId", "iterationId", "operationId", "diagnostics",
                   "expectedEmitters", "experimentId", "criticalPath", "equivalence",
                   "limitations"}
FRAGMENT_FIELDS = {"schemaVersion", "jobId", "iterationId", "operationId", "emitterId",
                   "domain", "coverage", "streamStatus", "clocks", "spans", "links",
                   "payloads", "milestones", "backgroundOperations", "limitations"}
COLLECTIONS = ("clocks", "spans", "links", "payloads", "milestones", "backgroundOperations")


def _text(value, error):
    if not isinstance(value, str) or not value.strip():
        raise WorkError(error)
    return value


def _identity(value, envelope):
    if (value.get("jobId") != envelope["jobId"] or
            value.get("iterationId") != envelope["iterationId"] or
            value.get("operationId") != envelope["operationId"]):
        raise WorkError("OPERATION_FRAGMENT_FOREIGN_OPERATION")


def _document(value):
    if isinstance(value, Path):
        return read_json(value)
    if isinstance(value, str):
        return json.loads(value) if value.lstrip().startswith("{") else read_json(value)
    return value


def _stream(value):
    if not isinstance(value, dict):
        raise WorkError("OPERATION_FRAGMENT_STREAM_REQUIRED")
    if type(value.get("complete")) is not bool or type(value.get("truncated")) is not bool:
        raise WorkError("OPERATION_FRAGMENT_STREAM_INVALID")
    dropped = value.get("droppedEvents")
    if type(dropped) is not int or dropped < 0:
        raise WorkError("OPERATION_FRAGMENT_STREAM_INVALID")
    return copy.deepcopy(value)


def _validate_envelope(envelope):
    if not isinstance(envelope, dict) or envelope.get("schemaVersion") != 1:
        raise WorkError("OPERATION_FRAGMENT_ENVELOPE_UNSUPPORTED")
    unknown = set(envelope) - ENVELOPE_FIELDS
    if unknown:
        raise WorkError("OPERATION_FRAGMENT_ENVELOPE_UNKNOWN_FIELD: " + ", ".join(sorted(unknown)))
    _text(envelope.get("jobId"), "OPERATION_FRAGMENT_JOB_REQUIRED")
    if type(envelope.get("iterationId")) is not int or envelope["iterationId"] < 0:
        raise WorkError("OPERATION_FRAGMENT_ITERATION_INVALID")
    _text(envelope.get("operationId"), "OPERATION_FRAGMENT_OPERATION_REQUIRED")
    diagnostics = envelope.get("diagnostics")
    if not isinstance(diagnostics, dict) or diagnostics.get("level") not in LEVELS:
        raise WorkError("OPERATION_FRAGMENT_DIAGNOSTICS_INVALID")
    expected = envelope.get("expectedEmitters")
    if not isinstance(expected, list) or not expected:
        raise WorkError("OPERATION_FRAGMENT_EXPECTED_EMITTERS_REQUIRED")
    by_id = {}
    for item in expected:
        if not isinstance(item, dict) or set(item) - {"emitterId", "domain", "required"}:
            raise WorkError("OPERATION_FRAGMENT_EXPECTED_EMITTER_INVALID")
        identifier = _text(item.get("emitterId"), "OPERATION_FRAGMENT_EMITTER_REQUIRED")
        if identifier in by_id or item.get("domain") not in DOMAINS or type(item.get("required", True)) is not bool:
            raise WorkError("OPERATION_FRAGMENT_EXPECTED_EMITTER_INVALID")
        by_id[identifier] = item
    return by_id


def assemble(envelope, fragments):
    """Return a raw schema-v1 sidecar; normalization remains a separate gate."""
    envelope = _document(envelope)
    expected = _validate_envelope(envelope)
    if not isinstance(fragments, (list, tuple)):
        raise WorkError("OPERATION_FRAGMENTS_COLLECTION_REQUIRED")
    result = {"schemaVersion": 1, "artifactKind": "itl-operation-evidence",
              "isRuntimeEvidence": True, "jobId": envelope["jobId"],
              "iterationId": envelope["iterationId"], "operationId": envelope["operationId"],
              "diagnostics": copy.deepcopy(envelope["diagnostics"]), "emitters": [],
              "clocks": [], "spans": [], "links": [], "payloads": [], "milestones": [],
              "backgroundOperations": [], "coverage": {},
              "criticalPath": copy.deepcopy(envelope.get("criticalPath")),
              "equivalence": copy.deepcopy(envelope.get("equivalence", {
                  "status": "unverified", "reason": "product equivalence predicate not supplied"})),
              "streamStatus": {"complete": True, "truncated": False, "droppedEvents": 0},
              "limitations": list(envelope.get("limitations", []))}
    if envelope.get("experimentId") is not None:
        result["experimentId"] = envelope["experimentId"]
    if result["criticalPath"] is None:
        del result["criticalPath"]

    observed = {}
    identifiers = {"clocks": set(), "spans": set(), "backgroundOperations": set()}
    keys = {"clocks": "clockId", "spans": "spanId", "backgroundOperations": "backgroundOperationId"}
    for source in fragments:
        fragment = _document(source)
        if not isinstance(fragment, dict) or fragment.get("schemaVersion") != 1:
            raise WorkError("OPERATION_FRAGMENT_SCHEMA_UNSUPPORTED")
        unknown = set(fragment) - FRAGMENT_FIELDS
        if unknown:
            raise WorkError("OPERATION_FRAGMENT_UNKNOWN_FIELD: " + ", ".join(sorted(unknown)))
        _identity(fragment, envelope)
        emitter_id = _text(fragment.get("emitterId"), "OPERATION_FRAGMENT_EMITTER_REQUIRED")
        if emitter_id in observed or emitter_id not in expected:
            raise WorkError("OPERATION_FRAGMENT_UNEXPECTED_OR_DUPLICATE_EMITTER: " + emitter_id)
        if fragment.get("domain") != expected[emitter_id]["domain"]:
            raise WorkError("OPERATION_FRAGMENT_DOMAIN_MISMATCH: " + emitter_id)
        coverage = fragment.get("coverage")
        if coverage not in COVERAGE:
            raise WorkError("OPERATION_FRAGMENT_COVERAGE_INVALID: " + emitter_id)
        stream = _stream(fragment.get("streamStatus"))
        observed[emitter_id] = fragment
        result["emitters"].append({"emitterId": emitter_id, "domain": fragment["domain"],
                                   "status": "complete" if stream["complete"] and not stream["truncated"] and not stream["droppedEvents"] else "partial",
                                   "coverage": coverage, "streamStatus": stream})
        previous = result["coverage"].get(fragment["domain"])
        result["coverage"][fragment["domain"]] = coverage if previous in (None, "complete") else previous
        result["streamStatus"]["complete"] = result["streamStatus"]["complete"] and stream["complete"]
        result["streamStatus"]["truncated"] = result["streamStatus"]["truncated"] or stream["truncated"]
        result["streamStatus"]["droppedEvents"] += stream["droppedEvents"]
        result["limitations"].extend(fragment.get("limitations", []))
        for collection in COLLECTIONS:
            values = fragment.get(collection, [])
            if not isinstance(values, list):
                raise WorkError("OPERATION_FRAGMENT_COLLECTION_INVALID: " + collection)
            if collection in keys:
                key = keys[collection]
                for item in values:
                    identifier = _text(item.get(key) if isinstance(item, dict) else None,
                                       "OPERATION_FRAGMENT_IDENTIFIER_REQUIRED: " + collection)
                    if identifier in identifiers[collection]:
                        raise WorkError("OPERATION_FRAGMENT_IDENTIFIER_COLLISION: " + identifier)
                    identifiers[collection].add(identifier)
            result[collection].extend(copy.deepcopy(values))

    for emitter_id, definition in expected.items():
        if emitter_id in observed:
            continue
        reason = "required producer did not deliver a fragment" if definition.get("required", True) else "optional producer did not deliver a fragment"
        result["emitters"].append({"emitterId": emitter_id, "domain": definition["domain"],
                                   "status": "missing", "coverage": "unknown", "reason": reason})
        result["coverage"][definition["domain"]] = "unknown"
        result["streamStatus"]["complete"] = False
        result["limitations"].append("emitter %s missing: %s" % (emitter_id, reason))
    for domain in DOMAINS:
        result["coverage"].setdefault(domain, "notApplicable")
    result["limitations"] = list(dict.fromkeys(result["limitations"]))
    return result


def publish(envelope, fragments, destination):
    """Atomically publish the assembled raw sidecar after the measured boundary."""
    destination = Path(destination)
    write_json(destination, assemble(envelope, fragments))
    return destination
