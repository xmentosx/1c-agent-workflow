"""Human-readable map of one normalized user-operation evidence document."""
from __future__ import annotations

from pathlib import Path


def _text(value, default="—"):
    if value is None:
        return default
    if isinstance(value, bool):
        return "true" if value else "false"
    result = " ".join(str(value).split())
    return result.replace("\\", "\\\\").replace("|", "\\|") or default


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, int) or value.is_integer():
        return f"{int(value):,}"
    return f"{value:,.6f}".rstrip("0").rstrip(".")


def _items(value):
    return value if isinstance(value, list) else []


def _measure(value):
    if not isinstance(value, dict):
        return "unknown — evidence not supplied"
    availability = value.get("availability", "unknown")
    if availability != "available":
        return _text(availability) + " — " + _text(value.get("reason"), "reason not supplied")
    number = _number(value.get("value"))
    if number is not None:
        return (number + " " + _text(value.get("unit"), "unit unknown")).strip()
    bounds = value.get("bounds")
    if isinstance(bounds, dict):
        lower, upper = _number(bounds.get("lower")), _number(bounds.get("upper"))
        if lower is not None or upper is not None:
            return "%s–%s %s" % (lower or "?", upper or "?", _text(value.get("unit"), "unit unknown"))
    return "available — numeric value not supplied"


def _duration(span):
    return _measure(span.get("duration"))


def _span_name(span):
    return _text(span.get("name"), _text(span.get("spanId")))


def _boundary(span):
    value = span.get("boundaries")
    if not isinstance(value, dict):
        return "—"
    return _text(value.get("start"), "?") + " → " + _text(value.get("end"), "?")


def _origin(span):
    duration = span.get("duration", {})
    parts = [duration.get("evidenceKind"), span.get("sourceRef") or duration.get("sourceRef")]
    return "; ".join(_text(item) for item in parts if item) or "—"


def _span_rows(document):
    spans = _items(document.get("spans"))
    children = {None: []}
    for item in spans:
        children.setdefault(item.get("parentSpanId"), []).append(item)
        children.setdefault(item["spanId"], [])
    rows = []

    def visit(item, depth):
        name = ("↳ " * depth) + _span_name(item)
        if item.get("callId"):
            name += " [`%s`]" % _text(item["callId"])
        rows.append("| %s | %s | %s | %s | %s | %s | %s |" % (
            name, _text(item.get("domain"), "unknown"), _text(item.get("kind")),
            _duration(item), _text(item.get("status"), "unknown"), _boundary(item), _origin(item)))
        for child in children.get(item["spanId"], []):
            visit(child, depth + 1)

    for root in children.get(None, []):
        visit(root, 0)
    return rows


def _domain_rows(document):
    rows = []
    for item in _items(document.get("spans")):
        if item.get("parentSpanId") is not None:
            continue
        rows.append("| %s | %s | %s | %s |" % (
            _text(item.get("domain"), "unknown"), _span_name(item), _duration(item),
            _text(item.get("status"), "unknown")))
    return rows


def _counts(payload):
    result = []
    for item in _items(payload.get("semanticCounts")):
        if not isinstance(item, dict):
            continue
        result.append(_text(item.get("name"), "count") + "=" + _measure(item))
    return "; ".join(result) or "not supplied"


def _payload_summary(payloads, call_id, direction):
    values = [item for item in _items(payloads)
              if isinstance(item, dict) and item.get("callId") == call_id and item.get("direction") == direction]
    if not values:
        return "not supplied"
    return "; ".join("%s (%s; %s)" % (
        _text(item.get("semanticKind"), "unknown kind"),
        _text(item.get("representation"), "representation unknown"), _counts(item)) for item in values)


def _rpc_rows(document):
    by_id = {item["spanId"]: item for item in _items(document.get("spans"))}
    remainders = {item.get("metricId", "").removesuffix("-uncovered-remainder"): item
                  for item in _items(document.get("derivedMetrics"))
                  if isinstance(item, dict) and item.get("metricId", "").endswith("-uncovered-remainder")}
    payloads = document.get("payloads", [])
    rows = []
    for link in _items(document.get("links")):
        if link.get("kind") != "rpc":
            continue
        call_id = link["callId"]
        client, server = by_id[link["from"]], by_id[link["to"]]
        remainder = remainders.get(call_id)
        remainder_text = _measure(remainder) if remainder else "unknown — prerequisites not proven"
        rows.append("| `%s` | %s | %s | %s | %s | %s |" % (
            _text(call_id), _duration(client), _duration(server), remainder_text,
            _payload_summary(payloads, call_id, "request"), _payload_summary(payloads, call_id, "response")))
    return rows


def _payload_rows(document):
    rows = []
    for item in _items(document.get("payloads")):
        if not isinstance(item, dict):
            continue
        rows.append("| `%s` | %s | %s | %s | %s | %s | %s |" % (
            _text(item.get("callId"), "unbound"), _text(item.get("direction"), "unknown"),
            _text(item.get("semanticKind"), "unknown"),
            _text(item.get("representation"), "unknown"), _counts(item),
            _measure(item.get("diagnosticSerializedBytes")), _measure(item.get("wireBytes"))))
    return rows


def _background_lines(document):
    operations = _items(document.get("backgroundOperations"))
    if not operations:
        return ["No background operation was registered. This does not prove that the operation had no background work."]
    lines = []
    for operation in operations:
        if not isinstance(operation, dict):
            continue
        lines += ["### " + _text(operation.get("backgroundOperationId"), "Unidentified background operation"), "",
                  "Status: %s. Ownership: %s. Location: %s." % (
                      _text(operation.get("status"), "unknown"),
                      _text(operation.get("ownership"), "unknown"),
                      _text(operation.get("location"), "unknown")), "",
                  "| Stage | Evidence |", "|---|---|"]
        stages = _items(operation.get("stages"))
        if not stages:
            lines.append("| unknown | no lifecycle stages supplied |")
        for stage in stages:
            if not isinstance(stage, dict):
                continue
            if stage.get("spanId"):
                evidence = "span `" + _text(stage["spanId"]) + "`"
            else:
                evidence = _measure(stage)
            lines.append("| %s | %s |" % (_text(stage.get("name"), "unknown"), evidence))
        lines.append("")
    return lines


def _critical_lines(document):
    value = document.get("criticalPath")
    if not isinstance(value, dict):
        return ["Critical path was not requested or could not be constructed."]
    if value.get("availability") == "available":
        spans = {item["spanId"]: item for item in _items(document.get("spans"))}
        path = " → ".join(_span_name(spans.get(identifier, {"spanId": identifier}))
                          for identifier in value.get("spanIds", []))
        return ["Duration: **%s**." % _measure(value), "", "Proven path: " + (path or "not supplied") + ".",
                "", "Parallel branches are not summed; this is the longest proven dependency path."]
    return ["Status: %s. Reason: %s." % (
        _text(value.get("status"), value.get("availability", "partial")),
        _text(value.get("reason"), "insufficient causal or clock evidence"))]


def render(document):
    """Render only contract fields; arbitrary payload values are never copied."""
    diagnostics = document.get("diagnostics", {})
    stream = document.get("streamStatus", {})
    lines = ["# Operation map: " + _text(document.get("operationId")), "",
             "Analysis status: **%s**. Diagnostic level: **%s**." % (
                 _text(document.get("analysisStatus"), "unknown"), _text(diagnostics.get("level"), "unknown")), "",
             "Event stream: complete=%s, truncated=%s, dropped=%s." % (
                 _text(stream.get("complete"), "unknown"), _text(stream.get("truncated"), "unknown"),
                 _text(stream.get("droppedEvents"), "unknown")), "", "## Producers", "",
             "| Producer | Domain | Status | Coverage | Reason |", "|---|---|---|---|---|"]
    emitters = _items(document.get("emitters"))
    for emitter in emitters:
        lines.append("| `%s` | %s | %s | %s | %s |" % (
            _text(emitter.get("emitterId")), _text(emitter.get("domain"), "unknown"),
            _text(emitter.get("status"), "unknown"), _text(emitter.get("coverage"), "unknown"),
            _text(emitter.get("reason"), "—")))
    if not emitters:
        lines.append("| — | unknown | unknown | unknown | producer inventory not supplied |")
    lines += ["",
             "## Domain windows", "",
             "These are recorded root windows, not a sum of nested work. Different domains may overlap.", "",
             "| Domain | Window | Duration | Status |", "|---|---|---:|---|"]
    lines += _domain_rows(document) or ["| unknown | no root window supplied | unknown | unknown |"]
    lines += ["",
             "## Operation steps", "",
             "Durations are inclusive; nested and overlapping spans are not summed.", "",
             "| Step | Domain | Kind | Duration | Status | Boundary | Evidence |",
             "|---|---|---|---:|---|---|---|"]
    lines += _span_rows(document) or ["| — | — | — | unknown | — | — | no spans supplied |"]

    lines += ["", "## RPC calls", "",
              "The uncovered remainder is the client RPC window outside the correlated server span; it is not network-only time.", "",
              "| Call | Client window | Server body | Uncovered remainder | Request semantics | Response semantics |",
              "|---|---:|---:|---:|---|---|"]
    lines += _rpc_rows(document) or ["| — | unknown | unknown | unknown | not supplied | not supplied |"]

    lines += ["", "## Payloads", "",
              "Semantic content, diagnostic serialization size, and actual wire bytes are distinct measurements.", "",
              "| Call | Direction | Semantic kind | Representation | Counts | Diagnostic bytes | Wire bytes |",
              "|---|---|---|---|---|---:|---:|"]
    lines += _payload_rows(document) or ["| — | — | — | — | not supplied | unknown | unknown |"]

    lines += ["", "## Background lifecycle", ""] + _background_lines(document)

    lines += ["## Milestones", "", "| Milestone | Availability | Predicate or event |",
              "|---|---|---|"]
    milestones = _items(document.get("milestones"))
    for item in milestones:
        if not isinstance(item, dict):
            continue
        evidence = item.get("predicate") or item.get("eventRef") or item.get("reason")
        availability = _text(item.get("availability"), "unknown")
        if item.get("availability") == "available" and item.get("evidenceKind"):
            availability += " (" + _text(item["evidenceKind"]) + ")"
        elif item.get("availability") != "available" and item.get("reason"):
            availability += " — " + _text(item["reason"])
        lines.append("| %s | %s | %s |" % (
            _text(item.get("name"), "unknown"), availability, _text(evidence, "not supplied")))
    if not milestones:
        lines.append("| — | unknown | no product milestones supplied |")

    lines += ["", "## Coverage and unknowns", "", "| Domain | Coverage |", "|---|---|"]
    coverage = document.get("coverage", {})
    if isinstance(coverage, dict):
        for name, value in coverage.items():
            lines.append("| %s | %s |" % (_text(name), _text(value)))
    if not coverage:
        lines.append("| all | unknown |")

    lines += ["", "## Clock domains", "", "| Clock | Kind | Unit | Resolution |",
              "|---|---|---|---:|"]
    for clock in _items(document.get("clocks")):
        lines.append("| `%s` | %s | %s | %s |" % (
            _text(clock.get("clockId")), _text(clock.get("kind")), _text(clock.get("unit")),
            _text(clock.get("resolution"), "unknown")))

    lines += ["", "## Critical path", ""] + _critical_lines(document)
    equivalence = document.get("equivalence", {})
    lines += ["", "## Product result", "",
              "Equivalence: **%s**. %s" % (
                  _text(equivalence.get("status"), "unverified"),
                  _text(equivalence.get("reason"), "No product equivalence statement supplied.")),
              "", "## Limitations", ""]
    limitations = _items(document.get("limitations"))
    lines += ["- " + _text(item) for item in limitations] or [
        "- No additional analyzer limitations were recorded; coverage and product-result gaps remain as shown above."]
    return "\n".join(lines) + "\n"


def write_report(path, document):
    path = Path(path)
    path.write_text(render(document), encoding="utf-8")
    return path
