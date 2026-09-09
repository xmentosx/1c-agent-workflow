"""Private stdio lease host for native callers; never a recovery/unlock endpoint.

The parent owns these pipes exclusively. Only the admitted message contains a
lease token. EOF/cancellation after admission retains needs-attention because
the host cannot infer that the parent's database work or restoration stopped.
"""
from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time

from .access import Lease, public
from .common import WorkError


def serve(input_stream, output_stream):
    def emit(value):
        output_stream.write(json.dumps(value, ensure_ascii=True, allow_nan=False) + "\n")
        output_stream.flush()

    lease = None
    admitted = threading.Event()
    interrupted = threading.Event()
    messages = queue.Queue()
    try:
        if sys.version_info < (3, 11):
            raise WorkError("INFOBASE_ACCESS_PYTHON311_REQUIRED")
        request = json.loads(input_stream.readline())
        fields = {"schemaVersion", "coordinator", "bases", "owner", "timeout", "inherited", "purpose"}
        owner_fields = {"project", "operation", "threadId", "parentPid", "requestId"}
        if (not isinstance(request, dict) or request.get("schemaVersion") != 1 or set(request) - fields or
                not isinstance(request.get("owner"), dict) or set(request["owner"]) - owner_fields or
                not isinstance(request.get("bases"), list) or
                any(not isinstance(base, dict) for base in request["bases"]) or
                not isinstance(request.get("coordinator"), str) or not request["coordinator"].strip()):
            raise WorkError("INFOBASE_ACCESS_HOST_REQUEST_INVALID")

        def receive():
            try:
                while True:
                    line = input_stream.readline()
                    if not line:
                        raise WorkError("INFOBASE_ACCESS_PARENT_DISCONNECTED")
                    value = json.loads(line)
                    if not isinstance(value, dict):
                        raise WorkError("INFOBASE_ACCESS_HOST_CONTROL_INVALID")
                    if value == {"event": "cancel"}:
                        interrupted.set()
                        messages.put(WorkError("INFOBASE_ACCESS_PARENT_CANCELLED"))
                        return
                    if (set(value) != {"event", "cleanupErrors"} or value["event"] != "release" or
                            not isinstance(value["cleanupErrors"], list) or
                            any(not isinstance(error, str) or not error for error in value["cleanupErrors"])):
                        raise WorkError("INFOBASE_ACCESS_HOST_CONTROL_INVALID")
                    if not admitted.is_set():
                        raise WorkError("INFOBASE_ACCESS_RELEASE_BEFORE_ADMISSION")
                    messages.put(value)
                    return
            except BaseException as error:
                interrupted.set()
                messages.put(error)

        threading.Thread(target=receive, daemon=True).start()
        last_progress = -float("inf")

        def progress(value):
            nonlocal last_progress
            if time.monotonic() - last_progress >= 1:
                emit({"event": "waiting", **value})
                last_progress = time.monotonic()

        lease = Lease(request["coordinator"], request["bases"], {**request["owner"], "parentPid": os.getppid()},
                      timeout=request.get("timeout", 3600), cancelled=interrupted.is_set,
                      progress=progress, inherited=request.get("inherited"), purpose=request.get("purpose", "operation"))
        lease.__enter__()
        admitted.set()
        emit({"event": "admitted", "proof": lease.proof(), "owner": public(lease.record)})
        value = messages.get()
        if isinstance(value, BaseException):
            raise value
        lease.release(cleanup_errors=value["cleanupErrors"])
        emit({"event": "released", "status": "needs-attention" if value["cleanupErrors"] else "released",
              "inherited": bool(lease.inherited)})
    except BaseException as error:
        if lease is not None:
            lease.release(cleanup_errors=["native parent did not confirm operation cleanup"])
        # No request/proof serialization in diagnostics: the input pipe is private.
        emit({"event": "error", "error": str(error) if isinstance(error, WorkError) else type(error).__name__})
        return 1
    return 0


if __name__ == "__main__":
    # A daemon waiting on a buffered stdin lock can abort Python finalization
    # when admission fails before the parent closes its pipe. Raw FileIO has no
    # buffered-reader lock, and json.loads accepts the UTF-8 bytes directly.
    raise SystemExit(serve(sys.stdin.buffer.raw, sys.stdout))
