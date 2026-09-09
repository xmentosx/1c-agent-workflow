#!/usr/bin/env python3
"""Portable CLI shared by local, SSH and remote-agent workflows (Python 3.11+)."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import time

from itl_remote.common import FileLock, WorkError, read_json, stamp, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("access-register")
    command.add_argument("--coordinator", required=True)
    command.add_argument("--resource", required=True)
    command.add_argument("--bindings", required=True, help="JSON array of explicit database connections sharing this resource")
    command = commands.add_parser("access-status")
    command.add_argument("--coordinator", required=True)
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
            command.add_argument("--once", action="store_true")
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
    args = parser.parse_args()
    from itl_remote import bootstrap, execution, jobs, profiling, transport
    if args.command in ("access-register", "access-status"):
        from itl_remote.access import Coordinator
        coordinator = Coordinator(args.coordinator)
        if args.command == "access-register":
            return coordinator.register(args.resource, read_json(args.bindings))
        return coordinator.snapshot()
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
        with FileLock(spool / "service.lock"):
            print("ITL worker ready. Stop: Ctrl+C. Spool: " + str(spool), flush=True)
            try:
                while True:
                    profile = read_json(spool / "profile.json")
                    write_json(spool / "worker.json", {"status": "ready", "pid": os.getpid(), "updatedAt": stamp()})
                    for package in sorted((spool / "jobs").glob("*")):
                        if package.name.startswith(".") or not package.is_dir():
                            continue
                        current = jobs.status(spool, package.name)
                        if current["status"] in ("queued", "running", "waiting-for-base"):
                            try:
                                result = execution.execute_job(spool, package.name, profile)
                                print(json.dumps(result, ensure_ascii=True), flush=True)
                            except WorkError as error:
                                if str(error).startswith("OWNER_BUSY"):
                                    continue
                                write_json(spool / "state" / (package.name + ".json"),
                                           {"id": package.name, "status": "needs-attention", "error": str(error), "updatedAt": stamp()})
                    from itl_remote.agents import run_queued_controls
                    run_queued_controls(spool)
                    if args.once:
                        return {"status": "stopped"}
                    time.sleep(1)
            finally:
                write_json(spool / "worker.json", {"status": "stopped", "pid": os.getpid(), "updatedAt": stamp()})


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
