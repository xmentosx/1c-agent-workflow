"""Scenario-side handshake. Import from the runtime directory supplied in the job."""
import contextlib
import os
from pathlib import Path
import time

from itl_remote.common import WorkError, read_json, write_json


def context():
    return read_json(os.environ["ITL_RUN_CONTEXT"])


@contextlib.contextmanager
def measurement(timeout=300):
    value = context()
    iteration = Path(value["iteration"])
    write_json(iteration / "ready.json", {"jobId": value["jobId"], "ready": True})
    deadline = time.monotonic() + timeout
    while not (iteration / "go.json").exists():
        if time.monotonic() > deadline:
            raise WorkError("CONTROLLER_START_TIMEOUT")
        time.sleep(0.01)
    if read_json(iteration / "go.json")["jobId"] != value["jobId"]:
        raise WorkError("FOREIGN_START_SIGNAL")
    started = time.monotonic_ns()
    yield value
    finished = time.monotonic_ns()
    write_json(iteration / "done.json", {"jobId": value["jobId"], "ready": True,
                                        "startedNs": started, "finishedNs": finished})


def verify(checks):
    value = context()
    passed = bool(checks) and all(check.get("passed") is True for check in checks)
    write_json(Path(value["iteration"]) / "verification.json",
               {"jobId": value["jobId"], "passed": passed, "checks": checks})
    if not passed:
        raise WorkError("SCENARIO_ASSERTIONS_FAILED")
