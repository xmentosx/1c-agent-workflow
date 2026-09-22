"""Execution-scoped exact-infobase ownership.

The blocking authority in this module is an operating-system handle.  Files in
``execution-guards-v2`` are deliberately diagnostic: a missing, stale or broken
record never prevents admission when the corresponding OS handle is free.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import hmac
import json
import os
import platform
import re
import secrets
import tempfile
import threading
import time
import uuid
from pathlib import Path

from .common import WorkError, process_identity, stamp, write_json


PROTOCOL = "execution-guards-v2"
TERMINAL_STATES = {"succeeded", "failed", "interrupted", "cancelled"}
_LOCAL_HELD = set()
_LOCAL_HELD_LOCK = threading.Lock()


def _stable_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _digest(value):
    return hashlib.sha256(_stable_json(value).encode("utf-8")).hexdigest()


def _text(value, name):
    value = str(value or "").strip()
    if not value:
        raise WorkError("EXECUTION_GUARD_RESOURCE_INVALID: " + name)
    return value


def _canonical_file_path(value):
    path = Path(_text(value, "file path")).expanduser()
    try:
        path = path.resolve(strict=False)
    except OSError as error:
        raise WorkError("EXECUTION_GUARD_RESOURCE_INVALID: file path: " + str(error)) from error
    normalized = os.path.normcase(os.path.normpath(str(path)))
    return normalized.casefold() if os.name == "nt" else normalized


def _server_connection_parts(value):
    connection = _text(value, "server connection")
    fields = {}
    for match in re.finditer(r'(?i)(?:^|;)\s*(srvr|ref)\s*=\s*(?:"((?:[^"]|"")*)"|([^;]*))\s*(?=;|$)',
                             connection):
        raw = match.group(2) if match.group(2) is not None else match.group(3)
        fields[match.group(1).casefold()] = raw.replace('""', '"').strip()
    if fields.get("srvr") and fields.get("ref"):
        return fields["srvr"], fields["ref"]
    separators = [index for index in (connection.find("\\"), connection.find("/")) if index > 0]
    if not separators:
        raise WorkError("EXECUTION_GUARD_RESOURCE_INVALID: server connection")
    split = min(separators)
    return connection[:split], connection[split + 1:]


def canonical_base(base):
    """Return a credential-free canonical exact-base identity."""
    if not isinstance(base, dict):
        raise WorkError("EXECUTION_GUARD_RESOURCE_INVALID: base must be an object")
    kind = _text(base.get("kind"), "kind").casefold()
    if kind == "file":
        canonical = {"kind": "file", "path": _canonical_file_path(base.get("path"))}
    elif kind == "server":
        server = base.get("server") or base.get("cluster")
        infobase = base.get("infobase") or base.get("name") or base.get("path")
        if not server and base.get("path"):
            server, infobase = _server_connection_parts(base.get("path"))
        canonical = {"kind": "server", "server": _text(server, "server").casefold(),
                     "infobase": _text(infobase, "infobase").casefold()}
    elif kind in ("file-resource", "seed"):
        canonical = {"kind": kind, "path": _canonical_file_path(base.get("path"))}
    else:
        raise WorkError("EXECUTION_GUARD_RESOURCE_INVALID: unsupported kind=" + kind)
    return canonical


def resource_key(base):
    canonical = canonical_base(base)
    return "base-" + _digest({"protocol": PROTOCOL, "base": canonical})


def canonical_resources(bases):
    if not isinstance(bases, (list, tuple)) or not bases:
        raise WorkError("EXECUTION_GUARD_RESOURCES_REQUIRED")
    return sorted({resource_key(base) for base in bases})


def default_root():
    parent = Path(os.environ.get("PROGRAMDATA", tempfile.gettempdir())) / "ITL"
    return parent / PROTOCOL


def target_execution(target):
    """Resolve one execution host and the complete resource set before waiting."""
    if not isinstance(target, dict):
        raise WorkError("EXECUTION_GUARD_TARGET_INVALID")
    execution = target.get("execution", {})
    if execution is None:
        execution = {}
    if not isinstance(execution, dict):
        raise WorkError("EXECUTION_GUARD_TARGET_INVALID: execution")
    base = target.get("infoBase")
    if not isinstance(base, dict):
        base = {"kind": "file-resource", "path": _text(target.get("workspace"), "workspace")}
    bases = [base] + list(execution.get("additionalBases", []))
    hosts = execution.get("hosts")
    if hosts is not None:
        hosts = sorted({_text(item, "execution host").casefold() for item in hosts})
        if len(hosts) != 1:
            raise WorkError("EXECUTION_GUARD_MULTI_HOST_UNSUPPORTED")
        configured_host = hosts[0]
    else:
        configured_host = str(execution.get("host") or platform.node()).strip().casefold()
    if canonical_base(base)["kind"] == "server" and not configured_host:
        raise WorkError("EXECUTION_GUARD_HOST_REQUIRED")
    current_host = platform.node().casefold()
    if configured_host not in (current_host, "localhost", "."):
        raise WorkError("EXECUTION_GUARD_WRONG_HOST: configured=" + configured_host +
                        " current=" + current_host)
    timeout = execution.get("waitTimeoutSeconds", 3600)
    if not isinstance(timeout, (int, float)) or timeout <= 0 or timeout > 86400:
        raise WorkError("EXECUTION_GUARD_WAIT_TIMEOUT_INVALID")
    root = Path(execution.get("guardRoot") or os.environ.get("ITL_EXECUTION_GUARD_ROOT") or default_root())
    return {"protocol": PROTOCOL, "root": str(root), "bases": bases,
            "resources": canonical_resources(bases), "waitTimeoutSeconds": float(timeout),
            "executionHost": configured_host}


class _OsHandle:
    """A non-recursive wrapper over a Windows mutex or POSIX flock."""
    def __init__(self, root, key):
        self.root = Path(root)
        self.key = key
        self.handle = None
        self.owned = False
        self.stream = None

    @property
    def name(self):
        identity = _digest({"root": os.path.normcase(str(self.root.resolve())), "key": self.key})
        # The execution host, not a Windows logon session, owns the resource.
        # Global keeps desktop, SSH and service-launched workflow processes on
        # the same exact-base authority.
        return "Global\\ITL.ExecutionGuard.V2." + identity

    def try_acquire(self):
        if self.handle is not None or self.stream is not None:
            raise WorkError("EXECUTION_GUARD_HANDLE_REUSED")
        if os.name == "nt":
            self._open_windows()
            result = self.kernel.WaitForSingleObject(self.handle, 0)
            if result not in (0, 0x80):
                self.close()
                return False
            self.owned = True
            return True
        import fcntl
        path = self.root / "locks" / (hashlib.sha256(self.key.encode("utf-8")).hexdigest() + ".lock")
        path.parent.mkdir(parents=True, exist_ok=True)
        stream = path.open("a+b")
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            stream.close()
            return False
        self.stream = stream
        return True

    def _open_windows(self):
        import ctypes as c
        from ctypes import wintypes as w
        kernel = c.WinDLL("kernel32", use_last_error=True)
        kernel.CreateMutexW.argtypes = [c.c_void_p, w.BOOL, w.LPCWSTR]
        kernel.CreateMutexW.restype = w.HANDLE
        kernel.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
        kernel.WaitForSingleObject.restype = w.DWORD
        kernel.ReleaseMutex.argtypes = [w.HANDLE]
        kernel.ReleaseMutex.restype = w.BOOL
        kernel.CloseHandle.argtypes = [w.HANDLE]
        kernel.CloseHandle.restype = w.BOOL
        handle = kernel.CreateMutexW(None, False, self.name)
        if not handle:
            raise c.WinError(c.get_last_error())
        self.handle = handle
        self.kernel = kernel

    def close(self):
        if self.handle is not None:
            self.kernel.CloseHandle(self.handle)
            self.handle = None
            self.owned = False

    def release(self):
        if self.handle is not None:
            if self.owned:
                self.kernel.ReleaseMutex(self.handle)
            self.close()
        if self.stream is not None:
            import fcntl
            with contextlib.suppress(OSError):
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
            self.stream.close()
            self.stream = None


def _identity_matches(expected):
    if not isinstance(expected, dict) or expected.get("pid") != os.getpid():
        return False
    try:
        return process_identity(os.getpid()) == expected
    except WorkError:
        return False


def _process_matches(pid, expected):
    try:
        return process_identity(int(pid)) == expected
    except (WorkError, TypeError, ValueError, OSError):
        return False


def _sign(payload, key):
    return hmac.new(key, _stable_json(payload).encode("utf-8"), hashlib.sha256).hexdigest()


def encode_execution_context(context, key):
    payload = {name: context[name] for name in
               ("schemaVersion", "protocol", "executionId", "operation", "resources", "supervisor")}
    envelope = {"payload": payload, "signature": _sign(payload, key)}
    return base64.urlsafe_b64encode(_stable_json(envelope).encode("utf-8")).decode("ascii")


def decode_execution_context(encoded, key, required_resources):
    try:
        envelope = json.loads(base64.urlsafe_b64decode(encoded.encode("ascii")).decode("utf-8"))
        payload = envelope["payload"]
        signature = envelope["signature"]
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise WorkError("EXECUTION_CONTEXT_INVALID") from error
    if not hmac.compare_digest(signature, _sign(payload, key)):
        raise WorkError("EXECUTION_CONTEXT_SIGNATURE_INVALID")
    if (payload.get("schemaVersion") != 1 or payload.get("protocol") != PROTOCOL or
            not isinstance(payload.get("executionId"), str) or
            payload.get("resources") != sorted(set(payload.get("resources", []))) or
            not _process_matches(payload.get("supervisor", {}).get("pid"), payload.get("supervisor"))):
        raise WorkError("EXECUTION_CONTEXT_INVALID")
    requested = set(required_resources)
    if not requested <= set(payload["resources"]):
        raise WorkError("EXECUTION_CONTEXT_RESOURCE_EXPANSION_FORBIDDEN")
    return payload


class ExecutionGuard:
    """Acquire all exact resources for one bounded execution or inherit them."""
    def __init__(self, root, resources, operation, *, execution_id=None, timeout=3600,
                 cancelled=lambda: False, progress=lambda record: None, cancel_path=None,
                 phase_deadline=None, inherited_context=None, context_key=None,
                 heartbeat_seconds=1.0):
        self.root = Path(root).resolve()
        self.resources = sorted(set(resources))
        if not self.resources or any(not isinstance(item, str) or not item.startswith("base-")
                                     for item in self.resources):
            raise WorkError("EXECUTION_GUARD_RESOURCES_INVALID")
        self.operation = _text(operation, "operation")
        self.execution_id = execution_id or uuid.uuid4().hex
        self.timeout = float(timeout)
        if self.timeout <= 0 or self.timeout > 86400:
            raise WorkError("EXECUTION_GUARD_WAIT_TIMEOUT_INVALID")
        self.cancelled = cancelled
        self.progress = progress
        self.cancel_path = Path(cancel_path) if cancel_path else None
        try:
            self.phase_deadline = int(phase_deadline) if phase_deadline is not None else None
        except (TypeError, ValueError) as error:
            raise WorkError("EXECUTION_GUARD_PHASE_DEADLINE_INVALID") from error
        if self.phase_deadline is not None and self.phase_deadline <= 0:
            raise WorkError("EXECUTION_GUARD_PHASE_DEADLINE_INVALID")
        self.inherited_context = inherited_context
        self.context_key = context_key
        self.heartbeat_seconds = max(0.1, float(heartbeat_seconds))
        self.handles = []
        self.wait_started = None
        self.record = None
        self._state_lock = threading.Lock()
        self._heartbeat_stop = threading.Event()
        self._heartbeat_thread = None
        self._context_key = None

    @property
    def state_path(self):
        return self.root / "executions" / (self.execution_id + ".json")

    @property
    def waiter_path(self):
        return self.root / "waiters" / (self.execution_id + ".json")

    def _cancelled(self):
        return bool(self.cancelled()) or bool(self.cancel_path and self.cancel_path.exists())

    def _publish(self, state, **extra):
        with self._state_lock:
            now = stamp()
            if self.record is None:
                identity = process_identity(os.getpid())
                self.record = {"schemaVersion": 1, "protocol": PROTOCOL,
                               "executionId": self.execution_id, "operation": self.operation,
                               "resources": self.resources, "pid": os.getpid(),
                               "processStartTime": identity.get("creationId"),
                               "supervisor": identity, "startedAt": now}
            self.record.update(state=state, heartbeatAt=now, updatedAt=now,
                               phaseDeadline=self.phase_deadline, **extra)
            write_json(self.state_path, self.record)
            snapshot = dict(self.record)
        self.progress(snapshot)

    def _heartbeat(self):
        while not self._heartbeat_stop.wait(self.heartbeat_seconds):
            if self.record and self.record.get("state") in ("waiting", "running", "cancelling"):
                self._publish(self.record["state"])

    def _start_heartbeat(self):
        self._heartbeat_thread = threading.Thread(target=self._heartbeat, daemon=True,
                                                  name="itl-execution-guard-heartbeat")
        self._heartbeat_thread.start()

    def _queue_lock(self, deadline):
        handle = _OsHandle(self.root, "queue")
        while not handle.try_acquire():
            if self._cancelled():
                raise WorkError("EXECUTION_GUARD_CANCELLED")
            self._raise_if_wait_expired(deadline)
            time.sleep(0.02)
        return handle

    def _raise_if_wait_expired(self, wait_deadline):
        if self.phase_deadline is not None and time.monotonic_ns() >= self.phase_deadline:
            raise WorkError("EXECUTION_GUARD_PHASE_DEADLINE_EXPIRED")
        if time.monotonic() >= wait_deadline:
            raise WorkError("EXECUTION_GUARD_WAIT_TIMEOUT")

    def _write_waiter(self, queued_ns):
        identity = process_identity(os.getpid())
        write_json(self.waiter_path, {"schemaVersion": 1, "protocol": PROTOCOL,
                                     "executionId": self.execution_id, "operation": self.operation,
                                     "resources": self.resources, "queuedNs": queued_ns,
                                     "pid": os.getpid(), "processIdentity": identity})

    def _is_head(self, deadline):
        queue_lock = self._queue_lock(deadline)
        try:
            earlier = []
            directory = self.root / "waiters"
            if directory.is_dir():
                for path in directory.glob("*.json"):
                    if path == self.waiter_path:
                        continue
                    try:
                        value = json.loads(path.read_text(encoding="utf-8"))
                        valid = (value.get("protocol") == PROTOCOL and
                                 isinstance(value.get("resources"), list) and
                                 isinstance(value.get("queuedNs"), int) and
                                 _process_matches(value.get("pid"), value.get("processIdentity")))
                    except (OSError, ValueError, TypeError, json.JSONDecodeError):
                        valid = False
                        value = {}
                    if not valid:
                        with contextlib.suppress(OSError):
                            path.unlink()
                        continue
                    if set(value["resources"]).intersection(self.resources):
                        earlier.append((value["queuedNs"], value.get("executionId", "")))
            return not earlier or (self._queued_ns, self.execution_id) < min(earlier)
        finally:
            queue_lock.release()

    def _try_handles(self):
        if os.name == "nt" and len(self.resources) > 1:
            import ctypes as c
            from ctypes import wintypes as w
            if len(self.resources) > 64:
                raise WorkError("EXECUTION_GUARD_RESOURCE_LIMIT_EXCEEDED")
            opened = []
            try:
                for resource in self.resources:
                    handle = _OsHandle(self.root, resource)
                    handle._open_windows()
                    opened.append(handle)
                kernel = opened[0].kernel
                kernel.WaitForMultipleObjects.argtypes = [w.DWORD, c.POINTER(w.HANDLE),
                                                           w.BOOL, w.DWORD]
                kernel.WaitForMultipleObjects.restype = w.DWORD
                raw_handles = (w.HANDLE * len(opened))(
                    *(handle.handle for handle in opened))
                result = kernel.WaitForMultipleObjects(len(opened), raw_handles, True, 0)
                if result != 0 and not 0x80 <= result < 0x80 + len(opened):
                    return False
                for handle in opened:
                    handle.owned = True
                self.handles = opened
                opened = []
                return True
            finally:
                for handle in opened:
                    handle.close()
        acquired = []
        try:
            for resource in self.resources:
                handle = _OsHandle(self.root, resource)
                if not handle.try_acquire():
                    return False
                acquired.append(handle)
            self.handles = acquired
            acquired = []
            return True
        finally:
            for handle in reversed(acquired):
                handle.release()

    def _inherit(self):
        if not self.context_key:
            raise WorkError("EXECUTION_CONTEXT_KEY_REQUIRED")
        payload = decode_execution_context(self.inherited_context, self.context_key, self.resources)
        self.execution_id = payload["executionId"]
        self.operation = payload["operation"]
        self.record = {"schemaVersion": 1, "protocol": PROTOCOL,
                       "executionId": self.execution_id, "operation": self.operation,
                       "resources": payload["resources"], "supervisor": payload["supervisor"],
                       "state": "running", "inherited": True}
        return self

    def __enter__(self):
        if self.inherited_context:
            return self._inherit()
        with _LOCAL_HELD_LOCK:
            if set(self.resources).intersection(_LOCAL_HELD):
                raise WorkError("EXECUTION_GUARD_REENTRANT_ACQUISITION_FORBIDDEN")
        self.root.mkdir(parents=True, exist_ok=True)
        self._queued_ns = time.monotonic_ns()
        deadline = time.monotonic() + self.timeout
        self.wait_started = time.monotonic()
        self._write_waiter(self._queued_ns)
        self._publish("waiting", waitSeconds=0.0)
        try:
            while True:
                if self._cancelled():
                    raise WorkError("EXECUTION_GUARD_CANCELLED")
                self._raise_if_wait_expired(deadline)
                if self._is_head(deadline) and self._try_handles():
                    break
                self._publish("waiting", waitSeconds=max(0.0, time.monotonic() - self.wait_started))
                time.sleep(0.05)
            with contextlib.suppress(OSError):
                self.waiter_path.unlink()
            with _LOCAL_HELD_LOCK:
                _LOCAL_HELD.update(self.resources)
            self._context_key = secrets.token_bytes(32)
            self._publish("running", waitSeconds=max(0.0, time.monotonic() - self.wait_started))
            self._start_heartbeat()
            return self
        except BaseException as error:
            with contextlib.suppress(OSError):
                self.waiter_path.unlink()
            for handle in reversed(self.handles):
                handle.release()
            self.handles = []
            with _LOCAL_HELD_LOCK:
                _LOCAL_HELD.difference_update(self.resources)
            result = ("cancelled" if isinstance(error, WorkError) and
                      str(error) == "EXECUTION_GUARD_CANCELLED" else "failed")
            self._publish(result, result=result, error=str(error), finishedAt=stamp())
            raise

    def context(self):
        if self.inherited_context:
            return {"encoded": self.inherited_context, "key": self.context_key}
        if not self.handles or self.record is None or self.record.get("state") != "running":
            raise WorkError("EXECUTION_CONTEXT_NOT_RUNNING")
        payload = {"schemaVersion": 1, "protocol": PROTOCOL,
                   "executionId": self.execution_id, "operation": self.operation,
                   "resources": self.resources, "supervisor": self.record["supervisor"]}
        return {"encoded": encode_execution_context(payload, self._context_key),
                "key": self._context_key}

    def terminal(self, result, *, error=None, artifacts=None):
        if result not in TERMINAL_STATES:
            raise WorkError("EXECUTION_GUARD_RESULT_INVALID")
        if self.inherited_context:
            return
        self._heartbeat_stop.set()
        if self._heartbeat_thread:
            self._heartbeat_thread.join(timeout=max(1.0, self.heartbeat_seconds * 2))
        self._publish(result, result=result, error=error, artifacts=list(artifacts or []),
                      finishedAt=stamp())
        for handle in reversed(self.handles):
            handle.release()
        self.handles = []
        with _LOCAL_HELD_LOCK:
            _LOCAL_HELD.difference_update(self.resources)

    def __exit__(self, error_type, error, _traceback):
        if self.inherited_context:
            return False
        if self.handles:
            result = "succeeded" if error_type is None else (
                "cancelled" if isinstance(error, WorkError) and str(error) == "EXECUTION_GUARD_CANCELLED"
                else "failed")
            self.terminal(result, error=str(error) if error else None)
        return False
