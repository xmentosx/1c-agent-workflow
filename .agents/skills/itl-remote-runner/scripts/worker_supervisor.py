#!/usr/bin/env python3
"""Stable user-space launcher that atomically switches worker generations."""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys
import time

from itl_remote.common import read_json, stamp, write_json


def _command(runtime, args, generation=None, confirmation=None):
    command = [sys.executable, "-B", "-X", "utf8", "-u", str(runtime), "worker",
               "--spool", str(args.spool)]
    if args.connection:
        command += ["--connection", str(args.connection)]
    if args.persistent:
        command.append("--persistent")
    else:
        command.append("--once")
    if generation:
        command += ["--generation", generation, "--confirm-path", str(confirmation)]
    return command


def _run(command):
    return subprocess.call(command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spool", required=True, type=Path)
    parser.add_argument("--bootstrap-runtime", required=True, type=Path)
    parser.add_argument("--connection", type=Path)
    parser.add_argument("--persistent", action="store_true")
    parser.add_argument("--trial-timeout-seconds", type=float, default=30)
    args = parser.parse_args()
    args.spool = args.spool.resolve()
    runtime_root = args.spool / "runtime"
    current_path, pending_path = runtime_root / "current.json", runtime_root / "pending.json"
    def current_state():
        value = read_json(current_path) if current_path.exists() else {
            "runtime": str(args.bootstrap_runtime.resolve())}
        selected = Path(value.get("runtime", ""))
        return value, selected if selected.is_file() else args.bootstrap_runtime.resolve()

    current, current_runtime = current_state()
    if not pending_path.exists():
        exit_code = _run(_command(current_runtime, args))
        # A running worker stages an update, then exits at its next idle
        # boundary. Apply that pending generation in this same supervisor
        # invocation so no user relaunch is required.
        if not pending_path.exists():
            return exit_code
        current, current_runtime = current_state()

    pending = read_json(pending_path)
    trial_runtime = Path(pending.get("runtime", ""))
    confirmation = runtime_root / ("confirmed-" + str(pending.get("archiveSha256", "invalid")) + ".json")
    confirmation.unlink(missing_ok=True)
    if not trial_runtime.is_file():
        write_json(runtime_root / "rollback.json",
                   {"status": "rolled-back", "reason": "pending-runtime-missing", "at": stamp(),
                    "pending": pending, "current": current})
        pending_path.unlink(missing_ok=True)
        return _run(_command(current_runtime, args))

    process = subprocess.Popen(_command(trial_runtime, args, pending.get("archiveSha256"), confirmation))
    deadline = time.monotonic() + min(max(args.trial_timeout_seconds, 1), 120)
    confirmed = False
    while time.monotonic() < deadline and process.poll() is None:
        if confirmation.exists():
            value = read_json(confirmation)
            confirmed = value.get("archiveSha256") == pending.get("archiveSha256")
            if confirmed:
                break
        time.sleep(0.1)
    if not confirmed and confirmation.exists():
        value = read_json(confirmation)
        confirmed = value.get("archiveSha256") == pending.get("archiveSha256")
    if confirmed:
        write_json(current_path, dict(pending, confirmedAt=stamp()))
        pending_path.unlink(missing_ok=True)
        return process.wait()

    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
    write_json(runtime_root / "rollback.json",
               {"status": "rolled-back", "reason": "trial-not-confirmed", "at": stamp(),
                "pending": pending, "current": current, "trialExitCode": process.returncode})
    pending_path.unlink(missing_ok=True)
    confirmation.unlink(missing_ok=True)
    return _run(_command(current_runtime, args))


if __name__ == "__main__":
    sys.exit(main())
