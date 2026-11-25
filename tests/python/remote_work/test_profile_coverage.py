"""Actual 8.3.27 file-session shapes, plus missing/foreign-family regressions."""
import copy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / ".agents/skills/itl-remote-runner/scripts"))
from itl_remote import profiling
from itl_remote.common import WorkError, read_json

FIXTURES = Path(__file__).parent / "fixtures/rdbg-file-profile"


class ProfileCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL серверный профиль ")
        self.root = Path(self.temp.name)
        self.discovery = ET.parse(FIXTURES / "discovery.xml").getroot()
        self.targets = [profiling.fields(t) for t in self.discovery.findall("{" + profiling.RESPONSE + "}id")]
        first = self.targets[0]
        self.proof = {"targetIds": [t["id"] for t in self.targets],
                      "targetTypes": {t["id"]: t["targetType"] for t in self.targets},
                      "seanceId": first["seanceId"], "infoBaseInstanceID": first["infoBaseInstanceID"],
                      "infoBaseAlias": first["infoBaseAlias"], "requiredTypes": profiling.required_profile_types("file")}
        self.client, self.server = FIXTURES / "client.xml", FIXTURES / "server.xml"
        tree = ET.parse(self.client)
        self.session = next(tree.iter("{" + profiling.MEASURE + "}sessionID")).text

    def tearDown(self):
        self.temp.cleanup()

    def test_real_discovery_keeps_both_file_contexts(self):
        selected = profiling.select_runtime_session(self.targets, "DefAlias", session_number=1)
        self.assertEqual(self.targets, selected)
        self.assertEqual({"ManagedClient", "ServerEmulation"}, {t["targetType"] for t in selected})

    def test_foreign_sessions_instances_and_background_jobs_are_not_adopted(self):
        foreign = [{**t, "id": "foreign-" + t["id"], "seanceId": "foreign", "seanceNo": "2"} for t in self.targets]
        background = {**self.targets[0], "id": "job", "targetType": "JobFileMode"}
        selected = profiling.select_runtime_session([*foreign, background, *self.targets], "DefAlias",
                                                    self.proof["seanceId"], self.proof["infoBaseInstanceID"])
        self.assertEqual(self.targets, selected)

    def test_both_native_packet_families_are_required_for_completeness(self):
        complete = profiling.analyze_raw([self.client, self.server], self.session, self.proof)
        self.assertTrue(complete["complete"])
        self.assertEqual(["ManagedClient", "ServerEmulation"], complete["coverage"]["observedTypes"])
        self.assertEqual([], complete["coverage"]["missingTypes"])
        self.assertNotIn("totalSeconds", complete)  # overlapping family totals are not summed
        partial = profiling.analyze_raw([self.client], self.session, self.proof)
        self.assertFalse(partial["complete"])
        self.assertEqual(["ServerEmulation"], partial["coverage"]["missingTypes"])
        self.assertEqual(1, len(partial["coverage"]["missingTargetIds"]))
        self.assertEqual(1, len(partial["packets"]))

    def test_foreign_packet_and_relabelled_family_are_rejected(self):
        foreign = {**self.proof, "seanceId": "different-session"}
        with self.assertRaisesRegex(WorkError, "FOREIGN_PROFILE_PACKET"):
            profiling.analyze_raw([self.client], self.session, foreign)
        wrong_type = copy.deepcopy(self.proof)
        for key in wrong_type["targetTypes"]:
            wrong_type["targetTypes"][key] = "Server"
        with self.assertRaisesRegex(WorkError, "PROFILE_TARGET_TYPE_MISMATCH"):
            profiling.analyze_raw([self.client], self.session, wrong_type)

    def test_file_packets_do_not_satisfy_server_base_coverage(self):
        proof = {**self.proof, "requiredTypes": profiling.required_profile_types("server")}
        result = profiling.analyze_raw([self.client, self.server], self.session, proof)
        self.assertFalse(result["complete"])
        self.assertEqual(["Server"], result["coverage"]["missingTypes"])

    def test_native_client_type_is_preserved_and_thin_packet_cannot_substitute_for_it(self):
        # An explicit transport-shape variant; the original thin-client packets
        # remain untouched and this is not claimed as a real thick-client capture.
        tree = ET.parse(self.client)
        for field in tree.iter("{" + profiling.DATA + "}targetType"):
            if field.text == "ManagedClient":
                field.text = "Client"
        variant = self.root / "Толстый клиент.xml"
        tree.write(variant, encoding="utf-8", xml_declaration=True)
        proof = copy.deepcopy(self.proof)
        for identifier, kind in proof["targetTypes"].items():
            if kind == "ManagedClient":
                proof["targetTypes"][identifier] = "Client"
        proof["requiredTypes"] = profiling.required_profile_types("file", "Client")
        complete = profiling.analyze_raw([variant, self.server], self.session, proof)
        self.assertTrue(complete["complete"])
        self.assertEqual(["Client", "ServerEmulation"], complete["coverage"]["observedTypes"])
        partial = profiling.analyze_raw([variant], self.session, proof)
        self.assertFalse(partial["complete"])
        self.assertEqual(["ServerEmulation"], partial["coverage"]["missingTypes"])
        with self.assertRaisesRegex(WorkError, "PROFILE_TARGET_TYPE_MISMATCH"):
            profiling.analyze_raw([self.client, self.server], self.session, proof)

    def collector(self):
        return profiling.Rdbg({"url": "http://127.0.0.1:1", "infoBaseAlias": "DefAlias", "collectTimeoutSeconds": 0},
                              self.proof, self.root / "raw")

    def test_partial_finish_preserves_profile_json_and_original_packets(self):
        collector = self.collector()
        collector.raw = [self.client]
        collector.session = self.session
        original = self.client.read_bytes()
        with patch.object(collector, "call", return_value=ET.Element("response")):
            result = collector.finish()
        self.assertFalse(result["complete"])
        self.assertEqual(result, read_json(self.root / "raw/profile.json"))
        self.assertEqual(original, self.client.read_bytes())

    def test_uncertain_attach_detaches_owned_targets_and_debugger(self):
        collector = self.collector()
        calls = []
        def rpc(command, **kwargs):
            calls.append(command)
            if command == "attachDebugUI":
                node = ET.Element("response")
                ET.SubElement(node, "{" + profiling.RESPONSE + "}result").text = "registered"
                return node
            if command == "getDbgTargets":
                return self.discovery
            if command == "attachDetachDbgTargets" and kwargs.get("attach"):
                raise WorkError("ATTACH_FAILED")
            return ET.Element("response")
        with patch.object(collector, "call", side_effect=rpc):
            with self.assertRaisesRegex(WorkError, "ATTACH_FAILED"):
                collector.open()
        self.assertIn("detachDebugUI", calls)
        self.assertEqual(2, calls.count("attachDetachDbgTargets"))
        self.assertEqual([], read_json(self.root / "raw/cleanup.json")["errors"])

    def test_attach_and_cleanup_failures_are_both_preserved(self):
        collector = self.collector()
        def rpc(command, **kwargs):
            if command == "attachDebugUI":
                node = ET.Element("response")
                ET.SubElement(node, "{" + profiling.RESPONSE + "}result").text = "registered"
                return node
            if command == "getDbgTargets":
                return self.discovery
            if command == "attachDetachDbgTargets":
                raise WorkError("ATTACH_FAILED" if kwargs.get("attach") else "DETACH_FAILED")
            return ET.Element("response")
        with patch.object(collector, "call", side_effect=rpc):
            with self.assertRaises(WorkError) as raised:
                collector.open()
        self.assertIn("ATTACH_FAILED", str(raised.exception))
        self.assertIn("DETACH_FAILED", str(raised.exception))
        self.assertIn("DETACH_FAILED", raised.exception.cleanup_errors[0])
        self.assertEqual(["DETACH_FAILED"], read_json(self.root / "raw/cleanup.json")["errors"])

    def test_duplicate_selected_discovery_id_is_not_silently_overwritten(self):
        collector = self.collector()
        duplicated = copy.deepcopy(self.discovery)
        duplicated.append(copy.deepcopy(duplicated[0]))
        calls = []
        def rpc(command, **kwargs):
            calls.append(command)
            node = ET.Element("response")
            if command == "attachDebugUI":
                ET.SubElement(node, "{" + profiling.RESPONSE + "}result").text = "registered"
            return duplicated if command == "getDbgTargets" else node
        with patch.object(collector, "call", side_effect=rpc):
            with self.assertRaisesRegex(WorkError, "OWNERSHIP_MISMATCH"):
                collector.open()
        self.assertNotIn("attachDetachDbgTargets", calls)
        self.assertIn("detachDebugUI", calls)


if __name__ == "__main__":
    unittest.main()
