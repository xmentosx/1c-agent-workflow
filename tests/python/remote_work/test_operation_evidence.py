import json
from pathlib import Path
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))

from itl_remote.common import WorkError, read_json, write_json
from itl_remote import jobs, operation_evidence


def span(identifier, duration, *, kind="work", call=None, clock="mono"):
    value = {"spanId": identifier, "kind": kind, "clockId": clock,
             "duration": {"availability": "available", "evidenceKind": "measured",
                          "value": duration, "unit": "ms"}}
    if call:
        value["callId"] = call
    return value


class OperationEvidenceTests(unittest.TestCase):
    def evidence(self):
        return {"schemaVersion": 1, "jobId": "job-1", "iterationId": 0,
                "operationId": "operation-1", "diagnostics": {"level": "D1"},
                "clocks": [{"clockId": "mono", "kind": "monotonic", "unit": "ms"}],
                "spans": [span("client", 2325, kind="rpcWindow", call="call-1"),
                          span("server", 2267, call="call-1")],
                "links": [{"kind": "rpc", "from": "client", "to": "server", "callId": "call-1",
                           "contained": True}],
                "coverage": {"client": "partial", "serverWithoutContext": "partial",
                             "serverWithContext": "unknown", "background": "unknown"},
                "milestones": [{"name": "fullyReady", "availability": "unknown",
                                "reason": "product predicate not supplied"}],
                "equivalence": {"status": "unverified", "reason": "product predicate not supplied"},
                "streamStatus": {"complete": True, "truncated": False, "droppedEvents": 0}}

    def test_normalizes_rpc_remainder_without_calling_it_network(self):
        value = operation_evidence.normalize(self.evidence(), job_id="job-1", iteration_id=0)
        self.assertEqual(58, value["derivedMetrics"][0]["value"])
        self.assertIn("not network", value["derivedMetrics"][0]["definition"])
        self.assertEqual("partial", value["analysisStatus"])
        self.assertIsNone(value["milestones"][0].get("value"))

    def test_longest_path_uses_parallel_dependencies_instead_of_sum(self):
        spans = [span("prepare", 2000), span("apply", 3000), span("background", 5000), span("join", 1000)]
        links = [{"kind": "continues", "from": "prepare", "to": "apply"},
                 {"kind": "spawn", "from": "prepare", "to": "background"},
                 {"kind": "join", "from": "apply", "to": "join"},
                 {"kind": "join", "from": "background", "to": "join"}]
        result = operation_evidence.longest_path(spans, links, "join")
        self.assertEqual(8000, result["value"])
        self.assertEqual(["prepare", "background", "join"], result["spanIds"])

    def test_rejects_foreign_duplicate_broken_and_cyclic_evidence(self):
        cases = []
        foreign = self.evidence(); foreign["jobId"] = "other"; cases.append(foreign)
        duplicate = self.evidence(); duplicate["spans"].append(dict(duplicate["spans"][0])); cases.append(duplicate)
        broken = self.evidence(); broken["links"][0]["to"] = "missing"; cases.append(broken)
        cyclic = self.evidence(); cyclic["links"] = [{"kind": "continues", "from": "client", "to": "server"},
                                                    {"kind": "continues", "from": "server", "to": "client"}]; cases.append(cyclic)
        for value in cases:
            with self.subTest(value=value):
                with self.assertRaises(WorkError):
                    operation_evidence.normalize(value, job_id="job-1", iteration_id=0)

    def test_incompatible_units_and_negative_remainder_never_become_a_metric(self):
        different = self.evidence(); different["spans"][1]["duration"]["unit"] = "ns"
        value = operation_evidence.normalize(different, job_id="job-1", iteration_id=0)
        self.assertEqual([], value["derivedMetrics"])
        self.assertTrue(any("unit" in item for item in value["limitations"]))
        negative = self.evidence(); negative["spans"][1]["duration"]["value"] = 2400
        value = operation_evidence.normalize(negative, job_id="job-1", iteration_id=0)
        self.assertEqual([], value["derivedMetrics"])
        self.assertTrue(any("negative" in item for item in value["limitations"]))

    def test_rpc_remainder_requires_explicit_interval_containment(self):
        value = self.evidence()
        del value["links"][0]["contained"]
        normalized = operation_evidence.normalize(value, job_id="job-1", iteration_id=0)
        self.assertEqual([], normalized["derivedMetrics"])
        self.assertTrue(any("containment not proven" in item for item in normalized["limitations"]))

    def test_each_rpc_call_id_identifies_one_correlated_pair(self):
        value = self.evidence()
        value["links"].append(dict(value["links"][0]))
        with self.assertRaisesRegex(WorkError, "RPC_CALL_DUPLICATE"):
            operation_evidence.normalize(value, job_id="job-1", iteration_id=0)

    def test_large_ticks_must_be_exact_decimal_strings_and_unknown_is_not_zero(self):
        value = self.evidence()
        value["spans"][0]["startTicks"] = "9007199254740993"
        value["spans"][0]["endTicks"] = "9007199254743318"
        value["payloads"] = [{"callId": "call-1", "wireBytes": {"availability": "unknown",
                                                                    "value": None, "reason": "not collected"}}]
        normalized = operation_evidence.normalize(value, job_id="job-1", iteration_id=0)
        self.assertEqual("9007199254740993", normalized["spans"][0]["startTicks"])
        self.assertIsNone(normalized["payloads"][0]["wireBytes"]["value"])
        value["spans"][0]["startTicks"] = 9007199254740993
        with self.assertRaisesRegex(WorkError, "TICKS"):
            operation_evidence.normalize(value, job_id="job-1", iteration_id=0)

    def test_truncated_or_unclosed_stream_is_partial(self):
        value = self.evidence(); value["streamStatus"].update(complete=False, truncated=True, droppedEvents=2)
        value["spans"][0]["status"] = "running"
        normalized = operation_evidence.normalize(value, job_id="job-1", iteration_id=0)
        self.assertEqual("partial", normalized["analysisStatus"])
        self.assertTrue(any("truncated" in item for item in normalized["limitations"]))

    def test_unknown_fields_are_rejected_before_public_normalization(self):
        value = self.evidence(); value["credential"] = "must-stay-private"
        with self.assertRaisesRegex(WorkError, "UNKNOWN_FIELD"):
            operation_evidence.normalize(value, job_id="job-1", iteration_id=0)

    def test_v1_remains_valid_and_v2_requires_diagnostics(self):
        scenario = {"schemaVersion": 1, "id": "old", "readyDescription": "ready", "dataIdentity": "d",
                    "repeatable": True, "mutates": False, "commands": {"action": ["x"], "verify": ["y"]}}
        jobs.validate_scenario(scenario)
        scenario["schemaVersion"] = 2
        with self.assertRaisesRegex(WorkError, "DIAGNOSTICS"):
            jobs.validate_scenario(scenario)
        scenario["diagnostics"] = {"schemaVersion": 1, "level": "D1",
                                   "evidencePath": "private/operation-evidence.json", "required": False}
        jobs.validate_scenario(scenario)
        for path in ("../operation-evidence.json", "operation-evidence.json", "C:/private/evidence.json"):
            scenario["diagnostics"]["evidencePath"] = path
            with self.subTest(path=path):
                with self.assertRaisesRegex(WorkError, "PATH"):
                    jobs.validate_scenario(scenario)

    def test_file_analysis_preserves_private_raw_and_writes_public_unicode_derivative(self):
        with tempfile.TemporaryDirectory(prefix="Доказательства с пробелом ") as temp:
            root = Path(temp); raw = root / "private/operation-evidence.json"; public = root / "operation-evidence.json"
            write_json(raw, self.evidence())
            summary = operation_evidence.analyze_file(raw, public, job_id="job-1", iteration_id=0)
            self.assertTrue(raw.is_file())
            self.assertTrue(public.is_file())
            self.assertEqual("partial", summary["status"])
            self.assertEqual(read_json(public)["operationId"], "operation-1")


if __name__ == "__main__":
    unittest.main()
