"""Job-owned adapter using the public ITL facade's MCP stdio surface."""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time
import uuid

from .common import WorkError, digest, native_environment, read_json, write_json
from .deadlines import Deadline


class StdioMcp:
    def __init__(self, command, directory, environment, log, timeout=300, *, deadline=None):
        self.timeout, self.serial = timeout, 0
        self.deadline = deadline
        self.uncertain = False
        self.closed = False
        self.close_error = None
        self.messages = queue.Queue()
        self.stderr = Path(log).open("wb")
        try:
            self.process = subprocess.Popen(command, cwd=directory, env=environment,
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                            text=True, encoding="utf-8", errors="strict", bufsize=1)
        except BaseException:
            self.stderr.close()
            raise
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        try:
            self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                       "clientInfo": {"name": "itl-performance", "version": "1"}})
            self.notify("notifications/initialized", {})
        except BaseException as primary:
            try:
                self.close()
            except Exception as cleanup:
                combined = WorkError(str(primary) + "; " + str(cleanup))
                combined.cleanup_errors = [str(cleanup)]
                raise combined from primary
            raise

    def _read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put(error)
        finally:
            self.messages.put(EOFError("ITL_FACADE_STDIO_CLOSED"))

    def notify(self, method, params):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method, "params": params}) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        if self.uncertain:
            raise WorkError("ITL_FACADE_PREVIOUS_REQUEST_UNCERTAIN: cleanup required")
        deadline = self.deadline or Deadline("action", self.timeout)
        remaining = deadline.remaining()
        if method == "tools/call" and self.deadline:
            params = {**params, "_meta": {"itlPhaseRemainingMs": remaining * 1000}}
        self.serial += 1
        identifier = self.serial
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        try:
            while True:
                try:
                    message = self.messages.get(timeout=min(deadline.remaining(), 0.1))
                except queue.Empty:
                    continue
                if isinstance(message, BaseException):
                    raise message
                if message.get("id") != identifier:
                    continue  # progress/log notifications are not command completion
                if "error" in message:
                    raise WorkError("ITL_FACADE_RPC_FAILED: " + str(message["error"]))
                return message["result"]
        except BaseException:
            self.uncertain = True
            with contextlib.suppress(BrokenPipeError, OSError):
                self.notify("notifications/cancelled", {"requestId": identifier, "reason": "phase ended"})
            raise

    def tool(self, name, arguments):
        result = self.request("tools/call", {"name": "call_tool", "arguments": {
            "name": name, "argumentsJson": json.dumps(arguments, ensure_ascii=False)}})
        if result.get("isError"):
            raise WorkError("ITL_FACADE_TOOL_FAILED: " + name + ": " + result_text(result))
        return result

    def close(self):
        if self.closed:
            if self.close_error:
                raise self.close_error
            return
        self.closed = True
        if self.process.stdin:
            with contextlib.suppress(BrokenPipeError, OSError):
                self.process.stdin.close()  # facade owns and releases its manager/TestClient
        forced = False
        try:
            # Cleanup has its own budget; an expired action never cancels cleanup.
            timeout = self.deadline.remaining() if self.deadline and self.deadline.phase in ("cleanup", "source-capture") else 60
            self.process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, WorkError):
            forced = True
            self.process.kill()  # only this job's facade; engine job contains descendants
            self.process.wait(timeout=5)
        self.reader.join(timeout=1)
        if self.process.stdout:
            self.process.stdout.close()
        self.stderr.close()
        if forced or self.process.returncode:
            self.close_error = WorkError("ITL_FACADE_CLEANUP_UNPROVEN: forced=" + str(forced)
                                         + "; exit=" + str(self.process.returncode))
            raise self.close_error


def result_text(result):
    return "\n".join(item.get("text", "") for item in result.get("content", []) if item.get("type") == "text")


def assert_scenario_success(result):
    text = result_text(result)
    if not re.search(r"(?m)^- Статус: Success\s*$", text):
        raise WorkError("VANESSA_SCENARIO_FAILED: " + text)
    steps = re.search(r"(?m)^## Шаги \(([0-9]+)\)", text)
    if not steps or int(steps[1]) == 0 or "**Failed**" in text:
        raise WorkError("VANESSA_SCENARIO_EVIDENCE_INVALID")


def own_launch(run, context):
    records = [read_json(path) for path in Path(run).glob("onec-process-*.json")]
    records = [r for r in records if r.get("jobId") == context["jobId"]]
    if len(records) != 1 or records[0].get("infoBase") != context["target"].get("infoBase"):
        raise WorkError("ITL_PERFORMANCE_OWNED_CLIENT_REQUIRED")
    record = records[0]
    if (record.get("ownershipKind") != "itl-broker" or not record.get("instanceId")
            or type(record.get("pid")) is not int or record["pid"] <= 0 or not record.get("startedAt")):
        raise WorkError("ITL_PERFORMANCE_BROKER_LAUNCH_REQUIRED")
    return records[0]


def run_feature(client, path, output):
    path, output = Path(path).resolve(), Path(output)
    before = digest(path)
    runtime = client.tool("run_scenario", {"filePath": str(path), "mode": "reloadAndRun"})
    result = client.tool("get_test_results", {})
    write_json(output, {"feature": str(path), "sha256": before, "runtime": runtime, "results": result})
    if digest(path) != before:
        raise WorkError("VANESSA_FEATURE_CHANGED_DURING_RUN")
    assert_scenario_success(result)
    return {"featureSha256": before, "resultsPath": str(output), "passed": True}


def daemon(context_path, setup_feature):
    context_path = Path(context_path).resolve()
    run = context_path.parent
    context = read_json(context_path)
    control = run / "vanessa-control"
    client = None
    cleanup_errors = []
    try:
        va = context["target"]["vanessa"]
        for key in ("facade", "helper", "catalog"):
            if not Path(va[key]).is_file():
                raise WorkError("ITL_VANESSA_INPUT_REQUIRED: " + key)
        environment = native_environment({"ITL_PERFORMANCE_CONTEXT": str(context_path)}, windows_powershell=True)
        command = [va["facade"], "serve", "--family", "vanessa-ui", "--project-root", context["target"]["workspace"],
                   "--helper", va["helper"], "--catalog", va["catalog"], "--idle-timeout", "1h",
                   "--cleanup-timeout", str(context.get("phaseTimeoutSeconds", {}).get("cleanup", 300)) + "s"]
        client = StdioMcp(command, context["target"]["workspace"], environment, run / "vanessa-facade.log",
                          deadline=Deadline.from_context(context))
        client.tool("connect_test_client", {"profileName": "itl-ondemand"})
        launch = own_launch(run, context)
        run_feature(client, setup_feature, run / "vanessa-setup.json")
        # The pinned native extension step obtains this value in the owned TestClient, not the manager base.
        variable = "ITLPerformanceSessionNumber"
        feature = run / "vanessa-session.feature"
        feature.write_text('#language: ru\nФункционал: Сеанс профилирования\nСценарий: Прочитать собственный сеанс\n'
                           '\tИ Я запоминаю значение выражения на сервере '
                           "'ПолучитьТекущийСеансИнформационнойБазы().НомерСеанса' в переменную '"
                           + variable + "' (Расширение)\n", encoding="utf-8")
        run_feature(client, feature, run / "vanessa-session-result.json")
        observation_result = client.tool("manage_variables", {"action": "get", "name": variable})
        write_json(run / "vanessa-session-value.json", observation_result)
        number = re.findall(r"(?m)^- Значение: ([0-9]+)\s*$", result_text(observation_result))
        if len(number) != 1 or int(number[0]) <= 0:
            raise WorkError("ITL_PERFORMANCE_SESSION_NUMBER_UNPROVEN")
        if own_launch(run, context) != launch:
            raise WorkError("ITL_PERFORMANCE_CLIENT_CHANGED_DURING_PREPARE")
        write_json(run / "session-observation.json", {"jobId": context["jobId"], "clientPid": launch["pid"],
                   "clientStartedAt": launch["startedAt"], "sessionNumber": int(number[0])})
        if context.get("rdbg"):
            from .profiling import runtime_proof
            runtime_proof(context_path, launch["pid"], observation_path="session-observation.json")
        write_json(control / "prepared.json", {"jobId": context["jobId"], "clientPid": launch["pid"]})
        while True:
            requests = sorted(control.glob("request-*.json"))
            for path in requests:
                response = path.with_name(path.name.replace("request-", "response-"))
                if response.exists():
                    continue
                request = read_json(path)
                if request.get("jobId") != context["jobId"]:
                    raise WorkError("ITL_PERFORMANCE_FOREIGN_REQUEST")
                client.deadline = Deadline.from_context(context, phase=request.get("phase"))
                if request["operation"] == "cleanup":
                    client.close()
                    client = None
                    write_json(response, {"jobId": context["jobId"], "passed": True})
                    return
                try:
                    if request["operation"] != "feature" or own_launch(run, context) != launch:
                        raise WorkError("ITL_PERFORMANCE_CLIENT_OR_OPERATION_CHANGED")
                    result = run_feature(client, request["feature"], path.with_name(path.name.replace("request-", "evidence-")))
                    if own_launch(run, context) != launch:
                        raise WorkError("ITL_PERFORMANCE_CLIENT_CHANGED_DURING_SCENARIO")
                    result["jobId"] = context["jobId"]
                    write_json(response, result)
                except Exception as error:
                    write_json(response, {"jobId": context["jobId"], "passed": False, "error": str(error)})
            time.sleep(0.02)
    except Exception as error:
        cleanup_errors.extend(getattr(error, "cleanup_errors", []))
        write_json(control / "error.json", {"jobId": context["jobId"], "error": str(error)})
        raise
    finally:
        errors = cleanup_errors
        if client:
            try:
                client.deadline = Deadline("cleanup", context.get("phaseTimeoutSeconds", {}).get("cleanup", 300))
                client.close()
            except Exception as error:
                errors.append(str(error))
        write_json(control / "stopped.json", {"jobId": context["jobId"], "passed": not errors, "errors": errors})
        if errors:
            raise WorkError("ITL_PERFORMANCE_CLEANUP_FAILED: " + "; ".join(errors))


def wait_response(path, context, timeout=None):
    control = Path(context["run"]) / "vanessa-control"
    deadline = Deadline.from_context(context)
    if timeout is not None:
        deadline = Deadline(deadline.phase, min(timeout, deadline.remaining()), cancel_path=context.get("cancelPath"))
    while not Path(path).exists():
        if deadline.phase != "cleanup" and (control / "error.json").exists():
            raise WorkError(read_json(control / "error.json")["error"])
        deadline.remaining()
        time.sleep(0.02)
    result = read_json(path)
    if result.get("jobId") != context["jobId"] or result.get("passed") is False:
        raise WorkError("ITL_PERFORMANCE_ADAPTER_FAILED: " + str(result))
    return result


def quiesce(context_path):
    """Close only this measurement's adapter; never restore the measured data."""
    context_path = Path(context_path).resolve()
    context = read_json(context_path)
    control = context_path.parent / "vanessa-control"
    started = control / "started.json"
    if not started.exists():
        return {"adapter": "vanessa", "status": "not-used"}
    if read_json(started).get("jobId") != context["jobId"]:
        raise WorkError("ITL_PERFORMANCE_FOREIGN_ADAPTER")
    stopped = command("cleanup", context_path=context_path)
    if not isinstance(stopped, dict) or stopped.get("passed") is not True or stopped.get("errors") != []:
        raise WorkError("ITL_PERFORMANCE_QUIESCENCE_UNPROVEN")
    return {"adapter": "vanessa", "status": "released", "jobId": context["jobId"]}


def wait_stopped(control, context):
    stopped = wait_response(control / "stopped.json", context)
    if stopped.get("passed") is not True or stopped.get("errors") != []:
        raise WorkError("ITL_PERFORMANCE_CLEANUP_UNPROVEN")
    return stopped


def command(operation, feature=None, *, context_path=None):
    context_path = Path(context_path or os.environ["ITL_RUN_CONTEXT"]).resolve()
    context = read_json(context_path)
    run = context_path.parent
    context["run"] = str(run)
    control = run / "vanessa-control"
    control.mkdir(exist_ok=True)
    if operation == "cleanup" and (control / "stopped.json").exists():
        return wait_stopped(control, context)
    if operation == "prepare":
        if (control / "started.json").exists():
            raise WorkError("ITL_PERFORMANCE_ADAPTER_ALREADY_STARTED")
        with (run / "vanessa-daemon.log").open("wb") as log:
            process = subprocess.Popen([sys.executable, str(Path(__file__).resolve().parent.parent / "vanessa_work.py"),
                                        "daemon", str(Path(feature).resolve())],
                                       stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        write_json(control / "started.json", {"jobId": context["jobId"], "pid": process.pid})
        return wait_response(control / "prepared.json", context)
    if operation == "cleanup" and not (control / "prepared.json").exists():
        if not (control / "started.json").exists():
            return
        return wait_stopped(control, context)
    nonce = uuid.uuid4().hex
    request = control / ("request-" + nonce + ".json")
    write_json(request, {"jobId": context["jobId"], "operation": "cleanup" if operation == "cleanup" else "feature",
                         "feature": str(Path(feature).resolve()) if feature else None, "phase": context.get("phase")})
    if operation == "cleanup":
        # Another caller can already be closing the same daemon. Its terminal
        # acknowledgement covers shutdown; a second request may never be read.
        return wait_stopped(control, context)
    return wait_response(control / ("response-" + nonce + ".json"), context)
