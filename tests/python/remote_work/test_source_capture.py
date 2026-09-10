"""Capture orchestration, native source producer and unchanged raw coverage."""
import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / ".agents/skills/itl-remote-runner/scripts"))
from itl_remote import profiling
from itl_remote.access import Lease
from itl_remote.common import WorkError, digest, read_json, write_json
from itl_remote.deadlines import Deadline
from itl_remote.source_capture import Snapshot, extension_names
from itl_remote.source_index import build_manifest, apply_manifest

FIXTURES = Path(__file__).parent / "fixtures/rdbg-file-profile"


class SourceIndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL снимок исходников ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.profile = profiling.analyze_raw([FIXTURES / "client.xml", FIXTURES / "server.xml"])
        self.module = self.profile["packets"][0]["sourceModules"][0]["moduleID"]
        self.snapshot = {"status": "captured", "snapshotId": "snapshot", "path": str(self.root), "artifacts": [], "configurations": []}
        self.add_configuration("configuration", "")

    def add_configuration(self, folder, extension):
        directory = self.root / folder
        metadata = directory / "DataProcessors/Тест/Forms/Форма.xml"
        metadata.parent.mkdir(parents=True)
        metadata.write_text('<MetaDataObject><Form uuid="' + self.module["objectID"] + '"/></MetaDataObject>', encoding="utf-8")
        source = metadata.with_suffix("") / "Ext/Form/Module.bsl"
        source.parent.mkdir(parents=True)
        source.write_bytes(("// строка\r\n" * 5000).encode("utf-8-sig"))
        index = directory / "ConfigDumpInfo.xml"
        index.write_text('<ConfigDumpInfo xmlns="http://v8.1c.ru/8.3/xcf/dumpinfo" format="Hierarchical"><ConfigVersions>'
                         '<Metadata name="DataProcessor.Тест.Form.Форма" id="' + self.module["objectID"] + '" configVersion="' + self.module["version"] + '"/>'
                         '<Metadata name="DataProcessor.Тест.Form.Форма.Form" id="' + self.module["objectID"] + '.0" configVersion="different-property-version"/>'
                         '</ConfigVersions></ConfigDumpInfo>', encoding="utf-8")
        self.snapshot["artifacts"].extend({"path": path.relative_to(self.root).as_posix(), "sha256": digest(path)}
                                          for path in (index, metadata, source))
        self.snapshot["configurations"].append({"path": folder, "extensionName": extension})
        return index, metadata, source

    def test_fresh_dump_produces_bindings_using_object_version_and_correct_form_path(self):
        manifest = build_manifest(self.snapshot, [self.profile])
        self.assertEqual(2, len(manifest["modules"]))
        self.assertEqual([], manifest["unmatched"])
        prior_coverage = copy.deepcopy(self.profile["coverage"])
        prior_packets = [(p["raw"], p["sha256"]) for p in self.profile["packets"]]
        self.profile["complete"] = False  # partial capture must remain partial after mapping
        apply_manifest(self.profile, self.snapshot, manifest, "required")
        self.assertTrue(self.profile["sourceAnalysis"]["requirementSatisfied"])
        self.assertFalse(self.profile["complete"])
        self.assertEqual(prior_coverage, self.profile["coverage"])
        self.assertEqual(prior_packets, [(p["raw"], p["sha256"]) for p in self.profile["packets"]])

    def test_old_profile_cannot_map_to_a_newer_dump_even_with_identical_paths(self):
        for packet in self.profile["packets"]:
            for item in packet["sourceModules"]:
                item["moduleID"]["version"] = "old-version"
        manifest = build_manifest(self.snapshot, [self.profile])
        self.assertEqual([], manifest["modules"])
        self.assertEqual(2, len(manifest["unmatched"]))

    def test_index_changes_are_rejected_before_any_bindings_are_written(self):
        path = self.root / "configuration/ConfigDumpInfo.xml"
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(WorkError, "SOURCE_CAPTURE_INDEX_CHANGED"):
            build_manifest(self.snapshot, [self.profile])

    def test_changed_module_cannot_inherit_the_old_native_version_from_an_unchanged_index(self):
        path = self.root / 'configuration/DataProcessors/Тест/Forms/Форма/Ext/Form/Module.bsl'
        path.write_text('// a different revision\n', encoding='utf-8')
        with self.assertRaisesRegex(WorkError, 'SOURCE_CAPTURE_MODULE_CHANGED_OR_UNSEALED'):
            build_manifest(self.snapshot, [self.profile])
        self.assertFalse((self.root / 'source-map.json').exists())

    def test_changed_metadata_cannot_redirect_binding_under_an_unchanged_index(self):
        path = self.root / 'configuration/DataProcessors/Тест/Forms/Форма.xml'
        path.write_bytes(path.read_bytes() + b'\n')
        with self.assertRaisesRegex(WorkError, 'SOURCE_CAPTURE_METADATA_CHANGED_OR_UNSEALED'):
            build_manifest(self.snapshot, [self.profile])

    def test_old_snapshot_without_module_hash_requires_recapture_instead_of_rehashing_current_bytes(self):
        self.snapshot['artifacts'] = [item for item in self.snapshot['artifacts'] if not item['path'].endswith('.bsl')]
        with self.assertRaisesRegex(WorkError, 'SOURCE_CAPTURE_MODULE_CHANGED_OR_UNSEALED'):
            build_manifest(self.snapshot, [self.profile])

    def test_same_identity_in_base_and_extension_is_ambiguous_without_extension_evidence(self):
        self.add_configuration("extension-sources/test", "Расширение")
        manifest = build_manifest(self.snapshot, [self.profile])
        self.assertEqual([], manifest["modules"])
        self.assertEqual("ambiguous-exported-module", manifest["unmatched"][0]["reason"])
        for packet in self.profile["packets"]:
            for item in packet["sourceModules"]:
                item["moduleID"]["extensionName"] = "Расширение"
        manifest = build_manifest(self.snapshot, [self.profile])
        self.assertEqual(2, len(manifest["modules"]))
        self.assertTrue(all(m["configurationExtension"] == "Расширение" for m in manifest["modules"]))

    def test_wrong_metadata_uuid_or_unsupported_property_never_guesses_a_file(self):
        metadata = self.root / "configuration/DataProcessors/Тест/Forms/Форма.xml"
        metadata.write_text('<MetaDataObject><Form uuid="other"/></MetaDataObject>', encoding="utf-8")
        with self.assertRaisesRegex(WorkError, 'SOURCE_CAPTURE_METADATA_CHANGED_OR_UNSEALED'):
            build_manifest(self.snapshot, [self.profile])
        # Independently exercise UUID validation on a sealed, inconsistent
        # export; a matching file hash must not make the wrong UUID acceptable.
        for artifact in self.snapshot['artifacts']:
            if artifact['path'] == metadata.relative_to(self.root).as_posix():
                artifact['sha256'] = digest(metadata)
        self.assertEqual([], build_manifest(self.snapshot, [self.profile])["modules"])
        self.profile["packets"][0]["sourceModules"][0]["moduleID"]["propertyID"] = "unknown"
        self.assertEqual("unsupported-module-property", build_manifest(self.snapshot, [self.profile])["unmatched"][0]["reason"])

    def test_changed_original_packet_is_not_remapped(self):
        path = self.root / "packet.xml"
        path.write_bytes((FIXTURES / "client.xml").read_bytes())
        profile = profiling.analyze_raw([path])
        manifest = build_manifest(self.snapshot, [profile])
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(WorkError, "SOURCE_PROFILE_PACKET_CHANGED"):
            apply_manifest(profile, self.snapshot, manifest, "required")


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL выгрузка базы ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = {"kind": "file", "path": str(self.root / "target")}
        self.context = {"jobId": "job", "operations": ["measure"], "target": {"infoBase": self.base, "workspace": str(self.root)}}
        self.lease = Lease(self.root / "coordinator", [self.base], {"jobId": "job"})
        self.lease.__enter__()
        self.addCleanup(self.lease.__exit__, None, None, None)
        self.context["accessLease"] = self.lease.proof()
        self.context_path = self.root / "context.json"
        write_json(self.context_path, self.context)

    def fake_step(self, snapshot, operation, extension=None):
        self.operations.append((operation, extension))
        log = snapshot.root / (str(len(self.operations)) + ".log")
        log.write_text("Расширение\n" if operation == "list-extensions" else "", encoding="utf-8-sig")
        key = hashlib.sha256((extension or "").encode("utf-8")).hexdigest()
        if operation in ("dump-database", "dump-extension"):
            binary = snapshot.root / ("extensions/" + key + ".cfe" if extension else "database.cf")
            binary.parent.mkdir(exist_ok=True)
            binary.write_bytes(b"captured")
        if operation == "create-scratch":
            scratch = snapshot.root / "private/scratch"
            scratch.mkdir()
            (scratch / "1Cv8.1CD").write_bytes(b"scratch")
            write_json(snapshot.root / "private/scratch-owner.json", {"snapshotId": snapshot.identifier, "jobId": "job", "path": str(scratch)})
        if operation == "dump-sources":
            folder = snapshot.root / ("extension-sources/" + key if extension else "configuration")
            folder.mkdir(parents=True)
            for name in ("ConfigDumpInfo.xml", "Configuration.xml"):
                (folder / name).write_bytes(b"<xml/>")
            metadata = folder / 'CommonModules/Тест.xml'
            metadata.parent.mkdir()
            metadata.write_bytes(b'<xml/>')
            module = folder / 'CommonModules/Тест/Ext/Module.bsl'
            module.parent.mkdir(parents=True)
            module.write_bytes(b'')
        return {"status": "completed", "log": str(log), "cleanupErrors": []}

    def test_captures_base_and_extensions_under_inherited_lease_and_cleans_only_scratch(self):
        snapshot = Snapshot(self.context_path, Deadline("source-capture", 10))
        self.operations = []
        with patch.object(Snapshot, "step", lambda s, op, ext=None: self.fake_step(s, op, ext)):
            result = snapshot.run()
        self.assertEqual("captured", result["status"], result)
        self.assertEqual([("list-extensions", None), ("dump-database", None), ("dump-extension", "Расширение"),
                          ("list-extensions", None), ("create-scratch", None), ("load-snapshot", None),
                          ("dump-sources", None), ("load-snapshot", "Расширение"), ("dump-sources", "Расширение")], self.operations)
        self.assertFalse((snapshot.root / "private/scratch").exists())
        self.assertTrue((snapshot.root / "database.cf").is_file())
        record = read_json(self.root / "coordinator/tickets" / (self.lease.record["ticket"] + ".json"))
        self.assertEqual("running", record["status"])
        self.assertEqual({}, record["participants"])
        self.assertEqual([], result["cleanupErrors"])
        sealed = {item['path']: item['sha256'] for item in result['artifacts']}
        for configuration in result['configurations']:
            for relative in ('CommonModules/Тест.xml', 'CommonModules/Тест/Ext/Module.bsl'):
                path = configuration['path'] + '/' + relative
                self.assertEqual(digest(snapshot.root / path), sealed[path])

    def test_missing_or_invalid_lease_cannot_launch_a_capture(self):
        self.context["accessLease"]["token"] = "wrong"
        write_json(self.context_path, self.context)
        with patch.object(Snapshot, "step") as launch:
            result = Snapshot(self.context_path, Deadline("source-capture", 10)).run()
            launch.assert_not_called()
        self.assertEqual("failed", result["status"])
        self.assertIn("INHERITANCE_INVALID", result["error"])

    def test_failed_capture_keeps_artifacts_and_primary_error(self):
        snapshot = Snapshot(self.context_path, Deadline("source-capture", 10))
        self.operations = []
        def step(s, op, ext=None):
            if op == "create-scratch":
                raise WorkError("fixture creation failed")
            return self.fake_step(s, op, ext)
        with patch.object(Snapshot, "step", step):
            result = snapshot.run()
        self.assertEqual("failed", result["status"])
        self.assertEqual("fixture creation failed", result["error"])
        self.assertTrue((snapshot.root / "database.cf").is_file())

        self.assertEqual("released", self.lease.release(), "a proven capture failure does not imply surviving native work")

    def test_capture_cleanup_keeps_its_participant_until_scratch_cleanup_finishes(self):
        snapshot = Snapshot(self.context_path, Deadline("source-capture", 10))
        self.operations = []
        cleanup = snapshot.cleanup_scratch
        def inspect_cleanup():
            record = read_json(self.root / "coordinator/tickets" / (self.lease.record["ticket"] + ".json"))
            self.assertEqual(1, len(record["participants"]))
            cleanup()
        with patch.object(Snapshot, "step", lambda s, op, ext=None: self.fake_step(s, op, ext)), patch.object(snapshot, "cleanup_scratch", inspect_cleanup):
            self.assertEqual("captured", snapshot.run()["status"])
        self.assertEqual("released", self.lease.release())

    def test_capture_unproven_native_cleanup_keeps_parent_reserved(self):
        snapshot = Snapshot(self.context_path, Deadline("source-capture", 10))
        def fail(s, operation, extension=None):
            s.result["cleanupErrors"].append("owned process still unproven")
            raise WorkError("capture failed")
        with patch.object(Snapshot, "step", fail):
            self.assertEqual("failed", snapshot.run()["status"])
        self.assertEqual("needs-attention", self.lease.release())

    def test_extension_log_is_utf8_and_diagnostics_are_not_treated_as_names(self):
        log = self.root / "extensions.log"
        log.write_text("VAExtension\nРасширение_Тест\n", encoding="utf-8-sig")
        self.assertEqual(["VAExtension", "Расширение_Тест"], extension_names(log))
        log.write_text("Access denied\n", encoding="utf-8")
        with self.assertRaisesRegex(WorkError, "LIST_UNRECOGNIZED"):
            extension_names(log)

    def test_failed_launcher_leaves_a_terminal_phase_record(self):
        snapshot = Snapshot(self.context_path, Deadline("source-capture", 10))
        with patch("itl_remote.source_capture.OwnedProcess", side_effect=OSError("cannot launch")):
            result = snapshot.run()
        self.assertEqual("failed", result["status"])
        self.assertEqual("failed", result["steps"][0]["status"])
        self.assertEqual("SOURCE_CAPTURE_LAUNCH_FAILED", result["steps"][0]["error"])

    def test_repository_offline_startup_notice_is_retained_without_becoming_an_extension(self):
        log = self.root / 'extensions.log'
        log.write_text('Connection to the configuration repository is not established\nVAExtension\n', encoding='utf-8-sig')
        diagnostics = []
        self.assertEqual(['VAExtension'], extension_names(log, diagnostics=diagnostics))
        self.assertEqual('SOURCE_CAPTURE_REPOSITORY_OFFLINE', diagnostics[0]['code'])
        self.assertEqual(str(log), diagnostics[0]['log'])
        log.write_text('Connection to the configuration repository is not established\nAccess denied\n', encoding='utf-8')
        with self.assertRaisesRegex(WorkError, 'LIST_UNRECOGNIZED'):
            extension_names(log, diagnostics=diagnostics)

    def test_scratch_without_completed_ownership_is_retained_and_reported(self):
        snapshot = Snapshot(self.context_path, Deadline("source-capture", 10))
        scratch = snapshot.root / "private/scratch"
        scratch.mkdir()
        snapshot.cleanup_scratch()
        self.assertTrue(scratch.exists())
        self.assertEqual(["SOURCE_CAPTURE_SCRATCH_WITHOUT_COMPLETION_MARKER"], snapshot.result["cleanupWarnings"])


if __name__ == "__main__":
    unittest.main()
