"""Execution-host phase budgets, inherited without restarting a child's clock."""
from __future__ import annotations

import math
import platform
from pathlib import Path
import time

from .common import WorkError


PHASES = ("update", "prepare", "action", "ready", "verify", "reset", "source-capture", "cleanup")


def seconds(value):
    if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= 86400:
        raise WorkError("INVALID_SCENARIO_TIMEOUT")
    return float(value)


def budgets(scenario):
    default = seconds(scenario.get("timeoutSeconds", 300))
    overrides = scenario.get("phaseTimeoutSeconds", {})
    if not isinstance(overrides, dict) or set(overrides) - set(PHASES):
        raise WorkError("INVALID_PHASE_TIMEOUTS")
    return {name: seconds(overrides.get(name, default)) for name in PHASES}


class Deadline:
    def __init__(self, phase, timeout, *, expires_ns=None, cancel_path=None):
        self.phase, self.timeout = phase, seconds(timeout)
        self.expires_ns = time.monotonic_ns() + int(self.timeout * 1e9) if expires_ns is None else expires_ns
        if type(self.expires_ns) is not int or self.expires_ns <= 0:
            raise WorkError("INVALID_PHASE_DEADLINE")
        self.cancel_path = cancel_path

    def remaining(self):
        if self.phase != "cleanup" and self.cancel_path and Path(self.cancel_path).exists():
            raise WorkError("CANCELLED")
        remaining = (self.expires_ns - time.monotonic_ns()) / 1e9
        if remaining <= 0:
            raise WorkError("PHASE_TIMEOUT: " + self.phase)
        return remaining

    def record(self):
        return {"name": self.phase, "timeoutSeconds": self.timeout,
                "deadlineMonotonicNs": self.expires_ns, "executionHost": platform.node()}

    @classmethod
    def from_context(cls, context, *, phase=None):
        record = phase or context.get("phase")
        if not record:
            return cls("action", context.get("timeoutSeconds", 300), cancel_path=context.get("cancelPath"))
        host = platform.node()
        if record.get("executionHost") != host:
            raise WorkError("FOREIGN_PHASE_DEADLINE_HOST")
        return cls(record["name"], record["timeoutSeconds"], expires_ns=record["deadlineMonotonicNs"],
                   cancel_path=context.get("cancelPath"))
