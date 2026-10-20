"""Optional facts in the native Code generation manifest; no state owner or I/O loop."""
import hashlib
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

KEY = "itl_source_identity"


def capture(components, inventory, project_id, code_root, source_key=""):
    """Called with the native inventory, before add_generation freezes its entry.

    An ordinary unchanged run does not rebuild or backfill an old generation.
    Configuration metadata is accepted only for the exact bytes already hashed
    by the native inventory. No Git HEAD/current mount is substituted for it.
    """
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}", source_key):
        return None
    revision = components.get("source", "")
    if not re.fullmatch(r"[a-f0-9]{64}", revision):
        return None
    version = ""
    try:
        xml_path = Path(code_root) / "Configuration.xml"
        raw = xml_path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if any(lane.get(str(xml_path)) == digest for lane in inventory.values()):
            root = ET.fromstring(raw)
            configuration = next((e for e in root.iter() if e.tag.rsplit("}", 1)[-1] == "Configuration"), None)
            if configuration is not None:
                properties = next((e for e in configuration if e.tag.rsplit("}", 1)[-1] == "Properties"), None)
                if properties is not None:
                    version = next((e.text or "" for e in properties if e.tag.rsplit("}", 1)[-1] == "Version"), "")
    except (OSError, ET.ParseError):
        pass  # Optional provenance never fails native ingestion.
    if len(version) > 128 or any(ord(c) < 32 for c in version):
        version = ""
    return {"contractVersion": 1, "sourceKey": source_key, "nativeProjectId": str(project_id),
            "indexedSource": {"revisionKind": "code-source-inventory-sha256", "revision": revision,
                              "configurationVersion": version, "extent": sorted(inventory),
                              "provenance": "active-index-manifest"}}


def describe(manifest_path, generation_id, project_id, layer="index"):
    """Use the caller's pinned bundle, never the latest published pointer."""
    unknown = {"contractVersion": 1, "nativeProjectId": str(project_id),
               "generation": generation_id, "layer": layer}
    try:
        document = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
        entry = document["generations"][generation_id]
        identity = entry[KEY]
        if (entry.get("generation_id") != generation_id or not entry.get("published_at")
                or identity.get("contractVersion") != 1 or identity.get("nativeProjectId") != str(project_id)
                or identity["indexedSource"]["revision"] != entry["fingerprint"]["source"]):
            return unknown
        # Copy only contract fields; paths, models and credentials stay native.
        indexed = identity["indexedSource"]
        safe_indexed = {k: indexed.get(k) for k in ("revisionKind", "revision", "configurationVersion", "extent", "provenance")}
        result = dict(unknown, sourceKey=identity["sourceKey"], indexedSource=safe_indexed)
        material = {k: v for k, v in result.items() if k != "layer"}
        result["stamp"] = hashlib.sha256(json.dumps(material, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
        return result
    except (OSError, ValueError, KeyError, TypeError):
        return unknown


def enrich(envelope, request, manifest_path, generation_id, project_id, live_xml=False):
    """Annotate two existing tools before their existing response budget runs."""
    if (getattr(request, "tool", None) not in ("get_module_structure", "search_function")
            or not getattr(request, "include_provenance", False)):
        return envelope
    data = envelope.get("data", envelope)
    layer = "index"
    if data.get("search_layer") in ("grep", "live_xml") or data.get("indexing_status") == "in_progress":
        layer = "live-source"
    if getattr(request, "tool", None) == "get_module_structure" and live_xml:
        # Live enrichment is useful but is not an indexed snapshot of those fields.
        layer = "index-with-live-enrichment"
    result = dict(envelope)
    full = describe(manifest_path, generation_id, project_id, layer)
    result["sourceIdentity"] = {k: full[k] for k in ("contractVersion", "generation", "layer", "stamp") if k in full}
    return result
