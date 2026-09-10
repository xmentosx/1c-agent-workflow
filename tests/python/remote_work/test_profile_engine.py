"""Profile coverage and debugger cleanup reach the engine's final verdict."""
import copy
import sys
from pathlib import Path
import unittest
from unittest.mock import patch

import test_runtime
from itl_remote import execution, profiling
from itl_remote.common import WorkError, write_json, read_json, digest
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

    def execute(self, fail_cleanup=False, native=None, client_type="ManagedClient"):
        native = native or profiling.analyze_raw([FIXTURES / "client.xml"])
        native.update(complete=False, coverage={"missingTypes": ["ServerEmulation"]})
        test = self
        class Collector:
            def __init__(self, config, proof, output):
                test.assertEqual([client_type, "ServerEmulation"], proof["requiredTypes"])
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
        snapshot = read_json(self.run / "progress.json")
        evidence = snapshot["profiles"][0]
        self.assertEqual(digest(self.run / evidence["path"]), evidence["sha256"])
        self.assertFalse(evidence["complete"])
        self.assertTrue(evidence["workloadVerified"])
        self.assertNotIn("packets", evidence)
        self.assertIn("PROFILE_INCOMPLETE", (self.run / "report.md").read_text(encoding="utf-8"))

    def test_engine_retains_discovered_thick_client_family_and_still_requires_server_coverage(self):
        proof_path = self.run / "runtime-proof.json"
        proof = read_json(proof_path)
        proof["targetTypes"] = {"client": "Client", "server": "ServerEmulation"}
        write_json(proof_path, proof)
        state, result = self.execute(client_type="Client")
        self.assertEqual("partial", state["status"], result)
        self.assertFalse(result["profiles"][0]["complete"])

    def test_failed_debugger_start_cleanup_is_not_reported_as_empty_cleanup(self):
        state, result = self.execute(fail_cleanup=True)
        self.assertEqual("needs-attention", state["status"])
        self.assertEqual(["detach unproven"], result["cleanupErrors"])

    def source_policy(self, policy, modules=None):
        scenario_path = self.package / "scenario.json"
        scenario = read_json(scenario_path)
        scenario["sourceAnalysis"] = policy
        if modules is not None:
            scenario["sourceAnalysisModules"] = modules
        write_json(scenario_path, scenario)
        request = read_json(self.package / "request.json")
        request["scenarioSha256"] = digest(scenario_path)
        write_json(self.package / "request.json", request)

    def test_required_source_capture_runs_after_verification_under_the_same_lease(self):
        from test_source_capture import SourceIndexTests
        source = SourceIndexTests()
        source.setUp()
        self.addCleanup(source.doCleanups)
        self.source_policy("required")
        scenario_path = self.package / 'scenario.json'
        scenario = read_json(scenario_path)
        scenario['commands']['quiesce'] = [sys.executable, '-c',
            'from pathlib import Path; import sys; Path(sys.argv[1]).write_text("released")', '{run}/quiesced.txt']
        write_json(scenario_path, scenario)
        request = read_json(self.package / 'request.json')
        request['scenarioSha256'] = digest(scenario_path)
        write_json(self.package / 'request.json', request)
        test = self
        order = []
        def quiesce(context_path):
            test.assertTrue((test.run / "000-profile/verification.json").is_file())
            test.assertEqual('released', (test.run / 'quiesced.txt').read_text())
            order.append('quiesce')
            return {"status": "released"}
        def captured(snapshot):
            test.assertEqual(['quiesce'], order)
            order.append('capture')
            test.assertEqual("source-capture", snapshot.context["phase"]["name"])
            test.assertTrue((test.run / "000-profile/verification.json").is_file())
            proof = snapshot.context["accessLease"]
            owner = read_json(Path(proof["coordinator"]) / "tickets" / (proof["ticket"] + ".json"))
            test.assertEqual("running", owner["status"])
            return {**source.snapshot, "cleanupErrors": []}
        with patch("itl_remote.source_capture.Snapshot.run", captured), \
                patch("itl_remote.vanessa.quiesce", quiesce):
            state, result = self.execute()
        self.assertEqual("partial", state["status"])  # still missing the server family
        self.assertTrue(result["profiles"][0]["sourceAnalysis"]["requirementSatisfied"])
        self.assertTrue(read_json(self.run / "000-profile/profile.json")["sourceAnalysis"]["requirementSatisfied"])
        self.assertEqual(['quiesce', 'capture'], order)

    def test_unconfirmed_quiescence_keeps_raw_profile_and_never_starts_designer(self):
        self.source_policy("optional")
        with patch("itl_remote.vanessa.quiesce", side_effect=WorkError("ITL_PERFORMANCE_QUIESCENCE_UNPROVEN")), \
                patch("itl_remote.source_capture.Snapshot") as snapshot:
            state, result = self.execute()
        snapshot.assert_not_called()
        self.assertFalse(result['sourceResolution']['captureAttempted'])
        self.assertTrue(result['profiles'][0]['packets'])
        self.assertIn('SOURCE_CAPTURE_FAILED: ITL_PERFORMANCE_QUIESCENCE_UNPROVEN', result['limitations'])

    def test_required_capture_failure_retains_profiles_and_cleanup_errors(self):
        self.source_policy("required")
        with patch("itl_remote.source_capture.Snapshot.run", return_value={"status": "failed", "error": "read denied", "cleanupErrors": ["exit unproven"]}):
            state, result = self.execute()
        self.assertEqual("needs-attention", state["status"])
        self.assertEqual("SOURCE_ANALYSIS_REQUIREMENT_UNSATISFIED", result["error"])
        self.assertEqual(["exit unproven"], result["cleanupErrors"])
        self.assertEqual(1, len(result["profiles"]))

    def test_optional_capture_failure_is_an_explicit_limitation(self):
        self.source_policy("optional")
        with patch("itl_remote.source_capture.Snapshot.run", return_value={"status": "failed", "error": "read denied", "cleanupErrors": []}):
            state, result = self.execute()
        self.assertEqual("partial", state["status"])
        self.assertIn("SOURCE_CAPTURE_FAILED: read denied", result["limitations"])
        self.assertEqual([], result["cleanupErrors"])

    def test_optional_index_failure_does_not_invalidate_intact_raw_measurements(self):
        self.source_policy("optional")
        with patch("itl_remote.source_capture.Snapshot.run", return_value={"status": "captured", "cleanupErrors": []}), \
                patch("itl_remote.source_index.build_manifest", side_effect=WorkError("SOURCE_CAPTURE_INDEX_CHANGED")):
            state, result = self.execute()
        self.assertEqual("partial", state["status"])
        self.assertIn("SOURCE_ANALYSIS_FAILED: SOURCE_CAPTURE_INDEX_CHANGED", result["limitations"])

    def test_cancellation_during_capture_is_not_downgraded_to_optional_failure(self):
        self.source_policy("optional")
        with patch("itl_remote.source_capture.Snapshot.run", return_value={"status": "failed", "error": "CANCELLED", "cleanupErrors": []}):
            state, result = self.execute()
        self.assertEqual("cancelled", state["status"])
        self.assertEqual(1, len(result["profiles"]))


if __name__ == "__main__":
    unittest.main()
