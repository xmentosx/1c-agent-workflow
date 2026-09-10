"""Real child/stdio waits inherit one phase budget; no live 1C is used."""
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import test_runtime
from itl_remote import jobs, vanessa
from itl_remote.common import WorkError, read_json, write_json
from itl_remote.deadlines import Deadline, budgets


class PhaseDeadlineTests(unittest.TestCase):
    def test_invalid_phase_budgets_are_rejected_before_packaging(self):
        for value in (0, -1, True, "900", float("nan"), float("inf"), 86401):
            with self.subTest(value=value), self.assertRaises(WorkError):
                budgets({"phaseTimeoutSeconds": {"prepare": value}})
        with self.assertRaisesRegex(WorkError, "INVALID_PHASE_TIMEOUTS"):
            budgets({"phaseTimeoutSeconds": {"typo": 900}})

    def test_child_does_not_restart_budget_after_301_seconds(self):
        deadline = Deadline("prepare", 1800)
        context = {"phase": deadline.record()}
        now = time.monotonic_ns()
        with patch("time.monotonic_ns", return_value=now + 301_000_000_000):
            child = Deadline.from_context(context)
            self.assertGreater(child.remaining(), 1498)
            self.assertLess(child.remaining(), 1500)
        with patch("time.monotonic_ns", return_value=now + 1801_000_000_000):
            with self.assertRaisesRegex(WorkError, "PHASE_TIMEOUT: prepare"):
                Deadline.from_context(context).remaining()
        context["phase"]["executionHost"] = "another host"
        with self.assertRaisesRegex(WorkError, "FOREIGN_PHASE_DEADLINE_HOST"):
            Deadline.from_context(context)

    def test_adapter_wait_accepts_long_inherited_budget_and_honors_cancellation(self):
        with tempfile.TemporaryDirectory(prefix="ITL сроки с пробелом ") as directory:
            root = Path(directory)
            context = {"jobId": "job", "run": directory, "phase": Deadline("action", 1800).record(),
                       "cancelPath": str(root / "cancel.json")}
            response = root / "response.json"
            now = time.monotonic_ns
            timer = threading.Timer(.04, lambda: write_json(response, {"jobId": "job", "passed": True}))
            timer.start()
            try:
                with patch("time.monotonic_ns", side_effect=lambda: now() + 301_000_000_000):
                    self.assertTrue(vanessa.wait_response(response, context)["passed"])
            finally:
                timer.join()
            write_json(root / "cancel.json", {})
            with self.assertRaisesRegex(WorkError, "CANCELLED"):
                vanessa.wait_response(root / "missing.json", context)
            context["phase"] = Deadline("cleanup", 5).record()
            self.assertTrue(vanessa.wait_response(response, context)["passed"])

    def test_stdio_deadline_survives_old_limit_then_stops_without_replay(self):
        with tempfile.TemporaryDirectory(prefix="ITL длинный вызов ") as directory:
            root = Path(directory)
            script = root / "stdio.py"
            script.write_text('''import json, sys, time
from pathlib import Path
for line in sys.stdin:
    q = json.loads(line)
    with Path('received.jsonl').open('a', encoding='utf-8') as f:
        f.write(json.dumps(q) + '\\n')
    if 'id' not in q:
        continue
    if q['method'] == 'tools/call':
        time.sleep(.12)
    print(json.dumps({'id': q['id'], 'result': {'content': []}}), flush=True)
''', encoding="utf-8")
            client = vanessa.StdioMcp([sys.executable, str(script)], root, os.environ, root / "stderr",
                                      deadline=Deadline("action", 1800))
            now = time.monotonic_ns
            try:
                with patch("time.monotonic_ns", side_effect=lambda: now() + 301_000_000_000):
                    self.assertEqual({"content": []}, client.tool("long", {}))
                client.deadline = Deadline("action", .04)
                with self.assertRaisesRegex(WorkError, "PHASE_TIMEOUT"):
                    client.tool("short", {})
                with self.assertRaisesRegex(WorkError, "PREVIOUS_REQUEST_UNCERTAIN"):
                    client.tool("must-not-replay", {})
            finally:
                client.deadline = Deadline("cleanup", 5)
                client.close()
            received = [json.loads(line) for line in (root / "received.jsonl").read_text().splitlines()]
            calls = [q for q in received if q['method'] == 'tools/call']
            self.assertEqual(2, len(calls))
            self.assertGreater(calls[0]['params']['_meta']['itlPhaseRemainingMs'], 1490000)
            self.assertLess(calls[0]['params']['_meta']['itlPhaseRemainingMs'], 1500000)
            self.assertEqual(1, len([q for q in received if q['method'] == 'notifications/cancelled']))

    def test_facade_nonzero_exit_is_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "fail.py"
            script.write_text("import sys, json\nfor line in sys.stdin:\n q=json.loads(line)\n if 'id' in q: print(json.dumps({'id':q['id'],'result':{}}),flush=True)\nsys.exit(7)\n")
            client = vanessa.StdioMcp([sys.executable, str(script)], root, os.environ, root / "log")
            with self.assertRaisesRegex(WorkError, "CLEANUP_UNPROVEN.*exit=7"):
                client.close()
            self.assertTrue(client.stderr.closed)
            with self.assertRaisesRegex(WorkError, "CLEANUP_UNPROVEN"):
                client.close()


class EnginePhaseTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_runtime.RuntimeTests()
        self.fixture.setUp()

    def tearDown(self):
        self.fixture.tearDown()

    def test_prepare_and_cleanup_have_independent_budgets_and_child_action_inherits_long_limit(self):
        f = self.fixture
        phase_script = f.source / "phase.py"
        phase_script.write_text('''import json, os, sys, time
from pathlib import Path
c=json.loads(Path(os.environ['ITL_RUN_CONTEXT']).read_text())
assert c['phase']['name'] == sys.argv[1]
time.sleep(.15)
Path(c['target']['workspace'], sys.argv[1]+'.done').touch()
''', encoding="utf-8")
        workload = (f.source / "workload.py").read_text()
        workload = workload.replace('with measurement():', 'with measurement() as measured:\n        assert measured["phase"]["name"] == "action"\n        assert measured["phase"]["timeoutSeconds"] == 1800')
        (f.source / "workload.py").write_text(workload)
        f.scenario['files'].append('phase.py')
        f.scenario.update(timeoutSeconds=.05, phaseTimeoutSeconds={"prepare": 2, "cleanup": 2, "action": 1800, "ready": 2, "verify": 2})
        for phase in ('prepare', 'cleanup'):
            f.scenario['commands'][phase] = ['{python}', '{input}/phase.py', phase]
        _, package = f.package()
        state, result = f.execute(package)
        self.assertEqual('completed', state['status'], result)
        self.assertTrue((f.source / 'cleanup.done').exists())
        phases = read_json(f.spool / 'runs/one/progress.json')['phases']
        self.assertEqual(['prepare', 'ready', 'action', 'verify', 'cleanup'], [p['name'] for p in phases])
        self.assertEqual(f.scenario['phaseTimeoutSeconds'], {p['name']: p['timeoutSeconds'] for p in phases})
        self.assertTrue(all(p['status'] == 'completed' for p in phases))

    def test_timeout_keeps_failed_phase_evidence_and_runs_cleanup(self):
        f = self.fixture
        f.scenario['adapter'] = 'command'
        f.scenario.update(timeoutSeconds=.1, phaseTimeoutSeconds={'cleanup': 2})
        f.scenario['commands']['action'] = ['{python}', '-c', 'import time; time.sleep(10)']
        f.scenario['commands']['cleanup'] = ['{python}', '-c', 'from pathlib import Path; Path("cleanup.done").touch()']
        _, package = f.package()
        state, result = f.execute(package)
        self.assertEqual('needs-attention', state['status'])
        self.assertTrue((f.source / 'cleanup.done').exists())
        self.assertEqual(['failed', 'completed'], [p['status'] for p in result['phases']])
        self.assertEqual([], result['cleanupErrors'])


if __name__ == '__main__':
    unittest.main()
