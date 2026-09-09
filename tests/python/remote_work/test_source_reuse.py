"""Pinned source reuse and explicit analysis scope through native packets."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

import test_source_mapping
import test_source_capture
import test_profile_engine
from itl_remote import profiling, jobs
from itl_remote.common import WorkError, digest, read_json, write_json
from itl_remote.source_analysis import Bindings
from itl_remote.source_index import build_manifest, apply_manifest
from itl_remote.deadlines import Deadline
from itl_remote.source_mapping import Selection, SourceResolver


class SourceSelectionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_source_mapping.SourceMappingTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def test_required_scope_excludes_other_native_context_without_hiding_raw_rows(self):
        f = self.fixture
        manifest = {**f.manifest, "modules": f.manifest["modules"][:1]}
        result = f.analyze(manifest, source_policy="required", source_modules=f.identities[:1])
        self.assertTrue(result["sourceAnalysis"]["requirementSatisfied"])
        self.assertEqual(1, result["sourceAnalysis"]["excludedModules"])
        self.assertEqual(2, len(result["packets"]))
        self.assertTrue(result["packets"][1]["top"])
        self.assertEqual("outside-requested-scope", result["packets"][1]["top"][0]["sourceIssue"])

    def test_absent_requested_module_does_not_silently_satisfy_required_analysis(self):
        f = self.fixture
        absent = {**f.identities[0], "objectID": "absent"}
        result = f.analyze(source_policy="required", source_modules=[f.identities[0], absent])
        self.assertFalse(result["sourceAnalysis"]["requirementSatisfied"])
        self.assertEqual([absent], result["sourceAnalysis"]["missingSelections"])

    def test_selection_can_follow_versions_but_never_collapses_extension_identity(self):
        f = self.fixture
        unversioned = {key: value for key, value in f.identities[0].items() if key != "version"}
        selection = Selection([unversioned])
        self.assertTrue(selection.includes({**f.identities[0], "version": "later"}))
        self.assertFalse(selection.includes({**f.identities[0], "extensionName": "Other"}))
        self.assertFalse(Selection(f.identities[:1]).includes({**f.identities[0], "version": "later"}))

    def test_invalid_selection_rejected_before_scenario_execution(self):
        for invalid in ([], {}, "all", [{"objectID": "incomplete"}], [{"id": 5}]):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(WorkError, "SOURCE_MODULE_SELECTION_INVALID"):
                Selection(invalid)
        with self.assertRaisesRegex(WorkError, "SOURCE_MODULE_SELECTION_REQUIRES_ANALYSIS"):
            jobs.validate_scenario({"sourceAnalysisModules": self.fixture.identities[:1]})

    def test_excluded_source_file_is_never_read(self):
        f = self.fixture
        resolver = SourceResolver(f.manifest, root=f.root, selection=f.identities[:1])
        with patch.object(Path, "read_bytes", side_effect=AssertionError("unexpected source access")):
            self.assertEqual("outside-requested-scope", resolver.resolve(f.identities[1])["sourceIssue"])

    def test_cli_applies_selected_scope_and_returns_unmet_scope_with_raw_data(self):
        f = self.fixture
        mapping = f.root / "Карта модулей.json"
        selection = f.root / "Нужные модули.json"
        write_json(mapping, {**f.manifest, "modules": f.manifest["modules"][:1]})
        write_json(selection, f.identities[:1])
        argv = [sys.executable, "-X", "utf8", str(test_source_mapping.RUNTIME / "remote_work.py"),
                "analyze", "--raw", *map(str, f.paths), "--source-map", str(mapping),
                "--source-analysis", "required", "--source-modules", str(selection)]
        completed = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)
        self.assertEqual(1, json.loads(completed.stdout)["sourceAnalysis"]["excludedModules"])
        write_json(selection, [{**f.identities[0], "version": "wrong"}])
        failed = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(2, failed.returncode, failed.stdout + failed.stderr)
        self.assertTrue(json.loads(failed.stdout)["packets"])


class SourceReuseTests(unittest.TestCase):
    def setUp(self):
        self.source = test_source_capture.SourceIndexTests()
        self.source.setUp()
        self.addCleanup(self.source.doCleanups)
        self.manifest = build_manifest(self.source.snapshot, [self.source.profile])
        self.path = self.source.root / "source-map.json"
        self.reference = {"path": str(self.path), "sha256": digest(self.path)}

    def bindings(self, suffix="analysis"):
        return Bindings(self.source.root / suffix, [self.source.profile], None, Deadline("source-capture", 30))

    def test_copied_run_sources_survive_original_source_removal(self):
        bindings = self.bindings()
        bindings.reuse([self.reference], self.source.root)
        self.assertEqual(2, bindings.evidence["reusedModules"])
        source_file = self.source.root / self.manifest["modules"][0]["path"]
        source_file.unlink()
        profile = copy.deepcopy(self.source.profile)
        apply_manifest(profile, {"path": str(bindings.root)}, bindings.manifest, "required")
        self.assertTrue(profile["sourceAnalysis"]["requirementSatisfied"])
        self.assertTrue(all(Path(p["top"][0]["source"]).is_relative_to(bindings.root) for p in profile["packets"]))

    def test_changed_manifest_or_source_cannot_reuse_observed_version_on_other_bytes(self):
        self.path.write_bytes(self.path.read_bytes() + b"\n")
        bindings = self.bindings()
        bindings.reuse([self.reference], self.source.root)
        self.assertEqual(0, bindings.evidence["reusedModules"])
        self.assertIn("SOURCE_REUSE_MANIFEST_CHANGED", bindings.evidence["diagnostics"])
        source_file = self.source.root / self.manifest["modules"][0]["path"]
        source_file.write_bytes(b"// modified after capture\n")
        bindings.reuse([{**self.reference, "sha256": digest(self.path)}], self.source.root)
        self.assertEqual(0, bindings.evidence["reusedModules"])
        self.assertTrue(any(isinstance(item, dict) and item["issue"] == "source-hash-mismatch" for item in bindings.evidence["diagnostics"]))

    def test_conflicting_pinned_bindings_never_choose_first_and_duplicate_bytes_are_harmless(self):
        bindings = self.bindings()
        bindings.reuse([self.reference, self.reference], self.source.root)
        self.assertEqual(2, len(bindings.manifest["modules"]))
        changed = self.source.root / "other.bsl"
        changed.write_bytes(b"// alternative\n" * 5000)
        second = {**self.manifest, "modules": [{**m, "path": changed.name, "sha256": digest(changed)} for m in self.manifest["modules"]]}
        path = self.source.root / "second.json"
        write_json(path, second)
        bindings.reuse([{"path": str(path), "sha256": digest(path)}], self.source.root)
        self.assertEqual(0, bindings.evidence["reusedModules"])
        self.assertEqual("ambiguous-source-binding", SourceResolver(bindings.manifest, root=bindings.root).resolve(self.source.module)["sourceIssue"])

    def engine(self, selection=None):
        fixture = test_profile_engine.ProfileEngineTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        fixture.source_policy("required", selection)
        fixture.target["sourceCapture"] = {"manifests": [self.reference]}
        return fixture

    def test_engine_skips_designer_when_requested_module_already_matches(self):
        fixture = self.engine([self.source.module])
        with patch("itl_remote.source_capture.Snapshot", side_effect=AssertionError("must not launch Designer")):
            state, result = fixture.execute(native=copy.deepcopy(self.source.profile))
        self.assertEqual("partial", state["status"])  # fixture marks raw coverage partial
        self.assertFalse(result["sourceResolution"]["captureAttempted"])
        self.assertEqual(1, result["sourceResolution"]["reusedModules"])
        self.assertTrue(result["profiles"][0]["sourceAnalysis"]["requirementSatisfied"])
        self.assertEqual(1, result["profiles"][0]["sourceAnalysis"]["excludedModules"])
        self.assertEqual(digest(result["sourceManifest"]["path"]), result["sourceManifest"]["sha256"])

    def test_engine_captures_only_unresolved_bindings_and_keeps_reused_modules(self):
        write_json(self.path, {**self.manifest, "modules": self.manifest["modules"][:1]})
        self.reference["sha256"] = digest(self.path)
        fixture = self.engine()
        with patch("itl_remote.source_capture.Snapshot.run", return_value={**self.source.snapshot, "cleanupErrors": []}), \
                patch("itl_remote.source_index.build_manifest", wraps=build_manifest) as producer:
            state, result = fixture.execute(native=copy.deepcopy(self.source.profile))
        self.assertEqual("partial", state["status"], result)
        self.assertTrue(result["profiles"][0]["sourceAnalysis"]["requirementSatisfied"])
        self.assertEqual(1, result["sourceResolution"]["reusedModules"])
        self.assertEqual([self.source.profile["packets"][1]["sourceModules"][0]["moduleID"]], producer.call_args.args[2])
        self.assertEqual(2, len(read_json(result["sourceManifest"]["path"])["modules"]))

    def test_absent_selected_module_does_not_trigger_pointless_database_export(self):
        absent = {**self.source.module, "objectID": "absent"}
        fixture = self.engine([absent])
        with patch("itl_remote.source_capture.Snapshot", side_effect=AssertionError("no measured module to capture")):
            state, result = fixture.execute()
        self.assertEqual("needs-attention", state["status"])
        self.assertEqual("SOURCE_ANALYSIS_REQUIREMENT_UNSATISFIED", result["error"])
        self.assertFalse(result["sourceResolution"]["captureAttempted"])
        self.assertEqual([absent], result["profiles"][0]["sourceAnalysis"]["missingSelections"])

    def test_optional_capture_construction_failure_keeps_measurement_and_cleanup(self):
        fixture = self.engine()
        fixture.source_policy("optional")
        fixture.target["sourceCapture"] = {}
        with patch("itl_remote.source_capture.Snapshot", side_effect=WorkError("capture directory unavailable")):
            state, result = fixture.execute()
        self.assertEqual("partial", state["status"])
        self.assertIn("SOURCE_CAPTURE_FAILED: capture directory unavailable", result["limitations"])
        self.assertEqual([], result["cleanupErrors"])
        self.assertTrue(result["profiles"][0]["packets"])


if __name__ == "__main__":
    unittest.main()
