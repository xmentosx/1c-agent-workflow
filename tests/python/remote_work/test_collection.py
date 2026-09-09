"""Collect crashed/running job evidence without manufacturing measurement success."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[3] / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))
from itl_remote import jobs, transport
from itl_remote.common import WorkError, digest, read_json, write_json


class CollectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Сбор после сбоя ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.spool = self.root / "очередь замеров"
        self.run = self.spool / "runs" / "crashed"
        # An actual process exits without writing a result or closing the job state.
        script = """import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from itl_remote.common import write_json
root = Path(sys.argv[2])
write_json(root / 'state/crashed.json', {'id':'crashed','status':'running'})
run = root / 'runs/crashed'
write_json(run / 'phase.json', {'phase':'cleanup','ownedWork':'unknown'})
write_json(run / 'context.json', {'accessLease':{'token':'never-export'}})
write_json(run / 'recovery/attempt/private/settings.json', {'secret':'never-export'})
(run / 'журнал замера.log').write_bytes('до аварии\\n'.encode('utf-8'))
os._exit(77)
"""
        process = subprocess.run([sys.executable, "-X", "utf8", "-c", script, str(RUNTIME), str(self.spool)],
                                 capture_output=True, timeout=20)
        self.assertEqual(77, process.returncode, process.stderr)
        self.connection = transport.Connection({"transport": "exchange", "spool": str(self.spool)})

    def assert_partial(self, value, output):
        self.assertEqual("partial", value["collectionStatus"])
        self.assertFalse(value["resultAvailable"])
        self.assertEqual("running", value["observedJob"]["status"])
        self.assertNotIn("status", value)  # No invented terminal job status.
        self.assertFalse((output / "result.json").exists())
        self.assertFalse((self.run / "result.json").exists())
        self.assertEqual("running", jobs.status(self.spool, "crashed")["status"])
        manifest = read_json(output / "download-manifest.json")
        self.assertEqual(value, manifest)
        self.assertTrue(manifest["observedAt"])
        paths = {entry["path"] for entry in manifest["files"]}
        self.assertIn("журнал замера.log", paths)
        self.assertIn("phase.json", paths)
        self.assertNotIn("context.json", paths)
        self.assertFalse(any("private" in path for path in paths))
        for entry in manifest["files"]:
            self.assertEqual(entry["sha256"], digest(output / entry["path"]))

    def test_default_keeps_result_not_ready_and_does_not_create_output(self):
        for method in (self.connection.collect, lambda job, out: jobs.collect(self.spool, job, out)):
            output = self.root / "нет результата"
            with self.assertRaisesRegex(WorkError, "RESULT_NOT_READY"):
                method("crashed", output)
            self.assertFalse(output.exists())

    def test_local_and_exchange_collect_after_actual_process_crash(self):
        before = {p.relative_to(self.spool): digest(p) for p in self.spool.rglob("*") if p.is_file()}
        local = self.root / "локальные журналы"
        self.assert_partial(jobs.collect(self.spool, "crashed", local, allow_partial=True), local)
        remote = self.root / "удаленные журналы"
        self.assert_partial(self.connection.collect("crashed", remote, allow_partial=True), remote)
        after = {p.relative_to(self.spool): digest(p) for p in self.spool.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_both_cli_routes_expose_partial_option(self):
        config = self.root / "соединение.json"
        write_json(config, self.connection.profile)
        for route in (["collect", "--spool", str(self.spool)],
                      ["remote", "--connection", str(config), "--action", "collect"]):
            output = self.root / route[0]
            process = subprocess.run([sys.executable, "-X", "utf8", str(RUNTIME / "remote_work.py"),
                                      *route, "--id", "crashed", "--output", str(output), "--allow-partial"],
                                     capture_output=True, text=True, encoding="utf-8", timeout=20)
            self.assertEqual(0, process.returncode, process.stdout + process.stderr)
            self.assert_partial(json.loads(process.stdout), output)

    def test_rpc_process_boundary_collects_recovery_logs_without_result(self):
        write_json(self.run / "recovery/attempt/observation.json", {"ownedWork":"unknown"})
        def rpc(message):
            process = subprocess.run([sys.executable, "-X", "utf8", str(RUNTIME / "remote_work.py"),
                                      "rpc", "--spool", str(self.spool)], input=json.dumps(message),
                                     capture_output=True, text=True, encoding="utf-8", timeout=20)
            self.assertEqual(0, process.returncode, process.stdout + process.stderr)
            return json.loads(process.stdout)
        output = self.root / "через RPC"
        with patch.object(self.connection, "call", side_effect=rpc):
            self.assert_partial(self.connection.collect("crashed", output, allow_partial=True), output)
        self.assertEqual("unknown", read_json(output / "recovery/attempt/observation.json")["ownedWork"])

    def test_allow_partial_preserves_completed_result_contract(self):
        result = {"status":"failed", "cleanupErrors":["owned process state unknown"]}
        write_json(self.run / "result.json", result)
        output = self.root / "готовый неуспешный замер"
        self.assertEqual(result, self.connection.collect("crashed", output, allow_partial=True))
        self.assertEqual("result", read_json(output / "download-manifest.json")["collectionStatus"])

    def test_no_run_and_existing_destination_remain_errors(self):
        with self.assertRaisesRegex(WorkError, "RESULT_NOT_READY"):
            self.connection.collect("not-started", self.root / "missing", allow_partial=True)
        output = self.root / "сохраненные журналы"
        output.mkdir()
        (output / "evidence.txt").write_bytes(b"keep")
        with self.assertRaisesRegex(WorkError, "RESULT_DESTINATION_EXISTS"):
            self.connection.collect("crashed", output, allow_partial=True)
        self.assertEqual(b"keep", (output / "evidence.txt").read_bytes())

    def test_changed_bytes_fail_without_success_manifest_or_modified_source(self):
        original_call = self.connection.call
        def change_after_inventory(message):
            result = original_call(message)
            if message["operation"] == "results":
                (self.run / "журнал замера.log").write_bytes(b"x" * len("до аварии\n".encode("utf-8")))
            return result
        output = self.root / "изменение во время сбора"
        with patch.object(self.connection, "call", side_effect=change_after_inventory):
            with self.assertRaisesRegex(WorkError, "RESULT_HASH_MISMATCH"):
                self.connection.collect("crashed", output, allow_partial=True)
        self.assertFalse((output / "download-manifest.json").exists())

    def test_collection_cannot_write_into_execution_spool(self):
        for output in (self.run / "new-output", self.spool / "control/new-output"):
            with self.assertRaisesRegex(WorkError, "RESULT_DESTINATION_IN_SPOOL"):
                self.connection.collect("crashed", output, allow_partial=True)
            self.assertFalse(output.exists())

    def test_unreadable_job_state_does_not_hide_crash_logs(self):
        (self.spool / "state/crashed.json").write_text('{"status":', encoding="utf-8")
        output = self.root / "журналы без состояния"
        value = self.connection.collect("crashed", output, allow_partial=True)
        self.assertEqual("partial", value["collectionStatus"])
        self.assertIsNone(value["observedJob"])
        self.assertEqual(["JOB_STATE_UNREADABLE"], value["observationErrors"])
        self.assertEqual((self.run / "журнал замера.log").read_bytes(), (output / "журнал замера.log").read_bytes())
        self.assertFalse((output / "result.json").exists())

    def test_truncated_file_fails_and_multi_chunk_file_is_verified(self):
        large = self.run / "large.log"
        large.write_bytes(b"a" * (transport.CHUNK * 2 + 3))
        output = self.root / "большой журнал"
        self.assert_partial(self.connection.collect("crashed", output, allow_partial=True), output)
        self.assertEqual(large.read_bytes(), (output / "large.log").read_bytes())
        original_call = self.connection.call
        def truncate_after_inventory(message):
            result = original_call(message)
            if message["operation"] == "results":
                large.write_bytes(b"a")
            return result
        output = self.root / "оборванный журнал"
        with patch.object(self.connection, "call", side_effect=truncate_after_inventory):
            with self.assertRaisesRegex(WorkError, "RESULT_TRANSFER_INCOMPLETE"):
                self.connection.collect("crashed", output, allow_partial=True)
        self.assertFalse((output / "download-manifest.json").exists())

    def test_appending_log_collects_only_verified_inventory_prefix(self):
        original_call = self.connection.call
        original = (self.run / "журнал замера.log").read_bytes()
        def append_after_inventory(message):
            result = original_call(message)
            if message["operation"] == "results":
                with (self.run / "журнал замера.log").open("ab") as stream:
                    stream.write(b"later progress\n")
            return result
        output = self.root / "растущий журнал"
        with patch.object(self.connection, "call", side_effect=append_after_inventory):
            self.assert_partial(self.connection.collect("crashed", output, allow_partial=True), output)
        self.assertEqual(original, (output / "журнал замера.log").read_bytes())

    def test_private_case_variants_are_not_collected_or_read_through_rpc(self):
        write_json(self.run / "recovery/attempt/Private/secret.json", {"secret":True})
        write_json(self.run / "recovery/attempt/Context.JSON", {"token":"private"})
        output = self.root / "без секретов"
        self.assert_partial(self.connection.collect("crashed", output, allow_partial=True), output)
        for relative in ("recovery/attempt/Private/secret.json", "recovery/attempt/Context.JSON"):
            self.assertFalse((output / relative).exists())
            with self.assertRaisesRegex(WorkError, "PRIVATE_OR_INVALID_RESULT"):
                transport.endpoint(self.spool, {"operation":"read-result", "id":"crashed",
                                                "path":relative, "offset":0})


if __name__ == "__main__":
    unittest.main()
