"""Retained verified samples and phase evidence survive interrupted series."""
import copy
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

import test_runtime
from itl_remote import execution, jobs
from itl_remote.common import digest, read_json, write_json


class MeasurementProgressTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_runtime.RuntimeTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.run = self.fixture.spool / "runs/series"

    def package(self, repeats=2, warmups=0):
        scenario = self.fixture.source / "scenario.json"
        write_json(scenario, self.fixture.scenario)
        package = self.fixture.root / "Пакет серии"
        jobs.pack(scenario, package, target="fixture", mode="time", repeats=repeats,
                  warmups=warmups, identifier="series")
        return package

    def test_actual_engine_crash_retains_a_verified_sample_without_completing_or_replaying_the_series(self):
        package = self.package()
        jobs.submit(package, self.fixture.spool)
        script = """import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from itl_remote import execution
from itl_remote.common import read_json
original = execution.write_json
def persist(path, value):
    original(path, value)
    if Path(path).name == 'progress.json' and len(value['iterations']) == 2:
        # Between iterations: completed action/verification children have exited,
        # and the second iteration has not launched any child yet.
        os._exit(77)
execution.write_json = persist
execution.execute_job(sys.argv[2], 'series', read_json(sys.argv[3]))
"""
        process = subprocess.run([sys.executable, "-X", "utf8", "-c", script, str(test_runtime.RUNTIME),
                                  str(self.fixture.spool), str(self.fixture.profile_path)],
                                 capture_output=True, timeout=30)
        self.assertEqual(77, process.returncode, process.stderr)
        retained_hash = digest(self.run / "progress.json")
        output = self.fixture.root / "Собранные повторы"
        collection = jobs.collect(self.fixture.spool, "series", output, allow_partial=True)
        self.assertFalse(collection["resultAvailable"])
        snapshot = read_json(output / "progress.json")
        self.assertEqual("running", snapshot["status"])
        self.assertEqual(["verified", "running"], [item["status"] for item in snapshot["iterations"]])
        self.assertEqual(1, len(snapshot["timings"]))
        self.assertTrue(snapshot["timings"][0]["verified"])
        self.assertEqual(["ready", "action", "verify"], [item["name"] for item in snapshot["phases"]])
        self.assertTrue(all(item["status"] == "completed" for item in snapshot["phases"]))
        self.assertEqual(digest(output / "provenance.json"), snapshot["provenance"]["sha256"])
        self.assertFalse((output / "context.json").exists())
        self.assertFalse((output / "result.json").exists())
        state = execution.execute_job(self.fixture.spool, "series", self.fixture.profile)
        self.assertEqual("needs-attention", state["status"])
        self.assertEqual(retained_hash, digest(self.run / "progress.json"))
        self.assertFalse((self.run / "001-time/ready.json").exists())

    def test_progress_writes_stay_outside_handshake_timing_and_warmups_do_not_become_samples(self):
        package = self.package(repeats=1, warmups=1)
        spans, snapshots = [], []
        original = execution.write_json

        def persist(path, value):
            if Path(path).name == "progress.json":
                begin = time.monotonic_ns()
                original(path, value)
                spans.append((begin, time.monotonic_ns()))
                snapshots.append(copy.deepcopy(value))
            else:
                original(path, value)

        with patch.object(execution, "write_json", side_effect=persist):
            state, result = self.fixture.execute(package)
        self.assertEqual("completed", state["status"], result)
        self.assertEqual(1, len(result["timings"]))
        self.assertEqual(["warmup", "time"], [item["kind"] for item in result["iterations"]])
        for iteration in ("000-warmup", "001-time"):
            done = read_json(self.run / iteration / "done.json")
            for begin, end in spans:
                self.assertTrue(end <= done["startedNs"] or begin >= done["finishedNs"], (iteration, begin, end, done))
        for snapshot in snapshots:
            verified = {item["iteration"] for item in snapshot["iterations"] if item["status"] == "verified"}
            self.assertTrue(all(item["iteration"] in verified for item in snapshot["timings"]))
            if not snapshot["resultAvailable"]:
                self.assertEqual("running", snapshot["status"])
        self.assertEqual(result["timings"], snapshots[-1]["timings"])
        self.assertTrue(snapshots[-1]["resultAvailable"])

    def test_failed_business_verification_does_not_accept_a_timing(self):
        path = self.fixture.source / "workload.py"
        path.write_text(test_runtime.WORKLOAD.replace('== "готово"', '== "неверный результат"'), encoding="utf-8")
        state, result = self.fixture.execute(self.package(repeats=1))
        self.assertEqual("needs-attention", state["status"], result)
        snapshot = read_json(self.run / "progress.json")
        self.assertEqual([], snapshot["timings"])
        self.assertEqual("failed", snapshot["iterations"][0]["status"])
        # The public verify helper writes the failed business check, then exits
        # nonzero; the engine must retain both that evidence and the phase error.
        self.assertEqual("COMMAND_FAILED: exit=1", snapshot["error"])
        verification = read_json(self.run / "000-time/verification.json")
        self.assertFalse(verification["passed"])
        self.assertFalse(verification["checks"][0]["passed"])
        self.assertEqual("verify", snapshot["phases"][-1]["name"])
        self.assertEqual("failed", snapshot["phases"][-1]["status"])

    def test_failed_cleanup_retains_verified_samples_but_never_publishes_premature_completion(self):
        self.fixture.scenario["commands"]["cleanup"] = ["{python}", "-c", "raise SystemExit(19)"]
        state, result = self.fixture.execute(self.package(repeats=1))
        snapshot = read_json(self.run / "progress.json")
        self.assertEqual("needs-attention", state["status"], result)
        self.assertEqual("needs-attention", snapshot["status"])
        self.assertEqual(1, len(snapshot["timings"]))
        self.assertEqual("verified", snapshot["iterations"][0]["status"])
        self.assertEqual("failed", snapshot["phases"][-1]["status"])
        self.assertEqual("cleanup", snapshot["phases"][-1]["name"])
        self.assertTrue(snapshot["cleanupErrors"])

    def test_command_launch_failure_is_a_failed_phase_with_no_sample(self):
        self.fixture.scenario["adapter"] = "command"
        self.fixture.scenario["commands"]["action"] = ["{input}/absent-command.exe"]
        state, result = self.fixture.execute(self.package(repeats=1))
        self.assertEqual("needs-attention", state["status"], result)
        snapshot = read_json(self.run / "progress.json")
        self.assertEqual([], snapshot["timings"])
        self.assertEqual("failed", snapshot["phases"][0]["status"])
        self.assertEqual("action", snapshot["phases"][0]["name"])
        self.assertEqual("failed", snapshot["iterations"][0]["status"])


if __name__ == "__main__":
    unittest.main()
