"""Stage verified user-local worker generations without replacing live code."""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

from . import VERSION
from .common import WorkError, beneath, digest, publish_path, read_json, stamp, write_json


RUNTIME_RELATIVE = ".agents/skills/itl-remote-runner/scripts/remote_work.py"
SUPERVISOR_RELATIVE = ".agents/skills/itl-remote-runner/scripts/worker_supervisor.py"
MAX_UPDATE_FILES = 5000
MAX_UPDATE_BYTES = 2 * 1024 * 1024 * 1024


def _version(value):
    try:
        parts = tuple(int(item) for item in str(value).split("."))
    except ValueError as error:
        raise WorkError("WORKER_UPDATE_VERSION_INVALID") from error
    if len(parts) != 3 or any(item < 0 for item in parts):
        raise WorkError("WORKER_UPDATE_VERSION_INVALID")
    return parts


def _manifest(archive):
    try:
        with zipfile.ZipFile(archive) as bundle:
            infos = bundle.infolist()
            if len(infos) > MAX_UPDATE_FILES or sum(info.file_size for info in infos) > MAX_UPDATE_BYTES:
                raise WorkError("WORKER_UPDATE_BUNDLE_LIMIT_EXCEEDED")
            names = [info.filename for info in infos]
            if len(names) != len(set(names)) or "bundle-manifest.json" not in names:
                raise WorkError("WORKER_UPDATE_MANIFEST_INVALID")
            value = json.loads(bundle.read("bundle-manifest.json").decode("utf-8-sig"))
    except (OSError, ValueError, zipfile.BadZipFile, KeyError) as error:
        raise WorkError("WORKER_UPDATE_BUNDLE_INVALID") from error
    files = value.get("files") if isinstance(value, dict) else None
    if value.get("schemaVersion") != 1 or not isinstance(files, dict):
        raise WorkError("WORKER_UPDATE_MANIFEST_INVALID")
    if set(names) != set(files) | {"bundle-manifest.json"}:
        raise WorkError("WORKER_UPDATE_INVENTORY_MISMATCH")
    if RUNTIME_RELATIVE not in files or SUPERVISOR_RELATIVE not in files:
        raise WorkError("WORKER_UPDATE_RUNTIME_MISSING")
    return value


def _extract(archive, destination, manifest):
    destination = Path(destination)
    staging = Path(tempfile.mkdtemp(prefix=".worker-update-", dir=destination.parent))
    try:
        with zipfile.ZipFile(archive) as bundle:
            for relative, entry in manifest["files"].items():
                if (not isinstance(relative, str) or not isinstance(entry, dict) or
                        type(entry.get("bytes")) is not int or entry["bytes"] < 0 or
                        not isinstance(entry.get("sha256"), str)):
                    raise WorkError("WORKER_UPDATE_MANIFEST_INVALID")
                info = bundle.getinfo(relative)
                if info.is_dir() or (info.external_attr >> 16) & 0o170000 == 0o120000:
                    raise WorkError("WORKER_UPDATE_ENTRY_INVALID")
                target = beneath(staging, relative)
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(info) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                if target.stat().st_size != entry["bytes"] or digest(target) != entry["sha256"]:
                    raise WorkError("WORKER_UPDATE_FILE_HASH_MISMATCH: " + relative)
        write_json(staging / "generation.json",
                   {"schemaVersion": 1, "version": manifest["version"],
                    "archiveSha256": digest(archive), "stagedAt": stamp()})
        publish_path(staging, destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def stage(spool, message, connection):
    spool = Path(spool).resolve()
    profile = read_json(spool / "profile.json")
    if profile.get("workerUpdatePolicy", "disabled") != "compatible":
        raise WorkError("WORKER_SELF_UPDATE_NOT_ALLOWED")
    from .transport import blob_path
    archive = blob_path(spool, message.get("sha256"))
    if (not archive.is_file() or archive.stat().st_size != message.get("bytes") or
            digest(archive) != message.get("sha256")):
        raise WorkError("WORKER_UPDATE_BLOB_INVALID")
    manifest = _manifest(archive)
    current, candidate = _version(VERSION), _version(manifest.get("version"))
    if candidate[0] != current[0]:
        raise WorkError("WORKER_UPDATE_MAJOR_INCOMPATIBLE")
    if candidate <= current:
        raise WorkError("WORKER_UPDATE_NOT_NEWER")
    sha = message["sha256"]
    generations = spool / "runtime" / "versions"
    generations.mkdir(parents=True, exist_ok=True)
    destination = generations / sha
    if not destination.exists():
        _extract(archive, destination, manifest)
    generation = read_json(destination / "generation.json")
    if generation.get("archiveSha256") != sha or generation.get("version") != manifest["version"]:
        raise WorkError("WORKER_UPDATE_GENERATION_INVALID")
    runtime = destination / RUNTIME_RELATIVE
    supervisor = destination / SUPERVISOR_RELATIVE
    completed = subprocess.run([sys.executable, "-B", "-X", "utf8", str(runtime), "version"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if completed.returncode != 0:
        raise WorkError("WORKER_UPDATE_SELF_TEST_FAILED")
    try:
        observed_version = json.loads(completed.stdout.decode("utf-8-sig")).get("version")
    except (ValueError, UnicodeError, AttributeError) as error:
        raise WorkError("WORKER_UPDATE_SELF_TEST_INVALID") from error
    if observed_version != manifest["version"]:
        raise WorkError("WORKER_UPDATE_VERSION_MISMATCH")
    pending = {"schemaVersion": 1, "version": manifest["version"], "archiveSha256": sha,
               "runtime": str(runtime), "supervisor": str(supervisor), "stagedAt": stamp()}
    pending_path = spool / "runtime" / "pending.json"
    if pending_path.exists():
        existing = read_json(pending_path)
        if (existing.get("archiveSha256"), existing.get("version")) != (sha, manifest["version"]):
            raise WorkError("WORKER_UPDATE_ALREADY_PENDING")
        pending = existing
    else:
        write_json(pending_path, pending)
    return {"status": "worker-update-staged", "version": manifest["version"],
            "archiveSha256": sha, "restart": "automatic-when-idle"}
