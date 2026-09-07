"""Shared filesystem, UTF-8 and native-process boundaries."""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid


class WorkError(RuntimeError):
    pass


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def publish_path(source, destination, *, replace=False):
    """Bounded retry for Windows scanner/share locks; keep publication atomic."""
    for attempt in range(20):
        try:
            if not replace and Path(destination).exists():
                raise WorkError("PUBLICATION_DESTINATION_EXISTS")
            (os.replace if replace else os.rename)(source, destination)
            return
        except OSError as error:
            if getattr(error, "winerror", None) not in (5, 32, 33) or attempt == 19:
                raise
            time.sleep(0.05 * (1 + min(attempt, 3)))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        publish_path(temporary, path, replace=True)
    finally:
        temporary.unlink(missing_ok=True)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def identity(value):
    raw = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def beneath(root, relative):
    """Reject absolute paths, traversal and symlink/junction escapes, including on Windows."""
    from pathlib import PureWindowsPath
    root = Path(root).resolve()
    candidate = Path(relative)
    if candidate.is_absolute() or PureWindowsPath(str(relative)).drive or ".." in candidate.parts:
        raise WorkError("PATH_OUTSIDE_ROOT: " + str(relative))
    resolved = (root / candidate).resolve()
    if not resolved.is_relative_to(root) or resolved == root:
        raise WorkError("PATH_OUTSIDE_ROOT: " + str(relative))
    return resolved


def stamp():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()


class FileLock:
    """OS-owned lock; a crashed worker never leaves a lock needing manual deletion."""
    def __init__(self, path):
        self.path = Path(path)
        self.stream = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = self.path.open("a+b")
        self.stream.seek(0)
        self.stream.write(b"0")
        self.stream.flush()
        self.stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self.stream.close()
            raise WorkError("OWNER_BUSY: " + str(self.path)) from error
        return self

    def __exit__(self, *_):
        self.stream.close()


def native_environment(extra=None):
    env = dict(os.environ)
    env.update(PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    env.update(extra or {})
    return env


def native_args(argv):
    """One native argv boundary for every adapter. Never accept a shell command string."""
    if not isinstance(argv, list) or not argv or any(not isinstance(a, str) or "\0" in a for a in argv):
        raise WorkError("COMMAND_REQUIRES_ARGUMENT_ARRAY")
    return argv


def capture(argv, *, cwd=None, timeout=60, input_bytes=None):
    result = subprocess.run(native_args(argv), cwd=cwd, input=input_bytes,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout, env=native_environment(), shell=False)
    if result.returncode:
        raise WorkError("NATIVE_FAILED: " + result.stderr.decode("utf-8", errors="replace")[-2000:])
    return result.stdout


class OwnedProcess:
    """Keep descendants in a Windows job (or POSIX process group), never kill by name."""
    def __init__(self, argv, cwd, output, env=None):
        self.log = Path(output).open("ab")
        self.job = None
        kwargs = dict(cwd=cwd, stdout=self.log, stderr=self.log, env=native_environment(env), shell=False)
        if os.name == "nt":
            kwargs["creationflags"] = 0x00000004 | subprocess.CREATE_NO_WINDOW  # suspended until owned
        else:
            kwargs["start_new_session"] = True
        try:
            self.process = subprocess.Popen(native_args(argv), **kwargs)
            if os.name == "nt":
                self._own_windows_process()
        except BaseException:
            if hasattr(self, "process"):
                self.process.kill()
                self.process.wait()
            self.log.close()
            raise

    def _own_windows_process(self):
        import ctypes as c
        from ctypes import wintypes as w
        kernel = c.WinDLL("kernel32", use_last_error=True)
        kernel.CreateJobObjectW.argtypes = [c.c_void_p, w.LPCWSTR]
        kernel.CreateJobObjectW.restype = w.HANDLE
        kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        kernel.SetInformationJobObject.argtypes = [w.HANDLE, c.c_int, c.c_void_p, w.DWORD]
        kernel.CloseHandle.argtypes = [w.HANDLE]
        kernel.TerminateJobObject.argtypes = [w.HANDLE, w.UINT]
        # JOBOBJECT_EXTENDED_LIMIT_INFORMATION, native pointer-size layout.
        class Basic(c.Structure):
            _fields_ = [("processTime", c.c_int64), ("jobTime", c.c_int64), ("flags", w.DWORD),
                        ("minWorking", c.c_size_t), ("maxWorking", c.c_size_t), ("active", w.DWORD),
                        ("affinity", c.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]
        class Extended(c.Structure):
            _fields_ = [("basic", Basic), ("io", c.c_uint64 * 6), ("processMemory", c.c_size_t),
                        ("jobMemory", c.c_size_t), ("peakProcess", c.c_size_t), ("peakJob", c.c_size_t)]
        info = Extended()
        info.basic.flags = 0x2000  # KILL_ON_JOB_CLOSE, also on abrupt runner exit
        job = kernel.CreateJobObjectW(None, None)
        if not job:
            raise c.WinError(c.get_last_error())
        self.job = job
        self.kernel = kernel
        if not kernel.SetInformationJobObject(job, 9, c.byref(info), c.sizeof(info)):
            kernel.CloseHandle(job)
            self.job = None
            raise c.WinError(c.get_last_error())
        if not kernel.AssignProcessToJobObject(job, w.HANDLE(int(self.process._handle))):
            kernel.CloseHandle(job)
            self.job = None
            raise c.WinError(c.get_last_error())
        nt = c.WinDLL("ntdll")
        nt.NtResumeProcess.argtypes = [w.HANDLE]
        if nt.NtResumeProcess(w.HANDLE(int(self.process._handle))) != 0:
            self.close()
            raise WorkError("PROCESS_RESUME_FAILED")

    def wait(self, timeout, cancelled=lambda: False):
        deadline = time.monotonic() + timeout
        while self.process.poll() is None:
            if cancelled():
                raise WorkError("CANCELLED")
            if time.monotonic() > deadline:
                raise WorkError("COMMAND_TIMEOUT")
            time.sleep(0.02)
        if self.process.returncode:
            raise WorkError("COMMAND_FAILED: exit=" + str(self.process.returncode))

    def close(self):
        if self.job:
            self.kernel.CloseHandle(self.job)
            self.job = None
        elif os.name != "nt":
            with contextlib.suppress(ProcessLookupError):
                os.killpg(self.process.pid, signal.SIGTERM)
        elif self.process.poll() is None:
            self.process.kill()
        with contextlib.suppress(subprocess.TimeoutExpired):
            self.process.wait(timeout=5)
        self.log.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
