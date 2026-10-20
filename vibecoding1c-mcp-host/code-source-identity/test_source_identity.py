import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from types import SimpleNamespace

import source_identity as identity
import patch


class SourceIdentity(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="source identity ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.xml = self.root / "Configuration.xml"
        self.xml.write_bytes(b'<MetaDataObject><Configuration><Properties><Version>5.0.1</Version></Properties></Configuration></MetaDataObject>')
        self.inventory = {"structural": {}, "xsd": {str(self.xml): hashlib.sha256(self.xml.read_bytes()).hexdigest()}}
        self.components = {"source": "c" * 64}
        self.captured = identity.capture(self.components, self.inventory, "code-same", self.root, "host/pm5corp")
        self.entry = {"generation_id": "g1", "published_at": "2026-10-21T00:00:00Z", "fingerprint": self.components, identity.KEY: self.captured}
        self.manifest = self.root / "manifest.json"
        self.save()

    def save(self):
        self.manifest.write_text(json.dumps({"generations": {"g1": self.entry}}), encoding="utf-8")

    def test_active_bytes_not_current_mount_and_no_promotion_of_failed_build(self):
        before = identity.describe(self.manifest, "g1", "code-same")
        self.xml.write_text("<new-current-mount/>", encoding="utf-8")
        self.assertEqual(identity.describe(self.manifest, "g1", "code-same"), before)
        self.assertEqual(before["indexedSource"]["configurationVersion"], "5.0.1")
        self.entry["published_at"] = None
        self.save()
        self.assertNotIn("stamp", identity.describe(self.manifest, "g1", "code-same"))

    def test_only_a_configuration_version_in_the_hashed_inventory_is_accepted(self):
        self.inventory["xsd"][str(self.xml)] = "d" * 64
        changed = identity.capture(self.components, self.inventory, "code-same", self.root, "host/pm5corp")
        self.assertEqual(changed["indexedSource"]["configurationVersion"], "")
        self.assertIsNone(identity.capture(self.components, self.inventory, "code-same", self.root, ""))
        self.assertIsNone(identity.capture(self.components, self.inventory, "code-same", self.root, "host/secret?token=value"))

    def test_old_or_inconsistent_manifest_is_unknown_and_pinned_generation_wins(self):
        self.assertNotIn("stamp", identity.describe(self.manifest, "g2", "code-same"))
        self.entry["fingerprint"] = {"source": "d" * 64}
        self.save()
        self.assertNotIn("stamp", identity.describe(self.manifest, "g1", "code-same"))
        self.entry["fingerprint"] = self.components
        del self.entry[identity.KEY]
        self.save()
        self.assertNotIn("stamp", identity.describe(self.manifest, "g1", "code-same"))

    def test_same_version_different_bytes_get_different_revision_stamps(self):
        before = identity.describe(self.manifest, "g1", "code-same")
        self.entry = copy.deepcopy(self.entry)
        self.entry["fingerprint"]["source"] = "d" * 64
        self.entry[identity.KEY]["indexedSource"]["revision"] = "d" * 64
        self.save()
        after = identity.describe(self.manifest, "g1", "code-same")
        self.assertNotEqual(before["stamp"], after["stamp"])
        self.assertEqual(before["indexedSource"]["configurationVersion"], after["indexedSource"]["configurationVersion"])

    def test_actual_layer_is_disclosed_before_existing_budget_and_tools_are_unchanged(self):
        envelope = {"status": "success", "data": {"name": "fixture"}}
        request = SimpleNamespace(tool="get_module_structure", include_provenance=True)
        annotated = identity.enrich(envelope, request, self.manifest, "g1", "code-same")
        self.assertEqual(annotated["sourceIdentity"]["layer"], "index")
        mixed = identity.enrich(envelope, request, self.manifest, "g1", "code-same", live_xml=True)
        self.assertEqual(mixed["sourceIdentity"]["layer"], "index-with-live-enrichment")
        self.assertNotIn("sourceIdentity", envelope)
        self.assertIs(identity.enrich(envelope, SimpleNamespace(tool="get_module_structure"), self.manifest, "g1", "code-same"), envelope)
        self.assertIs(identity.enrich(envelope, SimpleNamespace(tool="reindex"), self.manifest, "g1", "code-same"), envelope)
        self.assertLess(len(json.dumps(annotated["sourceIdentity"]).encode()), 2048)

    def test_unqualified_vendor_is_rejected_before_any_write(self):
        target = self.root / "src"
        (target / "index_generation").mkdir(parents=True)
        for name in patch.QUALIFIED:
            (target / name).write_text("# unexpected vendor\n", encoding="utf-8")
        before = {p: p.read_bytes() for p in target.rglob("*.py")}
        with self.assertRaisesRegex(ValueError, "Unqualified"):
            patch.patch(target)
        self.assertEqual(before, {p: p.read_bytes() for p in target.rglob("*.py")})

    @unittest.skipUnless(os.environ.get("ITL_NATIVE_CODE_FIXTURE"), "Exact native source fixture is not supplied")
    def test_exact_native_patch_parses_and_retains_the_native_budget_boundary(self):
        target = self.root / "native"
        shutil.copytree(os.environ["ITL_NATIVE_CODE_FIXTURE"], target)
        patch.patch(target)
        main = (target / "main.py").read_text(encoding="utf-8")
        self.assertIn("envelope = itl_source_identity.enrich", main)
        boundary = main[main.index("def _apply_structural_budget("):main.index("def _indexing_in_progress_response(")]
        self.assertLess(boundary.index("itl_source_identity.enrich"), boundary.index("return _apply_budget"))
        self.assertIn('entry["itl_source_identity"] = dict(identity)', (target / "index_generation/manifest.py").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
