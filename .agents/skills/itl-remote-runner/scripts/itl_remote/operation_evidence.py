"""Strict offline normalization for opt-in user-operation performance evidence."""
from __future__ import annotations

import copy
import math
from pathlib import Path
import re

from .common import WorkError, digest, read_json, write_json


LEVELS = ("D0", "D1", "D2", "D3")
AVAILABILITY = ("available", "unknown", "notApplicable", "notExecuted", "belowResolution", "invalid")
EVIDENCE_KINDS = ("measured", "derived", "bounded", "inferred")
CLOCK_KINDS = ("monotonic", "wall", "durationCounter")
LINK_KINDS = ("rpc", "spawn", "waitFor", "join", "resultOf", "continues")
DEPENDENCY_LINKS = ("spawn", "waitFor", "join", "resultOf", "continues")
MAX_EXACT_JSON_INTEGER = 2 ** 53
TOP_LEVEL_FIELDS = {"schemaVersion", "artifactKind", "isRuntimeEvidence", "note", "experimentId",
                    "jobId", "iterationId", "operationId", "diagnostics", "clocks", "emitters",
                    "spans", "links", "payloads", "milestones", "backgroundOperations", "coverage",
                    "criticalPath", "equivalence", "streamStatus", "limitations"}


def _text(value, error):
    if not isinstance(value, str) or not value.strip():
        raise WorkError(error)
    return value


def validate_diagnostics(value):
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise WorkError("OPERATION_EVIDENCE_DIAGNOSTICS_INVALID")
    if value.get("level") not in LEVELS:
        raise WorkError("OPERATION_EVIDENCE_DIAGNOSTICS_LEVEL_INVALID")
    path = Path(_text(value.get("evidencePath"), "OPERATION_EVIDENCE_PATH_REQUIRED"))
    if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0].casefold() != "private":
        raise WorkError("OPERATION_EVIDENCE_PATH_MUST_BE_PRIVATE_RELATIVE")
    if type(value.get("required", False)) is not bool:
        raise WorkError("OPERATION_EVIDENCE_REQUIRED_INVALID")
    return value


def _duration(span):
    value = span.get("duration")
    if not isinstance(value, dict) or value.get("availability") not in AVAILABILITY:
        raise WorkError("OPERATION_EVIDENCE_DURATION_INVALID")
    if value["availability"] != "available":
        if value.get("value") is not None or not value.get("reason"):
            raise WorkError("OPERATION_EVIDENCE_UNKNOWN_REQUIRES_NULL_AND_REASON")
        return None
    if value.get("evidenceKind") not in EVIDENCE_KINDS:
        raise WorkError("OPERATION_EVIDENCE_KIND_INVALID")
    number = value.get("value")
    if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number) or number < 0:
        raise WorkError("OPERATION_EVIDENCE_DURATION_VALUE_INVALID")
    _text(value.get("unit"), "OPERATION_EVIDENCE_DURATION_UNIT_REQUIRED")
    return value


def _validate_ticks(span):
    for key in ("startTicks", "endTicks"):
        if key not in span:
            continue
        value = span[key]
        if isinstance(value, int) and not isinstance(value, bool) and abs(value) <= MAX_EXACT_JSON_INTEGER:
            continue
        if isinstance(value, str) and re.fullmatch(r"-?[0-9]+", value):
            continue
        raise WorkError("OPERATION_EVIDENCE_TICKS_MUST_BE_EXACT")


def _validate_availability_tree(value):
    if isinstance(value, list):
        for item in value:
            _validate_availability_tree(item)
        return
    if not isinstance(value, dict):
        return
    if "availability" in value:
        if value["availability"] not in AVAILABILITY:
            raise WorkError("OPERATION_EVIDENCE_AVAILABILITY_INVALID")
        if value["availability"] != "available" and (value.get("value") is not None or not value.get("reason")):
            raise WorkError("OPERATION_EVIDENCE_UNKNOWN_REQUIRES_NULL_AND_REASON")
        if value["availability"] == "available" and value.get("evidenceKind") not in EVIDENCE_KINDS:
            raise WorkError("OPERATION_EVIDENCE_KIND_INVALID")
    for item in value.values():
        _validate_availability_tree(item)


def _dependencies(spans, links):
    ids = {item["spanId"] for item in spans}
    incoming = {identifier: [] for identifier in ids}
    outgoing = {identifier: [] for identifier in ids}
    for link in links:
        if link["kind"] not in DEPENDENCY_LINKS:
            continue
        source, target = link["from"], link["to"]
        incoming[target].append(source)
        outgoing[source].append(target)
    pending = {identifier: len(incoming[identifier]) for identifier in ids}
    queue = [identifier for identifier, count in pending.items() if count == 0]
    visited = 0
    while queue:
        current = queue.pop()
        visited += 1
        for target in outgoing[current]:
            pending[target] -= 1
            if pending[target] == 0:
                queue.append(target)
    if visited != len(ids):
        raise WorkError("OPERATION_EVIDENCE_DEPENDENCY_CYCLE")
    return incoming


def longest_path(spans, links, target_span_id):
    by_id = {item["spanId"]: item for item in spans}
    if target_span_id not in by_id:
        raise WorkError("OPERATION_EVIDENCE_CRITICAL_TARGET_MISSING")
    incoming = _dependencies(spans, links)
    memo = {}

    def visit(identifier, unit=None):
        duration = _duration(by_id[identifier])
        if duration is None:
            raise WorkError("OPERATION_EVIDENCE_CRITICAL_DURATION_UNKNOWN")
        if unit is not None and duration["unit"] != unit:
            raise WorkError("OPERATION_EVIDENCE_CRITICAL_CLOCK_INCOMPATIBLE")
        candidates = [visit(parent, duration["unit"]) for parent in incoming[identifier]]
        parent_value, parent_path = max(candidates, default=(0, []), key=lambda item: item[0])
        result = (parent_value + duration["value"], parent_path + [identifier])
        memo[identifier] = result
        return result

    value, path = visit(target_span_id)
    unit = _duration(by_id[target_span_id])["unit"]
    return {"availability": "available", "evidenceKind": "derived", "value": value,
            "unit": unit, "spanIds": path, "definition": "Longest proven dependency path; parallel branches are not summed"}


def normalize(document, *, job_id, iteration_id):
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        raise WorkError("OPERATION_EVIDENCE_SCHEMA_UNSUPPORTED")
    unknown = set(document) - TOP_LEVEL_FIELDS
    if unknown:
        raise WorkError("OPERATION_EVIDENCE_UNKNOWN_FIELD: " + ", ".join(sorted(unknown)))
    if document.get("jobId") != job_id or document.get("iterationId") != iteration_id:
        raise WorkError("OPERATION_EVIDENCE_FOREIGN_ITERATION")
    _text(document.get("operationId"), "OPERATION_EVIDENCE_OPERATION_ID_REQUIRED")
    _validate_availability_tree(document)
    diagnostics = document.get("diagnostics")
    if not isinstance(diagnostics, dict) or diagnostics.get("level") not in LEVELS:
        raise WorkError("OPERATION_EVIDENCE_LEVEL_INVALID")
    clocks = document.get("clocks")
    spans = document.get("spans")
    links = document.get("links", [])
    if not isinstance(clocks, list) or not isinstance(spans, list) or not isinstance(links, list):
        raise WorkError("OPERATION_EVIDENCE_COLLECTION_INVALID")
    clock_ids = set()
    for clock in clocks:
        identifier = _text(clock.get("clockId") if isinstance(clock, dict) else None, "OPERATION_EVIDENCE_CLOCK_ID_REQUIRED")
        if identifier in clock_ids or clock.get("kind") not in CLOCK_KINDS:
            raise WorkError("OPERATION_EVIDENCE_CLOCK_INVALID")
        _text(clock.get("unit"), "OPERATION_EVIDENCE_CLOCK_UNIT_REQUIRED")
        clock_ids.add(identifier)
    by_id = {}
    for span in spans:
        if not isinstance(span, dict):
            raise WorkError("OPERATION_EVIDENCE_SPAN_INVALID")
        identifier = _text(span.get("spanId"), "OPERATION_EVIDENCE_SPAN_ID_REQUIRED")
        if identifier in by_id or span.get("clockId") not in clock_ids:
            raise WorkError("OPERATION_EVIDENCE_SPAN_INVALID")
        _text(span.get("kind"), "OPERATION_EVIDENCE_SPAN_KIND_REQUIRED")
        _duration(span)
        _validate_ticks(span)
        by_id[identifier] = span
    for link in links:
        if (not isinstance(link, dict) or link.get("kind") not in LINK_KINDS or
                link.get("from") not in by_id or link.get("to") not in by_id):
            raise WorkError("OPERATION_EVIDENCE_LINK_INVALID")
        if link["kind"] == "rpc":
            call_id = _text(link.get("callId"), "OPERATION_EVIDENCE_RPC_CALL_REQUIRED")
            if by_id[link["from"]].get("callId") != call_id or by_id[link["to"]].get("callId") != call_id:
                raise WorkError("OPERATION_EVIDENCE_RPC_CALL_MISMATCH")
    _dependencies(spans, links)
    result = copy.deepcopy(document)
    limitations = list(result.get("limitations", []))
    derived = []
    for link in links:
        if link["kind"] != "rpc":
            continue
        client, server = by_id[link["from"]], by_id[link["to"]]
        c, s = _duration(client), _duration(server)
        if c is None or s is None:
            limitations.append("rpc remainder unavailable: duration unknown")
        elif c["unit"] != s["unit"]:
            limitations.append("rpc remainder unavailable: duration unit mismatch")
        elif link.get("contained") is False:
            limitations.append("rpc remainder unavailable: independent interval containment not proven")
        elif c["value"] < s["value"]:
            limitations.append("rpc remainder invalid: negative remainder")
        else:
            derived.append({"metricId": link["callId"] + "-uncovered-remainder",
                            "availability": "available", "evidenceKind": "derived",
                            "value": c["value"] - s["value"], "unit": c["unit"],
                            "definition": "Client RPC window outside the correlated server span; not network-only time",
                            "formula": "C - S", "operandRefs": [client["spanId"], server["spanId"]]})
    critical = result.get("criticalPath")
    if isinstance(critical, dict) and critical.get("targetSpanId"):
        try:
            result["criticalPath"] = longest_path(spans, links, critical["targetSpanId"])
        except WorkError as error:
            result["criticalPath"] = {"status": "partial", "value": None, "reason": str(error)}
            limitations.append("critical path partial: " + str(error))
    stream = result.get("streamStatus", {})
    if stream.get("truncated") or stream.get("complete") is not True or stream.get("droppedEvents", 0):
        limitations.append("event stream partial or truncated")
    if any(span.get("status", "completed") != "completed" for span in spans):
        limitations.append("one or more spans are unclosed")
    result["derivedMetrics"] = derived
    result["limitations"] = list(dict.fromkeys(limitations))
    coverage = result.get("coverage", {})
    equivalence = result.get("equivalence", {})
    result["analysisStatus"] = ("complete" if not result["limitations"] and coverage and
                                all(value == "complete" for value in coverage.values()) and
                                equivalence.get("status") == "verified" else "partial")
    return result


def analyze_file(source, destination, *, job_id, iteration_id):
    source, destination = Path(source), Path(destination)
    normalized = normalize(read_json(source), job_id=job_id, iteration_id=iteration_id)
    write_json(destination, normalized)
    return {"status": normalized["analysisStatus"], "path": destination.name,
            "sha256": digest(destination), "operationId": normalized["operationId"],
            "level": normalized["diagnostics"]["level"], "coverage": normalized.get("coverage", {}),
            "limitations": normalized["limitations"]}
