"""The same measurement engine runs locally, in the SSH worker and for an AI agent."""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import platform
import statistics
import sys
import time

from .common import FileLock, OwnedProcess, WorkError, digest, identity, read_json, stamp, write_json
from .jobs import authorize, job_id, status, validate_package
from .profiling import Rdbg, prepare_debug_server, required_profile_types
from .access import Lease, target_access
from .deadlines import Deadline, budgets


def render(command, variables):
    result = []
    for value in command:
        for key, replacement in variables.items():
            value = value.replace("{" + key + "}", str(replacement))
        result.append(value)
    return result


def wait_json(path, process, timeout, cancelled):
    deadline = timeout if isinstance(timeout, Deadline) else Deadline("ready", timeout)
    while not path.exists():
        if cancelled():
            raise WorkError("CANCELLED")
        if process.process.poll() is not None:
            raise WorkError("WORKLOAD_EXITED_WITHOUT_SIGNAL: " + path.name)
        deadline.remaining()
        time.sleep(0.01)
    return read_json(path)


def run_measurement(package, target, run, request, scenario, cancelled, progress, *, access_lease=None, access_scope=None, cancel_path=None):
    run = Path(run)
    run.mkdir(parents=True, exist_ok=True)
    variables = {"python": sys.executable, "runtime": Path(__file__).resolve().parent.parent,
                 "workspace": Path(target["workspace"]).resolve(), "input": Path(package) / "input",
                 "run": run, "context": run / "context.json"}
    phase_budgets = budgets(scenario)
    context = {"schemaVersion": 1, "jobId": request["id"], "parameters": request["parameters"],
               "target": target, "scenarioId": scenario["id"], "operations": request["operations"],
               "phaseTimeoutSeconds": phase_budgets, "cancelPath": str(cancel_path) if cancel_path else None}
    child_environment = {"ITL_RUN_CONTEXT": str(variables["context"])}
    if access_lease:
        context["accessLease"] = access_lease.proof()
        child_environment["ITL_INFOBASE_ACCESS_LEASE"] = json.dumps(context["accessLease"])
    # This file is machine-local, not included in the user-facing result archive.
    write_json(variables["context"], context)
    commands = scenario["commands"]
    processes = []
    profile_paths = []
    profiler = None
    result = {"schemaVersion": 1, "jobId": request["id"], "scenarioId": scenario["id"],
              "requestSha256": identity(request), "scenarioSha256": request["scenarioSha256"],
              "scenarioInputsSha256": identity(request["files"]),
              "parameters": request["parameters"], "dataIdentity": scenario["dataIdentity"],
              "sourceIdentity": target.get("sourceIdentity"), "host": platform.node(),
              "environmentIdentity": target.get("environmentIdentity"),
              "identityEvidence": "declared-by-profile-and-scenario; runtime adapters own exact loaded-data/source proof",
              "readiness": scenario["readyDescription"], "mode": request["mode"],
              "startedAt": stamp(), "timings": [], "profiles": [], "phases": [],
              "status": "running", "limitations": [], "cleanupErrors": []}
    if access_lease:
        result["access"] = {"scope": access_scope, "ticket": access_lease.record["ticket"],
                            "resources": access_lease.record["resources"], "waitSeconds": access_lease.wait_seconds}

    def start_phase(name):
        deadline = Deadline(name, phase_budgets[name], cancel_path=context["cancelPath"])
        context["phase"] = deadline.record()
        write_json(variables["context"], context)
        progress(name)
        return deadline

    def command(name, deadline=None):
        if name not in commands:
            return
        if cancelled() and name != "cleanup":
            raise WorkError("CANCELLED")
        deadline = deadline or start_phase(name)
        deadline.remaining()
        begin = time.monotonic()
        record = {"name": name, "startedAt": stamp(), "status": "running", "timeoutSeconds": deadline.timeout}
        result["phases"].append(record)
        write_json(run / "progress.json", {"jobId": request["id"], "phases": result["phases"]})
        process = OwnedProcess(render(commands[name], variables), variables["workspace"], run / (name + ".log"),
                               child_environment)
        processes.append(process)
        try:
            process.wait(deadline.remaining(), cancelled if name != "cleanup" else lambda: False)
            record["status"] = "completed"
        except Exception as error:
            record.update(status="failed", error=str(error))
            # Stop this command's owned tree before starting recovery/cleanup.
            # A persistent adapter started by prepare has its separate owner.
            try:
                process.close()
            except Exception as cleanup:
                result["cleanupErrors"].append(str(cleanup))
            raise
        finally:
            record["seconds"] = time.monotonic() - begin
            write_json(run / "progress.json", {"jobId": request["id"], "phases": result["phases"]})

    def open_profiler(iteration):
        proof = read_json(run / "runtime-proof.json")
        if proof.get("jobId") != request["id"]:
            raise WorkError("RDBG_STALE_OWNERSHIP_PROOF")
        client_pid = proof.get("clientPid")
        if not isinstance(client_pid, int) or client_pid <= 0:
            raise WorkError("RDBG_OWNED_CLIENT_PID_REQUIRED")
        launch_path = run / ("onec-process-%d.json" % client_pid)
        launch = read_json(launch_path)
        if launch.get("pid") != client_pid or launch.get("jobId") != request["id"] or launch.get("infoBase") != target.get("infoBase"):
            raise WorkError("RDBG_FOREIGN_CLIENT_LAUNCH")
        from .common import capture
        capture(["powershell.exe", "-NoProfile", "-File", str(variables["runtime"] / "Test-OneCProcessRecord.ps1"),
                 "-RecordPath", str(launch_path)], timeout=20)
        proof["requiredTypes"] = required_profile_types(target.get("infoBase", {}).get("kind"))
        collector = Rdbg({**effective_rdbg, "sourceAnalysis": scenario.get("sourceAnalysis", "none"),
                          "sourceAnalysisModules": scenario.get("sourceAnalysisModules")}, proof, iteration / "raw")
        collector.open()
        return collector

    try:
        command("update")
        if request["mode"] != "time":
            effective_rdbg = prepare_debug_server(target, run, processes, cancelled)
            context["rdbg"] = effective_rdbg
            write_json(variables["context"], context)
        else:
            effective_rdbg = None
        command("prepare")
        repeatable = scenario["repeatable"]
        iterations = []
        if request["mode"] != "profile":
            iterations += ["warmup"] * (request["warmups"] if repeatable else 0)
            iterations += ["time"] * (request["repeats"] if repeatable else 1)
        if request["mode"] != "time":
            if repeatable or not iterations:
                iterations.append("profile")
            else:
                result["limitations"].append("Profile omitted: a second mutating/non-repeatable run needs a reset contract.")
        for index, kind in enumerate(iterations):
            validate_package(package)
            if index:
                command("reset")
            iteration = run / ("%03d-%s" % (index, kind))
            iteration.mkdir()
            variables["iteration"] = iteration
            context.update(iteration=str(iteration), iterationKind=kind, iterationIndex=index)
            write_json(variables["context"], context)
            progress(kind)
            if kind == "profile":
                if not effective_rdbg:
                    result["limitations"].append("RDBG is not configured; requested profile is unavailable.")
                    continue
            if scenario.get("adapter", "command") == "handshake":
                readiness_deadline = start_phase("ready")
                process = OwnedProcess(render(commands["action"], variables), variables["workspace"],
                                       iteration / "action.log", child_environment)
                processes.append(process)
                ready = wait_json(iteration / "ready.json", process, readiness_deadline, cancelled)
                if ready.get("jobId") != request["id"] or ready.get("ready") is not True:
                    raise WorkError("WORKLOAD_READINESS_UNPROVEN")
                if kind == "profile":
                    profiler = open_profiler(iteration)
                if profiler:
                    profiler.start()
                action_deadline = start_phase("action")
                begin = time.monotonic_ns()
                write_json(iteration / "go.json", {"jobId": request["id"], "startedNs": begin, "phase": action_deadline.record()})
                done = wait_json(iteration / "done.json", process, action_deadline, cancelled)
                end = time.monotonic_ns()
                if done.get("jobId") != request["id"] or done.get("ready") is not True:
                    raise WorkError("WORKLOAD_COMPLETION_UNPROVEN")
                process.wait(action_deadline.remaining(), cancelled)
                command("ready")
                if "ready" in commands:
                    end = time.monotonic_ns()
                elif "startedNs" in done or "finishedNs" in done:
                    a, b = done.get("startedNs"), done.get("finishedNs")
                    if not isinstance(a, int) or not isinstance(b, int) or not begin <= a <= b <= end:
                        raise WorkError("WORKLOAD_CLOCK_INVALID")
                    begin, end = a, b
            else:
                if kind == "profile":
                    profiler = open_profiler(iteration)
                if profiler:
                    profiler.start()
                begin = time.monotonic_ns()
                command("action")
                command("ready")
                end = time.monotonic_ns()
            if profiler:
                try:
                    profile_result = profiler.finish()
                    result["profiles"].append(profile_result)
                    profile_paths.append(iteration / "profile.json")
                    if not profile_result["complete"]:
                        result["limitations"].append("PROFILE_INCOMPLETE: " + json.dumps(profile_result.get("coverage", {}), ensure_ascii=False))
                finally:
                    profiler.close()
                    profiler = None
            command("verify")
            verification = read_json(iteration / "verification.json")
            checks = verification.get("checks")
            if verification.get("jobId") != request["id"] or verification.get("passed") is not True or not isinstance(checks, list) or not checks or any(not isinstance(c, dict) or not c.get("name") or c.get("passed") is not True for c in checks):
                raise WorkError("SCENARIO_VERIFICATION_FAILED")
            if kind == "time":
                result["timings"].append({"iteration": index, "seconds": (end - begin) / 1e9,
                                          "profileEnabled": False, "verified": True})
        source_policy = scenario.get("sourceAnalysis", "none")
        if source_policy != "none" and result["profiles"]:
            from .source_analysis import resolve_sources
            resolve_sources(variables["context"], result["profiles"], profile_paths, source_policy,
                            scenario.get("sourceAnalysisModules"), start_phase("source-capture"), result)
        elif source_policy == "required":
            raise WorkError("SOURCE_ANALYSIS_PROFILE_UNAVAILABLE")
        result["status"] = "partial" if result["limitations"] else "completed"
    except Exception as error:
        result["status"] = "cancelled" if str(error) == "CANCELLED" else "needs-attention"
        result["error"] = str(error)
        result["cleanupErrors"].extend(getattr(error, "cleanup_errors", []))
    finally:
        if profiler:
            try:
                profiler.close()
            except Exception as error:
                result["cleanupErrors"].append(str(error))
        try:
            command("cleanup")
        except Exception as error:
            result["cleanupErrors"].append(str(error))
        for process in reversed(processes):
            try:
                process.close()
            except Exception as error:
                result["cleanupErrors"].append(str(error))
        if result["cleanupErrors"]:
            result["status"] = "needs-attention"
        result["finishedAt"] = stamp()
        seconds = [item["seconds"] for item in result["timings"]]
        result["summary"] = {"count": len(seconds), "medianSeconds": statistics.median(seconds) if seconds else None,
                             "minSeconds": min(seconds) if seconds else None, "maxSeconds": max(seconds) if seconds else None}
        write_json(run / "result.json", result)
        report(run, result)
    return result


def report(run, result):
    summary = result["summary"]
    lines = ["# " + result["scenarioId"], "", "Status: " + result["status"], "",
             "Readiness: " + result["readiness"], "",
             "Unprofiled operation time; transport, setup and cleanup are separate.", "",
             "| Run | Seconds |", "|---|---:|"]
    lines += ["| %s | %.6f |" % (r["iteration"], r["seconds"]) for r in result["timings"]]
    lines += ["", "Median: " + str(summary["medianSeconds"]), "",
              "A small sample is diagnostic evidence, not statistical proof of a speedup.", "",
              "Profiles: %d; native PFF: not produced." % len(result["profiles"])]
    lines += ["", *result["limitations"]]
    if result.get("error"):
        lines += ["", "Error: " + result["error"]]
    (Path(run) / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def compare(left, right):
    left, right = read_json(left), read_json(right)
    incompatible = [key for key in ("scenarioSha256", "scenarioInputsSha256", "parameters", "dataIdentity", "host", "environmentIdentity", "readiness")
                    if left.get(key) != right.get(key) or left.get(key) is None]
    if incompatible:
        raise WorkError("INCOMPARABLE_RUNS: " + ", ".join(incompatible))
    a, b = left["summary"]["medianSeconds"], right["summary"]["medianSeconds"]
    if left["status"] not in ("completed", "partial") or right["status"] not in ("completed", "partial") or not a or b is None:
        raise WorkError("VALIDATED_TIMING_REQUIRED")
    return {"kind": "historical-comparison", "baseline": left["jobId"], "candidate": right["jobId"],
            "baselineSeconds": a, "candidateSeconds": b, "differenceSeconds": b - a,
            "differencePercent": 100 * (b / a - 1), "statisticalProof": False,
            "sourceIdentity": [left.get("sourceIdentity"), right.get("sourceIdentity")]}


def execute_job(spool, identifier, profile, *, via_agent=False):
    spool = Path(spool).resolve()
    identifier = job_id(identifier)
    request, scenario = validate_package(spool / "jobs" / identifier)
    authorize(request, scenario, profile)
    if request["route"] == "agent" and not via_agent:
        from .agents import dispatch
        return dispatch(spool, request, profile, scenario)
    # One claim per job prevents replay without serializing unrelated databases.
    with FileLock(spool / "claims" / (identifier + ".lock")):
        state = status(spool, identifier)
        if state["status"] != "queued" and not (via_agent and state["status"] == "agent-running"):
            if state["status"] in ("running", "waiting-for-base"):
                state.update(status="needs-attention", error="INTERRUPTED_OWNER: inspect effects; no automatic replay", updatedAt=stamp())
                write_json(spool / "state" / (identifier + ".json"), state)
            return state
        package = spool / "jobs" / identifier
        request, scenario = validate_package(package)
        target = authorize(request, scenario, profile)
        cancelled = lambda: (spool / "control" / (identifier + ".cancel.json")).exists()
        if cancelled():
            state.update(status="cancelled", updatedAt=stamp())
            write_json(spool / "state" / (identifier + ".json"), state)
            return state
        access = target_access(target)
        profile_path = spool / "profile.json"
        profile_fingerprint = digest(profile_path) if profile_path.is_file() else None
        def waiting(record):
            state.update(status="waiting-for-base", phase="admission", access=record, ownerPid=os.getpid(), updatedAt=stamp())
            write_json(spool / "state" / (identifier + ".json"), state)
        def progress(phase):
            state.update(status="running", phase=phase, ownerPid=os.getpid(), updatedAt=stamp())
            write_json(spool / "state" / (identifier + ".json"), state)
        result = None
        try:
            inherited = json.loads(os.environ["ITL_INFOBASE_ACCESS_LEASE"]) if os.environ.get("ITL_INFOBASE_ACCESS_LEASE") else None
            with Lease(access["coordinator"], access["bases"], {"jobId": identifier, "workspace": target["workspace"],
                       "operation": "measure"}, timeout=access["timeout"], cancelled=cancelled,
                       progress=waiting, inherited=inherited) as lease:
                # Revalidate immutable inputs and target authorization after the
                # queue. Actual loaded configuration/data checks belong to prepare.
                request, scenario = validate_package(package)
                if profile_fingerprint and digest(profile_path) != profile_fingerprint:
                    raise WorkError("INFOBASE_ACCESS_TARGET_CHANGED: worker profile changed during admission")
                current_target = authorize(request, scenario, profile)
                if target_access(current_target) != access:
                    raise WorkError("INFOBASE_ACCESS_TARGET_CHANGED")
                progress("preparing")
                result = run_measurement(package, current_target, spool / "runs" / identifier, request, scenario, cancelled,
                                         progress, access_lease=lease, access_scope=access["scope"],
                                         cancel_path=spool / "control" / (identifier + ".cancel.json"))
                lease.release(cleanup_errors=result["cleanupErrors"])
                state.update(status=result["status"], phase="finished", access=result.get("access"),
                             result=str(spool / "runs" / identifier / "result.json"), updatedAt=stamp())
                if result.get("error"):
                    state["error"] = result["error"]
                write_json(spool / "state" / (identifier + ".json"), state)
        except WorkError as error:
            state.update(status="cancelled" if str(error) == "INFOBASE_ACCESS_CANCELLED" else "needs-attention",
                         error=str(error), updatedAt=stamp())
            write_json(spool / "state" / (identifier + ".json"), state)
            return state
    if result["status"] == "needs-attention" and request["route"] == "auto" and profile.get("agentFallback") and not via_agent:
        from .agents import dispatch
        dispatch(spool, request, profile, scenario, diagnosis=True)
    return state


def tempfile_root():
    import tempfile
    return tempfile.gettempdir()
