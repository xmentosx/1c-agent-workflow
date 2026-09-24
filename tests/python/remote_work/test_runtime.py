"""Behavioral regressions for portable local/remote jobs. No live 1C or paid AI."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))
from itl_remote import agents, bootstrap, common, controller, execution, host_commands, jobs, profiling, pull, transport, updates
from itl_remote.common import (FileLock, OwnedProcess, WorkError, digest, read_json,
                               resolve_resource_limits, resource_violation, write_json)


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

EVIDENCE_WORKLOAD = '''import json, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from itl_measure import context, measurement, verify
c = context()
iteration = Path(c["iteration"])
if sys.argv[2] == "action":
    with measurement():
        time.sleep(c["parameters"]["delay"])
        (iteration / "value.txt").write_text("готово", encoding="utf-8")
    raw = iteration / c["diagnostics"]["evidencePath"]
    raw.parent.mkdir(parents=True, exist_ok=True)
    value = {"schemaVersion": 1, "jobId": c["jobId"], "iterationId": c["iterationIndex"],
             "operationId": "fixture-operation", "diagnostics": {"level": c["diagnostics"]["level"]},
             "clocks": [{"clockId": "fixture-mono", "kind": "monotonic", "unit": "ms"}],
             "spans": [{"spanId": "operation", "kind": "work", "clockId": "fixture-mono",
                         "duration": {"availability": "available", "evidenceKind": "measured",
                                      "value": 30, "unit": "ms"}}],
             "links": [], "coverage": {"client": "partial", "serverWithContext": "unknown",
                                          "serverWithoutContext": "unknown", "background": "unknown"},
             "milestones": [], "equivalence": {"status": "unverified", "reason": "fixture"},
             "streamStatus": {"complete": True, "truncated": False, "droppedEvents": 0}}
    raw.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
else:
    verify([{"name":"result", "passed": (iteration / "value.txt").read_text(encoding="utf-8") == "готово"}])
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
                        "infoBase": {"kind": "file", "path": str(self.root / "конкретная база")},
                        "access": {"coordinator": str(self.root / "координатор баз")},
                        "environmentIdentity": "fixture-environment-v1"}}}
        self.profile_path = self.root / "profile.json"
        write_json(self.profile_path, self.profile)
        bootstrap.prepare(self.spool, self.profile_path)

    def tearDown(self):
        self.temp.cleanup()

    def test_host_command_uses_worker_queue_and_collects_unicode_output(self):
        self.profile["hostCommands"] = {"enabled": True}
        source = self.root / "команда в папке"
        source.mkdir()
        (source / "run.py").write_text(
            "import pathlib,sys\n"
            "pathlib.Path(sys.argv[1], 'created.txt').write_text('готово', encoding='utf-8')\n"
            "print('привет')\nprint('ошибка диагностики', file=sys.stderr)\n", encoding="utf-8")
        spec = source / "command.json"
        write_json(spec, {"schemaVersion": 1, "argv": [sys.executable, "-X", "utf8",
                   "{input}/run.py", "{run}"], "files": ["run.py"], "timeoutSeconds": 30})
        package = self.root / "командный пакет"
        host_commands.pack(spec, package, identifier="host-one")
        jobs.submit(package, self.spool)
        result = execution.execute_job(self.spool, "host-one", self.profile, expected_runner="worker")
        self.assertEqual("completed", result["status"], result)
        collected = self.root / "собранный результат"
        transport.Connection({"transport": "exchange", "spool": str(self.spool)}).collect("host-one", collected)
        self.assertEqual("привет\n", (collected / "stdout.log").read_text(encoding="utf-8"))
        self.assertEqual("ошибка диагностики\n", (collected / "stderr.log").read_text(encoding="utf-8"))
        self.assertEqual("готово", (collected / "created.txt").read_text(encoding="utf-8"))
        self.assertEqual("completed", execution.execute_job(self.spool, "host-one", self.profile)["status"])

    def test_host_command_requires_explicit_worker_authorization(self):
        source = self.root / "host spec"
        source.mkdir()
        spec = source / "command.json"
        write_json(spec, {"schemaVersion": 1, "argv": [sys.executable, "--version"]})
        package = self.root / "host package"
        host_commands.pack(spec, package, identifier="host-disabled")
        jobs.submit(package, self.spool)
        with self.assertRaisesRegex(WorkError, "HOST_COMMANDS_NOT_AUTHORIZED"):
            execution.execute_job(self.spool, "host-disabled", self.profile, expected_runner="worker")
        self.assertEqual("queued", jobs.status(self.spool, "host-disabled")["status"])

    def test_interrupted_host_command_is_not_replayed_after_owner_loss(self):
        self.profile["hostCommands"] = {"enabled": True}
        source = self.root / "command source"
        source.mkdir()
        marker = self.root / "must not be created.txt"
        spec = source / "command.json"
        write_json(spec, {"schemaVersion": 1, "argv": [sys.executable, "-c",
                          "from pathlib import Path; Path(%r).write_text('bad')" % str(marker)]})
        package = self.root / "interrupted package"
        host_commands.pack(spec, package, identifier="lost-owner")
        jobs.submit(package, self.spool)
        write_json(self.spool / "state/lost-owner.json", {"id": "lost-owner", "status": "running",
                   "ownerPid": 99999999, "ownerIdentity": {"creationId": "old"}})
        state = execution.execute_job(self.spool, "lost-owner", self.profile, expected_runner="worker")
        self.assertEqual("interrupted", state["status"])
        self.assertFalse(marker.exists())
        self.assertEqual("interrupted", execution.execute_job(self.spool, "lost-owner", self.profile)["status"])

    def test_cancelled_host_command_never_launches(self):
        self.profile["hostCommands"] = {"enabled": True}
        source = self.root / "cancel source"
        source.mkdir()
        marker = self.root / "cancel marker.txt"
        spec = source / "command.json"
        write_json(spec, {"schemaVersion": 1, "argv": [sys.executable, "-c",
                          "from pathlib import Path; Path(%r).write_text('bad')" % str(marker)]})
        package = self.root / "cancel package"
        host_commands.pack(spec, package, identifier="cancel-host")
        jobs.submit(package, self.spool)
        jobs.cancel(self.spool, "cancel-host")
        state = execution.execute_job(self.spool, "cancel-host", self.profile, expected_runner="worker")
        self.assertEqual("cancelled", state["status"])
        self.assertFalse(marker.exists())

    def test_onboarding_emits_one_launcher_and_never_prints_pairing_secret(self):
        bundle = self.root / "portable bundle.zip"
        bootstrap.export_bundle(REPO, bundle)
        controller = self.root / "controller.json"
        worker = self.root / "worker.json"
        bootstrap.pair("https://controller.example:8765", controller, worker, worker_id="ufa-user")
        profile = self.root / "host-profile.json"
        write_json(profile, {"schemaVersion": 1, "targets": {}, "hostCommands": {"enabled": True}})
        destination = self.root / "Обмен Яндекс" / "Старт UFA"
        with self.assertRaisesRegex(WorkError, "ONBOARD_TRUSTED_TRANSFER_REQUIRED"):
            bootstrap.onboard(bundle, worker, profile, destination, "ufa")
        result = bootstrap.onboard(bundle, worker, profile, destination, "ufa", trusted_transfer=True)
        self.assertEqual("user-start-required", result["status"])
        self.assertNotIn("token", result)
        self.assertEqual(read_json(worker)["pull"]["workerId"], result["workerId"])
        self.assertTrue((destination / "Start-Worker.cmd").is_file())
        self.assertTrue((destination / "Start-Worker.ps1").is_file())
        self.assertEqual(digest(bundle), read_json(destination / "onboard.json")["bundleSha256"])
        self.assertEqual(read_json(worker), read_json(destination / "worker-connection.json"))

    @unittest.skipUnless(os.name == "nt", "Windows user-session launcher")
    def test_one_launcher_handles_multiple_host_commands_and_reports_status(self):
        server, thread, url = pull.start_broker()
        bundle = self.root / "worker bundle.zip"
        bootstrap.export_bundle(REPO, bundle)
        controller = self.root / "controller.json"
        worker = self.root / "worker.json"
        bootstrap.pair(url, controller, worker, worker_id="one-click-user")
        profile = self.root / "host-profile.json"
        write_json(profile, {"schemaVersion": 1, "targets": {}, "hostCommands": {"enabled": True},
                             "workerLimits": {"maxJobs": 1, "maxLifetimeSeconds": 30}})
        destination = self.root / "Обмен Яндекс" / "Пуск UFA"
        staged = bootstrap.onboard(bundle, worker, profile, destination, "one-click", trusted_transfer=True)
        environment = dict(os.environ, LOCALAPPDATA=str(self.root / "private local"),
                           ITL_PYTHON_EXECUTABLE=sys.executable)
        process = subprocess.Popen(["cmd.exe", "/c", staged["launcher"]], cwd=self.root,
                                   env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        connection = transport.Connection(read_json(controller))
        try:
            deadline = time.monotonic() + 40
            observed = None
            while time.monotonic() < deadline:
                status_file = destination / "bootstrap-status.json"
                if status_file.exists():
                    observed = read_json(status_file)
                    if observed["phase"] in ("connected", "failed"):
                        break
                time.sleep(0.2)
            self.assertEqual("connected", observed["phase"], observed)
            for index in (1, 2):
                source = self.root / ("command " + str(index))
                source.mkdir()
                spec = source / "command.json"
                if index == 1:
                    command = {"schemaVersion": 1, "argv": [sys.executable, "-X", "utf8", "-c",
                               "print('команда 1')"]}
                else:
                    script = source / "script.ps1"
                    script.write_bytes(b"\xef\xbb\xbf" +
                                       "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n"
                                       "Write-Output 'команда 2'\n".encode("utf-8"))
                    command = {"schemaVersion": 1, "argv": ["powershell.exe", "-NoProfile",
                               "-ExecutionPolicy", "Bypass", "-File", "{input}/script.ps1"],
                               "files": ["script.ps1"]}
                write_json(spec, command)
                package = self.root / ("package " + str(index))
                identifier = "one-click-%s" % index
                host_commands.pack(spec, package, identifier=identifier)
                connection.send(package)
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    state = connection.call({"operation": "status", "id": identifier})
                    if state["status"] in ("completed", "failed", "interrupted"):
                        break
                    time.sleep(0.1)
                self.assertEqual("completed", state["status"], state)
                output = self.root / ("result " + str(index))
                connection.collect(identifier, output)
                self.assertEqual("команда %s\n" % index,
                                 (output / "stdout.log").read_text(encoding="utf-8"))
        finally:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            process.wait(timeout=10)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

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
        self.assertEqual("unavailable", result["loadedState"]["status"])
        self.assertFalse(result["loadedState"]["runtimeObserved"])
        self.assertIsNone(result["loadedState"]["evidence"])
        self.assertIsNotNone(result["resourceEvidence"]["hostBefore"])
        self.assertIsNotNone(result["resourceEvidence"]["hostAfter"])
        self.assertEqual("file", result["databaseTopology"])
        self.assertIsNotNone(result["databaseIdentity"])
        self.assertIn("Database binding: topology=file", (self.spool / "runs/one/report.md").read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(result["resourceEvidence"]["processes"]), 2)
        self.assertRegex(result["resourceEvidence"]["contextId"], "^[a-f0-9]{64}$")
        self.assertEqual({result["resourceEvidence"]["contextId"]},
                         {item["resourceContextId"] for item in result["resourceEvidence"]["processes"]})
        self.assertTrue((self.spool / "runs/one/resource-telemetry.jsonl").is_file())
        telemetry = [json.loads(line) for line in
                     (self.spool / "runs/one/resource-telemetry.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertTrue(any(sample["processes"] and sample["processes"][0]["pid"] > 0 for sample in telemetry))
        self.assertEqual({"status": "notRequested"}, result["operationEvidence"])

    def test_v2_collects_public_operation_evidence_and_keeps_raw_private(self):
        (self.source / "workload.py").write_text(EVIDENCE_WORKLOAD, encoding="utf-8")
        self.scenario.update(schemaVersion=2, diagnostics={"schemaVersion": 1, "level": "D1",
                                                           "evidencePath": "private/operation-evidence.json",
                                                           "required": False})
        request, package = self.package("evidence")
        self.assertEqual(2, request["schemaVersion"])
        state, result = self.execute(package)
        self.assertEqual("partial", state["status"], result)
        self.assertEqual(1, result["summary"]["count"])
        self.assertEqual("partial", result["operationEvidence"]["status"])
        item = result["operationEvidence"]["iterations"][0]
        self.assertEqual("fixture-operation", item["operationId"])
        run = self.spool / "runs/evidence/000-time"
        self.assertTrue((run / "private/operation-evidence.json").is_file())
        self.assertTrue((run / "operation-evidence.json").is_file())
        self.assertTrue((run / "operation-evidence.md").is_file())
        self.assertEqual("000-time/operation-evidence.json", item["path"])
        self.assertEqual("000-time/operation-evidence.md", item["reportPath"])
        output = self.root / "Собранные доказательства"
        jobs.collect(self.spool, "evidence", output)
        self.assertTrue((output / "000-time/operation-evidence.json").is_file())
        self.assertTrue((output / "000-time/operation-evidence.md").is_file())
        self.assertFalse((output / "000-time/private/operation-evidence.json").exists())
        summary = (output / "report.md").read_text(encoding="utf-8")
        self.assertIn("Operation evidence", summary)
        self.assertIn("[operation map](000-time/operation-evidence.md)", summary)

    def test_invalid_v2_sidecar_keeps_verified_timing_as_partial(self):
        broken = EVIDENCE_WORKLOAD.replace('"jobId": c["jobId"]', '"jobId": "foreign"')
        (self.source / "workload.py").write_text(broken, encoding="utf-8")
        self.scenario.update(schemaVersion=2, diagnostics={"schemaVersion": 1, "level": "D1",
                                                           "evidencePath": "private/operation-evidence.json",
                                                           "required": True})
        _, package = self.package("broken-evidence")
        state, result = self.execute(package)
        self.assertEqual("partial", state["status"], result)
        self.assertEqual(1, result["summary"]["count"])
        self.assertEqual("invalid", result["operationEvidence"]["status"])
        self.assertIn("FOREIGN_ITERATION", result["operationEvidence"]["iterations"][0]["error"])

    def test_same_id_is_never_executed_twice(self):
        request, package = self.package()
        state, result = self.execute(package)
        self.assertEqual(state, jobs.submit(package, self.spool))
        second = execution.execute_job(self.spool, request["id"], self.profile)
        self.assertEqual(state, second)
        self.assertEqual(result, read_json(self.spool / "runs" / request["id"] / "result.json"))

    def test_engine_crash_retains_collectable_conditions_without_a_result_or_replay(self):
        self.scenario["phaseTimeoutSeconds"] = {"action": 900}
        request, package = self.package(values={"delay": 0.08})
        jobs.submit(package, self.spool)
        script = """import os, sys
sys.path.insert(0, sys.argv[1])
from itl_remote import execution
from itl_remote.common import read_json
# Crash the actual job owner at the boundary before starting the workload.
execution.run_measurement = lambda *args, **kwargs: os._exit(77)
execution.execute_job(sys.argv[2], 'one', read_json(sys.argv[3]))
"""
        crashed = subprocess.run([sys.executable, "-X", "utf8", "-c", script,
                                  str(RUNTIME), str(self.spool), str(self.profile_path)],
                                 capture_output=True, timeout=20)
        self.assertEqual(77, crashed.returncode, crashed.stderr)
        run = self.spool / "runs/one"
        provenance_hash = digest(run / "provenance.json")
        output = self.root / "Условия после сбоя"
        collection = jobs.collect(self.spool, "one", output, allow_partial=True)
        self.assertFalse(collection["resultAvailable"])
        self.assertEqual("running", collection["observedJob"]["status"])
        provenance = read_json(output / "provenance.json")
        self.assertEqual(provenance_hash, digest(output / "provenance.json"))
        self.assertEqual(digest(package / "scenario.json"), provenance["scenarioSha256"])
        self.assertEqual(digest(package / "input/workload.py"), provenance["files"]["workload.py"]["sha256"])
        self.assertEqual({"delay": 0.08}, provenance["parameters"])
        self.assertEqual(900, provenance["phaseTimeoutSeconds"]["action"])
        self.assertEqual(["measure"], provenance["operations"])
        self.assertIn("declarations", provenance["identityEvidence"])
        self.assertEqual("worker", provenance["executor"])
        state = execution.execute_job(self.spool, "one", self.profile)
        self.assertEqual("interrupted", state["status"])
        self.assertEqual(provenance_hash, digest(run / "provenance.json"))
        self.assertFalse((run / "context.json").exists())
        self.assertFalse((run / "result.json").exists())

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

    def test_pull_worker_uses_optional_folder_for_blobs_and_pull_for_control(self):
        server, thread, url = pull.start_broker()
        controller = self.root / "контроллер подключения.json"
        worker = self.root / "воркер подключения.json"
        bulk = self.root / "Синхронизируемая папка"
        bulk.mkdir()
        pairing = bootstrap.pair(url, controller, worker, worker_id="terminal-user",
                                 controller_folder=bulk, worker_folder=bulk, threshold_bytes=1)
        self.assertEqual("terminal-user", pairing["workerId"])
        self.assertNotIn("token", pairing)
        _, package = self.package("pull-job", runner="worker", agent_policy="off")
        runtime = RUNTIME / "remote_work.py"
        process = subprocess.Popen([sys.executable, "-X", "utf8", str(runtime), "worker",
                                    "--spool", str(self.spool), "--connection", str(worker),
                                    "--persistent", "--max-jobs", "10", "--max-lifetime-seconds", "30"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        connection = transport.Connection(read_json(controller))
        try:
            sent = connection.send(package)
            self.assertEqual("folder", sent["transferChannels"]["workload.py"])
            deadline = time.monotonic() + 15
            state = None
            while time.monotonic() < deadline:
                state = connection.call({"operation": "status", "id": "pull-job"})
                if state["status"] in ("completed", "partial", "cancelled", "failed", "interrupted",
                                       "needs-attention"):
                    break
                time.sleep(0.05)
            self.assertEqual("completed", state["status"], state)
            output = self.root / "Результат через pull"
            result = connection.collect("pull-job", output)
            self.assertEqual("completed", result["status"], result)
            self.assertTrue(any((bulk / "itl-results").glob("*")))
            self.assertEqual("connected", read_json(self.spool / "pull-connection.json")["status"])
        finally:
            process.terminate()
            process.wait(timeout=10)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_user_local_controller_reuses_worker_across_project_tasks(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        controller_file = self.root / "пара контроллера.json"
        worker_file = self.root / "пара воркера.json"
        other_controller = self.root / "вторая пара контроллера.json"
        other_worker = self.root / "вторая пара воркера.json"
        bootstrap.pair("http://127.0.0.1:" + str(port), controller_file, worker_file,
                       worker_id="ufa-user")
        bootstrap.pair("http://127.0.0.1:" + str(port), other_controller, other_worker,
                       worker_id="ufa-other-user")
        home = self.root / "профили пользователя"
        project_one, project_two = self.root / "проект один", self.root / "проект два"
        project_one.mkdir()
        project_two.mkdir()
        runtime = RUNTIME / "remote_work.py"
        with patch.dict(os.environ, {"ITL_REMOTE_CONTROLLER_HOME": str(home)}):
            registered = controller.register("ufa-user", controller_file, port=port)
            self.assertEqual("registered", registered["status"])
            self.assertEqual("already-registered", controller.register("ufa-user", controller_file,
                                                                         port=port)["status"])
            self.assertEqual(["ufa-user"],
                             [item["name"] for item in controller.list_connections()["connections"]])
            worker_process = subprocess.Popen(
                [sys.executable, "-X", "utf8", str(runtime), "worker", "--spool", str(self.spool),
                 "--connection", str(worker_file), "--persistent", "--max-lifetime-seconds", "30"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            broker = None
            def stop_broker(value):
                os.kill(value["pid"], signal.SIGTERM)
                owned = controller._started_processes.pop(value["pid"], None)
                if owned is not None:
                    owned.wait(timeout=10)
                else:
                    deadline = time.monotonic() + 10
                    while common.process_is_alive(value["pid"]) and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertFalse(common.process_is_alive(value["pid"]))
            try:
                environment = dict(os.environ)
                started = subprocess.run(
                    [sys.executable, "-X", "utf8", str(runtime), "controller", "--action", "ensure",
                     "--name", "ufa-user"], cwd=project_one, env=environment,
                    capture_output=True, text=True, timeout=20)
                self.assertEqual(0, started.returncode, started.stdout + started.stderr)
                broker = json.loads(started.stdout)
                self.assertEqual("broker-started", broker["status"])
                controller.register("ufa-other-user", other_controller, port=port)
                self.assertEqual("broker-reused", controller.ensure("ufa-other-user")["status"])
                command = [sys.executable, "-X", "utf8", str(runtime), "remote", "--host", "ufa-user",
                           "--action", "probe"]
                first = subprocess.run(command, cwd=project_one, env=environment,
                                       capture_output=True, text=True, timeout=20)
                self.assertEqual(0, first.returncode, first.stdout + first.stderr)
                self.assertEqual("process-identity-and-heartbeat-verified",
                                 json.loads(first.stdout)["worker"]["liveness"])
                second = subprocess.run(command, cwd=project_two, env=environment,
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(0, second.returncode, second.stdout + second.stderr)
                self.assertEqual(broker["brokerId"], controller.ensure("ufa-user")["brokerId"])
                stop_broker(broker)
                broker = None
                restarted = controller.ensure("ufa-user")
                broker = restarted
                self.assertEqual("broker-started", restarted["status"])
                self.assertEqual("process-identity-and-heartbeat-verified",
                                 transport.Connection(read_json(registered["connection"])).call(
                                     {"operation": "probe"})["worker"]["liveness"])
            finally:
                if worker_process.poll() is None:
                    worker_process.terminate()
                    worker_process.wait(timeout=10)
                if broker and broker.get("pid"):
                    stop_broker(broker)

    def test_controller_never_replaces_unknown_listener(self):
        seen_headers = []
        response = {"status": "broker-ready", "brokerId": "foreign", "proof": "invalid"}
        class ForeignHandler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                return

            def do_POST(self):
                seen_headers.append(dict(self.headers))
                self.rfile.read(int(self.headers["Content-Length"]))
                body = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        listener = ThreadingHTTPServer(("127.0.0.1", 0), ForeignHandler)
        thread = threading.Thread(target=listener.serve_forever, daemon=True)
        thread.start()
        try:
            port = listener.server_address[1]
            controller_file = self.root / "unknown-controller.json"
            worker_file = self.root / "unknown-worker.json"
            bootstrap.pair("http://127.0.0.1:" + str(port), controller_file, worker_file)
            with patch.dict(os.environ, {"ITL_REMOTE_CONTROLLER_HOME": str(self.root / "private")}):
                controller.register("unknown", controller_file, port=port)
                with self.assertRaisesRegex(WorkError, "BROKER_PORT_OCCUPIED_OR_PAIR_NOT_LOADED"):
                    controller.ensure("unknown")
                response.clear()
                response.update({"error": "PULL_ROUTE_UNKNOWN"})
                with self.assertRaisesRegex(WorkError, "BROKER_PORT_OCCUPIED_OR_PAIR_NOT_LOADED"):
                    controller.ensure("unknown")
            self.assertEqual(2, len(seen_headers))
            self.assertTrue(all("Authorization" not in headers for headers in seen_headers))
            self.assertEqual(port, listener.server_address[1])
        finally:
            listener.shutdown()
            listener.server_close()
            thread.join(timeout=5)

    def test_controller_checks_local_broker_when_public_url_is_not_locally_routable(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        controller_file = self.root / "controller-proxy.json"
        worker_file = self.root / "worker-proxy.json"
        bootstrap.pair("https://controller.invalid:" + str(port), controller_file, worker_file)
        broker = None
        with patch.dict(os.environ, {"ITL_REMOTE_CONTROLLER_HOME": str(self.root / "private-proxy")}):
            controller.register("proxy", controller_file, port=port)
            try:
                broker = controller.ensure("proxy")
                self.assertEqual("broker-started", broker["status"])
                self.assertEqual("broker-reused", controller.ensure("proxy")["status"])
            finally:
                if broker and broker.get("pid"):
                    os.kill(broker["pid"], signal.SIGTERM)
                    controller._started_processes.pop(broker["pid"]).wait(timeout=10)

    def test_idle_worker_status_writes_only_on_change_or_bounded_refresh(self):
        from remote_work import WorkerHeartbeat
        heartbeat = WorkerHeartbeat(self.spool, "persistent", common.stamp())
        with patch.object(heartbeat, "_publish") as publish:
            heartbeat.update(status="ready")
            publish.assert_not_called()
            heartbeat.update(status="running")
            publish.assert_called_once()
        config = {"transport": "pull", "pull": {"url": "http://127.0.0.1:8765",
                  "workerId": "idle-worker", "token": "x" * 32}}
        worker = pull.PullWorker(config, self.spool, threading.Event())
        with patch.object(pull, "write_json") as published:
            worker._publish_connection({"status": "connected", "updatedAt": "first", "workerId": "idle-worker"})
            worker._publish_connection({"status": "connected", "updatedAt": "second", "workerId": "idle-worker"})
            self.assertEqual(1, published.call_count)
            worker.last_connection_at -= 11
            worker._publish_connection({"status": "connected", "updatedAt": "third", "workerId": "idle-worker"})
            self.assertEqual(2, published.call_count)
            worker._publish_connection({"status": "disconnected", "updatedAt": "fourth",
                                        "workerId": "idle-worker", "error": "PULL_CONNECTION_FAILED"})
            self.assertEqual(3, published.call_count)

    def test_paired_pull_worker_executes_host_command_without_remote_input(self):
        self.profile["hostCommands"] = {"enabled": True}
        write_json(self.spool / "profile.json", self.profile)
        server, thread, url = pull.start_broker()
        controller = self.root / "host-controller.json"
        worker = self.root / "host-worker.json"
        bootstrap.pair(url, controller, worker, worker_id="host-session")
        source = self.root / "скрипт для UFA"
        source.mkdir()
        (source / "script.py").write_text("print('сеанс доступен')\n", encoding="utf-8")
        spec = source / "command.json"
        write_json(spec, {"schemaVersion": 1, "argv": [sys.executable, "-X", "utf8", "{input}/script.py"],
                          "files": ["script.py"]})
        package = self.root / "pull host package"
        host_commands.pack(spec, package, identifier="host-pull")
        process = subprocess.Popen([sys.executable, "-X", "utf8", str(RUNTIME / "remote_work.py"), "worker",
                                    "--spool", str(self.spool), "--connection", str(worker),
                                    "--persistent", "--max-lifetime-seconds", "30"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        connection = transport.Connection(read_json(controller))
        try:
            connection.send(package)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                state = connection.call({"operation": "status", "id": "host-pull"})
                if state["status"] in ("completed", "failed", "interrupted"):
                    break
                time.sleep(0.05)
            self.assertEqual("completed", state["status"], state)
            result = self.root / "host result"
            connection.collect("host-pull", result)
            self.assertEqual("сеанс доступен\n", (result / "stdout.log").read_text(encoding="utf-8"))
        finally:
            process.terminate()
            process.wait(timeout=10)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_prepare_resume_requires_identical_unstarted_private_profile(self):
        spool = self.root / "recoverable preparation"
        first = bootstrap.prepare(spool, self.profile_path)
        self.assertEqual(first["launcher"], bootstrap.prepare(spool, self.profile_path, resume=True)["launcher"])
        changed = self.root / "changed profile.json"
        edited = read_json(self.profile_path)
        edited["hostCommands"] = {"enabled": True}
        write_json(changed, edited)
        with self.assertRaisesRegex(WorkError, "WORKER_RESUME_PROFILE_OR_OWNER_MISMATCH"):
            bootstrap.prepare(spool, changed, resume=True)
        self.assertEqual(read_json(spool / "profile.json")["targets"], self.profile["targets"])

    def test_unavailable_optional_folder_falls_back_to_pull_without_a_new_job(self):
        server, thread, url = pull.start_broker()
        controller = self.root / "controller-fallback.json"
        worker = self.root / "worker-fallback.json"
        controller_bulk = self.root / "Папка контроллера"
        worker_bulk = self.root / "Еще не синхронизированная папка воркера"
        controller_bulk.mkdir()
        worker_bulk.mkdir()
        bootstrap.pair(url, controller, worker, worker_id="folder-fallback",
                       controller_folder=controller_bulk, worker_folder=worker_bulk, threshold_bytes=1)
        _, package = self.package("same-job", runner="worker", agent_policy="off")
        process = subprocess.Popen([sys.executable, "-X", "utf8", str(RUNTIME / "remote_work.py"), "worker",
                                    "--spool", str(self.spool), "--connection", str(worker),
                                    "--persistent", "--max-jobs", "10", "--max-lifetime-seconds", "30"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            sent = transport.Connection(read_json(controller)).send(package)
            self.assertEqual("pull", sent["transferChannels"]["workload.py"])
            self.assertEqual("same-job", sent["id"])
            self.assertEqual(1, len(list((self.spool / "jobs").iterdir())))
        finally:
            process.terminate()
            process.wait(timeout=10)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_new_execution_contract_separates_runner_from_agent_policy(self):
        request, _ = self.package("modern", runner="worker", agent_policy="off")
        self.assertNotIn("route", request)
        self.assertEqual({"runner": "worker", "agentPolicy": "off", "legacyRoute": None},
                         jobs.execution_contract(request))
        legacy, _ = self.package("legacy-ssh", route="ssh")
        self.assertEqual("worker", jobs.execution_contract(legacy)["runner"])
        self.assertEqual("off", jobs.execution_contract(legacy)["agentPolicy"])

    def test_runner_contract_rejects_the_wrong_execution_owner(self):
        request, package = self.package("local-only", runner="local", agent_policy="off")
        with self.assertRaisesRegex(WorkError, "REMOTE_SEND_REQUIRES_WORKER_RUNNER"):
            transport.Connection(read_json(self.spool / "connection.json")).send(package)
        jobs.submit(package, self.spool)
        with self.assertRaisesRegex(WorkError, "EXECUTION_RUNNER_MISMATCH"):
            execution.execute_job(self.spool, request["id"], self.profile, expected_runner="worker")

    def test_pull_requires_tls_beyond_loopback(self):
        with self.assertRaisesRegex(WorkError, "PULL_TLS_REQUIRED_FOR_NON_LOOPBACK_LISTENER"):
            pull.start_broker("0.0.0.0", 0)
        with self.assertRaisesRegex(WorkError, "PULL_TLS_CERTIFICATE_AND_KEY_REQUIRED"):
            pull.start_broker(certificate=self.root / "server.pem")
        with self.assertRaisesRegex(WorkError, "PULL_TLS_REQUIRED"):
            bootstrap.pair("http://remote.example:8765", self.root / "controller.json",
                           self.root / "worker.json")

    def test_pull_broker_rejects_an_unpaired_identity(self):
        allowed_path = self.root / "allowed-controller.json"
        allowed = {"schemaVersion": 1, "transport": "pull",
                   "pull": {"url": "http://127.0.0.1:1", "workerId": "allowed-worker",
                            "token": "a" * 32, "timeoutSeconds": 1}}
        write_json(allowed_path, allowed)
        server, thread, url = pull.start_broker(connections=[allowed_path])
        try:
            rejected = json.loads(json.dumps(allowed))
            rejected["pull"].update(url=url, token="b" * 32)
            with self.assertRaisesRegex(WorkError, "PULL_AUTH_INVALID"):
                transport.Connection(rejected).call({"operation": "probe"})
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

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
        self.assertEqual("interrupted", result["status"])
        self.assertIn("INTERRUPTED_OWNER", result["error"])
        self.assertFalse((self.spool / "runs").exists())

    def test_reused_owner_pid_identity_is_reconciled_without_replay(self):
        _, package = self.package()
        jobs.submit(package, self.spool)
        write_json(self.spool / "state/one.json", {
            "id": "one", "status": "running", "ownerPid": os.getpid(),
            "ownerIdentity": {"pid": os.getpid(), "creationId": "previous-process"}})
        result = execution.execute_job(self.spool, "one", self.profile)
        self.assertEqual("interrupted", result["status"])
        self.assertIn("INTERRUPTED_OWNER_IDENTITY_MISMATCH", result["error"])
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

    def test_comparison_accepts_the_same_bound_database_and_topology(self):
        _, package = self.package()
        _, a = self.execute(package)
        b = dict(a, jobId="other")
        write_json(self.root / "a.json", a)
        write_json(self.root / "b.json", b)
        comparison = execution.compare(self.root / "a.json", self.root / "b.json")
        self.assertEqual("historical-comparison", comparison["kind"])
        self.assertEqual(0, comparison["differenceSeconds"])

    def test_comparison_rejects_another_database_and_file_server_topology(self):
        _, package = self.package()
        _, a = self.execute(package)
        b = dict(a, jobId="other", databaseIdentity="another-base")
        write_json(self.root / "a.json", a)
        write_json(self.root / "b.json", b)
        with self.assertRaisesRegex(WorkError, "databaseIdentity"):
            execution.compare(self.root / "a.json", self.root / "b.json")
        b = dict(a, jobId="other", databaseTopology="server")
        write_json(self.root / "b.json", b)
        with self.assertRaisesRegex(WorkError, "databaseTopology"):
            execution.compare(self.root / "a.json", self.root / "b.json")

    def test_comparison_rejects_legacy_result_without_database_binding(self):
        _, package = self.package()
        _, a = self.execute(package)
        b = dict(a, jobId="other")
        for value in (a, b):
            value.pop("databaseIdentity")
            value.pop("databaseTopology")
        write_json(self.root / "a.json", a)
        write_json(self.root / "b.json", b)
        with self.assertRaisesRegex(WorkError, "databaseIdentity"):
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

    def test_resource_policy_combines_operation_limits_conservatively(self):
        target = {"resourceLimits": {"maxJobMemoryMb": 100, "minAvailableMemoryMb": 100,
                                     "byOperation": {
                                         "measure": {"maxJobMemoryMb": 20, "minAvailableMemoryMb": 200},
                                         "update": {"maxJobMemoryMb": 40, "minAvailableMemoryMb": 300}}}}
        policy = resolve_resource_limits(target, ["measure", "update"])
        self.assertEqual(20, policy["maxJobMemoryMb"])
        self.assertEqual(300, policy["minAvailableMemoryMb"])
        update_only = resolve_resource_limits(
            {"resourceLimits": {"maxJobMemoryMb": 100,
                                "byOperation": {"update": {"maxJobMemoryMb": 200}}}}, ["update"])
        self.assertEqual(200, update_only["maxJobMemoryMb"])

    def test_resource_violation_names_the_exceeded_boundary(self):
        policy = resolve_resource_limits({"resourceLimits": {"maxProcessMemoryMb": 10}}, ["measure"])
        breach = resource_violation(
            policy,
            {"availablePhysicalBytes": 1024 ** 3, "committedPercent": 10},
            {"privateBytes": 11 * 1024 * 1024},
            {"jobMemoryBytes": 0},
            {"privateBytes": 0})
        self.assertEqual("RESOURCE_LIMIT_EXCEEDED", breach["code"])
        self.assertEqual("process-memory", breach["metric"])

    def test_low_host_memory_blocks_before_child_launch(self):
        policy = resolve_resource_limits({"resourceLimits": {"minAvailableMemoryMb": 1024}}, ["measure"])
        low_host = {"availablePhysicalBytes": 100 * 1024 * 1024, "committedPercent": 10}
        small_worker = {"privateBytes": 10 * 1024 * 1024}
        from unittest.mock import patch
        log = self.root / "must-not-start.log"
        with patch.object(common, "host_memory_snapshot", return_value=low_host), \
                patch.object(common, "process_memory_snapshot", return_value=small_worker):
            with self.assertRaisesRegex(WorkError, "RESOURCE_LIMIT_EXCEEDED.*host-available-memory"):
                OwnedProcess([sys.executable, "-c", "raise SystemExit(99)"], self.root, log,
                             resource_limits=policy)
        self.assertFalse(log.exists())

    def test_resource_preflight_marks_job_failed_without_launch(self):
        self.profile["targets"]["fixture"]["resourceLimits"] = {"minAvailableMemoryMb": 10 ** 9}
        _, package = self.package()
        state, result = self.execute(package)
        self.assertEqual("failed", state["status"])
        self.assertIn("RESOURCE_LIMIT_EXCEEDED", result["error"])
        self.assertEqual([], result["timings"])

    def test_resource_breach_remains_primary_when_cleanup_also_fails(self):
        self.scenario["adapter"] = "command"
        self.scenario["commands"]["action"] = [
            sys.executable, "-c",
            "import time; blocks=[]\nfor _ in range(30):\n blocks.append(bytearray(1024*1024)); time.sleep(.1)"]
        self.scenario["commands"]["cleanup"] = [sys.executable, "-c", "raise SystemExit(7)"]
        self.profile["targets"]["fixture"]["resourceLimits"] = {
            "maxGrowthMb": 4, "growthWindowSeconds": 2, "pollIntervalSeconds": 0.1}
        _, package = self.package()
        state, result = self.execute(package)
        self.assertEqual("failed", state["status"])
        self.assertTrue(result["error"].startswith("RESOURCE_LIMIT_EXCEEDED"), result)
        self.assertIn("job-memory-growth", result["error"])
        self.assertEqual(["COMMAND_FAILED: exit=7"], result["cleanupErrors"])

    @unittest.skipUnless(os.name == "nt", "native Job Object contract is Windows-only")
    def test_windows_resource_breaker_captures_owned_tree_and_keeps_foreign_process(self):
        grandchild = self.root / "внук расходует память.py"
        child = self.root / "дочерний процесс расходует память.py"
        identities = self.root / "идентификаторы процессов.json"
        start_gate = self.root / "начать расход памяти.flag"
        grandchild.write_text(
            "import sys,time\nfrom pathlib import Path\n"
            "while not Path(sys.argv[1]).exists(): time.sleep(.02)\nblocks=[]\n"
            "for _ in range(120):\n blocks.append(bytearray(1024*1024)); time.sleep(0.08)\n",
            encoding="utf-8")
        child.write_text(
            "import json,os,subprocess,sys,time\nfrom pathlib import Path\n"
            "grand=subprocess.Popen([sys.executable,sys.argv[1],sys.argv[3]])\n"
            "open(sys.argv[2],'w',encoding='utf-8').write(json.dumps({'child':os.getpid(),'grandchild':grand.pid}))\n"
            "while not Path(sys.argv[3]).exists(): time.sleep(.02)\n"
            "blocks=[]\n"
            "for _ in range(120):\n blocks.append(bytearray(1024*1024)); time.sleep(0.08)\n"
            "grand.wait()\n", encoding="utf-8")
        telemetry = self.root / "resource-telemetry.jsonl"
        policy = resolve_resource_limits({"resourceLimits": {
            "pollIntervalSeconds": 0.1, "maxWorkerMemoryMb": 4096,
            "maxProcessMemoryMb": 128, "maxJobMemoryMb": 256,
            "minAvailableMemoryMb": 1, "maxCommittedPercent": 100,
            "maxGrowthMb": 6, "growthWindowSeconds": 3}}, ["measure"])
        foreign = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"])
        owned = None
        try:
            with self.assertRaisesRegex(WorkError, "RESOURCE_LIMIT_EXCEEDED.*job-memory-growth"):
                with OwnedProcess([sys.executable, str(child), str(grandchild), str(identities), str(start_gate)],
                                  self.root, self.root / "owned.log",
                                  resource_limits=policy, telemetry=telemetry) as owned:
                    deadline = time.monotonic() + 5
                    while not identities.is_file() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(identities.is_file())
                    start_gate.write_text("go", encoding="ascii")
                    owned.wait(15)
            pids = read_json(identities)
            deadline = time.monotonic() + 5
            while any(common.process_is_alive(pid) for pid in pids.values()) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(common.process_is_alive(pids["child"]))
            self.assertFalse(common.process_is_alive(pids["grandchild"]))
            self.assertIsNone(foreign.poll())
            summary = owned.resource_summary()
            self.assertEqual("job-memory-growth", summary["breach"]["metric"])
            self.assertGreaterEqual(len(summary["processes"]), 2)
            by_pid = {item["pid"]: item for item in summary["processes"]}
            self.assertEqual(pids["child"], by_pid[pids["grandchild"]]["parentPid"])
            for pid in pids.values():
                self.assertGreater(by_pid[pid]["peakPrivateBytes"], 0)
                self.assertGreater(by_pid[pid]["peakWorkingSetBytes"], 0)
                self.assertRegex(by_pid[pid]["commandIdentity"], "^[a-f0-9]{64}$")
        finally:
            foreign.terminate()
            foreign.wait()

    def test_worker_probe_requires_matching_process_identity_and_fresh_heartbeat(self):
        write_json(self.spool / "worker.json", {
            "status": "ready", "pid": os.getpid(), "updatedAt": common.stamp(),
            "processIdentity": {"pid": os.getpid(), "creationId": "not-this-process"}})
        worker = bootstrap.inspect(self.spool)["worker"]
        self.assertEqual("stale", worker["status"])
        self.assertEqual("identity-mismatch", worker["liveness"])

        actual = common.process_identity(os.getpid())
        write_json(self.spool / "worker.json", {
            "status": "ready", "pid": os.getpid(), "updatedAt": "2000-01-01T00:00:00+00:00",
            "processIdentity": actual})
        worker = bootstrap.inspect(self.spool)["worker"]
        self.assertEqual("stale", worker["status"])
        self.assertEqual("heartbeat-expired", worker["liveness"])

    def test_prepared_worker_launcher_keeps_legacy_worker_one_shot(self):
        launcher = (self.spool / "Start-Worker.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("worker_supervisor.py", launcher)
        self.assertNotIn(" --persistent", launcher)

    def test_probe_marks_dead_worker_heartbeat_stale(self):
        write_json(self.spool / "worker.json", {"status": "ready", "pid": 999999999})
        worker = bootstrap.inspect(self.spool)["worker"]
        self.assertEqual("stale", worker["status"])
        self.assertEqual("stale", worker["liveness"])

    def test_default_worker_processes_only_one_queued_job(self):
        _, first = self.package("first")
        _, second = self.package("second")
        jobs.submit(first, self.spool)
        jobs.submit(second, self.spool)
        runtime = RUNTIME / "remote_work.py"
        completed = subprocess.run([sys.executable, str(runtime), "worker", "--spool", str(self.spool)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=20)
        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)
        self.assertEqual("completed", jobs.status(self.spool, "first")["status"])
        self.assertEqual("queued", jobs.status(self.spool, "second")["status"])
        worker = read_json(self.spool / "worker.json")
        self.assertEqual("stopped", worker["status"])
        self.assertEqual(1, worker["jobsProcessed"])
        self.assertEqual(worker["pid"], worker["processIdentity"]["pid"])
        self.assertRegex(worker["processIdentity"]["creationId"], "^(windows-filetime|proc-start):")
        self.assertEqual(common.current_user_identity(), worker["sessionIdentity"]["user"])
        self.assertEqual(common.current_user_identity(), read_json(self.spool / "profile.json")["workerOwner"])

    def test_worker_refreshes_identity_heartbeat_during_a_long_job(self):
        _, package = self.package(values={"delay": 8})
        jobs.submit(package, self.spool)
        runtime = RUNTIME / "remote_work.py"
        worker_process = subprocess.Popen([sys.executable, str(runtime), "worker", "--spool", str(self.spool)],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if jobs.status(self.spool, "one").get("status") == "running":
                    break
                time.sleep(0.05)
            self.assertEqual("running", jobs.status(self.spool, "one")["status"])
            time.sleep(5.5)
            worker = bootstrap.inspect(self.spool)["worker"]
            self.assertEqual("process-identity-and-heartbeat-verified", worker["liveness"])
            self.assertEqual("running", worker["status"])
        finally:
            if worker_process.poll() is None:
                worker_process.terminate()
            worker_process.communicate(timeout=10)

    @unittest.skipUnless(os.name == "nt", "worker Job Object ownership is Windows-only")
    def test_killed_worker_closes_owned_child_and_next_worker_only_reconciles(self):
        (self.source / "workload.py").write_text(
            "import os,sys,time\nfrom pathlib import Path\n"
            "sys.path.insert(0,sys.argv[1])\nfrom itl_measure import context,measurement,verify\n"
            "c=context()\n"
            "if sys.argv[2]=='action':\n"
            " (Path(c['iteration']).parent/'owned-child.json').write_text(str(os.getpid()),encoding='ascii')\n"
            " with measurement(): time.sleep(20)\n"
            "else: verify([{'name':'never-replayed','passed':False}])\n", encoding="utf-8")
        _, package = self.package()
        jobs.submit(package, self.spool)
        runtime = RUNTIME / "remote_work.py"
        first = subprocess.Popen([sys.executable, str(runtime), "worker", "--spool", str(self.spool)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        child_path = self.spool / "runs/one/owned-child.json"
        try:
            deadline = time.monotonic() + 10
            while not child_path.is_file() and first.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if not child_path.is_file():
                stdout, stderr = first.communicate(timeout=10)
                self.fail("owned child did not start\n" + stdout + stderr)
            child_pid = int(child_path.read_text(encoding="ascii"))
            self.assertTrue(common.process_is_alive(child_pid))
            first.terminate()
            first.communicate(timeout=10)
            deadline = time.monotonic() + 5
            while common.process_is_alive(child_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(common.process_is_alive(child_pid))

            second = subprocess.run([sys.executable, str(runtime), "worker", "--spool", str(self.spool)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
            self.assertEqual(0, second.returncode, second.stdout + second.stderr)
            state = jobs.status(self.spool, "one")
            self.assertEqual("interrupted", state["status"])
            self.assertIn("INTERRUPTED_OWNER", state["error"])
            self.assertFalse(state["reconciliation"]["workloadReplayed"])
            self.assertEqual(child_pid, int(child_path.read_text(encoding="ascii")))
        finally:
            if first.poll() is None:
                first.terminate()
                first.communicate(timeout=10)

    def test_persistent_worker_requires_explicit_profile_authorization(self):
        runtime = RUNTIME / "remote_work.py"
        completed = subprocess.run([sys.executable, str(runtime), "worker", "--persistent",
                                    "--spool", str(self.spool)], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, timeout=10)
        self.assertEqual(1, completed.returncode)
        self.assertIn("PERSISTENT_WORKER_NOT_ALLOWED", completed.stdout)

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
                            mode="time", runner="local", agent_policy="off", repeats=1, warmups=0)
        archive = self.root / "bundle.zip"
        bootstrap.export_bundle(REPO, archive)
        extracted = self.root / "portable bundle"
        with zipfile.ZipFile(archive) as z:
            z.extractall(extracted)
        runtime = extracted / ".agents/skills/itl-remote-runner/scripts/remote_work.py"
        self.assertFalse((extracted / "install-agent-1c-workflow.ps1").exists())
        for name in ('core', 'runtime-values', 'sessions', 'vanessa'):
            relative = '.agents/skills/1c-workflow/scripts/lib/agent-1c.' + name + '.ps1'
            self.assertEqual(digest(REPO / relative), digest(extracted / relative))
        jobs.submit(self.root / "calibration-package", self.spool)
        from itl_remote.common import capture
        state = json.loads(capture([sys.executable, str(runtime), "execute", "--spool", str(self.spool), "--id", request["id"]]))
        self.assertEqual("completed", state["status"], state)

    def test_portable_bundle_includes_verified_external_python_package(self):
        import shutil
        import zipfile
        root = self.root / "Исходники комплекта"
        for name in ("itl-remote-runner", "itl-remote-agent", "itl-performance"):
            shutil.copytree(REPO / ".agents/skills" / name, root / ".agents/skills" / name,
                            ignore=shutil.ignore_patterns("__pycache__"))
        lib = root / ".agents/skills/1c-workflow/scripts/lib"
        lib.mkdir(parents=True)
        for name in ("core", "ports", "sessions", "runtime-values", "immutable-download", "vanessa"):
            filename = "agent-1c." + name + ".ps1"
            shutil.copyfile(REPO / ".agents/skills/1c-workflow/scripts/lib" / filename, lib / filename)
        package = self.root / "Внешний архив.nupkg"
        package.write_bytes(b"fixture pinned package")
        assets = root / ".agents/skills/itl-remote-runner/assets/python-runtime"
        definition = read_json(assets / "manifest.json")
        definition["sha256"] = digest(package)
        write_json(assets / "manifest.json", definition)
        archive = self.root / "Автономный комплект.zip"
        bootstrap.export_bundle(root, archive, package)
        relative = ".agents/skills/itl-remote-runner/assets/python-runtime/" + definition["package"]
        with zipfile.ZipFile(archive) as bundle:
            self.assertEqual(package.read_bytes(), bundle.read(relative))
            manifest = json.loads(bundle.read("bundle-manifest.json"))
            self.assertEqual(definition["sha256"], manifest["files"][relative]["sha256"])
            self.assertEqual(1, bundle.namelist().count(relative))
            self.assertIn(".agents/skills/1c-workflow/scripts/lib/agent-1c.immutable-download.ps1", bundle.namelist())
        package.write_bytes(b"modified archive")
        rejected = self.root / "rejected.zip"
        with self.assertRaisesRegex(WorkError, "PORTABLE_PYTHON_ARCHIVE_HASH_MISMATCH"):
            bootstrap.export_bundle(root, rejected, package)
        self.assertFalse(rejected.exists())

    def test_worker_stages_newer_verified_generation_without_overwriting_live_runtime(self):
        import zipfile
        self.profile["workerUpdatePolicy"] = "compatible"
        write_json(self.spool / "profile.json", self.profile)
        original = self.root / "worker-current.zip"
        bootstrap.export_bundle(REPO, original)
        candidate = self.root / "worker-next.zip"
        with zipfile.ZipFile(original) as source, zipfile.ZipFile(candidate, "x", zipfile.ZIP_DEFLATED) as output:
            values = {info.filename: source.read(info.filename) for info in source.infolist()}
            version_name = ".agents/skills/itl-remote-runner/scripts/itl_remote/__init__.py"
            values[version_name] = values[version_name].replace(b'VERSION = "1.2.1"', b'VERSION = "1.3.0"')
            manifest = json.loads(values["bundle-manifest.json"])
            manifest["version"] = "1.3.0"
            manifest["files"][version_name] = {"sha256": hashlib.sha256(values[version_name]).hexdigest(),
                                                "bytes": len(values[version_name])}
            values["bundle-manifest.json"] = json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
            for name, value in values.items():
                output.writestr(name, value)
        entry = {"sha256": digest(candidate), "bytes": candidate.stat().st_size}
        blob = transport.blob_path(self.spool, entry["sha256"])
        blob.parent.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(candidate.read_bytes())
        staged = updates.stage(self.spool, {"operation": "stage-update", **entry}, {})
        self.assertEqual("worker-update-staged", staged["status"])
        pending = read_json(self.spool / "runtime/pending.json")
        self.assertEqual("1.3.0", pending["version"])
        self.assertTrue(Path(pending["runtime"]).is_file())
        self.assertTrue(Path(pending["supervisor"]).is_file())
        self.assertNotEqual(Path(pending["runtime"]), RUNTIME / "remote_work.py")

    def test_worker_update_rejects_a_tampered_manifest_entry(self):
        import zipfile
        self.profile["workerUpdatePolicy"] = "compatible"
        write_json(self.spool / "profile.json", self.profile)
        original = self.root / "worker-original.zip"
        bootstrap.export_bundle(REPO, original)
        candidate = self.root / "worker-tampered.zip"
        runtime_name = ".agents/skills/itl-remote-runner/scripts/remote_work.py"
        with zipfile.ZipFile(original) as source, zipfile.ZipFile(candidate, "x", zipfile.ZIP_DEFLATED) as output:
            for info in source.infolist():
                value = source.read(info.filename)
                if info.filename == "bundle-manifest.json":
                    manifest = json.loads(value)
                    manifest["version"] = "1.3.0"
                    value = json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
                elif info.filename == runtime_name:
                    value += b"\n# tampered\n"
                output.writestr(info.filename, value)
        entry = {"sha256": digest(candidate), "bytes": candidate.stat().st_size}
        blob = transport.blob_path(self.spool, entry["sha256"])
        blob.parent.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(candidate.read_bytes())
        with self.assertRaisesRegex(WorkError, "WORKER_UPDATE_FILE_HASH_MISMATCH"):
            updates.stage(self.spool, {"operation": "stage-update", **entry}, {})
        self.assertFalse((self.spool / "runtime/pending.json").exists())

    def test_pull_preparation_generates_persistent_supervised_user_launcher(self):
        server, thread, url = pull.start_broker()
        try:
            controller = self.root / "controller.json"
            worker = self.root / "worker.json"
            bootstrap.pair(url, controller, worker, worker_id="standard-user")
            spool = self.root / "worker pull spool"
            prepared = bootstrap.prepare(spool, self.profile_path, worker)
            launcher = (spool / "Start-Worker.ps1").read_text(encoding="utf-8-sig")
            self.assertIn("worker_supervisor.py", launcher)
            self.assertIn(" --connection ", launcher)
            self.assertIn(" --persistent", launcher)
            self.assertEqual("compatible", prepared["workerUpdatePolicy"])
            self.assertEqual("compatible", read_json(spool / "profile.json")["workerUpdatePolicy"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_worker_supervisor_rolls_back_an_unstartable_pending_generation(self):
        write_json(self.spool / "runtime/pending.json",
                   {"schemaVersion": 1, "version": "1.3.0", "archiveSha256": "a" * 64,
                    "runtime": str(self.root / "missing runtime.py"),
                    "supervisor": str(RUNTIME / "worker_supervisor.py"), "stagedAt": common.stamp()})
        completed = subprocess.run([sys.executable, "-X", "utf8", str(RUNTIME / "worker_supervisor.py"),
                                    "--spool", str(self.spool),
                                    "--bootstrap-runtime", str(RUNTIME / "remote_work.py")],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual("pending-runtime-missing", read_json(self.spool / "runtime/rollback.json")["reason"])
        self.assertFalse((self.spool / "runtime/pending.json").exists())

    def test_persistent_supervisor_restarts_after_bounded_worker_limit(self):
        runtime = self.root / "bounded worker.py"
        runtime.write_text('''import json, pathlib, sys
args = sys.argv[1:]
spool = pathlib.Path(args[args.index("--spool") + 1])
counter = spool / "starts.txt"
count = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(count))
(spool / "worker.json").write_text(json.dumps({"reason": "max-jobs" if count == 1 else "finished"}))
''', encoding="utf-8")
        write_json(self.spool / "runtime/current.json", {"runtime": str(runtime)})
        completed = subprocess.run([sys.executable, "-X", "utf8", str(RUNTIME / "worker_supervisor.py"),
                                    "--spool", str(self.spool), "--bootstrap-runtime", str(runtime),
                                    "--persistent"], capture_output=True, timeout=20)
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual("2", (self.spool / "starts.txt").read_text())

    def test_worker_supervisor_applies_update_staged_by_running_worker_without_user_restart(self):
        current_runtime = self.root / "current worker.py"
        trial_runtime = self.root / "trial worker.py"
        sha = "b" * 64
        trial_runtime.write_text('''import json, pathlib, sys
arguments = sys.argv[1:]
confirmation = pathlib.Path(arguments[arguments.index("--confirm-path") + 1])
generation = arguments[arguments.index("--generation") + 1]
confirmation.parent.mkdir(parents=True, exist_ok=True)
confirmation.write_text(json.dumps({"archiveSha256": generation}), encoding="utf-8")
''', encoding="utf-8")
        current_runtime.write_text('''import json, pathlib, sys
arguments = sys.argv[1:]
spool = pathlib.Path(arguments[arguments.index("--spool") + 1])
pending = {"schemaVersion": 1, "version": "1.3.0", "archiveSha256": "''' + sha + '''",
           "runtime": r"''' + str(trial_runtime) + '''", "supervisor": "fixture",
           "stagedAt": "fixture"}
path = spool / "runtime" / "pending.json"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(pending), encoding="utf-8")
''', encoding="utf-8")
        write_json(self.spool / "runtime/current.json",
                   {"schemaVersion": 1, "version": "1.2.0", "runtime": str(current_runtime)})
        completed = subprocess.run([sys.executable, "-X", "utf8", str(RUNTIME / "worker_supervisor.py"),
                                    "--spool", str(self.spool),
                                    "--bootstrap-runtime", str(current_runtime)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(0, completed.returncode, completed.stderr)
        selected = read_json(self.spool / "runtime/current.json")
        self.assertEqual("1.3.0", selected["version"])
        self.assertEqual(str(trial_runtime), selected["runtime"])
        self.assertFalse((self.spool / "runtime/pending.json").exists())

    def test_prepared_worker_preserves_immutable_interpreter_and_native_exit(self):
        launcher = (self.spool / "Start-Worker.ps1").read_text(encoding="utf-8-sig")
        self.assertIn(" -B -X utf8 -u ", launcher)
        self.assertIn("$env:PYTHONDONTWRITEBYTECODE='1'", launcher)
        self.assertIn("$env:PYTHONNOUSERSITE='1'", launcher)
        self.assertIn("$env:PYTHONHOME=$null", launcher)
        self.assertIn("exit $LASTEXITCODE", launcher)

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
        self.assertEqual("failed", state["status"], result)
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
