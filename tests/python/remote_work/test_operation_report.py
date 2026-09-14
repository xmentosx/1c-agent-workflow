from pathlib import Path
import sys
import unittest


REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))

from itl_remote import operation_evidence, operation_report
from itl_remote.common import WorkError


def measured(value, unit="ms"):
    return {"availability": "available", "evidenceKind": "measured",
            "value": value, "unit": unit}


def span(identifier, name, domain, duration, *, kind="work", parent=None,
         call=None, source=None):
    value = {"spanId": identifier, "name": name, "domain": domain,
             "kind": kind, "clockId": domain + "-clock",
             "duration": measured(duration), "status": "completed"}
    if parent:
        value["parentSpanId"] = parent
    if call:
        value["callId"] = call
    if source:
        value["sourceRef"] = source
    return value


class OperationReportTests(unittest.TestCase):
    def evidence(self):
        spans = [
            span("client-operation", "Open plan", "client", 10000, kind="container"),
            span("client-prepare", "Prepare parameters", "client", 1000,
                 parent="client-operation", source="CommonModule.Client:10"),
            span("client-rpc", "Load model", "client", 5000,
                 kind="rpcWindow", parent="client-operation", call="call-1"),
            span("server-rpc", "Load model server body", "serverWithoutContext", 4200,
                 kind="container", call="call-1"),
            span("server-read", "Read source data", "serverWithoutContext", 1200,
                 parent="server-rpc"),
            span("server-build", "Build model", "serverWithoutContext", 2600,
                 parent="server-rpc"),
            span("background", "Build secondary data", "background", 2000,
                 source="BackgroundJob:42"),
            span("client-apply", "Apply model", "client", 2000, parent="client-operation"),
        ]
        return {
            "schemaVersion": 1,
            "jobId": "job-1",
            "iterationId": 0,
            "operationId": "open-plan-1",
            "diagnostics": {"level": "D1"},
            "clocks": [
                {"clockId": "client-clock", "kind": "monotonic", "unit": "ms", "resolution": 1},
                {"clockId": "serverWithoutContext-clock", "kind": "durationCounter", "unit": "ms"},
                {"clockId": "background-clock", "kind": "durationCounter", "unit": "ms"},
            ],
            "spans": spans,
            "links": [
                {"kind": "rpc", "from": "client-rpc", "to": "server-rpc",
                 "callId": "call-1", "contained": True},
                {"kind": "continues", "from": "client-prepare", "to": "client-rpc"},
                {"kind": "spawn", "from": "client-rpc", "to": "background"},
                {"kind": "continues", "from": "client-rpc", "to": "client-apply"},
                {"kind": "join", "from": "background", "to": "client-apply"},
            ],
            "payloads": [
                {"callId": "call-1", "direction": "request", "semanticKind": "formContext",
                 "representation": "structure", "semanticCounts": [
                     {"name": "parameters", **measured(6, "field")},
                 ], "wireBytes": {"availability": "unknown", "value": None,
                                   "reason": "transport collector unavailable"}},
                {"callId": "call-1", "direction": "response", "semanticKind": "modelData",
                 "representation": "storageHandle", "semanticCounts": [
                     {"name": "rows", **measured(10102, "row")},
                 ], "diagnosticSerializedBytes": measured(18400000, "byte"),
                 "wireBytes": {"availability": "unknown", "value": None,
                               "reason": "platform protocol not captured"}},
            ],
            "milestones": [
                {"name": "apiReturned", "availability": "available",
                 "evidenceKind": "measured", "eventRef": "client-rpc:end",
                 "predicate": "Synchronous API returned"},
                {"name": "fullyReady", "availability": "unknown", "value": None,
                 "reason": "product predicate not supplied"},
            ],
            "backgroundOperations": [
                {"backgroundOperationId": "background-1", "status": "completed",
                 "ownership": "correlated", "location": "worker session 12",
                 "stages": [
                     {"name": "started", "spanId": "background"},
                     {"name": "resultAvailable", "availability": "unknown", "value": None,
                      "reason": "producer marker unavailable"},
                 ]},
            ],
            "coverage": {"client": "complete", "serverWithoutContext": "partial",
                         "serverWithContext": "notApplicable", "background": "partial"},
            "criticalPath": {"targetSpanId": "client-apply"},
            "equivalence": {"status": "unverified", "reason": "single diagnostic run"},
            "streamStatus": {"complete": True, "truncated": False, "droppedEvents": 0},
        }

    def test_renders_one_operation_as_steps_calls_payload_background_and_gaps(self):
        normalized = operation_evidence.normalize(self.evidence(), job_id="job-1", iteration_id=0)
        report = operation_report.render(normalized)

        for heading in ("# Operation map: open-plan-1", "## Domain windows", "## Operation steps",
                        "## RPC calls", "## Payloads", "## Background lifecycle",
                        "## Milestones", "## Coverage and unknowns", "## Critical path"):
            self.assertIn(heading, report)
        self.assertIn("Prepare parameters", report)
        self.assertIn("Open plan", report)
        self.assertIn("10,000 ms", report)
        self.assertIn("↳ Read source data", report)
        self.assertIn("call-1", report)
        self.assertIn("5,000 ms", report)
        self.assertIn("4,200 ms", report)
        self.assertIn("800 ms", report)
        self.assertIn("not network-only time", report)
        self.assertIn("parameters=6 field", report)
        self.assertIn("rows=10,102 row", report)
        self.assertIn("unknown — platform protocol not captured", report)
        self.assertIn("resultAvailable", report)
        self.assertIn("unknown — producer marker unavailable", report)
        self.assertIn("inclusive; nested and overlapping spans are not summed", report)
        self.assertIn("product predicate not supplied", report)

    def test_report_escapes_markdown_and_never_renders_arbitrary_payload_values(self):
        evidence = self.evidence()
        evidence["spans"][0]["name"] = "Prepare | secret\nline"
        evidence["payloads"][0]["rawValue"] = "must-not-be-public"
        normalized = operation_evidence.normalize(evidence, job_id="job-1", iteration_id=0)
        report = operation_report.render(normalized)

        self.assertIn("Prepare \\| secret line", report)
        self.assertNotIn("must-not-be-public", report)

    def test_parent_must_reference_a_real_acyclic_span(self):
        evidence = self.evidence()
        evidence["spans"][0]["parentSpanId"] = "missing"
        with self.assertRaisesRegex(WorkError, "PARENT"):
            operation_evidence.normalize(evidence, job_id="job-1", iteration_id=0)

        evidence = self.evidence()
        evidence["spans"][0]["parentSpanId"] = "client-rpc"
        evidence["spans"][1]["parentSpanId"] = "client-prepare"
        with self.assertRaisesRegex(WorkError, "PARENT_CYCLE"):
            operation_evidence.normalize(evidence, job_id="job-1", iteration_id=0)


if __name__ == "__main__":
    unittest.main()
