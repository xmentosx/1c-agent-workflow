"""Private stdio host which holds one execution guard for a caller process."""

from __future__ import annotations

import base64
import json
import sys

from .common import WorkError
from .execution_guard import ExecutionGuard, canonical_resources


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def read_request():
    line = sys.stdin.readline()
    if not line:
        raise WorkError("EXECUTION_GUARD_REQUEST_REQUIRED")
    try:
        request = json.loads(line)
    except json.JSONDecodeError as error:
        raise WorkError("EXECUTION_GUARD_REQUEST_INVALID") from error
    required = ("root", "bases", "operation", "executionId", "timeout")
    if request.get("schemaVersion") != 1 or any(name not in request for name in required):
        raise WorkError("EXECUTION_GUARD_REQUEST_INVALID")
    return request


def serve():
    request = read_request()
    resources = canonical_resources(request["bases"])
    inherited = request.get("inheritedContext")
    inherited_key = (base64.urlsafe_b64decode(request["inheritedContextKey"].encode("ascii"))
                     if inherited else None)

    def progress(record):
        if record.get("state") == "waiting":
            emit({"event": "waiting", "status": "waiting-for-base",
                  "executionId": record["executionId"], "resources": record["resources"],
                  "waitSeconds": record.get("waitSeconds", 0.0)})

    guard = ExecutionGuard(request["root"], resources, request["operation"],
                           execution_id=request["executionId"], timeout=float(request["timeout"]),
                           progress=progress, cancel_path=request.get("cancelPath"),
                           phase_deadline=request.get("phaseDeadline"),
                           inherited_context=inherited, context_key=inherited_key)
    entered = False
    terminal = False
    try:
        guard.__enter__()
        entered = True
        context = guard.context()
        emit({"event": "admitted", "status": "running", "executionId": guard.execution_id,
              "resources": guard.resources, "executionContext": context["encoded"],
              "executionContextKey": base64.urlsafe_b64encode(context["key"]).decode("ascii")})
        for line in sys.stdin:
            try:
                command = json.loads(line)
            except json.JSONDecodeError:
                emit({"event": "error", "status": "failed", "error": "EXECUTION_GUARD_COMMAND_INVALID"})
                continue
            action = command.get("action")
            if action == "release":
                result = command.get("result", "succeeded")
                guard.terminal(result, error=command.get("error"), artifacts=command.get("artifacts"))
                terminal = True
                emit({"event": "released", "status": result, "executionId": guard.execution_id})
                return 0
            if action == "validate":
                emit({"event": "validated", "status": "running", "executionId": guard.execution_id})
                continue
            emit({"event": "error", "status": "failed", "error": "EXECUTION_GUARD_COMMAND_INVALID"})
        return 0
    except (WorkError, ValueError, TypeError) as error:
        emit({"event": "error", "status": "failed", "error": str(error)})
        return 1
    finally:
        if entered and not terminal:
            if guard.inherited_context:
                guard.__exit__(WorkError, WorkError("EXECUTION_GUARD_PARENT_PIPE_CLOSED"), None)
            elif guard.handles:
                guard.terminal("interrupted", error="EXECUTION_GUARD_PARENT_PIPE_CLOSED")


if __name__ == "__main__":
    raise SystemExit(serve())
