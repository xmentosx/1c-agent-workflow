"""Content-addressed transfer over SSH stdin or a configured exchange directory."""
from __future__ import annotations

import base64
import json
from pathlib import Path
import re
import shutil
import sys

from .common import FileLock, WorkError, beneath, capture, digest, read_json, write_json
from .jobs import collect, status, submit, validate_package

CHUNK = 512 * 1024


def blob_path(spool, sha):
    if not re.fullmatch("[a-f0-9]{64}", sha):
        raise WorkError("INVALID_CONTENT_HASH")
    return Path(spool) / "blobs" / sha


def endpoint(spool, message):
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
        if not (root / "result.json").exists():
            raise WorkError("RESULT_NOT_READY")
        files = []
        for path in sorted(root.rglob("*")):
            if path.is_file() and path.name != "context.json" and "private" not in path.relative_to(root).parts:
                relative = path.relative_to(root).as_posix()
                beneath(root, relative)
                files.append({"path": relative, "bytes": path.stat().st_size, "sha256": digest(path)})
        return {"files": files}
    if operation == "read-result":
        from .jobs import job_id
        path = beneath(spool / "runs" / job_id(message["id"]), message["path"])
        if path.name == "context.json" or "private" in Path(message["path"]).parts or message["offset"] < 0:
            raise WorkError("PRIVATE_OR_INVALID_RESULT")
        with path.open("rb") as stream:
            stream.seek(message["offset"])
            return {"data": base64.b64encode(stream.read(CHUNK)).decode("ascii")}
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

    def collect(self, identifier, destination):
        destination = Path(destination)
        if destination.exists():
            raise WorkError("RESULT_DESTINATION_EXISTS")
        inventory = self.call({"operation": "results", "id": identifier})["files"]
        destination.mkdir(parents=True)
        for entry in inventory:
            path = beneath(destination, entry["path"])
            path.parent.mkdir(parents=True, exist_ok=True)
            offset = 0
            with path.open("wb") as stream:
                while offset < entry["bytes"]:
                    chunk = base64.b64decode(self.call({"operation": "read-result", "id": identifier,
                                                       "path": entry["path"], "offset": offset})["data"], validate=True)
                    if not chunk or offset + len(chunk) > entry["bytes"]:
                        raise WorkError("RESULT_TRANSFER_INCOMPLETE")
                    stream.write(chunk)
                    offset += len(chunk)
            if digest(path) != entry["sha256"]:
                raise WorkError("RESULT_HASH_MISMATCH")
        write_json(destination / "download-manifest.json", {"jobId": identifier, "files": inventory})
        return read_json(destination / "result.json")
