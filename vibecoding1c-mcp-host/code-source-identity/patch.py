"""Patch only the qualified native metadata surfaces; never copy a full vendor file."""
import ast
import hashlib
from pathlib import Path
import sys

QUALIFIED = {
    "main.py": "7e70a0449ee8b8669c676f16b60fc6f4bd18383f4bf6d8e8e68d612870f2a028",
    "index_generation/manifest.py": "745c7612f4725dfd0e4e2b04704bcde7fe9132851dc50b797fce0bebac23641c",
}


def patch(root):
    root = Path(root)
    originals = {name: (root / name).read_bytes() for name in QUALIFIED}
    for name, expected in QUALIFIED.items():
        if hashlib.sha256(originals[name]).hexdigest() != expected:
            raise ValueError("Unqualified Code source: " + name)
    changes = {
        "main.py": [
            ("import index_generation\n", "import index_generation\nimport itl_source_identity\n"),
            ("    manifest = plugin_runtime.derived_state_manifest()\n", "    identity = itl_source_identity.capture(components, inventory or {}, PROJECT_ID, code_path, os.environ.get('ITL_SOURCE_KEY', ''))\n    if identity is not None:\n        components[itl_source_identity.KEY] = identity\n    manifest = plugin_runtime.derived_state_manifest()\n"),
            ('        data["sub_index_gates"] = gates\n', '        data["sub_index_gates"] = gates\n        data["sourceIdentity"] = itl_source_identity.describe(_GENERATION_LAYOUT.manifest_path, _read_target().generation_id, PROJECT_ID)\n'),
            ('    return _apply_budget(envelope, request)\n\n\ndef _indexing_in_progress_response', '    envelope = itl_source_identity.enrich(envelope, request, _GENERATION_LAYOUT.manifest_path, _read_target().generation_id, PROJECT_ID, rlm_xml_helpers.live_xml_enabled())\n    return _apply_budget(envelope, request)\n\n\ndef _indexing_in_progress_response'),
        ],
        "index_generation/manifest.py": [
            ('        self._payload["generations"][str(generation_id)] = entry\n', '        identity = (fingerprint or {}).get("itl_source_identity")\n        if identity is not None:\n            entry["itl_source_identity"] = dict(identity)\n        self._payload["generations"][str(generation_id)] = entry\n'),
        ],
    }
    prepared = {}
    for name, replacements in changes.items():
        text = originals[name].decode("utf-8")
        for before, after in replacements:
            if text.count(before) != 1:
                raise ValueError("Native insertion is not unique: " + name)
            text = text.replace(before, after)
        ast.parse(text)
        prepared[name] = text.encode("utf-8")
    for name, content in prepared.items():
        (root / name).write_bytes(content)
    (root / "itl_source_identity.py").write_bytes(Path(__file__).with_name("source_identity.py").read_bytes())


if __name__ == "__main__":
    patch(sys.argv[1])
