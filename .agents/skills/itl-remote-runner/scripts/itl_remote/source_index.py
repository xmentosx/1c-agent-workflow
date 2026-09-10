"""Bind captured native modules to a fresh hierarchical Designer source export."""
from __future__ import annotations

from pathlib import Path
import base64
import hashlib
import xml.etree.ElementTree as ET

from .common import WorkError, beneath, digest, write_json
from .source_mapping import module_key, coverage, Selection

# Platform property UUIDs, also documented by go1cover's metareader constants:
# https://pkg.go.dev/github.com/asosnoviy/go1cover/pkg/metareader#pkg-constants
# These are protocol identifiers, not version-dependent object UUIDs.
PROPERTIES = {
    "32e087ab-1491-49b6-aba7-43571b41ac2b": "Form/Module.bsl",
    "d5963243-262e-4398-b4d7-fb16d06484f6": "Module.bsl",
    "078a6af8-d22c-4248-9c33-7e90075a3d2c": "CommandModule.bsl",
    "a637f77f-3840-441d-a1c3-699c8c5cb7e0": "ObjectModule.bsl",
    "d1b64a2c-8078-4982-8190-8f81aefda192": "ManagerModule.bsl",
    "0c8cad23-bf8c-468e-b49e-12f1927c048b": "ManagerModule.bsl",
    "9f36fd70-4bf4-47f6-b235-935f73aab43f": "RecordSetModule.bsl",
    "3e58c91f-9aaa-4f42-8999-4baf33907b75": "ValueManagerModule.bsl",
    "d22e852a-cf8a-4f77-8ccb-3548e7792bea": "ManagedApplicationModule.bsl",
    "9b7bbbae-9771-46f2-9e4d-2489e0ffc702": "SessionModule.bsl",
    "a4a9c1e2-1e54-4c7f-af06-4ca341198fac": "ExternalConnectionModule.bsl",
    "a78d9ce3-4e0c-48d5-9863-ae7342eedf94": "OrdinaryApplicationModule.bsl",
}
PLURALS = {name: name + "s" for name in (
    "CommonModule", "CommonForm", "CommonCommand", "Form", "Command", "Document", "Catalog",
    "Report", "DataProcessor", "InformationRegister", "AccumulationRegister", "CalculationRegister",
    "AccountingRegister", "Constant", "ExchangePlan", "Task", "HTTPService", "WebService", "SettingsStorage",
    "ExternalDataSource", "Table", "Cube", "Recalculation")}
PLURALS.update(BusinessProcess="BusinessProcesses", ChartOfAccounts="ChartsOfAccounts",
               ChartOfCalculationTypes="ChartsOfCalculationTypes", ChartOfCharacteristicTypes="ChartsOfCharacteristicTypes")


def metadata_path(name):
    parts = name.split(".")
    if len(parts) % 2 or any(not value.isidentifier() for value in parts):
        return None
    if parts[0] == "Configuration":
        return Path("Configuration.xml") if len(parts) == 2 else None
    path = Path()
    for kind, value in zip(parts[::2], parts[1::2]):
        if kind not in PLURALS:
            return None
        path = path / PLURALS[kind] / value
    return path.with_suffix(".xml")


def build_manifest(snapshot, profiles, selection=None, *, save=True, allow_changed_files=False):
    if snapshot.get("status") != "captured":
        raise WorkError("SOURCE_CAPTURE_NOT_COMPLETE")
    root = Path(snapshot["path"]).resolve()
    # The producer only accepts the exact indexes retained by its capture.
    hashes = {item["path"]: item["sha256"] for item in snapshot["artifacts"]}
    indexes = []
    for configuration in snapshot["configurations"]:
        directory = beneath(root, configuration["path"])
        index_path = directory / "ConfigDumpInfo.xml"
        index_relative = index_path.relative_to(root).as_posix()
        index_bytes = (base64.b64decode(configuration['indexXmlBase64'], validate=True)
                       if 'indexXmlBase64' in configuration else index_path.read_bytes())
        if hashlib.sha256(index_bytes).hexdigest() != hashes.get(index_relative):
            raise WorkError("SOURCE_CAPTURE_INDEX_CHANGED")
        tree = ET.fromstring(index_bytes)
        if tree.get("format") != "Hierarchical":
            raise WorkError("SOURCE_CAPTURE_DUMP_FORMAT_UNSUPPORTED")
        objects = {}
        for element in tree.iter("{http://v8.1c.ru/8.3/xcf/dumpinfo}Metadata"):
            objects.setdefault(element.get("id"), []).append(element.attrib)
        indexes.append((configuration, directory, index_relative, objects))
    manifest = {"schemaVersion": 2, "snapshotId": snapshot["snapshotId"], "modules": [], "unmatched": []}
    requested = {}
    selected = Selection(selection)
    for profile in profiles:
        for packet in profile["packets"]:
            for item in packet["sourceModules"]:
                module = item["moduleID"]
                if selected.includes(module):
                    requested[(module_key(module), module.get("version"))] = module
    for module in requested.values():
        candidates = []
        changed = None
        property_path = PROPERTIES.get(module.get("propertyID"))
        if property_path and module.get("version"):
            for configuration, directory, index_relative, objects in indexes:
                if module.get("extensionName") and module["extensionName"] != configuration["extensionName"]:
                    continue
                for obj in objects.get(module.get("objectID"), []):
                    if obj.get("configVersion") != module["version"]:
                        continue
                    relative = metadata_path(obj.get("name", ""))
                    if relative is None:
                        continue
                    metadata = beneath(directory, relative)
                    if not metadata.is_file():
                        continue
                    metadata_relative = metadata.relative_to(root).as_posix()
                    if digest(metadata) != hashes.get(metadata_relative):
                        if not allow_changed_files:
                            raise WorkError("SOURCE_CAPTURE_METADATA_CHANGED_OR_UNSEALED")
                        changed = 'checkout-metadata-changed'
                        continue
                    metadata_root = ET.parse(metadata).getroot()
                    if not any(child.get("uuid") == module["objectID"] for child in metadata_root):
                        continue
                    parent = Path() if relative.name == "Configuration.xml" else relative.with_suffix("")
                    source = beneath(directory, parent / "Ext" / property_path)
                    if not source.is_file():
                        continue
                    source_relative = source.relative_to(root).as_posix()
                    source_sha = hashes.get(source_relative)
                    if digest(source) != source_sha:
                        if not allow_changed_files:
                            raise WorkError("SOURCE_CAPTURE_MODULE_CHANGED_OR_UNSEALED")
                        changed = 'checkout-module-changed'
                        continue
                    candidates.append({"moduleID": module, "path": source.relative_to(root).as_posix(),
                                       "sha256": source_sha, "origin": 'checkout-native-export' if snapshot.get('source') == 'checkout-native-export' else 'database-snapshot',
                                       "snapshotId": snapshot["snapshotId"], "metadataName": obj["name"],
                                       "configurationExtension": configuration["extensionName"],
                                       "dumpIndex": index_relative, "dumpIndexSha256": hashes[index_relative]})
        if len(candidates) == 1:
            manifest["modules"].append(candidates[0])
        else:
            manifest["unmatched"].append({"moduleID": module, "reason": "ambiguous-exported-module" if candidates else
                                          changed or ("unsupported-module-property" if not property_path else "exact-exported-module-not-found")})
    if save:
        write_json(root / "source-map.json", manifest)
    return manifest


def apply_manifest(profile, snapshot, manifest, policy, selection=None):
    from .profiling import analyze_raw
    for packet in profile["packets"]:
        try:
            actual = digest(packet["raw"])
        except OSError as error:
            raise WorkError("SOURCE_PROFILE_PACKET_UNAVAILABLE") from error
        if actual != packet["sha256"]:
            raise WorkError("SOURCE_PROFILE_PACKET_CHANGED")
    packets = {}
    for session in {p["sessionId"] for p in profile["packets"]}:
        paths = list({p["raw"] for p in profile["packets"] if p["sessionId"] == session})
        mapped = analyze_raw(paths, session=session, source_map=manifest,
                             source_policy=policy, source_map_root=snapshot["path"], source_modules=selection)
        packets.update({(p["sessionId"], p["target"]["id"]): p for p in mapped["packets"]})
    for packet in profile["packets"]:
        match = packets[(packet["sessionId"], packet["target"]["id"])]
        packet.update(sourceModules=match["sourceModules"], top=match["top"])
    profile["sourceAnalysis"] = coverage(profile["packets"], policy, selection)
    return profile
