from pathlib import Path
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))

from itl_remote import operation_evidence, operation_producer
from itl_remote.common import WorkError, read_json, write_json
from itl_measure import publish_operation_evidence


def measured(value):
    return {"availability": "available", "evidenceKind": "measured", "value": value, "unit": "ms"}


def fragment(emitter, domain, *, span_id, clock_id, coverage="complete"):
    return {"schemaVersion": 1, "jobId": "job-1", "iterationId": 0,
            "operationId": "operation-1", "emitterId": emitter, "domain": domain,
            "coverage": coverage,
            "streamStatus": {"complete": True, "truncated": False, "droppedEvents": 0},
            "clocks": [{"clockId": clock_id, "kind": "durationCounter", "unit": "ms"}],
            "spans": [{"spanId": span_id, "name": emitter, "domain": domain, "kind": "container",
                       "clockId": clock_id, "duration": measured(10), "status": "completed"}]}


class OperationProducerTests(unittest.TestCase):
    def envelope(self):
        return {"schemaVersion": 1, "jobId": "job-1", "iterationId": 0,
                "operationId": "operation-1", "diagnostics": {"level": "D1"},
                "expectedEmitters": [
                    {"emitterId": "client", "domain": "client", "required": True},
                    {"emitterId": "server", "domain": "serverWithoutContext", "required": True},
                    {"emitterId": "background", "domain": "background", "required": False},
                ]}

    def test_merges_transported_fragments_and_marks_missing_producer_partial(self):
        client = fragment("client", "client", span_id="client-window", clock_id="client-clock")
        server = fragment("server", "serverWithoutContext", span_id="server-window", clock_id="server-clock")
        client["spans"][0].update(kind="rpcWindow", callId="call-1")
        server["spans"][0]["callId"] = "call-1"
        client["links"] = [{"kind": "rpc", "from": "client-window", "to": "server-window",
                            "callId": "call-1", "contained": True}]

        raw = operation_producer.assemble(self.envelope(), [json.dumps(client), server])
        normalized = operation_evidence.normalize(raw, job_id="job-1", iteration_id=0)

        self.assertEqual(3, len(normalized["emitters"]))
        self.assertEqual("missing", normalized["emitters"][2]["status"])
        self.assertFalse(normalized["streamStatus"]["complete"])
        self.assertEqual("unknown", normalized["coverage"]["background"])
        self.assertEqual("partial", normalized["analysisStatus"])
        self.assertTrue(any("background missing" in item for item in normalized["limitations"]))

    def test_rejects_foreign_duplicate_and_colliding_fragments(self):
        client = fragment("client", "client", span_id="same", clock_id="same-clock")
        foreign = fragment("server", "serverWithoutContext", span_id="server", clock_id="server-clock")
        foreign["jobId"] = "foreign"
        with self.assertRaisesRegex(WorkError, "FOREIGN_OPERATION"):
            operation_producer.assemble(self.envelope(), [client, foreign])
        with self.assertRaisesRegex(WorkError, "DUPLICATE_EMITTER"):
            operation_producer.assemble(self.envelope(), [client, client])
        server = fragment("server", "serverWithoutContext", span_id="same", clock_id="server-clock")
        with self.assertRaisesRegex(WorkError, "IDENTIFIER_COLLISION"):
            operation_producer.assemble(self.envelope(), [client, server])

    def test_publishes_atomically_under_unicode_path(self):
        client = fragment("client", "client", span_id="client", clock_id="client-clock")
        with tempfile.TemporaryDirectory(prefix="Фрагменты операции с пробелом ") as temp:
            destination = Path(temp) / "private" / "operation-evidence.json"
            operation_producer.publish(self.envelope(), [client], destination)
            self.assertEqual("operation-1", read_json(destination)["operationId"])
            self.assertFalse(destination.with_suffix(".json.tmp").exists())

    def test_scenario_helper_binds_context_identity_and_private_destination(self):
        client = fragment("client", "client", span_id="client", clock_id="client-clock")
        with tempfile.TemporaryDirectory(prefix="Контекст операции с пробелом ") as temp:
            root = Path(temp)
            context_path = root / "context.json"
            write_json(context_path, {"jobId": "job-1", "iterationIndex": 0,
                                      "iteration": str(root / "итерация"),
                                      "diagnostics": {"level": "D1", "evidencePath": "private/operation-evidence.json"}})
            envelope = {"operationId": "operation-1", "expectedEmitters": [
                {"emitterId": "client", "domain": "client", "required": True}]}
            with patch.dict(os.environ, {"ITL_RUN_CONTEXT": str(context_path)}):
                destination = publish_operation_evidence(envelope, [client])
            self.assertEqual(root / "итерация/private/operation-evidence.json", destination)
            self.assertEqual("job-1", read_json(destination)["jobId"])

    def test_bsl_scaffold_builds_memory_fragment_without_worker_file_io(self):
        source = (REPO / ".agents/skills/itl-performance/assets/OperationEvidenceFragment.bsl").read_text(encoding="utf-8")
        self.assertIn("СоздатьФрагментОперации", source)
        self.assertIn("СериализоватьФрагментОперации", source)
        self.assertIn("semanticCounts", source)
        self.assertNotIn("ЗаписьТекста", source)
        self.assertNotIn("ПереместитьФайл", source)


if __name__ == "__main__":
    unittest.main()
