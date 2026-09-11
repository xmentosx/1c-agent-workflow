#!/usr/bin/env python3
"""Portable CLI shared by local, SSH and remote-agent workflows (Python 3.11+)."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import time

from itl_remote.common import (FileLock, WorkError, host_memory_snapshot, process_memory_snapshot,
                               read_json, stamp, write_json)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
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
        if name == "worker":
            mode = command.add_mutually_exclusive_group()
            mode.add_argument("--once", action="store_true")
            mode.add_argument("--persistent", action="store_true")
            command.add_argument("--max-jobs", type=int)
            command.add_argument("--max-lifetime-seconds", type=float)
    command = commands.add_parser("prepare")
    command.add_argument("--spool", required=True)
    command.add_argument("--profile", required=True)
    command = commands.add_parser("pack")
    command.add_argument("--scenario", required=True)
    command.add_argument("--output", required=True)
    command.add_argument("--target", required=True)
    command.add_argument("--parameters", help="UTF-8 JSON object file")
    command.add_argument("--mode", choices=["time", "profile", "time+profile"], default="time+profile")
    command.add_argument("--route", choices=["local", "auto", "ssh", "agent"], default="auto")
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
    command = commands.add_parser("compare")
    command.add_argument("--baseline", required=True)
    command.add_argument("--candidate", required=True)
    command = commands.add_parser("analyze")
    command.add_argument("--raw", nargs="+", required=True)
    command.add_argument("--session")
    command.add_argument("--source-map")
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
    args = parser.parse_args()
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
                         route=args.route, repeats=args.repeats, warmups=args.warmups,
                         operations=args.operation, identifier=args.id, parent=args.parent)
    if args.command == "prepare":
        return bootstrap.prepare(args.spool, args.profile)
    if args.command == "probe":
        return bootstrap.inspect(args.spool)
    if args.command == "export":
        return bootstrap.export_bundle(args.repository, args.output)
    if args.command == "compare":
        return execution.compare(args.baseline, args.candidate)
    if args.command == "analyze":
        return profiling.analyze_raw(args.raw, args.session,
                                     source_map=read_json(args.source_map) if args.source_map else None)
    if args.command == "runtime-proof":
        return profiling.runtime_proof(args.context, args.client_pid, args.seance, args.instance, args.session_observation)
    if args.command == "submit":
        return jobs.submit(args.package, args.spool)
    if args.command == "send":
        return transport.Connection(read_json(args.connection)).send(args.package)
    if args.command == "remote":
        connection = transport.Connection(read_json(args.connection))
        if args.action == "collect":
            return connection.collect(args.id, args.output)
        if args.action == "agent-request":
            if not args.agent_action:
                raise WorkError("AGENT_ACTION_REQUIRED")
            return connection.call({"operation": "agent-request", "id": args.id, "action": args.agent_action,
                                    "payload": read_json(args.payload) if args.payload else {}})
        return connection.call({"operation": args.action, "id": args.id})
    if args.command in ("status", "cancel"):
        return getattr(jobs, args.command)(args.spool, args.id)
    if args.command == "collect":
        return jobs.collect(args.spool, args.id, args.output)
    if args.command == "rpc":
        return transport.endpoint(args.spool, json.load(sys.stdin))
    if args.command == "execute":
        return execution.execute_job(args.spool, args.id, read_json(Path(args.spool) / "profile.json"), via_agent=args.via_agent)
    if args.command == "worker":
        spool = Path(args.spool).resolve()
        profile = read_json(spool / "profile.json")
        worker_limits = profile.get("workerLimits", {})
        if not isinstance(worker_limits, dict):
            raise WorkError("WORKER_LIMITS_INVALID")
        if args.persistent and worker_limits.get("allowPersistent") is not True:
            raise WorkError("PERSISTENT_WORKER_NOT_ALLOWED")
        persistent = bool(args.persistent)
        max_jobs = args.max_jobs if args.max_jobs is not None else (worker_limits.get("maxJobs", 10) if persistent else 1)
        max_lifetime = (args.max_lifetime_seconds if args.max_lifetime_seconds is not None else
                        worker_limits.get("maxLifetimeSeconds", 3600))
        if type(max_jobs) is not int or not 1 <= max_jobs <= 100 or isinstance(max_lifetime, bool) or not isinstance(max_lifetime, (int, float)) or not 1 <= max_lifetime <= 86400:
            raise WorkError("WORKER_LIMITS_INVALID")
        started = time.monotonic()
        started_at = stamp()
        completed_jobs = 0
        stop_reason = "one-shot-complete"
        with FileLock(spool / "service.lock"):
            print("ITL worker ready. Mode: " + ("persistent" if persistent else "one-shot") +
                  ". Stop: Ctrl+C. Spool: " + str(spool), flush=True)
            try:
                while True:
                    profile = read_json(spool / "profile.json")
                    elapsed = time.monotonic() - started
                    if elapsed >= max_lifetime:
                        stop_reason = "max-lifetime"
                        break
                    write_json(spool / "worker.json", {"status": "ready", "pid": os.getpid(),
                               "mode": "persistent" if persistent else "one-shot", "startedAt": started_at,
                               "updatedAt": stamp(), "jobsProcessed": completed_jobs,
                               "hostMemory": host_memory_snapshot(),
                               "workerMemory": process_memory_snapshot(os.getpid())})
                    for package in sorted((spool / "jobs").glob("*")):
                        if package.name.startswith(".") or not package.is_dir():
                            continue
                        current = jobs.status(spool, package.name)
                        if current["status"] in ("queued", "running"):
                            try:
                                result = execution.execute_job(spool, package.name, profile)
                                print(json.dumps(result, ensure_ascii=True), flush=True)
                            except WorkError as error:
                                if str(error).startswith("OWNER_BUSY"):
                                    continue
                                write_json(spool / "state" / (package.name + ".json"),
                                           {"id": package.name, "status": "needs-attention", "error": str(error), "updatedAt": stamp()})
                            completed_jobs += 1
                            break
                    from itl_remote.agents import run_queued_controls
                    run_queued_controls(spool)
                    if not persistent:
                        break
                    if completed_jobs >= max_jobs:
                        stop_reason = "max-jobs"
                        break
                    time.sleep(1)
            finally:
                write_json(spool / "worker.json", {"status": "stopped", "pid": os.getpid(),
                           "mode": "persistent" if persistent else "one-shot", "startedAt": started_at,
                           "updatedAt": stamp(), "jobsProcessed": completed_jobs, "reason": stop_reason,
                           "hostMemory": host_memory_snapshot(),
                           "workerMemory": process_memory_snapshot(os.getpid())})
        return {"status": "stopped", "jobsProcessed": completed_jobs, "reason": stop_reason}


if __name__ == "__main__":
    try:
        value = main()
        print(json.dumps(value, ensure_ascii=True, allow_nan=False))
    except KeyboardInterrupt:
        print(json.dumps({"status": "interrupted"}))
        sys.exit(130)
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=True))
        sys.exit(1)
