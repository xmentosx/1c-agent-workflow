"""Shared filesystem, UTF-8 and native-process boundaries."""
from __future__ import annotations

import contextlib
import errno
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid


DEFAULT_RESOURCE_LIMITS = {
    "pollIntervalSeconds": 1.0,
    "maxWorkerMemoryMb": 2048,
    "maxProcessMemoryMb": 16384,
    "maxJobMemoryMb": 24576,
    "minAvailableMemoryMb": 256,
    "maxCommittedPercent": 92.0,
    "maxGrowthMb": 8192,
    "growthWindowSeconds": 30.0,
}

_MAXIMUM_FIELDS = ("maxWorkerMemoryMb", "maxProcessMemoryMb", "maxJobMemoryMb",
                   "maxCommittedPercent", "maxGrowthMb", "pollIntervalSeconds")


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


def _validated_resource_limits(values):
    allowed = set(DEFAULT_RESOURCE_LIMITS) | {"byOperation"}
    if not isinstance(values, dict) or set(values) - allowed:
        raise WorkError("RESOURCE_LIMITS_INVALID")
    result = dict(DEFAULT_RESOURCE_LIMITS)
    for name in DEFAULT_RESOURCE_LIMITS:
        if name in values:
            value = values[name]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
                raise WorkError("RESOURCE_LIMITS_INVALID: " + name)
            result[name] = float(value)
    if not 0.1 <= result["pollIntervalSeconds"] <= 5:
        raise WorkError("RESOURCE_LIMITS_INVALID: pollIntervalSeconds")
    if not 1 <= result["maxCommittedPercent"] <= 100:
        raise WorkError("RESOURCE_LIMITS_INVALID: maxCommittedPercent")
    if result["growthWindowSeconds"] < result["pollIntervalSeconds"]:
        raise WorkError("RESOURCE_LIMITS_INVALID: growthWindowSeconds")
    return result


def resolve_resource_limits(target=None, operations=None):
    """Resolve one conservative policy for every operation declared by a job."""
    configured = (target or {}).get("resourceLimits", {})
    base = _validated_resource_limits({key: value for key, value in configured.items()
                                       if key != "byOperation"})
    by_operation = configured.get("byOperation", {})
    if not isinstance(by_operation, dict) or any(not isinstance(item, dict) for item in by_operation.values()):
        raise WorkError("RESOURCE_LIMITS_INVALID: byOperation")
    if set(by_operation) - {"measure", "write-data", "update"}:
        raise WorkError("RESOURCE_LIMITS_INVALID: byOperation")
    policies = []
    for operation in sorted(set(operations or [])):
        override = by_operation.get(operation)
        policies.append(_validated_resource_limits(dict(base, **override)) if override is not None else base)
    if not policies:
        return base
    result = dict(base)
    for name in _MAXIMUM_FIELDS:
        result[name] = min(policy[name] for policy in policies)
    result["minAvailableMemoryMb"] = max(policy["minAvailableMemoryMb"] for policy in policies)
    result["growthWindowSeconds"] = min(policy["growthWindowSeconds"] for policy in policies)
    return result


def host_memory_snapshot():
    if os.name == "nt":
        import ctypes as c
        from ctypes import wintypes as w
        kernel = c.WinDLL("kernel32", use_last_error=True)
        psapi = c.WinDLL("psapi", use_last_error=True)
        kernel.GlobalMemoryStatusEx.argtypes = [c.c_void_p]
        psapi.GetPerformanceInfo.argtypes = [c.c_void_p, w.DWORD]

        class MemoryStatus(c.Structure):
            _fields_ = [("length", w.DWORD), ("memoryLoad", w.DWORD),
                        ("totalPhysical", c.c_uint64), ("availablePhysical", c.c_uint64),
                        ("totalPageFile", c.c_uint64), ("availablePageFile", c.c_uint64),
                        ("totalVirtual", c.c_uint64), ("availableVirtual", c.c_uint64),
                        ("availableExtendedVirtual", c.c_uint64)]

        class Performance(c.Structure):
            _fields_ = [("size", w.DWORD), ("commitTotal", c.c_size_t),
                        ("commitLimit", c.c_size_t), ("commitPeak", c.c_size_t),
                        ("physicalTotal", c.c_size_t), ("physicalAvailable", c.c_size_t),
                        ("systemCache", c.c_size_t), ("kernelTotal", c.c_size_t),
                        ("kernelPaged", c.c_size_t), ("kernelNonpaged", c.c_size_t),
                        ("pageSize", c.c_size_t), ("handleCount", w.DWORD),
                        ("processCount", w.DWORD), ("threadCount", w.DWORD)]

        memory = MemoryStatus()
        memory.length = c.sizeof(memory)
        performance = Performance()
        performance.size = c.sizeof(performance)
        if not kernel.GlobalMemoryStatusEx(c.byref(memory)):
            raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: GlobalMemoryStatusEx")
        if not psapi.GetPerformanceInfo(c.byref(performance), c.sizeof(performance)):
            raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: GetPerformanceInfo")
        page = int(performance.pageSize)
        committed = int(performance.commitTotal) * page
        commit_limit = int(performance.commitLimit) * page
        return {"capturedAt": stamp(), "totalPhysicalBytes": int(memory.totalPhysical),
                "availablePhysicalBytes": int(memory.availablePhysical),
                "committedBytes": committed, "commitLimitBytes": commit_limit,
                "committedPercent": 100.0 * committed / commit_limit if commit_limit else None}

    memory_info = Path("/proc/meminfo")
    if memory_info.is_file():
        values = {}
        for line in memory_info.read_text(encoding="ascii").splitlines():
            name, value = line.split(":", 1)
            values[name] = int(value.strip().split()[0]) * 1024
        committed, limit = values.get("Committed_AS"), values.get("CommitLimit")
        return {"capturedAt": stamp(), "totalPhysicalBytes": values.get("MemTotal"),
                "availablePhysicalBytes": values.get("MemAvailable"), "committedBytes": committed,
                "commitLimitBytes": limit, "committedPercent": None}
    raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: host memory")


def process_memory_snapshot(pid, handle=None):
    if os.name == "nt":
        import ctypes as c
        from ctypes import wintypes as w
        psapi = c.WinDLL("psapi", use_last_error=True)
        kernel = c.WinDLL("kernel32", use_last_error=True)
        psapi.GetProcessMemoryInfo.argtypes = [w.HANDLE, c.c_void_p, w.DWORD]
        kernel.CloseHandle.argtypes = [w.HANDLE]

        class Counters(c.Structure):
            _fields_ = [("size", w.DWORD), ("pageFaultCount", w.DWORD),
                        ("peakWorkingSet", c.c_size_t), ("workingSet", c.c_size_t),
                        ("quotaPeakPagedPool", c.c_size_t), ("quotaPagedPool", c.c_size_t),
                        ("quotaPeakNonPagedPool", c.c_size_t), ("quotaNonPagedPool", c.c_size_t),
                        ("pagefile", c.c_size_t), ("peakPagefile", c.c_size_t),
                        ("privateUsage", c.c_size_t)]

        close_handle = False
        if handle is None:
            kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
            kernel.OpenProcess.restype = w.HANDLE
            handle = kernel.OpenProcess(0x1000 | 0x0400, False, int(pid))
            close_handle = True
        if not handle:
            raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: OpenProcess")
        try:
            counters = Counters()
            counters.size = c.sizeof(counters)
            if not psapi.GetProcessMemoryInfo(w.HANDLE(int(handle)), c.byref(counters), c.sizeof(counters)):
                raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: GetProcessMemoryInfo")
            return {"pid": int(pid), "workingSetBytes": int(counters.workingSet),
                    "peakWorkingSetBytes": int(counters.peakWorkingSet),
                    "privateBytes": int(counters.privateUsage), "peakPrivateBytes": int(counters.peakPagefile)}
        finally:
            if close_handle:
                kernel.CloseHandle(handle)

    status = Path("/proc") / str(pid) / "status"
    if status.is_file():
        values = {}
        for line in status.read_text(encoding="ascii").splitlines():
            if ":" in line:
                name, value = line.split(":", 1)
                if value.strip().split() and value.strip().split()[0].isdigit():
                    values[name] = int(value.strip().split()[0]) * 1024
        return {"pid": int(pid), "workingSetBytes": values.get("VmRSS", 0),
                "peakWorkingSetBytes": values.get("VmHWM", 0),
                "privateBytes": values.get("VmSize", 0), "peakPrivateBytes": values.get("VmPeak", 0)}
    raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: process memory")


def process_is_alive(pid):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes as c
        from ctypes import wintypes as w
        kernel = c.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        kernel.OpenProcess.restype = w.HANDLE
        kernel.GetExitCodeProcess.argtypes = [w.HANDLE, c.POINTER(w.DWORD)]
        kernel.CloseHandle.argtypes = [w.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        try:
            code = w.DWORD()
            return bool(kernel.GetExitCodeProcess(handle, c.byref(code))) and code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def process_executable(pid):
    if os.name == "nt":
        import ctypes as c
        from ctypes import wintypes as w
        kernel = c.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        kernel.OpenProcess.restype = w.HANDLE
        kernel.QueryFullProcessImageNameW.argtypes = [w.HANDLE, w.DWORD, w.LPWSTR, c.POINTER(w.DWORD)]
        kernel.CloseHandle.argtypes = [w.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, int(pid))
        if not handle:
            return None
        try:
            size = w.DWORD(32768)
            buffer = c.create_unicode_buffer(size.value)
            if not kernel.QueryFullProcessImageNameW(handle, 0, buffer, c.byref(size)):
                return None
            return buffer.value
        finally:
            kernel.CloseHandle(handle)
    try:
        return str((Path("/proc") / str(pid) / "exe").resolve(strict=True))
    except OSError:
        return None


def resource_violation(policy, host, process, job, worker, growth_bytes=0):
    mb = 1024 * 1024
    checks = (
        (worker.get("privateBytes", 0) > policy["maxWorkerMemoryMb"] * mb,
         "worker-memory", worker.get("privateBytes", 0), policy["maxWorkerMemoryMb"] * mb),
        (process.get("privateBytes", 0) > policy["maxProcessMemoryMb"] * mb,
         "process-memory", process.get("privateBytes", 0), policy["maxProcessMemoryMb"] * mb),
        (job.get("jobMemoryBytes", 0) > policy["maxJobMemoryMb"] * mb,
         "job-memory", job.get("jobMemoryBytes", 0), policy["maxJobMemoryMb"] * mb),
        (host.get("availablePhysicalBytes", 0) < policy["minAvailableMemoryMb"] * mb,
         "host-available-memory", host.get("availablePhysicalBytes", 0), policy["minAvailableMemoryMb"] * mb),
        (host.get("committedPercent") is not None and host.get("committedPercent") > policy["maxCommittedPercent"],
         "host-committed-percent", host.get("committedPercent"), policy["maxCommittedPercent"]),
        (growth_bytes > policy["maxGrowthMb"] * mb,
         "job-memory-growth", growth_bytes, policy["maxGrowthMb"] * mb),
    )
    for exceeded, metric, observed, limit in checks:
        if exceeded:
            return {"code": "RESOURCE_LIMIT_EXCEEDED", "metric": metric,
                    "observed": observed, "limit": limit, "capturedAt": stamp()}
    return None


class FileLock:
    """OS-owned lock; a crashed worker never leaves a lock needing manual deletion."""
    def __init__(self, path):
        self.path = Path(path)
        self.stream = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = self.path.open("a+b")
        self.stream.seek(0)
        # Both Windows byte locks and POSIX flock permit an empty file. Writing
        # the byte before acquiring it fails outside the contention handler on
        # Windows when another process already owns that region.
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self.stream.close()
            if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                raise
            raise WorkError("OWNER_BUSY: " + str(self.path)) from error
        return self

    def __exit__(self, *_):
        self.stream.close()


def native_environment(extra=None, *, windows_powershell=False):
    env = dict(os.environ)
    if windows_powershell:
        # Windows PowerShell must reconstruct its own edition's module search path.
        # A facade started from pwsh otherwise autoloads incompatible PS7 modules.
        for key in list(env):
            if key.lower() == "psmodulepath":
                del env[key]
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
                            timeout=timeout, env=native_environment(windows_powershell=Path(argv[0]).name.lower() in ("powershell", "powershell.exe")), shell=False)
    if result.returncode:
        raise WorkError("NATIVE_FAILED: " + result.stderr.decode("utf-8", errors="replace")[-2000:])
    return result.stdout


def git_path_list(project, arguments):
    """One UTF-8/NUL boundary for Git path inventories used by Python adapters."""
    if not isinstance(arguments, list) or '-z' not in arguments:
        raise WorkError('GIT_PATH_LIST_REQUIRES_NUL_OUTPUT')
    output = capture(['git', '-c', 'core.quotepath=false', '-C', str(project)] + arguments, timeout=30)
    if output and not output.endswith(b'\0'):
        raise WorkError('GIT_PATH_LIST_UNTERMINATED')
    return [item.decode('utf-8') for item in output.split(b'\0') if item]


class OwnedProcess:
    """Keep descendants in a Windows job (or POSIX process group), never kill by name."""
    def __init__(self, argv, cwd, output, env=None, resource_limits=None, telemetry=None, *, input_data=None):
        self.argv = native_args(argv)
        if input_data is not None and (not isinstance(input_data, bytes) or len(input_data) > 4096):
            raise WorkError('OWNED_PROCESS_PRIVATE_INPUT_INVALID')
        self.resource_limits = _validated_resource_limits(resource_limits or {})
        self.telemetry = Path(telemetry) if telemetry else None
        self.resource_samples = []
        self.resource_breach = None
        self.started_at = stamp()
        self.next_resource_sample = 0.0
        host = host_memory_snapshot()
        worker = process_memory_snapshot(os.getpid())
        breach = resource_violation(self.resource_limits, host, {}, {}, worker)
        if breach:
            raise WorkError("RESOURCE_LIMIT_EXCEEDED: " + json.dumps(breach, ensure_ascii=False))
        self.log = Path(output).open("ab")
        self.job = None
        windows_powershell = Path(self.argv[0]).name.lower() in ('powershell', 'powershell.exe')
        kwargs = dict(cwd=cwd, stdout=self.log, stderr=self.log,
                      env=native_environment(env, windows_powershell=windows_powershell), shell=False)
        if input_data is not None:
            kwargs['stdin'] = subprocess.PIPE
        if os.name == "nt":
            kwargs["creationflags"] = 0x00000004 | subprocess.CREATE_NO_WINDOW  # suspended until owned
        else:
            kwargs["start_new_session"] = True
        try:
            self.process = subprocess.Popen(self.argv, **kwargs)
            if os.name == "nt":
                self._own_windows_process()
            if input_data is not None:
                try:
                    self.process.stdin.write(input_data)
                finally:
                    self.process.stdin.close()
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
        info.basic.flags = 0x2000 | 0x0100 | 0x0200  # kill-on-close plus process/job memory limits
        info.processMemory = int(self.resource_limits["maxProcessMemoryMb"] * 1024 * 1024)
        info.jobMemory = int(self.resource_limits["maxJobMemoryMb"] * 1024 * 1024)
        job = kernel.CreateJobObjectW(None, None)
        if not job:
            raise c.WinError(c.get_last_error())
        self.job = job
        self.kernel = kernel
        self.extended_type = Extended
        kernel.QueryInformationJobObject.argtypes = [w.HANDLE, c.c_int, c.c_void_p, w.DWORD, c.POINTER(w.DWORD)]
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

    def _job_memory_snapshot(self):
        if not self.job:
            process = process_memory_snapshot(self.process.pid)
            return {"jobMemoryBytes": process["privateBytes"],
                    "peakJobMemoryBytes": process["peakPrivateBytes"], "activeProcesses": 1}
        import ctypes as c
        from ctypes import wintypes as w
        class Usage(c.Structure):
            _fields_ = [("jobMemory", c.c_uint64), ("peakJobMemory", c.c_uint64)]

        info = self.extended_type()
        returned = w.DWORD()
        if not self.kernel.QueryInformationJobObject(self.job, 9, c.byref(info), c.sizeof(info), c.byref(returned)):
            raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: QueryInformationJobObject")
        usage = Usage()
        current = int(info.peakJob)
        if self.kernel.QueryInformationJobObject(self.job, 28, c.byref(usage), c.sizeof(usage), c.byref(returned)):
            current = int(usage.jobMemory)
        return {"jobMemoryBytes": current, "peakJobMemoryBytes": int(info.peakJob),
                "peakProcessMemoryBytes": int(info.peakProcess),
                "activeProcesses": int(info.basic.active)}

    def _job_process_ids(self):
        if not self.job:
            return [self.process.pid]
        import ctypes as c
        from ctypes import wintypes as w
        capacity = 256
        size = 8 + capacity * c.sizeof(c.c_size_t)
        buffer = c.create_string_buffer(size)
        returned = w.DWORD()
        if not self.kernel.QueryInformationJobObject(self.job, 3, buffer, size, c.byref(returned)):
            raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: JobObjectBasicProcessIdList")
        assigned = w.DWORD.from_buffer_copy(buffer.raw[0:4]).value
        listed = w.DWORD.from_buffer_copy(buffer.raw[4:8]).value
        if assigned > capacity or listed > capacity:
            raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: too many owned processes")
        return [c.c_size_t.from_buffer_copy(buffer.raw, 8 + index * c.sizeof(c.c_size_t)).value
                for index in range(listed)]

    def _sample_resources(self):
        process_samples = []
        for pid in self._job_process_ids():
            try:
                handle = int(self.process._handle) if os.name == "nt" and pid == self.process.pid else None
                item = process_memory_snapshot(pid, handle)
                item["executable"] = process_executable(pid)
                process_samples.append(item)
            except WorkError:
                if process_is_alive(pid):
                    raise
        if not process_samples:
            raise WorkError("RESOURCE_MONITOR_UNAVAILABLE: owned process list is empty")
        largest = max(process_samples, key=lambda item: item.get("privateBytes", 0))
        sample = {"capturedAt": stamp(), "host": host_memory_snapshot(),
                  "process": largest, "processes": process_samples,
                  "worker": process_memory_snapshot(os.getpid()), "job": self._job_memory_snapshot()}
        now = time.monotonic()
        current = sample["job"].get("jobMemoryBytes", 0)
        self.resource_samples.append((now, current))
        cutoff = now - self.resource_limits["growthWindowSeconds"]
        self.resource_samples = [entry for entry in self.resource_samples if entry[0] >= cutoff]
        growth = max(0, current - min(value for _, value in self.resource_samples))
        sample["growthWindowBytes"] = growth
        breach = resource_violation(self.resource_limits, sample["host"], sample["process"],
                                    sample["job"], sample["worker"], growth)
        if self.telemetry:
            self.telemetry.parent.mkdir(parents=True, exist_ok=True)
            with self.telemetry.open("a", encoding="utf-8", newline="\n") as stream:
                stream.write(json.dumps(dict(sample, pid=self.process.pid,
                                             executable=Path(self.argv[0]).name,
                                             breach=breach), ensure_ascii=False, allow_nan=False) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
        if breach:
            self.resource_breach = breach
            if self.job:
                self.kernel.TerminateJobObject(self.job, 1)
            elif self.process.poll() is None:
                self.process.kill()
            raise WorkError("RESOURCE_LIMIT_EXCEEDED: " + json.dumps(breach, ensure_ascii=False))
        return sample

    def monitor(self, *, force=False):
        now = time.monotonic()
        if force or now >= self.next_resource_sample:
            sample = self._sample_resources()
            self.next_resource_sample = now + self.resource_limits["pollIntervalSeconds"]
            return sample
        return None

    def wait(self, timeout, cancelled=lambda: False):
        deadline = time.monotonic() + timeout
        while self.process.poll() is None:
            if cancelled():
                raise WorkError("CANCELLED")
            if time.monotonic() > deadline:
                raise WorkError("COMMAND_TIMEOUT")
            self.monitor()
            time.sleep(0.1)
        if self.process.returncode:
            raise WorkError("COMMAND_FAILED: exit=" + str(self.process.returncode))

    def resource_summary(self):
        samples = [value for _, value in self.resource_samples]
        return {"pid": self.process.pid, "executable": Path(self.argv[0]).name,
                "startedAt": self.started_at, "finishedAt": stamp(),
                "peakObservedJobMemoryBytes": max(samples) if samples else 0,
                "breach": self.resource_breach}

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
