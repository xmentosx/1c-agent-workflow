#!/usr/bin/env python3
"""Portable CLI shared by local and user-started remote worker workflows (Python 3.11+)."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import threading
import time

from itl_remote.common import (FileLock, WorkError, current_session_identity, current_user_identity,
                               host_memory_snapshot, process_identity, process_memory_snapshot,
                               read_json, stamp, write_json)


def configure_utf8_stdio():
    """Make the CLI byte boundary deterministic before emitting native paths."""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure:
            reconfigure(encoding="utf-8", errors="strict")


class WorkerHeartbeat:
    """Publish a PID-reuse-safe heartbeat while the foreground worker owns its session."""
    def __init__(self, spool, mode, started_at):
        self.path = Path(spool) / "worker.json"
        self.identity = process_identity(os.getpid())
        self.state = {"status": "ready", "pid": os.getpid(), "processIdentity": self.identity,
                      "sessionIdentity": current_session_identity(), "mode": mode,
                      "startedAt": started_at, "jobsProcessed": 0}
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, name="itl-worker-heartbeat", daemon=True)

    def _publish(self):
        with self.lock:
            value = dict(self.state, updatedAt=stamp(), hostMemory=host_memory_snapshot(),
                         workerMemory=process_memory_snapshot(os.getpid()))
            write_json(self.path, value)

    def start(self):
        self._publish()
        self.thread.start()

    def update(self, **values):
        with self.lock:
            self.state.update(values)
        self._publish()

    def _run(self):
        while not self.stop_event.wait(1.0):
            self._publish()

    def stop(self, *, jobs_processed, reason):
        self.stop_event.set()
        self.thread.join(timeout=5)
        self.update(status="stopped", jobsProcessed=jobs_processed, reason=reason, currentJob=None)


def main():
    configure_utf8_stdio()
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("version")
    command = commands.add_parser("scaffold")
    command.add_argument("--project", required=True)
    command.add_argument("--name", required=True)
    command = commands.add_parser("agent-request")
    command.add_argument("--spool", required=True)
    command.add_argument("--id", required=True)
    command.add_argument("--action", choices=["read", "followup", "interrupt", "respond"], required=True)
    command.add_argument("--payload", help="JSON file: prompt or exact requestId/result")
    for name in ("probe", "worker", "execute", "status", "cancel", "collect", "rpc"):
        command = commands.add_parser(name)
        command.add_argument("--spool", required=True)
        if name in ("execute", "status", "cancel", "collect"):
            command.add_argument("--id", required=True)
        if name == "execute":
            command.add_argument("--via-agent", action="store_true")
        if name == "collect":
            command.add_argument("--output", required=True)
            command.add_argument("--allow-partial", action="store_true", help="Collect available diagnostics without requiring a measurement result")
        if name == "worker":
            mode = command.add_mutually_exclusive_group()
            mode.add_argument("--once", action="store_true")
            mode.add_argument("--persistent", action="store_true")
            command.add_argument("--max-jobs", type=int)
            command.add_argument("--max-lifetime-seconds", type=float)
            command.add_argument("--connection")
            command.add_argument("--generation")
            command.add_argument("--confirm-path")
    command = commands.add_parser("prepare")
    command.add_argument("--spool", required=True)
    command.add_argument("--profile", required=True)
    command.add_argument("--worker-connection")
    command.add_argument("--update-policy", choices=["disabled", "compatible"])
    command = commands.add_parser("pair")
    command.add_argument("--url", required=True)
    command.add_argument("--controller-output", required=True)
    command.add_argument("--worker-output", required=True)
    command.add_argument("--worker-id")
    command.add_argument("--controller-folder")
    command.add_argument("--worker-folder")
    command.add_argument("--threshold-bytes", type=int, default=64 * 1024 * 1024)
    command = commands.add_parser("pull-serve")
    command.add_argument("--listen", default="127.0.0.1")
    command.add_argument("--port", type=int, default=8765)
    command.add_argument("--certificate")
    command.add_argument("--private-key")
    command.add_argument("--connection", action="append", required=True,
                         help="Paired controller connection authorized by this broker; repeat as needed")
    command = commands.add_parser("stage-update")
    command.add_argument("--connection", required=True)
    command.add_argument("--bundle", required=True)
    command = commands.add_parser("sync-worker")
    command.add_argument("--connection", required=True)
    command.add_argument("--repository", required=True)
    command = commands.add_parser("pack")
    command.add_argument("--scenario", required=True)
    command.add_argument("--output", required=True)
    command.add_argument("--target", required=True)
    command.add_argument("--parameters", help="UTF-8 JSON object file")
    command.add_argument("--mode", choices=["time", "profile", "time+profile"], default="time+profile")
    execution = command.add_mutually_exclusive_group()
    execution.add_argument("--route", choices=["local", "auto", "ssh", "agent"],
                           help="Deprecated combined execution/transport selector")
    execution.add_argument("--runner", choices=["local", "worker"], default="worker")
    command.add_argument("--agent-policy", choices=["off", "requested", "diagnosis-on-failure"], default="off")
    command.add_argument("--repeats", type=int, default=3)
    command.add_argument("--warmups", type=int, default=1)
    command.add_argument("--operation", action="append", default=None)
    command.add_argument("--id")
    command.add_argument("--parent")
    for name in ("submit", "send"):
        command = commands.add_parser(name)
        command.add_argument("--package", required=True)
        command.add_argument("--spool" if name == "submit" else "--connection", required=True)
    command = commands.add_parser("remote")
    command.add_argument("--connection", required=True)
    command.add_argument("--action", choices=["probe", "status", "cancel", "collect", "agent-request"], required=True)
    command.add_argument("--agent-action", choices=["read", "followup", "interrupt", "respond"])
    command.add_argument("--payload")
    command.add_argument("--id")
    command.add_argument("--output")
    command.add_argument("--allow-partial", action="store_true", help="Allow diagnostic-only collection for --action collect")
    command = commands.add_parser("compare")
    command.add_argument("--baseline", required=True)
    command.add_argument("--candidate", required=True)
    command = commands.add_parser("analyze")
    command.add_argument("--raw", nargs="+", required=True)
    command.add_argument("--session")
    command.add_argument("--source-map")
    command.add_argument("--source-modules", help="JSON array of native module identities; omitted means all measured modules")
    command.add_argument("--source-analysis", choices=["none", "optional", "required"], default="optional")
    command = commands.add_parser("runtime-proof")
    command.add_argument("--context", required=True)
    command.add_argument("--client-pid", type=int, required=True)
    session = command.add_mutually_exclusive_group(required=True)
    session.add_argument("--seance")
    session.add_argument("--session-observation", help="own TestClient observation JSON path relative to the run directory")
    command.add_argument("--instance")
    command = commands.add_parser("export")
    command.add_argument("--repository", required=True)
    command.add_argument("--output", required=True)
    command.add_argument("--python-archive", help="Pinned Python package to include for offline Windows setup")
    args = parser.parse_args()
    if args.command == "version":
        from itl_remote import VERSION
        return {"version": VERSION}
    from itl_remote import bootstrap, execution, jobs, profiling, transport
    if args.command == "scaffold":
        from itl_remote.scenarios import scaffold
        return scaffold(args.project, args.name)
    if args.command == "agent-request":
        from itl_remote.agents import control
        return control(args.spool, args.id, args.action, read_json(args.payload) if args.payload else {})
    if args.command == "pack":
        return jobs.pack(args.scenario, args.output, target=args.target,
                         values=read_json(args.parameters) if args.parameters else {}, mode=args.mode,
                         route=args.route, runner=None if args.route else args.runner,
                         agent_policy=None if args.route else args.agent_policy,
                         repeats=args.repeats, warmups=args.warmups,
                         operations=args.operation, identifier=args.id, parent=args.parent)
    if args.command == "prepare":
        return bootstrap.prepare(args.spool, args.profile, args.worker_connection, args.update_policy)
    if args.command == "pair":
        return bootstrap.pair(args.url, args.controller_output, args.worker_output,
                              worker_id=args.worker_id, controller_folder=args.controller_folder,
                              worker_folder=args.worker_folder, threshold_bytes=args.threshold_bytes)
    if args.command == "pull-serve":
        from itl_remote.pull import serve
        return serve(args.listen, args.port, certificate=args.certificate, private_key=args.private_key,
                     connections=args.connection)
    if args.command == "stage-update":
        return transport.Connection(read_json(args.connection)).stage_update(args.bundle)
    if args.command == "sync-worker":
        import tempfile
        from itl_remote import VERSION
        connection = transport.Connection(read_json(args.connection))
        observed = connection.call({"operation": "probe"})
        if observed.get("version") == VERSION:
            return {"status": "worker-current", "version": VERSION}
        with tempfile.TemporaryDirectory(prefix="itl-worker-update-") as temporary:
            bundle = Path(temporary) / "worker-update.zip"
            bootstrap.export_bundle(args.repository, bundle)
            result = connection.stage_update(bundle)
        return dict(result, observedVersion=observed.get("version"), controllerVersion=VERSION)
    if args.command == "probe":
        return bootstrap.inspect(args.spool)
    if args.command == "export":
        return bootstrap.export_bundle(args.repository, args.output, args.python_archive)
    if args.command == "compare":
        return execution.compare(args.baseline, args.candidate)
    if args.command == "analyze":
        return profiling.analyze_raw(args.raw, args.session,
                                     source_map=read_json(args.source_map) if args.source_map and args.source_analysis != "none" else None,
                                     source_policy=args.source_analysis,
                                     source_map_root=Path(args.source_map).resolve().parent if args.source_map else None,
                                     source_modules=read_json(args.source_modules) if args.source_modules else None)
    if args.command == "runtime-proof":
        return profiling.runtime_proof(args.context, args.client_pid, args.seance, args.instance, args.session_observation)
    if args.command == "submit":
        return jobs.submit(args.package, args.spool)
    if args.command == "send":
        return transport.Connection(read_json(args.connection)).send(args.package)
    if args.command == "remote":
        connection = transport.Connection(read_json(args.connection))
        if args.action == "collect":
            return connection.collect(args.id, args.output, allow_partial=args.allow_partial)
        if args.action == "agent-request":
            if not args.agent_action:
                raise WorkError("AGENT_ACTION_REQUIRED")
            return connection.call({"operation": "agent-request", "id": args.id, "action": args.agent_action,
                                    "payload": read_json(args.payload) if args.payload else {}})
        return connection.call({"operation": args.action, "id": args.id})
    if args.command in ("status", "cancel"):
        return getattr(jobs, args.command)(args.spool, args.id)
    if args.command == "collect":
        return jobs.collect(args.spool, args.id, args.output, allow_partial=args.allow_partial)
    if args.command == "rpc":
        return transport.endpoint(args.spool, json.load(sys.stdin))
    if args.command == "execute":
        return execution.execute_job(args.spool, args.id, read_json(Path(args.spool) / "profile.json"),
                                     via_agent=args.via_agent,
                                     expected_runner="worker" if args.via_agent else "local")
    if args.command == "worker":
        spool = Path(args.spool).resolve()
        profile = read_json(spool / "profile.json")
        if profile.get("workerOwner") is not None and profile["workerOwner"] != current_user_identity():
            raise WorkError("WORKER_USER_IDENTITY_MISMATCH")
        worker_connection = read_json(args.connection) if args.connection else None
        worker_limits = profile.get("workerLimits", {})
        if not isinstance(worker_limits, dict):
            raise WorkError("WORKER_LIMITS_INVALID")
        pull_persistent = bool(worker_connection and worker_connection.get("transport") == "pull" and
                               worker_connection.get("pull", {}).get("persistent") is True)
        if args.persistent and worker_limits.get("allowPersistent") is not True and not pull_persistent:
            raise WorkError("PERSISTENT_WORKER_NOT_ALLOWED")
        persistent = bool(args.persistent)
        max_jobs = args.max_jobs if args.max_jobs is not None else (worker_limits.get("maxJobs", 10) if persistent else 1)
        max_lifetime = (args.max_lifetime_seconds if args.max_lifetime_seconds is not None else
                        worker_limits.get("maxLifetimeSeconds", 3600))
        if (type(max_jobs) is not int or not 1 <= max_jobs <= 100 or isinstance(max_lifetime, bool) or
                not isinstance(max_lifetime, (int, float)) or not 1 <= max_lifetime <= 86400):
            raise WorkError("WORKER_LIMITS_INVALID")
        started = time.monotonic()
        started_at = stamp()
        completed_jobs = 0
        stop_reason = "one-shot-complete"
        with FileLock(spool / "service.lock"):
            heartbeat = WorkerHeartbeat(spool, "persistent" if persistent else "one-shot", started_at)
            pull_stop = threading.Event()
            pull_worker = None
            if worker_connection is not None:
                if worker_connection.get("transport") != "pull":
                    raise WorkError("WORKER_CONNECTION_PULL_REQUIRED")
                from itl_remote.pull import PullWorker
                pull_worker = PullWorker(worker_connection, spool, pull_stop)
                pull_worker.start()
            heartbeat.start()
            if args.generation and args.confirm_path:
                write_json(args.confirm_path, {"archiveSha256": args.generation, "confirmedAt": stamp(),
                                               "pid": os.getpid()})
            print("ITL worker ready. Mode: " + ("persistent" if persistent else "one-shot") +
                  ". Stop: Ctrl+C. Spool: " + str(spool), flush=True)
            try:
                while True:
                    profile = read_json(spool / "profile.json")
                    elapsed = time.monotonic() - started
                    if elapsed >= max_lifetime:
                        stop_reason = "max-lifetime"
                        break
                    if (spool / "runtime" / "pending.json").exists():
                        stop_reason = "update-staged"
                        break
                    heartbeat.update(status="ready", jobsProcessed=completed_jobs, currentJob=None)
                    for package in sorted((spool / "jobs").glob("*")):
                        if package.name.startswith(".") or not package.is_dir():
                            continue
                        current = jobs.status(spool, package.name)
                        if current["status"] in ("queued", "running", "waiting-for-base"):
                            heartbeat.update(status="running", jobsProcessed=completed_jobs, currentJob=package.name)
                            try:
                                result = execution.execute_job(spool, package.name, profile, expected_runner="worker")
                                print(json.dumps(result, ensure_ascii=True), flush=True)
                            except WorkError as error:
                                if str(error).startswith("OWNER_BUSY"):
                                    heartbeat.update(status="ready", jobsProcessed=completed_jobs, currentJob=None)
                                    continue
                                write_json(spool / "state" / (package.name + ".json"),
                                           {"id": package.name, "status": "needs-attention", "error": str(error), "updatedAt": stamp()})
                            completed_jobs += 1
                            heartbeat.update(status="ready", jobsProcessed=completed_jobs, currentJob=None)
                            break
                    from itl_remote.agents import run_queued_controls
                    run_queued_controls(spool)
                    if not persistent and (completed_jobs or pull_worker is None):
                        break
                    if completed_jobs >= max_jobs:
                        stop_reason = "max-jobs"
                        break
                    time.sleep(0.2 if pull_worker is not None else 1)
            finally:
                if pull_worker is not None:
                    pull_worker.stop()
                heartbeat.stop(jobs_processed=completed_jobs, reason=stop_reason)
        return {"status": "stopped", "jobsProcessed": completed_jobs, "reason": stop_reason}


if __name__ == "__main__":
    try:
        value = main()
        print(json.dumps(value, ensure_ascii=True, allow_nan=False))
        if isinstance(value, dict) and value.get("sourceAnalysis", {}).get("requirementSatisfied") is False:
            sys.exit(2)
    except KeyboardInterrupt:
        print(json.dumps({"status": "interrupted"}))
        sys.exit(130)
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=True))
        sys.exit(1)
