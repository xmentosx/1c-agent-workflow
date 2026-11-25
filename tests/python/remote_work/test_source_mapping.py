"""Native packet/source identity and required/optional analysis regressions."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))
from itl_remote import profiling
from itl_remote.common import digest
from itl_remote.source_mapping import SourceResolver, module_key

FIXTURES = Path(__file__).parent / "fixtures/rdbg-file-profile"


class SourceMappingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL исходники замера ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paths = [FIXTURES / name for name in ("client.xml", "server.xml")]
        self.identities = [profiling.fields(next(ET.parse(path).iter("{" + profiling.MEASURE + "}moduleID")))
                           for path in self.paths]
        self.source = self.root / "Модуль формы.bsl"
        last_line = max(int(line.text) for path in self.paths for line in
                        ET.parse(path).iter("{" + profiling.MEASURE + "}lineNo"))
        self.source.write_bytes(("// строка\r\n" * last_line).encode("utf-8-sig"))
        self.manifest = {"schemaVersion": 2, "modules": [
            {"moduleID": identity, "path": self.source.name, "sha256": digest(self.source),
             "origin": "database-snapshot", "snapshotId": "capture-1"}
            for identity in self.identities]}

    def analyze(self, manifest=None, **kwargs):
        return profiling.analyze_raw(self.paths, source_map=self.manifest if manifest is None else manifest,
                                     source_map_root=self.root, **kwargs)

    def test_native_client_and_server_bind_without_legacy_id_and_preserve_raw(self):
        before = [digest(path) for path in [*self.paths, self.source]]
        result = self.analyze(source_policy="required")
        self.assertTrue(result["sourceAnalysis"]["requirementSatisfied"])
        self.assertEqual("complete", result["sourceAnalysis"]["status"])
        for packet in result["packets"]:
            self.assertTrue(all(row["sourceMatched"] for row in packet["top"]))
            self.assertEqual("capture-1", packet["sourceModules"][0]["snapshotId"])
        self.assertEqual(before, [digest(path) for path in [*self.paths, self.source]])

    def test_empty_legacy_key_never_binds_native_modules(self):
        entry = self.manifest["modules"][0]
        result = self.analyze({"": {**entry, "moduleVersion": self.identities[0]["version"]}})
        self.assertEqual(0, result["sourceAnalysis"]["matchedModules"])
        self.assertTrue(result["complete"])

    def test_native_contexts_and_extensions_are_not_interchangeable(self):
        resolver = SourceResolver(self.manifest, root=self.root)
        self.assertNotEqual(module_key(self.identities[0]), module_key(self.identities[1]))
        for field in ("objectID", "propertyID", "extId", "extensionName", "URL", "type"):
            with self.subTest(field=field):
                wrong = {**self.identities[0], field: "different"}
                self.assertFalse(resolver.resolve(wrong)["sourceMatched"])

    def test_platform_default_fields_match_but_unknown_fields_remain_distinct(self):
        defaulted = {**self.identities[0], "type": "ConfigModule", "URL": "", "extensionName": ""}
        self.assertEqual(module_key(self.identities[0]), module_key(defaulted))
        self.assertNotEqual(module_key(defaulted), module_key({**defaulted, "futureIdentity": "different"}))

    def test_module_version_is_not_replaced_with_a_checkout_or_configuration_version(self):
        manifest = copy.deepcopy(self.manifest)
        for entry in manifest["modules"]:
            entry["moduleID"]["version"] = "other-object-version"
        result = self.analyze(manifest, source_policy="required")
        self.assertTrue(result["complete"])
        self.assertFalse(result["sourceAnalysis"]["requirementSatisfied"])
        self.assertEqual("module-version-mismatch", result["packets"][0]["top"][0]["sourceIssue"])

    def test_whole_configuration_mismatch_does_not_reject_matching_modules(self):
        manifest = {**self.manifest, "configurationVersion": "unrelated-branch-version"}
        self.assertEqual("complete", self.analyze(manifest)["sourceAnalysis"]["status"])

    def test_older_and_newer_snapshots_resolve_only_the_exact_version(self):
        old = copy.deepcopy(self.manifest["modules"][0])
        old["moduleID"]["version"] = "old"
        old["path"] = "absent-old-module.bsl"
        self.manifest["modules"].insert(0, old)
        self.assertEqual("complete", self.analyze()["sourceAnalysis"]["status"])

    def test_conflicting_bindings_are_ambiguous_even_if_one_file_exists(self):
        self.manifest["modules"].append({**self.manifest["modules"][0], "path": "other.bsl"})
        result = self.analyze()
        self.assertEqual("ambiguous-source-binding", result["packets"][0]["top"][0]["sourceIssue"])
        self.assertEqual("partial", result["sourceAnalysis"]["status"])

    def test_duplicate_identical_bindings_are_harmless(self):
        self.manifest["modules"] += copy.deepcopy(self.manifest["modules"])
        self.assertEqual("complete", self.analyze()["sourceAnalysis"]["status"])

    def test_source_edits_missing_files_and_encoding_are_explicit(self):
        self.source.write_text("changed", encoding="utf-8")
        self.assertEqual("source-hash-mismatch", self.analyze()["packets"][0]["top"][0]["sourceIssue"])
        self.source.write_bytes(b"\xff")
        for entry in self.manifest["modules"]:
            entry["sha256"] = digest(self.source)
        self.assertEqual("source-encoding-unsupported", self.analyze()["packets"][0]["top"][0]["sourceIssue"])
        self.source.unlink()
        self.assertEqual("source-file-missing", self.analyze()["packets"][0]["top"][0]["sourceIssue"])

    def test_matching_hash_does_not_validate_a_line_outside_the_source(self):
        self.source.write_text("// one line\n", encoding="utf-8")
        for entry in self.manifest["modules"]:
            entry["sha256"] = digest(self.source)
        result = self.analyze(source_policy="required")
        self.assertFalse(result["sourceAnalysis"]["requirementSatisfied"])
        self.assertEqual(0, result["sourceAnalysis"]["matchedLines"])
        self.assertEqual("source-line-out-of-range", result["packets"][0]["top"][0]["sourceIssue"])

    def test_no_source_analysis_does_not_read_source_files(self):
        resolver = SourceResolver(self.manifest, root=self.root, policy="none")
        with patch.object(Path, "read_bytes", side_effect=AssertionError("unexpected source read")):
            self.assertEqual("not-requested", resolver.resolve(self.identities[0])["sourceIssue"])
        self.assertTrue(self.analyze(source_policy="none")["sourceAnalysis"]["requirementSatisfied"])

    def test_all_modules_are_inventoried_even_beyond_top_thirty_rows(self):
        tree = ET.parse(self.paths[0])
        measure = next(tree.iter("{" + profiling.COMMANDS + "}measure"))
        original = measure.find("{" + profiling.MEASURE + "}moduleData")
        for index in range(40):
            extra = copy.deepcopy(original)
            next(extra.iter("{" + profiling.DATA + "}objectID")).text = "unmatched-" + str(index)
            measure.append(extra)
        packet_path = self.root / "expanded.xml"
        tree.write(packet_path, encoding="utf-8")
        self.paths = [packet_path]
        result = self.analyze(source_policy="required")
        self.assertEqual(30, len(result["packets"][0]["top"]))
        self.assertEqual(41, result["sourceAnalysis"]["modules"])
        self.assertEqual(1, result["sourceAnalysis"]["matchedModules"])
        self.assertFalse(result["sourceAnalysis"]["requirementSatisfied"])

    def test_cli_resolves_paths_against_manifest_directory_and_retains_required_failure(self):
        manifest_path = self.root / "source-map.json"
        manifest_path.write_text(json.dumps(self.manifest, ensure_ascii=False), encoding="utf-8")
        argv = [sys.executable, "-X", "utf8", str(RUNTIME / "remote_work.py"), "analyze", "--raw",
                *map(str, self.paths), "--source-map", str(manifest_path), "--source-analysis", "required"]
        completed = subprocess.run(argv, cwd=REPO, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)
        self.assertEqual("complete", json.loads(completed.stdout)["sourceAnalysis"]["status"])
        self.source.unlink()
        failed = subprocess.run(argv, cwd=REPO, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(2, failed.returncode, failed.stdout + failed.stderr)
        retained = json.loads(failed.stdout)
        self.assertTrue(retained["complete"])
        self.assertFalse(retained["sourceAnalysis"]["requirementSatisfied"])
        self.assertTrue(all(Path(packet["raw"]).is_file() for packet in retained["packets"]))


if __name__ == "__main__":
    unittest.main()
