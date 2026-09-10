"""Public evidence for the 1C session and module versions that actually ran."""
from __future__ import annotations

import json
from pathlib import Path

from .common import WorkError, beneath, digest, read_json, write_json
from .source_mapping import module_key


def _reference(run, path):
    run = Path(run).resolve()
    path = Path(path).resolve()
    try:
        relative = path.relative_to(run)
    except ValueError as error:
        raise WorkError("LOADED_STATE_ARTIFACT_OUTSIDE_RUN") from error
    checked = beneath(run, relative)
    if not checked.is_file():
        raise WorkError("LOADED_STATE_ARTIFACT_MISSING")
    return {"path": relative.as_posix(), "sha256": digest(checked)}


def _public_runtime_proof(run, job_id):
    path = Path(run) / "runtime-proof.json"
    proof = read_json(path)
    if proof.get("jobId") != job_id:
        raise WorkError("LOADED_STATE_FOREIGN_RUNTIME_PROOF")
    fields = ("clientPid", "infoBaseAlias", "seanceId", "infoBaseInstanceID", "targetIds",
              "targetTypes", "requiredTypes", "sessionNumber", "observedAt")
    return {key: proof[key] for key in fields if key in proof}, _reference(run, path)


def _session_observation(run, job_id, proof):
    path = Path(run) / "session-observation.json"
    if not path.is_file():
        return None, None
    value = read_json(path)
    if (value.get("jobId") != job_id or value.get("clientPid") != proof.get("clientPid") or
            value.get("sessionNumber") != proof.get("sessionNumber")):
        raise WorkError("LOADED_STATE_FOREIGN_SESSION_OBSERVATION")
    fields = ("clientPid", "clientStartedAt", "sessionNumber")
    return {key: value[key] for key in fields if key in value}, _reference(run, path)


def _source_binding(run, module, policy):
    if policy == "none":
        return {"matched": False, "issue": "not-requested"}
    if not module.get("sourceMatched"):
        return {"matched": False, "issue": module.get("sourceIssue", "source-unavailable")}
    source = module.get("source")
    sha = module.get("sourceSha256")
    if not isinstance(source, str) or not source or not isinstance(sha, str) or len(sha) != 64:
        raise WorkError("LOADED_STATE_SOURCE_BINDING_INVALID")
    reference = _reference(run, source)
    if reference["sha256"] != sha.lower():
        raise WorkError("LOADED_STATE_SOURCE_BINDING_CHANGED")
    value = {"matched": True, **reference}
    for key in ("origin", "snapshotId"):
        if module.get(key) is not None:
            value[key] = module[key]
    return value


def _source_snapshot(run, snapshot):
    if snapshot.get("status") != "captured" or not snapshot.get("snapshotId"):
        raise WorkError("LOADED_STATE_SOURCE_SNAPSHOT_INVALID")
    root = Path(snapshot.get("path", "")).resolve()
    artifacts = snapshot.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise WorkError("LOADED_STATE_SOURCE_SNAPSHOT_INVALID")
    retained = []
    for item in artifacts:
        if (not isinstance(item, dict) or not isinstance(item.get("path"), str) or
                not isinstance(item.get("sha256"), str) or len(item["sha256"]) != 64):
            raise WorkError("LOADED_STATE_SOURCE_SNAPSHOT_INVALID")
        path = beneath(root, item["path"])
        if not path.is_file() or digest(path) != item["sha256"].lower():
            raise WorkError("LOADED_STATE_SOURCE_SNAPSHOT_CHANGED")
        retained.append({"path": item["path"].replace("\\", "/"), "sha256": item["sha256"].lower()})
    public = {"schemaVersion": 1, "snapshotId": snapshot["snapshotId"],
              "status": "captured", "configurations": snapshot.get("configurations", []),
              "artifacts": retained}
    path = Path(run) / "loaded-source-snapshot.json"
    write_json(path, public)
    return _reference(run, path)


def write_evidence(run, result, profile_paths, profile_references):
    """Write a hash-bound snapshot; declarations never become runtime proof."""
    run = Path(run).resolve()
    profiles = result.get("profiles", [])
    if not profiles:
        return {"status": "unavailable", "reason": "runtime-profile-not-collected",
                "runtimeObserved": False, "wholeConfigurationSourceProven": False,
                "dataStateProven": False, "evidence": None}
    if len(profiles) != len(profile_paths) or len(profiles) != len(profile_references):
        raise WorkError("LOADED_STATE_PROFILE_INVENTORY_CHANGED")

    proof, proof_reference = _public_runtime_proof(run, result["jobId"])
    observation, observation_reference = _session_observation(run, result["jobId"], proof)
    target_ids = set(proof.get("targetIds", []))
    target_types = proof.get("targetTypes") or {}
    policy = result.get("sourceAnalysisPolicy", "none")
    records = []
    configurations = set()
    unique_modules = {}
    source_states = {}
    source_hashes = {}
    source_issues = set()
    for profile, profile_path, profile_reference in zip(profiles, profile_paths, profile_references):
        actual_profile_reference = _reference(run, profile_path)
        if actual_profile_reference != {"path": profile_reference["path"], "sha256": profile_reference["sha256"]}:
            raise WorkError("LOADED_STATE_PROFILE_REFERENCE_CHANGED")
        for packet in profile.get("packets", []):
            target = packet.get("target", {})
            if (target.get("id") not in target_ids or target.get("seanceId") != proof.get("seanceId") or
                    target.get("infoBaseAlias") != proof.get("infoBaseAlias") or
                    target.get("infoBaseInstanceID") != proof.get("infoBaseInstanceID") or
                    (target_types and target_types.get(target.get("id")) != target.get("targetType"))):
                raise WorkError("LOADED_STATE_FOREIGN_PROFILE_PACKET")
            version = target.get("configVersion")
            if isinstance(version, str) and version:
                configurations.add(version)
            modules = []
            for module in packet.get("sourceModules", []):
                identity = module.get("moduleID")
                key = module_key(identity)
                module_version = identity.get("version") if isinstance(identity, dict) else None
                if not key or not isinstance(module_version, str) or not module_version:
                    raise WorkError("LOADED_STATE_MODULE_IDENTITY_REQUIRED")
                versioned_key = key + "|" + module_version
                serialized = json.dumps(identity, sort_keys=True, ensure_ascii=False)
                if versioned_key in unique_modules and unique_modules[versioned_key] != serialized:
                    raise WorkError("LOADED_STATE_MODULE_IDENTITY_AMBIGUOUS")
                unique_modules[versioned_key] = serialized
                binding = _source_binding(run, module, policy)
                requested = policy != "none" and binding.get("issue") != "outside-requested-scope"
                if requested:
                    fully_bound = binding["matched"] and module.get("lines", 0) == module.get("matchedLines", -1)
                    source_states.setdefault(versioned_key, []).append(fully_bound)
                if binding["matched"]:
                    source_hashes.setdefault(versioned_key, set()).add(binding["sha256"])
                    if len(source_hashes[versioned_key]) != 1:
                        raise WorkError("LOADED_STATE_SOURCE_BINDING_AMBIGUOUS")
                elif requested:
                    source_issues.add(binding["issue"])
                modules.append({"moduleID": identity, "lines": module.get("lines", 0),
                                "matchedLines": module.get("matchedLines", 0), "source": binding})
            records.append({"profile": actual_profile_reference, "sessionId": packet.get("sessionId"),
                            "target": {key: target.get(key) for key in
                                       ("id", "targetType", "seanceId", "infoBaseAlias",
                                        "infoBaseInstanceID", "configVersion")},
                            "measureSha256": packet.get("measureSha256"), "modules": modules})

    iterations = {item.get("iteration"): item.get("status") for item in result.get("iterations", [])}
    verified_profiles = sum(iterations.get(item.get("iteration")) == "verified" for item in profile_references)
    source_bound_count = sum(bool(values) and all(values) for values in source_states.values())
    source_requested_count = len(source_states)
    analysis_complete = bool(profiles) and all(
        profile.get("sourceAnalysis", {}).get("status") == "complete" for profile in profiles)
    binding_status = "not-requested" if policy == "none" else (
        "complete" if analysis_complete and source_requested_count and
        source_bound_count == source_requested_count else "partial")
    coverage_complete = all(profile.get("complete") is True for profile in profiles)
    configuration_consistent = len(configurations) == 1
    status = ("source-bound" if coverage_complete and configuration_consistent and binding_status == "complete" else
              "observed" if coverage_complete and configuration_consistent and policy == "none" else "partial")
    evidence = {"schemaVersion": 1, "jobId": result["jobId"], "status": status,
                "runtimeObserved": True, "scope": "executed-profile-modules",
                "runtimeProof": proof_reference, "runtime": proof,
                "sessionObservation": observation_reference, "session": observation,
                "configurationVersions": sorted(configurations),
                "configurationVersionConsistent": configuration_consistent,
                "profileCoverageComplete": coverage_complete,
                "profileCount": len(profiles), "verifiedProfileCount": verified_profiles,
                "moduleCount": len(unique_modules), "sourceRequestedModuleCount": source_requested_count,
                "sourceBoundModuleCount": source_bound_count,
                "sourceBindingStatus": binding_status, "sourceIssues": sorted(source_issues),
                "wholeConfigurationSourceProven": False, "dataStateProven": False,
                "declarations": {"sourceIdentity": result.get("sourceIdentity"),
                                 "dataIdentity": result.get("dataIdentity"),
                                 "environmentIdentity": result.get("environmentIdentity")},
                "packets": records}
    if result.get("sourceManifest"):
        evidence["sourceManifest"] = _reference(run, result["sourceManifest"]["path"])
    if result.get("sourceSnapshot") and result["sourceSnapshot"].get("status") == "captured":
        try:
            evidence["postMeasurementSourceSnapshot"] = _source_snapshot(run, result["sourceSnapshot"])
        except WorkError as error:
            if policy == "required":
                raise
            evidence["postMeasurementSourceSnapshotIssue"] = str(error)
    path = run / "loaded-state-evidence.json"
    write_json(path, evidence)
    return {key: evidence[key] for key in ("status", "runtimeObserved", "scope",
            "configurationVersions", "configurationVersionConsistent", "profileCoverageComplete",
            "profileCount", "verifiedProfileCount", "moduleCount", "sourceRequestedModuleCount",
            "sourceBoundModuleCount",
            "sourceBindingStatus", "wholeConfigurationSourceProven", "dataStateProven")} | {
                "evidence": _reference(run, path)}
