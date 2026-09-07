"""Harness adapters. Agent prose is never a measurement result."""
from __future__ import annotations

import json
from pathlib import Path
import queue
import subprocess
import threading
import time
import uuid

from .common import FileLock, WorkError, capture, native_args, native_environment, read_json, stamp, write_json


class JsonRpcProcess:
    def __init__(self, command, cwd, output, env=None):
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        self.errors = (self.output / "transport.log").open("ab")
        self.process = subprocess.Popen(native_args(command), cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.errors, env=native_environment(env),
                                        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.messages = queue.Queue()
        self.serial = 0
        self.events = []
        self.control_handler = None
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line.decode("utf-8-sig")))
        except Exception as error:
            self.messages.put({"transportError": str(error)})
        finally:
            self.messages.put({"transportClosed": True})

    def send(self, value):
        self.process.stdin.write((json.dumps(value, ensure_ascii=True) + "\n").encode("utf-8"))
        self.process.stdin.flush()

    def receive(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            if self.control_handler:
                self.control_handler()
            try:
                message = self.messages.get(timeout=min(0.2, max(0.001, deadline-time.monotonic())))
                break
            except queue.Empty:
                if time.monotonic() >= deadline:
                    raise WorkError("AGENT_TIMEOUT")
        if message.get("transportError") or message.get("transportClosed"):
            raise WorkError("AGENT_TRANSPORT_CLOSED")
        if "method" in message and "id" in message:
            # Never auto-approve an application command or user-input request.
            write_json(self.output / "pending-request.json", message)
            while time.monotonic() < deadline:
                if self.control_handler:
                    self.control_handler()
                response_path = self.output / "approval-response.json"
                if response_path.exists():
                    response = read_json(response_path)
                    if response.get("requestId") != message["id"]:
                        raise WorkError("AGENT_RESPONSE_ID_MISMATCH")
                    self.send({"jsonrpc": "2.0", "id": message["id"], "result": response["result"]})
                    response_path.unlink()
                    (self.output / "pending-request.json").unlink()
                    return self.receive(max(0.01, deadline-time.monotonic()))
                time.sleep(0.1)
            raise WorkError("AGENT_INPUT_TIMEOUT: request saved; resume the saved thread explicitly")
        return message

    def call(self, method, params=None, timeout=60):
        self.serial += 1
        identifier = self.serial
        self.send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.receive(max(0.01, deadline - time.monotonic()))
            if message.get("id") == identifier:
                if "error" in message:
                    raise WorkError("AGENT_RPC_ERROR: " + json.dumps(message["error"], ensure_ascii=True))
                return message.get("result", {})
            self.events.append(message)
        raise WorkError("AGENT_TIMEOUT")

    def close(self):
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.errors.close()
        self.process.stdout.close()


def instruction(spool, request, scenario, diagnosis):
    payload = {"jobId": request["id"], "spool": str(Path(spool).resolve()), "scenario": scenario["id"],
               "target": request["target"], "operations": request["operations"],
               "request": str(Path(spool).resolve() / "jobs" / request["id"] / "request.json")}
    if diagnosis:
        task = ("Diagnose this interrupted ITL job using its state and results. Do not rerun it, update any base, "
                "or change its inputs. Write diagnosis.md in its runs directory. Explain the concrete recovery "
                "and whether side effects or cleanup remain uncertain. Recovery is a new authorized job.")
    else:
        task = ("Execute this ITL measurement job by calling the provided remote_work.py execute command with "
                "--via-agent, --spool and --id below, and the local worker profile. Use the SAME engine; "
                "do not implement timers or profiling yourself. Read the three ITL remote/performance skills "
                "if an operation needs clarification. Preserve the target, scenario and permissions. "
                "If execution requires approval, surface it; never bypass the host permission policy. "
                "Report the result.json produced by the engine. Do not claim that prose proves success.")
    return task + "\n" + json.dumps(payload, ensure_ascii=False, indent=2)


def desktop_connection(config):
    """Discovery returns the live app's command/environment, never a cached pipe."""
    if not config.get("discoverCommand"):
        raise WorkError("DESKTOP_DISCOVERY_NOT_CONFIGURED")
    discovered = json.loads(capture(config["discoverCommand"], timeout=30).decode("utf-8-sig"))
    if not discovered.get("command") or not discovered.get("contextThreadId"):
        raise WorkError("DESKTOP_DISCOVERY_INCOMPLETE")
    return discovered


def returned_identity(value):
    if isinstance(value, dict):
        if value.get("threadId") or value.get("clientThreadId"):
            return {k: value[k] for k in ("threadId", "clientThreadId", "hostId") if value.get(k)}
        for key in ("structuredContent", "content", "result"):
            found = returned_identity(value.get(key))
            if found:
                return found
        if value.get("type") == "text":
            try:
                return returned_identity(json.loads(value["text"]))
            except (ValueError, KeyError):
                pass
    elif isinstance(value, list):
        for item in value:
            found = returned_identity(item)
            if found:
                return found
    return {}


def dispatch(spool, request, profile, scenario, diagnosis=False, followup=None):
    spool = Path(spool)
    directory = spool / "agents" / request["id"]
    directory.mkdir(parents=True, exist_ok=True)
    connection = profile.get("agent", {})
    if connection.get("kind") not in ("codex-app-server", "codex-desktop"):
        raise WorkError("AGENT_NOT_CONFIGURED")
    with FileLock(directory / "owner.lock"):
        previous = read_json(directory / "state.json") if (directory / "state.json").exists() else {}
        if previous and followup is None:
            return previous  # no duplicate paid turn after disconnect/retry
        state = dict(previous, jobId=request["id"], status="connecting", diagnosisOnly=diagnosis, updatedAt=stamp(), active=True)
        for key in ("turnFinished", "turnId", "error", "interruptError", "engineMayStillBeRunning"):
            state.pop(key, None)
        write_json(directory / "state.json", state)
        if not diagnosis and followup is None:
            with FileLock(spool / "worker.lock"):
                current = read_json(spool / "state" / (request["id"] + ".json"))
                if current["status"] != "queued":
                    raise WorkError("AGENT_JOB_ALREADY_CLAIMED")
                current.update(status="agent-running", updatedAt=stamp())
                write_json(spool / "state" / (request["id"] + ".json"), current)
        prompt = instruction(spool, request, scenario, diagnosis)
        prompt += "\nRuntime: " + str(Path(__file__).resolve().parent.parent / "remote_work.py")
        prompt += "\nWorker profile: " + str(profile.get("profilePath", ""))
        if followup is not None:
            prompt = followup + "\nOriginal immutable assignment/context:\n" + prompt
        write_json(directory / "assignment.json", {"prompt": prompt})
        client = None
        try:
            timeout = connection.get("timeoutSeconds", 900)
            if connection["kind"] == "codex-app-server":
                client = JsonRpcProcess(connection.get("command", ["codex", "app-server"]),
                                        profile["targets"][request["target"]]["workspace"], directory)
                client.call("initialize", {"clientInfo": {"name": "itl-remote-work", "version": "1.0.0"}})
                client.send({"method": "initialized", "params": {}})
                parameters = {"cwd": profile["targets"][request["target"]]["workspace"]}
                if connection.get("model"):
                    parameters["model"] = connection["model"]
                # Retain the host's configured sandbox/approval policy.
                if previous.get("threadId"):
                    parameters["threadId"] = previous["threadId"]
                thread = client.call("thread/resume" if previous.get("threadId") else "thread/start", parameters)["thread"]
                state.update(threadId=thread["id"], status="assigned")
                write_json(directory / "state.json", state)
                turn = client.call("turn/start", {"threadId": thread["id"], "input": [{"type": "text", "text": prompt}]})
                state["turnId"] = turn.get("turn", {}).get("id")
                write_json(directory / "state.json", state)
                def live_control():
                    if (directory / "interrupt.json").exists() or (spool / "control" / (request["id"] + ".cancel.json")).exists():
                        raise WorkError("AGENT_INTERRUPT_REQUESTED")
                client.control_handler = live_control
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    message = client.events.pop(0) if client.events else client.receive(max(0.01, deadline - time.monotonic()))
                    if message.get("method") == "turn/completed":
                        state["turnStatus"] = message.get("params", {}).get("turn", {}).get("status")
                        state["turnFinished"] = True
                        break
                else:
                    raise WorkError("AGENT_TIMEOUT")
            else:
                discovered = desktop_connection(connection)
                client = JsonRpcProcess(discovered["command"], discovered.get("cwd"), directory, discovered.get("env"))
                client.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                           "clientInfo": {"name": "itl-remote-work", "version": "1.0.0"}})
                client.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
                tools = client.call("tools/list").get("tools", [])
                names = {tool["name"] for tool in tools}
                schemas = {tool["name"]: tool.get("inputSchema", {}) for tool in tools}
                if not {"send_message_to_thread", "read_thread"} <= names or any("threadId" not in schemas[n].get("properties", {}) for n in ("send_message_to_thread", "read_thread")):
                    raise WorkError("DESKTOP_TOOLS_INCOMPATIBLE")
                def tool(name, arguments):
                    value = client.call("tools/call", {"name": name, "arguments": arguments,
                                        "_meta": {"openai/threadId": discovered["contextThreadId"]}}, timeout=timeout)
                    if value.get("isError"):
                        raise WorkError("DESKTOP_TOOL_FAILED: " + json.dumps(value, ensure_ascii=True))
                    return value
                thread_id = previous.get("threadId") or connection.get("threadId")
                created_with_prompt = False
                if not thread_id:
                    creation = connection.get("createThread")
                    if not isinstance(creation, dict) or "target" not in creation:
                        raise WorkError("DESKTOP_TARGET_THREAD_OR_CREATION_REQUIRED")
                    if "create_thread" not in names:
                        raise WorkError("DESKTOP_CREATE_UNAVAILABLE")
                    state["status"] = "creating-task"
                    write_json(directory / "state.json", state)
                    created = returned_identity(tool("create_thread", dict(creation, prompt=prompt)))
                    state.update(created)
                    write_json(directory / "state.json", state)
                    thread_id = created.get("threadId")
                    if not thread_id:
                        raise WorkError("DESKTOP_CREATION_PENDING: inspect saved clientThreadId; do not repeat creation")
                    created_with_prompt = True
                state.update(threadId=thread_id, status="assigned")
                write_json(directory / "state.json", state)
                if not created_with_prompt:
                    tool("send_message_to_thread", {"threadId": thread_id, "prompt": prompt})
                # Read-only snapshot. Desktop owns ongoing execution after this bridge exits.
                write_json(directory / "snapshot.json", tool("read_thread", {"threadId": thread_id, "turnLimit": 1}))
                state["status"] = "assigned"
            result_path = spool / "runs" / request["id"] / "result.json"
            if result_path.exists() and not diagnosis:
                result = read_json(result_path)
                state["status"] = result["status"]
            elif diagnosis:
                state["status"] = "diagnosis-returned" if (spool / "runs" / request["id"] / "diagnosis.md").exists() else "assigned"
            elif connection["kind"] == "codex-app-server":
                raise WorkError("AGENT_RETURNED_WITHOUT_ENGINE_RESULT")
        except Exception as error:
            state.update(status="needs-attention", error=str(error))
            if not diagnosis:
                try:
                    with FileLock(spool / "worker.lock"):
                        current = read_json(spool / "state" / (request["id"] + ".json"))
                        if current["status"] == "agent-running":
                            current.update(status="needs-attention", error=str(error), updatedAt=stamp())
                            write_json(spool / "state" / (request["id"] + ".json"), current)
                except WorkError as ownership:
                    if not str(ownership).startswith("OWNER_BUSY"):
                        raise
                    state["engineMayStillBeRunning"] = True
        finally:
            if client:
                client.control_handler = None
                if connection["kind"] == "codex-app-server" and state.get("turnId") and not state.get("turnFinished"):
                    try:
                        client.call("turn/interrupt", {"threadId": state["threadId"], "turnId": state["turnId"]}, timeout=5)
                    except Exception as error:
                        state["interruptError"] = str(error)
                client.close()
            state["active"] = False
            state["updatedAt"] = stamp()
            write_json(directory / "state.json", state)
        return state


def queue_followup(spool, identifier, payload):
    """SSH only queues work: the logged-in worker owns agent process creation."""
    from .jobs import job_id
    from .common import identity
    directory = Path(spool) / "agents" / job_id(identifier)
    read_json(directory / "state.json")
    if not payload.get("prompt") or not payload.get("controlId"):
        raise WorkError("REMOTE_FOLLOWUP_PROMPT_AND_CONTROL_ID_REQUIRED")
    path = directory / "controls" / (job_id(payload["controlId"]) + ".json")
    with FileLock(path.with_suffix(".lock")):
        if path.exists():
            previous = read_json(path)
            if identity(previous["payload"]) != identity(payload):
                raise WorkError("AGENT_CONTROL_ID_CONTENT_CONFLICT")
            return {"controlId": payload["controlId"], "status": previous["status"]}
        write_json(path, {"jobId": identifier, "payload": payload, "status": "queued", "updatedAt": stamp()})
    return {"controlId": payload["controlId"], "status": "queued"}

def run_queued_controls(spool):
    for path in sorted((Path(spool) / "agents").glob("*/controls/*.json")):
        with FileLock(path.with_suffix(".lock")):
            request = read_json(path)
            if request["status"] != "queued":
                continue
            # Persist intent before the paid call. A crashed dispatched request is inspected, never replayed.
            request.update(status="dispatched", updatedAt=stamp())
            write_json(path, request)
        try:
            result = control(spool, request["jobId"], "followup", request["payload"])
            request.update(status="returned", result=result)
        except Exception as error:
            request.update(status="needs-attention", error=str(error))
        request["updatedAt"] = stamp()
        write_json(path, request)


def control(spool, identifier, action, payload):
    """Explicit controls; retrying status never starts another paid turn."""
    from .jobs import job_id, validate_package
    directory = Path(spool) / "agents" / job_id(identifier)
    state = read_json(directory / "state.json")
    profile = read_json(Path(spool) / "profile.json")
    config = profile.get("agent", {})
    # Probe the OS lock: the persisted active flag can be stale after a crash.
    active = False
    try:
        with FileLock(directory / "owner.lock"):
            pass
    except WorkError as error:
        if not str(error).startswith("OWNER_BUSY"):
            raise
        active = True
    if action == "read":
        value = dict(state, active=active)
        value["controls"] = [{"controlId": p.stem, "status": read_json(p)["status"]}
                             for p in sorted((directory / "controls").glob("*.json"))]
        if (directory / "pending-request.json").exists():
            value["pendingRequest"] = read_json(directory / "pending-request.json")
        if (directory / "snapshot.json").exists():
            value["lastSnapshot"] = read_json(directory / "snapshot.json")
        if active or not state.get("threadId"):
            return value
        if config.get("kind") == "codex-app-server":
            client = JsonRpcProcess(config.get("command", ["codex", "app-server"]),
                                    profile["targets"][read_json(Path(spool) / "jobs" / identifier / "request.json")["target"]]["workspace"], directory)
            try:
                client.call("initialize", {"clientInfo": {"name": "itl-remote-work", "version": "1.0.0"}})
                client.send({"method": "initialized", "params": {}})
                value["snapshot"] = client.call("thread/read", {"threadId": state["threadId"], "includeTurns": True})
                return value
            finally:
                client.close()
    if action == "respond":
        if not active:
            raise WorkError("AGENT_CONNECTION_ENDED: resume saved thread with explicit followup")
        pending = read_json(directory / "pending-request.json")
        if payload.get("requestId") != pending["id"] or "result" not in payload:
            raise WorkError("AGENT_RESPONSE_ID_OR_RESULT_INVALID")
        write_json(directory / "approval-response.json", payload)
        return {"status": "response-queued"}
    if action == "interrupt" and active:
        write_json(directory / "interrupt.json", {"at": stamp()})
        return {"status": "interrupt-requested"}
    if config.get("kind") == "codex-desktop":
        discovered = desktop_connection(config)
        client = JsonRpcProcess(discovered["command"], discovered.get("cwd"), directory, discovered.get("env"))
        try:
            client.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "itl-remote-work", "version": "1.0.0"}})
            client.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
            name = {"followup": "send_message_to_thread", "interrupt": "interrupt_thread", "read": "read_thread"}[action]
            schemas = {t["name"]: t for t in client.call("tools/list").get("tools", [])}
            if name not in schemas:
                raise WorkError("DESKTOP_CONTROL_UNAVAILABLE: " + name)
            args = {"threadId": state["threadId"]}
            if action == "followup":
                if not payload.get("prompt"):
                    raise WorkError("FOLLOWUP_PROMPT_REQUIRED")
                args["prompt"] = payload["prompt"]
            result = client.call("tools/call", {"name": name, "arguments": args,
                                "_meta": {"openai/threadId": discovered["contextThreadId"]}})
            if result.get("isError"):
                raise WorkError("DESKTOP_CONTROL_FAILED: " + json.dumps(result))
            if action == "read":
                write_json(directory / "snapshot.json", result)
                return dict(value, snapshot=result)
            return result
        finally:
            client.close()
    if action == "interrupt":
        raise WorkError("AGENT_CONNECTION_ENDED: no live owned turn")
    if active:
        raise WorkError("AGENT_BUSY: respond or interrupt the current turn first")
    if not payload.get("prompt"):
        raise WorkError("FOLLOWUP_PROMPT_REQUIRED")
    for name in ("interrupt.json", "pending-request.json", "approval-response.json"):
        path = directory / name
        if path.exists():
            path.rename(directory / (str(uuid.uuid4()) + "-" + name))
    request, scenario = validate_package(Path(spool) / "jobs" / identifier)
    return dispatch(spool, request, profile, scenario, diagnosis=state.get("diagnosisOnly", False), followup=payload["prompt"])
