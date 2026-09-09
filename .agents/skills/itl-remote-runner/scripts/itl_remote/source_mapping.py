"""Exact offline source bindings; source availability never changes raw coverage.

A binding is supplied by a source snapshot producer, not inferred from a checkout
name or a database address. Native extId is opaque and is not an extension name.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from .common import WorkError


def module_key(module):
    """Keep all native identity fields, including extension/context distinctions."""
    if not isinstance(module, dict):
        return None
    if module.get("objectID") or module.get("propertyID"):
        if not module.get("objectID") or not module.get("propertyID"):
            return None
        identity = {key: value for key, value in module.items() if key != "version"}
        # Defaults declared by the platform BSLModuleIdInternal model. Do not
        # normalize extId into extensionName or discard unfamiliar fields.
        for key, default in (("type", "ConfigModule"), ("URL", ""),
                             ("extensionName", ""), ("extId", "0")):
            if identity.get(key) is None:
                identity[key] = default
        return "native:" + json.dumps(identity, sort_keys=True, ensure_ascii=True)
    if module.get("id"):
        return "legacy:" + str(module["id"])
    return None


class SourceResolver:
    def __init__(self, manifest=None, *, root=None, policy="optional"):
        if policy not in ("none", "optional", "required"):
            raise WorkError("INVALID_SOURCE_ANALYSIS_POLICY")
        self.policy = policy
        self.root = Path(root).resolve() if root is not None else Path.cwd()
        self.entries = {}
        self.provided = manifest is not None
        self.cache = {}
        if policy == "none" or manifest is None:
            return
        if not isinstance(manifest, dict):
            raise WorkError("SOURCE_MAP_INVALID")
        if "schemaVersion" in manifest:
            if manifest["schemaVersion"] != 2 or not isinstance(manifest.get("modules"), list):
                raise WorkError("SOURCE_MAP_SCHEMA_UNSUPPORTED")
            entries = manifest["modules"]
        else:
            # Preserve the old explicit-id format, but never use its empty key
            # for native packets that have no id field.
            entries = [{**entry, "moduleID": {"id": name, "version": entry.get("moduleVersion")}}
                       for name, entry in manifest.items() if name and isinstance(entry, dict)]
        for entry in entries:
            if not isinstance(entry, dict) or not module_key(entry.get("moduleID")):
                raise WorkError("SOURCE_MAP_MODULE_ID_INVALID")
            self.entries.setdefault(module_key(entry["moduleID"]), []).append(entry)

    def resolve(self, module):
        result = {"sourceMatched": False}
        if self.policy == "none":
            return {**result, "sourceIssue": "not-requested"}
        key = module_key(module)
        if key is None:
            return {**result, "sourceIssue": "module-identity-missing"}
        if not module.get("version"):
            return {**result, "sourceIssue": "module-version-missing"}
        candidates = self.entries.get(key, [])
        if not candidates:
            return {**result, "sourceIssue": "module-not-found" if self.provided else "source-map-not-provided"}
        candidates = [entry for entry in candidates if entry["moduleID"].get("version") == module["version"]]
        if not candidates:
            return {**result, "sourceIssue": "module-version-mismatch"}
        # Repeated identical records are harmless. Distinct bindings for the
        # same identity/version must not be resolved by choosing the first one.
        candidates = list({json.dumps(entry, sort_keys=True): entry for entry in candidates}.values())
        if len(candidates) != 1:
            return {**result, "sourceIssue": "ambiguous-source-binding"}
        entry = candidates[0]
        if not isinstance(entry.get("path"), str) or not entry["path"] or not isinstance(entry.get("sha256"), str):
            return {**result, "sourceIssue": "source-binding-incomplete"}
        source = self.root / entry["path"]
        cache_key = (str(source), entry["sha256"])
        if cache_key not in self.cache:
            try:
                raw = source.read_bytes()
                if hashlib.sha256(raw).hexdigest() != entry["sha256"].lower():
                    checked = {**result, "sourceIssue": "source-hash-mismatch"}
                else:
                    lines = raw.decode("utf-8-sig").splitlines()
                    checked = {"sourceMatched": True, "source": str(source.resolve()),
                               "sourceSha256": entry["sha256"].lower(), "sourceLineCount": len(lines)}
            except FileNotFoundError:
                checked = {**result, "sourceIssue": "source-file-missing"}
            except UnicodeError:
                checked = {**result, "sourceIssue": "source-encoding-unsupported"}
            except OSError:
                checked = {**result, "sourceIssue": "source-file-unreadable"}
            self.cache[cache_key] = checked
        result = dict(self.cache[cache_key])
        for name in ("origin", "snapshotId"):
            if name in entry:
                result[name] = entry[name]
        return result

    def line(self, match, line_number):
        if match["sourceMatched"] and (not isinstance(line_number, (int, float)) or
                                       not 1 <= line_number <= match["sourceLineCount"] or
                                       int(line_number) != line_number):
            return {**match, "sourceMatched": False, "sourceIssue": "source-line-out-of-range"}
        return match


def coverage(packets, policy):
    modules = [module for packet in packets for module in packet["sourceModules"]]
    total_lines = sum(module["lines"] for module in modules)
    matched_lines = sum(module["matchedLines"] for module in modules)
    matched_modules = sum(bool(module["sourceMatched"]) for module in modules)
    complete = bool(modules) and matched_modules == len(modules) and matched_lines == total_lines
    return {"policy": policy, "status": "not-requested" if policy == "none" else
            "complete" if complete else "partial" if matched_modules else "unmatched",
            "requirementSatisfied": policy != "required" or complete,
            "modules": len(modules), "matchedModules": matched_modules,
            "lines": total_lines, "matchedLines": matched_lines}
