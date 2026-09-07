"""Behavioral regressions for portable local/remote jobs. No live 1C or paid AI."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))
from itl_remote import agents, bootstrap, execution, jobs, profiling, transport
from itl_remote.common import FileLock, OwnedProcess, WorkError, digest, read_json, write_json


WORKLOAD = '''import sys, time, os
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from itl_measure import context, measurement, verify
c = context()
if sys.argv[2] == "action":
    with measurement():
        time.sleep(c["parameters"]["delay"])
        (Path(c["iteration"]) / "value.txt").write_text("готово", encoding="utf-8")
else:
    verify([{"name":"result", "passed": (Path(c["iteration"]) / "value.txt").read_text(encoding="utf-8") == "готово"}])
'''


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL замер с пробелом ")
        self.root = Path(self.temp.name)
        self.spool = self.root / "очередь заданий"
        self.source = self.root / "сценарий проекта"
        self.source.mkdir()
        (self.source / "workload.py").write_text(WORKLOAD, encoding="utf-8")
        self.scenario = {"schemaVersion": 1, "id": "async-operation", "adapter": "handshake",
                         "readyDescription": "the asynchronous value has been produced", "dataIdentity": "fixture-v1",
                         "parameters": {"delay": {"type": "number", "default": 0.03}},
                         "repeatable": True, "mutates": False, "files": ["workload.py"],
                         "commands": {"action": ["{python}", "{input}/workload.py", "{runtime}", "action"],
                                      "verify": ["{python}", "{input}/workload.py", "{runtime}", "verify"]}}
        self.profile = {"schemaVersion": 1, "targets": {"fixture": {"workspace": str(self.source),
                        "allowedOperations": ["measure"], "sourceIdentity": "fixture-code-v1",
                        "environmentIdentity": "fixture-environment-v1"}}}
        self.profile_path = self.root / "profile.json"
        write_json(self.profile_path, self.profile)
        bootstrap.prepare(self.spool, self.profile_path)

    def tearDown(self):
        self.temp.cleanup()

    def package(self, name="one", **kwargs):
        scenario = self.source / "scenario.json"
        write_json(scenario, self.scenario)
        dest = self.root / ("пакет " + name)
        request = jobs.pack(scenario, dest, target="fixture", mode=kwargs.pop("mode", "time"),
                            warmups=0, repeats=1, identifier=name, **kwargs)
        return request, dest

    def execute(self, package):
        submitted = jobs.submit(package, self.spool)
        state = execution.execute_job(self.spool, submitted["id"], self.profile)
        return state, read_json(self.spool / "runs" / submitted["id"] / "result.json")

    def test_async_local_measurement_waits_for_ready_and_verifies(self):
        request, package = self.package()
        state, result = self.execute(package)
        self.assertEqual("completed", state["status"], result)
        self.assertGreaterEqual(result["timings"][0]["seconds"], 0.03)
        self.assertFalse(result["timings"][0]["profileEnabled"])
        self.assertEqual(1, result["summary"]["count"])

    def test_same_id_is_never_executed_twice(self):
        request, package = self.package()
        state, result = self.execute(package)
        self.assertEqual(state, jobs.submit(package, self.spool))
        second = execution.execute_job(self.spool, request["id"], self.profile)
        self.assertEqual(state, second)
        self.assertEqual(result, read_json(self.spool / "runs" / request["id"] / "result.json"))

    def test_job_id_collision_with_different_parameters_is_rejected(self):
        request, package = self.package()
        jobs.submit(package, self.spool)
        path = package / "request.json"
        changed = read_json(path)
        changed["parameters"]["delay"] = 2
        write_json(path, changed)
        with self.assertRaisesRegex(WorkError, "CONTENT_CONFLICT"):
            jobs.submit(package, self.spool)

    def test_partial_upload_and_content_tampering_cannot_be_submitted(self):
        request, package = self.package()
        (package / "input/workload.py").write_text("bad", encoding="utf-8")
        with self.assertRaisesRegex(WorkError, "HASH_MISMATCH"):
            jobs.submit(package, self.spool)
        self.assertFalse((self.spool / "jobs/one").exists())

    def test_exchange_transport_roundtrips_exact_unicode_content(self):
        request, package = self.package()
        connection = transport.Connection({"transport": "exchange", "spool": str(self.spool)})
        self.assertEqual("queued", connection.send(package)["status"])
        self.assertEqual([], connection.call({"operation": "missing", "files": list(request["files"].values())})["missing"])
        state = execution.execute_job(self.spool, request["id"], self.profile)
        destination = self.root / "полученные результаты"
        result = connection.collect(request["id"], destination)
        self.assertEqual("completed", result["status"], result)
        self.assertFalse((destination / "context.json").exists())
        self.assertTrue((destination / "download-manifest.json").exists())

    def test_nonrepeatable_default_does_not_repeat_for_profile(self):
        self.scenario["repeatable"] = False
        request, package = self.package(mode="time+profile")
        state, result = self.execute(package)
        self.assertEqual("partial", state["status"])
        self.assertEqual(1, result["summary"]["count"])
        self.assertEqual([], result["profiles"])

    def test_unknown_target_and_missing_write_permission_fail_before_launch(self):
        request, package = self.package()
        self.profile["targets"] = {}
        jobs.submit(package, self.spool)
        with self.assertRaisesRegex(WorkError, "TARGET_NOT_CONFIGURED"):
            execution.execute_job(self.spool, request["id"], self.profile)
        self.assertFalse((self.spool / "runs").exists())
        self.scenario.update(mutates=True, repeatable=False)
        with self.assertRaisesRegex(WorkError, "WRITE_DATA_AUTHORIZATION_REQUIRED"):
            self.package("mutating")

    def test_interrupted_modifying_job_is_not_replayed(self):
        request, package = self.package()
        jobs.submit(package, self.spool)
        write_json(self.spool / "state/one.json", {"id": "one", "status": "running", "ownerPid": 999999})
        result = execution.execute_job(self.spool, "one", self.profile)
        self.assertEqual("needs-attention", result["status"])
        self.assertIn("INTERRUPTED_OWNER", result["error"])
        self.assertFalse((self.spool / "runs").exists())

    def test_cancel_queued_job_does_not_launch(self):
        request, package = self.package()
        jobs.submit(package, self.spool)
        jobs.cancel(self.spool, "one")
        self.assertEqual("cancelled", execution.execute_job(self.spool, "one", self.profile)["status"])

    def test_boolean_not_accepted_as_number(self):
        with self.assertRaisesRegex(WorkError, "PARAMETER_TYPE"):
            self.package(values={"delay": True})

    def test_input_paths_cannot_escape_package(self):
        self.scenario["files"] = ["../profile.json"]
        with self.assertRaisesRegex(WorkError, "PATH_OUTSIDE_ROOT"):
            self.package()

    def test_comparison_rejects_changed_data(self):
        _, package = self.package()
        _, a = self.execute(package)
        b = dict(a, jobId="other", dataIdentity="other-data")
        write_json(self.root / "a.json", a)
        write_json(self.root / "b.json", b)
        with self.assertRaisesRegex(WorkError, "INCOMPARABLE_RUNS"):
            execution.compare(self.root / "a.json", self.root / "b.json")

    def test_process_cancellation_keeps_foreign_process_alive(self):
        other = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"])
        try:
            with OwnedProcess([sys.executable, "-c", "import time;time.sleep(20)"], self.root, self.root / "own.log") as own:
                with self.assertRaisesRegex(WorkError, "CANCELLED"):
                    own.wait(30, lambda: True)
            self.assertIsNone(other.poll())
        finally:
            other.terminate()
            other.wait()

    def test_os_lock_is_released_after_owner_scope(self):
        with FileLock(self.root / "lock"):
            with self.assertRaisesRegex(WorkError, "OWNER_BUSY"):
                with FileLock(self.root / "lock"):
                    pass
        with FileLock(self.root / "lock"):
            pass

    def test_server_dbgs_is_not_launched_locally(self):
        target = {"infoBase": {"kind": "server"}, "rdbg": {"url": "http://dbgs-server:1550", "infoBaseAlias": "test"}}
        processes = []
        effective = profiling.prepare_debug_server(target, self.root, processes, lambda: False)
        self.assertEqual("http://dbgs-server:1550", effective["url"])
        self.assertEqual([], processes)

    def test_file_dbgs_cannot_silently_use_shared_server(self):
        target = {"infoBase": {"kind": "file"}, "rdbg": {"mode": "shared", "url": "http://other:1550"}}
        with self.assertRaisesRegex(WorkError, "FILE_BASE_REQUIRES_EXECUTION_HOST"):
            profiling.prepare_debug_server(target, self.root, [], lambda: False)



    def test_handshake_excludes_slow_process_teardown(self):
        text = WORKLOAD.replace('else:\n    verify', '    time.sleep(0.4)\nelse:\n    verify')
        (self.source / "workload.py").write_text(text, encoding="utf-8")
        _, package = self.package()
        before = time.monotonic()
        state, result = self.execute(package)
        self.assertEqual("completed", state["status"], result)
        self.assertGreater(time.monotonic() - before, 0.4)
        self.assertLess(result["timings"][0]["seconds"], 0.3)

    def test_invalid_transported_repetitions_never_launch(self):
        _, package = self.package()
        request = read_json(package / "request.json")
        request["repeats"] = 0
        write_json(package / "request.json", request)
        with self.assertRaisesRegex(WorkError, "INVALID_REPETITIONS"):
            jobs.submit(package, self.spool)

    def test_collect_excludes_private_settings_on_every_route(self):
        _, package = self.package()
        self.execute(package)
        private = self.spool / "runs/one/000-time/private"
        write_json(private / "VAParams.json", {"private": "fixture"})
        out = self.root / "result"
        jobs.collect(self.spool, "one", out)
        self.assertFalse((out / "context.json").exists())
        self.assertFalse((out / "000-time/private").exists())
        with self.assertRaisesRegex(WorkError, "PRIVATE_OR_INVALID"):
            transport.endpoint(self.spool, {"operation": "read-result", "id": "one",
                                            "path": "000-time/private/VAParams.json", "offset": 0})

    def test_scaffold_and_portable_bundle_execute_without_full_installation(self):
        from itl_remote.scenarios import scaffold
        import zipfile
        created = scaffold(self.source, "calibration")
        request = jobs.pack(created["scenario"], self.root / "calibration-package", target="fixture",
                            mode="time", repeats=1, warmups=0)
        archive = self.root / "bundle.zip"
        bootstrap.export_bundle(REPO, archive)
        extracted = self.root / "portable bundle"
        with zipfile.ZipFile(archive) as z:
            z.extractall(extracted)
        runtime = extracted / ".agents/skills/itl-remote-runner/scripts/remote_work.py"
        self.assertFalse((extracted / "install-agent-1c-workflow.ps1").exists())
        jobs.submit(self.root / "calibration-package", self.spool)
        from itl_remote.common import capture
        state = json.loads(capture([sys.executable, str(runtime), "execute", "--spool", str(self.spool), "--id", request["id"]]))
        self.assertEqual("completed", state["status"], state)

    def fake_agent(self, kind, fail=False):
        script = self.root / "agent fixture.py"
        script.write_text('''import sys,json,subprocess
runtime,spool,identifier,kind,fail=sys.argv[1:]
def send(value):
 print(json.dumps(value),flush=True)
for line in sys.stdin:
 m=json.loads(line); method=m.get("method")
 if "id" not in m: continue
 value={}
 if method=="initialize": value={}
 elif method in ("thread/start","thread/resume"): value={"thread":{"id":"fixture-thread"}}
 elif method=="tools/list": value={"tools":[{"name":n,"inputSchema":{"properties":{"threadId":{"type":"string"}}}} for n in ["send_message_to_thread","read_thread"]]}
 elif method=="turn/start" or method=="tools/call" and m["params"]["name"]=="send_message_to_thread":
  if fail=="yes":
   send({"id":m["id"],"error":{"message":"fixture denied"}}); continue
  p=subprocess.run([sys.executable,runtime,"execute","--via-agent","--spool",spool,"--id",identifier],stdout=subprocess.PIPE)
  if p.returncode: raise RuntimeError(p.stdout.decode())
  value={"turn":{"id":"fixture-turn"}} if kind=="codex-app-server" else {"content":[{"type":"text","text":"engine returned"}]}
 elif method=="tools/call": value={"content":[{"type":"text","text":"fixture snapshot"}]}
 send({"jsonrpc":"2.0","id":m["id"],"result":value})
 if method=="turn/start": send({"method":"turn/completed","params":{"turn":{"id":"fixture-turn","status":"completed"}}})
''', encoding="utf-8")
        command = [sys.executable, str(script), str(RUNTIME / "remote_work.py"), str(self.spool), "one", kind, "yes" if fail else "no"]
        config = {"kind": kind, "command": command, "timeoutSeconds": 10}
        if kind == "codex-desktop":
            discovery = self.root / "discovery.py"
            discovery.write_text("import json\nprint(json.dumps(" + repr({"command": command, "contextThreadId": "fixture-context"}) + "))", encoding="utf-8")
            config.update(discoverCommand=[sys.executable, str(discovery)], threadId="fixture-target")
        self.profile["agent"] = config
        write_json(self.spool / "profile.json", self.profile)

    def test_app_server_agent_runs_the_same_engine_once(self):
        self.fake_agent("codex-app-server")
        _, package = self.package(route="agent")
        state, result = self.execute(package)
        self.assertEqual("completed", state["status"], state)
        self.assertEqual(1, result["summary"]["count"])
        self.assertEqual("completed", execution.execute_job(self.spool, "one", self.profile)["status"])
        self.assertEqual("fixture-thread", agents.control(self.spool, "one", "read", {})["threadId"])

    def test_desktop_agent_runs_the_same_engine(self):
        self.fake_agent("codex-desktop")
        _, package = self.package(route="agent")
        state, result = self.execute(package)
        self.assertEqual("completed", state["status"], state)
        self.assertEqual(1, result["summary"]["count"])

    def test_agent_failure_updates_job_and_does_not_repeat_assignment(self):
        self.fake_agent("codex-app-server", fail=True)
        _, package = self.package(route="agent")
        jobs.submit(package, self.spool)
        state = execution.execute_job(self.spool, "one", self.profile)
        self.assertEqual("needs-attention", state["status"])
        self.assertEqual("needs-attention", jobs.status(self.spool, "one")["status"])
        self.assertEqual(state, execution.execute_job(self.spool, "one", self.profile))

    def test_approval_request_keeps_stdio_alive_until_explicit_response(self):
        script = self.root / "approval.py"
        script.write_text('''import sys,json
for line in sys.stdin:
 m=json.loads(line)
 if m.get("method")=="ask":
  print(json.dumps({"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"command":"fixture"}}),flush=True)
  response=json.loads(sys.stdin.readline())
  print(json.dumps({"id":m["id"],"result":{"decision":response["result"]["decision"]}}),flush=True)
''', encoding="utf-8")
        client = agents.JsonRpcProcess([sys.executable, str(script)], self.root, self.root / "approval")
        def respond():
            pending = self.root / "approval/pending-request.json"
            while not pending.exists():
                time.sleep(0.01)
            write_json(self.root / "approval/approval-response.json", {"requestId": "approval-1", "result": {"decision": "decline"}})
        thread = threading.Thread(target=respond, daemon=True)
        thread.start()
        try:
            self.assertEqual({"decision": "decline"}, client.call("ask", timeout=3))
            self.assertIsNone(client.process.poll())
        finally:
            client.close()
            thread.join(timeout=2)

    @unittest.skipUnless(os.name == "nt", "Windows SSH endpoint")
    def test_ssh_bootstrap_transmits_unicode_paths_as_data(self):
        from unittest.mock import patch
        from itl_remote.common import capture
        config = {"transport": "ssh", "ssh": {"host": "fixture-alias", "python": sys.executable,
                  "runtime": str(RUNTIME / "remote_work.py"), "spool": str(self.spool)}}
        observed = []
        def local_endpoint(command, **kwargs):
            observed.append(command)
            self.assertIn("StrictHostKeyChecking=yes", command)
            return capture(command[command.index("powershell.exe"):], **kwargs)
        _, package = self.package()
        with patch.object(transport, "capture", side_effect=local_endpoint):
            connection = transport.Connection(config)
            self.assertEqual("queued", connection.send(package)["status"])
            self.assertEqual("queued", connection.call({"operation": "status", "id": "one"})["status"])
        self.assertGreater(len(observed), 2)
        self.assertEqual(digest(package / "input/workload.py"), digest(self.spool / "jobs/one/input/workload.py"))


    def test_server_profile_requires_client_and_server_from_same_session(self):
        import xml.etree.ElementTree as ET
        from unittest.mock import patch
        R, D = profiling.RESPONSE, profiling.DATA
        registered = ET.fromstring('<response xmlns:r="' + R + '"><r:result>registered</r:result></response>')
        targets = ET.fromstring('<response xmlns:r="' + R + '" xmlns:d="' + D + '"><r:id><d:id>client</d:id><d:targetType>ManagedClient</d:targetType><d:seanceId>s</d:seanceId><d:infoBaseInstanceID>i</d:infoBaseInstanceID><d:infoBaseAlias>base</d:infoBaseAlias></r:id></response>')
        proof = {"targetIds": ["client"], "seanceId": "s", "infoBaseInstanceID": "i", "infoBaseAlias": "base",
                 "requiredTypes": ["ManagedClient", "Server"]}
        collector = profiling.Rdbg({"url": "http://127.0.0.1:1", "infoBaseAlias": "base"}, proof, self.root / "raw")
        calls = []
        def rpc(command, **kwargs):
            calls.append(command)
            return registered if command == "attachDebugUI" else targets
        with patch.object(collector, "call", side_effect=rpc):
            with self.assertRaisesRegex(WorkError, "TARGET_FAMILIES_INCOMPLETE"):
                collector.open()
        self.assertNotIn("attachDetachDbgTargets", calls)
        self.assertIn("detachDebugUI", calls)

    def test_rdbg_stop_omits_measure_session_and_decodes_deflate(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        import zlib
        import xml.etree.ElementTree as ET
        bodies = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                bodies.append(self.rfile.read(int(self.headers["Content-Length"])))
                data = zlib.compress(b"<response/>")
                self.send_response(200)
                self.send_header("Content-Encoding", "deflate")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        proof = {"targetIds": ["own"], "seanceId": "s", "infoBaseInstanceID": "i", "infoBaseAlias": "base"}
        collector = profiling.Rdbg({"url": "http://127.0.0.1:" + str(server.server_port), "infoBaseAlias": "base"},
                                  proof, self.root / "raw")
        try:
            collector.call("setMeasureMode", session="measure-session")
            collector.call("setMeasureMode")
            tag = "{" + profiling.RESPONSE + "}measureModeSeanceID"
            self.assertEqual("measure-session", ET.fromstring(bodies[0]).findtext(tag))
            self.assertIsNone(ET.fromstring(bodies[1]).find(tag))
            self.assertEqual(2, len(list((self.root / "raw").glob("*.response.bin"))))
            self.assertEqual(2, len(list((self.root / "raw").glob("*.response.xml"))))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_file_dbgs_uses_execution_host_and_utf16_notify(self):
        from unittest.mock import patch
        executable = self.root / "dbgs.exe"
        executable.write_bytes(b"fixture")
        observed = []
        class FakeProcess:
            def __init__(inner, command, cwd, log):
                observed.append(command)
                port = next(a.split("=", 1)[1] for a in command if a.startswith("--port="))
                notify = next(a.split("=", 1)[1] for a in command if a.startswith("--notify="))
                Path(notify).write_text("127.0.0.1:" + port, encoding="utf-16")
                inner.process = inner
                inner.pid = 1234
            def poll(inner):
                return None
        target = {"workspace": str(self.root), "infoBase": {"kind": "file"},
                  "rdbg": {"executable": str(executable), "infoBaseAlias": "fixture"}}
        processes = []
        with patch.object(profiling, "OwnedProcess", FakeProcess):
            effective = profiling.prepare_debug_server(target, self.root, processes, lambda: False)
        self.assertTrue(effective["url"].startswith("http://127.0.0.1:"))
        self.assertEqual(1, len(processes))
        self.assertIn("--addr=127.0.0.1", observed[0])

    def test_raw_profile_rejects_foreign_session_target(self):
        M, D, C = profiling.MEASURE, profiling.DATA, profiling.COMMANDS
        xml = '<response xmlns:m="' + M + '" xmlns:d="' + D + '" xmlns:c="' + C + '"><c:measure><m:sessionID>measure</m:sessionID><m:targetID><d:id>foreign</d:id><d:infoBaseAlias>base</d:infoBaseAlias><d:seanceId>s</d:seanceId><d:infoBaseInstanceID>i</d:infoBaseInstanceID></m:targetID><m:performanceFrequency>1000</m:performanceFrequency><m:totalDurability>250</m:totalDurability></c:measure></response>'
        path = self.root / "packet.xml"
        path.write_text(xml, encoding="utf-8")
        result = profiling.analyze_raw([path], "measure")
        self.assertEqual(0.25, result["packets"][0]["totalSeconds"])
        self.assertIsNone(result["pff"])
        proof = {"targetIds": ["own"], "infoBaseAlias": "base", "seanceId": "s", "infoBaseInstanceID": "i"}
        with self.assertRaisesRegex(WorkError, "FOREIGN_PROFILE_PACKET"):
            profiling.analyze_raw([path], "measure", expected=proof)


    def test_completed_agent_followup_interrupts_its_new_turn(self):
        from unittest.mock import patch
        self.fake_agent("codex-app-server")
        request, package = self.package(route="agent")
        self.execute(package)
        calls = []
        class InterruptedFollowup:
            def __init__(inner, *args, **kwargs):
                inner.events = []
                inner.control_handler = None
            def send(inner, value):
                pass
            def call(inner, method, params=None, **kwargs):
                calls.append((method, params))
                if method == "thread/resume":
                    return {"thread": {"id": "fixture-thread"}}
                if method == "turn/start":
                    return {"turn": {"id": "new-turn"}}
                return {}
            def receive(inner, timeout):
                raise WorkError("AGENT_INTERRUPT_REQUESTED")
            def close(inner):
                pass
        with patch.object(agents, "JsonRpcProcess", InterruptedFollowup):
            state = agents.dispatch(self.spool, request, self.profile, self.scenario, followup="Inspect the existing result")
        self.assertEqual("needs-attention", state["status"])
        self.assertIn(("turn/interrupt", {"threadId": "fixture-thread", "turnId": "new-turn"}), calls)


    def test_comparison_rejects_changed_workload_with_same_descriptor(self):
        _, first = self.package()
        _, a = self.execute(first)
        (self.source / "workload.py").write_text(WORKLOAD + "\n# another workload revision\n", encoding="utf-8")
        _, second = self.package("two")
        _, b = self.execute(second)
        write_json(self.root / "a.json", a)
        write_json(self.root / "b.json", b)
        with self.assertRaisesRegex(WorkError, "scenarioInputsSha256"):
            execution.compare(self.root / "a.json", self.root / "b.json")

    def test_false_check_cannot_be_hidden_by_top_level_passed(self):
        (self.source / "workload.py").write_text(WORKLOAD.replace(
            'verify([{"name":"result", "passed": (Path(c["iteration"]) / "value.txt").read_text(encoding="utf-8") == "готово"}])',
            'from itl_remote.common import write_json; write_json(Path(c["iteration"]) / "verification.json", {"jobId":c["jobId"],"passed":True,"checks":[{"name":"actual","passed":False}]})'
        ), encoding="utf-8")
        _, package = self.package()
        state, result = self.execute(package)
        self.assertEqual("needs-attention", state["status"], result)
        self.assertEqual([], result["timings"])


    def test_remote_followup_is_idempotent_and_runs_only_in_worker(self):
        from unittest.mock import patch
        self.fake_agent("codex-app-server")
        _, package = self.package(route="agent")
        self.execute(package)
        message = {"operation": "agent-request", "action": "followup", "id": "one",
                   "payload": {"controlId": "inspect-1", "prompt": "Inspect result without replay"}}
        with patch.object(agents, "control", return_value={"status": "completed"}) as call:
            self.assertEqual("queued", transport.endpoint(self.spool, message)["status"])
            self.assertEqual("queued", transport.endpoint(self.spool, message)["status"])
            call.assert_not_called()
            agents.run_queued_controls(self.spool)
            call.assert_called_once()
            agents.run_queued_controls(self.spool)
            call.assert_called_once()
            self.assertEqual("returned", transport.endpoint(self.spool, message)["status"])
        message["payload"]["prompt"] = "Different work"
        with self.assertRaisesRegex(WorkError, "CONTENT_CONFLICT"):
            transport.endpoint(self.spool, message)


    @unittest.skipUnless(os.name == "nt", "Windows dependency separators")
    def test_nested_windows_dependency_paths_survive_pack_transfer_and_execution(self):
        folder = self.source / "вложенный каталог"
        folder.mkdir()
        (folder / "workload.py").write_text(WORKLOAD, encoding="utf-8")
        self.scenario["files"] = ["вложенный каталог\\workload.py"]
        for phase in ("action", "verify"):
            self.scenario["commands"][phase][1] = "{input}/вложенный каталог/workload.py"
        _, package = self.package()
        connection = transport.Connection({"transport": "exchange", "spool": str(self.spool)})
        self.assertEqual("queued", connection.send(package)["status"])
        self.assertEqual("completed", execution.execute_job(self.spool, "one", self.profile)["status"])


    def test_missing_optional_sources_do_not_destroy_raw_profile_evidence(self):
        M, D, C = profiling.MEASURE, profiling.DATA, profiling.COMMANDS
        xml = '<response xmlns:m="' + M + '" xmlns:d="' + D + '" xmlns:c="' + C + '"><c:measure><m:sessionID>measure</m:sessionID><m:targetID><d:id>own</d:id></m:targetID><m:performanceFrequency>1000</m:performanceFrequency><m:moduleData><m:moduleID><d:id>module</d:id><d:version>v1</d:version></m:moduleID><m:lineInfo><m:durability>10</m:durability><m:pureDurability>5</m:pureDurability></m:lineInfo></m:moduleData></c:measure></response>'
        path = self.root / "packet.xml"
        path.write_text(xml, encoding="utf-8")
        result = profiling.analyze_raw([path], source_map={"module": {"moduleVersion": "v1",
                                      "path": str(self.root / "missing-source.bsl"), "sha256": "0" * 64}})
        self.assertTrue(result["complete"])
        self.assertFalse(result["packets"][0]["top"][0]["sourceMatched"])
        self.assertEqual(0.005, result["packets"][0]["top"][0]["pureSeconds"])

if __name__ == "__main__":
    unittest.main()
