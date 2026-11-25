"""Own-client session number resolves a unique debugger session, not a first target."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / ".agents/skills/itl-remote-runner/scripts"))
from itl_remote import profiling
from itl_remote.common import WorkError, write_json, read_json


def target(identifier="client", sid="session", instance="instance", kind="ManagedClient", number="1", alias="base"):
    return dict(id=identifier, seanceId=sid, infoBaseInstanceID=instance, targetType=kind,
                seanceNo=number, infoBaseAlias=alias)


class SessionIdentityTests(unittest.TestCase):
    def test_empty_settings_ack_is_valid_but_empty_discovery_is_not(self):
        from unittest.mock import MagicMock
        with tempfile.TemporaryDirectory() as directory:
            response = MagicMock(status=200)
            response.read.return_value = b""
            response.getheader.return_value = ""
            connection = MagicMock()
            connection.getresponse.return_value = response
            proof = {"targetIds": ["own"], "seanceId": "s", "infoBaseInstanceID": "i", "infoBaseAlias": "base"}
            collector = profiling.Rdbg({"url": "http://127.0.0.1:1550", "infoBaseAlias": "base"}, proof, directory)
            with patch.object(profiling.http.client, "HTTPConnection", return_value=connection):
                for command in ("initSettings", "attachDetachDbgTargets", "setMeasureMode"):
                    self.assertEqual("response", collector.call(command).tag)
                with self.assertRaises(ET.ParseError):
                    collector.call("getDbgTargets")
                response.status = 204
                self.assertEqual("response", collector.call("pingDebugUIParams").tag)
                self.assertEqual([], collector.raw)
                with self.assertRaisesRegex(WorkError, "HTTP_ERROR: 204"):
                    collector.call("getDbgTargets")
            self.assertEqual(b"", (Path(directory) / "000001-initSettings.response.bin").read_bytes())

    def test_filters_foreign_base_and_session_before_resolving_instance(self):
        own = [target(), target("server", kind="Server")]
        candidates = [target("foreign", alias="other"), target("another", number="2"), *own]
        self.assertEqual(own, profiling.select_runtime_session(candidates, "base", session_number=1))

    def test_retained_ufa_thick_client_is_one_owned_client_not_ambiguity(self):
        response = ET.parse(Path(__file__).parent / "fixtures/rdbg-thick-client/discovery.xml").getroot()
        own = [profiling.fields(item) for item in response.findall("{" + profiling.RESPONSE + "}id")]
        self.assertEqual({"Client", "Server"}, {item["targetType"] for item in own})
        candidates = [target("foreign-thin", number="48"), target("foreign-thick", kind="Client", alias="other", number="47"), *own]
        selected = profiling.select_runtime_session(candidates, "base", session_number=47)
        self.assertEqual(own, selected)
        proof = {"targetTypes": {item["id"]: item["targetType"] for item in selected}}
        self.assertEqual("Client", profiling.profile_client_type(proof))
        self.assertEqual(["Client", "Server"], profiling.required_profile_types("server", "Client"))

    def test_two_client_families_in_one_session_are_still_ambiguous(self):
        with self.assertRaisesRegex(WorkError, "CLIENT_AMBIGUOUS"):
            profiling.select_runtime_session([target(), target("thick", kind="Client")], "base", session_number=1)

    def test_retained_thick_client_family_is_written_to_runtime_proof_without_attachment(self):
        discovery = ET.parse(Path(__file__).parent / "fixtures/rdbg-thick-client/discovery.xml").getroot()
        with tempfile.TemporaryDirectory(prefix="ITL толстый клиент ") as directory:
            root = Path(directory)
            base = {"kind": "server", "path": "fixture-server/fixture-base"}
            write_json(root / "context.json", {"jobId": "job", "target": {"infoBase": base},
                                               "rdbg": {"url": "http://127.0.0.1:1550", "infoBaseAlias": "base"}})
            write_json(root / "onec-process-123.json", {"jobId": "job", "pid": 123, "startedAt": "launch", "infoBase": base})
            write_json(root / "session.json", {"jobId": "job", "clientPid": 123, "clientStartedAt": "launch", "sessionNumber": 47})
            calls = []
            def rpc(self, command, **kwargs):
                calls.append(command)
                if command == "getDbgTargets":
                    return discovery
                response = ET.Element("response")
                if command == "attachDebugUI":
                    ET.SubElement(response, "{" + profiling.RESPONSE + "}result").text = "registered"
                return response
            with patch("itl_remote.common.capture", return_value="{}"), patch.object(profiling.Rdbg, "call", rpc):
                result = profiling.runtime_proof(root / "context.json", 123, observation_path="session.json")
            self.assertEqual(["Client", "Server"], result["requiredTypes"])
            self.assertEqual({"Client", "Server"}, set(result["targetTypes"].values()))
            self.assertEqual(47, result["sessionNumber"])
            self.assertEqual(result, read_json(root / "runtime-proof.json"))
            self.assertNotIn("attachDetachDbgTargets", calls)
            self.assertIn("detachDebugUI", calls)

    def test_client_family_proof_cannot_claim_zero_or_multiple_clients(self):
        self.assertEqual("ManagedClient", profiling.profile_client_type({}))  # legacy proof
        for kinds, message in (({}, "CLIENT_NOT_DISCOVERED"), ({"server": "Server"}, "CLIENT_NOT_DISCOVERED"),
                               ({"a": "Client", "b": "ManagedClient"}, "CLIENT_AMBIGUOUS"),
                               (["Client"], "TARGET_TYPES_INVALID")):
            with self.subTest(kinds=kinds), self.assertRaisesRegex(WorkError, message):
                profiling.profile_client_type({"targetTypes": kinds})
        with self.assertRaisesRegex(WorkError, "CLIENT_TYPE_UNSUPPORTED"):
            profiling.required_profile_types("server", "Server")

    def test_same_number_in_two_sessions_or_instances_is_ambiguous(self):
        for foreign in (target("other", sid="other"), target("other", instance="other")):
            with self.subTest(foreign=foreign), self.assertRaisesRegex(WorkError, "SESSION_AMBIGUOUS"):
                profiling.select_runtime_session([target(), foreign], "base", session_number=1)

    def test_exact_existing_identity_keeps_foreign_targets_out(self):
        self.assertEqual([target()], profiling.select_runtime_session(
            [target("foreign", instance="foreign"), target()], "base", "session", "instance"))

    def test_missing_duplicate_or_server_only_targets_fail(self):
        cases = [([], "NOT_DISCOVERED"), ([target(identifier="")], "IDS_INVALID"),
                 ([target(), target()], "IDS_INVALID"),
                 ([target(kind="Server")], "CLIENT_NOT_DISCOVERED"),
                 ([target(), target("second")], "CLIENT_AMBIGUOUS")]
        for targets, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(WorkError, message):
                profiling.select_runtime_session(targets, "base", session_number=1)

    def test_invalid_session_numbers_fail(self):
        for number in (0, -1, 1.5, "NaN", "Infinity", "invalid", True):
            with self.subTest(number=number), self.assertRaisesRegex(WorkError, "NUMBER_INVALID"):
                profiling.select_runtime_session([target()], "base", session_number=number)

    def test_observation_resolves_without_attaching_and_binds_process_start(self):
        with tempfile.TemporaryDirectory(prefix="ITL профиль с пробелом ") as directory:
            root = Path(directory)
            base = {"kind": "file", "path": str(root / "База данных")}
            write_json(root / "context.json", {"jobId": "job", "target": {"infoBase": base},
                                               "rdbg": {"url": "http://127.0.0.1:1550", "infoBaseAlias": "base"}})
            write_json(root / "onec-process-123.json", {"jobId": "job", "pid": 123, "startedAt": "launch", "infoBase": base})
            observation = {"jobId": "job", "clientPid": 123, "clientStartedAt": "launch", "sessionNumber": 1}
            write_json(root / "session.json", observation)
            calls = []
            def rpc(self, command, **kwargs):
                calls.append(command)
                response = ET.Element("response")
                if command == "attachDebugUI":
                    ET.SubElement(response, "{" + profiling.RESPONSE + "}result").text = "registered"
                if command == "getDbgTargets":
                    for value in (target("foreign", number="2"), target()):
                        item = ET.SubElement(response, "{" + profiling.RESPONSE + "}id")
                        for key, field in value.items():
                            ET.SubElement(item, "{" + profiling.DATA + "}" + key).text = field
                return response
            with patch("itl_remote.common.capture", return_value="{}"), patch.object(profiling.Rdbg, "call", rpc):
                result = profiling.runtime_proof(root / "context.json", 123, observation_path="session.json")
                self.assertEqual(["client"], result["targetIds"])
                self.assertEqual("instance", result["infoBaseInstanceID"])
                self.assertEqual(result, read_json(root / "runtime-proof.json"))
                self.assertNotIn("attachDetachDbgTargets", calls)
                self.assertIn("detachDebugUI", calls)
                observation["clientStartedAt"] = "previous launch"
                write_json(root / "session.json", observation)
                calls.clear()
                with self.assertRaisesRegex(WorkError, "FOREIGN_SESSION_OBSERVATION"):
                    profiling.runtime_proof(root / "context.json", 123, observation_path="session.json")
                self.assertEqual([], calls)


if __name__ == "__main__":
    unittest.main()
