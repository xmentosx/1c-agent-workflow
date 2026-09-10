"""Resolve requested measured modules from pinned bindings, then capture gaps."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re

from .common import WorkError, read_json, write_json
from .source_mapping import Selection, SourceResolver, module_key


def identity(module):
    return module_key(module), module.get("version")


class Bindings:
    def __init__(self, root, profiles, selection, deadline):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=False)
        self.deadline = deadline
        selected = Selection(selection)
        self.requested = {identity(item["moduleID"]): item["moduleID"]
                          for profile in profiles for packet in profile["packets"]
                          for item in packet["sourceModules"] if selected.includes(item["moduleID"])}
        self.manifest = {"schemaVersion": 2, "modules": []}
        self.evidence = {"reusedModules": 0, "references": [], "diagnostics": []}

    def add(self, manifest, root, reference, *, replace=False):
        resolver = SourceResolver(manifest, root=root)
        for module in self.requested.values():
            self.deadline.remaining()
            resolved = resolver.resolve(module)
            if not resolved["sourceMatched"]:
                if resolved["sourceIssue"] not in ("module-not-found", "module-version-mismatch"):
                    self.evidence["diagnostics"].append({"moduleID": module, "issue": resolved["sourceIssue"], "reference": reference})
                continue
            source = Path(resolved["source"])
            raw = source.read_bytes()
            sha = hashlib.sha256(raw).hexdigest()
            if sha != resolved["sourceSha256"]:
                raise WorkError("SOURCE_REUSE_FILE_CHANGED")
            # Keep original bytes inside this run so later source removal and
            # edits in another checkout cannot invalidate the finished report.
            copied = self.root / (sha + ".bsl")
            if not copied.exists():
                copied.write_bytes(raw)
            elif copied.read_bytes() != raw:
                raise WorkError("SOURCE_ANALYSIS_COPY_CHANGED")
            key = identity(module)
            entries = self.manifest["modules"]
            if replace:
                entries[:] = [entry for entry in entries if identity(entry["moduleID"]) != key]
            if any(identity(entry["moduleID"]) == key and entry["sha256"] == sha for entry in entries):
                continue
            entries.append({"moduleID": module, "path": copied.name, "sha256": sha,
                            "origin": resolved.get("origin", "verified-source-binding"),
                            "snapshotId": resolved.get("snapshotId"), "bindingManifest": reference})

    def reuse(self, references, workspace):
        if not isinstance(references, list):
            self.evidence["diagnostics"].append("SOURCE_REUSE_REFERENCES_INVALID")
            return
        for reference in references:
            self.deadline.remaining()
            try:
                if (not isinstance(reference, dict) or not isinstance(reference.get("path"), str) or
                        not reference["path"] or not isinstance(reference.get("sha256"), str) or
                        not re.fullmatch("[0-9a-fA-F]{64}", reference["sha256"])):
                    raise WorkError("SOURCE_REUSE_REFERENCE_INVALID")
                path = Path(workspace) / reference["path"]
                raw = path.read_bytes()
                sha = hashlib.sha256(raw).hexdigest()
                if sha != reference["sha256"].lower():
                    raise WorkError("SOURCE_REUSE_MANIFEST_CHANGED")
                manifest = json.loads(raw.decode("utf-8-sig"))
                binding = sha + ".json"
                (self.root / binding).write_bytes(raw)
                self.add(manifest, path.parent, binding)
                self.evidence["references"].append({"path": str(path.resolve()), "sha256": sha})
            except Exception as error:
                if str(error) == "CANCELLED" or str(error).startswith("PHASE_"):
                    raise
                self.evidence["diagnostics"].append(str(error))
        resolver = SourceResolver(self.manifest, root=self.root)
        self.evidence["reusedModules"] = sum(resolver.resolve(module)["sourceMatched"] for module in self.requested.values())

    def save(self):
        path = self.root / "source-map.json"
        write_json(path, self.manifest)
        return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    def reuse_checkout_exports(self, workspace):
        from .source_index import build_manifest
        workspace = Path(workspace).resolve()
        for path in sorted((workspace / '.agent-1c/source-exports').glob('*.json')):
            self.deadline.remaining()
            try:
                raw = path.read_bytes()
                catalog = json.loads(raw.decode('utf-8-sig'))
                if (catalog.get('schemaVersion') != 1 or catalog.get('producer') != 'itl-designer-export' or
                        Path(catalog.get('workspace', '')).resolve() != workspace or
                        not isinstance(catalog.get('configurations'), list) or len(catalog['configurations']) != 1):
                    raise WorkError('SOURCE_EXPORT_CATALOG_INVALID')
                extension = catalog['configurations'][0]['extensionName']
                # ExtensionName and extId are different native fields. Match
                # the declared extension name and preserve opaque extId values
                # in each binding; never interpret them as extension names.
                modules = [module for module in self.requested.values()
                           if module.get('extensionName', '') == extension]
                if not modules:
                    continue
                manifest = build_manifest({**catalog, 'path': str(workspace)},
                    [{'packets': [{'sourceModules': [{'moduleID': module} for module in modules]}]}],
                    save=False, allow_changed_files=True)
                reference = hashlib.sha256(raw).hexdigest() + '-export.json'
                (self.root / reference).write_bytes(raw)
                self.add(manifest, workspace, reference)
                self.evidence['diagnostics'].extend(manifest['unmatched'])
                self.evidence['references'].append({'path': str(path), 'sha256': hashlib.sha256(raw).hexdigest(),
                                                    'producer': 'itl-designer-export'})
            except Exception as error:
                if str(error) == 'CANCELLED' or str(error).startswith('PHASE_'):
                    raise
                self.evidence['diagnostics'].append(str(error))


def resolve_sources(context_path, profiles, profile_paths, policy, selection, deadline, result, *, before_capture=None):
    from .source_capture import Snapshot
    from .source_index import build_manifest, apply_manifest
    context_path = Path(context_path)
    context = read_json(context_path)
    resolution = {"captureAttempted": False, "selection": selection, "reusedModules": 0}
    result["sourceResolution"] = resolution

    def apply(bindings):
        result["sourceManifest"] = bindings.save()
        for profile, path in zip(profiles, profile_paths):
            deadline.remaining()
            apply_manifest(profile, {"path": str(bindings.root)}, bindings.manifest, policy, selection)
            write_json(path, profile)
        return all(profile["sourceAnalysis"]["status"] == "complete" for profile in profiles)

    stage = "analysis"
    failed = False
    try:
        bindings = Bindings(context_path.parent / "source-analysis", profiles, selection, deadline)
        references = (context["target"].get("sourceCapture") or {}).get("manifests", [])
        bindings.reuse(references, context["target"]["workspace"])
        bindings.reuse_checkout_exports(context['target']['workspace'])
        resolution.update(bindings.evidence)
        complete = apply(bindings)
        resolution["reusedModules"] = len({identity(item["moduleID"])
            for profile in profiles for packet in profile["packets"] for item in packet["sourceModules"]
            if item["sourceMatched"] and item["matchedLines"] == item["lines"]})
        missing = {identity(item["moduleID"]): item["moduleID"]
                   for profile in profiles for packet in profile["packets"] for item in packet["sourceModules"]
                   if identity(item["moduleID"]) in bindings.requested and
                   (not item["sourceMatched"] or item["matchedLines"] != item["lines"])}
        if missing:
            stage = "capture"
            if before_capture is not None:
                resolution["quiescence"] = before_capture(deadline)
                deadline.remaining()
            resolution["captureAttempted"] = True
            snapshot = Snapshot(context_path, deadline).run()
            result["sourceSnapshot"] = snapshot
            result["cleanupErrors"].extend(snapshot["cleanupErrors"])
            if snapshot.get("error") == "CANCELLED":
                raise WorkError("CANCELLED")
            if snapshot["status"] != "captured":
                raise WorkError(snapshot.get("error", "unknown"))
            stage = "analysis"
            manifest = build_manifest(snapshot, profiles, list(missing.values()))
            # A fresh authoritative binding can resolve an old cache conflict.
            # Modules absent from the fresh export keep their verified old bind.
            manifest_path = Path(snapshot["path"]) / "source-map.json"
            raw = manifest_path.read_bytes()
            binding = hashlib.sha256(raw).hexdigest() + ".json"
            (bindings.root / binding).write_bytes(raw)
            bindings.add(manifest, snapshot["path"], binding, replace=True)
            complete = apply(bindings)
        if not complete:
            result["limitations"].append("SOURCE_ANALYSIS_INCOMPLETE")
    except Exception as error:
        if str(error) == "CANCELLED" or str(error).startswith("SOURCE_PROFILE_PACKET_"):
            raise
        failed = True
        result["limitations"].append(("SOURCE_CAPTURE_FAILED: " if stage == "capture" else "SOURCE_ANALYSIS_FAILED: ") + str(error))
    if policy == "required" and (failed or any(not p["sourceAnalysis"]["requirementSatisfied"] for p in profiles)):
        raise WorkError("SOURCE_ANALYSIS_REQUIREMENT_UNSATISFIED")
