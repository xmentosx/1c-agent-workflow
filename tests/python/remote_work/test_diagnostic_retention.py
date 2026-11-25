"""Measurement completion invokes native retention after owned process cleanup."""
from pathlib import Path
import os
import unittest
from unittest.mock import patch

import test_runtime
from itl_remote import diagnostic_retention, execution
from itl_remote.common import capture, read_json


@unittest.skipUnless(os.name == "nt", "installed Windows workflow adapter")
class DiagnosticRetentionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_runtime.RuntimeTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.helper = self.fixture.source / ".agents/skills/1c-workflow/scripts/agent-1c.ps1"
        self.helper.parent.mkdir(parents=True)
        self.helper.write_text("# fixture helper boundary", encoding="utf-8")

    def execute(self, *, failed_cleanup=False, fail_retention=False, real_helper=False):
        self.fixture.scenario["commands"]["prepare"] = ["{python}", "-c",
            "import os,pathlib; p=pathlib.Path(os.environ['TEMP']); "
            "assert os.environ['TMP']==str(p); (p/'v8_AA_1.tmp').write_text('disposable'); "
            "(p/'evidence.log').write_text('raw')"]
        if failed_cleanup:
            self.fixture.scenario["commands"]["cleanup"] = ["{python}", "-c", "raise SystemExit(19)"]

        def helper(argv, **kwargs):
            receipt = Path(argv[argv.index("-ProjectRoot") + 1]) / argv[argv.index("-DiagnosticCompletionPath") + 1]
            saved = read_json(receipt)
            self.assertTrue(saved["cleanupConfirmed"])
            self.assertEqual("completed", read_json(saved["resultPath"])["status"])
            self.assertEqual(1, len(saved["disposablePaths"]))
            self.assertTrue(saved["disposablePaths"][0].endswith("/native-temp/v8_AA_1.tmp"))
            self.assertTrue((receipt.parent / "native-temp/evidence.log").is_file())
            if fail_retention:
                raise OSError("retention unavailable")
            if real_helper:
                argv = list(argv)
                argv[3] = str(test_runtime.REPO / ".agents/skills/1c-workflow/scripts/agent-1c.ps1")
                return capture(argv, **kwargs)
            return "Штатная очистка\n".encode("utf-8")

        with patch.object(diagnostic_retention, "capture", side_effect=helper) as call:
            _, package = self.fixture.package()
            state, result = self.fixture.execute(package)
        return state, result, call

    def test_native_completion_has_an_exact_owned_temp_inventory_and_no_chat_dependency(self):
        state, result, call = self.execute()
        self.assertEqual("completed", state["status"], result)
        call.assert_called_once()
        argv = call.call_args.args[0]
        self.assertEqual(str(self.helper), argv[3])
        self.assertIn("-CleanupDiagnosticsOnly", argv)

    def test_unconfirmed_process_cleanup_never_enrolls_files(self):
        state, result, call = self.execute(failed_cleanup=True)
        self.assertEqual("failed", state["status"], result)
        self.assertTrue(result["cleanupErrors"])
        call.assert_not_called()

    def test_actual_native_helper_completes_under_the_measurement_guard(self):
        state, result, call = self.execute(real_helper=True)
        self.assertEqual("completed", state["status"], result)
        call.assert_called_once()
        retention = read_json(Path(state["result"]).parent / "artifact-retention.json")
        self.assertEqual("completed", retention["status"], retention)
        manifests = list((self.fixture.source / ".agent-1c/diagnostic-artifacts").glob("*.json"))
        self.assertEqual(1, len(manifests))
        self.assertEqual("itl-performance", read_json(manifests[0])["producer"])

    def test_retention_failure_preserves_the_measurement_and_reports_a_warning(self):
        state, result, call = self.execute(fail_retention=True)
        self.assertEqual("completed", state["status"], result)
        call.assert_called_once()
        retention = read_json(Path(state["result"]).parent / "artifact-retention.json")
        self.assertEqual("warning", retention["status"])
        self.assertIn("retention unavailable", retention["error"])
