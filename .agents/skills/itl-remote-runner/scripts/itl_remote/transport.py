"""Content-addressed transfer over SSH stdin or a configured exchange directory."""
from __future__ import annotations

import base64
import json
from pathlib import Path
import re
import shutil
import sys

from .common import FileLock, WorkError, beneath, capture, digest, read_json, stamp, write_json
from .jobs import status, submit, validate_package

CHUNK = 512 * 1024


def private_result(relative):
    path = Path(relative)
    return path.name.casefold() == "context.json" or "private" in {part.casefold() for part in path.parts}


def public_result_path(root, relative):
    path = beneath(root, relative)
    if private_result(relative) or private_result(path.relative_to(root.resolve())):
        raise WorkError("PRIVATE_OR_INVALID_RESULT")
    return path


def blob_path(spool, sha):
    if not re.fullmatch("[a-f0-9]{64}", sha):
        raise WorkError("INVALID_CONTENT_HASH")
    return Path(spool) / "blobs" / sha


def endpoint(spool, message):
    if message.get("operation") in ("recovery-plan", "recover", "recovery-cancel"):
        from . import recovery_job
        if message["operation"] == "recovery-plan":
            return recovery_job.create_plan(spool, message["id"])
        handler = recovery_job.enqueue if message["operation"] == "recover" else recovery_job.cancel
        return handler(spool, message["id"], message["planId"])
    spool = Path(spool).resolve()
    operation = message["operation"]
    if operation == "probe":
        from .bootstrap import inspect
        return inspect(spool)
    if operation == "status":
        return status(spool, message["id"])
    if operation == "cancel":
        from .jobs import cancel
        return cancel(spool, message["id"])
    if operation == "agent-request":
        from .agents import control, queue_followup
        if message["action"] == "followup":
            return queue_followup(spool, message["id"], message.get("payload", {}))
        return control(spool, message["id"], message["action"], message.get("payload", {}))
    if operation == "missing":
        missing = []
        for entry in message["files"]:
            blob = blob_path(spool, entry["sha256"])
            if not blob.is_file() or blob.stat().st_size != entry["bytes"] or digest(blob) != entry["sha256"]:
                missing.append(entry["sha256"])
        return {"missing": missing}
    if operation == "put":
        blob = blob_path(spool, message["sha256"])
        blob.parent.mkdir(parents=True, exist_ok=True)
        chunk = base64.b64decode(message["data"], validate=True)
        if len(chunk) > CHUNK or message["offset"] < 0:
            raise WorkError("INVALID_CHUNK")
        with FileLock(blob.with_suffix(".lock")):
            partial = blob.with_suffix(".partial")
            if message["offset"] == 0:
                partial.write_bytes(chunk)
            else:
                if not partial.exists() or partial.stat().st_size != message["offset"]:
                    raise WorkError("TRANSFER_OFFSET_MISMATCH")
                with partial.open("ab") as stream:
                    stream.write(chunk)
            if message.get("final"):
                if partial.stat().st_size != message["bytes"] or digest(partial) != message["sha256"]:
                    raise WorkError("TRANSFER_HASH_MISMATCH")
                partial.replace(blob)
        return {"received": message["offset"] + len(chunk)}
    if operation == "commit":
        import tempfile
        spool.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="incoming-", dir=spool) as temp:
            package = Path(temp)
            write_json(package / "request.json", message["request"])
            write_json(package / "scenario.json", message["scenario"])
            # Recreate the exact canonical JSON serialization used by pack().
            for relative, entry in message["request"]["files"].items():
                source = blob_path(spool, entry["sha256"])
                destination = beneath(package / "input", relative)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
            return submit(package, spool)
    if operation == "results":
        from .jobs import job_id
        root = spool / "runs" / job_id(message["id"])
        if not root.is_dir() or (not message.get("allowPartial", False) and not (root / "result.json").is_file()):
            raise WorkError("RESULT_NOT_READY")
        files = []
        for path in sorted(root.rglob("*")):
            if path.is_file() and not private_result(path.relative_to(root)):
                relative = path.relative_to(root).as_posix()
                public_result_path(root, relative)
                files.append({"path": relative, "bytes": path.stat().st_size, "sha256": digest(path)})
        result_available = any(entry["path"] == "result.json" for entry in files)
        if not result_available and not message.get("allowPartial", False):
            raise WorkError("RESULT_NOT_READY")
        observation_errors = []
        try:
            observed_job = status(spool, message["id"])
        except WorkError as error:
            if str(error) != "JOB_NOT_FOUND":
                raise
            observed_job = None
            observation_errors.append("JOB_NOT_FOUND")
        except (OSError, ValueError):
            # A damaged/unavailable state file must not hide the run's diagnostics.
            observed_job = None
            observation_errors.append("JOB_STATE_UNREADABLE")
        return {"files": files, "resultAvailable": result_available,
                "observedAt": stamp(), "observedJob": observed_job, "observationErrors": observation_errors}
    if operation == "read-result":
        from .jobs import job_id
        path = public_result_path(spool / "runs" / job_id(message["id"]), message["path"])
        count = message.get("bytes", CHUNK)
        if message["offset"] < 0 or type(count) is not int or not 0 < count <= CHUNK:
            raise WorkError("PRIVATE_OR_INVALID_RESULT")
        with path.open("rb") as stream:
            stream.seek(message["offset"])
            return {"data": base64.b64encode(stream.read(count)).decode("ascii")}
    raise WorkError("UNKNOWN_TRANSPORT_OPERATION")


class Connection:
    def __init__(self, profile):
        self.profile = profile

    def call(self, message):
        if self.profile["transport"] == "exchange":
            return endpoint(self.profile["spool"], message)
        if self.profile["transport"] != "ssh":
            raise WorkError("UNKNOWN_TRANSPORT")
        config = self.profile["ssh"]
        host = config["host"]
        if not host or host.startswith("-") or any(c in host for c in "\r\n\0"):
            raise WorkError("INVALID_SSH_HOST")
        # Paths and user data travel as JSON, never as a remote shell fragment.
        parameters = base64.b64encode(json.dumps({"python": config["python"], "runtime": config["runtime"],
                                                "spool": config["spool"]}, ensure_ascii=True).encode("utf-8")).decode("ascii")
        bootstrap = (
            "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; "
            "$utf8=[Text.UTF8Encoding]::new($false); [Console]::InputEncoding=$utf8; [Console]::OutputEncoding=$utf8; $OutputEncoding=$utf8; "
            "$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + parameters + "'))|ConvertFrom-Json; "
            "$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'; "
            "[Console]::In.ReadToEnd() | & $p.python -u $p.runtime rpc --spool $p.spool; exit $LASTEXITCODE"
        )
        encoded = base64.b64encode(bootstrap.encode("utf-16-le")).decode("ascii")
        command = [config.get("executable", "ssh"), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"]
        if config.get("port"):
            command += ["-p", str(int(config["port"]))]
        command += [host, "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]
        response = capture(command, input_bytes=json.dumps(message, ensure_ascii=True).encode("utf-8"), timeout=120)
        data = json.loads(response.decode("utf-8-sig"))
        if "error" in data:
            raise WorkError(data["error"])
        return data

    def send(self, package):
        request, scenario = validate_package(package)
        missing = set(self.call({"operation": "missing", "files": list(request["files"].values())})["missing"])
        for relative, entry in request["files"].items():
            if entry["sha256"] not in missing:
                continue
            with beneath(Path(package) / "input", relative).open("rb") as stream:
                offset = 0
                while True:
                    chunk = stream.read(CHUNK)
                    final = offset + len(chunk) == entry["bytes"]
                    self.call({"operation": "put", **entry, "offset": offset, "final": final,
                               "data": base64.b64encode(chunk).decode("ascii")})
                    offset += len(chunk)
                    if final:
                        break
            missing.remove(entry["sha256"])
        return self.call({"operation": "commit", "request": request, "scenario": scenario})

    def collect(self, identifier, destination, *, allow_partial=False):
        destination = Path(destination)
        if destination.exists():
            raise WorkError("RESULT_DESTINATION_EXISTS")
        if self.profile["transport"] == "exchange" and destination.resolve().is_relative_to(Path(self.profile["spool"]).resolve()):
            raise WorkError("RESULT_DESTINATION_IN_SPOOL")
        response = self.call({"operation": "results", "id": identifier, "allowPartial": allow_partial})
        inventory = response["files"]
        # Older completed-result endpoints only return files. They cannot serve a
        # partial collection, but their existing completed-result route still works.
        result_available = response.get("resultAvailable", any(entry["path"] == "result.json" for entry in inventory))
        if not result_available and not allow_partial:
            raise WorkError("RESULT_NOT_READY")
        destination.mkdir(parents=True)
        for entry in inventory:
            path = beneath(destination, entry["path"])
            path.parent.mkdir(parents=True, exist_ok=True)
            offset = 0
            with path.open("wb") as stream:
                while offset < entry["bytes"]:
                    chunk = base64.b64decode(self.call({"operation": "read-result", "id": identifier,
                                                       "path": entry["path"], "offset": offset,
                                                       "bytes": min(CHUNK, entry["bytes"] - offset)})["data"], validate=True)
                    if not chunk or offset + len(chunk) > entry["bytes"]:
                        raise WorkError("RESULT_TRANSFER_INCOMPLETE")
                    stream.write(chunk)
                    offset += len(chunk)
            if digest(path) != entry["sha256"]:
                raise WorkError("RESULT_HASH_MISMATCH")
        manifest = {"jobId": identifier, "files": inventory, "resultAvailable": result_available,
                    "collectionStatus": "result" if result_available else "partial",
                    "observedAt": response.get("observedAt"), "observedJob": response.get("observedJob"),
                    "observationErrors": response.get("observationErrors", [])}
        write_json(destination / "download-manifest.json", manifest)
        return read_json(destination / "result.json") if result_available else manifest
