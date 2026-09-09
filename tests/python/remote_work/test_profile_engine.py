"""Profile coverage and debugger cleanup reach the engine's final verdict."""
import copy
from pathlib import Path
import unittest
from unittest.mock import patch

import test_runtime
from itl_remote import execution, profiling
from itl_remote.common import WorkError, write_json
from test_profile_coverage import FIXTURES


class ProfileEngineTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_runtime.RuntimeTests()
        self.fixture.setUp()
        target = self.fixture.profile["targets"]["fixture"]
        target["infoBase"] = {"kind": "file", "path": str(self.fixture.root / "База профиля")}
        self.target = target
        _, self.package = self.fixture.package(mode="profile")
        proof = {"jobId": "one", "clientPid": 123, "targetIds": ["client", "server"],
                 "seanceId": "session", "infoBaseInstanceID": "instance", "infoBaseAlias": "DefAlias"}
        self.run = self.fixture.spool / "runs/one"
        write_json(self.run / "runtime-proof.json", proof)
        write_json(self.run / "onec-process-123.json", {"jobId": "one", "pid": 123, "infoBase": target["infoBase"]})

    def tearDown(self):
        self.fixture.tearDown()

    def execute(self, fail_cleanup=False):
        native = profiling.analyze_raw([FIXTURES / "client.xml"])
        native.update(complete=False, coverage={"missingTypes": ["ServerEmulation"]})
        test = self
        class Collector:
            def __init__(self, config, proof, output):
                test.assertEqual(["ManagedClient", "ServerEmulation"], proof["requiredTypes"])
            def open(self):
                if fail_cleanup:
                    error = WorkError("attach failed; cleanup failed")
                    error.cleanup_errors = ["detach unproven"]
                    raise error
            def start(self): pass
            def finish(self): return copy.deepcopy(native)
            def close(self): pass
        with patch.object(execution, "prepare_debug_server", return_value={"url": "http://127.0.0.1:1"}), \
                patch.object(execution, "Rdbg", Collector), patch("itl_remote.common.capture", return_value=b"{}"):
            return self.fixture.execute(self.package)

    def test_incomplete_collected_profile_keeps_native_evidence_and_marks_partial(self):
        state, result = self.execute()
        self.assertEqual("partial", state["status"], result)
        self.assertEqual(1, len(result["profiles"]))
        self.assertFalse(result["profiles"][0]["complete"])
        self.assertIn("PROFILE_INCOMPLETE", (self.run / "report.md").read_text(encoding="utf-8"))

    def test_failed_debugger_start_cleanup_is_not_reported_as_empty_cleanup(self):
        state, result = self.execute(fail_cleanup=True)
        self.assertEqual("needs-attention", state["status"])
        self.assertEqual(["detach unproven"], result["cleanupErrors"])


if __name__ == "__main__":
    unittest.main()
