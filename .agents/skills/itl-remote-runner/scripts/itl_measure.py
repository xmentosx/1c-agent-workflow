"""Scenario-side handshake. Import from the runtime directory supplied in the job."""
import contextlib
import os
from pathlib import Path
import time

from itl_remote.common import WorkError, read_json, write_json
from itl_remote.deadlines import Deadline
from itl_remote.operation_producer import publish


def context():
    return read_json(os.environ["ITL_RUN_CONTEXT"])


@contextlib.contextmanager
def measurement(timeout=None):
    value = context()
    iteration = Path(value["iteration"])
    write_json(iteration / "ready.json", {"jobId": value["jobId"], "ready": True})
    deadline = Deadline.from_context(value)
    # An explicit legacy caller limit may narrow, but never extend, its parent.
    if timeout is not None:
        deadline = Deadline("ready", min(timeout, deadline.remaining()), cancel_path=value.get("cancelPath"))
    while not (iteration / "go.json").exists():
        deadline.remaining()
        time.sleep(0.01)
    signal = read_json(iteration / "go.json")
    if signal["jobId"] != value["jobId"]:
        raise WorkError("FOREIGN_START_SIGNAL")
    if signal.get("phase"):
        value["phase"] = signal["phase"]
        Deadline.from_context(value).remaining()
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


def publish_operation_evidence(envelope, fragments):
    """Merge transported producer fragments into the iteration's private sidecar."""
    value = context()
    diagnostics = value.get("diagnostics")
    if not diagnostics:
        raise WorkError("OPERATION_EVIDENCE_NOT_REQUESTED")
    envelope = dict(envelope)
    envelope.setdefault("schemaVersion", 1)
    envelope.setdefault("jobId", value["jobId"])
    envelope.setdefault("iterationId", value["iterationIndex"])
    envelope.setdefault("diagnostics", {"level": diagnostics["level"]})
    destination = Path(value["iteration"]) / diagnostics["evidencePath"]
    return publish(envelope, fragments, destination)
